defmodule SymphonyElixir.Config.SchemaTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{BoardFactory, PathSafety, Workflow}
  alias SymphonyElixir.Config.Schema

  test "local Codex turns can write the managed worktree and shared Git metadata" do
    source = BoardFactory.workflow_source()
    workspace = Path.join(System.tmp_dir!(), BoardFactory.unique("sandbox-worktree"))
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    assert {:ok, bundle} = Workflow.load(source.workflow)
    settings = Schema.from_bundle(bundle)

    assert {:ok, canonical_workspace} = PathSafety.canonicalize(workspace)

    assert {git_common_dir, 0} =
             System.cmd(
               "git",
               ["-C", source.root, "rev-parse", "--path-format=absolute", "--git-common-dir"],
               stderr_to_stdout: true
             )

    assert {:ok, canonical_git_common_dir} =
             git_common_dir
             |> String.trim()
             |> PathSafety.canonicalize()

    assert {:ok, policy} = Schema.resolve_runtime_turn_sandbox_policy(settings, workspace)

    assert MapSet.new(policy["writableRoots"]) ==
             MapSet.new([canonical_workspace, canonical_git_common_dir])

    refute Path.expand(source.root) in policy["writableRoots"]
  end

  test "Codex turns honor a configured danger-full-access sandbox" do
    source = BoardFactory.workflow_source()
    assert {:ok, bundle} = Workflow.load(source.workflow)

    settings = Schema.from_bundle(bundle)
    settings = %{settings | codex: %{settings.codex | thread_sandbox: "danger-full-access"}}

    assert {:ok, %{"type" => "dangerFullAccess"}} =
             Schema.resolve_runtime_turn_sandbox_policy(settings, source.root)
  end
end
