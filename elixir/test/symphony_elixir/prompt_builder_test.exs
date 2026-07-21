defmodule SymphonyElixir.PromptBuilderTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.Board
  alias SymphonyElixir.Board.{Commands, Projection}
  alias SymphonyElixir.BoardFactory
  alias SymphonyElixir.{PromptBuilder, Repo}

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
    continuation = PromptBuilder.continuation_prompt(2)
    assert continuation =~ "same run and agent session"
    refute continuation =~ "turn 2 of"
    refute continuation =~ "maximum"
    assert PromptBuilder.runner_contract() =~ "task worktree"

    Board.execute(%Commands.RunFailed{task_id: task.id, run_id: run["id"], reason: :test_complete},
      actor: :system,
      expected_revision: task.revision,
      idempotency_key: BoardFactory.unique("cleanup")
    )
  end

  test "templates receive only stage identity and cannot inspect the frozen stage contract" do
    {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Minimal stage")})
    {todo, _result} = BoardFactory.move(created, "todo")

    {:ok, %{"task" => claimed, "run" => run}} =
      Board.execute(%Commands.ClaimRun{task_id: todo["id"]},
        actor: :system,
        expected_revision: todo["revision"],
        idempotency_key: BoardFactory.unique("minimal-stage-claim")
      )

    on_exit(fn -> cleanup_active_run(claimed["id"], run["id"]) end)

    sentinel = "FROZEN-STAGE-SECRET"

    frozen_stage =
      run["frozen_bundle"]["stage"]
      |> Map.put("workpad_template", sentinel)
      |> Map.put("prompt_path", sentinel)
      |> Map.put("workpad_template_path", sentinel)
      |> Map.put("allowed", [[sentinel, "model", "high"]])

    safe_run =
      run
      |> put_in(["frozen_bundle", "stage"], frozen_stage)
      |> put_in(["frozen_bundle", "context_prompt"], "stage={{ stage }} id={{ stage.id }}")

    {:ok, task} = Board.task(claimed["id"])
    prompt = PromptBuilder.build_prompt(task, safe_run)

    assert prompt =~ "id=implementation"
    refute prompt =~ sentinel

    for field <- ~w(prompt prompt_path workpad_template workpad_template_path allowed) do
      forbidden_run = put_in(run, ["frozen_bundle", "context_prompt"], "{{ stage.#{field} }}")

      assert_raise RuntimeError, ~r/context prompt render failed/, fn ->
        PromptBuilder.build_prompt(task, forbidden_run)
      end
    end
  end

  test "injects exactly one latest meaningful workpad body without prior-run lists" do
    {created, _} = BoardFactory.create_task(%{title: BoardFactory.unique("Prompt handoff")})
    {todo, _} = BoardFactory.move(created, "todo")

    {:ok, %{"task" => implementation_task, "run" => implementation_run}} =
      Board.execute(%Commands.ClaimRun{task_id: todo["id"]},
        actor: :system,
        expected_revision: todo["revision"],
        idempotency_key: BoardFactory.unique("claim")
      )

    :ok = Board.write_workpad(implementation_run["id"], 3, "older-handoff-body")

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

    :ok = Board.write_workpad(review_run["id"], 4, "only-latest-handoff-body")

    {:ok, %{"task" => rework_ready}} =
      Board.execute(%Commands.MoveTask{task_id: claimed_review["id"], column_id: "rework"},
        actor: %{type: :agent, identity: review_run["id"]},
        expected_revision: claimed_review["revision"],
        idempotency_key: BoardFactory.unique("review-move")
      )

    {:ok, %{"task" => rework_task, "run" => completed_review}} =
      Board.execute(%Commands.RunFinished{task_id: rework_ready["id"], run_id: review_run["id"], outcome: %{}},
        actor: :system,
        expected_revision: rework_ready["revision"],
        idempotency_key: BoardFactory.unique("review-finish")
      )

    {:ok, %{"task" => claimed_rework, "run" => rework_run}} =
      Board.execute(%Commands.ClaimRun{task_id: rework_task["id"]},
        actor: :system,
        expected_revision: rework_task["revision"],
        idempotency_key: BoardFactory.unique("rework-claim")
      )

    on_exit(fn -> cleanup_active_run(claimed_rework["id"], rework_run["id"]) end)

    context = """
    {% if latest_workpad %}
    latest={{ latest_workpad.run_id }}:{{ latest_workpad.stage_id }}:{{ latest_workpad.status }}:{{ latest_workpad.invocation }}
    {{ latest_workpad.content }}
    {% endif %}
    """

    rework_run = put_in(rework_run, ["frozen_bundle", "context_prompt"], context)
    {:ok, task} = Board.task(claimed_rework["id"])
    prompt = PromptBuilder.build_prompt(task, rework_run)

    assert completed_run["status"] == "completed"
    assert prompt =~ "latest=#{completed_review["id"]}:automated_review:completed:4"
    assert length(String.split(prompt, "only-latest-handoff-body")) == 2
    refute prompt =~ "older-handoff-body"
    refute prompt =~ "prior_handoffs"

    Board.execute(%Commands.RunFailed{task_id: task.id, run_id: rework_run["id"], reason: :test_complete},
      actor: :system,
      expected_revision: task.revision,
      idempotency_key: BoardFactory.unique("cleanup")
    )
  end

  test "injects failed and stopped terminal workpads as the single latest body" do
    Enum.each(["failed", "stopped"], fn status ->
      {task, current_run, terminal_run} = terminal_handoff_fixture(status)

      context = """
      {% if latest_workpad %}
      latest={{ latest_workpad.run_id }}:{{ latest_workpad.status }}:{{ latest_workpad.invocation }}
      {{ latest_workpad.content }}
      {% endif %}
      """

      current_run = put_in(current_run, ["frozen_bundle", "context_prompt"], context)
      prompt = PromptBuilder.build_prompt(task, current_run)

      assert prompt =~ "latest=#{terminal_run["id"]}:#{status}:2"
      assert length(String.split(prompt, "#{status} handoff evidence")) == 2
      cleanup_active_run(task.id, current_run["id"])
    end)
  end

  test "historical run volume cannot change prompt output beyond the one selected workpad" do
    {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Bounded prompt history")})
    {todo, _result} = BoardFactory.move(created, "todo")

    {:ok, %{"task" => claimed, "run" => current_run}} =
      Board.execute(%Commands.ClaimRun{task_id: todo["id"]},
        actor: :system,
        expected_revision: todo["revision"],
        idempotency_key: BoardFactory.unique("bounded-history-claim")
      )

    selected_id = "selected-history-#{Ecto.UUID.generate()}"
    historical_ids = Enum.map(1..60, &"historical-#{&1}-#{Ecto.UUID.generate()}")
    run_ids = [selected_id | historical_ids]

    on_exit(fn ->
      cleanup_active_run(claimed["id"], current_run["id"])

      Enum.each(run_ids, fn run_id ->
        SQL.query!(Repo, "DELETE FROM board_workpads WHERE run_id = ?", [run_id])
        SQL.query!(Repo, "DELETE FROM board_runs WHERE id = ?", [run_id])
      end)
    end)

    insert_terminal_run(selected_id, claimed["id"], "2026-02-01T00:00:00Z", %{"outcome" => "selected"})

    assert :ok =
             Projection.put_workpad(%{
               run_id: selected_id,
               invocation: 7,
               content: "ONLY-SELECTED-WORKPAD",
               template_sha256: nil,
               updated_at: "2026-02-01T00:00:00Z"
             })

    prompt_run = put_in(current_run, ["frozen_bundle", "context_prompt"], "latest={{ latest_workpad.content }}")
    {:ok, task} = Board.task(claimed["id"])
    baseline = PromptBuilder.build_prompt(task, prompt_run)

    Enum.with_index(historical_ids, 1)
    |> Enum.each(fn {run_id, index} ->
      sentinel = "HISTORICAL-SENTINEL-#{index}-" <> String.duplicate("x", 2_000)
      insert_terminal_run(run_id, claimed["id"], "2026-01-01T00:00:00Z", %{"outcome" => sentinel})

      assert :ok =
               Projection.put_workpad(%{
                 run_id: run_id,
                 invocation: index,
                 content: sentinel,
                 template_sha256: nil,
                 updated_at: "2026-01-01T00:00:00Z"
               })
    end)

    after_history = PromptBuilder.build_prompt(task, prompt_run)

    assert after_history == baseline
    assert length(String.split(after_history, "ONLY-SELECTED-WORKPAD")) == 2
    refute after_history =~ "HISTORICAL-SENTINEL"
  end

  test "rework prompts render only the feedback pending for the current review cycle" do
    {created, _} = BoardFactory.create_task(%{title: BoardFactory.unique("Feedback cycle")})
    human_review = BoardFactory.advance_to_human_review(created)

    assert {:ok, %{"task" => rework_one}} =
             Board.execute(
               %Commands.SubmitFeedback{task_id: human_review["id"], feedback: "First-cycle feedback"},
               actor: %{type: :human, identity: "board-ui"},
               expected_revision: human_review["revision"],
               idempotency_key: BoardFactory.unique("feedback-one")
             )

    assert {:ok, %{"task" => claimed_one, "run" => run_one}} = claim_task(rework_one)
    assert run_one["stage_id"] == "rework"

    {:ok, task_one} = Board.task(claimed_one["id"])
    prompt_one = PromptBuilder.build_prompt(task_one, run_one)
    assert prompt_one =~ "Human review feedback pending for this rework"
    assert prompt_one =~ "First-cycle feedback"

    assert {:ok, %{"task" => reviewed_one}} =
             Board.execute(%Commands.MoveTask{task_id: claimed_one["id"], column_id: "automated_review"},
               actor: %{type: :agent, identity: run_one["id"]},
               expected_revision: claimed_one["revision"],
               idempotency_key: BoardFactory.unique("cycle-one-review")
             )

    assert {:ok, %{"task" => finished_one}} = finish_run(reviewed_one, run_one)
    assert finished_one["metadata"]["human_feedback_pending"] == nil

    # Second review cycle: claim the automated review column and return to Human Review.
    assert {:ok, %{"task" => claimed_two, "run" => run_two}} = claim_task(finished_one)

    assert {:ok, %{"task" => human_review_two}} =
             Board.execute(%Commands.MoveTask{task_id: claimed_two["id"], column_id: "human_review"},
               actor: %{type: :agent, identity: run_two["id"]},
               expected_revision: claimed_two["revision"],
               idempotency_key: BoardFactory.unique("cycle-two-human-review")
             )

    assert {:ok, %{"task" => finished_two}} = finish_run(human_review_two, run_two)

    assert {:ok, %{"task" => rework_two}} =
             Board.execute(
               %Commands.SubmitFeedback{task_id: finished_two["id"], feedback: "Second-cycle feedback"},
               actor: %{type: :human, identity: "board-ui"},
               expected_revision: finished_two["revision"],
               idempotency_key: BoardFactory.unique("feedback-two")
             )

    assert {:ok, %{"task" => claimed_three, "run" => run_three}} = claim_task(rework_two)

    {:ok, task_three} = Board.task(claimed_three["id"])
    prompt_three = PromptBuilder.build_prompt(task_three, run_three)
    assert prompt_three =~ "Second-cycle feedback"
    refute prompt_three =~ "First-cycle feedback"

    cleanup_active_run(claimed_three["id"], run_three["id"])
  end

  test "rework prompt renders cleanly without pending human feedback" do
    {created, _} = BoardFactory.create_task(%{title: BoardFactory.unique("No feedback rework")})
    human_review = BoardFactory.advance_to_human_review(created)
    {rework, _result} = BoardFactory.move(human_review, "rework")

    assert {:ok, %{"task" => claimed, "run" => run}} = claim_task(rework)

    {:ok, task} = Board.task(claimed["id"])
    prompt = PromptBuilder.build_prompt(task, run)
    assert prompt =~ "Treat reviewer feedback as a fresh implementation pass"
    refute prompt =~ "Human review feedback pending"

    cleanup_active_run(claimed["id"], run["id"])
  end

  defp claim_task(task) do
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

  defp insert_terminal_run(id, task_id, finished_at, extra) do
    run =
      Map.merge(
        %{
          "id" => id,
          "task_id" => task_id,
          "stage_id" => "implementation",
          "status" => "failed",
          "finished_at" => finished_at,
          "updated_at" => finished_at
        },
        extra
      )

    SQL.query!(
      Repo,
      "INSERT INTO board_runs(id, task_id, stage_id, status, run_json, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
      [id, task_id, "implementation", "failed", Jason.encode!(run), finished_at]
    )
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
