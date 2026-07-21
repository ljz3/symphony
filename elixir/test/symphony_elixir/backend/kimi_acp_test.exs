defmodule SymphonyElixir.Backend.KimiACPTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Backend.KimiACP
  alias SymphonyElixir.Board.Projection
  alias SymphonyElixir.{BoardFactory, HttpServer, Paths, Workflow}
  alias SymphonyElixir.MCP.RunTransport
  alias SymphonyElixirWeb.Endpoint

  @model "kimi-code/k3"
  @effort "max"

  setup do
    previous_endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])
    start_supervised!({HttpServer, port: 0})
    on_exit(fn -> Application.put_env(:symphony_elixir, Endpoint, previous_endpoint_config) end)
    :ok
  end

  test "start_session completes the handshake and applies model, thinking, and mode in order" do
    ctx = kimi_workflow()
    workspace = task_workspace()
    run_id = BoardFactory.unique("run")

    assert {:ok, session} =
             KimiACP.start_session(workspace,
               backend: "kimi",
               run_id: run_id,
               model: @model,
               effort: @effort
             )

    on_exit(fn -> KimiACP.stop_session(session) end)

    assert session.backend == "kimi"
    assert session.session_id == "fake-acp-session"
    assert KimiACP.session_id(session) == "fake-acp-session"
    assert session.model == @model
    assert session.effort == @effort
    assert session.run_id == run_id
    assert session.invocation == 1
    assert session.turn == 0
    assert is_pid(session.client)

    events = capture_events(ctx.capture)

    assert Enum.map(events, & &1["type"]) == [
             "initialize",
             "session/new",
             "session/set_config_option",
             "session/set_config_option",
             "session/set_config_option"
           ]

    [initialize] = Enum.filter(events, &(&1["type"] == "initialize"))
    assert initialize["params"]["protocolVersion"] == 1

    [session_new] = Enum.filter(events, &(&1["type"] == "session/new"))
    assert %{"mcpServers" => [mcp_server]} = session_new["params"]
    assert mcp_server["name"] == "symphony"
    assert mcp_server["type"] == "http"
    assert mcp_server["url"] =~ "/mcp/runs/#{run_id}/1"
    assert [%{"name" => "Authorization", "value" => "Bearer " <> token}] = mcp_server["headers"]
    assert byte_size(token) > 0

    set_options = for event <- events, event["type"] == "session/set_config_option", do: event["params"]
    assert Enum.map(set_options, & &1["configId"]) == ["model", "thinking", "mode"]
    assert Enum.map(set_options, & &1["value"]) == [@model, @effort, "auto"]
    assert Enum.all?(set_options, &(&1["sessionId"] == "fake-acp-session"))
  end

  test "start_session with no effort skips the thinking config option" do
    ctx = kimi_workflow()
    workspace = task_workspace()
    run_id = BoardFactory.unique("run")

    assert {:ok, session} =
             KimiACP.start_session(workspace,
               backend: "kimi",
               run_id: run_id,
               model: @model
             )

    on_exit(fn -> KimiACP.stop_session(session) end)

    assert session.effort == nil

    config_ids =
      ctx.capture
      |> capture_events()
      |> Enum.filter(&(&1["type"] == "session/set_config_option"))
      |> Enum.map(& &1["params"]["configId"])

    assert config_ids == ["model", "mode"]
  end

  test "start_session rejects a model the agent does not advertise" do
    ctx = kimi_workflow(%{"FAKE_ACP_MODELS" => ~s(["other-model"])})
    workspace = task_workspace()
    run_id = BoardFactory.unique("run")

    assert {:error, {:model_unavailable, @model}} =
             KimiACP.start_session(workspace,
               backend: "kimi",
               run_id: run_id,
               model: @model,
               effort: @effort
             )

    refute Enum.any?(capture_events(ctx.capture), &(&1["type"] == "session/set_config_option"))
    assert RunTransport.fetch_config(run_id, 1) == :error
  end

  test "start_session rejects an effort when the selected model has no thinking option" do
    kimi_workflow(%{"FAKE_ACP_THINKING_BY_MODEL" => ~s({})})
    workspace = task_workspace()
    run_id = BoardFactory.unique("run")

    assert {:error, {:effort_unsupported, @model, @effort}} =
             KimiACP.start_session(workspace,
               backend: "kimi",
               run_id: run_id,
               model: @model,
               effort: @effort
             )

    assert RunTransport.fetch_config(run_id, 1) == :error
  end

  test "start_session rejects an effort value the thinking option does not offer" do
    kimi_workflow(%{"FAKE_ACP_THINKING_BY_MODEL" => ~s({"kimi-code/k3": ["low"]})})
    workspace = task_workspace()
    run_id = BoardFactory.unique("run")

    assert {:error, {:effort_unsupported, @model, @effort}} =
             KimiACP.start_session(workspace,
               backend: "kimi",
               run_id: run_id,
               model: @model,
               effort: @effort
             )

    assert RunTransport.fetch_config(run_id, 1) == :error
  end

  test "start_session rejects config options without a model option" do
    raw_options =
      Jason.encode!([
        %{
          "id" => "mode",
          "name" => "Mode",
          "category" => "mode",
          "type" => "select",
          "currentValue" => "auto",
          "options" => [%{"value" => "auto", "name" => "auto"}]
        }
      ])

    kimi_workflow(%{"FAKE_ACP_CONFIG_OPTIONS_RAW" => raw_options})
    workspace = task_workspace()
    run_id = BoardFactory.unique("run")

    assert {:error, {:unsupported_kimi_acp_shape, {:missing_option, "model"}}} =
             KimiACP.start_session(workspace,
               backend: "kimi",
               run_id: run_id,
               model: @model,
               effort: @effort
             )
  end

  test "start_session selects options by exact id, not by category" do
    raw_options =
      Jason.encode!([
        %{
          "id" => "spoofed-model",
          "name" => "Model",
          "category" => "model",
          "type" => "select",
          "currentValue" => @model,
          "options" => [%{"value" => @model, "name" => @model}]
        },
        %{
          "id" => "mode",
          "name" => "Mode",
          "category" => "mode",
          "type" => "select",
          "currentValue" => "auto",
          "options" => [%{"value" => "auto", "name" => "auto"}]
        }
      ])

    kimi_workflow(%{"FAKE_ACP_CONFIG_OPTIONS_RAW" => raw_options})
    workspace = task_workspace()
    run_id = BoardFactory.unique("run")

    assert {:error, {:unsupported_kimi_acp_shape, {:missing_option, "model"}}} =
             KimiACP.start_session(workspace,
               backend: "kimi",
               run_id: run_id,
               model: @model,
               effort: @effort
             )
  end

  test "start_session rejects an unsupported ACP protocol version" do
    kimi_workflow(%{"FAKE_ACP_PROTOCOL_VERSION" => "2"})
    workspace = task_workspace()
    run_id = BoardFactory.unique("run")

    assert {:error, {:unsupported_acp_protocol_version, 2}} =
             KimiACP.start_session(workspace,
               backend: "kimi",
               run_id: run_id,
               model: @model,
               effort: @effort
             )

    assert RunTransport.fetch_config(run_id, 1) == :error
  end

  test "start_session rejects an agent without MCP-over-HTTP capability" do
    kimi_workflow(%{"FAKE_ACP_MCP_HTTP" => "false"})
    workspace = task_workspace()
    run_id = BoardFactory.unique("run")

    assert {:error, :mcp_http_capability_missing} =
             KimiACP.start_session(workspace,
               backend: "kimi",
               run_id: run_id,
               model: @model,
               effort: @effort
             )

    assert RunTransport.fetch_config(run_id, 1) == :error
  end

  test "start_session authenticates with the login method when advertised" do
    ctx = kimi_workflow(%{"FAKE_ACP_AUTH_METHODS" => ~s([{"id": "login"}])})
    workspace = task_workspace()
    run_id = BoardFactory.unique("run")

    assert {:ok, session} =
             KimiACP.start_session(workspace,
               backend: "kimi",
               run_id: run_id,
               model: @model,
               effort: @effort
             )

    on_exit(fn -> KimiACP.stop_session(session) end)

    events = capture_events(ctx.capture)

    assert Enum.map(events, & &1["type"]) == [
             "initialize",
             "authenticate",
             "session/new",
             "session/set_config_option",
             "session/set_config_option",
             "session/set_config_option"
           ]

    [authenticate] = Enum.filter(events, &(&1["type"] == "authenticate"))
    assert authenticate["params"]["methodId"] == "login"
  end

  test "start_session surfaces an auth-required error as kimi login" do
    kimi_workflow(%{
      "FAKE_ACP_AUTH_METHODS" => ~s([{"id": "login"}]),
      "FAKE_ACP_AUTH_REQUIRED" => "1"
    })

    workspace = task_workspace()
    run_id = BoardFactory.unique("run")

    assert {:error, {:acp_auth_required, "kimi login"}} =
             KimiACP.start_session(workspace,
               backend: "kimi",
               run_id: run_id,
               model: @model,
               effort: @effort
             )

    assert RunTransport.fetch_config(run_id, 1) == :error
  end

  test "start_session rejects remote worker hosts without spawning the agent" do
    ctx = kimi_workflow()
    workspace = Path.join(Paths.worktrees_root("symphony"), BoardFactory.unique("kimi-ws"))
    run_id = BoardFactory.unique("run")

    assert {:error, :acp_remote_unsupported} =
             KimiACP.start_session(workspace,
               backend: "kimi",
               run_id: run_id,
               model: @model,
               effort: @effort,
               worker_host: "builder-a"
             )

    refute File.exists?(ctx.capture)
    assert RunTransport.fetch_config(run_id, 1) == :error
  end

  test "prompt streams normalized messages and increments the turn id" do
    kimi_workflow()
    workspace = task_workspace()
    run_id = BoardFactory.unique("run")

    assert {:ok, session} =
             KimiACP.start_session(workspace,
               backend: "kimi",
               run_id: run_id,
               model: @model,
               effort: @effort
             )

    on_exit(fn -> KimiACP.stop_session(session) end)

    test_pid = self()
    on_message = fn message -> send(test_pid, {:kimi_message, message}) end

    assert {:ok, result} = KimiACP.prompt(session, "Say something.", %{id: "task-1"}, on_message: on_message)
    assert result.stop_reason == :end_turn
    assert result.turn_id == "prompt-1"
    assert result.session.turn == 1

    assert_receive {:kimi_message,
                    %{
                      event: :session_started,
                      thread_id: "fake-acp-session",
                      turn_id: "prompt-1",
                      model: @model,
                      effort: @effort,
                      timestamp: %DateTime{}
                    }}

    assert_receive {:kimi_message, %{event: :notification, payload: %{"method" => "kimi/agent_message_chunk"}}}
    assert_receive {:kimi_message, %{event: :notification, payload: %{"method" => "kimi/tool_call"}}}
    assert_receive {:kimi_message, %{event: :turn_completed, stop_reason: "end_turn"}}

    assert {:ok, second} = KimiACP.prompt(result.session, "Again.", %{id: "task-1"}, on_message: on_message)
    assert second.stop_reason == :end_turn
    assert second.turn_id == "prompt-2"
    assert second.session.turn == 2

    assert_receive {:kimi_message, %{event: :session_started, turn_id: "prompt-2"}}
  end

  test "prompt maps the max_tokens stop reason to an ok result" do
    kimi_workflow(%{"FAKE_ACP_STOP_REASON" => "max_tokens"})
    workspace = task_workspace()
    run_id = BoardFactory.unique("run")

    assert {:ok, session} = KimiACP.start_session(workspace, backend: "kimi", run_id: run_id)
    on_exit(fn -> KimiACP.stop_session(session) end)

    assert {:ok, %{stop_reason: :max_tokens, turn_id: "prompt-1"}} =
             KimiACP.prompt(session, "Run out of tokens.", %{id: "task-1"}, on_message: fn _ -> :ok end)
  end

  test "prompt maps a refusal stop reason to an error" do
    kimi_workflow(%{"FAKE_ACP_STOP_REASON" => "refusal"})
    workspace = task_workspace()
    run_id = BoardFactory.unique("run")

    assert {:ok, session} = KimiACP.start_session(workspace, backend: "kimi", run_id: run_id)
    on_exit(fn -> KimiACP.stop_session(session) end)

    assert {:error, {:acp_refusal, "fake-acp-session"}} =
             KimiACP.prompt(session, "Refuse this.", %{id: "task-1"}, on_message: fn _ -> :ok end)
  end

  test "prompt maps an unknown stop reason to an error" do
    kimi_workflow(%{"FAKE_ACP_STOP_REASON" => "weird"})
    workspace = task_workspace()
    run_id = BoardFactory.unique("run")

    assert {:ok, session} = KimiACP.start_session(workspace, backend: "kimi", run_id: run_id)
    on_exit(fn -> KimiACP.stop_session(session) end)

    assert {:error, {:acp_unknown_stop_reason, "weird"}} =
             KimiACP.prompt(session, "Be weird.", %{id: "task-1"}, on_message: fn _ -> :ok end)
  end

  test "cancel_turn cancels an in-flight prompt" do
    ctx = kimi_workflow(%{"FAKE_ACP_WAIT_CANCEL" => "1"})
    workspace = task_workspace()
    run_id = BoardFactory.unique("run")
    test_pid = self()

    prompt_task =
      Task.async(fn ->
        {:ok, session} = KimiACP.start_session(workspace, backend: "kimi", run_id: run_id)
        send(test_pid, {:session_started, session})
        KimiACP.prompt(session, "Wait forever.", %{id: "task-1"}, on_message: fn _ -> :ok end)
      end)

    assert_receive {:session_started, session}, 15_000
    eventually(fn -> capture_has_type?(ctx.capture, "session/prompt") end)

    assert :ok = KimiACP.cancel_turn(session)
    assert {:error, :turn_cancelled} = Task.await(prompt_task, 15_000)

    eventually(fn -> capture_has_type?(ctx.capture, "session/cancel") end)
    [cancel] = ctx.capture |> capture_events() |> Enum.filter(&(&1["type"] == "session/cancel"))
    assert cancel["params"]["sessionId"] == "fake-acp-session"

    assert :ok = KimiACP.stop_session(session)
  end

  test "prompt auto-approves permission requests with the first allow_once option" do
    ctx = kimi_workflow(%{"FAKE_ACP_PERMISSION" => "1"})
    workspace = task_workspace()
    run_id = BoardFactory.unique("run")

    assert {:ok, session} = KimiACP.start_session(workspace, backend: "kimi", run_id: run_id)
    on_exit(fn -> KimiACP.stop_session(session) end)

    test_pid = self()
    on_message = fn message -> send(test_pid, {:kimi_message, message}) end

    assert {:ok, %{stop_reason: :end_turn}} =
             KimiACP.prompt(session, "Run a tool.", %{id: "task-1"}, on_message: on_message)

    assert_receive {:kimi_message,
                    %{
                      event: :approval_auto_approved,
                      outcome: %{"outcome" => "selected", "optionId" => "allow-once"}
                    }}

    [response] =
      ctx.capture
      |> capture_events()
      |> Enum.filter(&(&1["type"] == "agent_response" and &1["id"] == 90_001))

    assert response["result"] == %{"outcome" => %{"outcome" => "selected", "optionId" => "allow-once"}}
  end

  test "prompt cancels elicitation-style permission requests without allow options" do
    ctx = kimi_workflow(%{"FAKE_ACP_ELICIT" => "1"})
    workspace = task_workspace()
    run_id = BoardFactory.unique("run")

    assert {:ok, session} = KimiACP.start_session(workspace, backend: "kimi", run_id: run_id)
    on_exit(fn -> KimiACP.stop_session(session) end)

    assert {:ok, %{stop_reason: :end_turn}} =
             KimiACP.prompt(session, "Answer a question.", %{id: "task-1"}, on_message: fn _ -> :ok end)

    [response] =
      ctx.capture
      |> capture_events()
      |> Enum.filter(&(&1["type"] == "agent_response" and &1["id"] == 90_001))

    assert response["result"] == %{"outcome" => %{"outcome" => "cancelled"}}
  end

  test "prompt fails with the port exit reason when the agent crashes mid-turn" do
    kimi_workflow(%{"FAKE_ACP_WAIT_CANCEL" => "1", "FAKE_ACP_CRASH_AFTER" => "300"})
    workspace = task_workspace()
    run_id = BoardFactory.unique("run")

    assert {:ok, session} = KimiACP.start_session(workspace, backend: "kimi", run_id: run_id)
    on_exit(fn -> KimiACP.stop_session(session) end)

    assert {:error, {:port_exit, 3}} =
             KimiACP.prompt(session, "Crash now.", %{id: "task-1"}, on_message: fn _ -> :ok end)
  end

  test "stop_session is idempotent and unregisters the MCP scope" do
    kimi_workflow()
    workspace = task_workspace()
    run_id = BoardFactory.unique("run")

    assert {:ok, session} = KimiACP.start_session(workspace, backend: "kimi", run_id: run_id)
    assert {:ok, _config} = RunTransport.fetch_config(run_id, 1)

    assert :ok = KimiACP.stop_session(session)
    assert RunTransport.fetch_config(run_id, 1) == :error

    assert :ok = KimiACP.stop_session(session)
    assert RunTransport.fetch_config(run_id, 1) == :error
  end

  test "stats summarizes recorded run telemetry" do
    run_id = BoardFactory.unique("run")

    assert :ok =
             Projection.observe_run_telemetry(run_id, %{
               event: :session_started,
               thread_id: "s",
               turn_id: "prompt-1",
               timestamp: DateTime.utc_now()
             })

    assert KimiACP.stats(run_id) == %{"session_id" => "s", "turn_count" => 1, "token_usage" => nil}

    unknown_run_id = BoardFactory.unique("unknown-run")
    assert KimiACP.stats(unknown_run_id) == %{"session_id" => nil, "turn_count" => 0, "token_usage" => nil}
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp task_workspace do
    workspace = Path.join(Paths.worktrees_root("symphony"), BoardFactory.unique("kimi-ws"))
    File.mkdir_p!(workspace)
    workspace
  end

  defp kimi_workflow(fake_env \\ %{}, opts \\ []) do
    original_workflow = Workflow.workflow_file_path()
    source = BoardFactory.workflow_source()
    capture = Path.join(source.root, "fake-acp-capture.jsonl")
    command = fake_command(fake_env, source.root, capture)

    yaml =
      source.workflow
      |> File.read!()
      |> replace_backends_section(command, Keyword.get(opts, :include_codex, true))
      |> maybe_structured_stage_policy(Keyword.get(opts, :stage_policy, :legacy))

    File.write!(source.workflow, yaml)
    Workflow.set_workflow_file_path(source.workflow)
    assert :ok = Workflow.Store.force_reload()
    BoardFactory.await_activation()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow)
      Workflow.Store.force_reload()
    end)

    %{source: source, capture: capture}
  end

  # The ACP client wraps the backend command with `exec <command>`, so the
  # command must be a single simple command: the cd/env setup lives in a
  # launcher script.
  defp fake_command(fake_env, source_root, capture) do
    exports =
      fake_env
      |> Map.put("FAKE_ACP_CAPTURE", capture)
      |> Map.put("MIX_ENV", "test")
      |> Enum.map_join("\n", fn {key, value} -> "export #{key}=#{shell_escape(value)}" end)

    script = Path.join(source_root, "fake-kimi-acp.sh")

    File.write!(script, """
    #!/bin/sh
    set -e
    cd #{shell_escape(File.cwd!())}
    #{exports}
    exec mise exec -- mix run --no-compile --no-deps-check --no-start test/fixtures/fake_kimi_acp.exs
    """)

    "sh #{shell_escape(script)}"
  end

  defp replace_backends_section(workflow, command, include_codex) do
    codex =
      if include_codex do
        "  codex:\n" <>
          "    protocol: app_server\n" <>
          "    command: \"codex --config shell_environment_policy.inherit=all app-server\"\n"
      else
        ""
      end

    backends =
      "backends:\n" <>
        codex <>
        "  kimi:\n" <>
        "    protocol: acp\n" <>
        "    command: #{Jason.encode!(command)}\n" <>
        "    allow_unsandboxed: true\n"

    Regex.replace(~r/^codex:\n(?:  [^\n]*\n)+/m, workflow, backends)
  end

  defp maybe_structured_stage_policy(workflow, :legacy), do: workflow

  defp maybe_structured_stage_policy(workflow, :structured) do
    String.replace(
      workflow,
      "    allowed_model_efforts:\n      gpt-5.5: [xhigh]\n",
      "    allowed_models:\n      - backend: kimi\n        model: kimi-code/k3\n        efforts:\n          - max\n"
    )
  end

  defp capture_events(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      {:error, _reason} ->
        []
    end
  end

  defp capture_has_type?(path, type) do
    Enum.any?(capture_events(path), &(&1["type"] == type))
  end

  defp eventually(fun, timeout_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition did not become true")
      else
        Process.sleep(50)
        do_eventually(fun, deadline)
      end
    end
  end

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
