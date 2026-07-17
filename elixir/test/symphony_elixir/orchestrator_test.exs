defmodule SymphonyElixir.OrchestratorTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Board
  alias SymphonyElixir.Board.Commands
  alias SymphonyElixir.BoardFactory
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Config
  alias SymphonyElixir.DeterministicMerge
  alias SymphonyElixir.DeterministicMerge.Worker, as: MergeWorker
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.Task

  @head String.duplicate("a", 40)
  @target String.duplicate("b", 40)

  test "publication reconciliation skips active workpads and gates only the affected task" do
    bundle = publish_merging_bundle()
    active = task("active", "rework", "active-run")
    failing = task("failing", "rework", nil)
    ready = task("ready", "rework", nil)
    parent = self()

    publisher = fn task ->
      send(parent, {:published, task.id})
      if task.id == failing.id, do: {:error, :github_unavailable}, else: {:ok, "publication"}
    end

    updated =
      Orchestrator.reconcile_workpad_publications(
        struct(State, publication_errors: %{"stale" => :previous_failure}),
        [active, failing, ready],
        bundle,
        publisher
      )

    refute_receive {:published, "active"}
    assert_receive {:published, "failing"}
    assert_receive {:published, "ready"}
    assert updated.publication_errors == %{"failing" => :github_unavailable}

    refute Orchestrator.dispatch_eligible?(failing, bundle, updated)
    assert Orchestrator.dispatch_eligible?(ready, bundle, updated)

    assert {:reply, status, _state} = Orchestrator.handle_call(:status, self(), updated)
    assert status.publication_errors == %{"failing" => :github_unavailable}
  end

  test "preflight reservations consume global and worker capacity and expose only current state" do
    active = %{
      probe_id: make_ref(),
      task_id: "preparing",
      identifier: "SYM-PREFLIGHT",
      task_revision: 7,
      workflow_hash: "workflow-hash",
      worker_host: "builder-a",
      workspace_path: nil,
      phase: :preparing_worktree,
      started_at: "2026-07-16T00:00:00Z",
      last_activity_at: "2026-07-16T00:00:00Z",
      pid: self(),
      ref: make_ref()
    }

    failed = %{
      task_id: "failed",
      identifier: "SYM-FAILED",
      task_revision: 3,
      workflow_hash: "workflow-hash",
      worker_host: "builder-b",
      status: :failed,
      fingerprint: "failure-fingerprint",
      reason: "exit_status_2: configuration unavailable",
      reason_kind: "exit_status_2",
      completed_at: "2026-07-16T00:00:01Z",
      next_retry_at: "2026-07-16T00:00:31Z",
      retry_at_ms: System.monotonic_time(:millisecond) + 30_000
    }

    state =
      struct(State,
        preflights: %{active.task_id => active},
        preflight_refs: %{active.ref => active.task_id},
        preflight_failures: %{failed.task_id => failed}
      )

    assert Orchestrator.capacity_load(state) == 1
    assert Orchestrator.worker_load(state, "builder-a") == 1
    assert Orchestrator.worker_load(state, "builder-b") == 0

    assert {:reply, status, _state} = Orchestrator.handle_call(:status, self(), state)

    assert status.preflights == [
             %{
               identifier: "SYM-FAILED",
               task_id: "failed",
               task_revision: 3,
               workflow_hash: "workflow-hash",
               worker_host: "builder-b",
               status: :failed,
               fingerprint: "failure-fingerprint",
               reason: "exit_status_2: configuration unavailable",
               completed_at: "2026-07-16T00:00:01Z",
               next_retry_at: "2026-07-16T00:00:31Z"
             },
             %{
               identifier: "SYM-PREFLIGHT",
               task_id: "preparing",
               task_revision: 7,
               workflow_hash: "workflow-hash",
               worker_host: "builder-a",
               workspace_path: nil,
               status: :running,
               phase: :preparing_worktree,
               started_at: "2026-07-16T00:00:00Z",
               last_activity_at: "2026-07-16T00:00:00Z"
             }
           ]
  end

  test "rework draft conversion waits for the active run and executes after completion" do
    parent = self()
    active = %{task("rework", "rework", "active-run") | github: %{"number" => 42, "draft" => false}}
    state = struct(State)

    drafter = fn task ->
      send(parent, {:drafted, task.id})
      :ok
    end

    recorder = fn task ->
      send(parent, {:recorded, task.id})
      {:ok, %{}}
    end

    assert ^state = Orchestrator.reconcile_rework_draft(state, active, drafter, recorder)
    refute_receive {:drafted, "rework"}
    refute_receive {:recorded, "rework"}

    completed = %{active | active_run_id: nil, runtime_state: nil}
    assert ^state = Orchestrator.reconcile_rework_draft(state, completed, drafter, recorder)
    assert_receive {:drafted, "rework"}
    assert_receive {:recorded, "rework"}
  end

  test "rework redraft completion is cycle-scoped and repeated reconciliation is idempotent" do
    parent = self()
    state = struct(State)

    completed =
      linked_rework_task("cycle", %{
        "draft" => true,
        "rework_draft" => %{"completed" => true}
      })

    drafter = fn task ->
      send(parent, {:drafted, task.id})
      :ok
    end

    recorder = fn task ->
      send(parent, {:recorded, task.id})
      {:ok, %{}}
    end

    assert ^state = Orchestrator.reconcile_rework_draft(state, completed, drafter, recorder)
    refute_receive {:drafted, "cycle"}
    refute_receive {:recorded, "cycle"}

    ready_again = put_in(completed.github["draft"], false)
    assert ^state = Orchestrator.reconcile_rework_draft(state, ready_again, drafter, recorder)
    assert_receive {:drafted, "cycle"}
    assert_receive {:recorded, "cycle"}
  end

  test "rework dispatch remains task-local gated across drafter and recorder failures" do
    parent = self()
    bundle = Config.bundle!()
    state = struct(State)
    pending = linked_rework_task("pending")
    unrelated = task("unrelated", "todo", nil)

    refute Orchestrator.dispatch_eligible?(pending, bundle, state)
    assert Orchestrator.dispatch_eligible?(unrelated, bundle, state)

    failing_drafter = fn task ->
      send(parent, {:draft_attempted, task.id})
      {:error, :provider_unavailable}
    end

    recorder = fn task ->
      send(parent, {:recorded, task.id})
      {:ok, %{}}
    end

    assert ^state = Orchestrator.reconcile_rework_draft(state, pending, failing_drafter, recorder)
    assert_receive {:draft_attempted, "pending"}
    refute_receive {:recorded, "pending"}
    refute Orchestrator.dispatch_eligible?(pending, bundle, state)

    active = %{pending | active_run_id: "active-run", runtime_state: "running"}
    assert ^state = Orchestrator.reconcile_rework_draft(state, active, failing_drafter, recorder)
    refute_receive {:draft_attempted, "pending"}
  end

  test "recorder failure retries redraft and success enables dispatch" do
    parent = self()
    bundle = Config.bundle!()
    state = struct(State)
    pending = linked_rework_task("retry")
    attempts = :atomics.new(1, [])

    drafter = fn task ->
      send(parent, {:drafted, task.id})
      :ok
    end

    recorder = fn task ->
      attempt = :atomics.add_get(attempts, 1, 1)
      send(parent, {:recorded, task.id, attempt})
      if attempt == 1, do: {:error, :board_busy}, else: {:ok, %{}}
    end

    assert ^state = Orchestrator.reconcile_rework_draft(state, pending, drafter, recorder)
    assert_receive {:drafted, "retry"}
    assert_receive {:recorded, "retry", 1}
    refute Orchestrator.dispatch_eligible?(pending, bundle, state)

    assert ^state = Orchestrator.reconcile_rework_draft(state, pending, drafter, recorder)
    assert_receive {:drafted, "retry"}
    assert_receive {:recorded, "retry", 2}

    completed =
      linked_rework_task("retry", %{
        "draft" => true,
        "rework_draft" => %{"completed" => true}
      })

    assert Orchestrator.dispatch_eligible?(completed, bundle, state)
    assert ^state = Orchestrator.reconcile_rework_draft(state, completed, drafter, recorder)
    refute_receive {:drafted, "retry"}
    refute_receive {:recorded, "retry", 3}
  end

  test "failed rework redraft gates its claim while an unrelated task dispatches" do
    parent = self()
    pending = canonical_rework_task("Failure gate")
    pending_id = pending.id
    runs_before = Board.runs(pending.id)
    {unrelated_backlog, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Unrelated dispatch")})
    {unrelated, _result} = BoardFactory.move(unrelated_backlog, "todo")

    on_exit(fn ->
      cleanup_test_task(pending_id)
      cleanup_test_task(unrelated["id"])
    end)

    state =
      rework_dispatch_state(parent,
        task_filter: &(&1.id in [pending.id, unrelated["id"]]),
        rework_drafter: fn task ->
          if task.id == pending_id, do: send(parent, {:draft_failed, task.id})
          {:error, :provider_unavailable}
        end
      )

    assert {:noreply, _next} = Orchestrator.handle_info(:reconcile, state)
    assert_receive {:draft_failed, task_id}
    assert task_id == pending.id
    assert_receive {:agent_runner_called, unrelated_id, _unrelated_run_id}
    assert unrelated_id == unrelated["id"]
    refute_receive {:agent_runner_called, ^pending_id, _run_id}
    assert Board.runs(pending.id) == runs_before
    assert {:ok, unchanged} = Board.task(pending.id)
    assert is_nil(unchanged.active_run_id)
  end

  test "recorder failure prevents claim and retry records before dispatch" do
    parent = self()
    pending = canonical_rework_task("Recorder retry")
    pending_id = pending.id
    runs_before = Board.runs(pending.id)
    attempts = :atomics.new(1, [])

    on_exit(fn -> cleanup_test_task(pending_id) end)

    recorder = fn task, kind, attrs ->
      if task.id == pending_id do
        attempt = :atomics.add_get(attempts, 1, 1)
        send(parent, {:record_attempt, task.id, attempt})

        if attempt == 1,
          do: {:error, :board_busy},
          else: record_github_outcome(task, kind, attrs)
      else
        {:error, :not_targeted}
      end
    end

    state =
      rework_dispatch_state(parent,
        task_filter: &(&1.id == pending.id),
        rework_drafter: fn task ->
          if task.id == pending_id, do: send(parent, {:drafted_for_dispatch, task.id})
          :ok
        end,
        github_outcome_recorder: recorder
      )

    assert {:noreply, first_state} = Orchestrator.handle_info(:reconcile, state)
    assert_receive {:drafted_for_dispatch, task_id}
    assert task_id == pending.id
    assert_receive {:record_attempt, ^task_id, 1}
    refute_receive {:agent_runner_called, ^task_id, _run_id}
    assert Board.runs(task_id) == runs_before

    assert {:noreply, _second_state} = Orchestrator.handle_info(:reconcile, first_state)
    assert_receive {:drafted_for_dispatch, ^task_id}
    assert_receive {:record_attempt, ^task_id, 2}
    assert_receive {:agent_runner_called, ^task_id, run_id}
    assert length(Board.runs(task_id)) == length(runs_before) + 1

    assert {:ok, claimed} = Board.task(task_id)
    assert claimed.active_run_id == run_id
    assert claimed.github["draft"] == true
    assert get_in(claimed.github, ["rework_draft", "completed"]) == true
  end

  test "successful reconciliation claims the bumped revision in each ready and rework cycle" do
    parent = self()
    first_rework = canonical_rework_task("Two cycles")
    target_id = first_rework.id
    attempts = :atomics.new(1, [])

    on_exit(fn -> cleanup_test_task(target_id) end)

    drafter = fn task ->
      if task.id == target_id do
        attempt = :atomics.add_get(attempts, 1, 1)
        send(parent, {:cycle_drafted, task.id, attempt, task.revision})
        :ok
      else
        {:error, :not_targeted}
      end
    end

    recorder = fn task, kind, attrs ->
      if task.id == target_id do
        send(parent, {:cycle_recorded, task.id, :atomics.get(attempts, 1), task.revision})
        record_github_outcome(task, kind, attrs)
      else
        {:error, :not_targeted}
      end
    end

    state =
      rework_dispatch_state(parent,
        task_filter: &(&1.id == first_rework.id),
        rework_drafter: drafter,
        github_outcome_recorder: recorder
      )

    assert {:noreply, _first_state} = Orchestrator.handle_info(:reconcile, state)
    assert_receive {:cycle_drafted, task_id, 1, first_revision}
    assert task_id == first_rework.id
    assert first_revision == first_rework.revision
    assert_receive {:cycle_recorded, ^task_id, 1, ^first_revision}
    assert_receive {:agent_runner_called, ^task_id, first_run_id}

    assert {:ok, first_claimed} = Board.task(task_id)
    assert first_claimed.revision > first_revision
    assert first_claimed.active_run_id == first_run_id

    second_rework = complete_rework_and_ready_again(first_claimed, first_run_id)
    assert second_rework.github["draft"] == false
    refute Map.has_key?(second_rework.github, "rework_draft")

    second_state =
      rework_dispatch_state(parent,
        task_filter: &(&1.id == task_id),
        rework_drafter: drafter,
        github_outcome_recorder: recorder
      )

    assert {:noreply, _final_state} = Orchestrator.handle_info(:reconcile, second_state)
    assert_receive {:cycle_drafted, ^task_id, 2, second_revision}
    assert second_revision == second_rework.revision
    assert_receive {:cycle_recorded, ^task_id, 2, ^second_revision}
    assert_receive {:agent_runner_called, ^task_id, second_run_id}
    refute second_run_id == first_run_id

    assert {:ok, second_claimed} = Board.task(task_id)
    assert second_claimed.revision > second_revision
    assert second_claimed.active_run_id == second_run_id
  end

  test "merge-role work uses only the system runner and verified conflict dispatches one agent" do
    task = canonical_merge_task()
    selected_task_id = task.id
    runs_before_merge = Board.runs(selected_task_id)
    parent = self()

    merge_runner = fn merge_task, _bundle, _opts ->
      send(parent, {:merge_runner_called, merge_task.id, self()})

      receive do
        :release_merge_runner -> {:ok, :pending}
      end
    end

    agent_runner = fn task_id, run_id, _recipient ->
      send(parent, {:agent_runner_called, task_id, run_id})
      :ok
    end

    disabled_state =
      struct(State,
        dispatch_enabled: false,
        recover_orphans: false,
        task_filter: &(&1.id == selected_task_id),
        merge_runner: merge_runner,
        agent_runner: agent_runner,
        github_health: %{available: true, authenticated: true, error: nil},
        github_health_checked_at: System.monotonic_time(:millisecond)
      )

    assert {:noreply, disabled_state} = Orchestrator.handle_info(:reconcile, disabled_state)
    refute_receive {:merge_runner_called, ^selected_task_id, _pid}, 100

    state = %{disabled_state | dispatch_enabled: true}
    assert {:noreply, merging_state} = Orchestrator.handle_info(:reconcile, state)
    assert_receive {:merge_runner_called, ^selected_task_id, merge_pid}
    refute_receive {:agent_runner_called, ^selected_task_id, _run_id}, 100
    assert Board.runs(selected_task_id) == runs_before_merge

    refute Enum.any?(runs_before_merge, fn run ->
             run["start_column_id"] == "merging" or run["stage_id"] == "merging"
           end)

    paths = ["Sources/Conflict.swift"]
    conflict_id = DeterministicMerge.conflict_id(selected_task_id, @head, @target, paths)

    assert {:ok, %{"task" => conflicted}} =
             Board.execute(
               %Commands.RecordMergeConflict{
                 task_id: selected_task_id,
                 task_head: @head,
                 target_head: @target,
                 conflicted_paths: paths,
                 conflict_id: conflict_id
               },
               actor: :system,
               expected_revision: task.revision,
               idempotency_key: BoardFactory.unique("orchestrator-conflict")
             )

    assert conflicted["column_id"] == "merge_conflict"
    %{ref: merge_ref} = Map.fetch!(merging_state.merging, selected_task_id)
    send(merge_pid, :release_merge_runner)
    assert_receive {:DOWN, ^merge_ref, :process, ^merge_pid, :normal}

    assert {:noreply, post_merge_state} =
             Orchestrator.handle_info({:DOWN, merge_ref, :process, merge_pid, :normal}, merging_state)

    assert {:noreply, conflict_state} = Orchestrator.handle_info(:reconcile, post_merge_state)
    assert_receive {:agent_runner_called, ^selected_task_id, conflict_run_id}
    refute_receive {:agent_runner_called, ^selected_task_id, _run_id}, 100
    assert map_size(conflict_state.merging) == 0
    assert Map.fetch!(conflict_state.running, selected_task_id).run_id == conflict_run_id

    on_exit(fn -> cleanup_active_run(selected_task_id, conflict_run_id) end)
  end

  @tag timeout: 20_000
  test "merge invalidation kills readiness trees and frees the sole slot for the next task" do
    first = canonical_merge_task()
    second = canonical_merge_task()
    parent = self()
    readiness_root = Path.join(System.tmp_dir!(), BoardFactory.unique("merge-readiness-owner"))
    File.mkdir_p!(readiness_root)
    parent_path = Path.join(readiness_root, "parent.pid")
    child_path = Path.join(readiness_root, "child.pid")

    readiness_command = """
    trap '' TERM
    (trap '' TERM; while :; do sleep 1; done) &
    child=$!
    printf %s $$ > #{shell_escape(parent_path)}
    printf %s "$child" > #{shell_escape(child_path)}
    wait "$child"
    """

    merge_runner = fn merge_task, _bundle, _opts ->
      if merge_task.id == first.id do
        DeterministicMerge.SystemBoundary.call(:readiness, merge_task, %{
          worktree: readiness_root,
          worker_host: nil,
          readiness_command: readiness_command
        })
      else
        send(parent, {:next_merge_started, merge_task.id})
        {:ok, :pending}
      end
    end

    state =
      struct(State,
        dispatch_enabled: true,
        recover_orphans: false,
        task_filter: &(&1.id in [first.id, second.id]),
        merge_runner: merge_runner,
        github_health: %{available: true, authenticated: true, error: nil},
        github_health_checked_at: System.monotonic_time(:millisecond)
      )

    assert {:noreply, merging_state} = Orchestrator.handle_info(:reconcile, state)
    eventually(fn -> File.exists?(parent_path) and File.exists?(child_path) end)
    parent_pid = parent_path |> File.read!() |> String.trim() |> String.to_integer()
    child_pid = child_path |> File.read!() |> String.trim() |> String.to_integer()
    %{pid: merge_pid, ref: merge_ref} = Map.fetch!(merging_state.merging, first.id)

    on_exit(fn ->
      if Process.alive?(merge_pid), do: Process.exit(merge_pid, :kill)
      kill_process(parent_pid)
      kill_process(child_pid)
    end)

    assert {:ok, %{"task" => invalidated}} =
             Board.execute(
               %Commands.InvalidateReviewAttestation{
                 task_id: first.id,
                 reason: "source changed during readiness",
                 head_sha: @target
               },
               actor: :system,
               expected_revision: first.revision,
               idempotency_key: BoardFactory.unique("cancel-merge-readiness")
             )

    assert invalidated["column_id"] == "automated_review"

    assert {:noreply, cancelling_state} =
             Orchestrator.handle_info({:task_changed, first.id}, merging_state)

    assert_receive {:DOWN, ^merge_ref, :process, ^merge_pid, _reason}, 8_000

    assert {:noreply, released_state} =
             Orchestrator.handle_info(
               {:DOWN, merge_ref, :process, merge_pid, :shutdown},
               cancelling_state
             )

    refute process_alive?(parent_pid)
    refute process_alive?(child_pid)
    assert map_size(released_state.merging) == 0

    assert {:noreply, _next_state} = Orchestrator.handle_info(:reconcile, released_state)
    assert_receive {:next_merge_started, second_id}, 2_000
    assert second_id == second.id
  end

  @tag timeout: 20_000
  test "a restarted Orchestrator cancels an inherited readiness tree after the task leaves merge" do
    assert :none = MergeWorker.active()
    task = canonical_merge_task()
    readiness = start_inherited_readiness(task, Config.bundle!(), "task-moved")
    readiness_ref = readiness.ref
    readiness_pid = readiness.pid

    on_exit(fn -> cleanup_inherited_readiness(readiness) end)

    assert {:ok, %{"task" => moved}} =
             Board.execute(
               %Commands.InvalidateReviewAttestation{
                 task_id: task.id,
                 reason: "task moved while orchestrator was down",
                 head_sha: @target
               },
               actor: :system,
               expected_revision: task.revision,
               idempotency_key: BoardFactory.unique("inherited-task-moved")
             )

    assert moved["column_id"] == "automated_review"
    assert MergeWorker.semantic_guard(Task.from_map(moved), Config.bundle!()) != readiness.guard
    assert {:noreply, state} = Orchestrator.handle_info(:reconcile, inherited_merge_state(task.id))
    assert state.merging[task.id].cancelling
    assert_receive {:DOWN, ^readiness_ref, :process, ^readiness_pid, _reason}, 4_000
    refute process_alive?(readiness.parent_pid)
    refute process_alive?(readiness.child_pid)
  end

  @tag timeout: 20_000
  test "a restarted Orchestrator cancels an inherited worker from another workflow hash" do
    assert :none = MergeWorker.active()
    task = canonical_merge_task()
    stale_bundle = %{Config.bundle!() | hash: "stale-workflow-hash"}
    readiness = start_inherited_readiness(task, stale_bundle, "workflow-changed")
    readiness_ref = readiness.ref
    readiness_pid = readiness.pid

    on_exit(fn -> cleanup_inherited_readiness(readiness) end)

    assert MergeWorker.semantic_guard(task, Config.bundle!()) != readiness.guard
    assert {:noreply, state} = Orchestrator.handle_info(:reconcile, inherited_merge_state(task.id))
    assert state.merging[task.id].cancelling
    assert_receive {:DOWN, ^readiness_ref, :process, ^readiness_pid, _reason}, 4_000
    refute process_alive?(readiness.parent_pid)
    refute process_alive?(readiness.child_pid)
  end

  @tag timeout: 20_000
  test "a restarted Orchestrator retains an inherited worker across saga-only checkpoints" do
    assert :none = MergeWorker.active()
    task = canonical_merge_task()
    readiness = start_inherited_readiness(task, Config.bundle!(), "saga-checkpoint")
    readiness_ref = readiness.ref
    readiness_pid = readiness.pid

    on_exit(fn -> cleanup_inherited_readiness(readiness) end)

    assert {:ok, %{"task" => checkpointed}} =
             Board.execute(
               %Commands.RecordMergeCheckpoint{
                 task_id: task.id,
                 checkpoint: "clean_update_started",
                 attrs: %{"task_head" => @head, "target_head" => @target}
               },
               actor: :system,
               expected_revision: task.revision,
               idempotency_key: BoardFactory.unique("inherited-saga-checkpoint")
             )

    assert checkpointed["merge_saga"]["checkpoint"] == "clean_update_started"
    assert MergeWorker.semantic_guard(Task.from_map(checkpointed), Config.bundle!()) == readiness.guard
    assert {:noreply, state} = Orchestrator.handle_info(:reconcile, inherited_merge_state(task.id))
    refute state.merging[task.id].cancelling
    assert state.merging[task.id].pid == readiness.pid
    refute_receive {:DOWN, ^readiness_ref, :process, ^readiness_pid, _reason}, 200
    assert Process.alive?(readiness.pid)
  end

  test "pending merge outcomes obey a per-task retry cadence" do
    task = canonical_merge_task()
    parent = self()
    attempts = :atomics.new(1, [])
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, 10_000)

    merge_runner = fn merge_task, _bundle, _opts ->
      attempt = :atomics.add_get(attempts, 1, 1)
      send(parent, {:merge_retry_attempt, attempt, merge_task.id, self()})
      {:ok, :pending}
    end

    state =
      struct(State,
        dispatch_enabled: true,
        recover_orphans: false,
        task_filter: &(&1.id == task.id),
        merge_runner: merge_runner,
        github_health: %{available: true, authenticated: true, error: nil},
        github_health_checked_at: System.monotonic_time(:millisecond),
        monotonic_clock: fn :millisecond -> :atomics.get(clock, 1) end
      )
      |> Map.put(:merge_retry_ms, 250)
      |> Map.put(:merge_retry_after, %{})

    assert {:noreply, first_state} = Orchestrator.handle_info(:reconcile, state)
    assert_receive {:merge_retry_attempt, 1, task_id, first_pid}, 2_000
    assert task_id == task.id
    %{ref: first_ref} = Map.fetch!(first_state.merging, task.id)
    assert_receive {:DOWN, ^first_ref, :process, ^first_pid, first_reason}, 2_000

    assert {:noreply, waiting_state} =
             Orchestrator.handle_info(
               {:DOWN, first_ref, :process, first_pid, first_reason},
               first_state
             )

    waiting_state =
      Enum.reduce(1..5, waiting_state, fn _iteration, current ->
        assert {:noreply, next} = Orchestrator.handle_info(:reconcile, current)
        next
      end)

    refute_receive {:merge_retry_attempt, 2, ^task_id, _pid}
    assert :atomics.get(attempts, 1) == 1

    :atomics.put(clock, 1, 10_250)
    assert {:noreply, _retried_state} = Orchestrator.handle_info(:reconcile, waiting_state)
    assert_receive {:merge_retry_attempt, 2, ^task_id, _pid}, 2_000
  end

  test "immediate reconciliation triggers do not create periodic timer chains" do
    parent = self()

    scheduler = fn recipient, delay ->
      send(parent, {:periodic_reconcile_scheduled, recipient, delay})
      make_ref()
    end

    assert {:ok, state} =
             Orchestrator.init(
               dispatch_enabled: false,
               recover_orphans: false,
               task_filter: fn _task -> false end,
               reconcile_scheduler: scheduler
             )

    assert_receive {:periodic_reconcile_scheduled, recipient, 0}
    assert recipient == self()

    state = %{
      state
      | github_health: %{available: true, authenticated: true, error: nil},
        github_health_checked_at: System.monotonic_time(:millisecond)
    }

    assert {:noreply, state} = Orchestrator.handle_info(:scheduled_reconcile, state)
    assert_receive {:periodic_reconcile_scheduled, recipient, 1_000}
    assert recipient == self()
    refute_receive {:periodic_reconcile_scheduled, _recipient, _delay}

    state =
      Enum.reduce(1..3, state, fn _iteration, current ->
        assert :ok = Orchestrator.refresh(self())
        assert_receive :reconcile
        assert {:noreply, next} = Orchestrator.handle_info(:reconcile, current)
        next
      end)

    state =
      Enum.reduce(1..3, state, fn iteration, current ->
        assert {:noreply, next} =
                 Orchestrator.handle_info({:task_changed, "missing-reconcile-task-#{iteration}"}, current)

        assert_receive :reconcile
        assert {:noreply, reconciled} = Orchestrator.handle_info(:reconcile, next)
        reconciled
      end)

    state =
      Enum.reduce(1..3, state, fn iteration, current ->
        assert {:noreply, next} =
                 Orchestrator.handle_info({:workflow_activated, "new-workflow-hash-#{iteration}"}, current)

        assert_receive :reconcile
        assert {:noreply, reconciled} = Orchestrator.handle_info(:reconcile, next)
        reconciled
      end)

    assert %State{} = state
    refute_receive {:periodic_reconcile_scheduled, _recipient, _delay}
  end

  test "merge worker identity survives an Orchestrator-only restart and prevents duplicate effects" do
    assert :none = MergeWorker.active()

    task = canonical_merge_task()
    selected_task_id = task.id
    parent = self()
    invocations = :atomics.new(1, [])
    name = SymphonyElixir.OrchestratorRestartTest

    merge_runner = fn merge_task, _bundle, _opts ->
      invocation = :atomics.add_get(invocations, 1, 1)
      send(parent, {:merge_effect_invoked, invocation, merge_task.id, self()})

      receive do
        {:release_merge_effect, ^invocation} -> :ok
      end

      if invocation == 1 do
        {:ok, current} = Board.task(merge_task.id)

        result =
          Board.execute(
            %Commands.RecordMergeCheckpoint{
              task_id: merge_task.id,
              checkpoint: "clean_update_started",
              attrs: %{"task_head" => @head, "target_head" => @target}
            },
            actor: :system,
            expected_revision: current.revision,
            idempotency_key: BoardFactory.unique("orchestrator-restart-checkpoint")
          )

        send(parent, {:merge_checkpoint_result, result})
      end

      {:ok, :pending}
    end

    opts = [
      name: name,
      dispatch_enabled: false,
      recover_orphans: false,
      task_filter: &(&1.id == selected_task_id),
      merge_runner: merge_runner
    ]

    on_exit(fn ->
      case Process.whereis(name) do
        pid when is_pid(pid) -> safe_stop(pid)
        nil -> :ok
      end

      case MergeWorker.active() do
        {:ok, _task_id, pid, _guard} ->
          ref = Process.monitor(pid)
          send(pid, {:release_merge_effect, 1})
          send(pid, {:release_merge_effect, 2})
          await_merge_worker_exit(pid, ref)

        :none ->
          :ok
      end
    end)

    {:ok, first_orchestrator} = Orchestrator.start_link(opts)
    enable_dispatch(first_orchestrator)

    worker =
      receive do
        {:merge_effect_invoked, 1, ^selected_task_id, pid} ->
          pid
      after
        2_000 ->
          state = :sys.get_state(first_orchestrator)

          flunk(
            "merge worker did not start: gate=#{inspect(state.dispatch_gate)} " <>
              "active=#{inspect(MergeWorker.active())} task=#{inspect(Board.task(selected_task_id))}"
          )
      end

    assert {:ok, ^selected_task_id, ^worker, original_guard} = MergeWorker.active()

    send(first_orchestrator, :reconcile)
    send(first_orchestrator, :reconcile)
    refute_receive {:merge_effect_invoked, 2, ^selected_task_id, _pid}, 200
    assert :atomics.get(invocations, 1) == 1

    GenServer.stop(first_orchestrator, :normal)
    assert Process.alive?(worker)
    assert {:ok, ^selected_task_id, ^worker, ^original_guard} = MergeWorker.active()

    {:ok, restarted_orchestrator} = Orchestrator.start_link(opts)
    enable_dispatch(restarted_orchestrator)
    send(restarted_orchestrator, :reconcile)
    send(restarted_orchestrator, :reconcile)

    eventually(fn ->
      match?(
        %{pid: ^worker, guard: ^original_guard, cancelling: false},
        :sys.get_state(restarted_orchestrator).merging[selected_task_id]
      )
    end)

    refute_receive {:merge_effect_invoked, 2, ^selected_task_id, _pid}, 200
    assert :atomics.get(invocations, 1) == 1

    disable_dispatch(restarted_orchestrator)
    send(worker, {:release_merge_effect, 1})

    assert_receive {:merge_checkpoint_result, {:ok, %{"task" => checkpointed}}}, 2_000
    assert checkpointed["merge_saga"]["checkpoint"] == "clean_update_started"

    eventually(fn -> MergeWorker.active() == :none end)
    eventually(fn -> :sys.get_state(restarted_orchestrator).merging == %{} end)

    enable_dispatch(restarted_orchestrator)
    assert_receive {:merge_effect_invoked, 2, ^selected_task_id, retry_worker}, 2_000
    assert {:ok, ^selected_task_id, ^retry_worker, _retry_guard} = MergeWorker.active()
    assert retry_worker != worker

    disable_dispatch(restarted_orchestrator)
    send(retry_worker, {:release_merge_effect, 2})
    eventually(fn -> MergeWorker.active() == :none end)
    assert :atomics.get(invocations, 1) == 2
    safe_stop(restarted_orchestrator)
  end

  defp start_inherited_readiness(task, bundle, label) do
    root = Path.join(System.tmp_dir!(), BoardFactory.unique("inherited-readiness-#{label}"))
    File.mkdir_p!(root)
    parent_path = Path.join(root, "parent.pid")
    child_path = Path.join(root, "child.pid")

    command = """
    trap '' TERM
    (trap '' TERM; while :; do sleep 1; done) &
    child=$!
    printf %s $$ > #{shell_escape(parent_path)}
    printf %s "$child" > #{shell_escape(child_path)}
    wait "$child"
    """

    runner = fn merge_task, _bundle, _opts ->
      DeterministicMerge.SystemBoundary.call(:readiness, merge_task, %{
        worktree: root,
        worker_host: nil,
        readiness_command: command
      })
    end

    assert {:ok, task_id, pid, guard} = MergeWorker.ensure_started(task, bundle, runner)
    assert task_id == task.id
    ref = Process.monitor(pid)
    eventually(fn -> File.exists?(parent_path) and File.exists?(child_path) end)

    %{
      task_id: task.id,
      pid: pid,
      ref: ref,
      guard: guard,
      parent_pid: parent_path |> File.read!() |> String.trim() |> String.to_integer(),
      child_pid: child_path |> File.read!() |> String.trim() |> String.to_integer()
    }
  end

  defp inherited_merge_state(task_id) do
    struct(State,
      dispatch_enabled: true,
      recover_orphans: false,
      task_filter: &(&1.id == task_id),
      github_health: %{available: true, authenticated: true, error: nil},
      github_health_checked_at: System.monotonic_time(:millisecond)
    )
  end

  defp cleanup_inherited_readiness(readiness) do
    if Process.alive?(readiness.pid) do
      MergeWorker.cancel(readiness.pid, readiness.task_id)
      eventually(fn -> not Process.alive?(readiness.pid) end)
    end

    kill_process(readiness.parent_pid)
    kill_process(readiness.child_pid)
  end

  defp publish_merging_bundle do
    bundle = Config.bundle!()

    columns =
      Enum.map(bundle.columns, fn
        %{id: "rework"} = column -> %{column | publish_workpad: true}
        column -> column
      end)

    %{bundle | columns: columns}
  end

  defp task(id, column_id, active_run_id) do
    %Task{
      id: id,
      identifier: "SYM-#{id}",
      number: System.unique_integer([:positive]),
      project_id: "symphony",
      title: id,
      type: :feature,
      branch: "feature/#{id}",
      priority: :normal,
      brief: "brief",
      acceptance_criteria: [],
      column_id: column_id,
      rank: 1_024,
      revision: 1,
      active_run_id: active_run_id,
      runtime_state: if(active_run_id, do: "running"),
      created_at: "now",
      updated_at: "now"
    }
  end

  defp linked_rework_task(id, github \\ %{"draft" => false}) do
    %{task(id, "rework", nil) | github: Map.put(github, "number", 42)}
  end

  defp canonical_rework_task(label) do
    {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique(label)})
    {todo, _result} = BoardFactory.move(created, "todo")

    assert {:ok, %{"task" => implementation, "run" => implementation_run}} =
             Board.execute(%Commands.ClaimRun{task_id: todo["id"]},
               actor: :system,
               expected_revision: todo["revision"],
               idempotency_key: BoardFactory.unique("rework-implementation-claim")
             )

    criterion_id = implementation["acceptance_criteria"] |> hd() |> Map.fetch!("id")

    assert {:ok, %{"task" => evidenced}} =
             Board.execute(
               %Commands.CompleteAcceptance{
                 task_id: implementation["id"],
                 criterion_id: criterion_id,
                 evidence: [%{"command" => "mix test", "result" => "passed"}]
               },
               actor: %{type: :agent, identity: implementation_run["id"]},
               expected_revision: implementation["revision"],
               idempotency_key: BoardFactory.unique("rework-acceptance")
             )

    assert {:ok, %{"task" => sourced}} =
             Board.execute(%Commands.RecordSourceHead{task_id: evidenced["id"], head_sha: @head, clean: true},
               actor: %{type: :agent, identity: implementation_run["id"]},
               expected_revision: evidenced["revision"],
               idempotency_key: BoardFactory.unique("rework-source")
             )

    assert {:ok, %{"task" => linked}} =
             Board.execute(
               %Commands.LinkPullRequest{
                 task_id: sourced["id"],
                 run_id: implementation_run["id"],
                 number: 42,
                 url: "https://github.test/pull/42",
                 head_sha: @head,
                 state: "open",
                 draft: false
               },
               actor: :system,
               expected_revision: sourced["revision"],
               idempotency_key: BoardFactory.unique("rework-pull-request")
             )

    assert {:ok, %{"task" => review_ready}} =
             Board.execute(%Commands.MoveTask{task_id: linked["id"], column_id: "automated_review"},
               actor: %{type: :agent, identity: implementation_run["id"]},
               expected_revision: linked["revision"],
               idempotency_key: BoardFactory.unique("rework-to-review")
             )

    implementation_finished = finish_run_with_publication(review_ready, implementation_run, "pr_body")

    assert {:ok, %{"task" => review, "run" => review_run}} =
             Board.execute(%Commands.ClaimRun{task_id: implementation_finished["id"]},
               actor: :system,
               expected_revision: implementation_finished["revision"],
               idempotency_key: BoardFactory.unique("rework-review-claim")
             )

    human_review = record_ready_and_move_to_human(review, review_run)
    {rework, _result} = BoardFactory.move(human_review, "rework")
    Task.from_map(rework)
  end

  defp complete_rework_and_ready_again(task, rework_run_id) do
    assert {:ok, %{"task" => automated_review}} =
             Board.execute(%Commands.MoveTask{task_id: task.id, column_id: "automated_review"},
               actor: %{type: :agent, identity: rework_run_id},
               expected_revision: task.revision,
               idempotency_key: BoardFactory.unique("second-cycle-to-review")
             )

    rework_finished = finish_run_with_publication(automated_review, %{"id" => rework_run_id}, "workpad_comment")

    assert {:ok, %{"task" => review, "run" => review_run}} =
             Board.execute(%Commands.ClaimRun{task_id: rework_finished["id"]},
               actor: :system,
               expected_revision: rework_finished["revision"],
               idempotency_key: BoardFactory.unique("second-cycle-review-claim")
             )

    human_review = record_ready_and_move_to_human(review, review_run)
    {rework, _result} = BoardFactory.move(human_review, "rework")
    Task.from_map(rework)
  end

  defp record_ready_and_move_to_human(task, run) do
    assert {:ok, %{"task" => ready}} =
             Board.execute(
               %Commands.RecordGitHubOutcome{task_id: task["id"], kind: "ready", attrs: %{completed: true}},
               actor: %{type: :agent, identity: run["id"]},
               expected_revision: task["revision"],
               idempotency_key: BoardFactory.unique("cycle-ready")
             )

    assert {:ok, %{"task" => human_review}} =
             Board.execute(%Commands.MoveTask{task_id: ready["id"], column_id: "human_review"},
               actor: %{type: :agent, identity: run["id"]},
               expected_revision: ready["revision"],
               idempotency_key: BoardFactory.unique("cycle-human-review")
             )

    finish_run_with_publication(human_review, run, "workpad_comment")
  end

  defp rework_dispatch_state(parent, overrides) do
    defaults = [
      dispatch_enabled: true,
      recover_orphans: false,
      agent_runner: fn task_id, run_id, _recipient ->
        send(parent, {:agent_runner_called, task_id, run_id})
        :ok
      end,
      rework_drafter: fn task ->
        send(parent, {:drafted_for_dispatch, task.id})
        :ok
      end,
      github_outcome_recorder: &record_github_outcome/3,
      github_health: %{available: true, authenticated: true, error: nil},
      github_health_checked_at: System.monotonic_time(:millisecond)
    ]

    struct(State, Keyword.merge(defaults, overrides))
  end

  defp record_github_outcome(task, kind, attrs) do
    Board.execute(
      %Commands.RecordGitHubOutcome{task_id: task.id, kind: kind, attrs: attrs},
      actor: %{type: :system, identity: "test-github"},
      expected_revision: task.revision,
      idempotency_key: BoardFactory.unique("rework-outcome")
    )
  end

  defp canonical_merge_task do
    {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("System merge dispatch")})
    {todo, _result} = BoardFactory.move(created, "todo")

    assert {:ok, %{"task" => implementation, "run" => implementation_run}} =
             Board.execute(%Commands.ClaimRun{task_id: todo["id"]},
               actor: :system,
               expected_revision: todo["revision"],
               idempotency_key: BoardFactory.unique("orchestrator-implementation-claim")
             )

    criterion_id = implementation["acceptance_criteria"] |> hd() |> Map.fetch!("id")

    assert {:ok, %{"task" => evidenced}} =
             Board.execute(
               %Commands.CompleteAcceptance{
                 task_id: implementation["id"],
                 criterion_id: criterion_id,
                 evidence: [%{"command" => "mix test", "result" => "passed"}]
               },
               actor: %{type: :agent, identity: implementation_run["id"]},
               expected_revision: implementation["revision"],
               idempotency_key: BoardFactory.unique("orchestrator-acceptance")
             )

    assert {:ok, %{"task" => sourced}} =
             Board.execute(%Commands.RecordSourceHead{task_id: evidenced["id"], head_sha: @head, clean: true},
               actor: %{type: :agent, identity: implementation_run["id"]},
               expected_revision: evidenced["revision"],
               idempotency_key: BoardFactory.unique("orchestrator-source")
             )

    assert {:ok, %{"task" => linked}} =
             Board.execute(
               %Commands.LinkPullRequest{
                 task_id: sourced["id"],
                 run_id: implementation_run["id"],
                 number: 1,
                 url: "https://github.test/pull/1",
                 head_sha: @head,
                 state: "open",
                 draft: false
               },
               actor: :system,
               expected_revision: sourced["revision"],
               idempotency_key: BoardFactory.unique("orchestrator-pull-request")
             )

    assert {:ok, %{"task" => review_ready}} =
             Board.execute(%Commands.MoveTask{task_id: linked["id"], column_id: "automated_review"},
               actor: %{type: :agent, identity: implementation_run["id"]},
               expected_revision: linked["revision"],
               idempotency_key: BoardFactory.unique("orchestrator-to-review")
             )

    implementation_finished = finish_run(review_ready, implementation_run)

    assert {:ok, %{"task" => review_task, "run" => review_run}} =
             Board.execute(%Commands.ClaimRun{task_id: implementation_finished["id"]},
               actor: :system,
               expected_revision: implementation_finished["revision"],
               idempotency_key: BoardFactory.unique("orchestrator-review-claim")
             )

    arguments = %{
      "expected_revision" => review_task["revision"],
      "verdict" => "pass",
      "reviewed_head_sha" => @head,
      "route" => "merging",
      "plan_policy" => %{"status" => "followed", "summary" => "Repository plan policy followed."},
      "validation_evidence" => [%{"command" => "mix test", "result" => "passed", "exit_status" => 0}],
      "findings" => []
    }

    snapshotter = fn _task, _worktree, _opts ->
      {:ok,
       %{
         number: 1,
         state: "OPEN",
         draft: false,
         head_sha: @head,
         source_head_sha: @head,
         approved: true,
         required_checks_green: true,
         unresolved_review_threads: 0,
         feedback_fingerprint: "feedback-v1",
         checks_fingerprint: "checks-v1"
       }}
    end

    assert %{"success" => true} =
             DynamicTool.execute("symphony_review_complete", arguments,
               task_id: review_task["id"],
               run_id: review_run["id"],
               call_id: BoardFactory.unique("orchestrator-review-complete"),
               review_snapshotter: snapshotter
             )

    {:ok, attested} = Board.task(review_task["id"])
    finish_run(attested, review_run)
    {:ok, task} = Board.task(review_task["id"])
    task
  end

  defp finish_run(task, run) do
    task_id = if is_struct(task, Task), do: task.id, else: task["id"]
    revision = if is_struct(task, Task), do: task.revision, else: task["revision"]

    assert {:ok, %{"task" => finished}} =
             Board.execute(%Commands.RunFinished{task_id: task_id, run_id: run["id"], outcome: %{}},
               actor: :system,
               expected_revision: revision,
               idempotency_key: BoardFactory.unique("orchestrator-finish")
             )

    finished
  end

  defp finish_run_with_publication(task, run, destination) do
    finished = finish_run(task, run)

    assert {:ok, %{"task" => published}} =
             Board.execute(
               %Commands.RecordRunStatsPublication{
                 task_id: finished["id"],
                 run_id: run["id"],
                 destination: destination,
                 publication_id: BoardFactory.unique("test-stats-publication")
               },
               actor: :system,
               expected_revision: finished["revision"],
               idempotency_key: BoardFactory.unique("record-test-stats-publication")
             )

    published
  end

  defp cleanup_active_run(task_id, run_id) do
    case Board.task(task_id) do
      {:ok, %{active_run_id: ^run_id} = task} ->
        Board.execute(%Commands.RunFailed{task_id: task_id, run_id: run_id, reason: :test_cleanup},
          actor: :system,
          expected_revision: task.revision,
          idempotency_key: BoardFactory.unique("orchestrator-cleanup")
        )

      _ ->
        :ok
    end
  end

  defp cleanup_test_task(task_id) do
    case Board.task(task_id) do
      {:ok, %{active_run_id: run_id}} when is_binary(run_id) ->
        cleanup_active_run(task_id, run_id)

      {:ok, %{column_id: column_id} = task} when column_id not in ["blocked", "cancelled", "done"] ->
        Board.execute(%Commands.BlockTask{task_id: task_id, reason: "test cleanup"},
          actor: :system,
          expected_revision: task.revision,
          idempotency_key: BoardFactory.unique("orchestrator-task-cleanup")
        )

      _ ->
        :ok
    end
  end

  defp enable_dispatch(orchestrator) do
    :sys.replace_state(orchestrator, fn state ->
      %{
        state
        | dispatch_enabled: true,
          github_health: %{available: true, authenticated: true, error: nil},
          github_health_checked_at: System.monotonic_time(:millisecond)
      }
    end)

    send(orchestrator, :reconcile)
  end

  defp disable_dispatch(orchestrator) do
    :sys.replace_state(orchestrator, &%{&1 | dispatch_enabled: false})
  end

  defp safe_stop(orchestrator) do
    GenServer.stop(orchestrator, :normal)
  catch
    :exit, {:noproc, {GenServer, :stop, _arguments}} -> :ok
  end

  defp await_merge_worker_exit(pid, ref) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      2_000 -> flunk("merge worker did not stop during test cleanup")
    end
  end

  defp eventually(assertion, attempts \\ 300)

  defp eventually(assertion, attempts) when attempts > 0 do
    if assertion.() do
      :ok
    else
      Process.sleep(10)
      eventually(assertion, attempts - 1)
    end
  end

  defp eventually(assertion, 0), do: assert(assertion.())

  defp process_alive?(pid) when is_integer(pid) do
    match?({_output, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
  end

  defp kill_process(pid) do
    if process_alive?(pid) do
      System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    :ok
  end

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
