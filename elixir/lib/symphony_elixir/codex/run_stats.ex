defmodule SymphonyElixir.Codex.RunStats do
  @moduledoc """
  Normalizes cumulative Codex token snapshots and tracks per-run turn usage.

  Only thread-level absolute totals and the legacy token-count absolute total
  are accepted. Incremental and generic usage payloads are deliberately
  ignored so callers cannot double-count a Codex thread.
  """

  @type token_usage :: %{
          required(String.t()) => non_neg_integer()
        }

  @type t :: %{
          required(String.t()) => String.t() | [String.t()] | token_usage() | nil
        }

  @spec new() :: t()
  def new do
    %{
      "thread_id" => nil,
      "turn_ids" => [],
      "token_usage" => nil
    }
  end

  @spec observe(t(), map()) :: {:ok, t()} | :ignore
  def observe(current, message) when is_map(current) and is_map(message) do
    updated =
      current
      |> observe_session(message)
      |> observe_usage(message)

    if updated == current, do: :ignore, else: {:ok, updated}
  end

  @spec relevant?(map()) :: boolean()
  def relevant?(message) when is_map(message) do
    value(message, :event) in [:session_started, "session_started"] or
      not is_nil(absolute_token_usage(message))
  end

  @spec summary(t() | nil) :: map()
  def summary(telemetry) when is_map(telemetry) do
    %{
      "turn_count" => telemetry |> Map.get("turn_ids", []) |> Enum.uniq() |> length(),
      "token_usage" => Map.get(telemetry, "token_usage")
    }
  end

  def summary(_telemetry), do: %{"turn_count" => 0, "token_usage" => nil}

  @spec absolute_token_usage(map()) :: token_usage() | nil
  def absolute_token_usage(message) when is_map(message) do
    payload = value(message, :payload) || message

    dedicated_thread_usage(payload) || legacy_absolute_usage(payload)
  end

  defp observe_session(current, message) do
    if value(message, :event) in [:session_started, "session_started"] do
      thread_id = value(message, :thread_id)
      turn_id = value(message, :turn_id)

      current
      |> maybe_put_thread_id(thread_id)
      |> maybe_add_turn_id(turn_id)
    else
      current
    end
  end

  defp observe_usage(current, message) do
    case absolute_token_usage(message) do
      nil ->
        current

      usage ->
        previous = Map.get(current, "token_usage")

        if accept_snapshot?(previous, usage) do
          Map.put(current, "token_usage", usage)
        else
          current
        end
    end
  end

  defp dedicated_thread_usage(payload) do
    if value(payload, :method) == "thread/tokenUsage/updated" do
      payload
      |> path([:params, :tokenUsage, :total])
      |> normalize_usage()
    end
  end

  defp legacy_absolute_usage(payload) do
    if value(payload, :method) == "turn/completed" do
      nil
    else
      [
        [:params, :msg, :payload, :info, :total_token_usage],
        [:params, :msg, :info, :total_token_usage],
        [:params, :info, :total_token_usage],
        [:info, :total_token_usage]
      ]
      |> Enum.find_value(fn keys -> payload |> path(keys) |> normalize_usage() end)
    end
  end

  defp normalize_usage(usage) when is_map(usage) do
    input = token_value(usage, [:input_tokens, :prompt_tokens, :inputTokens, :promptTokens])
    cached = token_value(usage, [:cached_input_tokens, :cachedInputTokens])
    output = token_value(usage, [:output_tokens, :completion_tokens, :outputTokens, :completionTokens])
    total = token_value(usage, [:total_tokens, :totalTokens, :total])

    if Enum.any?([input, cached, output, total], &is_integer/1) do
      normalized_input = input || 0
      normalized_output = output || 0

      %{
        "input_tokens" => normalized_input,
        "cached_input_tokens" => cached || 0,
        "output_tokens" => normalized_output,
        "total_tokens" => total || normalized_input + normalized_output
      }
    end
  end

  defp normalize_usage(_usage), do: nil

  defp accept_snapshot?(nil, _usage), do: true

  defp accept_snapshot?(previous, usage) when is_map(previous) do
    usage["total_tokens"] >= Map.get(previous, "total_tokens", 0)
  end

  defp maybe_put_thread_id(current, thread_id) when is_binary(thread_id) and thread_id != "",
    do: Map.put(current, "thread_id", thread_id)

  defp maybe_put_thread_id(current, _thread_id), do: current

  defp maybe_add_turn_id(current, turn_id) when is_binary(turn_id) and turn_id != "" do
    Map.update(current, "turn_ids", [turn_id], fn turn_ids ->
      if turn_id in turn_ids, do: turn_ids, else: turn_ids ++ [turn_id]
    end)
  end

  defp maybe_add_turn_id(current, _turn_id), do: current

  defp token_value(payload, keys) do
    Enum.find_value(keys, fn key -> payload |> value(key) |> non_negative_integer() end)
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: nil

  defp path(payload, keys) do
    Enum.reduce_while(keys, payload, &path_segment/2)
  end

  defp path_segment(_key, current) when not is_map(current), do: {:halt, nil}

  defp path_segment(key, current) do
    case value(current, key) do
      nil -> {:halt, nil}
      nested -> {:cont, nested}
    end
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
