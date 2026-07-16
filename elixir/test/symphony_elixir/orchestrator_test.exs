defmodule SymphonyElixir.OrchestratorTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.Task

  test "publication reconciliation skips active workpads and gates only the affected task" do
    bundle = publish_merging_bundle()
    active = task("active", "merging", "active-run")
    failing = task("failing", "merging", nil)
    ready = task("ready", "merging", nil)
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

  defp publish_merging_bundle do
    bundle = Config.bundle!()

    columns =
      Enum.map(bundle.columns, fn
        %{id: "merging"} = column -> %{column | publish_workpad: true}
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
end
