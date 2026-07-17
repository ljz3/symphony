defmodule SymphonyElixir.DeterministicMerge.Worker do
  @moduledoc """
  Runs the single deterministic-merge effect independently of the Orchestrator.

  The unique registry slot survives an Orchestrator restart, allowing the new
  Orchestrator to observe the existing worker instead of starting a concurrent
  mutation against the same project worktree.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Task
  alias SymphonyElixir.Workflow.Bundle

  @registry SymphonyElixir.DeterministicMerge.WorkerRegistry
  @supervisor SymphonyElixir.DeterministicMerge.WorkerSupervisor
  @slot :active
  @cancel_escalation_ms 2_000

  @type runner :: (Task.t(), Bundle.t(), keyword() -> term())
  @type active_worker :: {:ok, String.t(), pid()} | :none

  @doc "Returns the single active merge worker, if one exists."
  @spec active() :: active_worker()
  def active do
    case Registry.lookup(@registry, @slot) do
      [{pid, task_id}] -> {:ok, task_id, pid}
      [] -> :none
    end
  end

  @doc "Starts the merge worker or returns the worker that already owns the slot."
  @spec ensure_started(Task.t(), Bundle.t(), runner()) ::
          active_worker() | {:error, term()}
  def ensure_started(%Task{} = task, %Bundle{} = bundle, runner) when is_function(runner, 3) do
    ensure_started(task, bundle, runner, [])
  end

  @doc false
  @spec ensure_started(Task.t(), Bundle.t(), runner(), keyword()) ::
          active_worker() | {:error, term()}
  def ensure_started(%Task{} = task, %Bundle{} = bundle, runner, opts)
      when is_function(runner, 3) and is_list(opts) do
    supervisor = Keyword.get(opts, :supervisor, @supervisor)
    worker_opts = [task: task, bundle: bundle, runner: runner]

    case DynamicSupervisor.start_child(supervisor, {__MODULE__, worker_opts}) do
      {:ok, pid} -> {:ok, task.id, pid}
      {:error, {:already_started, _pid}} -> active()
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Cancels an invalidated merge worker and escalates only after that explicit cancellation."
  @spec cancel(pid(), String.t()) :: :ok
  def cancel(pid, task_id) when is_pid(pid) and is_binary(task_id) do
    send(pid, {:cancel_deterministic_merge, task_id})

    spawn(fn -> force_cancel_if_running(pid) end)
    :ok
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    task = Keyword.fetch!(opts, :task)
    name = {:via, Registry, {@registry, @slot, task.id}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :task).id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @impl true
  def init(opts) do
    state = %{
      task: Keyword.fetch!(opts, :task),
      bundle: Keyword.fetch!(opts, :bundle),
      runner: Keyword.fetch!(opts, :runner)
    }

    {:ok, state, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    result = state.runner.(state.task, state.bundle, [])
    log_result(state.task.id, result)
    {:stop, :normal, state}
  end

  defp log_result(task_id, {:ok, outcome}) do
    Logger.info("deterministic merge worker completed task_id=#{task_id} outcome=#{outcome}")
  end

  defp log_result(task_id, result) do
    Logger.warning("deterministic merge worker failed task_id=#{task_id} result=#{inspect(result)}")
  end

  defp force_cancel_if_running(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      @cancel_escalation_ms ->
        Process.demonitor(ref, [:flush])

        if Process.alive?(pid) do
          _ = DynamicSupervisor.terminate_child(@supervisor, pid)
        end
    end
  end
end
