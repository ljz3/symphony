defmodule SymphonyElixir.JobSupervisor do
  @moduledoc "Supervises external project jobs independently of Codex request handlers."

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec start_job(map(), GenServer.server()) :: DynamicSupervisor.on_start_child()
  def start_job(request, manager) when is_map(request) do
    DynamicSupervisor.start_child(__MODULE__, {SymphonyElixir.JobWorker, request: request, manager: manager})
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
