defmodule SymphonyElixir.DynamicToolTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Board
  alias SymphonyElixir.Board.Commands
  alias SymphonyElixir.BoardFactory
  alias SymphonyElixir.Codex.DynamicTool

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
