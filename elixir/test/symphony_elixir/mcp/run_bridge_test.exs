defmodule SymphonyElixir.MCP.RunBridgeTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Board, BoardFactory, Config, HttpServer, Paths}
  alias SymphonyElixir.Board.Commands
  alias SymphonyElixir.MCP.{RunBridge, RunHandler, RunTransport}
  alias SymphonyElixirWeb.Endpoint

  @protocol_version "2025-11-25"

  setup do
    previous_endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])
    on_exit(fn -> Application.put_env(:symphony_elixir, Endpoint, previous_endpoint_config) end)

    start_supervised!({HttpServer, port: 0})
    {:ok, port: HttpServer.bound_port()}
  end

  test "token is deterministic per {run_id, invocation} and decodes to 32 bytes" do
    assert {:ok, token_a1} = RunBridge.token("run-a", 1)
    assert {:ok, ^token_a1} = RunBridge.token("run-a", 1)

    assert {:ok, token_a2} = RunBridge.token("run-a", 2)
    assert {:ok, token_b1} = RunBridge.token("run-b", 1)

    refute token_a1 == token_a2
    refute token_a1 == token_b1

    assert {:ok, decoded} = Base.url_decode64(token_a1)
    assert byte_size(decoded) == 32
  end

  test "secret file is created with mode 0600 and reused across token calls" do
    {:ok, bundle} = Config.bundle()
    path = Path.join(Paths.runtime_root(bundle.project.id), "mcp_run_secret")
    run_id = BoardFactory.unique("run")

    assert {:ok, first} = RunBridge.token(run_id, 1)
    assert File.exists?(path)

    stat = File.stat!(path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600

    assert {:ok, secret} = File.read(path)
    assert byte_size(secret) == 32

    expected = :crypto.mac(:hmac, :sha256, secret, "#{run_id}:1") |> Base.url_encode64()
    assert first == expected

    # A second call reads the persisted secret instead of regenerating it.
    assert {:ok, ^first} = RunBridge.token(run_id, 1)
    assert {:ok, ^secret} = File.read(path)
  end

  test "await_bound_port returns the bound port while serving and times out when not" do
    assert {:ok, port} = HttpServer.await_bound_port(1_000)
    assert is_integer(port) and port > 0
    assert port == HttpServer.bound_port()

    stop_supervised!(HttpServer)
    assert HttpServer.bound_port() == nil
    assert {:error, :timeout} = HttpServer.await_bound_port(200)
  end

  test "scope registration is idempotent and teardown removes the config" do
    run_id = BoardFactory.unique("run")
    on_exit(fn -> RunTransport.unregister_scope(run_id, 1) end)
    baseline = RunTransport.scope_count()

    assert {:ok, :registered} = RunTransport.register_scope(run_id, 1)
    assert {:ok, :already_registered} = RunTransport.register_scope(run_id, 1)
    assert RunTransport.scope_count() == baseline + 1

    assert {:ok, %MCP.Transport.StreamableHTTP.Plug{} = config} = RunTransport.fetch_config(run_id, 1)
    assert config.handler_opts == [run_id: run_id, invocation: 1]
    assert is_reference(config.sessions) or is_tuple(config.sessions)

    assert :ok = RunTransport.unregister_scope(run_id, 1)
    assert :error = RunTransport.fetch_config(run_id, 1)
    assert RunTransport.scope_count() == baseline

    assert :ok = RunTransport.unregister_scope(run_id, 1)
  end

  test "initialize through the run endpoint returns a session bound to the scope" do
    run_id = BoardFactory.unique("run")
    %{url: url, token: token} = register_scope!(run_id)

    response = mcp_post(url, token, initialize_payload())

    assert response.status == 200
    assert get_in(response.body, ["result", "serverInfo", "name"]) == "symphony-run"
    assert [session_id] = Req.Response.get_header(response, "mcp-session-id")
    assert is_binary(session_id)
  end

  test "rejects missing, wrong, cross-invocation, and unregistered-scope tokens", %{port: port} do
    run_id = BoardFactory.unique("run")
    %{url: url, token: _token} = register_scope!(run_id, 1)

    missing =
      Req.post!(url,
        json: initialize_payload(),
        headers: [{"accept", "application/json, text/event-stream"}],
        retry: false
      )

    assert missing.status == 403

    assert mcp_post(url, "definitely-not-the-token", initialize_payload()).status == 403

    {:ok, other_invocation_token} = RunBridge.token(run_id, 2)
    assert mcp_post(url, other_invocation_token, initialize_payload()).status == 403

    ghost_run = BoardFactory.unique("run")
    {:ok, ghost_token} = RunBridge.token(ghost_run, 1)
    ghost_url = "http://127.0.0.1:#{port}/mcp/runs/#{ghost_run}/1"
    assert mcp_post(ghost_url, ghost_token, initialize_payload()).status == 403
  end

  test "a session id minted in one scope does not resolve in another scope" do
    run_a = BoardFactory.unique("run")
    run_b = BoardFactory.unique("run")
    %{url: url_a, token: token_a} = register_scope!(run_a)
    %{url: url_b, token: token_b} = register_scope!(run_b)

    session_a = mcp_initialize(url_a, token_a)

    tools_list = %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list", "params" => %{}}
    cross_post = mcp_post(url_b, token_b, tools_list, session_a)
    assert cross_post.status == 404
    assert get_in(cross_post.body, ["error", "message"]) == "Not found"

    assert mcp_get(url_b, token_b, session_a).status == 404
    assert mcp_delete(url_b, token_b, session_a).status == 404

    # Scope A's session is untouched by the failed cross-scope calls.
    assert mcp_delete(url_a, token_a, session_a).status == 200
  end

  test "GET and DELETE route to the scope transport and DELETE tears the session down" do
    run_id = BoardFactory.unique("run")
    %{url: url, token: token} = register_scope!(run_id)
    session_id = mcp_initialize(url, token)

    assert mcp_get(url, token, session_id).status == 200
    assert mcp_delete(url, token, session_id).status == 200

    tools_list = %{"jsonrpc" => "2.0", "id" => 9, "method" => "tools/list", "params" => %{}}
    assert mcp_post(url, token, tools_list, session_id).status == 404
  end

  test "serves a real run's tools through the bridge end to end" do
    {task, run} = claimable_run()
    on_exit(fn -> cleanup_active_run(task["id"], run["id"]) end)
    %{url: url, token: token} = register_scope!(run["id"], 1)
    session_id = mcp_initialize(url, token)

    listed = mcp_post(url, token, %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list", "params" => %{}}, session_id)
    assert listed.status == 200
    tool_names = get_in(listed.body, ["result", "tools"]) |> Enum.map(& &1["name"])

    for tool <- ~w(symphony_task_context symphony_workpad_read symphony_workpad_write symphony_task_transition) do
      assert tool in tool_names
    end

    written = mcp_call(url, token, session_id, 3, "symphony_workpad_write", %{"content" => "hello"})
    refute get_in(written, ["result", "isError"])

    assert %{"bytes" => 5, "invocation" => 1, "run_id" => run["id"]} ==
             written |> get_in(["result", "content"]) |> List.first() |> Map.fetch!("text") |> Jason.decode!()

    read = mcp_call(url, token, session_id, 4, "symphony_workpad_read", %{})
    refute get_in(read, ["result", "isError"])

    assert read |> get_in(["result", "content"]) |> List.first() |> Map.fetch!("text") |> Jason.decode!() |> Map.fetch!("content") =~
             "hello"
  end

  test "handler namespaces call ids by request id so replays dedupe at the board" do
    {task, run} = claimable_run()
    on_exit(fn -> cleanup_active_run(task["id"], run["id"]) end)
    {:ok, state} = RunHandler.init(run_id: run["id"], invocation: 1)
    context = %MCP.Server.ToolContext{server_pid: self(), request_id: 7, meta: nil}

    criterion_id = task["acceptance_criteria"] |> hd() |> Map.fetch!("id")

    accept_args = %{
      "criterion_id" => criterion_id,
      "evidence" => [%{"command" => "mix test", "result" => "passed"}],
      "expected_revision" => task["revision"]
    }

    # The same request id maps to the same `dynamic-tool:<run>:mcp:<nonce>:<id>`
    # idempotency key, so the duplicate delivery replays the stored result.
    assert {:ok, [%{"type" => "text", "text" => first_text}], false, ^state} =
             RunHandler.handle_call_tool("symphony_acceptance_complete", accept_args, context, state)

    assert {:ok, [%{"type" => "text", "text" => ^first_text}], false, ^state} =
             RunHandler.handle_call_tool("symphony_acceptance_complete", accept_args, context, state)

    assert {:ok, after_accept} = Board.task(task["id"])
    assert after_accept.revision == task["revision"] + 1

    # The terminal transition lands exactly once.
    blocked_args = %{"column_id" => "blocked", "reason" => "stuck", "expected_revision" => after_accept.revision}

    assert {:ok, [%{"type" => "text", "text" => blocked_text}], false, ^state} =
             RunHandler.handle_call_tool("symphony_task_transition", blocked_args, %{context | request_id: 8}, state)

    assert Jason.decode!(blocked_text)["run"] == %{"status" => "failed"}

    assert {:ok, blocked} = Board.task(task["id"])
    assert blocked.column_id == "blocked"
    assert blocked.revision == after_accept.revision + 1

    # Re-delivering the terminal transition does not double-apply: the
    # same-column guard fires (DynamicTool semantics, identical to the codex
    # channel) and the board still shows exactly one transition event.
    assert {:ok, [%{"type" => "text", "text" => redelivered_text}], true, ^state} =
             RunHandler.handle_call_tool("symphony_task_transition", blocked_args, %{context | request_id: 8}, state)

    assert Jason.decode!(redelivered_text)["error"]["reason"] =~ "transition_must_change_column"

    # A fresh request id after the terminal transition is an error too: the run
    # is no longer active for any other target column.
    assert {:ok, [%{"type" => "text", "text" => inactive_text}], true, ^state} =
             RunHandler.handle_call_tool(
               "symphony_task_transition",
               %{"column_id" => "rework", "expected_revision" => blocked.revision},
               %{context | request_id: 9},
               state
             )

    assert Jason.decode!(inactive_text)["error"]["reason"] =~ "tool_scope_not_active"

    assert 1 == Board.events(task["id"]) |> Enum.count(&(&1["type"] == "task_blocked"))
  end

  test "handler converts dynamic-tool results into MCP content with isError flags" do
    {task, run} = claimable_run()
    on_exit(fn -> cleanup_active_run(task["id"], run["id"]) end)
    {:ok, state} = RunHandler.init(run_id: run["id"], invocation: 1)
    context = %MCP.Server.ToolContext{server_pid: self(), request_id: 1, meta: nil}

    assert {:ok, [%{"type" => "text", "text" => error_text}], true, ^state} =
             RunHandler.handle_call_tool("symphony_no_such_tool", %{}, context, state)

    assert %{"error" => %{"reason" => reason}} = Jason.decode!(error_text)
    assert reason =~ "unsupported_dynamic_tool"

    assert {:ok, [%{"type" => "text", "text" => ok_text}], false, ^state} =
             RunHandler.handle_call_tool(
               "symphony_workpad_write",
               %{"content" => "conversion"},
               %{context | request_id: 2},
               state
             )

    assert %{"run_id" => written_run_id, "invocation" => 1, "bytes" => 10} = Jason.decode!(ok_text)
    assert written_run_id == run["id"]

    {:ok, dead_state} = RunHandler.init(run_id: "no-such-run", invocation: 1)

    assert {:ok, [%{"type" => "text", "text" => dead_text}], true, ^dead_state} =
             RunHandler.handle_call_tool("symphony_workpad_read", %{}, context, dead_state)

    assert Jason.decode!(dead_text)["error"]["reason"] == "run_unavailable"
  end

  test "unregister closes every session transport, deletes the table, and re-registration is fresh" do
    run_id = BoardFactory.unique("run")
    %{url: url, token: token} = register_scope!(run_id)

    session_one = mcp_initialize(url, token)
    session_two = mcp_initialize(url, token)
    refute session_one == session_two

    {:ok, config} = RunTransport.fetch_config(run_id, 1)
    entries = :ets.tab2list(config.sessions)
    assert length(entries) == 2
    transport_pids = Enum.map(entries, fn {_session_id, transport_pid} -> transport_pid end)
    assert Enum.all?(transport_pids, &Process.alive?/1)

    assert :ok = RunBridge.unregister(run_id, 1)
    assert :error = RunTransport.fetch_config(run_id, 1)
    assert :ets.info(config.sessions) == :undefined
    Enum.each(transport_pids, fn pid -> eventually(fn -> not Process.alive?(pid) end) end)

    assert {:ok, :registered} = RunTransport.register_scope(run_id, 1)
    {:ok, fresh} = RunTransport.fetch_config(run_id, 1)
    assert fresh.sessions != config.sessions
    assert :ets.tab2list(fresh.sessions) == []
  end

  test "the global /mcp endpoint still serves initialize without bearer auth", %{port: port} do
    url = "http://127.0.0.1:#{port}/mcp"

    response =
      Req.post!(url,
        json: initialize_payload(),
        headers: [{"accept", "application/json, text/event-stream"}, {"mcp-protocol-version", @protocol_version}],
        retry: false
      )

    assert response.status == 200
    assert get_in(response.body, ["result", "serverInfo", "name"]) == "symphony"
    assert [session_id] = Req.Response.get_header(response, "mcp-session-id")

    assert Req.delete!(url,
             headers: [
               {"mcp-session-id", session_id},
               {"mcp-protocol-version", @protocol_version}
             ],
             retry: false
           ).status == 200
  end

  defp register_scope!(run_id, invocation \\ 1) do
    {:ok, %{url: url, token: token}} = RunBridge.register(run_id, invocation)
    on_exit(fn -> RunBridge.unregister(run_id, invocation) end)
    %{url: url, token: token}
  end

  defp claimable_run do
    {created, _} = BoardFactory.create_task(%{title: BoardFactory.unique("Run bridge task")})
    {todo, _} = BoardFactory.move(created, "todo")

    {:ok, %{"task" => claimed, "run" => run}} =
      Board.execute(%Commands.ClaimRun{task_id: todo["id"]},
        actor: :system,
        expected_revision: todo["revision"],
        idempotency_key: BoardFactory.unique("claim")
      )

    {claimed, run}
  end

  defp cleanup_active_run(task_id, run_id) do
    case Board.task(task_id) do
      {:ok, %{active_run_id: ^run_id} = task} ->
        Board.execute(%Commands.RunFailed{task_id: task_id, run_id: run_id, reason: :test_cleanup},
          actor: :system,
          expected_revision: task.revision,
          idempotency_key: BoardFactory.unique("cleanup")
        )

      _ ->
        :ok
    end
  end

  defp initialize_payload(id \\ 1) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @protocol_version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "run-bridge-test", "version" => "1.0.0"}
      }
    }
  end

  defp mcp_initialize(url, token) do
    response = mcp_post(url, token, initialize_payload())
    assert response.status == 200
    assert [session_id] = Req.Response.get_header(response, "mcp-session-id")

    initialized =
      mcp_post(
        url,
        token,
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}},
        session_id
      )

    assert initialized.status == 202
    session_id
  end

  defp mcp_call(url, token, session_id, id, name, arguments) do
    response =
      mcp_post(
        url,
        token,
        %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call", "params" => %{"name" => name, "arguments" => arguments}},
        session_id
      )

    assert response.status == 200
    response.body
  end

  defp mcp_post(url, token, body, session_id \\ nil) do
    Req.post!(url, json: body, headers: mcp_headers(token, session_id), retry: false)
  end

  defp mcp_get(url, token, session_id) do
    Req.get!(url, headers: mcp_headers(token, session_id), retry: false)
  end

  defp mcp_delete(url, token, session_id) do
    Req.delete!(url, headers: mcp_headers(token, session_id), retry: false)
  end

  defp mcp_headers(token, session_id) do
    headers = [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/json, text/event-stream"},
      {"mcp-protocol-version", @protocol_version}
    ]

    if session_id, do: [{"mcp-session-id", session_id} | headers], else: headers
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: flunk("condition did not become true")

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end
end
