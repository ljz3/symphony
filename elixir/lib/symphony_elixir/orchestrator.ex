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
  alias SymphonyElixir.GitHub
  alias SymphonyElixir.SSH
  alias SymphonyElixir.Task
  alias SymphonyElixir.Workflow.{Bundle, Store}
  alias SymphonyElixir.Worktree

  @reconcile_interval_ms 1_000
  @github_health_ttl_ms 5_000
  @graceful_stop_ms 10_000
  @forced_stop_ms 5_000
  @telemetry_broadcast_delay_ms 250

  defmodule State do
    @moduledoc false
    defstruct started_at: nil,
              running: %{},
              refs: %{},
              cleanup_errors: %{},
              cleanup_running: MapSet.new(),
              cleanup_completed: MapSet.new(),
              rate_limits: %{},
              telemetry_broadcasts: MapSet.new(),
              github_health: nil,
              github_health_checked_at: 0,
              dispatch_gate: nil,
              last_reconciled_at: nil
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
          rate_limits: [],
          dispatch_gate: :not_started,
          cleanup_errors: %{}
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
  def init(_opts) do
    :ok = Board.subscribe(:tasks)
    :ok = Board.subscribe(:workflow)
    :ok = Board.subscribe(:health)
    schedule_reconcile(0)
    {:ok, %State{started_at: timestamp()}}
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
       rate_limits: state.rate_limits |> Map.values() |> Enum.sort_by(& &1["worker"]),
       dispatch_gate: state.dispatch_gate,
       github: state.github_health,
       cleanup_errors: state.cleanup_errors,
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
    state = state |> maybe_request_stop(task_id) |> maybe_terminal_cleanup(task_id)
    send(self(), :reconcile)
    {:noreply, state}
  end

  def handle_info({:workflow_activated, _hash}, state) do
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

  def handle_info({ref, result}, state) when is_reference(ref) do
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

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
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

  def handle_info({:interrupt_runner, task_id, run_id}, state) do
    case state.running[task_id] do
      %{run_id: ^run_id, session: session} = runtime ->
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

  defp dispatch_candidates(state) do
    {state, gate} = refresh_dispatch_health(state)

    case gate do
      nil -> do_dispatch_candidates(%{state | dispatch_gate: nil})
      reason -> %{state | dispatch_gate: reason}
    end
  end

  defp do_dispatch_candidates(state) do
    bundle = Config.bundle!()
    slots = max(bundle.agent.max_concurrent_agents - map_size(state.running), 0)

    candidates =
      Board.tasks()
      |> Enum.filter(&eligible?(&1, bundle))
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
    case claim_and_start(task, worker_host, state, bundle) do
      {:ok, next} -> {:cont, {next, remaining - 1}}
      {:error, _reason, next} -> {:cont, {next, remaining}}
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

        async =
          Elixir.Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn ->
            AgentRunner.run(task.id, run["id"], recipient)
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
      match?(%{role: :dispatch}, column) and dependencies_done?(task, bundle)
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
    with :ok <- dispatch_enabled(),
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

  defp dispatch_enabled do
    if Application.get_env(:symphony_elixir, :dispatch_enabled, true),
      do: :ok,
      else: {:error, :dispatch_disabled}
  end

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
    |> Enum.filter(fn host -> worker_healthy?(host) and worker_load(state, host) < capacity end)
    |> choose_worker(state)
  end

  defp choose_worker([], _state), do: {:error, :no_eligible_worker}

  defp choose_worker(hosts, state) do
    {:ok, Enum.min_by(hosts, &worker_load(state, &1))}
  end

  defp worker_load(state, host) do
    Enum.count(state.running, fn {_id, runtime} -> runtime.worker_host == host end)
  end

  defp worker_healthy?(host) do
    match?({:ok, {_output, 0}}, SSH.run(host, "true", timeout: 5_000, stderr_to_stdout: true))
  end

  defp recover_orphan_runs(state) do
    if Application.get_env(:symphony_elixir, :dispatch_enabled, true) do
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
        send(runtime.pid, :stop)
        timer = Process.send_after(self(), {:interrupt_runner, task_id, runtime.run_id}, @graceful_stop_ms)
        put_in(state.running[task_id], %{runtime | stopping: true, interrupt_timer: timer})

      _ ->
        state
    end
  end

  defp finalize_runner_result(_task_id, _run_id, :ok, state), do: state

  defp finalize_runner_result(task_id, run_id, {:error, reason}, state) do
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
    Enum.reduce(Board.tasks(), state, fn task, acc ->
      acc
      |> maybe_rework_to_draft(task)
      |> maybe_publish_workpads(task)
      |> maybe_publish_run_stats(task)
      |> maybe_terminal_cleanup(task.id)
    end)
  end

  defp maybe_rework_to_draft(state, %{column_id: "rework", github: %{"number" => _number, "draft" => false}} = task) do
    unless get_in(task.github, ["rework_draft", "completed"]) == true do
      {worktree, worker_host} = last_location(task)

      with :ok <- GitHub.convert_to_draft(task, worktree, worker_host: worker_host),
           {:ok, _result} <- record_github_outcome(task, "rework_draft", %{completed: true}) do
        :ok
      else
        {:error, reason} -> Logger.warning("rework draft saga pending task_id=#{task.id} reason=#{inspect(reason)}")
      end
    end

    state
  end

  defp maybe_rework_to_draft(state, _task), do: state

  defp maybe_publish_workpads(state, task) do
    bundle = Config.bundle!()

    case Bundle.column(bundle, task.column_id) do
      %{publish_workpad: true} ->
        {worktree, worker_host} = last_location(task)

        case GitHub.publish_workpads(task, worktree, worker_host: worker_host) do
          {:ok, _publication_id} -> :ok
          {:error, reason} -> Logger.warning("workpad publication pending task_id=#{task.id} reason=#{inspect(reason)}")
        end

      _ ->
        :ok
    end

    state
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
    DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
  end
end
