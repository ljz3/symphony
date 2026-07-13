defmodule SymphonyElixir.Board.Storage do
  @moduledoc """
  Owns internal SQLite projection migrations and durability pragmas.
  """

  use GenServer

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.Repo

  @migration_version 2

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec migrate() :: :ok | {:error, term()}
  def migrate do
    with {:ok, _result} <- SQL.query(Repo, "PRAGMA journal_mode=WAL", []),
         {:ok, _result} <- SQL.query(Repo, "PRAGMA synchronous=FULL", []),
         {:ok, _result} <- SQL.query(Repo, "PRAGMA foreign_keys=ON", []),
         {:ok, _result} <- SQL.query(Repo, migration_table_sql(), []) do
      apply_migrations()
    end
  end

  @spec migration_version() :: non_neg_integer()
  def migration_version do
    case SQL.query(Repo, "SELECT COALESCE(MAX(version), 0) FROM board_migrations", []) do
      {:ok, %{rows: [[version]]}} -> version
      _ -> 0
    end
  end

  @spec supported_migration_version() :: pos_integer()
  def supported_migration_version, do: @migration_version

  @impl true
  def init(_opts) do
    case migrate() do
      :ok -> {:ok, %{migration_version: @migration_version}}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp apply_migrations do
    current = migration_version()

    with :ok <- maybe_apply_version_one(current), do: maybe_apply_version_two(current)
  end

  defp maybe_apply_version_one(current), do: if(current < 1, do: apply_version_one(), else: :ok)
  defp maybe_apply_version_two(current), do: if(current < 2, do: apply_version_two(), else: :ok)

  defp apply_version_one do
    Repo.transaction(&migrate_version_one/0)
    |> case do
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, {:projection_migration_failed, 1, reason}}
    end
  end

  defp migrate_version_one do
    Enum.each(version_one_statements(), fn statement -> SQL.query!(Repo, statement, []) end)

    SQL.query!(Repo, "INSERT INTO board_migrations(version, applied_at) VALUES (?, ?)", [
      1,
      timestamp()
    ])
  end

  defp apply_version_two do
    Repo.transaction(fn ->
      SQL.query!(
        Repo,
        """
        CREATE TABLE board_run_telemetry (
          run_id TEXT PRIMARY KEY,
          telemetry_json TEXT NOT NULL,
          updated_at TEXT NOT NULL
        ) STRICT
        """,
        []
      )

      SQL.query!(Repo, "INSERT INTO board_migrations(version, applied_at) VALUES (?, ?)", [
        2,
        timestamp()
      ])
    end)
    |> case do
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, {:projection_migration_failed, 2, reason}}
    end
  end

  defp migration_table_sql do
    """
    CREATE TABLE IF NOT EXISTS board_migrations (
      version INTEGER PRIMARY KEY,
      applied_at TEXT NOT NULL
    ) STRICT
    """
  end

  defp version_one_statements do
    [
      """
      CREATE TABLE board_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      ) STRICT
      """,
      """
      CREATE TABLE board_events (
        sequence INTEGER PRIMARY KEY,
        event_id TEXT NOT NULL UNIQUE,
        command_id TEXT NOT NULL,
        idempotency_key TEXT NOT NULL,
        task_id TEXT,
        run_id TEXT,
        task_revision INTEGER NOT NULL,
        event_type TEXT NOT NULL,
        git_oid TEXT NOT NULL,
        event_json TEXT NOT NULL,
        inserted_at TEXT NOT NULL
      ) STRICT
      """,
      "CREATE UNIQUE INDEX board_events_command_id_index ON board_events(command_id)",
      """
      CREATE TABLE board_tasks (
        id TEXT PRIMARY KEY,
        identifier TEXT NOT NULL UNIQUE,
        number INTEGER NOT NULL UNIQUE,
        column_id TEXT NOT NULL,
        rank INTEGER NOT NULL,
        priority INTEGER NOT NULL,
        revision INTEGER NOT NULL,
        archived INTEGER NOT NULL CHECK(archived IN (0, 1)),
        task_json TEXT NOT NULL,
        updated_at TEXT NOT NULL
      ) STRICT
      """,
      "CREATE INDEX board_tasks_dispatch_index ON board_tasks(archived, column_id, priority, rank)",
      """
      CREATE TABLE board_runs (
        id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL,
        stage_id TEXT NOT NULL,
        status TEXT NOT NULL,
        run_json TEXT NOT NULL,
        updated_at TEXT NOT NULL
      ) STRICT
      """,
      "CREATE INDEX board_runs_task_index ON board_runs(task_id, updated_at)",
      """
      CREATE TABLE board_workpads (
        run_id TEXT NOT NULL,
        invocation INTEGER NOT NULL,
        content TEXT NOT NULL,
        published INTEGER NOT NULL DEFAULT 0 CHECK(published IN (0, 1)),
        publication_id TEXT,
        updated_at TEXT NOT NULL,
        PRIMARY KEY(run_id, invocation)
      ) STRICT
      """,
      """
      CREATE TABLE board_idempotency (
        idempotency_key TEXT PRIMARY KEY,
        command_id TEXT NOT NULL,
        event_id TEXT NOT NULL,
        result_json TEXT NOT NULL,
        inserted_at TEXT NOT NULL
      ) STRICT
      """,
      """
      CREATE TABLE board_external_effects (
        id TEXT PRIMARY KEY,
        task_id TEXT,
        kind TEXT NOT NULL,
        state TEXT NOT NULL,
        effect_json TEXT NOT NULL,
        updated_at TEXT NOT NULL
      ) STRICT
      """
    ]
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
  end
end
