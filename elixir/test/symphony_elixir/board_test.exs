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

  test "an active agent can persist a scoped GitHub saga outcome" do
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

    assert {:ok, _result} =
             Board.execute(
               %Commands.RunFailed{
                 task_id: recorded["id"],
                 run_id: run["id"],
                 reason: "test cleanup"
               },
               actor: :system,
               expected_revision: recorded["revision"],
               idempotency_key: BoardFactory.unique("cleanup")
             )
  end

  test "terminal run stats are canonical, replayable, and clear live telemetry" do
    assert Storage.migration_version() == 2

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

    assert {:ok, %{"run" => recovered_creator}} =
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
  end
end
