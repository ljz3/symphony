defmodule SymphonyElixir.WorktreeTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{BoardFactory, Task, Workflow, Worktree}

  setup do
    original = Workflow.workflow_file_path()
    source = BoardFactory.workflow_source()
    :ok = Workflow.set_workflow_file_path(source.workflow)
    assert :ok = Workflow.Store.force_reload()
    BoardFactory.await_activation()
    assert {:ok, %{source: %{root: root}}} = Workflow.current()
    assert root == source.root

    on_exit(fn ->
      Workflow.set_workflow_file_path(original)
      Workflow.Store.force_reload()
    end)

    %{source: source}
  end

  test "creates, reuses, and safely removes a managed persistent Git worktree", %{source: source} do
    task = task_fixture(BoardFactory.unique("SYM-WT"))

    assert {:ok, path} = Worktree.ensure(task)
    assert File.dir?(path)
    assert {:ok, task.branch} == Worktree.reconcile(task, path) |> then(fn {:ok, info} -> {:ok, info.branch} end)
    assert {:ok, ^path} = Worktree.ensure(task)

    dirty = Path.join(path, "dirty.txt")
    File.write!(dirty, "dirty\n")
    assert {:error, {:dirty_worktree_not_removed, ^path}} = Worktree.remove(task)
    assert File.exists?(dirty)

    File.rm!(dirty)
    assert :ok = Worktree.remove(task)
    refute File.exists?(path)
    refute local_branch_exists?(source.root, task.branch)
  end

  test "retries local branch cleanup only after the managed worktree is gone", %{source: source} do
    task = task_fixture(BoardFactory.unique("SYM-CLEANUP"))
    assert {:ok, path} = Worktree.ensure(task)

    BoardFactory.git!(source.root, ["worktree", "remove", path])
    other = Path.join(System.tmp_dir!(), BoardFactory.unique("branch-owner"))
    BoardFactory.git!(source.root, ["worktree", "add", other, task.branch])
    root = source.root

    assert {:error, {:git_failed, ^root, ["branch", "--delete", "--force", "--", branch], _status, _output}} =
             Worktree.remove(task)

    assert branch == task.branch
    assert File.dir?(other)
    assert local_branch_exists?(source.root, task.branch)

    BoardFactory.git!(source.root, ["worktree", "remove", other])
    assert :ok = Worktree.remove(task)
    refute local_branch_exists?(source.root, task.branch)
  end

  test "leaves an unmanaged destination untouched" do
    task = task_fixture(BoardFactory.unique("SYM-UNMANAGED"))
    path = Worktree.path(task)
    File.mkdir_p!(path)
    sentinel = Path.join(path, "keep-me")
    File.write!(sentinel, "safe")

    assert {:error, {:unmanaged_existing_worktree, ^path, _reason}} = Worktree.ensure(task)
    assert File.read!(sentinel) == "safe"
  end

  test "runs preflight in the managed worktree with frozen task and workflow identity" do
    task = task_fixture(BoardFactory.unique("SYM-PREFLIGHT-ENV"))
    assert {:ok, path} = Worktree.ensure(task)

    command =
      ~S(printf '%s\n' "$SYMPHONY_TASK_ID|$SYMPHONY_TASK_IDENTIFIER|$SYMPHONY_TASK_BRANCH|$SYMPHONY_WORKFLOW_HASH|$PWD")

    assert {:ok, output} = Worktree.run_preflight(task, path, command, "workflow-hash")

    [task_id, identifier, branch, workflow_hash, command_path] =
      output |> String.trim() |> String.split("|", parts: 5)

    assert [task_id, identifier, branch, workflow_hash] ==
             [task.id, task.identifier, task.branch, "workflow-hash"]

    assert {:ok, canonical_command_path} = SymphonyElixir.PathSafety.canonicalize(command_path)
    assert {:ok, canonical_path} = SymphonyElixir.PathSafety.canonicalize(path)
    assert canonical_command_path == canonical_path
  end

  @tag timeout: 15_000
  test "waits for a quiet preflight beyond the former hook deadline and preserves all output" do
    task = task_fixture(BoardFactory.unique("SYM-PREFLIGHT-LONG"))
    assert {:ok, path} = Worktree.ensure(task)
    payload = String.duplicate("preflight-output-", 8_192)
    encoded = Base.encode64(payload)

    started_at = System.monotonic_time(:millisecond)

    assert {:ok, ^payload} =
             Worktree.run_preflight(
               task,
               path,
               "sleep 5.2; printf %s #{encoded} | base64 --decode",
               "workflow-hash"
             )

    assert System.monotonic_time(:millisecond) - started_at >= 5_100
  end

  test "stops an active preflight when its orchestrator owner exits" do
    task = task_fixture(BoardFactory.unique("SYM-PREFLIGHT-OWNER"))
    assert {:ok, path} = Worktree.ensure(task)
    marker = Path.join(path, "preflight-started")
    owner = spawn(fn -> Process.sleep(:infinity) end)

    preflight =
      Elixir.Task.async(fn ->
        Worktree.run_preflight(
          task,
          path,
          "touch #{shell_escape(marker)}; sleep 600",
          "workflow-hash",
          nil,
          owner: owner
        )
      end)

    eventually(fn -> File.exists?(marker) end)
    Process.exit(owner, :kill)

    assert {:error, :preflight_owner_down} = Elixir.Task.await(preflight, 5_000)
  end

  @tag timeout: 20_000
  test "owner loss kills TERM-ignoring local and SSH preflight trees before returning" do
    original_path = System.get_env("PATH")
    fake_bin = Path.join(System.tmp_dir!(), BoardFactory.unique("preflight-fake-ssh"))
    File.mkdir_p!(fake_bin)

    fake_ssh = Path.join(fake_bin, "ssh")

    File.write!(fake_ssh, """
    #!/bin/sh
    for argument in "$@"; do command=$argument; done
    exec /bin/sh -c "$command"
    """)

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", fake_bin <> ":" <> original_path)
    on_exit(fn -> System.put_env("PATH", original_path) end)

    Enum.each([nil, "fake-worker"], fn worker_host ->
      suffix = worker_host || "local"
      task = task_fixture(BoardFactory.unique("SYM-PREFLIGHT-TREE-#{suffix}"))
      assert {:ok, path} = Worktree.ensure(task)
      parent_path = Path.join(path, "#{suffix}-parent.pid")
      child_path = Path.join(path, "#{suffix}-child.pid")
      owner = spawn(fn -> Process.sleep(:infinity) end)

      command = """
      trap '' TERM
      (trap '' TERM; while :; do sleep 1; done) &
      child=$!
      printf %s $$ > #{shell_escape(parent_path)}
      printf %s "$child" > #{shell_escape(child_path)}
      wait "$child"
      """

      preflight =
        Elixir.Task.async(fn ->
          Worktree.run_preflight(
            task,
            path,
            command,
            "workflow-hash",
            worker_host,
            owner: owner
          )
        end)

      eventually(fn -> File.exists?(parent_path) and File.exists?(child_path) end)
      parent_pid = parent_path |> File.read!() |> String.trim() |> String.to_integer()
      child_pid = child_path |> File.read!() |> String.trim() |> String.to_integer()

      on_exit(fn ->
        kill_process(parent_pid)
        kill_process(child_pid)
      end)

      assert process_alive?(parent_pid)
      assert process_alive?(child_pid)
      Process.exit(owner, :kill)

      assert {:error, :preflight_owner_down} = Elixir.Task.await(preflight, 8_000)
      refute process_alive?(parent_pid)
      refute process_alive?(child_pid)
    end)
  end

  @tag timeout: 20_000
  test "waits for a worktree hook beyond the former hook deadline", %{source: source} do
    workflow =
      source.workflow
      |> File.read!()
      |> String.replace("hooks:\n", "hooks:\n  before_run: sleep 5.2\n", global: false)

    File.write!(source.workflow, workflow)
    assert :ok = Workflow.Store.force_reload()
    BoardFactory.await_activation()

    task = task_fixture(BoardFactory.unique("SYM-LONG-HOOK"))
    assert {:ok, path} = Worktree.ensure(task)

    started_at = System.monotonic_time(:millisecond)
    assert :ok = Worktree.run_hook(:before_run, task, path)
    assert System.monotonic_time(:millisecond) - started_at >= 5_100
  end

  defp task_fixture(identifier) do
    %Task{
      id: Ecto.UUID.generate(),
      identifier: identifier,
      number: System.unique_integer([:positive]),
      project_id: "symphony",
      title: "Worktree task",
      type: :feature,
      branch: "feature/#{identifier}",
      priority: :normal,
      brief: "Brief",
      acceptance_criteria: [
        %{"id" => Ecto.UUID.generate(), "text" => "Works", "completed" => false, "evidence" => [], "evidence_history" => []}
      ],
      column_id: "backlog",
      rank: 1_024,
      revision: 1,
      created_at: "now",
      updated_at: "now"
    }
  end

  defp local_branch_exists?(root, branch) do
    match?(
      {_output, 0},
      System.cmd("git", ["-C", root, "show-ref", "--verify", "--quiet", "refs/heads/#{branch}"], stderr_to_stdout: true)
    )
  end

  defp eventually(predicate, attempts \\ 100)
  defp eventually(predicate, 0), do: assert(predicate.())

  defp eventually(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(25)
      eventually(predicate, attempts - 1)
    end
  end

  defp process_alive?(pid) when is_integer(pid) do
    match?({_output, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
  end

  defp kill_process(pid) do
    if process_alive?(pid) do
      System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    :ok
  end

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
