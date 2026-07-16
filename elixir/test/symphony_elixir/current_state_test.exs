defmodule SymphonyElixir.CurrentStateTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Board, BoardFactory, Config, CurrentState, Task}

  test "projects only the exact current-state allowlist and omits nils" do
    sentinel = "SECRET-HISTORY-SENTINEL"
    {dependency, _key} = BoardFactory.create_task(%{title: "Dependency title", brief: sentinel})
    {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Current state")})
    {todo, _result} = BoardFactory.move(created, "todo")
    {:ok, %Task{} = task} = Board.task(todo["id"])

    criterion =
      task.acceptance_criteria
      |> hd()
      |> Map.put("completed", true)
      |> Map.put("evidence", [%{"command" => "mix test", "result" => "passed"}])
      |> Map.put("evidence_history", [%{"raw" => sentinel}])

    task = %Task{
      task
      | acceptance_criteria: [criterion],
        dependencies: [dependency["id"]],
        runtime_state: "running",
        active_run_id: "run-current",
        source: %{
          "head_sha" => String.duplicate("a", 40),
          "base_sha" => String.duplicate("b", 40),
          "clean" => true,
          "recorded_at" => "2026-01-01T00:00:00Z",
          "raw" => sentinel
        },
        github: %{
          "number" => 42,
          "url" => "https://github.example/pull/42",
          "state" => "open",
          "draft" => false,
          "head_sha" => String.duplicate("a", 40),
          "ready" => %{"completed" => true, "raw" => sentinel},
          "merged" => %{
            "merged" => false,
            "merge_sha" => nil,
            "merge_reachable" => false,
            "raw" => sentinel
          },
          "raw" => sentinel
        },
        metadata: %{"raw" => sentinel}
    }

    run = %{
      "id" => "run-current",
      "task_id" => task.id,
      "stage_id" => "implementation",
      "status" => "running",
      "model" => "gpt-5.5",
      "effort" => "xhigh",
      "worker_host" => nil,
      "claimed_at" => "2026-01-01T00:00:00Z",
      "started_at" => "2026-01-01T00:00:01Z",
      "updated_at" => "2026-01-01T00:00:02Z",
      "frozen_bundle" => %{"raw" => sentinel},
      "invocations" => [%{"raw" => sentinel}],
      "outcome" => %{"raw" => sentinel}
    }

    projection = CurrentState.project(task, run, Config.bundle!())
    encoded = Jason.encode!(projection)

    assert Map.keys(projection) |> Enum.sort() ==
             ~w(allowed_transitions criteria dependencies github run source task)

    assert Map.keys(projection["task"]) |> Enum.sort() ==
             ~w(branch brief column_id id identifier priority revision title type)

    assert Map.keys(projection["run"]) |> Enum.sort() ==
             ~w(claimed_at effort id model stage_id started_at status updated_at)

    assert Map.keys(projection["source"]) |> Enum.sort() ==
             ~w(base_sha clean head_sha)

    assert Map.keys(projection["github"]) |> Enum.sort() ==
             ~w(draft head_sha merged number reachable ready state url)

    assert projection["criteria"] == [
             %{
               "id" => criterion["id"],
               "text" => criterion["text"],
               "completed" => true,
               "evidence" => [%{"command" => "mix test", "result" => "passed"}]
             }
           ]

    assert projection["dependencies"] == [
             %{
               "id" => dependency["id"],
               "identifier" => dependency["identifier"],
               "title" => "Dependency title",
               "column_id" => "backlog",
               "satisfied" => false
             }
           ]

    assert Enum.all?(projection["allowed_transitions"], fn transition ->
             Map.keys(transition) |> Enum.sort() == ~w(id name role)
           end)

    refute encoded =~ sentinel
    refute encoded =~ "frozen_bundle"
    refute encoded =~ "evidence_history"
    refute encoded =~ "invocations"
    refute encoded =~ "metadata"
    refute encoded =~ "runtime_state"
    refute encoded =~ "desired_column_id"
    refute encoded =~ "recorded_at"
  end

  test "includes only explicit current block and preflight fields when present" do
    {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Optional state")})
    {:ok, %Task{} = task} = Board.task(created["id"])

    task = %Task{
      task
      | blocked_from_column_id: "in_progress",
        desired_column_id: "cancelled",
        metadata: %{
          "blocked_reason" => "Concrete blocker",
          "review_attestation" => %{
            "verdict" => "pass",
            "reviewed_head_sha" => String.duplicate("c", 40),
            "raw" => "do-not-copy"
          }
        }
    }

    run = %{
      "id" => "run-optional",
      "stage_id" => "implementation",
      "status" => "running",
      "current_job" => %{
        "job_id" => "job-current",
        "job" => "validation",
        "status" => "running",
        "started_at" => "2026-01-01T00:00:00Z",
        "output" => "must-not-leak"
      }
    }

    preflight = %{
      task_id: task.id,
      status: :failed,
      reason: "Xcode unavailable",
      completed_at: "2026-01-01T00:00:00Z",
      next_retry_at: "2026-01-01T00:01:00Z",
      workspace_path: "/private/secret"
    }

    projection =
      CurrentState.project(task, run, Config.bundle!(), preflights: [preflight])

    assert projection["task"]["block"] == %{
             "from_column_id" => "in_progress",
             "reason" => "Concrete blocker"
           }

    assert projection["preflight"] == %{
             "status" => "failed",
             "reason" => "Xcode unavailable",
             "completed_at" => "2026-01-01T00:00:00Z",
             "next_retry_at" => "2026-01-01T00:01:00Z"
           }

    refute Map.has_key?(projection["task"], "desired_column_id")
    refute Map.has_key?(projection, "job")
    refute Map.has_key?(projection, "review_attestation")

    encoded = Jason.encode!(projection)
    refute encoded =~ "/private/secret"
    refute encoded =~ "must-not-leak"
    refute encoded =~ "do-not-copy"
    refute encoded =~ "reviewed_head_sha"
  end
end
