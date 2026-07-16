defmodule SymphonyElixir.Wave4RegressionTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.{Config, Workflow}

  test "advertises the structured review completion tool" do
    assert "symphony_review_complete" in Enum.map(DynamicTool.tool_specs(), & &1["name"])
  end

  test "reference workflow makes merge system-owned and conflict resolution agent-owned" do
    bundle = Config.bundle!()

    assert Workflow.Bundle.column(bundle, "merging").role == :merge
    assert Workflow.Bundle.column(bundle, "merge_conflict").role == :dispatch
    assert bundle.merge.review_column == "automated_review"
    assert bundle.merge.conflict_column == "merge_conflict"
  end

  test "loads a model-free deterministic merge saga" do
    assert Code.ensure_loaded?(SymphonyElixir.DeterministicMerge)
    assert function_exported?(SymphonyElixir.DeterministicMerge, :run, 3)
  end

  test "merge conflict prompt forbids landing the pull request" do
    bundle = Config.bundle!()
    conflict = Map.fetch!(bundle.stages, "merge_conflict")

    assert conflict.prompt =~ "without rebase"
    assert conflict.prompt =~ "symphony_job_run"
    assert conflict.prompt =~ "never merge or land the pull request"
  end
end
