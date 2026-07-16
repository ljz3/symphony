defmodule SymphonyElixir.DynamicToolTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Board
  alias SymphonyElixir.Board.Commands
  alias SymphonyElixir.BoardFactory
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Workflow

  test "tools are scoped to one active task/run and use call IDs for idempotency" do
    {created, _} = BoardFactory.create_task(%{title: BoardFactory.unique("Tool")})
    {todo, _} = BoardFactory.move(created, "todo")

    {:ok, %{"task" => claimed, "run" => run}} =
      Board.execute(%Commands.ClaimRun{task_id: todo["id"]},
        actor: :system,
        expected_revision: todo["revision"],
        idempotency_key: BoardFactory.unique("claim")
      )

    opts = [task_id: claimed["id"], run_id: run["id"], call_id: "context-call"]

    assert %{"success" => true, "output" => context_json} =
             DynamicTool.execute("symphony_task_context", %{}, opts)

    assert Jason.decode!(context_json)["task"]["id"] == claimed["id"]

    assert %{"success" => true} =
             DynamicTool.execute(
               "symphony_workpad_write",
               %{"content" => "# Workpad\n\nEvidence."},
               Keyword.put(opts, :call_id, "write-call")
             )

    assert %{"success" => true, "output" => workpad_json} =
             DynamicTool.execute("symphony_workpad_read", %{}, Keyword.put(opts, :call_id, "read-call"))

    assert Jason.decode!(workpad_json)["content"] =~ "Evidence"

    criterion_id = claimed["acceptance_criteria"] |> hd() |> Map.fetch!("id")

    complete_args = %{
      "criterion_id" => criterion_id,
      "evidence" => [%{"command" => "mix test", "result" => "passed"}],
      "expected_revision" => claimed["revision"]
    }

    complete_opts = Keyword.put(opts, :call_id, "acceptance-call")

    assert %{"success" => true, "output" => first_result} =
             DynamicTool.execute("symphony_acceptance_complete", complete_args, complete_opts)

    assert %{"success" => true, "output" => ^first_result} =
             DynamicTool.execute("symphony_acceptance_complete", complete_args, complete_opts)

    {:ok, refreshed} = Board.task(claimed["id"])

    blocked_args = %{
      "column_id" => "blocked",
      "reason" => "External dependency unavailable",
      "expected_revision" => refreshed.revision
    }

    assert %{"success" => true} =
             DynamicTool.execute(
               "symphony_task_transition",
               blocked_args,
               Keyword.put(opts, :call_id, "block-call")
             )

    assert {:ok, %{"status" => "failed"}} = Board.run(run["id"])

    {other, _} = BoardFactory.create_task(%{title: BoardFactory.unique("Other")})

    assert %{"success" => false} =
             DynamicTool.execute(
               "symphony_task_context",
               %{},
               task_id: other["id"],
               run_id: run["id"],
               call_id: "cross-task"
             )
  end

  test "advertises only strict Symphony task tools" do
    names = Enum.map(DynamicTool.tool_specs(), & &1["name"])

    assert names == [
             "symphony_task_context",
             "symphony_workpad_read",
             "symphony_workpad_write",
             "symphony_acceptance_complete",
             "symphony_task_transition",
             "symphony_task_create"
           ]

    refute "linear_graphql" in names
    assert Enum.all?(DynamicTool.tool_specs(), &(&1["inputSchema"]["additionalProperties"] == false))
    assert get_in(Enum.find(DynamicTool.tool_specs(), &(&1["name"] == "symphony_workpad_read")), ["inputSchema", "properties", "run_id", "type"]) == "string"

    create = Enum.find(DynamicTool.tool_specs(), &(&1["name"] == "symphony_task_create"))
    refute "project_id" in create["inputSchema"]["required"]
    refute Map.has_key?(create["inputSchema"]["properties"], "project_id")
  end

  test "derives the blocking job enum only from the run's frozen definitions" do
    run = %{
      "frozen_bundle" => %{
        "jobs" => %{
          "full_validation" => %{
            "id" => "full_validation",
            "executable" => "./scripts/validate.sh",
            "arguments" => ["full", "--run-id", "$SYMPHONY_JOB_ID"],
            "passthrough_arguments" => "forbidden",
            "environment" => %{}
          },
          "targeted_validation" => %{
            "id" => "targeted_validation",
            "executable" => "./scripts/validate.sh",
            "arguments" => ["targeted", "--run-id", "$SYMPHONY_JOB_ID"],
            "passthrough_arguments" => "required",
            "environment" => %{}
          }
        }
      }
    }

    spec = Enum.find(DynamicTool.tool_specs(run), &(&1["name"] == "symphony_job_run"))
    assert get_in(spec, ["inputSchema", "properties", "job", "enum"]) == ["full_validation", "targeted_validation"]
    assert get_in(spec, ["inputSchema", "required"]) == ["job", "arguments"]

    refute Enum.any?(DynamicTool.tool_specs(%{"frozen_bundle" => %{"jobs" => %{}}}), fn tool ->
             tool["name"] == "symphony_job_run"
           end)
  end

  test "executes only the active run's frozen job and replays duplicate call delivery" do
    original_workflow = Workflow.workflow_file_path()
    source = BoardFactory.workflow_source()

    File.write!(
      source.workflow,
      File.read!(source.workflow) <>
        """

        jobs:
          identity:
            executable: /usr/bin/env
            arguments: [printf, "%s|%s|%s", $SYMPHONY_JOB_ID]
            passthrough_arguments: required
            environment:
              FROZEN_JOB_VALUE: original
        """
    )

    Workflow.set_workflow_file_path(source.workflow)
    assert :ok = Workflow.Store.force_reload()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow)
      Workflow.Store.force_reload()
    end)

    {created, _} = BoardFactory.create_task(%{title: BoardFactory.unique("Frozen job")})
    {todo, _} = BoardFactory.move(created, "todo")
    {task, run} = claim(todo)

    assert get_in(run, ["frozen_bundle", "jobs", "identity", "environment", "FROZEN_JOB_VALUE"]) ==
             "original"

    assert {:ok, %{"task" => running_task, "run" => running_run}} =
             Board.execute(
               %Commands.RunStarted{
                 task_id: task["id"],
                 run_id: run["id"],
                 session_id: "job-test-session",
                 workspace_path: source.root
               },
               actor: :system,
               expected_revision: task["revision"],
               idempotency_key: BoardFactory.unique("job-start")
             )

    opts = [task_id: running_task["id"], run_id: running_run["id"], call_id: "job-call"]

    assert %{"success" => true, "output" => first_json} =
             DynamicTool.execute(
               "symphony_job_run",
               %{"job" => "identity", "arguments" => ["FROZEN_JOB_VALUE", "SYMPHONY_TASK_IDENTIFIER"]},
               opts
             )

    first = Jason.decode!(first_json)
    assert first["status"] == "completed"
    assert first["output"] == "#{first["job_id"]}|FROZEN_JOB_VALUE|SYMPHONY_TASK_IDENTIFIER"

    assert %{"success" => true, "output" => ^first_json} =
             DynamicTool.execute(
               "symphony_job_run",
               %{"job" => "identity", "arguments" => ["changed", "arguments"]},
               opts
             )

    cleanup_active_run(running_task["id"], running_run["id"])
  end

  test "mutation call IDs are idempotent within one run and independent across runs" do
    {first_created, _} = BoardFactory.create_task(%{title: BoardFactory.unique("First call namespace")})
    {first_todo, _} = BoardFactory.move(first_created, "todo")
    {first_task, first_run} = claim(first_todo)

    {second_created, _} = BoardFactory.create_task(%{title: BoardFactory.unique("Second call namespace")})
    {second_todo, _} = BoardFactory.move(second_created, "todo")
    {second_task, second_run} = claim(second_todo)

    on_exit(fn ->
      cleanup_active_run(first_task["id"], first_run["id"])
      cleanup_active_run(second_task["id"], second_run["id"])
    end)

    first_args = %{
      "criterion_id" => first_task["acceptance_criteria"] |> hd() |> Map.fetch!("id"),
      "evidence" => [%{"command" => "mix test", "result" => "first passed"}],
      "expected_revision" => first_task["revision"]
    }

    second_args = %{
      "criterion_id" => second_task["acceptance_criteria"] |> hd() |> Map.fetch!("id"),
      "evidence" => [%{"command" => "mix test", "result" => "second passed"}],
      "expected_revision" => second_task["revision"]
    }

    first_opts = [task_id: first_task["id"], run_id: first_run["id"], call_id: "1"]
    second_opts = [task_id: second_task["id"], run_id: second_run["id"], call_id: "1"]

    assert %{"success" => true, "output" => first_json} =
             DynamicTool.execute("symphony_acceptance_complete", first_args, first_opts)

    assert %{"success" => true, "output" => second_json} =
             DynamicTool.execute("symphony_acceptance_complete", second_args, second_opts)

    assert Jason.decode!(first_json)["task"]["id"] == first_task["id"]
    assert Jason.decode!(second_json)["task"]["id"] == second_task["id"]

    assert %{"success" => true, "output" => ^first_json} =
             DynamicTool.execute("symphony_acceptance_complete", first_args, first_opts)
  end

  test "reads completed same-task prior-run workpads without permitting cross-task access" do
    {created, _} = BoardFactory.create_task(%{title: BoardFactory.unique("Prior workpad")})
    {todo, _} = BoardFactory.move(created, "todo")
    {implementation_task, implementation_run} = claim(todo)
    :ok = Board.write_workpad(implementation_run["id"], 1, "implementation evidence")
    {review_ready, _completed_implementation} = finish_to(implementation_task, implementation_run, "automated_review")

    {review_task, review_run} = claim(review_ready)
    :ok = Board.write_workpad(review_run["id"], 1, "review finding one")
    :ok = Board.write_workpad(review_run["id"], 2, "review finding two")
    {rework_ready, completed_review} = finish_to(review_task, review_run, "rework")

    {rework_task, rework_run} = claim(rework_ready)
    :ok = Board.write_workpad(rework_run["id"], 1, "current rework")

    on_exit(fn -> cleanup_active_run(rework_task["id"], rework_run["id"]) end)

    opts = [task_id: rework_task["id"], run_id: rework_run["id"], call_id: "prior-read"]

    assert %{"success" => true, "output" => first_prior_json} =
             DynamicTool.execute(
               "symphony_workpad_read",
               %{"run_id" => completed_review["id"], "invocation" => 1},
               Keyword.put(opts, :call_id, "first-prior-read")
             )

    assert Jason.decode!(first_prior_json)["content"] == "review finding one"

    assert %{"success" => true, "output" => prior_json} =
             DynamicTool.execute(
               "symphony_workpad_read",
               %{"run_id" => completed_review["id"], "invocation" => 2},
               opts
             )

    prior = Jason.decode!(prior_json)
    assert prior["content"] == "review finding two"
    assert prior["run_id"] == completed_review["id"]
    assert prior["stage_id"] == "automated_review"
    assert prior["status"] == "completed"
    assert prior["invocation"] == 2

    assert %{"success" => true, "output" => current_json} =
             DynamicTool.execute("symphony_workpad_read", %{}, Keyword.put(opts, :call_id, "current-read"))

    assert Jason.decode!(current_json)["content"] == "current rework"

    {other_created, _} = BoardFactory.create_task(%{title: BoardFactory.unique("Other prior workpad")})
    {other_todo, _} = BoardFactory.move(other_created, "todo")
    {other_task, other_run} = claim(other_todo)
    :ok = Board.write_workpad(other_run["id"], 1, "cross-task secret")
    {_other_review, completed_other} = finish_to(other_task, other_run, "automated_review")

    assert %{"success" => false, "output" => cross_task_json} =
             DynamicTool.execute(
               "symphony_workpad_read",
               %{"run_id" => completed_other["id"], "invocation" => 1},
               Keyword.put(opts, :call_id, "cross-task-read")
             )

    refute cross_task_json =~ "cross-task secret"

    assert {:ok, _result} =
             Board.execute(
               %Commands.RunFailed{
                 task_id: rework_task["id"],
                 run_id: rework_run["id"],
                 reason: :test_complete
               },
               actor: :system,
               expected_revision: rework_task["revision"],
               idempotency_key: BoardFactory.unique("cleanup")
             )
  end

  test "reads failed and stopped same-task workpads while rejecting another active run" do
    Enum.each(["failed", "stopped"], fn status ->
      {current_task, current_run, prior_run} = terminal_prior_fixture(status)
      opts = [task_id: current_task["id"], run_id: current_run["id"]]

      assert %{"success" => true, "output" => json} =
               DynamicTool.execute(
                 "symphony_workpad_read",
                 %{"run_id" => prior_run["id"], "invocation" => 2},
                 Keyword.put(opts, :call_id, "#{status}-prior-read")
               )

      payload = Jason.decode!(json)
      assert payload["status"] == status
      assert payload["content"] == "#{status} terminal evidence"

      {other_created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Active secret")})
      {other_todo, _result} = BoardFactory.move(other_created, "todo")
      {other_task, other_run} = claim(other_todo)
      :ok = Board.write_workpad(other_run["id"], 1, "active cross-task secret")

      assert %{"success" => false, "output" => rejected} =
               DynamicTool.execute(
                 "symphony_workpad_read",
                 %{"run_id" => other_run["id"], "invocation" => 1},
                 Keyword.put(opts, :call_id, "#{status}-active-read")
               )

      refute rejected =~ "active cross-task secret"
      cleanup_active_run(other_task["id"], other_run["id"])
      cleanup_active_run(current_task["id"], current_run["id"])
    end)
  end

  test "a publish-only destination rejects the transition until publication succeeds" do
    original = Workflow.workflow_file_path()
    source = publish_only_workflow_source()
    :ok = Workflow.set_workflow_file_path(source.workflow)
    assert :ok = Workflow.Store.force_reload()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original)
      Workflow.Store.force_reload()
    end)

    {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Publish before merging")})
    {todo, _result} = BoardFactory.move(created, "todo")
    {implementation_task, implementation_run} = claim(todo)
    {review_ready, _completed} = finish_to(implementation_task, implementation_run, "automated_review")
    {review_task, review_run} = claim(review_ready)
    :ok = Board.write_workpad(review_run["id"], 1, "review workpad")

    opts = [task_id: review_task["id"], run_id: review_run["id"], call_id: "merge-transition"]
    parent = self()

    failing_publisher = fn _task, _worktree, _publisher_opts ->
      send(parent, :publication_attempted)
      {:error, :publication_failed}
    end

    assert %{"success" => false} =
             DynamicTool.execute(
               "symphony_task_transition",
               %{"column_id" => "merging", "expected_revision" => review_task["revision"]},
               Keyword.put(opts, :workpad_publisher, failing_publisher)
             )

    assert_receive :publication_attempted
    assert {:ok, unchanged} = Board.task(review_task["id"])
    assert unchanged.column_id == "automated_review"
    assert unchanged.active_run_id == review_run["id"]

    successful_publisher = fn _task, _worktree, _publisher_opts -> {:ok, "stable-publication"} end

    assert %{"success" => true} =
             DynamicTool.execute(
               "symphony_task_transition",
               %{"column_id" => "merging", "expected_revision" => unchanged.revision},
               opts
               |> Keyword.put(:call_id, "merge-transition-retry")
               |> Keyword.put(:workpad_publisher, successful_publisher)
             )

    assert {:ok, merged} = Board.task(review_task["id"])
    assert merged.column_id == "merging"
    cleanup_active_run(merged.id, review_run["id"])
  end

  defp claim(task) do
    {:ok, %{"task" => claimed, "run" => run}} =
      Board.execute(%Commands.ClaimRun{task_id: task["id"]},
        actor: :system,
        expected_revision: task["revision"],
        idempotency_key: BoardFactory.unique("claim")
      )

    {claimed, run}
  end

  defp finish_to(task, run, column_id) do
    {:ok, %{"task" => moved}} =
      Board.execute(%Commands.MoveTask{task_id: task["id"], column_id: column_id},
        actor: %{type: :agent, identity: run["id"]},
        expected_revision: task["revision"],
        idempotency_key: BoardFactory.unique("move")
      )

    {:ok, %{"task" => finished_task, "run" => finished_run}} =
      Board.execute(%Commands.RunFinished{task_id: task["id"], run_id: run["id"], outcome: %{}},
        actor: :system,
        expected_revision: moved["revision"],
        idempotency_key: BoardFactory.unique("finish")
      )

    {finished_task, finished_run}
  end

  defp terminal_prior_fixture(status) do
    {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("#{status} prior")})
    {todo, _result} = BoardFactory.move(created, "todo")
    {prior_task, prior_run} = claim(todo)
    :ok = Board.write_workpad(prior_run["id"], 2, "#{status} terminal evidence")

    terminal_task =
      case status do
        "failed" ->
          {:ok, %{"task" => blocked, "run" => %{"status" => "failed"}}} =
            Board.execute(%Commands.RunFailed{task_id: prior_task["id"], run_id: prior_run["id"], reason: :test},
              actor: :system,
              expected_revision: prior_task["revision"],
              idempotency_key: BoardFactory.unique("failed-prior")
            )

          blocked

        "stopped" ->
          {:ok, %{"task" => stopping}} =
            Board.execute(%Commands.MoveTask{task_id: prior_task["id"], column_id: "cancelled"},
              actor: :human,
              expected_revision: prior_task["revision"],
              idempotency_key: BoardFactory.unique("stop-prior")
            )

          {:ok, %{"task" => cancelled, "run" => %{"status" => "stopped"}}} =
            Board.execute(%Commands.RunFinished{task_id: stopping["id"], run_id: prior_run["id"], outcome: %{}},
              actor: :system,
              expected_revision: stopping["revision"],
              idempotency_key: BoardFactory.unique("finish-stopped-prior")
            )

          cancelled
      end

    {:ok, %{"task" => resumed}} =
      case status do
        "failed" ->
          Board.execute(%Commands.ResumeTask{task_id: terminal_task["id"]},
            actor: :human,
            expected_revision: terminal_task["revision"],
            idempotency_key: BoardFactory.unique("resume-failed-prior")
          )

        "stopped" ->
          Board.execute(%Commands.MoveTask{task_id: terminal_task["id"], column_id: "todo", force: true},
            actor: :system,
            expected_revision: terminal_task["revision"],
            idempotency_key: BoardFactory.unique("resume-stopped-prior")
          )
      end

    {current_task, current_run} = claim(resumed)
    {:ok, terminal_run} = Board.run(prior_run["id"])
    {current_task, current_run, terminal_run}
  end

  defp publish_only_workflow_source do
    source = BoardFactory.workflow_source()

    workflow =
      source.workflow
      |> File.read!()
      |> String.replace(
        "  - id: merging\n    name: Merging\n    role: dispatch\n    stage: merging",
        "  - id: merging\n    name: Merging\n    role: dispatch\n    stage: merging\n    publish_workpad: true"
      )
      |> String.replace(
        "    automated_review: [human_review, rework, blocked]",
        "    automated_review: [human_review, merging, rework, blocked]"
      )

    File.write!(source.workflow, workflow)
    source
  end

  defp cleanup_active_run(task_id, run_id) do
    case Board.task(task_id) do
      {:ok, %{active_run_id: ^run_id} = task} ->
        Board.execute(%Commands.RunFailed{task_id: task_id, run_id: run_id, reason: :test_cleanup},
          actor: :system,
          expected_revision: task.revision,
          idempotency_key: BoardFactory.unique("cleanup")
        )

      _ ->
        :ok
    end
  end
end
