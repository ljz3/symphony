defmodule SymphonyElixir.BoardTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Board
  alias SymphonyElixir.Board.{Commands, History, Projection, Storage}
  alias SymphonyElixir.BoardFactory

  test "commands are revision checked, idempotent, claimed atomically, and fail to Blocked without retry" do
    {created, key} = BoardFactory.create_task(%{title: BoardFactory.unique("Lifecycle")})

    assert {:ok, %{"task" => ^created}} =
             Board.execute(%Commands.CreateTask{attrs: %{title: "ignored"}},
               actor: :human,
               expected_revision: 0,
               idempotency_key: key
             )

    assert {:error, {:stale_task_revision, _, 0, 1}} =
             Board.execute(%Commands.MoveTask{task_id: created["id"], column_id: "todo"},
               actor: :human,
               expected_revision: 0,
               idempotency_key: BoardFactory.unique("stale")
             )

    {todo, _} = BoardFactory.move(created, "todo")

    assert {:ok, %{"task" => claimed, "run" => run}} =
             Board.execute(%Commands.ClaimRun{task_id: todo["id"]},
               actor: :system,
               expected_revision: todo["revision"],
               idempotency_key: BoardFactory.unique("claim")
             )

    assert claimed["column_id"] == "in_progress"
    assert claimed["runtime_state"] == "starting"
    assert run["frozen_bundle"]["stage"]["id"] == "implementation"

    assert run["frozen_bundle"]["jobs"]
           |> Map.keys()
           |> Enum.sort() == ["full_validation", "targeted_validation"]

    assert get_in(run, ["frozen_bundle", "jobs", "full_validation", "passthrough_arguments"]) ==
             "forbidden"

    assert get_in(run, ["frozen_bundle", "jobs", "targeted_validation", "passthrough_arguments"]) ==
             "required"

    assert {:ok, %{"task" => blocked, "run" => failed}} =
             Board.execute(%Commands.RunFailed{task_id: claimed["id"], run_id: run["id"], reason: :boom},
               actor: :system,
               expected_revision: claimed["revision"],
               idempotency_key: BoardFactory.unique("fail")
             )

    assert blocked["column_id"] == "blocked"
    assert blocked["blocked_from_column_id"] == "in_progress"
    assert failed["status"] == "failed"

    assert {:ok, %{"task" => resumed}} =
             Board.execute(%Commands.ResumeTask{task_id: blocked["id"]},
               actor: :human,
               expected_revision: blocked["revision"],
               idempotency_key: BoardFactory.unique("resume")
             )

    assert resumed["column_id"] == "in_progress"
    assert resumed["active_run_id"] == nil
  end

  test "acceptance evidence and dependency cycles are enforced" do
    {first, _} = BoardFactory.create_task(%{title: BoardFactory.unique("Dependency A")})
    {second, _} = BoardFactory.create_task(%{title: BoardFactory.unique("Dependency B"), dependencies: [first["id"]]})
    criterion_id = first["acceptance_criteria"] |> hd() |> Map.fetch!("id")

    assert {:error, :agent_completion_requires_evidence} =
             Board.execute(%Commands.CompleteAcceptance{task_id: first["id"], criterion_id: criterion_id},
               actor: :agent,
               expected_revision: first["revision"],
               idempotency_key: BoardFactory.unique("evidence")
             )

    assert {:ok, %{"task" => completed}} =
             Board.execute(
               %Commands.CompleteAcceptance{
                 task_id: first["id"],
                 criterion_id: criterion_id,
                 evidence: [%{"command" => "mix test", "result" => "passed"}]
               },
               actor: :agent,
               expected_revision: first["revision"],
               idempotency_key: BoardFactory.unique("evidence")
             )

    assert get_in(completed, ["acceptance_criteria", Access.at(0), "completed"])

    assert {:ok, %{"task" => reopened}} =
             Board.execute(%Commands.ReopenAcceptance{task_id: first["id"], criterion_id: criterion_id, reason: "regression"},
               actor: :human,
               expected_revision: completed["revision"],
               idempotency_key: BoardFactory.unique("reopen")
             )

    refute get_in(reopened, ["acceptance_criteria", Access.at(0), "completed"])

    assert {:error, :dependency_cycle} =
             Board.execute(%Commands.UpdateTask{task_id: first["id"], attrs: %{dependencies: [second["id"]]}},
               actor: :human,
               expected_revision: reopened["revision"],
               idempotency_key: BoardFactory.unique("cycle")
             )
  end

  test "terminal tasks archive by tombstone and checkpoints are committed" do
    {task, _} = BoardFactory.create_task(%{title: BoardFactory.unique("Archive"), type: "Chore"})
    {cancelled, _} = BoardFactory.move(task, "cancelled")

    assert {:ok, %{"task" => archived}} =
             Board.execute(%Commands.ArchiveTask{task_id: task["id"]},
               actor: :human,
               expected_revision: cancelled["revision"],
               idempotency_key: BoardFactory.unique("archive")
             )

    assert is_binary(archived["archived_at"])
    assert Enum.any?(Board.tasks(archived: true), &(&1.id == task["id"]))
    assert {:ok, checkpoint} = Board.checkpoint()
    assert checkpoint.sequence > 0
    assert byte_size(checkpoint.sha256) == 64
  end

  test "sparse reordering preserves priority-aware task order" do
    {first, _} = BoardFactory.create_task(%{title: BoardFactory.unique("Rank 1")})
    {second, _} = BoardFactory.create_task(%{title: BoardFactory.unique("Rank 2")})

    assert {:ok, %{"task" => moved}} =
             Board.execute(%Commands.ReorderTask{task_id: second["id"], after_task_id: first["id"]},
               actor: :human,
               expected_revision: second["revision"],
               idempotency_key: BoardFactory.unique("rank")
             )

    assert moved["rank"] < first["rank"]
  end

  test "an active agent persists scoped GitHub saga outcomes and canonical draft state" do
    {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("GitHub saga")})
    {todo, _result} = BoardFactory.move(created, "todo")

    assert {:ok, %{"task" => claimed, "run" => run}} =
             Board.execute(%Commands.ClaimRun{task_id: todo["id"]},
               actor: :system,
               expected_revision: todo["revision"],
               idempotency_key: BoardFactory.unique("claim")
             )

    assert {:ok, %{"task" => recorded}} =
             Board.execute(
               %Commands.RecordGitHubOutcome{
                 task_id: claimed["id"],
                 kind: "ready",
                 attrs: %{completed: true}
               },
               actor: %{type: :agent, identity: run["id"]},
               expected_revision: claimed["revision"],
               idempotency_key: BoardFactory.unique("github-outcome")
             )

    assert get_in(recorded, ["github", "ready", "completed"]) == true
    assert recorded["github"]["draft"] == false

    assert {:ok, %{"task" => drafted}} =
             Board.execute(
               %Commands.RecordGitHubOutcome{
                 task_id: recorded["id"],
                 kind: "rework_draft",
                 attrs: %{completed: true}
               },
               actor: %{type: :agent, identity: run["id"]},
               expected_revision: recorded["revision"],
               idempotency_key: BoardFactory.unique("github-draft-outcome")
             )

    assert get_in(drafted, ["github", "rework_draft", "completed"]) == true
    assert drafted["github"]["draft"] == true

    assert {:ok, %{"task" => ready_again}} =
             Board.execute(
               %Commands.RecordGitHubOutcome{
                 task_id: drafted["id"],
                 kind: "ready",
                 attrs: %{completed: true}
               },
               actor: %{type: :agent, identity: run["id"]},
               expected_revision: drafted["revision"],
               idempotency_key: BoardFactory.unique("github-ready-again")
             )

    assert ready_again["github"]["draft"] == false
    refute Map.has_key?(ready_again["github"], "rework_draft")

    assert {:ok, %{"task" => drafted_again}} =
             Board.execute(
               %Commands.RecordGitHubOutcome{
                 task_id: ready_again["id"],
                 kind: "rework_draft",
                 attrs: %{completed: true}
               },
               actor: %{type: :agent, identity: run["id"]},
               expected_revision: ready_again["revision"],
               idempotency_key: BoardFactory.unique("github-draft-again")
             )

    assert drafted_again["github"]["draft"] == true
    assert get_in(drafted_again, ["github", "rework_draft", "completed"]) == true

    assert {:ok, _result} =
             Board.execute(
               %Commands.RunFailed{
                 task_id: drafted_again["id"],
                 run_id: run["id"],
                 reason: "test cleanup"
               },
               actor: :system,
               expected_revision: drafted_again["revision"],
               idempotency_key: BoardFactory.unique("cleanup")
             )
  end

  test "terminal run stats are canonical, replayable, and clear live telemetry" do
    assert Storage.migration_version() == 3

    {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Run stats")})
    {todo, _result} = BoardFactory.move(created, "todo")

    assert {:ok, %{"task" => claimed, "run" => run}} =
             Board.execute(%Commands.ClaimRun{task_id: todo["id"]},
               actor: :system,
               expected_revision: todo["revision"],
               idempotency_key: BoardFactory.unique("stats-claim")
             )

    assert {:ok, %{"task" => running}} =
             Board.execute(
               %Commands.RunStarted{
                 task_id: claimed["id"],
                 run_id: run["id"],
                 session_id: "thread-stats",
                 workspace_path: "/tmp/stats"
               },
               actor: :system,
               expected_revision: claimed["revision"],
               idempotency_key: BoardFactory.unique("stats-start")
             )

    assert :ok =
             Projection.observe_run_telemetry(run["id"], %{
               event: :session_started,
               thread_id: "thread-stats",
               turn_id: "turn-stats"
             })

    assert :ok =
             Projection.observe_run_telemetry(run["id"], %{
               event: :notification,
               payload: %{
                 "method" => "thread/tokenUsage/updated",
                 "params" => %{
                   "tokenUsage" => %{
                     "total" => %{
                       "inputTokens" => 1_000,
                       "cachedInputTokens" => 700,
                       "outputTokens" => 250,
                       "totalTokens" => 1_250
                     }
                   }
                 }
               }
             })

    assert {:ok, %{"run" => failed}} =
             Board.execute(
               %Commands.RunFailed{
                 task_id: running["id"],
                 run_id: run["id"],
                 reason: :boom
               },
               actor: :system,
               expected_revision: running["revision"],
               idempotency_key: BoardFactory.unique("stats-fail")
             )

    assert failed["status"] == "failed"
    assert failed["stats"]["turn_count"] == 1
    assert failed["stats"]["duration_ms"] >= 0

    assert failed["stats"]["token_usage"] == %{
             "input_tokens" => 1_000,
             "cached_input_tokens" => 700,
             "output_tokens" => 250,
             "total_tokens" => 1_250
           }

    assert Projection.run_telemetry(run["id"]) == nil

    assert {:ok, events} = History.events("symphony")
    assert :ok = Projection.rebuild(events)
    assert {:ok, replayed} = Board.run(run["id"])
    assert replayed["stats"] == failed["stats"]
  end

  test "completed and stopped runs retain stats even without token usage" do
    {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Completed stats")})
    {todo, _result} = BoardFactory.move(created, "todo")

    assert {:ok, %{"task" => claimed, "run" => completed_run}} =
             Board.execute(%Commands.ClaimRun{task_id: todo["id"]},
               actor: :system,
               expected_revision: todo["revision"],
               idempotency_key: BoardFactory.unique("complete-claim")
             )

    assert {:ok, %{"task" => linked, "run" => linked_run}} =
             Board.execute(
               %Commands.LinkPullRequest{
                 task_id: claimed["id"],
                 run_id: completed_run["id"],
                 number: 42,
                 url: "https://github.example/pull/42",
                 head_sha: String.duplicate("a", 40),
                 state: "open",
                 draft: true,
                 created_by_run_id: completed_run["id"]
               },
               actor: :system,
               expected_revision: claimed["revision"],
               idempotency_key: BoardFactory.unique("complete-pr-link")
             )

    assert linked_run["pull_request_created"] == true
    {transitioned, _result} = BoardFactory.move(linked, "automated_review", :agent)

    assert {:ok, %{"task" => completed_task, "run" => completed}} =
             Board.execute(
               %Commands.RunFinished{
                 task_id: transitioned["id"],
                 run_id: completed_run["id"],
                 outcome: %{turns: 1},
                 stats: %{"turn_count" => 1, "token_usage" => nil}
               },
               actor: :system,
               expected_revision: transitioned["revision"],
               idempotency_key: BoardFactory.unique("complete-finish")
             )

    assert completed["status"] == "completed"
    assert completed["stats"]["turn_count"] == 1
    assert completed["stats"]["token_usage"] == nil

    assert {:ok, %{"run" => published}} =
             Board.execute(
               %Commands.RecordRunStatsPublication{
                 task_id: completed_task["id"],
                 run_id: completed["id"],
                 destination: "pr_body",
                 publication_id: "stats-publication"
               },
               actor: :system,
               expected_revision: completed_task["revision"],
               idempotency_key: BoardFactory.unique("complete-stats-publication")
             )

    assert published["stats_publication"]["destination"] == "pr_body"
    assert published["stats_publication"]["publication_id"] == "stats-publication"

    {stop_created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Stopped stats")})
    {stop_todo, _result} = BoardFactory.move(stop_created, "todo")

    assert {:ok, %{"task" => stop_claimed, "run" => stopped_run}} =
             Board.execute(%Commands.ClaimRun{task_id: stop_todo["id"]},
               actor: :system,
               expected_revision: stop_todo["revision"],
               idempotency_key: BoardFactory.unique("stop-claim")
             )

    {stop_requested, _result} = BoardFactory.move(stop_claimed, "cancelled")

    assert {:ok, %{"run" => stopped}} =
             Board.execute(
               %Commands.RunFinished{
                 task_id: stop_requested["id"],
                 run_id: stopped_run["id"],
                 outcome: %{reason: "human_stop"},
                 stats: %{"turn_count" => 0, "token_usage" => nil}
               },
               actor: :system,
               expected_revision: stop_requested["revision"],
               idempotency_key: BoardFactory.unique("stop-finish")
             )

    assert stopped["status"] == "stopped"
    assert stopped["stats"]["turn_count"] == 0
    assert stopped["stats"]["token_usage"] == nil
  end

  test "recovers the original PR creator association from its hidden marker" do
    {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Recovered PR creator")})
    {todo, _result} = BoardFactory.move(created, "todo")

    assert {:ok, %{"task" => first_claimed, "run" => first_run}} =
             Board.execute(%Commands.ClaimRun{task_id: todo["id"]},
               actor: :system,
               expected_revision: todo["revision"],
               idempotency_key: BoardFactory.unique("creator-first-claim")
             )

    {transitioned, _result} = BoardFactory.move(first_claimed, "automated_review", :agent)

    assert {:ok, %{"task" => between_runs}} =
             Board.execute(
               %Commands.RunFinished{
                 task_id: transitioned["id"],
                 run_id: first_run["id"],
                 outcome: %{turns: 1},
                 stats: %{"turn_count" => 1, "token_usage" => nil}
               },
               actor: :system,
               expected_revision: transitioned["revision"],
               idempotency_key: BoardFactory.unique("creator-first-finish")
             )

    assert {:ok, %{"task" => second_claimed, "run" => second_run}} =
             Board.execute(%Commands.ClaimRun{task_id: between_runs["id"]},
               actor: :system,
               expected_revision: between_runs["revision"],
               idempotency_key: BoardFactory.unique("creator-second-claim")
             )

    assert {:ok, %{"task" => linked_task, "run" => recovered_creator}} =
             Board.execute(
               %Commands.LinkPullRequest{
                 task_id: second_claimed["id"],
                 run_id: second_run["id"],
                 number: 42,
                 url: "https://github.example/pull/42",
                 head_sha: String.duplicate("b", 40),
                 state: "open",
                 draft: true,
                 created_by_run_id: first_run["id"]
               },
               actor: :system,
               expected_revision: second_claimed["revision"],
               idempotency_key: BoardFactory.unique("creator-recovered-link")
             )

    assert recovered_creator["id"] == first_run["id"]
    assert recovered_creator["pull_request_created"] == true
    assert {:ok, %{"pull_request_created" => false}} = Board.run(second_run["id"])

    assert {:ok, %{"task" => cleaned}} =
             Board.execute(
               %Commands.RunFailed{
                 task_id: linked_task["id"],
                 run_id: second_run["id"],
                 reason: :test_cleanup
               },
               actor: :system,
               expected_revision: linked_task["revision"],
               idempotency_key: BoardFactory.unique("creator-cleanup")
             )

    assert {:ok, %{"run" => published_creator}} =
             Board.execute(
               %Commands.RecordRunStatsPublication{
                 task_id: cleaned["id"],
                 run_id: first_run["id"],
                 destination: "pr_body",
                 publication_id: "creator-recovery-test-cleanup"
               },
               actor: :system,
               expected_revision: cleaned["revision"],
               idempotency_key: BoardFactory.unique("creator-stats-cleanup")
             )

    assert published_creator["stats_publication"]["publication_id"] ==
             "creator-recovery-test-cleanup"
  end

  describe "SubmitFeedback" do
    test "records feedback canonically, transitions to Rework atomically, and survives replay" do
      {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Feedback")})
      human_review = BoardFactory.advance_to_human_review(created)

      assert {:ok, %{"task" => rework}} =
               Board.execute(
                 %Commands.SubmitFeedback{
                   task_id: human_review["id"],
                   feedback: "  Fix the parser edge case\nAdd tests  "
                 },
                 actor: %{type: :human, identity: "board-ui"},
                 expected_revision: human_review["revision"],
                 idempotency_key: BoardFactory.unique("feedback")
               )

      assert rework["column_id"] == "rework"
      assert rework["revision"] == human_review["revision"] + 1

      assert [entry] = rework["metadata"]["human_feedback_pending"]
      assert entry["text"] == "Fix the parser edge case\nAdd tests"
      assert entry["actor"] == "board-ui"
      assert is_binary(entry["at"])

      assert Enum.any?(Board.events(rework["id"]), fn event ->
               event["type"] == "human_feedback_submitted" and
                 event["payload"]["feedback"] == entry
             end)

      assert {:ok, events} = History.events("symphony")
      assert :ok = Projection.rebuild(events)
      assert {:ok, replayed} = Board.task(rework["id"])
      assert replayed.metadata["human_feedback_pending"] == [entry]

      assert Enum.any?(Board.events(rework["id"]), fn event ->
               event["type"] == "human_feedback_submitted" and
                 event["payload"]["feedback"] == entry
             end)
    end

    test "rejects invalid source, archived, active, blank, non-human, and stale submissions" do
      {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Feedback rejections")})
      {todo, _} = BoardFactory.move(created, "todo")

      assert {:error, {:invalid_feedback_source, "todo"}} =
               Board.execute(%Commands.SubmitFeedback{task_id: todo["id"], feedback: "Please fix"},
                 actor: :human,
                 expected_revision: todo["revision"],
                 idempotency_key: BoardFactory.unique("feedback-source")
               )

      {archive_source, _} = BoardFactory.create_task(%{title: BoardFactory.unique("Feedback archived")})
      {cancelled, _} = BoardFactory.move(archive_source, "cancelled")

      assert {:ok, %{"task" => archived}} =
               Board.execute(%Commands.ArchiveTask{task_id: cancelled["id"]},
                 actor: :human,
                 expected_revision: cancelled["revision"],
                 idempotency_key: BoardFactory.unique("archive")
               )

      assert {:error, :task_archived} =
               Board.execute(%Commands.SubmitFeedback{task_id: archived["id"], feedback: "Please fix"},
                 actor: :human,
                 expected_revision: archived["revision"],
                 idempotency_key: BoardFactory.unique("feedback-archived")
               )

      {active_source, _} = BoardFactory.create_task(%{title: BoardFactory.unique("Feedback active")})
      {active_review, active_run} = BoardFactory.advance_to_human_review(active_source, false)

      assert {:error, :task_active} =
               Board.execute(%Commands.SubmitFeedback{task_id: active_review["id"], feedback: "Please fix"},
                 actor: :human,
                 expected_revision: active_review["revision"],
                 idempotency_key: BoardFactory.unique("feedback-active")
               )

      assert {:error, {:human_actor_required, _actor}} =
               Board.execute(%Commands.SubmitFeedback{task_id: active_review["id"], feedback: "Please fix"},
                 actor: :system,
                 expected_revision: active_review["revision"],
                 idempotency_key: BoardFactory.unique("feedback-system")
               )

      assert {:error, {:required_text, :feedback}} =
               Board.execute(%Commands.SubmitFeedback{task_id: active_review["id"], feedback: "   "},
                 actor: :human,
                 expected_revision: active_review["revision"],
                 idempotency_key: BoardFactory.unique("feedback-blank")
               )

      assert {:error, {:stale_task_revision, _, _, _}} =
               Board.execute(%Commands.SubmitFeedback{task_id: active_review["id"], feedback: "Please fix"},
                 actor: :human,
                 expected_revision: active_review["revision"] + 1,
                 idempotency_key: BoardFactory.unique("feedback-stale")
               )

      assert {:ok, _cleanup} =
               Board.execute(
                 %Commands.RunFailed{task_id: active_review["id"], run_id: active_run["id"], reason: :test_cleanup},
                 actor: :system,
                 expected_revision: active_review["revision"],
                 idempotency_key: BoardFactory.unique("cleanup")
               )
    end

    test "rejects a plain human MoveTask from Human Review to Rework" do
      {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Feedback bypass")})
      human_review = BoardFactory.advance_to_human_review(created)

      assert {:error, :feedback_required} =
               Board.execute(%Commands.MoveTask{task_id: human_review["id"], column_id: "rework"},
                 actor: :human,
                 expected_revision: human_review["revision"],
                 idempotency_key: BoardFactory.unique("bypass")
               )

      # System force moves remain available as a recovery escape hatch.
      assert {:ok, %{"task" => forced}} =
               Board.execute(%Commands.MoveTask{task_id: human_review["id"], column_id: "rework", force: true},
                 actor: :system,
                 expected_revision: human_review["revision"],
                 idempotency_key: BoardFactory.unique("force-bypass")
               )

      assert forced["column_id"] == "rework"
      assert forced["metadata"]["human_feedback_pending"] == nil
    end

    test "pending feedback survives failed and blocked rework and is consumed by a successful one" do
      {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Feedback lifecycle")})
      human_review = BoardFactory.advance_to_human_review(created)

      assert {:ok, %{"task" => rework}} = submit_feedback(human_review, "Keep the cache bounded")
      assert length(pending_feedback(rework["id"])) == 1

      # A failed rework run retains the pending feedback.
      assert {:ok, %{"task" => claimed, "run" => run}} = claim_run(rework)

      assert {:ok, %{"task" => blocked}} =
               Board.execute(
                 %Commands.RunFailed{task_id: claimed["id"], run_id: run["id"], reason: :boom},
                 actor: :system,
                 expected_revision: claimed["revision"],
                 idempotency_key: BoardFactory.unique("fail")
               )

      assert blocked["column_id"] == "blocked"
      assert length(pending_feedback(blocked["id"])) == 1

      assert {:ok, %{"task" => resumed}} = resume_task(blocked)
      assert resumed["column_id"] == "rework"

      # A rework run finishing outside Blocked consumes the pending feedback.
      assert {:ok, %{"task" => reclaimed, "run" => second_run}} = claim_run(resumed)

      assert {:ok, %{"task" => reviewed}} =
               Board.execute(%Commands.MoveTask{task_id: reclaimed["id"], column_id: "automated_review"},
                 actor: %{type: :agent, identity: second_run["id"]},
                 expected_revision: reclaimed["revision"],
                 idempotency_key: BoardFactory.unique("review")
               )

      assert {:ok, %{"task" => finished}} = finish_run(reviewed, second_run)
      assert finished["column_id"] == "automated_review"
      assert pending_feedback(finished["id"]) == nil
    end

    test "pending feedback survives a stopped rework run" do
      {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Feedback stopped")})
      human_review = BoardFactory.advance_to_human_review(created)

      assert {:ok, %{"task" => rework}} = submit_feedback(human_review, "Document the trade-off")
      assert {:ok, %{"task" => claimed, "run" => run}} = claim_run(rework)

      assert {:ok, %{"task" => stopping}} =
               Board.execute(%Commands.MoveTask{task_id: claimed["id"], column_id: "cancelled"},
                 actor: :human,
                 expected_revision: claimed["revision"],
                 idempotency_key: BoardFactory.unique("stop")
               )

      assert stopping["runtime_state"] == "stopping"

      assert {:ok, %{"task" => cancelled}} = finish_run(stopping, run)
      assert cancelled["column_id"] == "cancelled"
      assert length(pending_feedback(cancelled["id"])) == 1
    end
  end

  defp submit_feedback(task, feedback) do
    Board.execute(%Commands.SubmitFeedback{task_id: task["id"], feedback: feedback},
      actor: %{type: :human, identity: "board-ui"},
      expected_revision: task["revision"],
      idempotency_key: BoardFactory.unique("feedback")
    )
  end

  defp claim_run(task) do
    Board.execute(%Commands.ClaimRun{task_id: task["id"]},
      actor: :system,
      expected_revision: task["revision"],
      idempotency_key: BoardFactory.unique("claim")
    )
  end

  defp finish_run(task, run) do
    Board.execute(
      %Commands.RunFinished{task_id: task["id"], run_id: run["id"], outcome: %{}, stats: nil},
      actor: :system,
      expected_revision: task["revision"],
      idempotency_key: BoardFactory.unique("finish")
    )
  end

  defp resume_task(task) do
    Board.execute(%Commands.ResumeTask{task_id: task["id"]},
      actor: :human,
      expected_revision: task["revision"],
      idempotency_key: BoardFactory.unique("resume")
    )
  end

  defp pending_feedback(task_id) do
    {:ok, task} = Board.task(task_id)
    task.metadata["human_feedback_pending"]
  end
end
