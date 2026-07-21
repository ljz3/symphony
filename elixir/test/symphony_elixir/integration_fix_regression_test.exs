defmodule SymphonyElixir.IntegrationFixRegressionTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Board
  alias SymphonyElixir.Board.Commands
  alias SymphonyElixir.BoardFactory
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.DeterministicMerge
  alias SymphonyElixir.JobManager
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.Worktree

  setup do
    original_workflow = Workflow.workflow_file_path()
    source = BoardFactory.workflow_source()
    prepare_conflict_source!(source)
    :ok = Workflow.set_workflow_file_path(source.workflow)
    assert :ok = Workflow.Store.force_reload()
    BoardFactory.await_activation()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow)
      Workflow.Store.force_reload()
    end)

    %{source: source}
  end

  @tag timeout: 30_000
  test "reconciled conflict source completes through AgentRunner, JobManager, and the dynamic tool", %{
    source: source
  } do
    {created, _key} =
      BoardFactory.create_task(%{
        title: BoardFactory.unique("Real conflict resolution"),
        acceptance_criteria: ["The recorded conflict is resolved and validated."]
      })

    {todo, _result} = BoardFactory.move(created, "todo")

    assert {:ok, %{"task" => implementation, "run" => implementation_run}} =
             Board.execute(%Commands.ClaimRun{task_id: todo["id"]},
               actor: :system,
               expected_revision: todo["revision"],
               idempotency_key: BoardFactory.unique("real-conflict-implementation")
             )

    on_exit(fn -> cleanup_active_run(implementation["id"]) end)
    criterion_id = implementation["acceptance_criteria"] |> hd() |> Map.fetch!("id")

    assert {:ok, %{"task" => evidenced}} =
             Board.execute(
               %Commands.CompleteAcceptance{
                 task_id: implementation["id"],
                 criterion_id: criterion_id,
                 evidence: [%{"command" => "real integration regression", "result" => "passed"}]
               },
               actor: %{type: :agent, identity: implementation_run["id"]},
               expected_revision: implementation["revision"],
               idempotency_key: BoardFactory.unique("real-conflict-evidence")
             )

    assert {:ok, task} = Board.task(evidenced["id"])
    assert {:ok, worktree} = Worktree.ensure(task)
    File.write!(Path.join(worktree, "conflict.txt"), "task version\n")
    git!(worktree, ["add", "conflict.txt"])
    git!(worktree, ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "task change"])
    task_head = git!(worktree, ["rev-parse", "HEAD"]) |> String.trim()
    assert :ok = Worktree.push(task, worktree)
    assert :ok = AgentRunner.reconcile_source(task.id, implementation_run["id"], worktree)

    assert {:ok, sourced} = Board.task(task.id)

    assert {:ok, %{"task" => linked}} =
             Board.execute(
               %Commands.LinkPullRequest{
                 task_id: sourced.id,
                 run_id: implementation_run["id"],
                 number: 41,
                 url: "https://github.test/pull/41",
                 head_sha: task_head,
                 state: "open",
                 draft: false
               },
               actor: :system,
               expected_revision: sourced.revision,
               idempotency_key: BoardFactory.unique("real-conflict-pr")
             )

    assert {:ok, %{"task" => review_ready}} =
             Board.execute(%Commands.MoveTask{task_id: linked["id"], column_id: "automated_review"},
               actor: %{type: :agent, identity: implementation_run["id"]},
               expected_revision: linked["revision"],
               idempotency_key: BoardFactory.unique("real-conflict-to-review")
             )

    implementation_finished = finish_run(review_ready, implementation_run)

    assert {:ok, %{"task" => review, "run" => review_run}} =
             Board.execute(%Commands.ClaimRun{task_id: implementation_finished["id"]},
               actor: :system,
               expected_revision: implementation_finished["revision"],
               idempotency_key: BoardFactory.unique("real-conflict-review")
             )

    assert %{"success" => true} =
             DynamicTool.execute(
               "symphony_review_complete",
               %{
                 "expected_revision" => review["revision"],
                 "verdict" => "pass",
                 "reviewed_head_sha" => task_head,
                 "route" => "merging",
                 "plan_policy" => %{"status" => "followed", "summary" => "Regression fixture is plan-exempt."},
                 "validation_evidence" => [
                   %{"command" => "real integration regression", "result" => "passed", "exit_status" => 0}
                 ],
                 "findings" => []
               },
               task_id: review["id"],
               run_id: review_run["id"],
               call_id: BoardFactory.unique("real-conflict-review-tool"),
               review_snapshotter: fn _task, _worktree, _opts ->
                 {:ok,
                  %{
                    number: 41,
                    state: "OPEN",
                    draft: false,
                    head_sha: task_head,
                    source_head_sha: task_head,
                    approved: true,
                    required_checks_green: true,
                    unresolved_review_threads: 0,
                    feedback_fingerprint: "feedback-real",
                    checks_fingerprint: "checks-real"
                  }}
               end
             )

    assert {:ok, attested} = Board.task(review["id"])
    merge_pending = finish_run(attested, review_run)

    File.write!(Path.join(source.root, "conflict.txt"), "target version\n")
    git!(source.root, ["add", "conflict.txt"])
    git!(source.root, ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "target change"])
    target_head = git!(source.root, ["rev-parse", "HEAD"]) |> String.trim()
    git!(source.root, ["push", "origin", "main"])

    paths = ["conflict.txt"]
    conflict_id = DeterministicMerge.conflict_id(merge_pending["id"], task_head, target_head, paths)

    assert {:ok, %{"task" => conflicted}} =
             Board.execute(
               %Commands.RecordMergeConflict{
                 task_id: merge_pending["id"],
                 task_head: task_head,
                 target_head: target_head,
                 conflicted_paths: paths,
                 conflict_id: conflict_id
               },
               actor: :system,
               expected_revision: merge_pending["revision"],
               idempotency_key: BoardFactory.unique("real-conflict-record")
             )

    assert {:ok, %{"task" => conflict_task, "run" => conflict_run}} =
             Board.execute(%Commands.ClaimRun{task_id: conflicted["id"]},
               actor: :system,
               expected_revision: conflicted["revision"],
               idempotency_key: BoardFactory.unique("real-conflict-claim")
             )

    assert {:ok, %{"task" => running_conflict}} =
             Board.execute(
               %Commands.RunStarted{
                 task_id: conflict_task["id"],
                 run_id: conflict_run["id"],
                 session_id: "real-conflict-session",
                 workspace_path: worktree
               },
               actor: :system,
               expected_revision: conflict_task["revision"],
               idempotency_key: BoardFactory.unique("real-conflict-started")
             )

    git!(worktree, ["fetch", "origin", "main"])
    {_output, merge_status} = git_status(worktree, ["merge", "--no-ff", "--no-edit", target_head])
    assert merge_status != 0
    File.write!(Path.join(worktree, "conflict.txt"), "resolved version\n")
    git!(worktree, ["add", "conflict.txt"])
    git!(worktree, ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "resolve conflict"])
    final_head = git!(worktree, ["rev-parse", "HEAD"]) |> String.trim()
    git!(worktree, ["push", "origin", running_conflict["branch"]])

    assert :ok = AgentRunner.reconcile_source(running_conflict["id"], conflict_run["id"], worktree)
    assert {:ok, reconciled} = Board.task(running_conflict["id"])
    assert reconciled.source["head_sha"] == final_head
    assert get_in(reconciled.merge_saga, ["last_conflict", "task_head"]) == task_head

    frozen_job = get_in(conflict_run, ["frozen_bundle", "jobs", "full_validation"])
    source_fingerprint = JobManager.source_fingerprint(worktree, nil)

    assert {:ok, %{"status" => "completed", "exit_code" => 0}} =
             JobManager.run(%{
               task_id: reconciled.id,
               task_identifier: reconciled.identifier,
               task_branch: reconciled.branch,
               run_id: conflict_run["id"],
               call_id: "real-conflict-validation",
               job: frozen_job,
               arguments: [],
               workspace: worktree,
               worker_host: nil,
               source_fingerprint: source_fingerprint
             })

    assert {:ok, verified_task} = Board.task(reconciled.id)

    assert %{"success" => true, "output" => output} =
             DynamicTool.execute(
               "symphony_task_transition",
               %{
                 "column_id" => "automated_review",
                 "expected_revision" => verified_task.revision
               },
               task_id: verified_task.id,
               run_id: conflict_run["id"],
               call_id: "real-conflict-complete",
               provider_snapshotter: fn _task, _worktree, _opts ->
                 {:ok, %{"number" => 41, "state" => "OPEN", "head_sha" => final_head}}
               end
             )

    assert %{"event_type" => "merge_conflict_resolved", "task" => %{"column_id" => "automated_review"}} =
             Jason.decode!(output)
  end

  defp prepare_conflict_source!(source) do
    workflow =
      Regex.replace(
        ~r/(  full_validation:\n    executable: ).*/,
        File.read!(source.workflow),
        "\\1./validate-conflict.sh"
      )

    File.write!(source.workflow, workflow)
    File.write!(Path.join(source.root, "conflict.txt"), "base version\n")
    validation = Path.join(source.root, "validate-conflict.sh")
    File.write!(validation, "#!/bin/sh\nset -eu\nprintf validated\n")
    File.chmod!(validation, 0o755)
    git!(source.root, ["add", "."])
    git!(source.root, ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "conflict fixture"])
    git!(source.root, ["push", "origin", "main"])
  end

  defp finish_run(task, run) do
    task_id = if is_map_key(task, :id), do: task.id, else: task["id"]
    revision = if is_map_key(task, :revision), do: task.revision, else: task["revision"]

    assert {:ok, %{"task" => finished}} =
             Board.execute(%Commands.RunFinished{task_id: task_id, run_id: run["id"], outcome: %{}},
               actor: :system,
               expected_revision: revision,
               idempotency_key: BoardFactory.unique("real-conflict-finish")
             )

    finished
  end

  defp cleanup_active_run(task_id) do
    case Board.task(task_id) do
      {:ok, %{active_run_id: run_id} = task} when is_binary(run_id) ->
        Board.execute(%Commands.RunFailed{task_id: task.id, run_id: run_id, reason: :test_cleanup},
          actor: :system,
          expected_revision: task.revision,
          idempotency_key: BoardFactory.unique("real-conflict-cleanup")
        )

      _ ->
        :ok
    end
  end

  defp git!(root, arguments) do
    case git_status(root, arguments) do
      {output, 0} -> output
      {output, status} -> flunk("git failed (#{status}): #{output}")
    end
  end

  defp git_status(root, arguments) do
    System.cmd("git", ["-C", root | arguments], stderr_to_stdout: true)
  end
end
