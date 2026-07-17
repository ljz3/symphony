defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Event-driven dispatcher and runtime reconciler for board tasks.

  A failed invocation is blocked immediately. There is deliberately no retry
  queue; only GitHub publication outages wait inside the same run/session.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Board
  alias SymphonyElixir.Board.{Commands, Lease, Projection, Sync, Writer}
  alias SymphonyElixir.Codex.{Activity, AppServer, RunStats}
  alias SymphonyElixir.Config
  alias SymphonyElixir.DeterministicMerge
  alias SymphonyElixir.DeterministicMerge.Worker, as: MergeWorker
  alias SymphonyElixir.GitHub
  alias SymphonyElixir.JobManager
  alias SymphonyElixir.ReviewAttestation
  alias SymphonyElixir.SSH
  alias SymphonyElixir.Task
  alias SymphonyElixir.Workflow.{Bundle, Store}
  alias SymphonyElixir.Worktree

  @reconcile_interval_ms 1_000
  @github_health_ttl_ms 5_000
  @worker_health_retry_ms 5_000
  @worker_health_refresh_ms 30_000
  @graceful_stop_ms 10_000
  @forced_stop_ms 5_000
  @telemetry_broadcast_delay_ms 250

  defmodule State do
    @moduledoc false
    defstruct started_at: nil,
              running: %{},
              refs: %{},
              merging: %{},
              merge_refs: %{},
              merge_retry_after: %{},
              merge_retry_ms: 1_000,
              preflights: %{},
              preflight_refs: %{},
              preflight_failures: %{},
              worker_health: %{},
              worker_health_refs: %{},
              cleanup_errors: %{},
              cleanup_running: MapSet.new(),
              cleanup_completed: MapSet.new(),
              rate_limits: %{},
              telemetry_broadcasts: MapSet.new(),
              publication_errors: %{},
              github_health: nil,
              github_health_checked_at: 0,
              dispatch_gate: nil,
              dispatch_enabled: nil,
              recover_orphans: true,
              task_filter: nil,
              last_reconciled_at: nil,
              agent_runner: nil,
              merge_runner: nil,
              rework_drafter: nil,
              github_outcome_recorder: nil

    @type t :: %__MODULE__{}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec status() :: map()
  def status do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(pid, :status)

      _ ->
        %{
          online: false,
          started_at: nil,
          running: [],
          preflights: [],
          worker_health: [],
          rate_limits: [],
          dispatch_gate: :not_started,
          cleanup_errors: %{},
          publication_errors: %{}
        }
    end
  end

  @spec refresh() :: :ok
  def refresh do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> send(pid, :reconcile)
      _ -> :ok
    end

    :ok
  end

  @impl true
  def init(opts) do
    :ok = Board.subscribe(:tasks)
    :ok = Board.subscribe(:workflow)
    :ok = Board.subscribe(:health)
    schedule_reconcile(0)

    {:ok,
     %State{
       started_at: timestamp(),
       dispatch_enabled: Keyword.get(opts, :dispatch_enabled),
       recover_orphans: Keyword.get(opts, :recover_orphans, true),
       task_filter: Keyword.get(opts, :task_filter),
       agent_runner: Keyword.get(opts, :agent_runner, &AgentRunner.run/3),
       merge_runner: Keyword.get(opts, :merge_runner, &DeterministicMerge.run/3),
       merge_retry_ms: Keyword.get(opts, :merge_retry_ms, @reconcile_interval_ms),
       rework_drafter: Keyword.get(opts, :rework_drafter),
       github_outcome_recorder: Keyword.get(opts, :github_outcome_recorder)
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    running =
      Enum.map(state.running, fn {task_id, runtime} ->
        %{
          task_id: task_id,
          run_id: runtime.run_id,
          worker_host: runtime.worker_host,
          workspace_path: runtime.workspace_path,
          session_id: runtime.session && runtime.session.thread_id,
          last_activity: runtime.last_activity,
          last_activity_at: runtime.last_activity_at,
          stopping: runtime.stopping
        }
      end)

    {:reply,
     %{
       online: true,
       started_at: state.started_at,
       running: running,
       merging:
         state.merging
         |> Enum.map(fn {task_id, runtime} -> %{task_id: task_id, started_at: runtime.started_at} end)
         |> Enum.sort_by(& &1.task_id),
       merge_retries:
         state.merge_retry_after
         |> Enum.map(fn {task_id, retry} -> %{task_id: task_id, next_retry_at: retry.next_retry_at} end)
         |> Enum.sort_by(& &1.task_id),
       preflights: preflight_status(state),
       worker_health: worker_health_status(state),
       rate_limits: state.rate_limits |> Map.values() |> Enum.sort_by(& &1["worker"]),
       dispatch_gate: state.dispatch_gate,
       github: state.github_health,
       cleanup_errors: state.cleanup_errors,
       publication_errors: state.publication_errors,
       last_reconciled_at: state.last_reconciled_at
     }, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    schedule_reconcile(@reconcile_interval_ms)

    state =
      state
      |> recover_orphan_runs()
      |> reconcile_desired_stops()
      |> reconcile_external_effects()
      |> dispatch_candidates()
      |> Map.put(:last_reconciled_at, timestamp())

    {:noreply, state}
  end

  def handle_info({:task_changed, task_id}, state) do
    previous = state

    state =
      state
      |> reconcile_task_merge(task_id)
      |> reconcile_task_preflight(task_id)
      |> maybe_request_stop(task_id)
      |> maybe_terminal_cleanup(task_id)
      |> broadcast_preflight_change(previous)

    send(self(), :reconcile)
    {:noreply, state}
  end

  def handle_info({:workflow_activated, _hash}, state) do
    previous = state
    bundle = Config.bundle!()

    state =
      state
      |> cancel_all_merges(:workflow_changed)
      |> Map.put(:merge_retry_after, %{})
      |> cancel_all_preflights()
      |> Map.put(:preflight_failures, %{})
      |> broadcast_preflight_change(previous)
      |> reconcile_worker_health_if_dispatching(bundle)

    send(self(), :reconcile)
    {:noreply, state}
  end

  def handle_info({:github_wait, _task_id, _run_id, reason, _backoff_ms}, state) do
    health = %{available: false, authenticated: true, error: reason}
    {:noreply, %{state | github_health: health, github_health_checked_at: System.monotonic_time(:millisecond)}}
  end

  def handle_info(:board_health_changed, state), do: {:noreply, state}

  def handle_info({:runner_session, task_id, run_id, session, worktree}, state) do
    state =
      update_in(state.running[task_id], fn
        %{run_id: ^run_id} = runtime -> %{runtime | session: session, workspace_path: worktree}
        runtime -> runtime
      end)

    {:noreply, schedule_telemetry_broadcast(state, run_id)}
  end

  def handle_info({:runner_update, task_id, run_id, update}, state) do
    case state.running[task_id] do
      %{run_id: ^run_id} = runtime ->
        activity = Activity.summary(update)
        activity_at = message_timestamp(update)

        runtime =
          runtime
          |> maybe_put_runtime(:last_activity, activity)
          |> maybe_put_runtime(:last_activity_at, if(activity, do: activity_at))

        state = put_in(state.running[task_id], runtime)
        state = maybe_put_rate_limits(state, runtime.worker_host, Activity.rate_limits(update), activity_at)
        {:noreply, schedule_telemetry_broadcast(state, run_id)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:broadcast_run_update, run_id}, state) do
    Phoenix.PubSub.broadcast(
      SymphonyElixir.PubSub,
      "board:runs",
      {:run_telemetry_changed, run_id}
    )

    {:noreply, %{state | telemetry_broadcasts: MapSet.delete(state.telemetry_broadcasts, run_id)}}
  end

  def handle_info({:preflight_phase, task_id, probe_id, phase, workspace_path}, state) do
    previous = state

    state =
      update_in(state.preflights[task_id], fn
        %{probe_id: ^probe_id, phase: current_phase} = preflight when current_phase != :cancelling ->
          %{
            preflight
            | phase: phase,
              workspace_path: workspace_path,
              last_activity_at: timestamp()
          }

        preflight ->
          preflight
      end)
      |> broadcast_preflight_change(previous)

    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.worker_health_refs, ref) do
      {nil, _worker_health_refs} ->
        handle_preflight_or_runner_result(ref, result, state)

      {{host, probe_id}, worker_health_refs} ->
        previous = state
        Process.demonitor(ref, [:flush])

        state =
          %{state | worker_health_refs: worker_health_refs}
          |> finish_worker_health_probe(host, probe_id, result)
          |> broadcast_worker_health_change(previous)

        send(self(), :reconcile)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.worker_health_refs, ref) do
      {nil, _worker_health_refs} ->
        handle_preflight_or_runner_down(ref, reason, state)

      {{host, probe_id}, worker_health_refs} ->
        previous = state

        state =
          %{state | worker_health_refs: worker_health_refs}
          |> finish_worker_health_probe(host, probe_id, {:error, {:worker_health_process_exit, reason}})
          |> broadcast_worker_health_change(previous)

        send(self(), :reconcile)
        {:noreply, state}
    end
  end

  def handle_info({:interrupt_runner, task_id, run_id}, state) do
    case state.running[task_id] do
      %{run_id: ^run_id, session: session} = runtime ->
        :ok = JobManager.cancel_run(run_id)
        if session, do: AppServer.stop_session(session)
        timer = Process.send_after(self(), {:kill_runner, task_id, run_id}, @forced_stop_ms)
        runtime = %{runtime | interrupt_timer: nil, kill_timer: timer}
        {:noreply, put_in(state.running[task_id], runtime)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:kill_runner, task_id, run_id}, state) do
    case state.running[task_id] do
      %{run_id: ^run_id, pid: pid} = runtime ->
        :ok = JobManager.cancel_run(run_id)
        _ = Elixir.Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid)
        {:noreply, put_in(state.running[task_id], %{runtime | kill_timer: nil})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:terminal_cleanup_result, task_id, result}, state) do
    cleanup_running = MapSet.delete(state.cleanup_running, task_id)

    cleanup_errors =
      case result do
        :ok -> Map.delete(state.cleanup_errors, task_id)
        {:error, reason} -> Map.put(state.cleanup_errors, task_id, reason)
      end

    cleanup_completed =
      if result == :ok,
        do: MapSet.put(state.cleanup_completed, task_id),
        else: state.cleanup_completed

    Phoenix.PubSub.broadcast(SymphonyElixir.PubSub, "board:health", :board_health_changed)

    {:noreply,
     %{
       state
       | cleanup_errors: cleanup_errors,
         cleanup_running: cleanup_running,
         cleanup_completed: cleanup_completed
     }}
  end

  defp handle_runner_result(ref, result, state) do
    case Map.pop(state.refs, ref) do
      {nil, _refs} ->
        {:noreply, state}

      {task_id, refs} ->
        Process.demonitor(ref, [:flush])
        {runtime, running} = Map.pop(state.running, task_id)
        cancel_stop_timers(runtime)
        state = %{state | refs: refs, running: running}
        state = finalize_runner_result(task_id, runtime.run_id, result, state)
        send(self(), :reconcile)
        {:noreply, state}
    end
  end

  defp handle_preflight_or_runner_result(ref, result, state) do
    case Map.pop(state.preflight_refs, ref) do
      {nil, _preflight_refs} ->
        handle_runner_result(ref, result, state)

      {task_id, preflight_refs} ->
        previous = state
        Process.demonitor(ref, [:flush])
        {preflight, preflights} = Map.pop(state.preflights, task_id)

        state =
          %{state | preflight_refs: preflight_refs, preflights: preflights}
          |> finish_preflight(preflight, result)
          |> broadcast_preflight_change(previous)

        send(self(), :reconcile)
        {:noreply, state}
    end
  end

  defp handle_runner_down(ref, reason, state) do
    case Map.pop(state.refs, ref) do
      {nil, _refs} ->
        {:noreply, state}

      {task_id, refs} ->
        {runtime, running} = Map.pop(state.running, task_id)
        cancel_stop_timers(runtime)
        state = %{state | refs: refs, running: running}
        state = finalize_runner_result(task_id, runtime.run_id, {:error, {:runner_exit, reason}}, state)
        send(self(), :reconcile)
        {:noreply, state}
    end
  end

  defp handle_preflight_or_runner_down(ref, reason, state) do
    case Map.pop(state.merge_refs, ref) do
      {nil, _merge_refs} ->
        handle_preflight_or_runner_down_without_merge(ref, reason, state)

      {task_id, merge_refs} ->
        {runtime, merging} = Map.pop(state.merging, task_id)
        log_merge_exit(task_id, reason)

        state =
          %{state | merge_refs: merge_refs, merging: merging}
          |> maybe_schedule_merge_retry(task_id, runtime)

        send(self(), :reconcile)
        {:noreply, state}
    end
  end

  defp handle_preflight_or_runner_down_without_merge(ref, reason, state) do
    case Map.pop(state.preflight_refs, ref) do
      {nil, _preflight_refs} ->
        handle_runner_down(ref, reason, state)

      {task_id, preflight_refs} ->
        previous = state
        {preflight, preflights} = Map.pop(state.preflights, task_id)

        state =
          %{state | preflight_refs: preflight_refs, preflights: preflights}
          |> finish_preflight(preflight, {:error, nil, {:preflight_process_exit, reason}})
          |> broadcast_preflight_change(previous)

        send(self(), :reconcile)
        {:noreply, state}
    end
  end

  defp finish_preflight(state, nil, _result), do: state

  defp finish_preflight(state, %{discard_result: true} = preflight, _result) do
    Logger.info(
      "preflight result discarded reason=#{preflight.cancellation_reason} task_id=#{preflight.task_id} " <>
        "task_identifier=#{preflight.identifier} task_revision=#{preflight.task_revision} " <>
        "workflow_hash=#{preflight.workflow_hash} worker_host=#{worker_label(preflight.worker_host)}"
    )

    state
  end

  defp finish_preflight(state, preflight, {:ok, _workspace_path, _output}) do
    claim_after_preflight(state, preflight)
  end

  defp finish_preflight(state, preflight, {:error, _workspace_path, reason}) do
    record_preflight_failure(state, preflight, reason)
  end

  defp finish_preflight(state, preflight, other) do
    record_preflight_failure(state, preflight, {:unexpected_preflight_result, other})
  end

  defp claim_after_preflight(state, preflight) do
    bundle = Config.bundle!()
    {state, gate} = refresh_dispatch_health(state)

    Logger.info(
      "preflight completed outcome=passed project_id=#{bundle.project.id} task_id=#{preflight.task_id} " <>
        "task_identifier=#{preflight.identifier} task_revision=#{preflight.task_revision} " <>
        "workflow_hash=#{preflight.workflow_hash} worker_host=#{worker_label(preflight.worker_host)}"
    )

    case gate do
      nil -> claim_current_preflight(state, preflight, bundle)
      reason -> defer_preflight_claim(state, preflight, reason)
    end
  end

  defp claim_current_preflight(state, preflight, bundle) do
    with {:ok, task} <- Board.task(preflight.task_id),
         true <- current_preflight_snapshot?(task, bundle, preflight, state),
         true <- worker_reservation_current?(preflight.worker_host, bundle, state),
         true <- capacity_load(state) < bundle.agent.max_concurrent_agents do
      finish_preflight_claim(claim_and_start(task, preflight.worker_host, state, bundle))
    else
      _stale -> discard_stale_preflight_claim(state, preflight)
    end
  end

  defp finish_preflight_claim({:ok, next}), do: next
  defp finish_preflight_claim({:error, _reason, next}), do: next

  defp discard_stale_preflight_claim(state, preflight) do
    Logger.info(
      "preflight result discarded reason=stale_snapshot task_id=#{preflight.task_id} " <>
        "task_identifier=#{preflight.identifier} task_revision=#{preflight.task_revision} " <>
        "workflow_hash=#{preflight.workflow_hash} worker_host=#{worker_label(preflight.worker_host)}"
    )

    state
  end

  defp defer_preflight_claim(state, preflight, reason) do
    Logger.info(
      "preflight result deferred reason=#{inspect(reason)} task_id=#{preflight.task_id} " <>
        "task_identifier=#{preflight.identifier} task_revision=#{preflight.task_revision} " <>
        "workflow_hash=#{preflight.workflow_hash} worker_host=#{worker_label(preflight.worker_host)}"
    )

    %{state | dispatch_gate: reason}
  end

  defp record_preflight_failure(state, preflight, reason) do
    bundle = Config.bundle!()

    case Board.task(preflight.task_id) do
      {:ok, task} ->
        if current_preflight_snapshot?(task, bundle, preflight, state) do
          failure = preflight_failure(preflight, reason)

          Logger.warning(
            "preflight failed project_id=#{bundle.project.id} task_id=#{preflight.task_id} " <>
              "task_identifier=#{preflight.identifier} task_revision=#{preflight.task_revision} " <>
              "workflow_hash=#{preflight.workflow_hash} " <>
              "worker_host=#{worker_label(preflight.worker_host)} reason=#{failure.reason_kind} " <>
              "fingerprint=#{failure.fingerprint} next_retry_at=#{failure.next_retry_at}"
          )

          %{state | preflight_failures: Map.put(state.preflight_failures, task.id, failure)}
        else
          state
        end

      _ ->
        state
    end
  end

  defp current_preflight_snapshot?(task, bundle, preflight, state) do
    task.revision == preflight.task_revision and bundle.hash == preflight.workflow_hash and
      preflight_dispatch_eligible?(task, bundle, state)
  end

  defp preflight_dispatch_eligible?(task, bundle, state) do
    eligible?(task, bundle) and not Map.has_key?(state.publication_errors, task.id)
  end

  defp worker_reservation_current?(nil, %{agent: %{ssh_hosts: []}}, _state), do: true

  defp worker_reservation_current?(host, bundle, state) when is_binary(host) do
    capacity = bundle.agent.max_concurrent_agents_per_host || bundle.agent.max_concurrent_agents
    host in bundle.agent.ssh_hosts and worker_load(state, host) < capacity
  end

  defp worker_reservation_current?(_host, _bundle, _state), do: false

  defp preflight_failure(preflight, reason) do
    {reason_kind, diagnostic} = preflight_failure_details(reason)
    delay = preflight.retry_after_failure_ms
    completed = DateTime.utc_now()
    fingerprint = failure_fingerprint(reason_kind, diagnostic)

    reason =
      if diagnostic == "",
        do: reason_kind,
        else: reason_kind <> ": " <> diagnostic

    %{
      task_id: preflight.task_id,
      identifier: preflight.identifier,
      task_revision: preflight.task_revision,
      workflow_hash: preflight.workflow_hash,
      worker_host: preflight.worker_host,
      status: :failed,
      fingerprint: fingerprint,
      reason: reason,
      reason_kind: reason_kind,
      completed_at: completed |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
      next_retry_at:
        completed
        |> DateTime.add(delay, :millisecond)
        |> DateTime.truncate(:microsecond)
        |> DateTime.to_iso8601(),
      retry_at_ms: System.monotonic_time(:millisecond) + delay
    }
  end

  defp preflight_failure_details({:preflight_failed, status, output}) do
    {"exit_status_#{status}", sanitize_preflight_output(output)}
  end

  defp preflight_failure_details(reason), do: {inspect(reason), ""}

  defp sanitize_preflight_output(output) when is_binary(output) do
    if String.valid?(output) do
      output
      |> String.replace(~r/\e\[[0-9;?]*[ -\/]*[@-~]/, "")
      |> String.trim()
    else
      inspect(output, binaries: :as_binaries)
    end
  end

  defp failure_fingerprint(reason, output) do
    :sha256
    |> :crypto.hash(reason <> "\0" <> output)
    |> Base.encode16(case: :lower)
  end

  defp dispatch_candidates(state) do
    {state, gate} = refresh_dispatch_health(state)

    case gate do
      nil -> state |> Map.put(:dispatch_gate, nil) |> dispatch_merge_candidates() |> do_dispatch_candidates()
      reason -> %{state | dispatch_gate: reason}
    end
  end

  defp dispatch_merge_candidates(%{merging: merging} = state) when map_size(merging) > 0, do: state

  defp dispatch_merge_candidates(state) do
    case MergeWorker.active() do
      {:ok, task_id, pid} -> observe_existing_merge_worker(state, task_id, pid)
      :none -> do_dispatch_merge_candidate(state)
    end
  end

  defp observe_existing_merge_worker(state, task_id, pid) do
    case Board.task(task_id) do
      {:ok, task} -> observe_merge_worker(state, task, pid, Config.bundle!())
      {:error, :not_found} -> state
    end
  end

  defp do_dispatch_merge_candidate(state) do
    bundle = Config.bundle!()

    candidate =
      Board.tasks()
      |> Enum.filter(&merge_eligible?(&1, bundle, state))
      |> Enum.sort_by(&{Task.priority_weight(&1.priority), &1.rank, &1.number})
      |> List.first()

    case candidate do
      nil -> state
      task -> start_merge_worker(state, task, bundle)
    end
  end

  defp merge_eligible?(task, bundle, state) do
    not Task.archived?(task) and is_nil(task.runtime_state) and is_nil(task.active_run_id) and
      match?(%{role: :merge}, Bundle.column(bundle, task.column_id)) and
      selected_candidate?(task, state.task_filter) and merge_retry_ready?(task, bundle, state)
  end

  defp start_merge_worker(state, task, bundle) do
    case MergeWorker.ensure_started(task, bundle, state.merge_runner) do
      {:ok, task_id, pid} ->
        if task_id == task.id,
          do: observe_merge_worker(state, task, pid, bundle),
          else: observe_existing_merge_worker(state, task_id, pid)

      :none ->
        state

      {:error, reason} ->
        Logger.warning("deterministic merge worker start failed task_id=#{task.id} reason=#{inspect(reason)}")
        state
    end
  end

  defp observe_merge_worker(state, task, pid, bundle) do
    ref = Process.monitor(pid)

    runtime = %{
      pid: pid,
      ref: ref,
      started_at: timestamp(),
      guard: merge_guard(task, bundle),
      cancelling: false
    }

    %{
      state
      | merging: Map.put(state.merging, task.id, runtime),
        merge_refs: Map.put(state.merge_refs, ref, task.id),
        merge_retry_after: Map.delete(state.merge_retry_after, task.id)
    }
  end

  defp log_merge_exit(task_id, :normal) do
    Logger.info("deterministic merge worker exited task_id=#{task_id} reason=normal")
  end

  defp log_merge_exit(task_id, reason) do
    Logger.warning("deterministic merge worker exited task_id=#{task_id} reason=#{inspect(reason)}")
  end

  defp reconcile_task_merge(state, task_id) do
    bundle = Config.bundle!()

    state = reconcile_merge_runtime(state, task_id, state.merging[task_id], bundle)

    clear_stale_merge_retry(state, task_id, bundle)
  end

  defp reconcile_merge_runtime(state, _task_id, nil, _bundle), do: state
  defp reconcile_merge_runtime(state, _task_id, %{cancelling: true}, _bundle), do: state

  defp reconcile_merge_runtime(state, task_id, runtime, bundle) do
    case Board.task(task_id) do
      {:ok, task} ->
        if merge_guard(task, bundle) == runtime.guard and merge_column?(task, bundle),
          do: state,
          else: cancel_merge_worker(state, task_id, :task_semantics_changed)

      {:error, :not_found} ->
        cancel_merge_worker(state, task_id, :task_missing)
    end
  end

  defp cancel_all_merges(state, reason) do
    Enum.reduce(Map.keys(state.merging), state, &cancel_merge_worker(&2, &1, reason))
  end

  defp cancel_merge_worker(state, task_id, reason) do
    case state.merging[task_id] do
      nil ->
        state

      %{cancelling: true} ->
        state

      runtime ->
        :ok = MergeWorker.cancel(runtime.pid, task_id)

        Logger.info("deterministic merge cancellation requested task_id=#{task_id} reason=#{reason}")

        put_in(state.merging[task_id], %{runtime | cancelling: true})
    end
  end

  defp maybe_schedule_merge_retry(state, _task_id, nil), do: state
  defp maybe_schedule_merge_retry(state, _task_id, %{cancelling: true}), do: state

  defp maybe_schedule_merge_retry(state, task_id, runtime) do
    bundle = Config.bundle!()

    case Board.task(task_id) do
      {:ok, task} ->
        if merge_column?(task, bundle) and merge_guard(task, bundle) == runtime.guard do
          delay = state.merge_retry_ms
          now = DateTime.utc_now()

          retry = %{
            guard: runtime.guard,
            retry_at_ms: System.monotonic_time(:millisecond) + delay,
            next_retry_at:
              now
              |> DateTime.add(delay, :millisecond)
              |> DateTime.truncate(:microsecond)
              |> DateTime.to_iso8601()
          }

          put_in(state.merge_retry_after[task_id], retry)
        else
          %{state | merge_retry_after: Map.delete(state.merge_retry_after, task_id)}
        end

      {:error, :not_found} ->
        %{state | merge_retry_after: Map.delete(state.merge_retry_after, task_id)}
    end
  end

  defp merge_retry_ready?(task, bundle, state) do
    case state.merge_retry_after[task.id] do
      nil ->
        true

      %{guard: guard, retry_at_ms: retry_at_ms} ->
        guard != merge_guard(task, bundle) or System.monotonic_time(:millisecond) >= retry_at_ms
    end
  end

  defp clear_stale_merge_retry(state, task_id, bundle) do
    case {state.merge_retry_after[task_id], Board.task(task_id)} do
      {nil, _task} ->
        state

      {%{guard: guard}, {:ok, task}} ->
        if merge_column?(task, bundle) and merge_guard(task, bundle) == guard,
          do: state,
          else: %{state | merge_retry_after: Map.delete(state.merge_retry_after, task_id)}

      {_retry, {:error, :not_found}} ->
        %{state | merge_retry_after: Map.delete(state.merge_retry_after, task_id)}
    end
  end

  defp merge_column?(task, bundle) do
    match?(%{role: :merge}, Bundle.column(bundle, task.column_id)) and is_nil(task.active_run_id) and
      is_nil(task.runtime_state)
  end

  defp merge_guard(task, bundle) do
    canonical = %{
      workflow_hash: bundle.hash,
      column_id: task.column_id,
      source: Map.take(task.source, ~w(head_sha base_sha clean)),
      github: Map.take(task.github, ~w(number head_sha state draft)),
      acceptance: ReviewAttestation.criteria_fingerprint(task.acceptance_criteria),
      review_attestation: task.review_attestation
    }

    canonical
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp do_dispatch_candidates(state) do
    bundle = Config.bundle!()
    previous = state

    state =
      state
      |> reconcile_worker_health(bundle)
      |> prune_preflight_failures(bundle)
      |> broadcast_preflight_change(previous)

    slots = max(bundle.agent.max_concurrent_agents - capacity_load(state), 0)
    now = System.monotonic_time(:millisecond)

    candidates =
      Board.tasks()
      |> Enum.filter(
        &(dispatch_eligible?(&1, bundle, state) and preflight_ready?(&1, bundle, state, now) and
            selected_candidate?(&1, state.task_filter))
      )
      |> Enum.sort_by(&{Task.priority_weight(&1.priority), &1.rank, &1.number})

    {state, _remaining_slots} =
      Enum.reduce_while(candidates, {state, slots}, &dispatch_candidate(&1, &2, bundle))

    state
  end

  defp dispatch_candidate(_task, {state, remaining}, _bundle) when remaining <= 0 do
    {:halt, {state, remaining}}
  end

  defp dispatch_candidate(task, {state, remaining}, bundle) do
    case select_worker(state, bundle) do
      {:ok, worker_host} -> dispatch_with_worker(task, worker_host, state, remaining, bundle)
      {:error, reason} -> {:halt, {%{state | dispatch_gate: reason}, remaining}}
    end
  end

  defp dispatch_with_worker(task, worker_host, state, remaining, bundle) do
    result =
      case bundle.dispatch.preflight do
        nil -> claim_and_start(task, worker_host, state, bundle)
        preflight -> start_preflight(task, worker_host, state, bundle, preflight)
      end

    case result do
      {:ok, next} -> {:cont, {next, remaining - 1}}
      {:error, _reason, next} -> {:cont, {next, remaining}}
    end
  end

  defp start_preflight(task, worker_host, state, bundle, config) do
    previous = state
    recipient = self()
    probe_id = make_ref()

    async =
      Elixir.Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
        run_preflight(task, worker_host, bundle, config, recipient, probe_id)
      end)

    now = timestamp()

    preflight = %{
      probe_id: probe_id,
      task_id: task.id,
      identifier: task.identifier,
      task_revision: task.revision,
      workflow_hash: bundle.hash,
      worker_host: worker_host,
      workspace_path: nil,
      phase: :preparing_worktree,
      started_at: now,
      last_activity_at: now,
      retry_after_failure_ms: config.retry_after_failure_ms,
      discard_result: false,
      cancellation_reason: nil,
      pid: async.pid,
      ref: async.ref
    }

    state = %{
      state
      | preflights: Map.put(state.preflights, task.id, preflight),
        preflight_refs: Map.put(state.preflight_refs, async.ref, task.id),
        preflight_failures: Map.delete(state.preflight_failures, task.id)
    }

    Logger.info(
      "preflight started project_id=#{bundle.project.id} task_id=#{task.id} " <>
        "task_identifier=#{task.identifier} task_revision=#{task.revision} workflow_hash=#{bundle.hash} " <>
        "worker_host=#{worker_label(worker_host)}"
    )

    {:ok, broadcast_preflight_change(state, previous)}
  end

  defp run_preflight(task, worker_host, bundle, config, recipient, probe_id) do
    preparation_guard = start_owned_task_guard(recipient, self(), :preflight_owner_down)
    worktree_result = Worktree.ensure(task, worker_host)
    :ok = stop_owned_task_guard(preparation_guard)

    case worktree_result do
      {:ok, workspace_path} ->
        send(recipient, {:preflight_phase, task.id, probe_id, :running, workspace_path})

        case Worktree.run_preflight(
               task,
               workspace_path,
               config.command,
               bundle.hash,
               worker_host,
               owner: recipient,
               cancellation_ref: probe_id
             ) do
          {:ok, output} -> {:ok, workspace_path, output}
          {:error, reason} -> {:error, workspace_path, reason}
        end

      {:error, reason} ->
        {:error, nil, {:worktree_prepare_failed, reason}}
    end
  end

  defp start_owned_task_guard(owner, task, owner_down_reason) do
    spawn(fn ->
      owner_ref = Process.monitor(owner)
      task_ref = Process.monitor(task)

      receive do
        {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
          Worktree.terminate_owned_processes(task)
          Process.exit(task, owner_down_reason)

        {:DOWN, ^task_ref, :process, ^task, _reason} ->
          :ok

        {:stop_owned_task_guard, caller, stop_ref} ->
          Process.demonitor(owner_ref, [:flush])
          Process.demonitor(task_ref, [:flush])
          send(caller, {:owned_task_guard_stopped, stop_ref})
      end
    end)
  end

  defp stop_owned_task_guard(guard) do
    guard_ref = Process.monitor(guard)
    stop_ref = make_ref()
    send(guard, {:stop_owned_task_guard, self(), stop_ref})

    receive do
      {:owned_task_guard_stopped, ^stop_ref} ->
        Process.demonitor(guard_ref, [:flush])
        :ok

      {:DOWN, ^guard_ref, :process, ^guard, _reason} ->
        :ok
    end
  end

  defp claim_and_start(task, worker_host, state, bundle) do
    command = %Commands.ClaimRun{task_id: task.id, worker_host: worker_host}
    key = "claim:#{task.id}:#{task.revision}:#{bundle.hash}"

    case Board.execute(command,
           actor: %{type: :system, identity: "orchestrator"},
           expected_revision: task.revision,
           idempotency_key: key
         ) do
      {:ok, %{"run" => run}} ->
        recipient = self()

        runner = state.agent_runner

        async =
          Elixir.Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
            runner.(task.id, run["id"], recipient)
          end)

        runtime = %{
          pid: async.pid,
          ref: async.ref,
          run_id: run["id"],
          worker_host: worker_host,
          workspace_path: nil,
          session: nil,
          last_activity: nil,
          last_activity_at: nil,
          stopping: false,
          interrupt_timer: nil,
          kill_timer: nil
        }

        state = %{state | running: Map.put(state.running, task.id, runtime), refs: Map.put(state.refs, async.ref, task.id)}
        {:ok, state}

      {:error, reason} ->
        Logger.warning("run claim failed task_id=#{task.id} reason=#{inspect(reason)}")
        {:error, reason, state}
    end
  end

  defp eligible?(task, bundle) do
    column = Bundle.column(bundle, task.column_id)

    not Task.archived?(task) and is_nil(task.runtime_state) and is_nil(task.active_run_id) and
      match?(%{role: :dispatch}, column) and dependencies_done?(task, bundle) and
      rework_draft_complete?(task)
  end

  @doc false
  @spec dispatch_eligible?(Task.t(), Bundle.t(), State.t()) :: boolean()
  def dispatch_eligible?(task, bundle, state) do
    preflight_dispatch_eligible?(task, bundle, state) and
      not Map.has_key?(state.preflights, task.id)
  end

  defp preflight_ready?(_task, %{dispatch: %{preflight: nil}}, _state, _now), do: true

  defp preflight_ready?(task, bundle, state, now) do
    case state.preflight_failures[task.id] do
      nil ->
        true

      %{task_revision: revision, workflow_hash: hash, retry_at_ms: retry_at_ms} ->
        revision != task.revision or hash != bundle.hash or now >= retry_at_ms
    end
  end

  defp prune_preflight_failures(state, bundle) do
    tasks = Map.new(Board.tasks(), &{&1.id, &1})

    failures =
      Map.filter(state.preflight_failures, fn {task_id, failure} ->
        case tasks[task_id] do
          nil ->
            false

          task ->
            failure.task_revision == task.revision and failure.workflow_hash == bundle.hash and
              eligible?(task, bundle)
        end
      end)

    %{state | preflight_failures: failures}
  end

  defp dependencies_done?(task, bundle) do
    done_id = Bundle.done_column(bundle).id

    Enum.all?(task.dependencies, fn id ->
      case Board.task(id) do
        {:ok, %{column_id: ^done_id}} -> true
        _ -> false
      end
    end)
  end

  defp refresh_dispatch_health(state) do
    workflow_status = Store.status()
    writer = safe_writer_state()
    now = System.monotonic_time(:millisecond)

    state = refresh_github_health(state, now)
    {state, dispatch_gate(state, workflow_status, writer)}
  end

  defp refresh_github_health(state, now) do
    stale = is_nil(state.github_health) or now - state.github_health_checked_at >= @github_health_ttl_ms

    if stale,
      do: %{state | github_health: GitHub.health(), github_health_checked_at: now},
      else: state
  end

  defp dispatch_gate(state, workflow_status, writer) do
    with :ok <- dispatch_enabled(state),
         :ok <- workflow_gate(workflow_status),
         :ok <- lease_gate(),
         :ok <- projection_gate(writer),
         :ok <- github_gate(state.github_health),
         :ok <- board_sync_gate() do
      nil
    else
      {:error, gate} -> gate
    end
  end

  defp dispatch_enabled(%{dispatch_enabled: enabled}) do
    enabled = if is_boolean(enabled), do: enabled, else: Application.get_env(:symphony_elixir, :dispatch_enabled, true)

    if enabled,
      do: :ok,
      else: {:error, :dispatch_disabled}
  end

  defp selected_candidate?(_task, nil), do: true
  defp selected_candidate?(task, filter) when is_function(filter, 1), do: filter.(task)

  defp workflow_gate(%{valid: false, error: error}), do: {:error, {:workflow_invalid, error}}
  defp workflow_gate(%{pending: true}), do: {:error, :workflow_activation_pending}

  defp workflow_gate(%{error: error}) when not is_nil(error) do
    {:error, {:workflow_invalid_candidate, error}}
  end

  defp workflow_gate(_status), do: :ok

  defp lease_gate do
    if Lease.owner?(), do: :ok, else: {:error, :project_lease_not_owned}
  end

  defp projection_gate(%{projection_error: error}) when not is_nil(error) do
    {:error, {:projection_error, error}}
  end

  defp projection_gate(%{mutable: false}), do: {:error, :board_not_mutable}
  defp projection_gate(_writer), do: :ok

  defp github_gate(%{available: true}), do: :ok
  defp github_gate(health), do: {:error, {:github_unavailable, health && health[:error]}}

  defp board_sync_gate do
    if Config.bundle!().board.remote do
      remote_board_sync_gate(Sync.status())
    else
      :ok
    end
  end

  defp remote_board_sync_gate(status) do
    case status do
      %{state: :diverged} -> {:error, :board_history_diverged}
      %{state: :behind} -> {:error, :board_history_behind}
      %{configured: false} -> {:error, :board_sync_pending}
      %{state: state} when state in [:unknown, :not_started] -> {:error, :board_sync_pending}
      _ -> :ok
    end
  end

  defp select_worker(_state, %{agent: %{ssh_hosts: []}}), do: {:ok, nil}

  defp select_worker(state, bundle) do
    capacity = bundle.agent.max_concurrent_agents_per_host || bundle.agent.max_concurrent_agents

    bundle.agent.ssh_hosts
    |> Enum.filter(fn host -> worker_healthy?(state, host) and worker_load(state, host) < capacity end)
    |> choose_worker(state)
  end

  defp choose_worker([], _state), do: {:error, :no_eligible_worker}

  defp choose_worker(hosts, state) do
    {:ok, Enum.min_by(hosts, &worker_load(state, &1))}
  end

  defp reconcile_worker_health(state, bundle) do
    previous = state
    configured_hosts = MapSet.new(bundle.agent.ssh_hosts)

    state =
      state.worker_health
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(configured_hosts, &1))
      |> Enum.reduce(state, &cancel_worker_health_probe(&2, &1, :worker_removed))

    now = System.monotonic_time(:millisecond)

    state =
      Enum.reduce(bundle.agent.ssh_hosts, state, fn host, acc ->
        if worker_health_probe_due?(acc.worker_health[host], now),
          do: start_worker_health_probe(acc, host),
          else: acc
      end)

    broadcast_worker_health_change(state, previous)
  end

  defp reconcile_worker_health_if_dispatching(state, bundle) do
    if dispatch_enabled(state) == :ok do
      reconcile_worker_health(state, bundle)
    else
      previous = state
      state |> cancel_all_worker_health() |> broadcast_worker_health_change(previous)
    end
  end

  defp worker_health_probe_due?(nil, _now), do: true
  defp worker_health_probe_due?(%{status: :unhealthy, retry_at_ms: retry_at_ms}, now), do: now >= retry_at_ms
  defp worker_health_probe_due?(%{status: :healthy, refresh_at_ms: refresh_at_ms}, now), do: now >= refresh_at_ms
  defp worker_health_probe_due?(_health, _now), do: false

  defp start_worker_health_probe(state, host) do
    recipient = self()
    probe_id = make_ref()

    async =
      Elixir.Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
        run_worker_health_probe(host, recipient)
      end)

    entry = %{
      host: host,
      status: :probing,
      probe_id: probe_id,
      pid: async.pid,
      ref: async.ref,
      started_at: timestamp(),
      completed_at: nil,
      reason: nil,
      next_retry_at: nil,
      next_probe_at: nil,
      retry_at_ms: nil,
      refresh_at_ms: nil
    }

    Logger.info("worker health probe started worker_host=#{host}")

    %{
      state
      | worker_health: Map.put(state.worker_health, host, entry),
        worker_health_refs: Map.put(state.worker_health_refs, async.ref, {host, probe_id})
    }
  end

  defp run_worker_health_probe(host, owner) do
    guard = start_owned_task_guard(owner, self(), :worker_health_owner_down)
    result = SSH.run(host, "true", stderr_to_stdout: true)
    :ok = stop_owned_task_guard(guard)
    result
  end

  defp finish_worker_health_probe(state, host, probe_id, result) do
    case state.worker_health[host] do
      %{probe_id: ^probe_id, status: :probing} = entry ->
        put_worker_health_result(state, host, entry, result)

      _stale_or_cancelled ->
        state
    end
  end

  defp put_worker_health_result(state, host, entry, {:ok, {_output, 0}}) do
    completed_at = DateTime.utc_now()

    health = %{
      entry
      | status: :healthy,
        pid: nil,
        ref: nil,
        completed_at: format_datetime(completed_at),
        reason: nil,
        next_retry_at: nil,
        next_probe_at: format_datetime(DateTime.add(completed_at, @worker_health_refresh_ms, :millisecond)),
        retry_at_ms: nil,
        refresh_at_ms: System.monotonic_time(:millisecond) + @worker_health_refresh_ms
    }

    Logger.info("worker health probe completed outcome=healthy worker_host=#{host}")
    %{state | worker_health: Map.put(state.worker_health, host, health)}
  end

  defp put_worker_health_result(state, host, entry, result) do
    completed_at = DateTime.utc_now()
    reason = worker_health_failure_reason(result)

    health = %{
      entry
      | status: :unhealthy,
        pid: nil,
        ref: nil,
        completed_at: format_datetime(completed_at),
        reason: reason,
        next_retry_at: format_datetime(DateTime.add(completed_at, @worker_health_retry_ms, :millisecond)),
        next_probe_at: nil,
        retry_at_ms: System.monotonic_time(:millisecond) + @worker_health_retry_ms,
        refresh_at_ms: nil
    }

    Logger.warning(
      "worker health probe completed outcome=unhealthy worker_host=#{host} reason=#{inspect(reason)} " <>
        "next_retry_at=#{health.next_retry_at}"
    )

    %{state | worker_health: Map.put(state.worker_health, host, health)}
  end

  defp worker_health_failure_reason({:ok, {_output, status}}), do: "exit_status_#{status}"
  defp worker_health_failure_reason({:error, reason}), do: inspect(reason)
  defp worker_health_failure_reason(other), do: inspect({:unexpected_worker_health_result, other})

  defp cancel_worker_health_probe(state, host, reason) do
    case Map.pop(state.worker_health, host) do
      {nil, worker_health} ->
        %{state | worker_health: worker_health}

      {health, worker_health} ->
        if health.status == :probing do
          Worktree.terminate_owned_processes(health.pid)
          Process.exit(health.pid, :worker_health_cancelled)
          Process.demonitor(health.ref, [:flush])
        end

        Logger.info("worker health probe cancelled worker_host=#{host} reason=#{reason}")

        %{
          state
          | worker_health: worker_health,
            worker_health_refs: Map.delete(state.worker_health_refs, health.ref)
        }
    end
  end

  defp cancel_all_worker_health(state) do
    Enum.reduce(Map.keys(state.worker_health), state, &cancel_worker_health_probe(&2, &1, :shutdown))
  end

  @doc false
  @spec capacity_load(State.t()) :: non_neg_integer()
  def capacity_load(state) do
    map_size(state.running) + map_size(state.preflights)
  end

  @doc false
  @spec worker_load(State.t(), String.t() | nil) :: non_neg_integer()
  def worker_load(state, host) do
    running = Enum.count(state.running, fn {_id, runtime} -> runtime.worker_host == host end)
    preflights = Enum.count(state.preflights, fn {_id, preflight} -> preflight.worker_host == host end)
    running + preflights
  end

  defp worker_healthy?(state, host), do: match?(%{status: :healthy}, state.worker_health[host])

  defp recover_orphan_runs(state) do
    if state.recover_orphans and dispatch_enabled(state) == :ok do
      known_run_ids = MapSet.new(state.running, fn {_task_id, runtime} -> runtime.run_id end)

      Board.runs()
      |> Enum.filter(&(&1["status"] in ["starting", "running", "stopping"]))
      |> Enum.reject(&MapSet.member?(known_run_ids, &1["id"]))
      |> Enum.each(fn run -> fail_run(run["task_id"], run["id"], :orphaned_after_restart) end)
    end

    state
  end

  defp reconcile_desired_stops(state) do
    Enum.reduce(Map.keys(state.running), state, &maybe_request_stop(&2, &1))
  end

  defp maybe_request_stop(state, task_id) do
    case {state.running[task_id], Board.task(task_id)} do
      {%{stopping: false} = runtime, {:ok, %{desired_column_id: desired}}} when is_binary(desired) ->
        :ok = JobManager.cancel_run(runtime.run_id)
        send(runtime.pid, :stop)
        timer = Process.send_after(self(), {:interrupt_runner, task_id, runtime.run_id}, @graceful_stop_ms)
        put_in(state.running[task_id], %{runtime | stopping: true, interrupt_timer: timer})

      _ ->
        state
    end
  end

  defp finalize_runner_result(_task_id, _run_id, :ok, state), do: state

  defp finalize_runner_result(task_id, run_id, {:error, reason}, state) do
    :ok = JobManager.cancel_run(run_id)

    case Board.task(task_id) do
      {:ok, %{active_run_id: ^run_id, desired_column_id: desired} = task} when is_binary(desired) ->
        finish_stopped_run(task, run_id, reason)

      {:ok, %{active_run_id: ^run_id}} ->
        fail_run(task_id, run_id, reason)

      _ ->
        :ok
    end

    state
  end

  defp finalize_runner_result(task_id, run_id, other, state) do
    finalize_runner_result(task_id, run_id, {:error, {:unexpected_runner_result, other}}, state)
  end

  defp finish_stopped_run(task, run_id, reason) do
    Board.execute(
      %Commands.RunFinished{
        task_id: task.id,
        run_id: run_id,
        outcome: %{reason: inspect(reason)},
        stats: run_stats(run_id)
      },
      actor: %{type: :system, identity: "orchestrator"},
      expected_revision: task.revision,
      idempotency_key: "run-stopped:#{run_id}"
    )
  end

  defp fail_run(task_id, run_id, reason) do
    with {:ok, task} <- Board.task(task_id),
         true <- task.active_run_id == run_id do
      Board.execute(
        %Commands.RunFailed{
          task_id: task_id,
          run_id: run_id,
          reason: reason,
          stats: run_stats(run_id)
        },
        actor: %{type: :system, identity: "orchestrator"},
        expected_revision: task.revision,
        idempotency_key: "run-failed:#{run_id}"
      )
    else
      _ -> :ok
    end
  end

  defp run_stats(run_id), do: RunStats.summary(Projection.run_telemetry(run_id))

  defp reconcile_external_effects(state) do
    tasks = Board.tasks()
    bundle = Config.bundle!()
    previous_publication_errors = state.publication_errors
    state = reconcile_workpad_publications(state, tasks, bundle, &publish_task_workpads/1)

    if state.publication_errors != previous_publication_errors do
      Phoenix.PubSub.broadcast(SymphonyElixir.PubSub, "board:health", :board_health_changed)
    end

    Enum.reduce(tasks, state, fn task, acc ->
      acc
      |> reconcile_rework_draft(task)
      |> maybe_publish_run_stats(task)
      |> maybe_terminal_cleanup(task.id)
    end)
  end

  @doc false
  @spec reconcile_rework_draft(State.t(), Task.t()) :: State.t()
  def reconcile_rework_draft(state, task) do
    drafter = state.rework_drafter || (&convert_rework_to_draft/1)
    outcome_recorder = state.github_outcome_recorder || (&record_github_outcome/3)
    recorder = &outcome_recorder.(&1, "rework_draft", %{completed: true})
    reconcile_rework_draft(state, task, drafter, recorder)
  end

  @doc false
  @spec reconcile_rework_draft(
          State.t(),
          Task.t(),
          (Task.t() -> :ok | {:error, term()}),
          (Task.t() -> {:ok, term()} | {:error, term()})
        ) :: State.t()
  def reconcile_rework_draft(
        state,
        %{column_id: "rework", active_run_id: nil, github: %{"number" => _number}} = task,
        drafter,
        recorder
      )
      when is_function(drafter, 1) and is_function(recorder, 1) do
    unless rework_draft_complete?(task) do
      with :ok <- maybe_convert_rework_to_draft(task, drafter),
           {:ok, _result} <- recorder.(task) do
        :ok
      else
        {:error, reason} -> Logger.warning("rework draft saga pending task_id=#{task.id} reason=#{inspect(reason)}")
      end
    end

    state
  end

  def reconcile_rework_draft(state, _task, _drafter, _recorder), do: state

  defp maybe_convert_rework_to_draft(%{github: %{"draft" => true}}, _drafter), do: :ok
  defp maybe_convert_rework_to_draft(task, drafter), do: drafter.(task)

  defp rework_draft_complete?(%{column_id: "rework", github: %{"number" => _number} = github}) do
    github["draft"] == true and get_in(github, ["rework_draft", "completed"]) == true
  end

  defp rework_draft_complete?(_task), do: true

  defp convert_rework_to_draft(task) do
    {worktree, worker_host} = last_location(task)
    GitHub.convert_to_draft(task, worktree, worker_host: worker_host)
  end

  @doc false
  @spec reconcile_workpad_publications(
          State.t(),
          [Task.t()],
          Bundle.t(),
          (Task.t() -> {:ok, term()} | {:error, term()})
        ) :: State.t()
  def reconcile_workpad_publications(state, tasks, bundle, publisher) when is_function(publisher, 1) do
    current_errors = Map.take(state.publication_errors, Enum.map(tasks, & &1.id))

    publication_errors =
      Enum.reduce(tasks, current_errors, fn task, errors ->
        reconcile_task_publication(task, errors, bundle, publisher)
      end)

    %{state | publication_errors: publication_errors}
  end

  defp reconcile_task_publication(task, errors, bundle, publisher) do
    case Bundle.column(bundle, task.column_id) do
      %{publish_workpad: true} when is_nil(task.active_run_id) ->
        update_publication_error(task, errors, publisher.(task))

      _column ->
        Map.delete(errors, task.id)
    end
  end

  defp update_publication_error(task, errors, {:ok, _publication_id}) do
    Map.delete(errors, task.id)
  end

  defp update_publication_error(task, errors, {:error, reason}) do
    Logger.warning("workpad publication pending task_id=#{task.id} reason=#{inspect(reason)}")
    Map.put(errors, task.id, reason)
  end

  defp publish_task_workpads(task) do
    {worktree, worker_host} = last_location(task)
    GitHub.publish_workpads(task, worktree, worker_host: worker_host)
  end

  defp maybe_publish_run_stats(state, task) do
    task.id
    |> Board.runs()
    |> Enum.filter(fn run ->
      run["status"] in ["completed", "stopped", "failed"] and is_map(run["stats"]) and
        is_nil(run["stats_publication"])
    end)
    |> Enum.each(fn run ->
      case GitHub.publish_run_stats(task, run) do
        {:ok, nil} ->
          :ok

        {:ok, %{destination: destination, publication_id: publication_id} = publication}
        when is_binary(destination) and is_binary(publication_id) ->
          record_run_stats_publication(task, run, publication)

        {:ok, publication} ->
          Logger.warning(
            "run stats publication returned invalid metadata task_id=#{task.id} run_id=#{run["id"]} " <>
              "publication=#{inspect(publication)}"
          )

        {:error, reason} ->
          Logger.warning("run stats publication pending task_id=#{task.id} run_id=#{run["id"]} reason=#{inspect(reason)}")
      end
    end)

    state
  end

  defp record_run_stats_publication(task, run, publication) do
    Board.execute(
      %Commands.RecordRunStatsPublication{
        task_id: task.id,
        run_id: run["id"],
        destination: publication.destination,
        publication_id: publication.publication_id
      },
      actor: %{type: :system, identity: "github"},
      expected_revision: task.revision,
      idempotency_key: "run-stats-published:#{run["id"]}"
    )
    |> case do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "run stats publication record pending task_id=#{task.id} run_id=#{run["id"]} " <>
            "reason=#{inspect(reason)}"
        )
    end
  end

  defp maybe_terminal_cleanup(state, task_id) do
    case Board.task(task_id) do
      {:ok, task} -> maybe_start_terminal_cleanup(state, task, Config.bundle!())
      _ -> state
    end
  end

  defp maybe_start_terminal_cleanup(state, task, bundle) do
    ready =
      Task.terminal?(task, bundle) and is_nil(task.active_run_id) and
        not MapSet.member?(state.cleanup_running, task.id) and
        not MapSet.member?(state.cleanup_completed, task.id)

    if ready, do: start_terminal_cleanup(state, task), else: state
  end

  defp start_terminal_cleanup(state, task) do
    parent = self()

    Elixir.Task.start(fn ->
      result = terminal_effects_and_cleanup(task)
      send(parent, {:terminal_cleanup_result, task.id, result})
    end)

    %{state | cleanup_running: MapSet.put(state.cleanup_running, task.id)}
  end

  defp terminal_effects_and_cleanup(task) do
    {_worktree, worker_host} = last_location(task)

    with :ok <- maybe_close_cancelled_pull_request(task, worker_host) do
      Worktree.remove(task, worker_host)
    end
  end

  defp maybe_close_cancelled_pull_request(%{column_id: "cancelled", github: %{"number" => _number}} = task, worker_host) do
    if get_in(task.github, ["cancelled", "completed"]) == true do
      :ok
    else
      {worktree, _host} = last_location(task)

      with :ok <-
             GitHub.close(
               task,
               worktree,
               task.metadata["cancel_reason"] || "Task cancelled",
               worker_host: worker_host
             ),
           {:ok, _result} <- record_github_outcome(task, "cancelled", %{completed: true}) do
        :ok
      end
    end
  end

  defp maybe_close_cancelled_pull_request(_task, _worker_host), do: :ok

  defp record_github_outcome(task, kind, attrs) do
    Board.execute(
      %Commands.RecordGitHubOutcome{task_id: task.id, kind: kind, attrs: attrs},
      actor: %{type: :system, identity: "github"},
      expected_revision: task.revision,
      idempotency_key: "github:#{kind}:#{task.id}:#{task.revision}"
    )
  end

  defp last_location(task) do
    case Board.runs(task.id) do
      [%{"workspace_path" => path, "worker_host" => worker_host} | _] when is_binary(path) ->
        {path, worker_host}

      [%{"worker_host" => worker_host} | _] ->
        {Worktree.path(task), worker_host}

      _ ->
        {Worktree.path(task), nil}
    end
  end

  defp reconcile_task_preflight(state, task_id) do
    bundle = Config.bundle!()

    case Board.task(task_id) do
      {:ok, task} -> reconcile_task_preflight(state, task, bundle)
      {:error, :not_found} -> state |> cancel_preflight(task_id, :task_missing) |> clear_preflight_failure(task_id)
    end
  end

  defp reconcile_task_preflight(state, task, bundle) do
    state =
      case state.preflights[task.id] do
        nil ->
          state

        %{discard_result: true} ->
          state

        preflight ->
          if active_preflight_current?(task, bundle, preflight, state),
            do: state,
            else: cancel_preflight(state, task.id, :task_semantics_changed)
      end

    case state.preflight_failures[task.id] do
      nil ->
        state

      failure ->
        if failed_preflight_current?(task, bundle, failure, state),
          do: state,
          else: clear_preflight_failure(state, task.id)
    end
  end

  defp active_preflight_current?(task, bundle, preflight, state) do
    current_preflight_snapshot?(task, bundle, preflight, state) and
      active_worker_reservation_current?(preflight.worker_host, bundle, state) and
      capacity_load(state) <= bundle.agent.max_concurrent_agents
  end

  defp failed_preflight_current?(task, bundle, failure, state) do
    current_preflight_snapshot?(task, bundle, failure, state) and
      configured_worker?(failure.worker_host, bundle)
  end

  defp active_worker_reservation_current?(nil, %{agent: %{ssh_hosts: []}}, _state), do: true

  defp active_worker_reservation_current?(host, bundle, state) when is_binary(host) do
    capacity = bundle.agent.max_concurrent_agents_per_host || bundle.agent.max_concurrent_agents
    host in bundle.agent.ssh_hosts and worker_load(state, host) <= capacity
  end

  defp active_worker_reservation_current?(_host, _bundle, _state), do: false

  defp configured_worker?(nil, %{agent: %{ssh_hosts: []}}), do: true
  defp configured_worker?(host, bundle) when is_binary(host), do: host in bundle.agent.ssh_hosts
  defp configured_worker?(_host, _bundle), do: false

  defp clear_preflight_failure(state, task_id) do
    %{state | preflight_failures: Map.delete(state.preflight_failures, task_id)}
  end

  defp cancel_preflight(state, task_id, reason) do
    case Map.pop(state.preflights, task_id) do
      {nil, preflights} ->
        %{state | preflights: preflights}

      {preflight, preflights} ->
        if preflight.phase == :preparing_worktree do
          Worktree.terminate_owned_processes(preflight.pid)
          Process.exit(preflight.pid, :preflight_cancelled)
        else
          send(preflight.pid, {:cancel_preflight, preflight.probe_id})
        end

        Logger.info(
          "preflight cancellation requested reason=#{reason} task_id=#{preflight.task_id} " <>
            "task_identifier=#{preflight.identifier} task_revision=#{preflight.task_revision} " <>
            "workflow_hash=#{preflight.workflow_hash} worker_host=#{worker_label(preflight.worker_host)}"
        )

        cancelling = %{
          preflight
          | phase: :cancelling,
            discard_result: true,
            cancellation_reason: reason,
            last_activity_at: timestamp()
        }

        %{
          state
          | preflights: Map.put(preflights, task_id, cancelling),
            preflight_failures: Map.delete(state.preflight_failures, task_id)
        }
    end
  end

  defp cancel_all_preflights(state) do
    Enum.reduce(Map.keys(state.preflights), state, &cancel_preflight(&2, &1, :workflow_changed))
  end

  defp preflight_status(state) do
    running = Enum.map(state.preflights, fn {_task_id, preflight} -> running_preflight_status(preflight) end)
    failed = Enum.map(state.preflight_failures, fn {_task_id, failure} -> failed_preflight_status(failure) end)

    Enum.sort_by(running ++ failed, &{&1.identifier, &1.task_id})
  end

  defp running_preflight_status(preflight) do
    %{
      task_id: preflight.task_id,
      identifier: preflight.identifier,
      task_revision: preflight.task_revision,
      workflow_hash: preflight.workflow_hash,
      worker_host: preflight.worker_host,
      workspace_path: preflight.workspace_path,
      status: :running,
      phase: preflight.phase,
      started_at: preflight.started_at,
      last_activity_at: preflight.last_activity_at
    }
  end

  defp failed_preflight_status(failure) do
    Map.take(failure, [
      :task_id,
      :identifier,
      :task_revision,
      :workflow_hash,
      :worker_host,
      :status,
      :fingerprint,
      :reason,
      :completed_at,
      :next_retry_at
    ])
  end

  defp worker_health_status(state) do
    state.worker_health
    |> Map.values()
    |> Enum.map(
      &Map.take(&1, [
        :host,
        :status,
        :started_at,
        :completed_at,
        :reason,
        :next_retry_at,
        :next_probe_at
      ])
    )
    |> Enum.sort_by(& &1.host)
  end

  defp broadcast_preflight_change(state, previous) do
    if state.preflights != previous.preflights or state.preflight_failures != previous.preflight_failures do
      Phoenix.PubSub.broadcast(SymphonyElixir.PubSub, "board:health", :board_health_changed)
    end

    state
  end

  defp broadcast_worker_health_change(state, previous) do
    if state.worker_health != previous.worker_health do
      Phoenix.PubSub.broadcast(SymphonyElixir.PubSub, "board:health", :board_health_changed)
    end

    state
  end

  defp worker_label(nil), do: "local"
  defp worker_label(host), do: host

  defp cancel_stop_timers(nil), do: :ok

  defp cancel_stop_timers(runtime) do
    Enum.each([runtime.interrupt_timer, runtime.kill_timer], fn
      reference when is_reference(reference) -> Process.cancel_timer(reference)
      _ -> :ok
    end)
  end

  defp safe_writer_state do
    Writer.state()
  catch
    :exit, _reason -> %{mutable: false, projection_error: :writer_unavailable}
  end

  defp schedule_reconcile(delay), do: Process.send_after(self(), :reconcile, delay)

  defp schedule_telemetry_broadcast(state, run_id) do
    if MapSet.member?(state.telemetry_broadcasts, run_id) do
      state
    else
      Process.send_after(self(), {:broadcast_run_update, run_id}, @telemetry_broadcast_delay_ms)
      %{state | telemetry_broadcasts: MapSet.put(state.telemetry_broadcasts, run_id)}
    end
  end

  defp maybe_put_rate_limits(state, _worker_host, nil, _observed_at), do: state

  defp maybe_put_rate_limits(state, worker_host, limits, observed_at) do
    worker = worker_host || "local"

    entry = %{
      "worker" => worker,
      "observed_at" => observed_at,
      "limits" => limits
    }

    %{state | rate_limits: Map.put(state.rate_limits, worker, entry)}
  end

  defp maybe_put_runtime(runtime, _key, nil), do: runtime
  defp maybe_put_runtime(runtime, key, value), do: Map.put(runtime, key, value)

  defp message_timestamp(message) do
    case Map.get(message, :timestamp) || Map.get(message, "timestamp") do
      %DateTime{} = value -> value |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
      value when is_binary(value) -> value
      _ -> timestamp()
    end
  end

  defp timestamp do
    DateTime.utc_now() |> format_datetime()
  end

  defp format_datetime(datetime), do: datetime |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

  @impl true
  def terminate(reason, state) do
    state = state |> cancel_all_preflights() |> cancel_all_worker_health()
    _state = if shutdown_reason?(reason), do: cancel_all_merges(state, :shutdown), else: state
    :ok
  end

  defp shutdown_reason?(:shutdown), do: true
  defp shutdown_reason?({:shutdown, _reason}), do: true
  defp shutdown_reason?(_reason), do: false
end
