defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes strict run-scoped Symphony tools requested by Codex app-server turns.
  """

  alias SymphonyElixir.Board
  alias SymphonyElixir.Board.Commands
  alias SymphonyElixir.{CurrentState, GitHub, JobManager, MergeConflictResolution, TaskCreateTool, Workflow, Worktree}
  alias SymphonyElixir.Workflow.Bundle

  @context_tool "symphony_task_context"
  @workpad_read_tool "symphony_workpad_read"
  @workpad_write_tool "symphony_workpad_write"
  @acceptance_tool "symphony_acceptance_complete"
  @review_tool "symphony_review_complete"
  @transition_tool "symphony_task_transition"
  @create_tool "symphony_task_create"
  @job_tool "symphony_job_run"

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    with {:ok, scope} <- scope(tool, opts),
         {:ok, normalized_arguments} <- normalize_arguments(arguments),
         {:ok, result} <- execute_scoped(tool, normalized_arguments, scope, opts) do
      success_response(result)
    else
      {:error, reason} -> failure_response(reason)
    end
  rescue
    error -> failure_response({:tool_exception, Exception.message(error)})
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    tool_specs(nil)
  end

  @spec tool_specs(map() | nil) :: [map()]
  def tool_specs(run) do
    task_tools = [
      tool_spec(@context_tool, "Read the current task, run, dependencies, criteria, GitHub state, and allowed transitions.", %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{}
      }),
      tool_spec(@workpad_read_tool, "Read the one latest meaningful workpad selected for this task.", %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{}
      }),
      tool_spec(@workpad_write_tool, "Replace this run's private durable workpad content.", %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["content"],
        "properties" => %{
          "content" => %{"type" => "string", "minLength" => 1},
          "invocation" => %{"type" => "integer", "minimum" => 1}
        }
      }),
      tool_spec(@acceptance_tool, "Complete one acceptance criterion with concrete evidence.", %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["criterion_id", "evidence", "expected_revision"],
        "properties" => %{
          "criterion_id" => %{"type" => "string", "minLength" => 1},
          "evidence" => %{"type" => "array", "minItems" => 1, "items" => %{"type" => "object"}},
          "expected_revision" => %{"type" => "integer", "minimum" => 0}
        }
      }),
      tool_spec(@transition_tool, "Transition the running task to a permitted different workflow column.", %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["column_id", "expected_revision"],
        "properties" => %{
          "column_id" => %{"type" => "string", "minLength" => 1},
          "reason" => %{"type" => ["string", "null"]},
          "expected_revision" => %{"type" => "integer", "minimum" => 0}
        }
      }),
      tool_spec(@create_tool, TaskCreateTool.dynamic_description(), TaskCreateTool.input_schema(false))
    ]

    task_tools = if review_tool_available?(run), do: List.insert_at(task_tools, 4, review_tool_spec()), else: task_tools

    case frozen_jobs(run) |> Map.keys() |> Enum.sort() do
      [] -> task_tools
      names -> task_tools ++ [job_tool_spec(names)]
    end
  end

  defp execute_scoped(@context_tool, arguments, scope, _opts) do
    with :ok <- empty_arguments(arguments, @context_tool),
         {:ok, bundle} <- Workflow.current() do
      {:ok, CurrentState.project(scope.task, scope.run, bundle)}
    end
  end

  defp execute_scoped(@workpad_read_tool, arguments, scope, _opts) do
    with :ok <- empty_arguments(arguments, @workpad_read_tool) do
      {:ok, Board.latest_workpad(scope.task.id, scope.run["id"])}
    end
  end

  defp execute_scoped(@workpad_write_tool, arguments, scope, opts) do
    invocation = argument(arguments, "invocation", Keyword.get(opts, :invocation, 1))

    with {:ok, content} <- required_string(arguments, "content"),
         :ok <- Board.write_workpad(scope.run["id"], invocation, content) do
      {:ok, %{run_id: scope.run["id"], invocation: invocation, bytes: byte_size(content)}}
    end
  end

  defp execute_scoped(@acceptance_tool, arguments, scope, opts) do
    with {:ok, criterion_id} <- required_string(arguments, "criterion_id"),
         {:ok, evidence} <- required_nonempty_list(arguments, "evidence"),
         {:ok, revision} <- required_revision(arguments) do
      board_execute(
        %Commands.CompleteAcceptance{
          task_id: scope.task.id,
          criterion_id: criterion_id,
          evidence: evidence
        },
        revision,
        scope,
        opts
      )
    end
  end

  defp execute_scoped(@review_tool, arguments, scope, opts) do
    worktree = scope.run["workspace_path"] || Worktree.path(scope.task)
    snapshotter = Keyword.get(opts, :review_snapshotter, &GitHub.review_snapshot/3)

    with {:ok, verdict} <- required_enum(arguments, "verdict", ["pass", "rework"]),
         {:ok, reviewed_head_sha} <- required_sha(arguments, "reviewed_head_sha"),
         {:ok, route} <- required_string(arguments, "route"),
         {:ok, plan_policy} <- required_plan_policy(arguments),
         {:ok, validation_evidence} <- required_validation_evidence(arguments),
         {:ok, findings} <- required_findings(arguments),
         {:ok, revision} <- required_revision(arguments),
         {:ok, provider_snapshot} <-
           snapshotter.(scope.task, worktree, worker_host: scope.run["worker_host"]) do
      board_execute(
        %Commands.RecordReviewAttestation{
          task_id: scope.task.id,
          run_id: scope.run["id"],
          verdict: verdict,
          reviewed_head_sha: reviewed_head_sha,
          route: route,
          plan_policy: plan_policy,
          validation_evidence: validation_evidence,
          findings: findings,
          provider_snapshot: provider_snapshot
        },
        revision,
        scope,
        opts
      )
    end
  end

  defp execute_scoped(@transition_tool, arguments, scope, opts) do
    with {:ok, column_id} <- required_string(arguments, "column_id"),
         {:ok, revision} <- required_revision(arguments) do
      cond do
        column_id == scope.task.column_id and replayable_conflict_completion?(scope, column_id) ->
          replay_conflict_completion(scope, revision, opts)

        column_id == scope.task.column_id ->
          {:error, :transition_must_change_column}

        scope.active? ->
          transition(scope, column_id, argument(arguments, "reason"), revision, opts)

        true ->
          {:error, :tool_scope_not_active}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_scoped(@create_tool, arguments, scope, opts) do
    attrs = Map.put(arguments, "priority", argument(arguments, "priority", "Normal"))

    board_execute(%Commands.CreateTask{attrs: attrs}, 0, scope, opts)
  end

  defp execute_scoped(@job_tool, arguments, scope, opts) do
    jobs = frozen_jobs(scope.run)

    with {:ok, job_name} <- required_string(arguments, "job"),
         {:ok, passthrough} <- required_string_list(arguments, "arguments"),
         {:ok, job} <- fetch_job(jobs, job_name),
         workspace when is_binary(workspace) <- scope.run["workspace_path"],
         source_fingerprint when is_binary(source_fingerprint) <-
           JobManager.source_fingerprint(workspace, scope.run["worker_host"]),
         {:ok, result} <-
           JobManager.run(%{
             task_id: scope.task.id,
             task_identifier: scope.task.identifier,
             task_branch: scope.task.branch,
             run_id: scope.run["id"],
             call_id: to_string(Keyword.fetch!(opts, :call_id)),
             job: job,
             arguments: passthrough,
             workspace: workspace,
             worker_host: scope.run["worker_host"],
             source_fingerprint: source_fingerprint
           }) do
      {:ok, result}
    else
      nil -> {:error, :job_workspace_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_scoped(tool, _arguments, _scope, _opts) do
    {:error, {:unsupported_dynamic_tool, tool, supported_tool_names()}}
  end

  defp transition(scope, "blocked", reason, revision, opts) do
    with {:ok, reason} <- nonempty(reason, :blocked_transition_reason) do
      board_execute(
        %Commands.RunFailed{task_id: scope.task.id, run_id: scope.run["id"], reason: reason},
        revision,
        scope,
        opts
      )
    end
  end

  defp transition(scope, column_id, reason, revision, opts) do
    with {:ok, bundle} <- Workflow.current(),
         column when not is_nil(column) <- Bundle.column(bundle, column_id),
         {:ok, revision} <- maybe_complete_external_saga(scope, column, revision, opts) do
      if conflict_review_transition?(scope.task, column_id, bundle) do
        complete_conflict_resolution(scope, revision, opts)
      else
        board_execute(
          %Commands.MoveTask{task_id: scope.task.id, column_id: column_id, reason: reason},
          revision,
          scope,
          opts
        )
      end
    else
      nil -> {:error, {:unknown_column, column_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_complete_external_saga(scope, %{mark_pr_ready: true}, revision, opts) do
    worktree = scope.run["workspace_path"] || Worktree.path(scope.task)

    with {:ok, readiness} <- GitHub.mark_ready(scope.task, worktree, worker_host: scope.run["worker_host"]),
         {:ok, result} <-
           board_execute(
             %Commands.RecordGitHubOutcome{task_id: scope.task.id, kind: "ready", attrs: readiness},
             revision,
             scope,
             Keyword.put(opts, :idempotency_suffix, "ready")
           ) do
      {:ok, get_in(result, ["task", "revision"])}
    end
  end

  defp maybe_complete_external_saga(scope, %{publish_workpad: true}, revision, opts) do
    worktree = scope.run["workspace_path"] || Worktree.path(scope.task)
    publisher = Keyword.get(opts, :workpad_publisher, &GitHub.publish_workpads/3)

    case publisher.(scope.task, worktree, worker_host: scope.run["worker_host"]) do
      {:ok, _publication_id} -> {:ok, revision}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_complete_external_saga(scope, %{satisfies_dependencies: true}, revision, opts) do
    worktree = scope.run["workspace_path"] || Worktree.path(scope.task)

    with {:ok, merged} <- GitHub.merged_and_reachable(scope.task, worktree, worker_host: scope.run["worker_host"]),
         {:ok, result} <-
           board_execute(
             %Commands.RecordGitHubOutcome{task_id: scope.task.id, kind: "merged", attrs: merged},
             revision,
             scope,
             Keyword.put(opts, :idempotency_suffix, "merged")
           ) do
      {:ok, get_in(result, ["task", "revision"])}
    end
  end

  defp maybe_complete_external_saga(_scope, _column, revision, _opts), do: {:ok, revision}

  defp complete_conflict_resolution(scope, revision, opts) do
    worktree = scope.run["workspace_path"] || Worktree.path(scope.task)
    verifier = Keyword.get(opts, :conflict_resolution_verifier, &MergeConflictResolution.verify/4)
    verification_opts = Keyword.put(opts, :worker_host, scope.run["worker_host"])

    with {:ok, proof} <- verifier.(scope.task, scope.run, worktree, verification_opts) do
      board_execute(
        %Commands.CompleteMergeConflictResolution{
          task_id: scope.task.id,
          run_id: scope.run["id"],
          proof: proof
        },
        revision,
        scope,
        opts
      )
    end
  end

  defp replay_conflict_completion(scope, revision, opts) do
    proof = get_in(scope.task.merge_saga, ["resolution"]) || %{}

    case board_execute(
           %Commands.CompleteMergeConflictResolution{
             task_id: scope.task.id,
             run_id: scope.run["id"],
             proof: proof
           },
           revision,
           scope,
           opts
         ) do
      {:ok, result} -> {:ok, result}
      {:error, _reason} -> {:error, :transition_must_change_column}
    end
  end

  defp conflict_review_transition?(task, column_id, %{merge: %{} = merge}) do
    task.column_id == merge.conflict_column and column_id == merge.review_column
  end

  defp conflict_review_transition?(_task, _column_id, _bundle), do: false

  defp replayable_conflict_completion?(scope, column_id) do
    resolution = get_in(scope.task.merge_saga, ["resolution"])

    column_id == scope.task.column_id and
      get_in(scope.task.merge_saga, ["checkpoint"]) == "conflict_resolved" and
      scope.run["start_column_id"] != scope.task.column_id and is_map(resolution) and
      resolution["run_id"] == scope.run["id"]
  end

  defp board_execute(command, expected_revision, scope, opts) do
    executor = Keyword.get(opts, :board_executor, &Board.execute/2)
    call_id = Keyword.fetch!(opts, :call_id) |> to_string()
    suffix = Keyword.get(opts, :idempotency_suffix)
    base_key = "dynamic-tool:#{scope.run["id"]}:#{call_id}"
    key = if suffix, do: "#{base_key}:#{suffix}", else: base_key

    with {:ok, result} <-
           executor.(command,
             actor: %{type: :agent, identity: scope.run["id"]},
             expected_revision: expected_revision,
             idempotency_key: key
           ) do
      {:ok, compact_mutation_result(result)}
    end
  end

  defp scope(tool, opts) do
    with task_id when is_binary(task_id) <- Keyword.get(opts, :task_id),
         run_id when is_binary(run_id) <- Keyword.get(opts, :run_id),
         {:ok, task} <- Board.task(task_id),
         {:ok, run} <- Board.run(run_id),
         true <- run["task_id"] == task.id do
      active? = task.active_run_id == run_id and run["status"] in ["starting", "running", "stopping"]

      if active? or tool == @transition_tool,
        do: {:ok, %{task: task, run: run, active?: active?}},
        else: {:error, :tool_scope_not_active}
    else
      false -> {:error, :tool_scope_not_active}
      nil -> {:error, :tool_scope_required}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_arguments(arguments) when is_map(arguments), do: {:ok, stringify_keys(arguments)}
  defp normalize_arguments(_arguments), do: {:error, :tool_arguments_must_be_object}

  defp required_string(arguments, key), do: arguments |> Map.get(key) |> nonempty(key)

  defp required_nonempty_list(arguments, key) do
    case arguments[key] do
      values when is_list(values) and values != [] -> {:ok, values}
      _ -> {:error, {:nonempty_list_required, key}}
    end
  end

  defp required_string_list(arguments, key) do
    case arguments[key] do
      values when is_list(values) ->
        if Enum.all?(values, &is_binary/1),
          do: {:ok, values},
          else: {:error, {:string_list_required, key}}

      _ ->
        {:error, {:string_list_required, key}}
    end
  end

  defp required_revision(arguments) do
    case arguments["expected_revision"] do
      revision when is_integer(revision) and revision >= 0 -> {:ok, revision}
      _ -> {:error, :expected_revision_required}
    end
  end

  defp required_sha(arguments, key) do
    with {:ok, sha} <- required_string(arguments, key),
         true <- Regex.match?(~r/\A[0-9a-f]{40,64}\z/i, sha) do
      {:ok, sha}
    else
      false -> {:error, {:invalid_git_sha, key}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp required_enum(arguments, key, allowed) do
    case Map.get(arguments, key) do
      value -> if value in allowed, do: {:ok, value}, else: {:error, {:invalid_enum, key, allowed}}
    end
  end

  defp required_plan_policy(%{"plan_policy" => %{} = policy}) do
    status = policy["status"]
    summary = policy["summary"]

    if Map.keys(policy) |> Enum.sort() == ["status", "summary"] and
         status in ["not_required", "followed", "deviation"] and nonblank_string?(summary),
       do: {:ok, policy},
       else: {:error, :invalid_review_plan_policy}
  end

  defp required_plan_policy(_arguments), do: {:error, :invalid_review_plan_policy}

  defp required_validation_evidence(%{"validation_evidence" => evidence})
       when is_list(evidence) and evidence != [] do
    if Enum.all?(evidence, &valid_validation_evidence?/1),
      do: {:ok, evidence},
      else: {:error, :invalid_review_validation_evidence}
  end

  defp required_validation_evidence(_arguments), do: {:error, :invalid_review_validation_evidence}

  defp valid_validation_evidence?(evidence) when is_map(evidence) do
    allowed = ~w(artifact command exit_status result)

    Enum.all?(Map.keys(evidence), &(&1 in allowed)) and nonblank_string?(evidence["command"]) and
      nonblank_string?(evidence["result"]) and optional_string?(evidence["artifact"]) and
      (is_nil(evidence["exit_status"]) or is_integer(evidence["exit_status"]))
  end

  defp valid_validation_evidence?(_evidence), do: false

  defp required_findings(%{"findings" => findings}) when is_list(findings) do
    if Enum.all?(findings, &valid_finding?/1),
      do: {:ok, findings},
      else: {:error, :invalid_review_findings}
  end

  defp required_findings(_arguments), do: {:error, :invalid_review_findings}

  defp valid_finding?(finding) when is_map(finding) do
    allowed = ~w(line path severity summary)

    Enum.all?(Map.keys(finding), &(&1 in allowed)) and
      finding["severity"] in ["blocker", "high", "medium", "low", "note"] and
      nonblank_string?(finding["summary"]) and optional_string?(finding["path"]) and
      (is_nil(finding["line"]) or (is_integer(finding["line"]) and finding["line"] > 0))
  end

  defp valid_finding?(_finding), do: false

  defp empty_arguments(arguments, _tool) when map_size(arguments) == 0, do: :ok
  defp empty_arguments(_arguments, tool), do: {:error, {:tool_takes_no_arguments, tool}}

  defp argument(arguments, key, default \\ nil), do: Map.get(arguments, key, default)

  defp nonempty(value, key) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: {:error, {:nonempty_string_required, key}}, else: {:ok, value}
  end

  defp nonempty(_value, key), do: {:error, {:nonempty_string_required, key}}

  defp nonblank_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp optional_string?(nil), do: true
  defp optional_string?(value), do: is_binary(value)

  defp tool_spec(name, description, schema) do
    %{"name" => name, "description" => description, "inputSchema" => schema}
  end

  defp job_tool_spec(names) do
    tool_spec(
      @job_tool,
      "Run one configured project job and wait for its terminal result without polling.",
      %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["job", "arguments"],
        "properties" => %{
          "job" => %{"type" => "string", "enum" => names},
          "arguments" => %{"type" => "array", "items" => %{"type" => "string"}}
        }
      }
    )
  end

  defp review_tool_spec do
    tool_spec(
      @review_tool,
      "Record an exact-head automated-review verdict, evidence, findings, and permitted route.",
      %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ~w(expected_revision verdict reviewed_head_sha route plan_policy validation_evidence findings),
        "properties" => %{
          "expected_revision" => %{"type" => "integer", "minimum" => 0},
          "verdict" => %{"type" => "string", "enum" => ["pass", "rework"]},
          "reviewed_head_sha" => %{"type" => "string", "pattern" => "^[0-9a-fA-F]{40,64}$"},
          "route" => %{"type" => "string", "minLength" => 1},
          "plan_policy" => review_plan_policy_schema(),
          "validation_evidence" => review_validation_schema(),
          "findings" => review_findings_schema()
        }
      }
    )
  end

  defp review_plan_policy_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["status", "summary"],
      "properties" => %{
        "status" => %{"type" => "string", "enum" => ["not_required", "followed", "deviation"]},
        "summary" => %{"type" => "string", "minLength" => 1}
      }
    }
  end

  defp review_validation_schema do
    %{
      "type" => "array",
      "minItems" => 1,
      "items" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["command", "result"],
        "properties" => %{
          "command" => %{"type" => "string", "minLength" => 1},
          "result" => %{"type" => "string", "minLength" => 1},
          "artifact" => %{"type" => ["string", "null"]},
          "exit_status" => %{"type" => ["integer", "null"]}
        }
      }
    }
  end

  defp review_findings_schema do
    %{
      "type" => "array",
      "items" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["severity", "summary"],
        "properties" => %{
          "severity" => %{"type" => "string", "enum" => ["blocker", "high", "medium", "low", "note"]},
          "summary" => %{"type" => "string", "minLength" => 1},
          "path" => %{"type" => ["string", "null"]},
          "line" => %{"type" => ["integer", "null"], "minimum" => 1}
        }
      }
    }
  end

  defp review_tool_available?(nil), do: true

  defp review_tool_available?(%{"stage_id" => stage_id}) do
    case Workflow.current() do
      {:ok, %{merge: %{} = merge} = bundle} ->
        case Bundle.column(bundle, merge.review_column) do
          %{stage_id: ^stage_id} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp review_tool_available?(_run), do: false

  defp frozen_jobs(%{"frozen_bundle" => %{"jobs" => jobs}}) when is_map(jobs), do: jobs
  defp frozen_jobs(_run), do: %{}

  defp fetch_job(jobs, name) do
    case Map.fetch(jobs, name) do
      {:ok, job} -> {:ok, job}
      :error -> {:error, {:unknown_project_job, name, jobs |> Map.keys() |> Enum.sort()}}
    end
  end

  defp compact_mutation_result(result) do
    %{
      "event_type" => result["event_type"],
      "task" => compact_mutation_task(result["task"]),
      "run" => compact_mutation_run(result["run"])
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp compact_mutation_task(task) when is_map(task) do
    Map.take(task, ~w(revision column_id))
  end

  defp compact_mutation_task(_task), do: nil

  defp compact_mutation_run(run) when is_map(run), do: Map.take(run, ~w(status))
  defp compact_mutation_run(_run), do: nil

  defp success_response(payload), do: response(true, payload)
  defp failure_response(reason), do: response(false, %{error: %{reason: inspect(reason)}})

  defp response(success, payload) do
    output = Jason.encode!(payload, pretty: true)

    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp supported_tool_names, do: Enum.map(tool_specs(), & &1["name"])

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
