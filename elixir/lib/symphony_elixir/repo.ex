defmodule SymphonyElixir.Repo do
  @moduledoc """
  SQLite repository for the rebuildable board projection and local workpads.
  """

  use Ecto.Repo,
    otp_app: :symphony_elixir,
    adapter: Ecto.Adapters.SQLite3

  alias Exqlite.Basic
  alias SymphonyElixir.Board.{History, Storage}
  alias SymphonyElixir.Paths
  alias SymphonyElixir.Workflow

  @impl true
  def init(_context, config) do
    project_id = current_project_id()
    database = Keyword.get(config, :database, Paths.database(project_id))
    maybe_restore_checkpoint(project_id, database)

    {:ok,
     config
     |> Keyword.put(:database, database)
     |> Keyword.put(:pool_size, 1)
     |> Keyword.put(:journal_mode, :wal)
     |> Keyword.put(:synchronous, :full)
     |> Keyword.put(:foreign_keys, :on)}
  end

  defp current_project_id do
    case Workflow.project_identity() do
      {:ok, %{id: id}} -> id
      _ -> "unconfigured"
    end
  end

  defp maybe_restore_checkpoint(project_id, database) do
    if File.exists?(database) and database_healthy?(database) do
      :ok
    else
      :ok = File.mkdir_p(Path.dirname(database))
      remove_database_files(database)

      with {:ok, manifest} when is_map(manifest) <- History.latest_checkpoint(project_id),
           true <- manifest["format_version"] == 1,
           true <- manifest["projection_migration_version"] <= Storage.supported_migration_version(),
           :ok <- History.extract_checkpoint(project_id, manifest, database),
           true <- database_healthy?(database) do
        :ok
      else
        _reason ->
          File.rm(database)
          :ok
      end
    end
  end

  defp database_healthy?(database) do
    case Basic.open(database) do
      {:ok, connection} ->
        result =
          connection
          |> Basic.exec("PRAGMA quick_check")
          |> Basic.rows()

        healthy = match?({:ok, [["ok"]], _columns}, result)

        Basic.close(connection)
        healthy

      {:error, _reason} ->
        false
    end
  rescue
    _error -> false
  end

  defp remove_database_files(database) do
    Enum.each([database, database <> "-wal", database <> "-shm"], &File.rm/1)
  end
end
