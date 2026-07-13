defmodule SymphonyElixir.Codex.Catalog do
  @moduledoc "Caches Codex's complete hidden/paginated model catalog for task editing."

  use GenServer

  alias SymphonyElixir.AgentStage
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Paths, Workflow}

  @refresh_interval_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec status() :: map()
  def status do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, :status)
      _ -> %{available: false, loading: false, models: [], error: :not_started}
    end
  end

  @spec pairs(AgentStage.t()) :: [{String.t(), String.t()}]
  def pairs(%AgentStage{} = stage) do
    case status() do
      %{available: true, models: models} ->
        available = MapSet.new(models, & &1["model"])
        stage |> AgentStage.pairs() |> Enum.filter(fn {model, _effort} -> MapSet.member?(available, model) end)

      _ ->
        AgentStage.pairs(stage)
    end
  end

  @spec refresh() :: :ok
  def refresh do
    if Process.whereis(__MODULE__), do: send(__MODULE__, :refresh)
    :ok
  end

  @impl true
  def init(_opts) do
    send(self(), :refresh)
    {:ok, %{available: false, loading: false, models: [], error: nil, checked_at: nil, task_ref: nil}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, Map.drop(state, [:task_ref]), state}
  end

  @impl true
  def handle_info(:refresh, %{loading: true} = state), do: {:noreply, state}

  def handle_info(:refresh, state) do
    task =
      Elixir.Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, &load_catalog/0)

    {:noreply, %{state | loading: true, task_ref: task.ref}}
  end

  def handle_info({reference, result}, %{task_ref: reference} = state) do
    Process.demonitor(reference, [:flush])
    Process.send_after(self(), :refresh, @refresh_interval_ms)
    checked_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    next =
      case result do
        {:ok, models} ->
          %{state | available: true, loading: false, models: models, error: nil, checked_at: checked_at, task_ref: nil}

        {:error, reason} ->
          %{state | available: false, loading: false, error: reason, checked_at: checked_at, task_ref: nil}
      end

    Phoenix.PubSub.broadcast(SymphonyElixir.PubSub, "board:health", :board_health_changed)
    {:noreply, next}
  end

  def handle_info({_reference, _result}, state), do: {:noreply, state}

  def handle_info({:DOWN, reference, :process, _pid, reason}, %{task_ref: reference} = state) do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
    {:noreply, %{state | available: false, loading: false, error: {:catalog_process_exit, reason}, task_ref: nil}}
  end

  def handle_info({:DOWN, _reference, :process, _pid, _reason}, state), do: {:noreply, state}

  defp load_catalog do
    if Application.get_env(:symphony_elixir, :catalog_enabled, true) do
      with {:ok, bundle} <- Workflow.current() do
        workspace = Path.join(Paths.runtime_root(bundle.project.id), "catalog")
        AppServer.catalog(workspace)
      end
    else
      {:error, :catalog_disabled}
    end
  end
end
