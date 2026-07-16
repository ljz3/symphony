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
    {% if latest_workpad %}{{ latest_workpad.run_id }}{% endif %}
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
    {% if latest_workpad %}
    Latest workpad: {{ latest_workpad.run_id }}
    {% endif %}
    """

    File.write!(path, template)
    assert {:ok, _bundle} = Workflow.load(source.workflow)

    rendered =
      template
      |> Solid.parse!()
      |> Solid.render!(
        %{"github" => %{}, "dependencies" => [], "latest_workpad" => nil},
        strict_variables: true,
        strict_filters: true
      )
      |> IO.iodata_to_binary()

    refute rendered =~ "Dependencies:"
    refute rendered =~ "Pull request:"
    refute rendered =~ "Latest workpad:"
  end

  test "rejects user-visible schema versions and unknown configuration" do
    source = BoardFactory.workflow_source()
    yaml = File.read!(source.workflow)
    File.write!(source.workflow, "schema_version: 1\n" <> yaml)
    assert {:error, :user_visible_schema_version_forbidden} = Workflow.load(source.workflow)

    File.write!(source.workflow, "mystery: true\n" <> yaml)
    assert {:error, {:unknown_workflow_keys, "workflow", ["mystery"]}} = Workflow.load(source.workflow)
  end

  test "loads the deadline-free jobs, preflight, and deterministic merge foundation" do
    source = BoardFactory.workflow_source()

    source.workflow
    |> File.read!()
    |> String.replace(
      "  - id: merging\n    name: Merging\n    role: dispatch\n    stage: merging",
      "  - id: merging\n    name: Merging\n    role: merge"
    )
    |> Kernel.<>("""

    jobs:
      targeted_validation:
        executable: ./scripts/validate.sh
        arguments: [targeted, --run-id, $SYMPHONY_JOB_ID]
        passthrough_arguments: required
        environment:
          DEVELOPER_DIR: /Applications/Xcode.app/Contents/Developer
    dispatch:
      preflight:
        command: ./scripts/symphony-preflight.sh
        retry_after_failure_ms: 30000
    merge:
      method: squash
      readiness_command: ./scripts/symphony-merge-readiness.sh
      review_column: automated_review
      conflict_column: rework
    """)
    |> then(&File.write!(source.workflow, &1))

    assert {:ok, bundle} = Workflow.load(source.workflow)

    assert bundle.jobs["targeted_validation"].executable == "./scripts/validate.sh"

    assert bundle.jobs["targeted_validation"].arguments == [
             "targeted",
             "--run-id",
             "$SYMPHONY_JOB_ID"
           ]

    assert bundle.jobs["targeted_validation"].passthrough_arguments == :required

    assert bundle.jobs["targeted_validation"].environment == %{
             "DEVELOPER_DIR" => "/Applications/Xcode.app/Contents/Developer"
           }

    assert bundle.dispatch.preflight == %{
             command: "./scripts/symphony-preflight.sh",
             retry_after_failure_ms: 30_000
           }

    assert bundle.merge == %{
             method: :squash,
             readiness_command: "./scripts/symphony-merge-readiness.sh",
             review_column: "automated_review",
             conflict_column: "rework"
           }

    assert Workflow.Bundle.column(bundle, "merging").role == :merge
    refute Workflow.Bundle.column(bundle, "merging").stage_id
  end

  test "rejects execution deadline and output-cap keys with a migration error" do
    source = BoardFactory.workflow_source()
    original = File.read!(source.workflow)

    merge_workflow = fn key ->
      original
      |> String.replace(
        "  - id: merging\n    name: Merging\n    role: dispatch\n    stage: merging",
        "  - id: merging\n    name: Merging\n    role: merge"
      )
      |> Kernel.<>("""

      merge:
        method: squash
        readiness_command: ./merge-readiness.sh
        review_column: automated_review
        conflict_column: rework
        #{key}: 1
      """)
    end

    cases = [
      {"agent", "max_turns_per_run", insert_under(original, "agent:", "  max_turns_per_run: 2")},
      {"codex", "turn_timeout_ms", insert_under(original, "codex:", "  turn_timeout_ms: 1")},
      {"codex", "read_timeout_ms", insert_under(original, "codex:", "  read_timeout_ms: 1")},
      {"codex", "stall_timeout_ms", insert_under(original, "codex:", "  stall_timeout_ms: 1")},
      {"hooks", "timeout_ms", insert_under(original, "hooks:", "  timeout_ms: 1")},
      {"jobs.validation", "max_output_bytes",
       original <>
         """

         jobs:
           validation:
             executable: ./validate.sh
             arguments: []
             passthrough_arguments: forbidden
             environment: {}
             max_output_bytes: 1
         """},
      {"jobs.validation", "timeout_ms",
       original <>
         """

         jobs:
           validation:
             executable: ./validate.sh
             arguments: []
             passthrough_arguments: forbidden
             environment: {}
             timeout_ms: 1
         """},
      {"dispatch.preflight", "timeout_ms",
       original <>
         """

         dispatch:
           preflight:
             command: ./preflight.sh
             retry_after_failure_ms: 1
             timeout_ms: 1
         """},
      {"dispatch.preflight", "max_output_bytes",
       original <>
         """

         dispatch:
           preflight:
             command: ./preflight.sh
             retry_after_failure_ms: 1
             max_output_bytes: 1
         """},
      {"merge", "readiness_timeout_ms", merge_workflow.("readiness_timeout_ms")},
      {"merge", "max_output_bytes", merge_workflow.("max_output_bytes")}
    ]

    Enum.each(cases, fn {context, key, yaml} ->
      File.write!(source.workflow, yaml)

      assert {:error, {:execution_limits_forbidden, ^context, [^key]}} =
               Workflow.load(source.workflow)
    end)
  end

  test "rejects unknown nested job keys and non-reserved Symphony argument tokens" do
    source = BoardFactory.workflow_source()
    original = File.read!(source.workflow)

    job = """

    jobs:
      validation:
        executable: ./validate.sh
        arguments: [$SYMPHONY_TASK_ID]
        passthrough_arguments: forbidden
        environment: {}
    """

    File.write!(source.workflow, original <> job)

    assert {:error, {:invalid_job_argument_token, "validation", "$SYMPHONY_TASK_ID"}} =
             Workflow.load(source.workflow)

    File.write!(source.workflow, original <> String.replace(job, "$SYMPHONY_TASK_ID", "literal") <> "    mystery: true\n")

    assert {:error, {:unknown_workflow_keys, "jobs.validation", ["mystery"]}} =
             Workflow.load(source.workflow)
  end

  test "requires merge policy for a merge role and dispatch targets for that policy" do
    source = BoardFactory.workflow_source()

    merge_role_workflow =
      source.workflow
      |> File.read!()
      |> String.replace(
        "  - id: merging\n    name: Merging\n    role: dispatch\n    stage: merging",
        "  - id: merging\n    name: Merging\n    role: merge"
      )

    File.write!(source.workflow, merge_role_workflow)
    assert {:error, {:merge_columns_require_configuration, ["merging"]}} = Workflow.load(source.workflow)

    File.write!(
      source.workflow,
      merge_role_workflow <>
        """

        merge:
          method: squash
          readiness_command: ./merge-readiness.sh
          review_column: human_review
          conflict_column: rework
        """
    )

    assert {:error, {:merge_target_not_dispatchable, :review, "human_review", :pause}} =
             Workflow.load(source.workflow)
  end

  defp insert_under(yaml, heading, line) do
    String.replace(yaml, heading <> "\n", heading <> "\n" <> line <> "\n", global: false)
  end
end
