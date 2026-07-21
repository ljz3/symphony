# Scripted fake `kimi acp` agent for tests.
#
# Speaks ACP JSON-RPC over stdio, driven by environment variables:
#
#   FAKE_ACP_CAPTURE            append captured events (JSON lines) to this file
#   FAKE_ACP_PROTOCOL_VERSION   integer, default 1
#   FAKE_ACP_MCP_HTTP           "false" to advertise mcpCapabilities.http = false
#   FAKE_ACP_AUTH_METHODS       JSON array, default []
#   FAKE_ACP_AUTH_REQUIRED      "1" to fail authenticate with -32000
#   FAKE_ACP_MODELS             JSON list, default ["kimi-code/k3"]
#   FAKE_ACP_THINKING_BY_MODEL  JSON map model => [effort]; models absent from
#                               the map expose no thinking option once selected
#   FAKE_ACP_MODES              JSON list, default ["manual", "auto", "yolo"]
#   FAKE_ACP_CONFIG_OPTIONS_RAW JSON list replacing the computed configOptions
#   FAKE_ACP_STOP_REASON        default "end_turn"
#   FAKE_ACP_WAIT_CANCEL        "1" to hold the prompt until session/cancel
#   FAKE_ACP_PERMISSION         "1" to issue an allow-kind permission request
#   FAKE_ACP_ELICIT             "1" to issue a reject-kind-only permission request
#   FAKE_ACP_USAGE              "1" to emit a usage_update notification
#   FAKE_ACP_MALFORMED          "1" to emit one non-JSON line at startup
#   FAKE_ACP_STDERR             "1" to write one line to stderr at startup
#   FAKE_ACP_HANG               "1" to never answer any request
#   FAKE_ACP_CRASH_AFTER        integer ms after which the agent exits with 3
#   FAKE_ACP_OVERSIZE           "1" to emit one 9MB line after initialize

