defmodule SymphonyElixir.MCP.Handler do
  @moduledoc """
  MCP handler for Symphony's guarded task creation and narrow read-only task views.

  The external MCP surface is intentionally limited to the three tool definitions
  returned by `handle_list_tools/2`. Read presenters only copy explicitly safe
  fields from the canonical board projection.
  """

  @behaviour MCP.Server.Handler

  require Logger

  alias MCP.Server.ToolContext
  alias SymphonyElixir.Board
  alias SymphonyElixir.Board.Commands
  alias SymphonyElixir.Task
  alias SymphonyElixir.TaskCreateTool
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.Workflow.Bundle

  @task_create_name "symphony_task_create"
  @task_get_name "symphony_task_get"
  @tasks_by_state_name "symphony_tasks_by_state"
  @task_get_description "Get one Symphony task by its exact human identifier."
  @tasks_by_state_description "List current, non-archived Symphony tasks in one workflow column."
  @history_limits %{runs: 3, events: 10}

  @impl true
  def init(_opts), do: {:ok, %{session_nonce: Ecto.UUID.generate()}}

  @impl true
  def handle_list_tools(_cursor, state) do
    bundle = current_bundle_for_discovery()

    {:ok,
     [
       TaskCreateTool.mcp_tool_spec(),
       task_get_tool_spec(),
       tasks_by_state_tool_spec(bundle)
     ], nil, state}
  end

  @impl true
  def handle_call_tool(name, arguments, %ToolContext{} = context, state) do
    case name do
      @task_create_name -> execute_create(arguments, context, state)
      @task_get_name -> execute_task_get(arguments, context, state)
      @tasks_by_state_name -> execute_tasks_by_state(arguments, context, state)
      _other -> {:error, -32_601, "Unknown tool", state}
    end
  end

  defp execute_create(arguments, context, state) do
    key = idempotency_key(state.session_nonce, context.request_id)

    with {:ok, _bundle} <- verify_project(arguments),
         {:ok, attrs} <- TaskCreateTool.validate_mcp_arguments(arguments),
         {:ok, result} <-
           Board.execute(%Commands.CreateTask{attrs: attrs},
             actor: %{type: :agent, identity: "mcp:#{state.session_nonce}"},
             expected_revision: 0,
             idempotency_key: key
           ) do
      log_success(TaskCreateTool.name(), state.session_nonce, key)
      {:ok, text_content(success_payload(result)), state}
    else
      {:error, reason} ->
        {code, message} = safe_error(reason)
        log_failure(TaskCreateTool.name(), state.session_nonce, key, code)
        {:ok, text_content(error_payload(code, message)), true, state}
    end
  rescue
    _error ->
      log_failure(
        TaskCreateTool.name(),
        state.session_nonce,
        idempotency_key(state.session_nonce, context.request_id),
        "internal_error"
      )

      {:ok, text_content(error_payload("internal_error", "Task creation failed unexpectedly.")), true, state}
  end

  defp execute_task_get(arguments, context, state) do
    key = request_key(state.session_nonce, context.request_id)

    with {:ok, bundle} <- verify_project(arguments),
         {:ok, %{"identifier" => identifier}} <- validate_task_get_arguments(arguments),
         {:ok, task} <- find_task_by_identifier(identifier),
         {:ok, metrics} <- Board.task_metrics(task.id) do
      payload = task_get_payload(task, bundle, metrics)
      log_success(@task_get_name, state.session_nonce, key)
      {:ok, text_content(payload), state}
    else
      {:error, reason} ->
        {code, message} = safe_read_error(reason, "Task lookup failed unexpectedly.")
        log_failure(@task_get_name, state.session_nonce, key, code)
        {:ok, text_content(error_payload(code, message)), true, state}
    end
  rescue
    _error ->
      log_failure(
        @task_get_name,
        state.session_nonce,
        request_key(state.session_nonce, context.request_id),
        "internal_error"
      )

      {:ok, text_content(error_payload("internal_error", "Task lookup failed unexpectedly.")), true, state}
  end

  defp execute_tasks_by_state(arguments, context, state) do
    key = request_key(state.session_nonce, context.request_id)

    with {:ok, bundle} <- verify_project(arguments),
         {:ok, %{"state" => state_id}} <- validate_tasks_by_state_arguments(arguments),
         {:ok, column} <- workflow_column(bundle, state_id) do
      tasks =
        Board.tasks()
        |> Enum.filter(&(&1.column_id == column.id))
        |> Enum.map(&task_list_view(&1, bundle))

      payload = %{
        "state" => %{"id" => column.id, "name" => column.name},
        "count" => length(tasks),
        "tasks" => tasks
      }

      log_success(@tasks_by_state_name, state.session_nonce, key)
      {:ok, text_content(payload), state}
    else
      {:error, reason} ->
        {code, message} = safe_read_error(reason, "Task listing failed unexpectedly.")
        log_failure(@tasks_by_state_name, state.session_nonce, key, code)
        {:ok, text_content(error_payload(code, message)), true, state}
    end
  rescue
    _error ->
      log_failure(
        @tasks_by_state_name,
        state.session_nonce,
        request_key(state.session_nonce, context.request_id),
        "internal_error"
      )

      {:ok, text_content(error_payload("internal_error", "Task listing failed unexpectedly.")), true, state}
  end

  defp task_get_tool_spec do
    %{
      "name" => @task_get_name,
      "description" => @task_get_description,
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["project_id", "identifier"],
        "properties" => %{
          "project_id" => project_property(),
          "identifier" => %{
            "type" => "string",
            "minLength" => 1,
            "description" => "Exact human task identifier, for example SYM-42."
          }
        }
      },
      "annotations" => read_tool_annotations("Get Symphony task")
    }
  end

  defp tasks_by_state_tool_spec(bundle) do
    %{
      "name" => @tasks_by_state_name,
      "description" => @tasks_by_state_description,
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["project_id", "state"],
        "properties" => %{
          "project_id" => project_property(),
          "state" => %{
            "type" => "string",
            "enum" => workflow_column_ids(bundle),
            "description" => "Exact, case-sensitive workflow column ID."
          }
        }
      },
      "annotations" => read_tool_annotations("List Symphony tasks by state")
    }
  end

  defp project_property do
    %{
      "type" => "string",
      "minLength" => 1,
      "description" => "Exact workflow project ID the caller independently intends to access. Do not guess or replace it after a mismatch."
    }
  end

  defp read_tool_annotations(title) do
    %{
      "title" => title,
      "readOnlyHint" => true,
      "destructiveHint" => false,
      "idempotentHint" => true,
      "openWorldHint" => false
    }
  end

  defp current_bundle_for_discovery do
    case Workflow.current() do
      {:ok, bundle} -> bundle
      {:error, _reason} -> nil
    end
  end

  defp workflow_column_ids(%Bundle{columns: columns}), do: Enum.map(columns, & &1.id)
  defp workflow_column_ids(_bundle), do: []

  defp verify_project(%{"project_id" => project_id}) when is_binary(project_id) and project_id != "" do
    case Workflow.current() do
      {:ok, bundle} when bundle.project.id == project_id -> {:ok, bundle}
      {:ok, _bundle} -> {:error, :project_id_mismatch}
      {:error, _reason} -> {:error, :workflow_unavailable}
    end
  end

  defp verify_project(_arguments), do: {:error, :project_id_mismatch}

  defp validate_task_get_arguments(arguments) when is_map(arguments) do
    with :ok <- string_keys(arguments),
         :ok <- known_fields(arguments, ["project_id", "identifier"]),
         :ok <- required_fields(arguments, ["project_id", "identifier"]),
         :ok <- nonempty_string_field(arguments, "identifier") do
      {:ok, arguments}
    end
  end

  defp validate_task_get_arguments(_arguments), do: {:error, :arguments_must_be_object}

  defp validate_tasks_by_state_arguments(arguments) when is_map(arguments) do
    with :ok <- string_keys(arguments),
         :ok <- known_fields(arguments, ["project_id", "state"]),
         :ok <- required_fields(arguments, ["project_id", "state"]),
         :ok <- nonempty_string_field(arguments, "state") do
      {:ok, arguments}
    end
  end

  defp validate_tasks_by_state_arguments(_arguments), do: {:error, :arguments_must_be_object}

  defp string_keys(arguments) do
    if Enum.all?(Map.keys(arguments), &is_binary/1),
      do: :ok,
      else: {:error, :arguments_must_use_string_keys}
  end

  defp known_fields(arguments, allowed) do
    unknown = arguments |> Map.keys() |> Enum.reject(&(&1 in allowed)) |> Enum.sort()
    if unknown == [], do: :ok, else: {:error, {:unknown_fields, unknown}}
  end

  defp required_fields(arguments, required) do
    missing = Enum.reject(required, &Map.has_key?(arguments, &1))
    if missing == [], do: :ok, else: {:error, {:missing_fields, missing}}
  end

  defp nonempty_string_field(arguments, field) do
    case arguments[field] do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, {:invalid_field, field}}, else: :ok

      _value ->
        {:error, {:invalid_field, field}}
    end
  end

  defp workflow_column(%Bundle{} = bundle, state_id) do
    case Bundle.column(bundle, state_id) do
      %Bundle.Column{} = column -> {:ok, column}
      nil -> {:error, {:unknown_state, state_id}}
    end
  end

  defp find_task_by_identifier(identifier) do
    case Board.task(identifier) do
      {:ok, %Task{identifier: ^identifier} = task} -> {:ok, task}
      {:ok, _task} -> {:error, :task_not_found}
      {:error, :not_found} -> {:error, :task_not_found}
    end
  end

  defp task_get_payload(task, bundle, metrics) do
    runs = Map.get(metrics, "runs", Board.runs(task.id))
    events = Board.events(task.id)

    %{
      "task" => task_view(task, bundle),
      "stats" => metrics["stats"],
      "runs" => history_envelope(runs, @history_limits.runs, &compact_run/1, &run_sort_key/1),
      "events" => history_envelope(events, @history_limits.events, &compact_event/1, &event_sort_key/1)
    }
  end

  defp task_view(%Task{} = task, %Bundle{} = bundle) do
    %{
      "id" => task.id,
      "identifier" => task.identifier,
      "title" => task.title,
      "type" => Atom.to_string(task.type),
      "priority" => Atom.to_string(task.priority),
      "status" => status_view(task, bundle),
      "brief" => task.brief,
      "acceptance_criteria" => task.acceptance_criteria,
      "stage_selections" => task.stage_selections,
      "dependencies" => dependency_views(task.dependencies),
      "branch" => task.branch,
      "pull_request" => safe_pull_request(task.github),
      "active_run_id" => task.active_run_id,
      "created_at" => task.created_at,
      "updated_at" => task.updated_at,
      "archived_at" => task.archived_at
    }
  end

  defp task_list_view(%Task{} = task, %Bundle{} = bundle) do
    %{
      "id" => task.id,
      "identifier" => task.identifier,
      "title" => task.title,
      "type" => Atom.to_string(task.type),
      "priority" => Atom.to_string(task.priority),
      "status" => %{
        "column_id" => task.column_id,
        "column_name" => column_name(bundle, task.column_id),
        "runtime_state" => task.runtime_state
      },
      "dependencies" => dependency_views(task.dependencies),
      "branch" => task.branch,
      "pull_request" => safe_pull_request(task.github)
    }
  end

  defp status_view(%Task{} = task, %Bundle{} = bundle) do
    %{
      "column_id" => task.column_id,
      "column_name" => column_name(bundle, task.column_id),
      "runtime_state" => task.runtime_state,
      "blocked_from_column_id" => task.blocked_from_column_id,
      "desired_column_id" => task.desired_column_id
    }
  end

  defp column_name(%Bundle{} = bundle, column_id) do
    case Bundle.column(bundle, column_id) do
      %Bundle.Column{name: name} -> name
      nil -> nil
    end
  end

  defp dependency_views(dependencies) when is_list(dependencies) do
    Enum.flat_map(dependencies, fn dependency_id ->
      case Board.task(dependency_id) do
        {:ok, dependency} -> [%{"id" => dependency.id, "identifier" => dependency.identifier}]
        {:error, :not_found} -> []
      end
    end)
  end

  defp safe_pull_request(%{"number" => number, "url" => url, "draft" => draft})
       when is_integer(number) and number > 0 and is_binary(url) and url != "" and is_boolean(draft),
       do: %{"number" => number, "url" => url, "draft" => draft}

  defp safe_pull_request(_github), do: nil

  defp history_envelope(items, limit, presenter, sort_key) do
    sorted = Enum.sort_by(items, sort_key, :desc)
    total = length(sorted)

    %{
      "items" => sorted |> Enum.take(limit) |> Enum.map(presenter),
      "total" => total,
      "truncated" => total > limit
    }
  end

  defp run_sort_key(run), do: Map.get(run, "updated_at") || Map.get(run, "finished_at") || ""
  defp event_sort_key(event), do: Map.get(event, "sequence", 0)

  defp compact_run(run) do
    compact =
      Map.take(run, [
        "id",
        "status",
        "stage_id",
        "model",
        "effort",
        "worker_host",
        "claimed_at",
        "started_at",
        "finished_at"
      ])
      |> Map.put("effective_stats", Map.get(run, "effective_stats"))

    compact
    |> maybe_put_present("failure", Map.get(run, "failure"))
    |> maybe_put_present("activity", safe_activity(Map.get(run, "activity")))
  end

  defp safe_activity(%{"summary" => summary, "at" => at}) when is_binary(summary),
    do: %{"summary" => summary, "at" => at}

  defp safe_activity(_activity), do: nil

  defp compact_event(event) do
    %{
      "sequence" => event["sequence"],
      "type" => event["type"],
      "timestamp" => event["timestamp"],
      "actor" => Map.take(event["actor"] || %{}, ["type", "identity"]),
      "run_id" => event["run_id"],
      "task_revision" => event["task_revision"]
    }
  end

  defp maybe_put_present(map, _key, nil), do: map
  defp maybe_put_present(map, key, value), do: Map.put(map, key, value)

  defp success_payload(result) do
    task = result["task"]

    %{
      "event_type" => result["event_type"],
      "task" =>
        Map.take(task, [
          "id",
          "identifier",
          "project_id",
          "column_id",
          "revision",
          "type",
          "priority"
        ])
    }
  end

  defp error_payload(code, message), do: %{"error" => %{"code" => code, "message" => message}}

  defp text_content(payload), do: [%{"type" => "text", "text" => Jason.encode!(payload, pretty: true)}]

  defp safe_error(:project_id_mismatch) do
    {"project_id_mismatch", "The supplied project_id does not match this Symphony project. Verify your intended project independently; do not guess another ID."}
  end

  defp safe_error(:workflow_unavailable), do: {"service_unavailable", "The Symphony workflow is unavailable."}
  defp safe_error(:task_not_found), do: {"task_not_found", "Task not found."}
  defp safe_error({:unknown_state, _state}), do: {"unknown_state", "The requested workflow state is unavailable."}
  defp safe_error(:arguments_must_be_object), do: invalid_arguments("Arguments must be an object.")
  defp safe_error(:arguments_must_use_string_keys), do: invalid_arguments("Argument keys must be strings.")

  defp safe_error({:unknown_fields, fields}) do
    invalid_arguments("Unknown argument fields: #{Enum.join(fields, ", ")}.")
  end

  defp safe_error({:missing_fields, fields}) do
    invalid_arguments("Missing required argument fields: #{Enum.join(fields, ", ")}.")
  end

  defp safe_error({:invalid_field, field}), do: invalid_arguments("Invalid value for #{field}.")

  defp safe_error({:dependency_not_found, _dependency}) do
    {"dependency_not_found", "At least one dependency could not be resolved in this project."}
  end

  defp safe_error({:stage_selection_required, stage_id}) do
    {"stage_selection_required", "An explicit model and effort selection is required for stage #{stage_id}."}
  end

  defp safe_error({:stage_selection_not_permitted, stage_id, _model, _effort}) do
    {"stage_selection_not_permitted", "The supplied model and effort are not permitted for stage #{stage_id}."}
  end

  defp safe_error({:invalid_stage_selection, stage_id}) do
    {"invalid_stage_selection", "The stage selection for #{stage_id} is invalid."}
  end

  defp safe_error(reason)
       when reason in [
              :project_lease_not_owned,
              :board_history_diverged,
              :board_history_behind,
              :board_sync_pending,
              :project_identity_changed
            ] do
    {"board_unavailable", "The Symphony board is not currently writable."}
  end

  defp safe_error(_reason), do: {"task_create_failed", "The task could not be created from the supplied fields."}

  defp safe_read_error(reason, _fallback_message)
       when reason in [:project_id_mismatch, :workflow_unavailable, :task_not_found],
       do: safe_error(reason)

  defp safe_read_error({:unknown_state, _state} = reason, _fallback_message), do: safe_error(reason)
  defp safe_read_error({:unknown_fields, _fields} = reason, _fallback_message), do: safe_error(reason)
  defp safe_read_error({:missing_fields, _fields} = reason, _fallback_message), do: safe_error(reason)
  defp safe_read_error({:invalid_field, _field} = reason, _fallback_message), do: safe_error(reason)
  defp safe_read_error(:arguments_must_be_object = reason, _fallback_message), do: safe_error(reason)

  defp safe_read_error(:arguments_must_use_string_keys = reason, _fallback_message), do: safe_error(reason)

  defp safe_read_error(_reason, fallback_message), do: {"internal_error", fallback_message}

  defp invalid_arguments(message), do: {"invalid_arguments", message}

  defp idempotency_key(session_nonce, request_id) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary({session_nonce, request_id}))
    "mcp:task-create:" <> Base.encode16(digest, case: :lower)
  end

  defp request_key(session_nonce, request_id) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary({session_nonce, request_id}))
    "mcp:request:" <> Base.encode16(digest, case: :lower)
  end

  defp log_success(tool, session_nonce, key) do
    Logger.info("mcp tool completed tool=#{tool} session_id=mcp:#{session_nonce} mcp_request_key=#{key}")
  end

  defp log_failure(tool, session_nonce, key, code) do
    Logger.warning("mcp tool failed tool=#{tool} session_id=mcp:#{session_nonce} mcp_request_key=#{key} reason=#{code}")
  end
end
