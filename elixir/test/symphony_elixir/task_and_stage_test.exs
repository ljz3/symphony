defmodule SymphonyElixir.TaskAndStageTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{AgentStage, Config, Task}

  test "task branches and priority weights are deterministic" do
    assert Task.branch_for(:feature, "SYM-1") == "feature/SYM-1"
    assert Task.branch_for(:bug_fix, "SYM-2") == "fix/SYM-2"
    assert Task.branch_for(:chore, "SYM-3") == "chore/SYM-3"
    assert Enum.map([:urgent, :high, :normal, :low], &Task.priority_weight/1) == [0, 1, 2, 3]
  end

  test "task maps preserve booleans and nil while round-tripping enums" do
    task = task_fixture()
    map = Task.to_map(task)

    assert map["archived_at"] == nil
    assert get_in(map, ["acceptance_criteria", Access.at(0), "completed"]) == false
    assert map["type"] == "feature"
    assert map["priority"] == "normal"
    assert Task.from_map(map) == task
    refute Task.archived?(task)
    assert Task.archived?(%{task | archived_at: "now"})
  end

  test "terminal state follows the active workflow roles" do
    bundle = Config.bundle!()
    refute Task.terminal?(task_fixture(), bundle)
    assert Task.terminal?(%{task_fixture() | column_id: "done"}, bundle)
  end

  test "agent stage enumerates, resolves, and validates model effort pairs" do
    stage = %AgentStage{
      id: "review",
      prompt_path: "prompt.md",
      prompt: "prompt",
      workpad_template_path: "workpad.md",
      workpad_template: "workpad",
      allowed_model_efforts: %{"b" => ["low", "high"], "a" => ["medium"]}
    }

    assert AgentStage.pairs(stage) == [{"a", "medium"}, {"b", "low"}, {"b", "high"}]
    assert AgentStage.singleton_pair(stage) == :multiple
    assert AgentStage.permits?(stage, "b", "high")
    refute AgentStage.permits?(stage, "b", "medium")

    singleton = %{stage | allowed_model_efforts: %{"a" => ["medium"]}}
    assert AgentStage.singleton_pair(singleton) == {:ok, {"a", "medium"}}
  end

  defp task_fixture do
    %Task{
      id: "id",
      identifier: "SYM-1",
      number: 1,
      project_id: "symphony",
      title: "Title",
      type: :feature,
      branch: "feature/SYM-1",
      priority: :normal,
      brief: "Brief",
      acceptance_criteria: [
        %{"id" => "criterion", "text" => "Works", "completed" => false, "evidence" => [], "evidence_history" => []}
      ],
      column_id: "backlog",
      rank: 1_024,
      revision: 1,
      created_at: "now",
      updated_at: "now"
    }
  end
end
