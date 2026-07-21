defmodule SymphonyElixir.ACP.ClientTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ACP.Client

  @moduletag timeout: 120_000

  @fake_script "test/fixtures/fake_kimi_acp.exs"
  @recv_timeout 15_000

  test "handshake correlates responses to their own refs, including overlapping requests" do
    {client, _cwd} = start_client()

    {:ok, init_ref} = Client.request_async(client, "initialize", initialize_params(), @recv_timeout)

    assert_receive {:acp_response, ^init_ref, {:ok, hello}}, @recv_timeout
    assert hello["protocolVersion"] == 1
    assert hello["agentInfo"]["name"] == "Fake Kimi ACP"
    assert get_in(hello, ["agentCapabilities", "mcpCapabilities", "http"]) == true

    {:ok, session_ref} = Client.request_async(client, "session/new", session_new_params(), @recv_timeout)
    assert_receive {:acp_response, ^session_ref, {:ok, %{"sessionId" => "fake-acp-session"}}}, @recv_timeout

    # Two overlapping in-flight requests resolve to their own refs.
    {:ok, first_ref} =
      Client.request_async(
        client,
        "session/set_config_option",
        %{"sessionId" => "fake-acp-session", "configId" => "mode", "value" => "yolo"},
        @recv_timeout
      )

    {:ok, second_ref} = Client.request_async(client, "session/new", session_new_params(), @recv_timeout)

    assert_receive {:acp_response, ^first_ref, {:ok, %{"configOptions" => options}}}, @recv_timeout
    assert is_list(options)
    assert_receive {:acp_response, ^second_ref, {:ok, %{"sessionId" => "fake-acp-session"}}}, @recv_timeout
  end

  test "session/update notifications stream to the subscriber with raw lines" do
    {client, _cwd} = start_client()

    {:ok, init_ref} = Client.request_async(client, "initialize", initialize_params(), @recv_timeout)
    assert_receive {:acp_response, ^init_ref, {:ok, _hello}}, @recv_timeout

    {:ok, session_ref} = Client.request_async(client, "session/new", session_new_params(), @recv_timeout)
    assert_receive {:acp_response, ^session_ref, {:ok, %{"sessionId" => _}}}, @recv_timeout

    {:ok, prompt_ref} = Client.request_async(client, "session/prompt", prompt_params(), @recv_timeout)

    assert_receive {:acp_notification, "session/update", first_params, first_raw}, @recv_timeout
    assert_receive {:acp_notification, "session/update", second_params, second_raw}, @recv_timeout

    assert first_params["sessionId"] == "fake-acp-session"
    assert get_in(first_params, ["update", "sessionUpdate"]) == "agent_message_chunk"
    assert get_in(first_params, ["update", "content", "text"]) == "fake chunk"
    assert Jason.decode!(first_raw)["method"] == "session/update"

    assert get_in(second_params, ["update", "sessionUpdate"]) == "tool_call"
    assert get_in(second_params, ["update", "toolCallId"]) == "call-1"
    assert Jason.decode!(second_raw)["method"] == "session/update"

    assert_receive {:acp_response, ^prompt_ref, {:ok, %{"stopReason" => "end_turn"}}}, @recv_timeout
  end

  test "agent-initiated permission requests are answered with respond/3" do
    cwd = tmp_cwd()
    capture = Path.join(cwd, "capture.jsonl")
    {client, ^cwd} = start_client(%{"FAKE_ACP_PERMISSION" => "1", "FAKE_ACP_CAPTURE" => capture}, cwd: cwd)

    {:ok, init_ref} = Client.request_async(client, "initialize", initialize_params(), @recv_timeout)
    assert_receive {:acp_response, ^init_ref, {:ok, _hello}}, @recv_timeout

    {:ok, prompt_ref} = Client.request_async(client, "session/prompt", prompt_params(), @recv_timeout)

    assert_receive {:acp_request, 90_001, "session/request_permission", params, raw}, @recv_timeout
    assert get_in(params, ["toolCall", "toolCallId"]) == "call-1"
    assert Enum.any?(params["options"], &(&1["kind"] == "allow_once"))
    assert Jason.decode!(raw)["method"] == "session/request_permission"

    outcome = %{"outcome" => %{"outcome" => "selected", "optionId" => "allow-once"}}
    assert :ok = Client.respond(client, 90_001, outcome)

    assert_receive {:acp_response, ^prompt_ref, {:ok, %{"stopReason" => "end_turn"}}}, @recv_timeout

    eventually(fn ->
      File.exists?(capture) &&
        Enum.any?(captured_events(capture), fn
          %{"type" => "agent_response", "id" => 90_001, "result" => result} -> result == outcome
          _other -> false
        end)
    end)
  end

  test "respond_error/4 answers agent-initiated requests with an error object" do
    cwd = tmp_cwd()
    capture = Path.join(cwd, "capture.jsonl")
    {client, ^cwd} = start_client(%{"FAKE_ACP_ELICIT" => "1", "FAKE_ACP_CAPTURE" => capture}, cwd: cwd)

    {:ok, init_ref} = Client.request_async(client, "initialize", initialize_params(), @recv_timeout)
    assert_receive {:acp_response, ^init_ref, {:ok, _hello}}, @recv_timeout

    {:ok, prompt_ref} = Client.request_async(client, "session/prompt", prompt_params(), @recv_timeout)

    assert_receive {:acp_request, 90_001, "session/request_permission", params, _raw}, @recv_timeout
    assert Enum.all?(params["options"], &String.starts_with?(&1["kind"], "reject"))

    assert :ok = Client.respond_error(client, 90_001, -32_001, "client denied")

    assert_receive {:acp_response, ^prompt_ref, {:ok, %{"stopReason" => "end_turn"}}}, @recv_timeout

    eventually(fn ->
      File.exists?(capture) &&
        Enum.any?(captured_events(capture), fn
          %{"type" => "agent_response", "id" => 90_001, "error" => error} ->
            error == %{"code" => -32_001, "message" => "client denied"}

          _other ->
            false
        end)
    end)
  end

  test "malformed stdout lines surface as :acp_malformed and the client survives" do
    {client, _cwd} = start_client(%{"FAKE_ACP_MALFORMED" => "1"})

    assert_receive {:acp_malformed, "this line is not json"}, @recv_timeout

    {:ok, init_ref} = Client.request_async(client, "initialize", initialize_params(), @recv_timeout)
    assert_receive {:acp_response, ^init_ref, {:ok, %{"protocolVersion" => 1}}}, @recv_timeout
  end

  test "stderr is redirected to the log file and never enters the JSON stream" do
    cwd = tmp_cwd()
    stderr_log = Path.join(cwd, "agent.stderr.log")
    {client, ^cwd} = start_client(%{"FAKE_ACP_STDERR" => "1"}, cwd: cwd, stderr_log: stderr_log)

    {:ok, init_ref} = Client.request_async(client, "initialize", initialize_params(), @recv_timeout)
    assert_receive {:acp_response, ^init_ref, {:ok, %{"protocolVersion" => 1}}}, @recv_timeout

    eventually(fn -> File.exists?(stderr_log) && File.read!(stderr_log) =~ "fake stderr line" end)

    refute_receive {:acp_malformed, _line}, 300
  end

  test "agent crash fails pending requests, notifies the subscriber, and exits the client" do
    {client, _cwd} = start_client(%{"FAKE_ACP_CRASH_AFTER" => "200", "FAKE_ACP_WAIT_CANCEL" => "1"})
    monitor = Process.monitor(client)

    {:ok, init_ref} = Client.request_async(client, "initialize", initialize_params(), @recv_timeout)
    assert_receive {:acp_response, ^init_ref, {:ok, %{"protocolVersion" => 1}}}, @recv_timeout

    {:ok, prompt_ref} = Client.request_async(client, "session/prompt", prompt_params(), 5_000)

    assert_receive {:acp_response, ^prompt_ref, {:error, {:port_exit, 3}}}, @recv_timeout
    assert_receive {:acp_exit, {:port_exit, 3}}, @recv_timeout
    assert_receive {:DOWN, ^monitor, :process, ^client, :normal}, @recv_timeout
  end

  test "request timeout reaches the caller and the hung transport stays stoppable" do
    {client, cwd} = start_client(%{"FAKE_ACP_HANG" => "1"})

    {:ok, ref} = Client.request_async(client, "initialize", initialize_params(), 100)

    assert_receive {:acp_response, ^ref, {:error, :acp_request_timeout}}, @recv_timeout
    assert Process.alive?(client)

    assert :ok = Client.stop(client)
    refute Process.alive?(client)

    kill_hung_agent(cwd)
  end

  test "oversize frames trip the frame cap, fail pending requests, and stop the client" do
    {client, _cwd} = start_client(%{"FAKE_ACP_OVERSIZE" => "1", "FAKE_ACP_WAIT_CANCEL" => "1"})
    monitor = Process.monitor(client)

    {:ok, init_ref} = Client.request_async(client, "initialize", initialize_params(), @recv_timeout)
    {:ok, prompt_ref} = Client.request_async(client, "session/prompt", prompt_params(), @recv_timeout)

    assert_receive {:acp_response, ^init_ref, {:ok, %{"protocolVersion" => 1}}}, @recv_timeout

    assert_receive {:acp_response, ^prompt_ref, {:error, {:acp_message_too_large, bytes}}}, @recv_timeout
    assert is_integer(bytes)
    assert bytes > 8 * 1024 * 1024

    assert_receive {:acp_exit, {:acp_message_too_large, ^bytes}}, @recv_timeout
    assert_receive {:DOWN, ^monitor, :process, ^client, :normal}, @recv_timeout
  end

  test "notify/3 sends notifications; session/cancel releases a held prompt" do
    cwd = tmp_cwd()
    capture = Path.join(cwd, "capture.jsonl")
    {client, ^cwd} = start_client(%{"FAKE_ACP_WAIT_CANCEL" => "1", "FAKE_ACP_CAPTURE" => capture}, cwd: cwd)

    {:ok, init_ref} = Client.request_async(client, "initialize", initialize_params(), @recv_timeout)
    assert_receive {:acp_response, ^init_ref, {:ok, _hello}}, @recv_timeout

    {:ok, prompt_ref} = Client.request_async(client, "session/prompt", prompt_params(), @recv_timeout)

    eventually(fn ->
      File.exists?(capture) &&
        Enum.any?(captured_events(capture), &(&1["type"] == "session/prompt"))
    end)

    assert :ok = Client.notify(client, "session/cancel", %{"sessionId" => "fake-acp-session"})

    assert_receive {:acp_notification, "session/update", params, _raw}, @recv_timeout
    assert get_in(params, ["update", "sessionUpdate"]) == "tool_call_update"
    assert get_in(params, ["update", "status"]) == "cancelled"

    assert_receive {:acp_response, ^prompt_ref, {:ok, %{"stopReason" => "cancelled"}}}, @recv_timeout

    eventually(fn ->
      Enum.any?(captured_events(capture), &(&1["type"] == "session/cancel"))
    end)
  end

  test "stop/1 is idempotent and tolerates dead processes" do
    {client, _cwd} = start_client()

    assert :ok = Client.stop(client)
    refute Process.alive?(client)
    assert :ok = Client.stop(client)

    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, _reason}, 5_000
    assert :ok = Client.stop(dead)
  end

  test "stopping the transport explicitly fails every pending caller" do
    {client, _cwd} = start_client(%{"FAKE_ACP_WAIT_CANCEL" => "1"})
    monitor = Process.monitor(client)

    {:ok, init_ref} = Client.request_async(client, "initialize", initialize_params(), @recv_timeout)
    assert_receive {:acp_response, ^init_ref, {:ok, _hello}}, @recv_timeout

    {:ok, prompt_ref} = Client.request_async(client, "session/prompt", prompt_params(), @recv_timeout)

    assert :ok = Client.stop(client)

    assert_receive {:acp_response, ^prompt_ref, {:error, :transport_stopped}}, @recv_timeout
    assert_receive {:acp_exit, :transport_stopped}, @recv_timeout
    assert_receive {:DOWN, ^monitor, :process, ^client, :normal}, @recv_timeout
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  # The client wraps the command as `exec <command> 2>> <log>`, which only
  # supports a single simple command, so the `cd` + `mix run` launch lives in
  # a per-test script. The script records its own pid before the exec chain
  # (the pid survives every `exec`) so tests can reap a hung agent.
  defp start_client(environment \\ %{}, opts \\ []) do
    {cwd, opts} = Keyword.pop_lazy(opts, :cwd, &tmp_cwd/0)
    File.mkdir_p!(cwd)
    launcher = write_launcher!(cwd)

    client_opts =
      [command: launcher, cwd: cwd, environment: environment, subscriber: self()]
      |> Keyword.merge(opts)

    {:ok, client} = Client.start_link(client_opts)

    on_exit(fn -> Client.stop(client) end)

    {client, cwd}
  end

  defp tmp_cwd do
    Path.join(System.tmp_dir!(), "acp-client-#{System.unique_integer([:positive])}")
  end

  defp write_launcher!(cwd) do
    path = Path.join(cwd, "launch-fake-acp.sh")

    File.write!(path, """
    #!/bin/sh
    echo $$ > #{shell_escape(Path.join(cwd, "agent.pid"))}
    cd #{shell_escape(File.cwd!())} || exit 1
    MIX_ENV=test
    export MIX_ENV
    exec mise exec -- mix run --no-compile --no-deps-check --no-start #{@fake_script}
    """)

    File.chmod!(path, 0o755)
    shell_escape(path)
  end

  defp kill_hung_agent(cwd) do
    with {:ok, contents} <- File.read(Path.join(cwd, "agent.pid")),
         {pid, ""} <- Integer.parse(String.trim(contents)),
         {command, 0} <- System.cmd("ps", ["-o", "command=", "-p", Integer.to_string(pid)]) do
      # The pid comes from this test's own launcher; the guard only protects
      # against pid reuse in the seconds since the file was written. The
      # exec chain (sh -> mise -> mix -> beam) keeps a single pid.
      if command =~ cwd or command =~ "beam" or command =~ "mix" or command =~ "mise" do
        System.cmd("kill", ["-9", Integer.to_string(pid)])
      end
    end

    :ok
  end

  defp captured_events(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp initialize_params do
    %{
      "protocolVersion" => 1,
      "clientCapabilities" => %{"session" => %{"configOptions" => %{"boolean" => %{}}}},
      "clientInfo" => %{"name" => "symphony-acp-client-test", "version" => "0.0.0"}
    }
  end

  defp session_new_params do
    %{"cwd" => File.cwd!(), "mcpServers" => []}
  end

  defp prompt_params do
    %{"sessionId" => "fake-acp-session", "prompt" => [%{"type" => "text", "text" => "hello"}]}
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

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
