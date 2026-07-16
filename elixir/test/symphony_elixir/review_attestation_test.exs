defmodule SymphonyElixir.ReviewAttestationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Board
  alias SymphonyElixir.Board.Commands
  alias SymphonyElixir.Board.Writer
  alias SymphonyElixir.BoardFactory
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Config
  alias SymphonyElixir.CurrentState
  alias SymphonyElixir.DeterministicMerge
  alias SymphonyElixir.ReviewAttestation
  alias SymphonyElixir.Task

  @head String.duplicate("a", 40)
  @changed String.duplicate("b", 40)

  test "acceptance fingerprint is canonical across criterion and map-key order" do
    first = %{
      "id" => "first",
      "text" => "First criterion",
      "completed" => true,
      "evidence" => [%{"result" => "pass", "details" => %{"count" => 1}}]
    }

    second = %{
      id: "second",
      text: "Second criterion",
      completed: true,
      evidence: [%{details: %{count: 2}, result: "pass"}]
    }

    fingerprint = ReviewAttestation.criteria_fingerprint([first, second])

    assert fingerprint == ReviewAttestation.criteria_fingerprint([second, first])

    refute fingerprint ==
             ReviewAttestation.criteria_fingerprint([
               first,
               put_in(second, [:evidence, Access.at(0), :details, :count], 3)
             ])
  end

  test "strict review tool records a canonical exact-head pass and replays idempotently" do
    {review_task, review_run} = active_review()
    args = pass_arguments(review_task)
    opts = review_opts(review_task, review_run, "review-pass")

    assert %{"success" => true, "output" => output} =
             DynamicTool.execute("symphony_review_complete", args, opts)

    assert %{"success" => true, "output" => ^output} =
             DynamicTool.execute("symphony_review_complete", args, opts)

    payload = Jason.decode!(output)
    assert Map.keys(payload) |> Enum.sort() == ["event_type", "run", "task"]
    assert payload["task"]["column_id"] == "merging"
    assert payload["run"] == %{"status" => "starting"}

    {:ok, attested} = Board.task(review_task["id"])
    assert attested.review_attestation["verdict"] == "pass"
    assert attested.review_attestation["reviewed_head_sha"] == @head
    assert attested.review_attestation["reviewer_identity"] == review_run["id"]
    assert attested.review_attestation["run_id"] == review_run["id"]
    assert attested.review_attestation["feedback_fingerprint"] == "feedback-v1"
    assert is_binary(attested.review_attestation["criteria_fingerprint"])
    refute Map.has_key?(attested.metadata, "review_attestation")

    [event] = Board.events(attested.id) |> Enum.filter(&(&1["type"] == "review_attestation_recorded"))
    assert get_in(event, ["payload", "task", "review_attestation", "verdict"]) == "pass"

    finish_run(attested, review_run)
    assert :ok = Writer.reload_history()
    assert {:ok, replayed} = Board.task(attested.id)
    assert replayed.review_attestation == attested.review_attestation
  end

  test "human acceptance-set removal replacement and addition invalidate an exact pass" do
    mutations = [
      removal: fn [first, _second] -> [first] end,
      replacement: fn [first, second] -> [%{first | "text" => "Replacement criterion"}, second] end,
      addition: fn criteria -> criteria ++ [%{"id" => Ecto.UUID.generate(), "text" => "Added criterion"}] end
    ]

    Enum.each(mutations, fn {_name, mutate} ->
      {review_task, review_run} = active_review(["Keep this criterion", "Change this criterion"])

      assert %{"success" => true} =
               DynamicTool.execute(
                 "symphony_review_complete",
                 pass_arguments(review_task),
                 review_opts(review_task, review_run, BoardFactory.unique("criteria-pass"))
               )

      {:ok, attested} = Board.task(review_task["id"])
      finished = finish_run(attested, review_run)

      criteria =
        finished["acceptance_criteria"]
        |> Enum.map(&Map.take(&1, ~w(id text)))
        |> mutate.()

      assert {:ok, %{"task" => updated}} =
               Board.execute(
                 %Commands.UpdateTask{
                   task_id: finished["id"],
                   attrs: %{acceptance_criteria: criteria}
                 },
                 actor: %{type: :human, identity: "criteria-editor"},
                 expected_revision: finished["revision"],
                 idempotency_key: BoardFactory.unique("criteria-change")
               )

      assert updated["column_id"] == "automated_review"
      assert is_nil(updated["review_attestation"])
      assert get_in(updated, ["merge_saga", "reason"]) == "acceptance_criteria_changed"
    end)
  end

  test "canonical acceptance evidence completion and reopening invalidate an exact pass" do
    commands = [
      fn task, criterion_id ->
        %Commands.CompleteAcceptance{
          task_id: task["id"],
          criterion_id: criterion_id,
          evidence: [%{"result" => "new evidence"}]
        }
      end,
      fn task, criterion_id ->
        %Commands.ReopenAcceptance{
          task_id: task["id"],
          criterion_id: criterion_id,
          reason: "require new evidence"
        }
      end
    ]

    Enum.each(commands, fn command ->
      {review_task, review_run} = active_review()

      assert %{"success" => true} =
               DynamicTool.execute(
                 "symphony_review_complete",
                 pass_arguments(review_task),
                 review_opts(review_task, review_run, BoardFactory.unique("criteria-evidence-pass"))
               )

      {:ok, attested} = Board.task(review_task["id"])
      finished = finish_run(attested, review_run)
      criterion_id = get_in(finished, ["acceptance_criteria", Access.at(0), "id"])

      assert {:ok, %{"task" => updated}} =
               Board.execute(command.(finished, criterion_id),
                 actor: %{type: :human, identity: "criteria-editor"},
                 expected_revision: finished["revision"],
                 idempotency_key: BoardFactory.unique("criteria-evidence-change")
               )

      assert updated["column_id"] == "automated_review"
      assert is_nil(updated["review_attestation"])
      assert get_in(updated, ["merge_saga", "reason"]) == "acceptance_criteria_changed"
    end)
  end

  test "same-head pull-request relink invalidates the attested pull-request identity" do
    {review_task, review_run} = active_review()

    assert %{"success" => true} =
             DynamicTool.execute(
               "symphony_review_complete",
               pass_arguments(review_task),
               review_opts(review_task, review_run, "pass-before-pr-relink")
             )

    {:ok, attested} = Board.task(review_task["id"])
    assert attested.review_attestation["pull_request_number"] == 1

    assert {:ok, %{"task" => relinked}} =
             Board.execute(
               %Commands.LinkPullRequest{
                 task_id: attested.id,
                 run_id: review_run["id"],
                 number: 2,
                 url: "https://github.test/pull/2",
                 head_sha: @head,
                 state: "open",
                 draft: false
               },
               actor: :system,
               expected_revision: attested.revision,
               idempotency_key: BoardFactory.unique("same-head-pr-relink")
             )

    assert relinked["column_id"] == "automated_review"
    assert is_nil(relinked["review_attestation"])
  end

  test "pass rejects stale source/PR heads while rework records only a rework verdict and permitted route" do
    {review_task, review_run} = active_review()

    stale = put_in(pass_arguments(review_task), ["reviewed_head_sha"], @changed)

    assert %{"success" => false, "output" => stale_error} =
             DynamicTool.execute(
               "symphony_review_complete",
               stale,
               review_opts(review_task, review_run, "stale-pass")
             )

    assert stale_error =~ "review_attestation_head_or_payload_invalid"

    rework = %{
      "expected_revision" => review_task["revision"],
      "verdict" => "rework",
      "reviewed_head_sha" => @head,
      "route" => "rework",
      "plan_policy" => %{"status" => "deviation", "summary" => "Plan evidence is incomplete."},
      "validation_evidence" => [%{"command" => "mix test", "result" => "failed", "exit_status" => 1}],
      "findings" => [%{"severity" => "high", "summary" => "Correctness regression"}]
    }

    assert %{"success" => true} =
             DynamicTool.execute(
               "symphony_review_complete",
               rework,
               review_opts(review_task, review_run, "review-rework")
             )

    assert {:ok, routed} = Board.task(review_task["id"])
    assert routed.column_id == "rework"
    assert routed.review_attestation["verdict"] == "rework"
    refute routed.review_attestation["verdict"] == "pass"
  end

  test "source and pull-request head mutations invalidate pass attestations canonically" do
    {review_task, review_run} = active_review()

    assert %{"success" => true} =
             DynamicTool.execute(
               "symphony_review_complete",
               pass_arguments(review_task),
               review_opts(review_task, review_run, "pass-before-source-change")
             )

    {:ok, attested} = Board.task(review_task["id"])
    finished = finish_run(attested, review_run)

    assert {:ok, %{"task" => changed}} =
             Board.execute(
               %Commands.RecordSourceHead{task_id: finished["id"], head_sha: @changed, clean: true},
               actor: :system,
               expected_revision: finished["revision"],
               idempotency_key: BoardFactory.unique("source-head-changed")
             )

    assert changed["column_id"] == "automated_review"
    assert is_nil(changed["review_attestation"])

    {second_task, second_run} = active_review()

    assert %{"success" => true} =
             DynamicTool.execute(
               "symphony_review_complete",
               pass_arguments(second_task),
               review_opts(second_task, second_run, "pass-before-pr-change")
             )

    {:ok, second_attested} = Board.task(second_task["id"])

    assert {:ok, %{"task" => pr_changed}} =
             Board.execute(
               %Commands.LinkPullRequest{
                 task_id: second_attested.id,
                 run_id: second_run["id"],
                 number: 1,
                 url: "https://github.test/pull/1",
                 head_sha: @changed,
                 state: "open",
                 draft: false
               },
               actor: :system,
               expected_revision: second_attested.revision,
               idempotency_key: BoardFactory.unique("pr-head-changed")
             )

    assert pr_changed["column_id"] == "automated_review"
    assert is_nil(pr_changed["review_attestation"])
    cleanup_active_run(second_attested.id, second_run["id"])
  end

  test "clean-update invalidation atomically records the pushed source and pull-request head" do
    {review_task, review_run} = active_review()

    assert %{"success" => true} =
             DynamicTool.execute(
               "symphony_review_complete",
               pass_arguments(review_task),
               review_opts(review_task, review_run, "pass-before-clean-update")
             )

    {:ok, attested} = Board.task(review_task["id"])
    finished = finish_run(attested, review_run)

    assert {:ok, %{"task" => invalidated}} =
             Board.execute(
               %Commands.InvalidateReviewAttestation{
                 task_id: finished["id"],
                 reason: "target branch merged into task branch; exact-head review required",
                 head_sha: @changed
               },
               actor: :system,
               expected_revision: finished["revision"],
               idempotency_key: BoardFactory.unique("clean-update-invalidation")
             )

    assert invalidated["column_id"] == "automated_review"
    assert invalidated["source"]["head_sha"] == @changed
    assert invalidated["github"]["head_sha"] == @changed
    assert is_nil(invalidated["review_attestation"])
  end

  test "CurrentState exposes only the deep review-attestation allowlist" do
    {review_task, review_run} = active_review()

    assert %{"success" => true} =
             DynamicTool.execute(
               "symphony_review_complete",
               pass_arguments(review_task),
               review_opts(review_task, review_run, "state-pass")
             )

    {:ok, %Task{} = task} = Board.task(review_task["id"])

    poisoned = %Task{
      task
      | review_attestation:
          task.review_attestation
          |> Map.put("raw", "SECRET-ATTESTATION")
          |> put_in(["plan_policy", "raw"], "SECRET-PLAN")
          |> update_in(["validation_evidence"], fn [item] -> [Map.put(item, "raw", "SECRET-EVIDENCE")] end)
          |> update_in(["findings"], fn findings -> findings ++ [%{"severity" => "note", "summary" => "kept", "raw" => "SECRET-FINDING"}] end)
    }

    projection = CurrentState.project(poisoned, review_run, Config.bundle!())
    encoded = Jason.encode!(projection)
    attestation = projection["review_attestation"]

    assert Map.keys(attestation) |> Enum.sort() ==
             ~w(checks_fingerprint criteria_fingerprint feedback_fingerprint findings plan_policy pull_request_number reviewed_at reviewed_head_sha reviewer_identity route run_id validation_evidence verdict)

    assert Map.keys(attestation["plan_policy"]) |> Enum.sort() == ~w(status summary)
    assert Enum.all?(attestation["validation_evidence"], &(Map.keys(&1) -- ~w(command result artifact exit_status) == []))
    assert Enum.all?(attestation["findings"], &(Map.keys(&1) -- ~w(severity summary path line) == []))
    refute encoded =~ "SECRET-"
  end

  test "only a canonical verified conflict can be claimed and its agent can only return to review or blocked" do
    {review_task, review_run} = active_review()

    assert %{"success" => true} =
             DynamicTool.execute(
               "symphony_review_complete",
               pass_arguments(review_task),
               review_opts(review_task, review_run, "conflict-pass")
             )

    {:ok, attested} = Board.task(review_task["id"])
    finished = finish_run(attested, review_run)
    target = String.duplicate("c", 40)
    paths = ["Sources/A.swift", "Sources/B.swift"]
    conflict_id = DeterministicMerge.conflict_id(finished["id"], @head, target, paths)

    assert {:ok, %{"task" => conflicted}} =
             Board.execute(
               %Commands.RecordMergeConflict{
                 task_id: finished["id"],
                 task_head: @head,
                 target_head: target,
                 conflicted_paths: paths,
                 conflict_id: conflict_id
               },
               actor: :system,
               expected_revision: finished["revision"],
               idempotency_key: BoardFactory.unique("verified-conflict")
             )

    assert conflicted["column_id"] == "merge_conflict"

    assert {:ok, %{"task" => claimed, "run" => conflict_run}} =
             Board.execute(%Commands.ClaimRun{task_id: conflicted["id"]},
               actor: :system,
               expected_revision: conflicted["revision"],
               idempotency_key: BoardFactory.unique("conflict-claim")
             )

    assert conflict_run["stage_id"] == "merge_conflict"

    assert {:error, :merge_conflict_must_return_to_review} =
             Board.execute(%Commands.MoveTask{task_id: claimed["id"], column_id: "rework"},
               actor: %{type: :agent, identity: conflict_run["id"]},
               expected_revision: claimed["revision"],
               idempotency_key: BoardFactory.unique("bad-conflict-route")
             )

    assert {:ok, %{"task" => review}} =
             Board.execute(%Commands.MoveTask{task_id: claimed["id"], column_id: "automated_review"},
               actor: %{type: :agent, identity: conflict_run["id"]},
               expected_revision: claimed["revision"],
               idempotency_key: BoardFactory.unique("conflict-return-review")
             )

    assert review["column_id"] == "automated_review"
    cleanup_active_run(review["id"], conflict_run["id"])
  end

  test "review tool schema is strict at every nested object" do
    spec = Enum.find(DynamicTool.tool_specs(), &(&1["name"] == "symphony_review_complete"))
    schema = spec["inputSchema"]

    assert schema["additionalProperties"] == false
    assert get_in(schema, ["properties", "plan_policy", "additionalProperties"]) == false
    assert get_in(schema, ["properties", "validation_evidence", "items", "additionalProperties"]) == false
    assert get_in(schema, ["properties", "findings", "items", "additionalProperties"]) == false
    assert get_in(schema, ["properties", "verdict", "enum"]) == ["pass", "rework"]
  end

  defp active_review(criteria \\ ["The behavior is verified."]) do
    {created, _key} =
      BoardFactory.create_task(%{
        title: BoardFactory.unique("Attestation"),
        acceptance_criteria: criteria
      })

    {todo, _result} = BoardFactory.move(created, "todo")

    {:ok, %{"task" => implementation, "run" => implementation_run}} =
      Board.execute(%Commands.ClaimRun{task_id: todo["id"]},
        actor: :system,
        expected_revision: todo["revision"],
        idempotency_key: BoardFactory.unique("implementation-claim")
      )

    evidenced =
      Enum.reduce(implementation["acceptance_criteria"], implementation, fn criterion, current ->
        {:ok, %{"task" => updated}} =
          Board.execute(
            %Commands.CompleteAcceptance{
              task_id: current["id"],
              criterion_id: criterion["id"],
              evidence: [%{"command" => "mix test", "result" => "passed"}]
            },
            actor: %{type: :agent, identity: implementation_run["id"]},
            expected_revision: current["revision"],
            idempotency_key: BoardFactory.unique("acceptance")
          )

        updated
      end)

    {:ok, %{"task" => sourced}} =
      Board.execute(%Commands.RecordSourceHead{task_id: evidenced["id"], head_sha: @head, clean: true},
        actor: %{type: :agent, identity: implementation_run["id"]},
        expected_revision: evidenced["revision"],
        idempotency_key: BoardFactory.unique("source")
      )

    {:ok, %{"task" => linked}} =
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
        idempotency_key: BoardFactory.unique("pull-request")
      )

    {:ok, %{"task" => review_ready}} =
      Board.execute(%Commands.MoveTask{task_id: linked["id"], column_id: "automated_review"},
        actor: %{type: :agent, identity: implementation_run["id"]},
        expected_revision: linked["revision"],
        idempotency_key: BoardFactory.unique("to-review")
      )

    finished = finish_run(review_ready, implementation_run)

    {:ok, %{"task" => review_task, "run" => review_run}} =
      Board.execute(%Commands.ClaimRun{task_id: finished["id"]},
        actor: :system,
        expected_revision: finished["revision"],
        idempotency_key: BoardFactory.unique("review-claim")
      )

    on_exit(fn -> cleanup_active_run(review_task["id"], review_run["id"]) end)
    {review_task, review_run}
  end

  defp finish_run(task, run) do
    task_id = task_value(task, :id)
    revision = task_value(task, :revision)

    {:ok, %{"task" => finished}} =
      Board.execute(%Commands.RunFinished{task_id: task_id, run_id: run["id"], outcome: %{}},
        actor: :system,
        expected_revision: revision,
        idempotency_key: BoardFactory.unique("finish-run")
      )

    finished
  end

  defp pass_arguments(task) do
    %{
      "expected_revision" => task["revision"],
      "verdict" => "pass",
      "reviewed_head_sha" => @head,
      "route" => "merging",
      "plan_policy" => %{"status" => "followed", "summary" => "Repository plan policy followed."},
      "validation_evidence" => [%{"command" => "mix test", "result" => "passed", "exit_status" => 0}],
      "findings" => []
    }
  end

  defp review_opts(task, run, call_id) do
    [
      task_id: task["id"],
      run_id: run["id"],
      call_id: call_id,
      review_snapshotter: fn _task, _worktree, _opts -> {:ok, provider_snapshot()} end
    ]
  end

  defp provider_snapshot do
    %{
      number: 1,
      state: "OPEN",
      head_sha: @head,
      source_head_sha: @head,
      approved: true,
      required_checks_green: true,
      unresolved_review_threads: 0,
      feedback_fingerprint: "feedback-v1",
      checks_fingerprint: "checks-v1"
    }
  end

  defp task_value(%Task{} = task, field), do: Map.fetch!(task, field)
  defp task_value(task, field), do: Map.fetch!(task, Atom.to_string(field))

  defp cleanup_active_run(task_id, run_id) do
    case Board.task(task_id) do
      {:ok, %{active_run_id: ^run_id} = task} ->
        Board.execute(%Commands.RunFailed{task_id: task.id, run_id: run_id, reason: :test_cleanup},
          actor: :system,
          expected_revision: task.revision,
          idempotency_key: BoardFactory.unique("cleanup")
        )

      _ ->
        :ok
    end
  end
end
