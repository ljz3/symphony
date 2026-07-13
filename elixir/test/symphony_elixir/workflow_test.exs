defmodule SymphonyElixir.WorkflowTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{AgentStage, BoardFactory, Workflow}

  test "loads one strict YAML/template bundle with the standard workflow" do
    source = BoardFactory.workflow_source()

    assert {:ok, bundle} = Workflow.load(source.workflow)
    assert bundle.project == %{id: "symphony", key: "SYM"}
    assert bundle.source.root == source.root
    assert bundle.source.default_branch == "main"

    assert bundle.columns |> Enum.map(& &1.name) |> Enum.take(5) ==
             ["Backlog", "Todo", "In Progress", "Automated Review", "Human Review"]

    assert {:ok, {"gpt-5.5", "xhigh"}} = AgentStage.singleton_pair(bundle.stages["implementation"])
    assert Workflow.Bundle.initial_column(bundle).id == "backlog"
    assert Workflow.Bundle.blocked_column(bundle).id == "blocked"
    assert Workflow.Bundle.done_column(bundle).id == "done"
    assert Workflow.Bundle.transition_allowed?(bundle, :agent, "in_progress", "automated_review")
    refute Workflow.Bundle.transition_allowed?(bundle, :human, "backlog", "done")
  end

  test "rejects unknown Solid variables before activation" do
    source = BoardFactory.workflow_source()
    path = Path.join(Path.dirname(source.workflow), "workflow/prompts/context.md")
    File.write!(path, "{{ uncurated.secret }}\n")

    assert {:error, {:template_parse_error, ^path, message}} = Workflow.load(source.workflow)
    assert message =~ "Undefined variable"
  end

  test "validates Solid templates against realistic empty first-run assigns" do
    source = BoardFactory.workflow_source()
    path = Path.join(Path.dirname(source.workflow), "workflow/prompts/context.md")

    File.write!(path, """
    {% if github %}{{ github.number }}{% endif %}
    {% if dependencies %}{{ dependencies[0].identifier }}{% endif %}
    {% if prior_handoffs %}{{ prior_handoffs[0].run_id }}{% endif %}
    """)

    assert {:error, {:template_parse_error, ^path, message}} = Workflow.load(source.workflow)
    assert message =~ "Undefined variable"
  end

  test "renders empty-safe context without empty conditional headings" do
    source = BoardFactory.workflow_source()
    path = Path.join(Path.dirname(source.workflow), "workflow/prompts/context.md")

    template = """
    {% if dependencies.size > 0 %}
    Dependencies:
    {% for dependency in dependencies %}- {{ dependency.identifier }}{% endfor %}
    {% endif %}
    {% if github != empty %}
    Pull request: {{ github.number }}
    {% endif %}
    {% if prior_handoffs.size > 0 %}
    Prior run handoffs:
    {% for handoff in prior_handoffs %}- {{ handoff.run_id }}{% endfor %}
    {% endif %}
    """

    File.write!(path, template)
    assert {:ok, _bundle} = Workflow.load(source.workflow)

    rendered =
      template
      |> Solid.parse!()
      |> Solid.render!(
        %{"github" => %{}, "dependencies" => [], "prior_handoffs" => []},
        strict_variables: true,
        strict_filters: true
      )
      |> IO.iodata_to_binary()

    refute rendered =~ "Dependencies:"
    refute rendered =~ "Pull request:"
    refute rendered =~ "Prior run handoffs:"
  end

  test "rejects user-visible schema versions and unknown configuration" do
    source = BoardFactory.workflow_source()
    yaml = File.read!(source.workflow)
    File.write!(source.workflow, "schema_version: 1\n" <> yaml)
    assert {:error, :user_visible_schema_version_forbidden} = Workflow.load(source.workflow)

    File.write!(source.workflow, "mystery: true\n" <> yaml)
    assert {:error, {:unknown_workflow_keys, "workflow", ["mystery"]}} = Workflow.load(source.workflow)
  end
end
