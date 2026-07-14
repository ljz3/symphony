defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes strict run-scoped Symphony tools requested by Codex app-server turns.
  """

  alias SymphonyElixir.Board
  alias SymphonyElixir.Board.Commands
  alias SymphonyElixir.{GitHub, Task, TaskCreateTool, Workflow, Worktree}
  alias SymphonyElixir.Workflow.Bundle

  @context_tool "symphony_task_context"
  @workpad_read_tool "symphony_workpad_read"
  @workpad_write_tool "symphony_workpad_write"
  @acceptance_tool "symphony_acceptance_complete"
  @transition_tool "symphony_task_transition"
  @create_tool "symphony_task_create"

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    with {:ok, scope} <- scope(opts),
         {:ok, result} <- execute_scoped(tool, normalize_arguments(arguments), scope, opts) do
      success_response(result)
    else
      {:error, reason} -> failure_response(reason)
    end
  rescue
    error -> failure_response({:tool_exception, Exception.message(error)})
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      tool_spec(@context_tool, "Read the current task, run, dependencies, criteria, GitHub state, and allowed transitions.", %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{}
      }),
      tool_spec(@workpad_read_tool, "Read the current run's workpad or a terminal prior run's workpad for this task.", %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "run_id" => %{
            "type" => "string",
            "minLength" => 1,
            "description" => "Defaults to the active run; may select only a completed, failed, or stopped prior run of the same task."
          },
          "invocation" => %{"type" => "integer", "minimum" => 1}
        }
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
  end

  defp execute_scoped(@context_tool, _arguments, scope, _opts) do
    with {:ok, bundle} <- Workflow.current() do
      dependencies =
        Enum.flat_map(scope.task.dependencies, &dependency_context/1)

      allowed_ids = Map.get(bundle.agent_transitions, scope.task.column_id, [])
      allowed = bundle.columns |> Enum.filter(&(&1.id in allowed_ids)) |> Enum.map(&Map.from_struct/1)

      {:ok,
       %{
         task: Task.to_map(scope.task),
         run: scope.run,
         dependencies: dependencies,
         github: scope.task.github,
         allowed_transitions: allowed
       }}
    end
  end

  defp execute_scoped(@workpad_read_tool, arguments, scope, opts) do
    invocation = argument(arguments, "invocation", Keyword.get(opts, :invocation, 1))

    with {:ok, target_run} <- readable_workpad_run(arguments, scope),
         {:ok, content} <- Board.read_workpad(target_run["id"], invocation) do
      {:ok,
       %{
         run_id: target_run["id"],
         task_id: target_run["task_id"],
         stage_id: target_run["stage_id"],
         status: target_run["status"],
         finished_at: target_run["finished_at"],
         invocation: invocation,
         content: content
       }}
    else
      {:error, :not_found} -> {:error, {:workpad_not_found, argument(arguments, "run_id", scope.run["id"]), invocation}}
      {:error, reason} -> {:error, reason}
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

  defp execute_scoped(@transition_tool, arguments, scope, opts) do
    with {:ok, column_id} <- required_string(arguments, "column_id"),
         true <- column_id != scope.task.column_id,
         {:ok, revision} <- required_revision(arguments) do
      transition(scope, column_id, argument(arguments, "reason"), revision, opts)
    else
      false -> {:error, :transition_must_change_column}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_scoped(@create_tool, arguments, scope, opts) do
    attrs = Map.put(arguments, "priority", argument(arguments, "priority", "Normal"))

    board_execute(%Commands.CreateTask{attrs: attrs}, 0, scope, opts)
  end

  defp execute_scoped(tool, _arguments, _scope, _opts) do
    {:error, {:unsupported_dynamic_tool, tool, supported_tool_names()}}
  end

  defp dependency_context(id) do
    case Board.task(id) do
      {:ok, task} -> [Task.to_map(task)]
      _ -> []
    end
  end

  defp readable_workpad_run(arguments, scope) do
    requested_run_id = argument(arguments, "run_id", scope.run["id"])

    if requested_run_id == scope.run["id"] do
      {:ok, scope.run}
    else
      case Board.run(requested_run_id) do
        {:ok, %{"task_id" => task_id, "status" => status} = run}
        when task_id == scope.task.id and status in ["completed", "failed", "stopped"] ->
          {:ok, run}

        _ ->
          {:error, :workpad_run_not_readable}
      end
    end
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
      board_execute(
        %Commands.MoveTask{task_id: scope.task.id, column_id: column_id, reason: reason},
        revision,
        scope,
        opts
      )
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

  defp board_execute(command, expected_revision, scope, opts) do
    executor = Keyword.get(opts, :board_executor, &Board.execute/2)
    call_id = Keyword.fetch!(opts, :call_id) |> to_string()
    suffix = Keyword.get(opts, :idempotency_suffix)
    base_key = "dynamic-tool:#{scope.run["id"]}:#{call_id}"
    key = if suffix, do: "#{base_key}:#{suffix}", else: base_key

    executor.(command,
      actor: %{type: :agent, identity: scope.run["id"]},
      expected_revision: expected_revision,
      idempotency_key: key
    )
  end

  defp scope(opts) do
    with task_id when is_binary(task_id) <- Keyword.get(opts, :task_id),
         run_id when is_binary(run_id) <- Keyword.get(opts, :run_id),
         {:ok, task} <- Board.task(task_id),
         {:ok, run} <- Board.run(run_id),
         true <- run["task_id"] == task.id,
         true <- task.active_run_id == run_id,
         true <- run["status"] in ["starting", "running", "stopping"] do
      {:ok, %{task: task, run: run}}
    else
      false -> {:error, :tool_scope_not_active}
      nil -> {:error, :tool_scope_required}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_arguments(arguments) when is_map(arguments), do: stringify_keys(arguments)
  defp normalize_arguments(nil), do: %{}
  defp normalize_arguments(_arguments), do: %{}

  defp required_string(arguments, key), do: arguments |> Map.get(key) |> nonempty(key)

  defp required_nonempty_list(arguments, key) do
    case arguments[key] do
      values when is_list(values) and values != [] -> {:ok, values}
      _ -> {:error, {:nonempty_list_required, key}}
    end
  end

  defp required_revision(arguments) do
    case arguments["expected_revision"] do
      revision when is_integer(revision) and revision >= 0 -> {:ok, revision}
      _ -> {:error, :expected_revision_required}
    end
  end

  defp argument(arguments, key, default \\ nil), do: Map.get(arguments, key, default)

  defp nonempty(value, key) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: {:error, {:nonempty_string_required, key}}, else: {:ok, value}
  end

  defp nonempty(_value, key), do: {:error, {:nonempty_string_required, key}}

  defp tool_spec(name, description, schema) do
    %{"name" => name, "description" => description, "inputSchema" => schema}
  end

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
