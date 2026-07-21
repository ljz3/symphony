defmodule SymphonyElixir.Backend.KimiACP.Catalog do
  @moduledoc """
  Caches the available `(model, effort?)` options of every configured ACP
  backend, learned from each agent's live session config options.

  A backend with no successful probe yet reports `:loading`; a failed probe
  reports `{:failed, reason}`; a backend that is not configured (or catalog
  probing is disabled) reports `:disabled` without spawning any agent
  process or producing log noise.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.AgentStage
  alias SymphonyElixir.Backend.KimiACP
  alias SymphonyElixir.{Paths, Workflow}

  @refresh_interval_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec status() :: %{String.t() => map()}
  def status do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, :status)
      _ -> %{}
    end
  end

  @spec pairs(String.t(), [AgentStage.model_option()]) :: [AgentStage.model_option()]
  def pairs(backend, options) when is_binary(backend) and is_list(options) do
    case status()[backend] do
      %{state: :available, options: available} ->
        available_set = MapSet.new(available)
        Enum.filter(options, fn {_backend, model, effort} -> MapSet.member?(available_set, {model, effort}) end)

      _ ->
        options
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
    {:ok, %{backends: %{}, loading: false, task_ref: nil}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.backends, state}
  end

  @impl true
  def handle_info(:refresh, %{loading: true} = state), do: {:noreply, state}

  def handle_info(:refresh, state) do
    task = Elixir.Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, &load_catalogs/0)
    {:noreply, %{state | loading: true, task_ref: task.ref}}
  end

  def handle_info({reference, result}, %{task_ref: reference} = state) do
    Process.demonitor(reference, [:flush])
    Process.send_after(self(), :refresh, @refresh_interval_ms)

    {:noreply, %{state | backends: result, loading: false, task_ref: nil}}
  end

  def handle_info({_reference, _result}, state), do: {:noreply, state}

  def handle_info({:DOWN, reference, :process, _pid, _reason}, %{task_ref: reference} = state) do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
    {:noreply, %{state | loading: false, task_ref: nil}}
  end

  def handle_info({:DOWN, _reference, :process, _pid, _reason}, state), do: {:noreply, state}

  defp load_catalogs do
    case Workflow.current() do
      {:ok, bundle} ->
        bundle.backends
        |> Enum.filter(fn {_name, config} -> config[:protocol] == "acp" end)
        |> Map.new(fn {backend, _config} -> {backend, load_backend_catalog(backend, bundle)} end)

      {:error, _reason} ->
        %{}
    end
  end

  defp load_backend_catalog(backend, bundle) do
    if Application.get_env(:symphony_elixir, :catalog_enabled, true) do
      workspace = Path.join(Paths.runtime_root(bundle.project.id), "catalog")
      models = policy_models(bundle, backend)

      case KimiACP.catalog_options(workspace, backend: backend, models: models) do
        {:ok, options} -> %{state: :available, options: options, checked_at: checked_at()}
        {:error, reason} -> %{state: :failed, error: reason, checked_at: checked_at()}
      end
    else
      %{state: :disabled}
    end
  end

  # Only policy models are probed; each probe sets the model once to learn
  # its model-dependent thinking options.
  defp policy_models(bundle, backend) do
    bundle.stages
    |> Enum.flat_map(fn {_id, stage} -> stage.allowed end)
    |> Enum.filter(fn {stage_backend, _model, _effort} -> stage_backend == backend end)
    |> Enum.map(fn {_backend, model, _effort} -> model end)
    |> Enum.uniq()
  end

  defp checked_at do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
