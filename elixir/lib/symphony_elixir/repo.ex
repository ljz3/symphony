defmodule SymphonyElixir.Repo do
  @moduledoc """
  SQLite repository for the rebuildable board projection and local workpads.
  """

  use Ecto.Repo,
    otp_app: :symphony_elixir,
    adapter: Ecto.Adapters.SQLite3

  alias SymphonyElixir.DatabaseRecovery
  alias SymphonyElixir.Paths
  alias SymphonyElixir.Workflow

  defmodule StartupError do
    @moduledoc false
    defexception [:database, :reason]

    @impl true
    def message(%__MODULE__{database: database, reason: reason}) do
      "database startup aborted for #{database}: #{inspect(reason)}"
    end
  end

  @impl true
  def init(_context, config) do
    project_id = current_project_id()
    database = Keyword.get(config, :database, Paths.database(project_id))

    case DatabaseRecovery.prepare(project_id, database) do
      :ok -> :ok
      {:error, reason} -> raise StartupError, database: database, reason: reason
    end

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
end
