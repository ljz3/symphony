defmodule SymphonyElixir.Board.Checkpoint do
  @moduledoc """
  Creates and verifies SQLite snapshots on the separate Git checkpoints branch.
  """

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.Board.{History, Projection, Storage}
  alias SymphonyElixir.{Repo, Workflow}

  @spec create() :: {:ok, map()} | {:error, term()}
  def create do
    with {:ok, bundle} <- Workflow.current(),
         sequence when sequence > 0 <- Projection.last_sequence(),
         head when is_binary(head) <- Projection.history_head(),
         database when is_binary(database) <- Repo.config()[:database],
         snapshot <- snapshot_path(database, sequence),
         :ok <- vacuum_into(snapshot),
         {:ok, contents} <- File.read(snapshot),
         checksum <- Base.encode16(:crypto.hash(:sha256, contents), case: :lower),
         {:ok, commit_oid} <- History.commit_checkpoint(bundle.project.id, sequence, head, snapshot, checksum) do
      File.rm(snapshot)
      {:ok, %{sequence: sequence, event_oid: head, checkpoint_oid: commit_oid, sha256: checksum}}
    else
      0 -> {:error, :no_events_to_checkpoint}
      nil -> {:error, :projection_head_unavailable}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:checkpoint_failed, other}}
    end
  end

  @spec restore_latest(String.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def restore_latest(project_id, destination) when is_binary(project_id) and is_binary(destination) do
    with {:ok, manifest} when is_map(manifest) <- History.latest_checkpoint(project_id),
         true <- compatible?(manifest),
         :ok <- History.extract_checkpoint(project_id, manifest, destination) do
      {:ok, manifest}
    else
      {:ok, nil} -> {:error, :checkpoint_not_found}
      false -> {:error, :checkpoint_incompatible}
      {:error, reason} -> {:error, reason}
    end
  end

  defp vacuum_into(snapshot) do
    File.rm(snapshot)

    case SQL.query(Repo, "VACUUM INTO ?", [snapshot]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:sqlite_backup_failed, reason}}
    end
  end

  defp compatible?(manifest) do
    manifest["format_version"] == 1 and
      manifest["projection_migration_version"] <= Storage.migration_version()
  end

  defp snapshot_path(database, sequence) do
    database <> ".checkpoint-#{sequence}-#{Ecto.UUID.generate()}"
  end
end
