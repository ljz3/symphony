defmodule SymphonyElixir.WorktreeTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{BoardFactory, Task, Workflow, Worktree}

  setup do
    original = Workflow.workflow_file_path()
    source = BoardFactory.workflow_source()
    :ok = Workflow.set_workflow_file_path(source.workflow)
    assert :ok = Workflow.Store.force_reload()
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
end
