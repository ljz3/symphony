defmodule SymphonyElixir.PromptBuilderTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Board
  alias SymphonyElixir.Board.Commands
  alias SymphonyElixir.BoardFactory
  alias SymphonyElixir.PromptBuilder

  test "composes the hard runner contract, base, context, and frozen stage in order" do
    {created, _} = BoardFactory.create_task(%{title: BoardFactory.unique("Prompt")})
    {todo, _} = BoardFactory.move(created, "todo")

    {:ok, %{"task" => claimed, "run" => run}} =
      Board.execute(%Commands.ClaimRun{task_id: todo["id"]},
        actor: :system,
        expected_revision: todo["revision"],
        idempotency_key: BoardFactory.unique("claim")
      )

    {:ok, task} = Board.task(claimed["id"])
    prompt = PromptBuilder.build_prompt(task, run)

    assert prompt =~ "# Symphony runner contract"
    assert prompt =~ "unattended Symphony engineering agent"
    assert prompt =~ task.identifier
    assert prompt =~ "Implement the task end to end"
    assert index(prompt, "runner contract") < index(prompt, "unattended Symphony")
    assert index(prompt, "unattended Symphony") < index(prompt, task.identifier)
    assert index(prompt, task.identifier) < index(prompt, "Implement the task")

    workpad = PromptBuilder.render_workpad(task, run)
    assert workpad =~ "Implementation workpad"
    assert workpad =~ task.identifier
    assert PromptBuilder.continuation_prompt(2, 3) =~ "turn 2 of 3"
    assert PromptBuilder.runner_contract() =~ "task worktree"

    Board.execute(%Commands.RunFailed{task_id: task.id, run_id: run["id"], reason: :test_complete},
      actor: :system,
      expected_revision: task.revision,
      idempotency_key: BoardFactory.unique("cleanup")
    )
  end

  test "exposes completed prior-run stage and workpad invocation metadata" do
    {created, _} = BoardFactory.create_task(%{title: BoardFactory.unique("Prompt handoff")})
    {todo, _} = BoardFactory.move(created, "todo")

    {:ok, %{"task" => implementation_task, "run" => implementation_run}} =
      Board.execute(%Commands.ClaimRun{task_id: todo["id"]},
        actor: :system,
        expected_revision: todo["revision"],
        idempotency_key: BoardFactory.unique("claim")
      )

    :ok = Board.write_workpad(implementation_run["id"], 3, "handoff evidence")

    {:ok, %{"task" => review_ready}} =
      Board.execute(%Commands.MoveTask{task_id: implementation_task["id"], column_id: "automated_review"},
        actor: %{type: :agent, identity: implementation_run["id"]},
        expected_revision: implementation_task["revision"],
        idempotency_key: BoardFactory.unique("move")
      )

    {:ok, %{"task" => finished_task, "run" => completed_run}} =
      Board.execute(%Commands.RunFinished{task_id: review_ready["id"], run_id: implementation_run["id"], outcome: %{}},
        actor: :system,
        expected_revision: review_ready["revision"],
        idempotency_key: BoardFactory.unique("finish")
      )

    {:ok, %{"task" => claimed_review, "run" => review_run}} =
      Board.execute(%Commands.ClaimRun{task_id: finished_task["id"]},
        actor: :system,
        expected_revision: finished_task["revision"],
        idempotency_key: BoardFactory.unique("review-claim")
      )

    on_exit(fn -> cleanup_active_run(claimed_review["id"], review_run["id"]) end)

    context = """
    {% for handoff in prior_handoffs %}
    handoff={{ handoff.run_id }}:{{ handoff.stage_id }}:{{ handoff.status }}
    {% for workpad in handoff.workpads %}workpad={{ workpad.invocation }}:{{ workpad.updated_at }}{% endfor %}
    {% endfor %}
    """

    review_run = put_in(review_run, ["frozen_bundle", "context_prompt"], context)
    {:ok, task} = Board.task(claimed_review["id"])
    prompt = PromptBuilder.build_prompt(task, review_run)

    assert prompt =~ "handoff=#{completed_run["id"]}:implementation:completed"
    assert prompt =~ "workpad=3:"

    Board.execute(%Commands.RunFailed{task_id: task.id, run_id: review_run["id"], reason: :test_complete},
      actor: :system,
      expected_revision: task.revision,
      idempotency_key: BoardFactory.unique("cleanup")
    )
  end

  test "exposes failed and stopped prior-run workpads with terminal status metadata" do
    Enum.each(["failed", "stopped"], fn status ->
      {task, current_run, terminal_run} = terminal_handoff_fixture(status)

      context = """
      {% for handoff in prior_handoffs %}
      handoff={{ handoff.run_id }}:{{ handoff.status }}
      {% for workpad in handoff.workpads %}workpad={{ workpad.invocation }}:{{ workpad.published }}{% endfor %}
      {% endfor %}
      """

      current_run = put_in(current_run, ["frozen_bundle", "context_prompt"], context)
      prompt = PromptBuilder.build_prompt(task, current_run)

      assert prompt =~ "handoff=#{terminal_run["id"]}:#{status}"
      assert prompt =~ "workpad=2:false"
      cleanup_active_run(task.id, current_run["id"])
    end)
  end

  defp index(string, pattern), do: :binary.match(string, pattern) |> elem(0)

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

  defp terminal_handoff_fixture(status) do
    {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("#{status} handoff")})
    {todo, _result} = BoardFactory.move(created, "todo")

    {:ok, %{"task" => prior_task, "run" => prior_run}} =
      Board.execute(%Commands.ClaimRun{task_id: todo["id"]},
        actor: :system,
        expected_revision: todo["revision"],
        idempotency_key: BoardFactory.unique("terminal-handoff-claim")
      )

    :ok = Board.write_workpad(prior_run["id"], 2, "#{status} handoff evidence")

    terminal_task =
      case status do
        "failed" ->
          {:ok, %{"task" => blocked}} =
            Board.execute(%Commands.RunFailed{task_id: prior_task["id"], run_id: prior_run["id"], reason: :test},
              actor: :system,
              expected_revision: prior_task["revision"],
              idempotency_key: BoardFactory.unique("handoff-failed")
            )

          blocked

        "stopped" ->
          {:ok, %{"task" => stopping}} =
            Board.execute(%Commands.MoveTask{task_id: prior_task["id"], column_id: "cancelled"},
              actor: :human,
              expected_revision: prior_task["revision"],
              idempotency_key: BoardFactory.unique("handoff-stop")
            )

          {:ok, %{"task" => cancelled}} =
            Board.execute(%Commands.RunFinished{task_id: stopping["id"], run_id: prior_run["id"], outcome: %{}},
              actor: :system,
              expected_revision: stopping["revision"],
              idempotency_key: BoardFactory.unique("handoff-stopped")
            )

          cancelled
      end

    {:ok, %{"task" => resumed}} =
      if status == "failed" do
        Board.execute(%Commands.ResumeTask{task_id: terminal_task["id"]},
          actor: :human,
          expected_revision: terminal_task["revision"],
          idempotency_key: BoardFactory.unique("handoff-resume-failed")
        )
      else
        Board.execute(%Commands.MoveTask{task_id: terminal_task["id"], column_id: "todo", force: true},
          actor: :system,
          expected_revision: terminal_task["revision"],
          idempotency_key: BoardFactory.unique("handoff-resume-stopped")
        )
      end

    {:ok, %{"task" => current, "run" => current_run}} =
      Board.execute(%Commands.ClaimRun{task_id: resumed["id"]},
        actor: :system,
        expected_revision: resumed["revision"],
        idempotency_key: BoardFactory.unique("terminal-handoff-current")
      )

    {:ok, task} = Board.task(current["id"])
    {:ok, terminal_run} = Board.run(prior_run["id"])
    {task, current_run, terminal_run}
  end
end
