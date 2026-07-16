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
    assert conflict.prompt =~ "Commit the resolution before"
    assert conflict.prompt =~ "configured `full_validation` job and no arguments"
    assert conflict.prompt =~ "do not repeat a\nsuccessful validation for an unchanged committed source"
    assert conflict.prompt =~ "Push the exact successfully\nvalidated head"
    assert conflict.prompt =~ "never merge or land the pull request"
  end

  test "reference conflict runs advertise the project-owned full validation job" do
    bundle = Config.bundle!()
    job = Map.fetch!(bundle.jobs, "full_validation")
    targeted = Map.fetch!(bundle.jobs, "targeted_validation")

    assert job.executable == "./elixir/scripts/symphony-full-validation.sh"
    assert job.arguments == []
    assert job.passthrough_arguments == :forbidden
    assert job.environment == %{}
    assert targeted.executable == "./elixir/scripts/symphony-targeted-validation.sh"
    assert targeted.arguments == []
    assert targeted.passthrough_arguments == :required
    assert targeted.environment == %{}

    run = %{
      "stage_id" => "merge_conflict",
      "frozen_bundle" => %{
        "jobs" => %{"full_validation" => job |> Map.from_struct() |> stringify_keys()}
      }
    }

    spec = Enum.find(DynamicTool.tool_specs(run), &(&1["name"] == "symphony_job_run"))

    assert get_in(spec, ["inputSchema", "properties", "job", "enum"]) == ["full_validation"]
  end

  test "project wrappers are executable and preserve targeted arguments literally" do
    source_root = Path.expand("..", File.cwd!())
    targeted = Path.join(source_root, "elixir/scripts/symphony-targeted-validation.sh")
    full = Path.join(source_root, "elixir/scripts/symphony-full-validation.sh")

    assert executable?(targeted)
    assert executable?(full)

    bin = Path.join(System.tmp_dir!(), "symphony-wrapper-bin-#{Ecto.UUID.generate()}")
    File.mkdir_p!(bin)
    mise = Path.join(bin, "mise")

    File.write!(mise, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n")
    File.chmod!(mise, 0o755)
    env = [{"PATH", bin <> ":" <> System.get_env("PATH")}]

    assert {targeted_output, 0} =
             System.cmd(
               targeted,
               ["test/one test.exs", "semi;dollar$wild*"],
               cd: source_root,
               env: env,
               stderr_to_stdout: true
             )

    assert String.split(targeted_output, "\n", trim: true) == [
             "exec",
             "--",
             "mix",
             "test",
             "test/one test.exs",
             "semi;dollar$wild*"
           ]

    assert {full_output, 0} =
             System.cmd(full, [], cd: source_root, env: env, stderr_to_stdout: true)

    assert String.split(full_output, "\n", trim: true) == ["exec", "--", "make", "all"]
  end

  defp executable?(path) do
    {:ok, stat} = File.stat(path)
    Bitwise.band(stat.mode, 0o111) != 0
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
