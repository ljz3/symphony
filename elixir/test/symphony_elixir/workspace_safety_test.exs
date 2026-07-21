defmodule SymphonyElixir.WorkspaceSafetyTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{BoardFactory, Config, Paths, WorkspaceSafety}

  test "local task cwd must be a managed worktree under the worktree root" do
    root = Paths.worktrees_root(Config.bundle!().project.id)
    worktree = Path.join(root, BoardFactory.unique("task-worktree"))
    File.mkdir_p!(worktree)

    assert {:ok, canonical} = WorkspaceSafety.validate_task_cwd(worktree, nil)
    assert {:ok, canonical_root} = SymphonyElixir.PathSafety.canonicalize(root)
    assert canonical == Path.join(canonical_root, Path.basename(worktree))

    assert {:error, {:invalid_workspace_cwd, :workspace_root, _}} =
             WorkspaceSafety.validate_local_task_cwd(root)

    outside = Path.join(System.tmp_dir!(), BoardFactory.unique("outside"))
    File.mkdir_p!(outside)

    assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _, _}} =
             WorkspaceSafety.validate_local_task_cwd(outside)
  end

  test "symlink escapes are rejected" do
    root = Paths.worktrees_root(Config.bundle!().project.id)
    target = Path.join(System.tmp_dir!(), BoardFactory.unique("symlink-target"))
    File.mkdir_p!(target)
    link = Path.join(root, BoardFactory.unique("symlink-escape"))
    File.ln_s!(target, link)

    assert {:error, {:invalid_workspace_cwd, :symlink_escape, _, _}} =
             WorkspaceSafety.validate_local_task_cwd(link)
  after
    root = Paths.worktrees_root(Config.bundle!().project.id)

    root
    |> File.ls!()
    |> Enum.filter(&String.contains?(&1, "symlink-escape"))
    |> Enum.each(fn entry -> File.rm!(Path.join(root, entry)) end)
  end

  test "unreadable paths report path_unreadable" do
    root = Paths.worktrees_root(Config.bundle!().project.id)
    blocked = Path.join(root, BoardFactory.unique("blocked-dir"))
    File.mkdir_p!(blocked)
    File.chmod!(blocked, 0o000)

    try do
      assert {:error, {:invalid_workspace_cwd, :path_unreadable, _, _}} =
               WorkspaceSafety.validate_local_task_cwd(Path.join(blocked, "child"))
    after
      File.chmod!(blocked, 0o755)
    end
  end

  test "unreadable catalog paths report invalid catalog cwd" do
    project_id = Config.bundle!().project.id
    blocked = Path.join(Paths.runtime_root(project_id), BoardFactory.unique("blocked-catalog"))
    File.mkdir_p!(blocked)
    File.chmod!(blocked, 0o000)

    try do
      assert {:error, {:invalid_catalog_cwd, _}} =
               WorkspaceSafety.validate_catalog_cwd(Path.join(blocked, "child"), project_id)
    after
      File.chmod!(blocked, 0o755)
    end
  end

  test "remote task cwd keeps remote semantics and is never expanded locally" do
    assert {:ok, "/data/worktrees/SYM-1"} =
             WorkspaceSafety.validate_task_cwd("/data/worktrees/SYM-1", "builder-a")

    assert {:ok, "relative/path"} = WorkspaceSafety.validate_remote_task_cwd("relative/path", "builder-a")

    assert {:error, {:invalid_workspace_cwd, :empty_remote_workspace, "builder-a"}} =
             WorkspaceSafety.validate_remote_task_cwd("  ", "builder-a")

    assert {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, "builder-a", _}} =
             WorkspaceSafety.validate_remote_task_cwd("/tmp/with\nnewline", "builder-a")
  end

  test "catalog cwd must live under the project runtime root" do
    project_id = Config.bundle!().project.id
    scratch = Path.join(Paths.runtime_root(project_id), "catalog")
    File.mkdir_p!(scratch)

    assert {:ok, _canonical} = WorkspaceSafety.validate_catalog_cwd(scratch, project_id)

    outside = Path.join(System.tmp_dir!(), BoardFactory.unique("catalog-outside"))
    File.mkdir_p!(outside)

    assert {:error, {:invalid_catalog_cwd, _}} = WorkspaceSafety.validate_catalog_cwd(outside, project_id)
  end
end
