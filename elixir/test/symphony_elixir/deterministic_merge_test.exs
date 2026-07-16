defmodule SymphonyElixir.DeterministicMergeTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Board.Commands
  alias SymphonyElixir.{Config, DeterministicMerge, Task}

  @head String.duplicate("a", 40)
  @target String.duplicate("b", 40)
  @updated String.duplicate("c", 40)
  @merge String.duplicate("d", 40)

  setup do
    task = merge_task()
    Process.put(:merge_fake_task, task)
    Process.put(:merge_fake_results, %{})
    Process.put(:merge_fake_calls, [])
    Process.put(:merge_scenario, %{})
    Process.delete(:merge_fake_ensure_context)

    on_exit(fn ->
      Process.delete(:merge_fake_task)
      Process.delete(:merge_fake_results)
      Process.delete(:merge_fake_calls)
      Process.delete(:merge_scenario)
      Process.delete(:merge_fake_ensure_context)
    end)

    %{task: task, bundle: Config.bundle!()}
  end

  test "ready reviewed head is guarded-squash merged and verified without an agent", %{task: task, bundle: bundle} do
    assert {:ok, :completed} = run(task, bundle)

    completed = current_task()
    assert completed.column_id == "done"
    assert get_in(completed.github, ["merged", "merge_sha"]) == @merge
    assert get_in(completed.github, ["merged", "merge_reachable"]) == true
    assert count_call(:guarded_squash) == 1
    assert count_call(:merge_target) == 0
  end

  test "clean target update pushes once, invalidates review, and returns to automated review", %{
    task: task,
    bundle: bundle
  } do
    scenario(%{target_ancestor: false, merge_target: {:ok, @updated}})

    assert {:ok, :review_required} = run(task, bundle)
    updated = current_task()
    assert updated.column_id == "automated_review"
    assert is_nil(updated.review_attestation)
    assert updated.source["head_sha"] == @updated
    assert updated.github["head_sha"] == @updated
    assert count_call(:merge_target) == 1
    assert count_call(:push_head) == 1
    assert count_call(:guarded_squash) == 0
  end

  test "only a verified git conflict reaches conflict dispatch and the same head pair then blocks", %{
    task: task,
    bundle: bundle
  } do
    scenario(%{target_ancestor: false, merge_target: {:conflict, ["z.swift", "a.swift", "z.swift"]}})

    assert {:ok, :conflict} = run(task, bundle)
    conflicted = current_task()
    assert conflicted.column_id == "merge_conflict"
    assert get_in(conflicted.merge_saga, ["last_conflict", "conflicted_paths"]) == ["a.swift", "z.swift"]
    assert is_nil(conflicted.review_attestation)

    repeated = %{
      conflicted
      | column_id: "merging",
        review_attestation: merge_task().review_attestation,
        revision: conflicted.revision + 1
    }

    Process.put(:merge_fake_task, repeated)
    assert {:ok, :blocked} = run(repeated, bundle)
    assert current_task().column_id == "blocked"
    assert current_task().metadata["blocked_reason"] =~ "Repeated merge conflict"
  end

  test "stale head, changed feedback, absent or changes-requested approval, and failed checks return to review", %{
    task: task,
    bundle: bundle
  } do
    cases = [
      {:stale_head, %{source_head: @updated}},
      {:feedback, %{snapshot: %{feedback_fingerprint: "changed"}}},
      {:check_fingerprint, %{snapshot: %{checks_fingerprint: "changed"}}},
      {:approval_absent, %{snapshot: %{approved: false, review_decision: ""}}},
      {:changes_requested, %{snapshot: %{approved: false, review_decision: "CHANGES_REQUESTED"}}},
      {:checks, %{snapshot: %{required_checks_green: false}}}
    ]

    Enum.each(cases, fn {_name, changes} ->
      Process.put(:merge_fake_task, task)
      Process.put(:merge_fake_results, %{})
      Process.put(:merge_fake_calls, [])
      scenario(changes)

      assert {:ok, :review_required} = run(task, bundle)
      assert current_task().column_id == "automated_review"
      assert count_call(:readiness) == 0
      assert count_call(:guarded_squash) == 0
    end)
  end

  test "transient provider failure remains merge-pending while a missing pull request blocks", %{
    task: task,
    bundle: bundle
  } do
    scenario(%{review_snapshot: {:error, {:transient, :network_down}}})
    assert {:ok, :pending} = run(task, bundle)
    assert current_task().column_id == "merging"

    missing = %{task | github: %{}}
    Process.put(:merge_fake_task, missing)
    scenario(%{review_snapshot: {:error, :pull_request_not_linked}})
    assert {:ok, :blocked} = run(missing, bundle)
    assert current_task().column_id == "blocked"
  end

  test "failed readiness returns review and transport failure blocks without agent dispatch", %{
    task: task,
    bundle: bundle
  } do
    scenario(%{readiness: {:error, {:readiness_failed, 7, "tests failed"}}})
    assert {:ok, :review_required} = run(task, bundle)
    assert current_task().column_id == "automated_review"

    Process.put(:merge_fake_task, task)
    scenario(%{readiness: {:error, {:readiness_transport_failed, "port closed"}}})
    assert {:ok, :blocked} = run(task, bundle)
    assert current_task().column_id == "blocked"
  end

  test "guarded head mismatch returns review and merge reachability resumes idempotently", %{
    task: task,
    bundle: bundle
  } do
    scenario(%{guarded_squash: {:error, {:stale, :head_changed}}})
    assert {:ok, :review_required} = run(task, bundle)
    assert current_task().column_id == "automated_review"

    Process.put(:merge_fake_task, task)
    Process.put(:merge_fake_calls, [])
    scenario(%{reachable: false})
    assert {:ok, :pending} = run(task, bundle)
    pending = current_task()
    assert get_in(pending.merge_saga, ["checkpoint"]) == "reachability_pending"

    scenario(%{snapshot: %{state: "MERGED", merge_sha: @merge}, reachable: true})
    assert {:ok, :completed} = run(pending, bundle)
    assert current_task().column_id == "done"
    assert count_call(:guarded_squash) == 1
  end

  test "a crash-recovered clean update pushes the existing merge commit instead of merging twice", %{
    task: task,
    bundle: bundle
  } do
    recovering = %{
      task
      | merge_saga: %{
          "checkpoint" => "clean_update_started",
          "attrs" => %{"task_head" => @head, "target_head" => @target}
        }
    }

    Process.put(:merge_fake_task, recovering)
    scenario(%{source_head: @updated, target_ancestor: true})

    assert {:ok, :review_required} = run(recovering, bundle)
    assert count_call(:merge_target) == 0
    assert count_call(:push_head) == 1
  end

  test "entry, snapshot, readiness, fetch, and comparison failures route deterministically", %{
    task: task,
    bundle: bundle
  } do
    cases = [
      {%{ensure_worktree: {:error, {:transient, :checkout_busy}}}, {:ok, :pending}, "merging"},
      {%{ensure_worktree: {:error, :unsafe_checkout}}, {:ok, :blocked}, "blocked"},
      {%{review_snapshot: {:error, :malformed_snapshot}}, {:ok, :blocked}, "blocked"},
      {%{snapshot: %{state: "CLOSED"}}, {:ok, :blocked}, "blocked"},
      {%{readiness: {:error, {:transient, :runner_busy}}}, {:ok, :pending}, "merging"},
      {%{fetch_target: {:error, {:transient, :fetch_busy}}}, {:ok, :pending}, "merging"},
      {%{fetch_target: {:error, :missing_target}}, {:ok, :blocked}, "blocked"},
      {%{target_ancestor: {:error, {:transient, :comparison_busy}}}, {:ok, :pending}, "merging"},
      {%{target_ancestor: {:error, :bad_comparison}}, {:ok, :blocked}, "blocked"}
    ]

    Enum.each(cases, fn {values, expected, column} ->
      reset(task)
      scenario(values)
      assert ^expected = run(task, bundle)
      assert current_task().column_id == column
    end)

    invalid = %{task | review_attestation: nil}
    reset(invalid)
    assert {:ok, :blocked} = run(invalid, bundle)
  end

  test "clean-update recovery and write failures preserve the saga contract", %{task: task, bundle: bundle} do
    recovering = fn attrs ->
      %{task | merge_saga: %{"checkpoint" => "clean_update_started", "attrs" => attrs}}
    end

    invalid = recovering.(%{"task_head" => "invalid", "target_head" => @target})
    reset(invalid)
    assert {:ok, :blocked} = run(invalid, bundle)

    cases = [
      {%{source_head: {:error, {:transient, :head_busy}}}, {:ok, :pending}, "merging"},
      {%{source_head: {:error, :head_failed}}, {:ok, :blocked}, "blocked"},
      {%{source_head: @head, merge_target: {:error, {:transient, :merge_busy}}}, {:ok, :pending}, "merging"},
      {%{source_head: @head, merge_target: {:error, {:stale, :head_changed}}}, {:ok, :review_required}, "automated_review"},
      {%{source_head: @head, merge_target: {:error, :merge_failed}}, {:ok, :blocked}, "blocked"},
      {%{source_head: @updated, target_ancestor: false}, {:ok, :review_required}, "automated_review"},
      {%{source_head: @updated, target_ancestor: {:error, {:transient, :comparison_busy}}}, {:ok, :pending}, "merging"},
      {%{source_head: @updated, target_ancestor: {:error, :comparison_failed}}, {:ok, :blocked}, "blocked"},
      {
        %{source_head: @updated, target_ancestor: true, push_head: {:error, {:transient, :push_busy}}},
        {:ok, :pending},
        "merging"
      },
      {
        %{source_head: @updated, target_ancestor: true, push_head: {:error, {:stale, :remote_changed}}},
        {:ok, :review_required},
        "automated_review"
      },
      {%{source_head: @updated, target_ancestor: true, push_head: {:error, :push_failed}}, {:ok, :blocked}, "blocked"}
    ]

    Enum.each(cases, fn {values, expected, column} ->
      recovering_task = recovering.(%{"task_head" => @head, "target_head" => @target})
      reset(recovering_task)
      scenario(values)
      assert ^expected = run(recovering_task, bundle)
      assert current_task().column_id == column
    end)
  end

  test "provider conflict hints and guarded merge failures are independently verified", %{
    task: task,
    bundle: bundle
  } do
    cases = [
      {%{snapshot: %{mergeable: "CONFLICTING"}, probe_conflict: {:conflict, ["hint.swift"]}}, {:ok, :conflict}, "merge_conflict"},
      {%{snapshot: %{mergeable: "CONFLICTING"}, probe_conflict: {:ok, :clean}}, {:ok, :review_required}, "automated_review"},
      {%{snapshot: %{mergeable: "CONFLICTING"}, probe_conflict: {:error, {:transient, :probe_busy}}}, {:ok, :pending}, "merging"},
      {%{snapshot: %{mergeable: "CONFLICTING"}, probe_conflict: {:error, :probe_failed}}, {:ok, :blocked}, "blocked"},
      {%{guarded_squash: {:conflict, :provider_conflict}, probe_conflict: {:ok, :clean}}, {:ok, :review_required}, "automated_review"},
      {%{guarded_squash: {:error, {:transient, :merge_busy}}}, {:ok, :pending}, "merging"},
      {%{guarded_squash: {:error, {:missing_or_closed_pr, "CLOSED"}}}, {:ok, :blocked}, "blocked"},
      {%{guarded_squash: {:error, :merge_failed}}, {:ok, :blocked}, "blocked"}
    ]

    Enum.each(cases, fn {values, expected, column} ->
      reset(task)
      scenario(values)
      assert ^expected = run(task, bundle)
      assert current_task().column_id == column
    end)
  end

  test "merged recovery and reachability failures remain resumable or block safely", %{task: task, bundle: bundle} do
    invalidly_merged = %{task | merge_saga: nil}
    reset(invalidly_merged)
    scenario(%{snapshot: %{state: "MERGED", merge_sha: @merge}})
    assert {:ok, :blocked} = run(invalidly_merged, bundle)

    checkpointed = %{task | merge_saga: %{"checkpoint" => "squash_started"}}

    cases = [
      {
        %{snapshot: %{state: "MERGED", merge_sha: @merge}, fetch_target: {:error, {:transient, :fetch_busy}}},
        {:ok, :pending},
        "merging"
      },
      {%{snapshot: %{state: "MERGED", merge_sha: @merge}, fetch_target: {:error, :fetch_failed}}, {:ok, :blocked}, "blocked"},
      {
        %{snapshot: %{state: "MERGED", merge_sha: @merge}, reachable: {:error, {:transient, :graph_busy}}},
        {:ok, :pending},
        "merging"
      },
      {%{snapshot: %{state: "MERGED", merge_sha: @merge}, reachable: {:error, :graph_failed}}, {:ok, :blocked}, "blocked"}
    ]

    Enum.each(cases, fn {values, expected, column} ->
      reset(checkpointed)
      scenario(values)
      assert ^expected = run(checkpointed, bundle)
      assert current_task().column_id == column
    end)
  end

  test "canonical write failures are returned without claiming an external effect", %{task: task, bundle: bundle} do
    cases = [
      {Commands.RecordMergeCheckpoint, %{}, :checkpoint_failed},
      {Commands.InvalidateReviewAttestation, %{snapshot: %{required_checks_green: false}}, :review_write_failed},
      {Commands.BlockTask, %{snapshot: %{state: "CLOSED"}}, :block_write_failed},
      {
        Commands.RecordMergeConflict,
        %{snapshot: %{mergeable: "CONFLICTING"}, probe_conflict: {:conflict, ["conflict.swift"]}},
        :conflict_write_failed
      },
      {Commands.CompleteDeterministicMerge, %{}, :completion_write_failed}
    ]

    Enum.each(cases, fn {command_module, values, reason} ->
      reset(task)
      scenario(Map.merge(values, %{board_error: {command_module, reason}}))
      assert {:error, ^reason} = run(task, bundle)
    end)

    checkpointed = %{task | merge_saga: %{"checkpoint" => "squash_started"}}
    reset(checkpointed)

    scenario(%{
      snapshot: %{state: "MERGED", merge_sha: @merge},
      reachable: false,
      board_error: {Commands.RecordMergeCheckpoint, :reachability_checkpoint_failed}
    })

    assert {:error, :reachability_checkpoint_failed} = run(checkpointed, bundle)
  end

  test "prior run history supplies the last local or remote merge location", %{task: task, bundle: bundle} do
    histories = [
      {[%{"workspace_path" => "/tmp/prior-worktree", "worker_host" => "builder-a"}], %{worktree: "/tmp/prior-worktree", worker_host: "builder-a"}},
      {[%{"worker_host" => "builder-b"}], %{worktree: nil, worker_host: "builder-b"}}
    ]

    Enum.each(histories, fn {history, expected_location} ->
      reset(task)
      assert {:ok, :completed} = run_from_history(task, bundle, history)
      assert Map.take(Process.get(:merge_fake_ensure_context), [:worktree, :worker_host]) == expected_location
    end)

    reset(task)
    assert {:ok, :completed} = run_from_board_history(task, bundle)

    assert Map.take(Process.get(:merge_fake_ensure_context), [:worktree, :worker_host]) == %{
             worktree: nil,
             worker_host: nil
           }
  end

  test "the same review reason in a later revision performs a fresh canonical write", %{task: task, bundle: bundle} do
    scenario(%{snapshot: %{required_checks_green: false}})
    assert {:ok, :review_required} = run(task, bundle)
    first = current_task()

    next_cycle = %{task | revision: first.revision + 1}
    Process.put(:merge_fake_task, next_cycle)
    Process.put(:merge_fake_calls, [])

    assert {:ok, :review_required} = run(next_cycle, bundle)
    assert current_task().revision == next_cycle.revision + 1
  end

  defp run(task, bundle) do
    DeterministicMerge.run(task, bundle,
      boundary: &boundary/3,
      board_executor: &board_execute/2,
      location: %{worktree: "/tmp/fake-worktree", worker_host: nil}
    )
  end

  defp run_from_history(task, bundle, history) do
    DeterministicMerge.run(task, bundle,
      boundary: &boundary/3,
      board_executor: &board_execute/2,
      run_history: history
    )
  end

  defp run_from_board_history(task, bundle) do
    DeterministicMerge.run(task, bundle,
      boundary: &boundary/3,
      board_executor: &board_execute/2
    )
  end

  defp boundary(operation, _task, context) do
    if operation == :ensure_worktree, do: Process.put(:merge_fake_ensure_context, context)
    calls = Process.get(:merge_fake_calls, [])
    Process.put(:merge_fake_calls, calls ++ [operation])
    scenario = Process.get(:merge_scenario, %{})
    boundary_result(operation, context, scenario)
  end

  defp boundary_result(:ensure_worktree, context, scenario) do
    Map.get(scenario, :ensure_worktree, {:ok, Map.put(context, :worktree, "/tmp/fake-worktree")})
  end

  defp boundary_result(:source_head, _context, scenario),
    do: wrap_ok(Map.get(scenario, :source_head, @head))

  defp boundary_result(:review_snapshot, _context, scenario),
    do: Map.get(scenario, :review_snapshot, {:ok, snapshot(scenario[:snapshot] || %{})})

  defp boundary_result(:readiness, _context, scenario),
    do: Map.get(scenario, :readiness, {:ok, "ready"})

  defp boundary_result(:fetch_target, _context, scenario),
    do: wrap_ok(Map.get(scenario, :fetch_target, @target))

  defp boundary_result(:target_ancestor, _context, scenario),
    do: wrap_ok(Map.get(scenario, :target_ancestor, true))

  defp boundary_result(:merge_target, _context, scenario),
    do: Map.get(scenario, :merge_target, {:ok, @updated})

  defp boundary_result(:probe_conflict, _context, scenario),
    do: Map.get(scenario, :probe_conflict, {:conflict, ["conflict.swift"]})

  defp boundary_result(:push_head, _context, scenario), do: Map.get(scenario, :push_head, :ok)

  defp boundary_result(:guarded_squash, _context, scenario),
    do: Map.get(scenario, :guarded_squash, {:ok, @merge})

  defp boundary_result(:reachable, _context, scenario),
    do: wrap_ok(Map.get(scenario, :reachable, true))

  defp snapshot(overrides) do
    Map.merge(
      %{
        state: "OPEN",
        head_sha: @head,
        source_head_sha: @head,
        approved: true,
        mergeable: "MERGEABLE",
        merge_sha: nil,
        unresolved_review_threads: 0,
        required_checks_green: true,
        feedback_fingerprint: "feedback-v1",
        checks_fingerprint: "checks-v1"
      },
      overrides
    )
  end

  defp board_execute(command, opts) do
    key = Keyword.fetch!(opts, :idempotency_key)
    prior = Process.get(:merge_fake_results, %{})

    case Process.get(:merge_scenario, %{})[:board_error] do
      {module, reason} when command.__struct__ == module ->
        {:error, reason}

      _ ->
        execute_board_command(command, key, prior)
    end
  end

  defp execute_board_command(command, key, prior) do
    case prior[key] do
      nil ->
        task = current_task()
        updated = apply_command(command, task)
        result = %{"task" => Task.to_map(updated), "event_type" => command.__struct__ |> Module.split() |> List.last()}
        Process.put(:merge_fake_task, updated)
        Process.put(:merge_fake_results, Map.put(prior, key, result))
        {:ok, result}

      result ->
        {:ok, result}
    end
  end

  defp apply_command(%Commands.RecordMergeCheckpoint{} = command, task) do
    saga =
      (task.merge_saga || %{})
      |> Map.put("checkpoint", command.checkpoint)
      |> Map.put("attrs", command.attrs)

    bump(task, %{merge_saga: saga})
  end

  defp apply_command(%Commands.InvalidateReviewAttestation{reason: reason, head_sha: head_sha}, task) do
    saga = (task.merge_saga || %{}) |> Map.put("checkpoint", "review_required") |> Map.put("reason", reason)

    heads =
      if is_binary(head_sha),
        do: %{source: Map.put(task.source, "head_sha", head_sha), github: Map.put(task.github, "head_sha", head_sha)},
        else: %{}

    bump(
      task,
      Map.merge(%{column_id: "automated_review", review_attestation: nil, merge_saga: saga}, heads)
    )
  end

  defp apply_command(%Commands.BlockTask{reason: reason}, task) do
    bump(task, %{
      column_id: "blocked",
      blocked_from_column_id: task.column_id,
      review_attestation: nil,
      metadata: Map.put(task.metadata, "blocked_reason", reason)
    })
  end

  defp apply_command(%Commands.RecordMergeConflict{} = command, task) do
    previous = get_in(task.merge_saga || %{}, ["last_conflict"])

    if previous && previous["task_head"] == command.task_head && previous["target_head"] == command.target_head do
      apply_command(
        %Commands.BlockTask{
          reason: "Repeated merge conflict for task head #{command.task_head} and target head #{command.target_head}"
        },
        task
      )
    else
      conflict = %{
        "id" => command.conflict_id,
        "task_head" => command.task_head,
        "target_head" => command.target_head,
        "conflicted_paths" => command.conflicted_paths
      }

      saga = (task.merge_saga || %{}) |> Map.put("checkpoint", "conflict_recorded") |> Map.put("last_conflict", conflict)
      bump(task, %{column_id: "merge_conflict", review_attestation: nil, merge_saga: saga})
    end
  end

  defp apply_command(%Commands.CompleteDeterministicMerge{} = command, task) do
    github =
      Map.put(task.github, "merged", %{
        "merged" => true,
        "merge_sha" => command.merge_sha,
        "merge_reachable" => true
      })

    bump(task, %{column_id: "done", github: github, merge_saga: %{"checkpoint" => "completed"}})
  end

  defp bump(task, attrs), do: task |> Map.merge(attrs) |> Map.put(:revision, task.revision + 1)

  defp current_task, do: Process.get(:merge_fake_task)
  defp count_call(operation), do: Enum.count(Process.get(:merge_fake_calls, []), &(&1 == operation))
  defp scenario(values), do: Process.put(:merge_scenario, values)

  defp reset(task) do
    Process.put(:merge_fake_task, task)
    Process.put(:merge_fake_results, %{})
    Process.put(:merge_fake_calls, [])
    Process.put(:merge_scenario, %{})
    Process.delete(:merge_fake_ensure_context)
  end

  defp wrap_ok({tag, _reason} = result) when tag in [:error, :conflict], do: result
  defp wrap_ok(value), do: {:ok, value}

  defp merge_task do
    %Task{
      id: "task-merge",
      identifier: "SYM-1",
      number: 1,
      project_id: "symphony",
      title: "Deterministic merge",
      type: :feature,
      branch: "feature/SYM-1",
      priority: :normal,
      brief: "Merge safely",
      acceptance_criteria: [
        %{"id" => "criterion", "text" => "Verified", "completed" => true, "evidence" => [%{"result" => "pass"}]}
      ],
      column_id: "merging",
      rank: 1_024,
      revision: 7,
      source: %{"head_sha" => @head, "clean" => true},
      github: %{"number" => 7, "head_sha" => @head, "state" => "open"},
      review_attestation: %{
        "verdict" => "pass",
        "reviewed_head_sha" => @head,
        "feedback_fingerprint" => "feedback-v1",
        "checks_fingerprint" => "checks-v1"
      },
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z"
    }
  end
end
