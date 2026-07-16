defmodule SymphonyElixir.MergeConflictResolutionTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.JobManager
  alias SymphonyElixir.MergeConflictResolution
  alias SymphonyElixir.Task

  test "accepts the recorded parent-pair merge and recorded-path-only follow-up commits" do
    fixture = conflict_fixture(followup_path: "A.txt")

    assert {:ok, snapshot} =
             MergeConflictResolution.source_snapshot(
               fixture.task,
               fixture.root,
               fixture.conflict,
               []
             )

    assert snapshot == %{
             "clean" => true,
             "final_head_sha" => fixture.final_head,
             "remote_head_sha" => fixture.final_head,
             "merge_commit_sha" => fixture.merge_commit,
             "conflicted_paths" => ["A.txt", "B.txt"]
           }
  end

  test "rejects a merge commit that changes a non-conflict path" do
    fixture = conflict_fixture(merge_extra_path: "outside.txt")

    assert {:error, {:merge_conflict_out_of_scope_paths, ["outside.txt"]}} =
             MergeConflictResolution.source_snapshot(
               fixture.task,
               fixture.root,
               fixture.conflict,
               []
             )
  end

  test "rejects any out-of-scope follow-up commit even when the final tree is pushed" do
    fixture = conflict_fixture(followup_path: "outside.txt")

    assert {:error, {:merge_conflict_out_of_scope_paths, ["outside.txt"]}} =
             MergeConflictResolution.source_snapshot(
               fixture.task,
               fixture.root,
               fixture.conflict,
               []
             )
  end

  test "rejects dirty, uncommitted, and unpushed final source" do
    dirty = conflict_fixture(dirty?: true)

    assert {:error, :merge_conflict_worktree_dirty} =
             MergeConflictResolution.source_snapshot(dirty.task, dirty.root, dirty.conflict, [])

    unpushed = conflict_fixture(push?: false)

    assert {:error, :merge_conflict_unpushed} =
             MergeConflictResolution.source_snapshot(
               unpushed.task,
               unpushed.root,
               unpushed.conflict,
               []
             )

    stale_remote = conflict_fixture(followup_path: "A.txt", push_merge_before_followup?: true, push?: false)

    assert {:error, :merge_conflict_unpushed} =
             MergeConflictResolution.source_snapshot(
               stale_remote.task,
               stale_remote.root,
               stale_remote.conflict,
               []
             )
  end

  test "rejects a missing recorded parent pair and a reconstructed conflict-set mismatch" do
    fixture = conflict_fixture()

    wrong_parent =
      put_in(fixture.conflict, ["target_head"], String.duplicate("f", 40))

    assert {:error, :merge_conflict_wrong_topology} =
             MergeConflictResolution.source_snapshot(
               fixture.task,
               fixture.root,
               wrong_parent,
               []
             )

    wrong_paths = put_in(fixture.conflict, ["conflicted_paths"], ["A.txt"])

    assert {:error, :merge_conflict_stale} =
             MergeConflictResolution.source_snapshot(
               fixture.task,
               fixture.root,
               wrong_paths,
               []
             )
  end

  test "accepts only a current canonical run, exact job proof, open matching PR, and stable final source" do
    fixture = conflict_fixture()
    fingerprint = JobManager.source_fingerprint(fixture.root, nil)
    job = frozen_job()
    {task, run} = run(fixture.task, job)
    source = source_snapshot(fixture)
    parent = self()

    opts = [
      source_snapshotter: fn task, worktree, conflict, _opts ->
        send(parent, {:source_snapshot, task.id, worktree, conflict["id"]})
        {:ok, source}
      end,
      source_fingerprinter: fn _worktree, nil -> fingerprint end,
      job_success_finder: fn run_id, frozen_jobs, ^fingerprint ->
        send(parent, {:job_lookup, run_id, frozen_jobs})
        {:ok, job_proof(run_id, job, fingerprint)}
      end,
      provider_snapshotter: fn task, worktree, worker_host: nil ->
        send(parent, {:provider_snapshot, task.id, worktree})
        {:ok, provider(task, fixture.final_head)}
      end
    ]

    assert {:ok, proof} =
             MergeConflictResolution.verify(task, run, fixture.root, opts)

    assert proof["conflict_id"] == fixture.conflict["id"]
    assert proof["run_id"] == run["id"]
    assert proof["final_head_sha"] == fixture.final_head
    assert proof["source_fingerprint"] == fingerprint
    assert proof["job"]["job"] == "full_validation"
    assert proof["pull_request"] == provider(task, fixture.final_head)

    assert_receive {:source_snapshot, _, _, _}
    assert_receive {:job_lookup, _, _}
    assert_receive {:provider_snapshot, _, _}
    assert_receive {:source_snapshot, _, _, _}
  end

  test "propagates provider and job-manager failures and rejects final source races" do
    fixture = conflict_fixture()
    fingerprint = String.duplicate("e", 64)
    job = frozen_job()
    {task, run} = run(fixture.task, job)
    source = source_snapshot(fixture)
    base = verification_opts(source, fingerprint, job, run, task)

    assert {:error, :provider_down} =
             MergeConflictResolution.verify(
               task,
               run,
               fixture.root,
               Keyword.put(base, :provider_snapshotter, fn _, _, _ -> {:error, :provider_down} end)
             )

    assert {:error, :job_store_down} =
             MergeConflictResolution.verify(
               task,
               run,
               fixture.root,
               Keyword.put(base, :job_success_finder, fn _, _, _ -> {:error, :job_store_down} end)
             )

    snapshots = :counters.new(1, [])

    changing_source = fn _, _, _, _ ->
      :counters.add(snapshots, 1, 1)

      if :counters.get(snapshots, 1) == 1,
        do: {:ok, source},
        else: {:ok, Map.put(source, "final_head_sha", String.duplicate("9", 40))}
    end

    assert {:error, :merge_conflict_source_changed_during_verification} =
             MergeConflictResolution.verify(
               task,
               run,
               fixture.root,
               Keyword.put(base, :source_snapshotter, changing_source)
             )

    fingerprints = :counters.new(1, [])

    changing_fingerprint = fn _, nil ->
      :counters.add(fingerprints, 1, 1)

      if :counters.get(fingerprints, 1) == 1,
        do: fingerprint,
        else: String.duplicate("8", 64)
    end

    assert {:error, :merge_conflict_source_changed_during_verification} =
             MergeConflictResolution.verify(
               task,
               run,
               fixture.root,
               Keyword.put(base, :source_fingerprinter, changing_fingerprint)
             )
  end

  test "rejects wrong PR identity, state, or head and malformed source/job proof" do
    fixture = conflict_fixture()
    fingerprint = String.duplicate("e", 64)
    job = frozen_job()
    {task, run} = run(fixture.task, job)
    source = source_snapshot(fixture)
    base = verification_opts(source, fingerprint, job, run, task)

    provider_cases = [
      Map.put(provider(task, fixture.final_head), "number", 999),
      Map.put(provider(task, fixture.final_head), "state", "CLOSED"),
      Map.put(provider(task, fixture.final_head), "head_sha", String.duplicate("7", 40))
    ]

    Enum.each(provider_cases, fn snapshot ->
      assert {:error, :merge_conflict_pull_request_head_mismatch} =
               MergeConflictResolution.verify(
                 task,
                 run,
                 fixture.root,
                 Keyword.put(base, :provider_snapshotter, fn _, _, _ -> {:ok, snapshot} end)
               )
    end)

    assert {:error, :merge_conflict_invalid_source_proof} =
             MergeConflictResolution.verify(
               task,
               run,
               fixture.root,
               Keyword.put(base, :source_snapshotter, fn _, _, _, _ ->
                 {:ok, Map.put(source, "clean", false)}
               end)
             )

    assert {:error, :merge_conflict_invalid_validation_proof} =
             MergeConflictResolution.verify(
               task,
               run,
               fixture.root,
               Keyword.put(base, :job_success_finder, fn run_id, _, ^fingerprint ->
                 {:ok, Map.put(job_proof(run_id, job, fingerprint), "exit_code", 1)}
               end)
             )
  end

  test "rejects stale canonical conflict state, an inactive run, missing frozen jobs, and fingerprint errors" do
    fixture = conflict_fixture()
    fingerprint = String.duplicate("e", 64)
    job = frozen_job()
    {task, run} = run(fixture.task, job)
    source = source_snapshot(fixture)
    base = verification_opts(source, fingerprint, job, run, task)

    assert {:error, :merge_conflict_stale} =
             MergeConflictResolution.verify(
               %{task | merge_saga: nil},
               run,
               fixture.root,
               base
             )

    assert {:error, :merge_conflict_run_not_current} =
             MergeConflictResolution.verify(
               task,
               %{run | "status" => "completed"},
               fixture.root,
               base
             )

    assert {:error, :merge_conflict_stale} =
             MergeConflictResolution.verify(
               %{task | source: Map.put(task.source, "head_sha", String.duplicate("6", 40))},
               run,
               fixture.root,
               base
             )

    assert {:error, :conflict_validation_missing} =
             MergeConflictResolution.verify(
               task,
               put_in(run, ["frozen_bundle", "jobs"], %{}),
               fixture.root,
               base
             )

    assert {:error, :fingerprint_unavailable} =
             MergeConflictResolution.verify(
               task,
               run,
               fixture.root,
               Keyword.put(base, :source_fingerprinter, fn _, _ ->
                 {:error, :fingerprint_unavailable}
               end)
             )

    assert {:error, :merge_conflict_source_fingerprint_failed} =
             MergeConflictResolution.verify(
               task,
               run,
               fixture.root,
               Keyword.put(base, :source_fingerprinter, fn _, _ -> nil end)
             )
  end

  test "rejects malformed and failed Git inspection without weakening path or topology checks" do
    fixture = conflict_fixture()

    cases = [
      {:bad_status, :merge_conflict_source_inspection_failed},
      {:bad_head, :merge_conflict_invalid_source_head},
      {:nil_head, :merge_conflict_invalid_source_head},
      {:invalid_remote, :merge_conflict_unpushed},
      {:history_status, :merge_conflict_history_inspection_failed},
      {:invalid_tree, :merge_conflict_invalid_automatic_tree},
      {:empty_tree, :merge_conflict_invalid_automatic_tree},
      {:followup_status, {:merge_conflict_git_failed, 9}},
      {:followup_error, :followup_transport_failed},
      {:followup_diff_status, {:merge_conflict_git_failed, 8}},
      {:followup_diff_error, :diff_transport_failed}
    ]

    Enum.each(cases, fn {mode, expected} ->
      assert {:error, ^expected} =
               MergeConflictResolution.source_snapshot(
                 fixture.task,
                 fixture.root,
                 fixture.conflict,
                 git_runner: fake_git_runner(fixture, mode)
               )
    end)

    assert {:error, :top_level_transport_failed} =
             MergeConflictResolution.source_snapshot(
               fixture.task,
               fixture.root,
               fixture.conflict,
               git_runner: fn _, _ -> {:error, :top_level_transport_failed} end
             )
  end

  test "default local and remote Git runners reject missing executables and transport failures" do
    fixture = conflict_fixture()
    old_path = System.get_env("PATH")
    empty_path = Path.join(System.tmp_dir!(), "empty-path-#{Ecto.UUID.generate()}")
    File.mkdir_p!(empty_path)

    try do
      System.put_env("PATH", empty_path)

      assert {:error, :git_not_found} =
               MergeConflictResolution.source_snapshot(
                 fixture.task,
                 fixture.root,
                 fixture.conflict,
                 []
               )

      assert {:error, :ssh_not_found} =
               MergeConflictResolution.source_snapshot(
                 fixture.task,
                 fixture.root,
                 fixture.conflict,
                 worker_host: "worker.example"
               )
    after
      System.put_env("PATH", old_path)
    end

    fake_bin = Path.join(System.tmp_dir!(), "conflict-fake-ssh-#{Ecto.UUID.generate()}")
    File.mkdir_p!(fake_bin)
    ssh = Path.join(fake_bin, "ssh")
    File.write!(ssh, "#!/bin/sh\nprintf ' M remote-dirty\\n'\n")
    File.chmod!(ssh, 0o755)

    try do
      System.put_env("PATH", fake_bin <> ":" <> old_path)

      assert {:error, :merge_conflict_worktree_dirty} =
               MergeConflictResolution.source_snapshot(
                 fixture.task,
                 fixture.root,
                 fixture.conflict,
                 worker_host: "worker.example"
               )
    after
      System.put_env("PATH", old_path)
    end

    invalid_git_bin = Path.join(System.tmp_dir!(), "conflict-invalid-git-#{Ecto.UUID.generate()}")
    File.mkdir_p!(invalid_git_bin)
    invalid_git = Path.join(invalid_git_bin, "git")
    File.write!(invalid_git, "not an executable image\n")
    File.chmod!(invalid_git, 0o755)

    try do
      System.put_env("PATH", invalid_git_bin <> ":" <> old_path)

      assert {:error, :merge_conflict_source_inspection_failed} =
               MergeConflictResolution.source_snapshot(
                 fixture.task,
                 fixture.root,
                 fixture.conflict,
                 []
               )
    after
      System.put_env("PATH", old_path)
    end

    assert {:error, {:git_transport_failed, "transport exploded"}} =
             MergeConflictResolution.source_snapshot(
               fixture.task,
               fixture.root,
               fixture.conflict,
               system_command_runner: fn _, _, _ -> raise "transport exploded" end
             )
  end

  test "default verify arity and non-map job results fail closed" do
    fixture = conflict_fixture()
    fingerprint = String.duplicate("e", 64)
    job = frozen_job()
    {task, run} = run(fixture.task, job)
    source = source_snapshot(fixture)

    assert {:error, :merge_conflict_stale} =
             MergeConflictResolution.verify(%{task | merge_saga: nil}, run, fixture.root)

    assert {:error, :merge_conflict_invalid_validation_proof} =
             MergeConflictResolution.verify(
               task,
               run,
               fixture.root,
               verification_opts(source, fingerprint, job, run, task)
               |> Keyword.put(:job_success_finder, fn _, _, _ -> {:ok, "not-a-proof"} end)
             )
  end

  defp verification_opts(source, fingerprint, job, _run, task) do
    [
      source_snapshotter: fn _, _, _, _ -> {:ok, source} end,
      source_fingerprinter: fn _, nil -> fingerprint end,
      job_success_finder: fn run_id, _, ^fingerprint ->
        {:ok, job_proof(run_id, job, fingerprint)}
      end,
      provider_snapshotter: fn _, _, _ -> {:ok, provider(task, source["final_head_sha"])} end
    ]
  end

  defp source_snapshot(fixture) do
    %{
      "clean" => true,
      "final_head_sha" => fixture.final_head,
      "remote_head_sha" => fixture.final_head,
      "merge_commit_sha" => fixture.merge_commit,
      "conflicted_paths" => fixture.conflict["conflicted_paths"]
    }
  end

  defp provider(task, head) do
    %{"number" => task.github["number"], "head_sha" => head, "state" => "OPEN"}
  end

  defp job_proof(run_id, job, fingerprint) do
    %{
      "job_id" => Ecto.UUID.generate(),
      "job" => job["id"],
      "status" => "completed",
      "exit_code" => 0,
      "run_id" => run_id,
      "source_fingerprint" => fingerprint,
      "job_definition_fingerprint" => JobManager.job_definition_fingerprint(job)
    }
  end

  defp frozen_job do
    %{
      "id" => "full_validation",
      "executable" => "./scripts/full.sh",
      "arguments" => [],
      "passthrough_arguments" => "forbidden",
      "environment" => %{}
    }
  end

  defp run(task, job) do
    run = %{
      "id" => Ecto.UUID.generate(),
      "task_id" => task.id,
      "status" => "running",
      "stage_id" => "merge_conflict",
      "start_column_id" => "merge_conflict",
      "frozen_bundle" => %{"jobs" => %{job["id"] => job}}
    }

    {%{task | active_run_id: run["id"]}, run}
  end

  defp fake_git_runner(fixture, mode) do
    fn _worktree, arguments -> fake_git_result(arguments, fixture, mode) end
  end

  defp fake_git_result(["status" | _], _fixture, :bad_status), do: {:ok, "", 7}
  defp fake_git_result(["status" | _], _fixture, _mode), do: {:ok, "", 0}
  defp fake_git_result(["rev-parse", "HEAD"], _fixture, :bad_head), do: {:ok, "not-a-head", 0}
  defp fake_git_result(["rev-parse", "HEAD"], _fixture, :nil_head), do: {:ok, nil, 0}
  defp fake_git_result(["rev-parse", "HEAD"], fixture, _mode), do: {:ok, fixture.final_head, 0}

  defp fake_git_result(["ls-remote" | _], fixture, :invalid_remote),
    do: {:ok, "not-a-head\trefs/heads/#{fixture.task.branch}\n", 0}

  defp fake_git_result(["ls-remote" | _], fixture, _mode),
    do: {:ok, "#{fixture.final_head}\trefs/heads/#{fixture.task.branch}\n", 0}

  defp fake_git_result(["rev-list", "--first-parent", "--parents", "HEAD"], _fixture, :history_status),
    do: {:ok, "", 7}

  defp fake_git_result(["rev-list", "--first-parent", "--parents", "HEAD"], fixture, _mode),
    do: {:ok, "#{fixture.merge_commit} #{fixture.conflict["task_head"]} #{fixture.conflict["target_head"]}\n", 0}

  defp fake_git_result(["merge-tree" | _], _fixture, :invalid_tree),
    do: {:ok, "not-a-tree\nA.txt\nB.txt\n", 1}

  defp fake_git_result(["merge-tree" | _], _fixture, :empty_tree), do: {:ok, "", 1}

  defp fake_git_result(["merge-tree" | _], _fixture, _mode),
    do: {:ok, "#{String.duplicate("4", 40)}\nA.txt\nB.txt\n", 1}

  defp fake_git_result(["diff", "--name-only" | _], _fixture, _mode),
    do: {:ok, "A.txt\nB.txt\n", 0}

  defp fake_git_result(["rev-list", "--first-parent", _range], _fixture, :followup_status),
    do: {:ok, "", 9}

  defp fake_git_result(["rev-list", "--first-parent", _range], _fixture, :followup_error),
    do: {:error, :followup_transport_failed}

  defp fake_git_result(["rev-list", "--first-parent", _range], _fixture, mode)
       when mode in [:followup_diff_status, :followup_diff_error],
       do: {:ok, String.duplicate("5", 40) <> "\n", 0}

  defp fake_git_result(["rev-list", "--first-parent", _range], _fixture, _mode),
    do: {:ok, "", 0}

  defp fake_git_result(["diff-tree" | _], _fixture, :followup_diff_status), do: {:ok, "", 8}

  defp fake_git_result(["diff-tree" | _], _fixture, :followup_diff_error),
    do: {:error, :diff_transport_failed}

  defp conflict_fixture(opts \\ []) do
    root = Path.join(System.tmp_dir!(), "symphony-conflict-#{Ecto.UUID.generate()}")
    remote = root <> "-remote.git"
    branch = "feature/FOODMAP-1"
    File.mkdir_p!(root)
    git_raw!(["init", "--bare", "--initial-branch=main", remote])
    git_raw!(["init", "--initial-branch=main", root])
    git!(root, ["config", "user.name", "Test"])
    git!(root, ["config", "user.email", "test@example.com"])
    git!(root, ["remote", "add", "origin", remote])

    write!(root, "A.txt", "base A\n")
    write!(root, "B.txt", "base B\n")
    write!(root, "outside.txt", "base outside\n")
    commit!(root, "base")
    base = head!(root)

    git!(root, ["switch", "-c", "target"])
    write!(root, "A.txt", "target A\n")
    write!(root, "B.txt", "target B\n")
    commit!(root, "target")
    target_head = head!(root)

    git!(root, ["switch", "-c", branch, base])
    write!(root, "A.txt", "task A\n")
    write!(root, "B.txt", "task B\n")
    commit!(root, "task")
    task_head = head!(root)

    {_output, status} = git_status(root, ["merge", "--no-ff", "--no-edit", target_head])
    assert status != 0
    write!(root, "A.txt", "resolved A\n")
    write!(root, "B.txt", "resolved B\n")

    if path = Keyword.get(opts, :merge_extra_path), do: write!(root, path, "merge extra\n")
    commit!(root, "resolve")
    merge_commit = head!(root)

    if Keyword.get(opts, :push_merge_before_followup?, false) do
      git!(root, ["push", "-u", "origin", branch])
    end

    if path = Keyword.get(opts, :followup_path) do
      write!(root, path, "follow-up\n")
      commit!(root, "follow-up")
    end

    final_head = head!(root)
    if Keyword.get(opts, :push?, true), do: git!(root, ["push", "-u", "origin", branch])
    if Keyword.get(opts, :dirty?, false), do: write!(root, "uncommitted.txt", "dirty\n")

    conflict = %{
      "id" => Ecto.UUID.generate(),
      "task_head" => task_head,
      "target_head" => target_head,
      "conflicted_paths" => ["A.txt", "B.txt"]
    }

    task = task(branch, task_head, conflict)

    %{
      root: root,
      remote: remote,
      task: task,
      conflict: conflict,
      merge_commit: merge_commit,
      final_head: final_head
    }
  end

  defp task(branch, task_head, conflict) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %Task{
      id: Ecto.UUID.generate(),
      identifier: "FOODMAP-1",
      number: 1,
      project_id: "symphony",
      title: "Resolve conflict",
      type: :feature,
      branch: branch,
      priority: :normal,
      brief: "Resolve the verified conflict.",
      acceptance_criteria: [],
      column_id: "merge_conflict",
      rank: 1,
      revision: 1,
      runtime_state: "running",
      active_run_id: nil,
      source: %{"head_sha" => task_head, "clean" => true},
      github: %{"number" => 42, "head_sha" => task_head},
      merge_saga: %{"checkpoint" => "conflict_recorded", "last_conflict" => conflict},
      created_at: now,
      updated_at: now
    }
  end

  defp commit!(root, message) do
    git!(root, ["add", "."])
    git!(root, ["commit", "-m", message])
  end

  defp head!(root), do: root |> git!(["rev-parse", "HEAD"]) |> String.trim()
  defp write!(root, path, content), do: File.write!(Path.join(root, path), content)

  defp git!(root, arguments) do
    case git_status(root, arguments) do
      {output, 0} -> output
      {output, status} -> flunk("git failed (#{status}): #{output}")
    end
  end

  defp git_status(root, arguments) do
    System.cmd("git", ["-C", root | arguments], stderr_to_stdout: true)
  end

  defp git_raw!(arguments) do
    case System.cmd("git", arguments, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git failed (#{status}): #{output}")
    end
  end
end
