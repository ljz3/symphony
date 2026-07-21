defmodule SymphonyElixir.WorkflowReloadPolicyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Board.WorkflowReloadPolicy
  alias SymphonyElixir.Task
  alias SymphonyElixir.Workflow

  test "preserves protected columns when selections become incompatible" do
    {:ok, bundle} = Workflow.load(Path.expand("../../WORKFLOW.yml", __DIR__))
    changed_bundle = incompatible_bundle(bundle)

    tasks =
      Enum.map(~w(done blocked cancelled backlog todo in_progress human_review), fn column_id ->
        task(column_id)
      end)

    assert WorkflowReloadPolicy.incompatible_tasks(tasks, changed_bundle)
           |> Enum.map(& &1.column_id) == ["in_progress", "human_review"]
  end

  test "preserves tasks with an active runtime even outside protected columns" do
    {:ok, bundle} = Workflow.load(Path.expand("../../WORKFLOW.yml", __DIR__))
    changed_bundle = incompatible_bundle(bundle)

    assert WorkflowReloadPolicy.incompatible_tasks([task("in_progress", "running")], changed_bundle) == []
  end

  defp incompatible_bundle(bundle) do
    stage = %{bundle.stages["implementation"] | allowed: [{"codex", "reload-incompatible", "xhigh"}]}
    %{bundle | stages: Map.put(bundle.stages, "implementation", stage)}
  end

  defp task(column_id, runtime_state \\ nil) do
    %Task{
      id: Ecto.UUID.generate(),
      identifier: "FOODMAP-#{System.unique_integer([:positive])}",
      number: 1,
      project_id: "food-map",
      title: "Workflow reload policy test",
      type: "feature",
      branch: "feature/workflow-reload-policy-test",
      priority: "normal",
      brief: "",
      acceptance_criteria: [],
      column_id: column_id,
      rank: 1.0,
      revision: 1,
      stage_selections: %{
        "implementation" => %{"model" => "gpt-5.5", "effort" => "xhigh"}
      },
      runtime_state: runtime_state,
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
  end
end
