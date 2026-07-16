defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()

    children = [
      {Phoenix.PubSub, name: SymphonyElixir.PubSub},
      {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
      {Registry, keys: :unique, name: SymphonyElixir.DeterministicMerge.WorkerRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: SymphonyElixir.DeterministicMerge.WorkerSupervisor},
      SymphonyElixir.Workflow.Store,
      SymphonyElixir.JobSupervisor,
      SymphonyElixir.JobManager,
      SymphonyElixir.Repo,
      SymphonyElixir.Board.Storage,
      SymphonyElixir.Board.WorkpadStore,
      SymphonyElixir.Board.Lease,
      SymphonyElixir.Board.Writer,
      SymphonyElixir.MCP.Transport,
      SymphonyElixir.Board.Sync,
      SymphonyElixir.Codex.Catalog,
      SymphonyElixir.Orchestrator,
      SymphonyElixir.HttpServer
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    case Process.whereis(SymphonyElixir.Board.Writer) do
      pid when is_pid(pid) -> maybe_checkpoint_on_shutdown()
      nil -> :ok
    end

    :ok
  end

  defp maybe_checkpoint_on_shutdown do
    unless SymphonyElixir.Board.busy?(), do: SymphonyElixir.Board.checkpoint()
    :ok
  end
end
