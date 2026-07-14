defmodule SymphonyElixir.DatabaseRecovery do
  @moduledoc """
  Classifies SQLite health without destructive fallback and installs validated
  replacements while retaining confirmed-corrupt database families.
  """

  alias Exqlite.{Basic, Connection}
  alias SymphonyElixir.Board.{History, Storage}
  alias SymphonyElixir.Paths

  @type health :: :healthy | {:confirmed_corrupt, term()} | {:indeterminate, term()}

  @spec prepare(String.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def prepare(project_id, database, opts \\ []) when is_binary(project_id) and is_binary(database) do
    health_check = Keyword.get(opts, :health_check, &health/1)

    case family_state(database, health_check) do
      :healthy ->
        :ok

      :missing ->
        replace(project_id, database, :missing, health_check, opts)

      {:confirmed_corrupt, diagnostics} ->
        replace(project_id, database, {:confirmed_corrupt, diagnostics}, health_check, opts)

      {:indeterminate, reason} ->
        {:error, {:database_health_indeterminate, database, reason}}
    end
  end

  @spec health(Path.t()) :: health()
  def health(database) when is_binary(database) do
    case Connection.connect(database: database, mode: :readonly) do
      {:ok, connection} -> check_connection(connection)
      {:error, reason} -> {:indeterminate, {:open_failed, reason}}
    end
  rescue
    error -> {:indeterminate, {:health_check_exception, Exception.message(error)}}
  catch
    kind, reason -> {:indeterminate, {:health_check_failure, kind, reason}}
  end

  defp family_state(database, health_check) do
    family = existing_family(database)

    cond do
      family == [] -> :missing
      database not in family -> {:confirmed_corrupt, {:database_missing_with_sidecars, family}}
      true -> normalize_health(health_check.(database))
    end
  rescue
    error -> {:indeterminate, {:health_check_exception, Exception.message(error)}}
  catch
    kind, reason -> {:indeterminate, {:health_check_failure, kind, reason}}
  end

  defp normalize_health(:healthy), do: :healthy
  defp normalize_health({:confirmed_corrupt, _reason} = result), do: result
  defp normalize_health({:indeterminate, _reason} = result), do: result
  defp normalize_health(other), do: {:indeterminate, {:invalid_health_result, other}}

  defp check_connection(connection) do
    connection
    |> Basic.exec("PRAGMA quick_check")
    |> Basic.rows()
    |> case do
      {:ok, [["ok"]], _columns} -> :healthy
      {:ok, rows, _columns} -> {:confirmed_corrupt, {:quick_check_failed, rows}}
      {:error, reason} -> {:indeterminate, {:quick_check_error, reason}}
    end
  rescue
    error -> {:indeterminate, {:quick_check_exception, Exception.message(error)}}
  catch
    kind, reason -> {:indeterminate, {:quick_check_failure, kind, reason}}
  after
    safe_close(connection)
  end

  defp safe_close(connection) do
    Basic.close(connection)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp replace(project_id, database, classification, health_check, opts) do
    staging_root = Path.join(Path.dirname(database), ".recovery-staging-#{Ecto.UUID.generate()}")
    staged = Path.join(staging_root, Path.basename(database))
    builder = Keyword.get(opts, :replacement_builder, &build_replacement(project_id, &1))

    try do
      build_and_install(builder, staged, health_check, database, classification, project_id, opts)
    after
      File.rm_rf(staging_root)
    end
  end

  defp build_and_install(builder, staged, health_check, database, classification, project_id, opts) do
    with :ok <- private_directory(Path.dirname(staged)),
         :ok <- normalize_builder_result(builder.(staged)),
         :ok <- validate_replacement(staged, health_check) do
      install_replacement(database, staged, classification, project_id, opts)
    end
  rescue
    error -> {:error, {:replacement_build_failed, staged, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:replacement_build_failed, staged, {kind, reason}}}
  end

  defp normalize_builder_result(:ok), do: :ok
  defp normalize_builder_result({:error, _reason} = error), do: error
  defp normalize_builder_result(other), do: {:error, {:invalid_replacement_builder_result, other}}

  defp validate_replacement(staged, health_check) do
    case normalize_health(health_check.(staged)) do
      :healthy -> :ok
      {:confirmed_corrupt, reason} -> {:error, {:replacement_validation_failed, staged, reason}}
      {:indeterminate, reason} -> {:error, {:replacement_validation_indeterminate, staged, reason}}
    end
  rescue
    error -> {:error, {:replacement_validation_indeterminate, staged, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:replacement_validation_indeterminate, staged, {kind, reason}}}
  end

  defp build_replacement(project_id, staged) do
    case History.latest_checkpoint(project_id) do
      {:ok, nil} -> create_empty_database(staged)
      {:ok, manifest} -> build_checkpoint_or_empty(project_id, manifest, staged)
      {:error, reason} -> {:error, {:checkpoint_lookup_failed, reason}}
    end
  end

  defp build_checkpoint_or_empty(project_id, manifest, staged) do
    case extract_compatible_checkpoint(project_id, manifest, staged) do
      :ok -> :ok
      {:error, _reason} -> reset_to_empty_database(staged)
    end
  end

  defp reset_to_empty_database(staged) do
    Enum.each([staged, staged <> "-wal", staged <> "-shm"], &File.rm/1)
    create_empty_database(staged)
  end

  defp extract_compatible_checkpoint(project_id, manifest, staged) do
    with 1 <- manifest["format_version"],
         version when is_integer(version) <- manifest["projection_migration_version"],
         true <- version <= Storage.supported_migration_version(),
         :ok <- History.extract_checkpoint(project_id, manifest, staged) do
      :ok
    else
      false -> {:error, {:checkpoint_migration_too_new, manifest["projection_migration_version"]}}
      {:error, reason} -> {:error, {:checkpoint_extract_failed, reason}}
      _ -> {:error, :incompatible_checkpoint_manifest}
    end
  end

  defp create_empty_database(staged) do
    case Basic.open(staged) do
      {:ok, connection} ->
        safe_close(connection)
        :ok

      {:error, reason} ->
        {:error, {:empty_database_create_failed, reason}}
    end
  rescue
    error -> {:error, {:empty_database_create_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:empty_database_create_failed, {kind, reason}}}
  end

  defp install_replacement(database, staged, :missing, _project_id, opts) do
    rename = Keyword.get(opts, :rename, &File.rename/2)

    case File.mkdir_p(Path.dirname(database)) do
      :ok -> rename_replacement(rename, staged, database)
      {:error, reason} -> {:error, {:replacement_install_failed, database, reason}}
    end
  end

  defp install_replacement(database, staged, {:confirmed_corrupt, _diagnostics}, project_id, opts) do
    recovery_root = Keyword.get(opts, :recovery_root, Paths.recovery_root(project_id))
    quarantine = Path.join(recovery_root, quarantine_name())
    rename = Keyword.get(opts, :rename, &File.rename/2)

    with :ok <- private_directory(recovery_root),
         :ok <- private_directory(quarantine),
         {:ok, moved} <- quarantine_family(database, quarantine, rename) do
      install_or_rollback(database, staged, quarantine, moved, rename)
    end
  end

  defp rename_replacement(rename, staged, database) do
    case rename.(staged, database) do
      :ok -> :ok
      {:error, reason} -> {:error, {:replacement_install_failed, database, reason}}
    end
  end

  defp quarantine_family(database, quarantine, rename) do
    existing_family(database)
    |> Enum.reduce_while({:ok, []}, fn source, {:ok, moved} ->
      destination = Path.join(quarantine, Path.basename(source))

      case rename.(source, destination) do
        :ok -> {:cont, {:ok, [{source, destination} | moved]}}
        {:error, reason} -> {:halt, rollback_quarantine(moved, {:quarantine_failed, source, reason}, rename)}
      end
    end)
  end

  defp install_or_rollback(database, staged, quarantine, moved, rename) do
    case rename.(staged, database) do
      :ok ->
        :ok

      {:error, reason} ->
        rollback_quarantine(moved, {:replacement_install_failed, database, reason}, rename)
        |> case do
          {:error, install_reason} ->
            File.rmdir(quarantine)
            {:error, install_reason}
        end
    end
  end

  defp rollback_quarantine(moved, original_reason, rename) do
    failures =
      Enum.reduce(moved, [], fn {source, destination}, failures ->
        case rename.(destination, source) do
          :ok -> failures
          {:error, reason} -> [{destination, source, reason} | failures]
        end
      end)

    if failures == [],
      do: {:error, original_reason},
      else: {:error, {:recovery_rollback_failed, original_reason, Enum.reverse(failures)}}
  end

  defp existing_family(database) do
    [database, database <> "-wal", database <> "-shm"]
    |> Enum.filter(&File.exists?/1)
  end

  defp private_directory(path) do
    case File.mkdir_p(path) do
      :ok -> File.chmod(path, 0o700)
      {:error, reason} -> {:error, reason}
    end
  end

  defp quarantine_name do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%S%fZ")
    "#{timestamp}-#{Ecto.UUID.generate()}"
  end
end
