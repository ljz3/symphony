defmodule SymphonyElixir.MCP.Handler do
  @moduledoc """
  MCP handler exposing the guarded Symphony task-creation tool.
  """

  @behaviour MCP.Server.Handler

  require Logger

  alias MCP.Server.ToolContext
  alias SymphonyElixir.Board
  alias SymphonyElixir.Board.Commands
  alias SymphonyElixir.{TaskCreateTool, Workflow}

  @impl true
  def init(_opts), do: {:ok, %{session_nonce: Ecto.UUID.generate()}}

  @impl true
  def handle_list_tools(_cursor, state), do: {:ok, [TaskCreateTool.mcp_tool_spec()], nil, state}

  @impl true
  def handle_call_tool(name, arguments, %ToolContext{} = context, state) do
    if name == TaskCreateTool.name() do
      execute_create(arguments, context, state)
    else
      {:error, -32_601, "Unknown tool", state}
    end
  end

  defp execute_create(arguments, context, state) do
    key = idempotency_key(state.session_nonce, context.request_id)

    with :ok <- verify_project(arguments),
         {:ok, attrs} <- TaskCreateTool.validate_mcp_arguments(arguments),
         {:ok, result} <-
           Board.execute(%Commands.CreateTask{attrs: attrs},
             actor: %{type: :agent, identity: "mcp:#{state.session_nonce}"},
             expected_revision: 0,
             idempotency_key: key
           ) do
      task = result["task"]
      log_success(task, state.session_nonce, key)
      {:ok, text_content(success_payload(result)), state}
    else
      {:error, reason} ->
        {code, message} = safe_error(reason)
        log_failure(code, state.session_nonce, key)
        {:ok, text_content(error_payload(code, message)), true, state}
    end
  rescue
    _error ->
      key = idempotency_key(state.session_nonce, context.request_id)
      log_failure("internal_error", state.session_nonce, key)
      {:ok, text_content(error_payload("internal_error", "Task creation failed unexpectedly.")), true, state}
  end

  defp verify_project(%{"project_id" => project_id}) when is_binary(project_id) and project_id != "" do
    case Workflow.current() do
      {:ok, bundle} when bundle.project.id == project_id -> :ok
      {:ok, _bundle} -> {:error, :project_id_mismatch}
      {:error, _reason} -> {:error, :workflow_unavailable}
    end
  end

  defp verify_project(_arguments), do: {:error, :project_id_mismatch}

  defp idempotency_key(session_nonce, request_id) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary({session_nonce, request_id}))
    "mcp:task-create:" <> Base.encode16(digest, case: :lower)
  end

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

  defp error_payload(code, message) do
    %{"error" => %{"code" => code, "message" => message}}
  end

  defp text_content(payload) do
    [%{"type" => "text", "text" => Jason.encode!(payload, pretty: true)}]
  end

  defp safe_error(:project_id_mismatch) do
    {"project_id_mismatch", "The supplied project_id does not match this Symphony project. Verify your intended project independently; do not guess another ID."}
  end

  defp safe_error(:workflow_unavailable), do: {"service_unavailable", "The Symphony workflow is unavailable."}
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

  defp invalid_arguments(message), do: {"invalid_arguments", message}

  defp log_success(task, session_nonce, key) do
    Logger.info(
      "mcp task create completed project_id=#{task["project_id"]} task_id=#{task["id"]} " <>
        "task_identifier=#{task["identifier"]} session_id=mcp:#{session_nonce} mcp_request_key=#{key}"
    )
  end

  defp log_failure(code, session_nonce, key) do
    Logger.warning("mcp task create failed session_id=mcp:#{session_nonce} mcp_request_key=#{key} reason=#{code}")
  end
end
