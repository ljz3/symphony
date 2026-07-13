defmodule SymphonyElixir.Codex.Activity do
  @moduledoc """
  Extracts bounded, operator-safe activity and rate-limit summaries from Codex messages.

  Raw prompts, reasoning, command output, workpads, and arbitrary protocol payloads are
  deliberately excluded from the returned values.
  """

  alias SymphonyElixir.Codex.RunStats

  @max_summary_length 140
  @codex_event_summaries %{
    "exec_command_begin" => "command started",
    "exec_command_end" => "command completed",
    "exec_command_output_delta" => "command output streaming",
    "mcp_tool_call_begin" => "MCP tool call started",
    "mcp_tool_call_end" => "MCP tool call completed",
    "agent_message_delta" => "agent response streaming",
    "agent_reasoning_delta" => "reasoning streaming",
    "turn_diff" => "working-tree diff updated",
    "token_count" => "token usage updated"
  }
  @item_labels %{
    "agentMessage" => "agent response",
    "agent_message" => "agent response",
    "commandExecution" => "command",
    "command_execution" => "command",
    "dynamicToolCall" => "tool call",
    "dynamic_tool_call" => "tool call",
    "fileChange" => "file change",
    "file_change" => "file change",
    "mcpToolCall" => "MCP tool call",
    "mcp_tool_call" => "MCP tool call",
    "plan" => "plan",
    "reasoning" => "reasoning",
    "toolCall" => "tool call",
    "tool_call" => "tool call",
    "webSearch" => "web search",
    "web_search" => "web search"
  }
  @bucket_keys %{
    "remaining" => "remaining",
    "limit" => "limit",
    "reset_in_seconds" => "reset_in_seconds",
    "resetInSeconds" => "reset_in_seconds",
    "reset_at" => "reset_at",
    "resetAt" => "reset_at",
    "resets_at" => "reset_at",
    "resetsAt" => "reset_at",
    "used_percent" => "used_percent",
    "usedPercent" => "used_percent",
    "window_duration_mins" => "window_duration_mins",
    "windowDurationMins" => "window_duration_mins",
    "has_credits" => "has_credits",
    "hasCredits" => "has_credits",
    "unlimited" => "unlimited",
    "balance" => "balance"
  }

  @spec summary(map()) :: String.t() | nil
  def summary(message) when is_map(message) do
    event = value(message, :event)
    payload = value(message, :payload) || message
    method = value(payload, :method)

    (event_summary(event, message) || method_summary(method, payload) || fallback_summary(event))
    |> sanitize_summary()
  end

  @spec rate_limits(map()) :: map() | nil
  def rate_limits(message) when is_map(message) do
    message
    |> find_rate_limits(0)
    |> normalize_rate_limits()
  end

  defp event_summary(event, message) when event in [:session_started, "session_started"] do
    case value(message, :model) do
      model when is_binary(model) and model != "" -> "session started · #{model}"
      _ -> "session started"
    end
  end

  defp event_summary(event, _message) when event in [:startup_failed, "startup_failed"], do: "session startup failed"

  defp event_summary(event, _message) when event in [:turn_ended_with_error, "turn_ended_with_error"],
    do: "turn ended with an error"

  defp event_summary(event, _message) when event in [:turn_failed, "turn_failed"], do: "turn failed"
  defp event_summary(event, _message) when event in [:turn_cancelled, "turn_cancelled"], do: "turn cancelled"
  defp event_summary(event, _message) when event in [:turn_interrupted, "turn_interrupted"], do: "turn interrupted"

  defp event_summary(event, _message) when event in [:tool_call_completed, "tool_call_completed"],
    do: "tool call completed"

  defp event_summary(event, _message) when event in [:tool_call_failed, "tool_call_failed"], do: "tool call failed"

  defp event_summary(event, _message) when event in [:approval_auto_approved, "approval_auto_approved"],
    do: "approval request auto-approved"

  defp event_summary(event, _message) when event in [:tool_input_auto_answered, "tool_input_auto_answered"],
    do: "tool input auto-answered"

  defp event_summary(_event, _message), do: nil

  defp method_summary("thread/tokenUsage/updated", payload) do
    case RunStats.absolute_token_usage(%{payload: payload}) do
      %{"total_tokens" => total} -> "token usage updated · #{format_count(total)} total"
      _ -> "token usage updated"
    end
  end

  defp method_summary("turn/started", _payload), do: "turn started"
  defp method_summary("turn/completed", _payload), do: "turn completed"
  defp method_summary("turn/failed", _payload), do: "turn failed"
  defp method_summary("turn/cancelled", _payload), do: "turn cancelled"
  defp method_summary("turn/plan/updated", _payload), do: "plan updated"
  defp method_summary("turn/diff/updated", _payload), do: "working-tree diff updated"
  defp method_summary("account/rateLimits/updated", _payload), do: "rate limits updated"
  defp method_summary("item/agentMessage/delta", _payload), do: "agent response streaming"
  defp method_summary("item/plan/delta", _payload), do: "plan streaming"
  defp method_summary("item/reasoning/summaryTextDelta", _payload), do: "reasoning summary streaming"
  defp method_summary("item/reasoning/summaryPartAdded", _payload), do: "reasoning summary updated"
  defp method_summary("item/reasoning/textDelta", _payload), do: "reasoning streaming"
  defp method_summary("item/commandExecution/outputDelta", _payload), do: "command output streaming"
  defp method_summary("item/fileChange/outputDelta", _payload), do: "file changes streaming"
  defp method_summary("item/commandExecution/requestApproval", _payload), do: "command approval requested"
  defp method_summary("item/fileChange/requestApproval", _payload), do: "file-change approval requested"
  defp method_summary("item/tool/requestUserInput", _payload), do: "tool requested user input"
  defp method_summary("tool/requestUserInput", _payload), do: "tool requested user input"
  defp method_summary("item/started", payload), do: item_summary("started", payload)
  defp method_summary("item/completed", payload), do: item_summary("completed", payload)

  defp method_summary(<<"codex/event/", suffix::binary>>, _payload) do
    Map.get(@codex_event_summaries, suffix, "Codex activity")
  end

  defp method_summary(method, _payload) when is_binary(method), do: "Codex activity"
  defp method_summary(_method, _payload), do: nil

  defp item_summary(state, payload) do
    type =
      path(payload, [:params, :item, :type]) ||
        path(payload, [:params, :itemType]) ||
        path(payload, [:params, :type])

    label = if is_binary(type), do: Map.get(@item_labels, type), else: nil
    "#{label || "item"} #{state}"
  end

  defp fallback_summary(event) when is_atom(event) or is_binary(event), do: "Codex activity"
  defp fallback_summary(_event), do: nil

  defp sanitize_summary(nil), do: nil

  defp sanitize_summary(summary) when is_binary(summary) do
    summary
    |> String.replace(~r/\x1B\[[0-9;]*[A-Za-z]/, "")
    |> String.replace(~r/\x1B./, "")
    |> String.replace(~r/[\x00-\x1F\x7F]/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, @max_summary_length)
    |> blank_nil()
  end

  defp format_count(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp find_rate_limits(_value, depth) when depth > 8, do: nil

  defp find_rate_limits(map, depth) when is_map(map) do
    direct =
      value(map, :rateLimits) ||
        value(map, :rate_limits)

    cond do
      is_map(direct) ->
        direct

      rate_limit_map?(map) ->
        map

      true ->
        Enum.find_value(Map.values(map), &find_rate_limits(&1, depth + 1))
    end
  end

  defp find_rate_limits(list, depth) when is_list(list), do: Enum.find_value(list, &find_rate_limits(&1, depth + 1))
  defp find_rate_limits(_value, _depth), do: nil

  defp rate_limit_map?(map) do
    Enum.any?(["primary", :primary, "secondary", :secondary, "credits", :credits], &Map.has_key?(map, &1))
  end

  defp normalize_rate_limits(map) when is_map(map) do
    normalized =
      %{}
      |> put_scalar("limit_id", value(map, :limit_id) || value(map, :limitId))
      |> put_scalar("limit_name", value(map, :limit_name) || value(map, :limitName))
      |> put_scalar("plan_type", value(map, :plan_type) || value(map, :planType))
      |> put_bucket("primary", value(map, :primary))
      |> put_bucket("secondary", value(map, :secondary))
      |> put_bucket("credits", value(map, :credits))

    if map_size(normalized) == 0, do: nil, else: normalized
  end

  defp normalize_rate_limits(_map), do: nil

  defp put_scalar(result, key, value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: Map.put(result, key, value)

  defp put_scalar(result, _key, _value), do: result

  defp put_bucket(result, key, value) when is_map(value) do
    bucket =
      Enum.reduce(value, %{}, fn {field, nested}, acc ->
        canonical = Map.get(@bucket_keys, to_string(field))

        if canonical && scalar?(nested), do: Map.put(acc, canonical, nested), else: acc
      end)

    if map_size(bucket) == 0, do: result, else: Map.put(result, key, bucket)
  end

  defp put_bucket(result, _key, _value), do: result

  defp scalar?(value), do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)

  defp path(payload, keys) do
    Enum.reduce_while(keys, payload, fn key, current ->
      case value(current, key) do
        nil -> {:halt, nil}
        nested -> {:cont, nested}
      end
    end)
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp value(_map, _key), do: nil
  defp blank_nil(""), do: nil
  defp blank_nil(value), do: value
end