defmodule FakeKimiACP do
  @moduledoc false

  def run do
    # Self-destruct watchdog: a fake must never outlive its test run as an OS
    # orphan (the HANG scenario never reads stdin, so EOF cannot save it).
    spawn(fn ->
      Process.sleep(60_000)
      System.halt(0)
    end)

    if env("FAKE_ACP_HANG") == "1" do
      Process.sleep(:infinity)
    end

    if crash_after = env("FAKE_ACP_CRASH_AFTER") do
      spawn(fn ->
        Process.sleep(String.to_integer(crash_after))
        System.halt(3)
      end)
    end

    if env("FAKE_ACP_MALFORMED") == "1" do
      IO.binwrite(:stdio, "this line is not json\n")
    end

    if env("FAKE_ACP_STDERR") == "1" do
      IO.binwrite(:stderr, "fake stderr line\n")
    end

    %{
      models: json_env("FAKE_ACP_MODELS", ["kimi-code/k3"]),
      thinking_by_model: json_env("FAKE_ACP_THINKING_BY_MODEL", %{"kimi-code/k3" => ["max"]}),
      modes: json_env("FAKE_ACP_MODES", ["manual", "auto", "yolo"]),
      config_options_override: json_env("FAKE_ACP_CONFIG_OPTIONS_RAW", nil),
      current_model: nil,
      current_thinking: nil,
      current_mode: nil,
      pending_prompt_id: nil
    }
    |> loop()
  end

  defp loop(state) do
    case IO.binread(:stdio, :line) do
      :eof ->
        :ok

      {:error, _reason} ->
        :ok

      line ->
        state
        |> handle(line)
        |> loop()
    end
  end

  defp handle(state, line) do
    case Jason.decode(line) do
      {:ok, %{"method" => method, "id" => id} = message} ->
        handle_request(state, id, method, Map.get(message, "params") || %{})

      {:ok, %{"id" => id, "result" => result}} ->
        capture(state, %{"type" => "agent_response", "id" => id, "result" => result})
        state

      {:ok, %{"id" => id, "error" => error}} ->
        capture(state, %{"type" => "agent_response", "id" => id, "error" => error})
        state

      {:ok, %{"method" => method} = message} ->
        handle_notification(state, method, Map.get(message, "params") || %{})

      _other ->
        state
    end
  end

  defp handle_request(state, id, "initialize", params) do
    capture(state, %{"type" => "initialize", "params" => params})

    result = %{
      "protocolVersion" => String.to_integer(env("FAKE_ACP_PROTOCOL_VERSION") || "1"),
      "agentCapabilities" => %{
        "mcpCapabilities" => %{"http" => env("FAKE_ACP_MCP_HTTP") != "false", "sse" => false},
        "promptCapabilities" => %{"image" => true}
      },
      "agentInfo" => %{"name" => "Fake Kimi ACP", "version" => "0.0.0"},
      "authMethods" => json_env("FAKE_ACP_AUTH_METHODS", [])
    }

    respond(id, result)

    if env("FAKE_ACP_OVERSIZE") == "1" do
      IO.binwrite(:stdio, Jason.encode!(%{"method" => "session/update", "params" => %{"pad" => String.duplicate("x", 9 * 1_048_576)}}) <> "\n")
    end

    state
  end

  defp handle_request(state, id, "authenticate", params) do
    capture(state, %{"type" => "authenticate", "params" => params})

    if env("FAKE_ACP_AUTH_REQUIRED") == "1" do
      respond_error(id, -32_000, "authRequired")
    else
      respond(id, %{})
    end

    state
  end

  defp handle_request(state, id, "session/new", params) do
    capture(state, %{"type" => "session/new", "params" => params})
    respond(id, %{"sessionId" => "fake-acp-session", "configOptions" => config_options(state)})
    state
  end

  defp handle_request(state, id, "session/set_config_option", params) do
    capture(state, %{"type" => "session/set_config_option", "params" => params})

    state =
      case params["configId"] do
        "model" -> %{state | current_model: params["value"]}
        "thinking" -> %{state | current_thinking: params["value"]}
        "mode" -> %{state | current_mode: params["value"]}
        _ -> state
      end

    respond(id, %{"configOptions" => config_options(state)})
    state
  end

  defp handle_request(state, id, "session/prompt", params) do
    capture(state, %{"type" => "session/prompt", "params" => params})

    cond do
      env("FAKE_ACP_WAIT_CANCEL") == "1" ->
        %{state | pending_prompt_id: id}

      env("FAKE_ACP_PERMISSION") == "1" or env("FAKE_ACP_ELICIT") == "1" ->
        permission_request(state, id)

      true ->
        finish_prompt(state, id)
        state
    end
  end

  defp handle_request(state, id, method, params) do
    capture(state, %{"type" => "unknown_request", "method" => method, "params" => params})
    respond_error(id, -32_601, "Method not found")
    state
  end

  defp handle_notification(state, "session/cancel", params) do
    capture(state, %{"type" => "session/cancel", "params" => params})

    case state.pending_prompt_id do
      nil ->
        :ok

      prompt_id ->
        notify(%{"sessionUpdate" => "tool_call_update", "toolCallId" => "call-1", "status" => "cancelled"})
        respond(prompt_id, %{"stopReason" => "cancelled"})
    end

    %{state | pending_prompt_id: nil}
  end

  defp handle_notification(state, _method, _params), do: state

  defp permission_request(state, prompt_id) do
    options =
      if env("FAKE_ACP_ELICIT") == "1" do
        [
          %{"optionId" => "reject-now", "name" => "Reject", "kind" => "reject_once"},
          %{"optionId" => "reject-ever", "name" => "Never", "kind" => "reject_always"}
        ]
      else
        [
          %{"optionId" => "allow-once", "name" => "Allow once", "kind" => "allow_once"},
          %{"optionId" => "allow-always", "name" => "Always allow", "kind" => "allow_always"},
          %{"optionId" => "reject-now", "name" => "Reject", "kind" => "reject_once"}
        ]
      end

    request(
      90_001,
      "session/request_permission",
      %{
        "sessionId" => "fake-acp-session",
        "toolCall" => %{"toolCallId" => "call-1", "title" => "Run tests", "kind" => "execute", "status" => "pending"},
        "options" => options
      }
    )

    spawn(fn ->
      Process.sleep(200)
      finish_prompt(state, prompt_id)
    end)

    state
  end

  defp finish_prompt(_state, id) do
    notify(%{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => "fake chunk"}
    })

    notify(%{"sessionUpdate" => "tool_call", "toolCallId" => "call-1", "title" => "Run tests", "kind" => "execute", "status" => "completed"})

    if env("FAKE_ACP_USAGE") == "1" do
      notify(%{"sessionUpdate" => "usage_update", "used" => 100, "size" => 1_000})
    end

    respond(id, %{"stopReason" => env("FAKE_ACP_STOP_REASON") || "end_turn"})
  end

  defp config_options(state) do
    case state.config_options_override do
      nil -> computed_config_options(state)
      override -> override
    end
  end

  defp computed_config_options(state) do
    model = state.current_model || hd(state.models)
    mode = state.current_mode || hd(state.modes)

    base = [
      %{
        "id" => "model",
        "name" => "Model",
        "category" => "model",
        "type" => "select",
        "currentValue" => model,
        "options" => Enum.map(state.models, &%{"value" => &1, "name" => &1})
      },
      %{
        "id" => "mode",
        "name" => "Mode",
        "category" => "mode",
        "type" => "select",
        "currentValue" => mode,
        "options" => Enum.map(state.modes, &%{"value" => &1, "name" => &1})
      }
    ]

    case Map.get(state.thinking_by_model, model) do
      nil ->
        base

      efforts ->
        thinking = %{
          "id" => "thinking",
          "name" => "Thinking",
          "category" => "thought_level",
          "type" => "select",
          "currentValue" => state.current_thinking || hd(efforts),
          "options" => Enum.map(efforts, &%{"value" => &1, "name" => &1})
        }

        [thinking | base]
    end
  end

  defp respond(id, result) do
    write(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp respond_error(id, code, message) do
    write(%{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}})
  end

  defp request(id, method, params) do
    write(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
  end

  defp notify(update) do
    write(%{"jsonrpc" => "2.0", "method" => "session/update", "params" => %{"sessionId" => "fake-acp-session", "update" => update}})
  end

  defp write(payload) do
    IO.binwrite(:stdio, Jason.encode!(payload) <> "\n")
  end

  defp capture(state, event) do
    case env("FAKE_ACP_CAPTURE") do
      nil -> :ok
      path -> File.write!(path, Jason.encode!(event) <> "\n", [:append])
    end

    state
  end

  defp env(name), do: System.get_env(name)

  defp json_env(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> Jason.decode!(value)
    end
  end
end

FakeKimiACP.run()
