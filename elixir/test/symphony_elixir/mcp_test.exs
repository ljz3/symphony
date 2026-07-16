defmodule SymphonyElixir.MCPTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]

  alias SymphonyElixir.Board
  alias SymphonyElixir.BoardFactory
  alias SymphonyElixir.HttpServer
  alias SymphonyElixirWeb.Endpoint

  @endpoint Endpoint
  @protocol_version "2025-11-25"

  setup do
    start_supervised!(Endpoint)
    :ok
  end

  test "performs the MCP handshake and advertises exactly the three guarded task tools" do
    session_id = initialize_session()
    response = request(session_id, 2, "tools/list", %{})

    assert response.status == 200
    assert %{"result" => %{"tools" => tools}} = json_response(response, 200)

    assert Enum.map(tools, & &1["name"]) == [
             "symphony_task_create",
             "symphony_task_get",
             "symphony_tasks_by_state"
           ]

    assert Enum.all?(tools, &(&1["inputSchema"]["additionalProperties"] == false))

    create = Enum.at(tools, 0)
    assert create["inputSchema"]["required"] == ["project_id", "title", "type", "brief", "acceptance_criteria"]
    assert create["inputSchema"]["properties"]["project_id"]["type"] == "string"
    assert create["annotations"]["readOnlyHint"] == false
    assert create["annotations"]["destructiveHint"] == false
    assert create["annotations"]["idempotentHint"] == false
    assert create["annotations"]["openWorldHint"] == false

    get_tool = Enum.at(tools, 1)
    assert get_tool["inputSchema"]["required"] == ["project_id", "identifier"]

    assert get_tool["annotations"] == %{
             "title" => "Get Symphony task",
             "readOnlyHint" => true,
             "destructiveHint" => false,
             "idempotentHint" => true,
             "openWorldHint" => false
           }

    state_tool = Enum.at(tools, 2)
    assert state_tool["inputSchema"]["required"] == ["project_id", "state"]

    assert state_tool["inputSchema"]["properties"]["state"]["enum"] == [
             "backlog",
             "todo",
             "in_progress",
             "automated_review",
             "human_review",
             "rework",
             "merge_conflict",
             "merging",
             "blocked",
             "done",
             "cancelled"
           ]

    assert state_tool["annotations"]["readOnlyHint"] == true
    assert state_tool["annotations"]["destructiveHint"] == false
    assert state_tool["annotations"]["idempotentHint"] == true
    assert state_tool["annotations"]["openWorldHint"] == false

    close_session(session_id)
  end

  test "serves MCP through the same Bandit listener as the UI" do
    previous_endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])
    on_exit(fn -> Application.put_env(:symphony_elixir, Endpoint, previous_endpoint_config) end)

    stop_supervised!(Endpoint)
    start_supervised!({HttpServer, port: 0})
    port = HttpServer.bound_port()
    url = "http://127.0.0.1:#{port}/mcp"
    headers = [{"origin", "http://127.0.0.1:#{port}"}, {"accept", "application/json, text/event-stream"}]

    initialize = Req.post!(url, json: initialize_payload(5), headers: headers)
    assert initialize.status == 200
    assert get_in(initialize.body, ["result", "serverInfo", "name"]) == "symphony"
    assert [session_id] = Req.Response.get_header(initialize, "mcp-session-id")

    session_headers = [{"mcp-session-id", session_id}, {"mcp-protocol-version", @protocol_version} | headers]

    initialized =
      Req.post!(url,
        json: %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}},
        headers: session_headers
      )

    assert initialized.status == 202

    listed =
      Req.post!(url,
        json: %{"jsonrpc" => "2.0", "id" => 6, "method" => "tools/list", "params" => %{}},
        headers: session_headers
      )

    assert listed.status == 200

    assert get_in(listed.body, ["result", "tools"]) |> Enum.map(& &1["name"]) == [
             "symphony_task_create",
             "symphony_task_get",
             "symphony_tasks_by_state"
           ]

    assert Req.delete!(url, headers: session_headers).status == 200
  end

  test "gets an actionable task view without raw task, GitHub, or workpad data" do
    {dependency, _} = BoardFactory.create_task(%{title: BoardFactory.unique("MCP dependency")})

    {task, _} =
      BoardFactory.create_task(%{
        title: BoardFactory.unique("MCP lookup"),
        dependencies: [dependency["id"]],
        stage_selections: %{"implementation" => %{"model" => "gpt-5.5", "effort" => "xhigh"}}
      })

    session_id = initialize_session()

    payload =
      call_tool(session_id, 40, "symphony_task_get", %{
        "project_id" => "symphony",
        "identifier" => task["identifier"]
      })

    assert payload["task"] == %{
             "id" => task["id"],
             "identifier" => task["identifier"],
             "title" => task["title"],
             "type" => "feature",
             "priority" => "normal",
             "status" => %{
               "column_id" => "backlog",
               "column_name" => "Backlog",
               "runtime_state" => nil,
               "blocked_from_column_id" => nil,
               "desired_column_id" => nil
             },
             "brief" => task["brief"],
             "acceptance_criteria" => task["acceptance_criteria"],
             "stage_selections" => task["stage_selections"],
             "dependencies" => [%{"id" => dependency["id"], "identifier" => dependency["identifier"]}],
             "branch" => task["branch"],
             "pull_request" => nil,
             "active_run_id" => nil,
             "created_at" => task["created_at"],
             "updated_at" => task["updated_at"],
             "archived_at" => nil
           }

    assert payload["stats"]["run_count"] == 0
    assert payload["runs"] == %{"items" => [], "total" => 0, "truncated" => false}
    assert payload["events"]["total"] == 1
    assert length(payload["events"]["items"]) == 1

    event = hd(payload["events"]["items"])
    assert Map.keys(event) |> Enum.sort() == ["actor", "run_id", "sequence", "task_revision", "timestamp", "type"]
    refute Map.has_key?(event, "payload")
    refute Map.has_key?(event, "idempotency_key")
    refute Map.has_key?(payload["task"], "source")
    refute Map.has_key?(payload["task"], "github")
    refute Map.has_key?(payload["task"], "metadata")
    refute Jason.encode!(payload) =~ "workspace_path"
    refute Jason.encode!(payload) =~ "workpad"

    close_session(session_id)
  end

  test "lists current tasks by exact workflow state in canonical order" do
    {archived, _} = BoardFactory.create_task(%{title: BoardFactory.unique("MCP archived")})
    {cancelled, _} = BoardFactory.move(archived, "cancelled")

    assert {:ok, %{"task" => archived_task}} =
             Board.execute(%SymphonyElixir.Board.Commands.ArchiveTask{task_id: cancelled["id"]},
               actor: :human,
               expected_revision: cancelled["revision"],
               idempotency_key: BoardFactory.unique("mcp-archive")
             )

    {current, _} = BoardFactory.create_task(%{title: BoardFactory.unique("MCP current")})
    session_id = initialize_session()

    payload =
      call_tool(session_id, 50, "symphony_tasks_by_state", %{
        "project_id" => "symphony",
        "state" => "backlog"
      })

    assert payload["state"] == %{"id" => "backlog", "name" => "Backlog"}
    assert payload["count"] == length(payload["tasks"])
    assert Enum.any?(payload["tasks"], &(&1["id"] == current["id"]))
    refute Enum.any?(payload["tasks"], &(&1["id"] == archived_task["id"]))

    listed = Enum.find(payload["tasks"], &(&1["id"] == current["id"]))

    assert Map.keys(listed) |> Enum.sort() == [
             "branch",
             "dependencies",
             "id",
             "identifier",
             "priority",
             "pull_request",
             "status",
             "title",
             "type"
           ]

    assert Map.keys(listed["status"]) |> Enum.sort() == ["column_id", "column_name", "runtime_state"]

    close_session(session_id)
  end

  test "creates one canonical Backlog task and deduplicates a repeated MCP request" do
    session_id = initialize_session()
    before_tasks = length(Board.tasks())
    before_events = length(Board.events())
    arguments = valid_arguments(BoardFactory.unique("Created through MCP"))

    first = call_tool(session_id, 10, "symphony_task_create", arguments)
    second = call_tool(session_id, 10, "symphony_task_create", arguments)

    assert first == second
    assert %{"event_type" => "task_created", "task" => task_result} = first
    assert task_result["project_id"] == "symphony"
    assert task_result["column_id"] == "backlog"
    assert task_result["priority"] == "normal"
    assert length(Board.tasks()) == before_tasks + 1
    assert length(Board.events()) == before_events + 1

    assert {:ok, task} = Board.task(task_result["id"])
    assert task.identifier == task_result["identifier"]
    assert task.priority == :normal
    assert task.column_id == "backlog"

    assert [event] = Board.events(task.id)
    assert event["type"] == "task_created"
    assert event["actor"]["type"] == "agent"
    assert event["actor"]["identity"] =~ "mcp:"
    assert event["idempotency_key"] =~ "mcp:task-create:"

    close_session(session_id)
  end

  test "rejects incorrect project identity and malformed arguments without mutation" do
    session_id = initialize_session()
    before_tasks = length(Board.tasks())
    before_events = length(Board.events())
    valid = valid_arguments(BoardFactory.unique("Rejected MCP task"))

    mismatch =
      call_tool_error(session_id, 20, "symphony_task_create", %{valid | "project_id" => "another-project"})

    assert mismatch["error"]["code"] == "project_id_mismatch"
    refute mismatch["error"]["message"] =~ "symphony"

    missing = call_tool_error(session_id, 21, "symphony_task_create", Map.delete(valid, "project_id"))
    assert missing["error"]["code"] == "project_id_mismatch"

    unknown = call_tool_error(session_id, 22, "symphony_task_create", Map.put(valid, "unexpected", true))
    assert unknown["error"]["code"] == "invalid_arguments"
    assert unknown["error"]["message"] =~ "unexpected"

    invalid = call_tool_error(session_id, 23, "symphony_task_create", Map.put(valid, "type", "Incident"))
    assert invalid["error"]["code"] == "invalid_arguments"

    assert length(Board.tasks()) == before_tasks
    assert length(Board.events()) == before_events

    close_session(session_id)
  end

  test "guards every read tool before validating other arguments" do
    {task, _} = BoardFactory.create_task(%{title: BoardFactory.unique("MCP guard")})
    session_id = initialize_session()

    read_calls = [
      {"symphony_task_get", %{"project_id" => "symphony", "identifier" => task["identifier"]}},
      {"symphony_tasks_by_state", %{"project_id" => "symphony", "state" => "backlog"}}
    ]

    Enum.each(read_calls, fn {name, arguments} ->
      mismatch =
        call_tool_error(
          session_id,
          System.unique_integer([:positive]),
          name,
          Map.put(arguments, "project_id", "other")
        )

      assert mismatch["error"]["code"] == "project_id_mismatch"
      refute mismatch["error"]["message"] =~ "symphony"

      missing =
        call_tool_error(
          session_id,
          System.unique_integer([:positive]),
          name,
          Map.delete(arguments, "project_id")
        )

      assert missing["error"]["code"] == "project_id_mismatch"

      unknown =
        call_tool_error(
          session_id,
          System.unique_integer([:positive]),
          name,
          Map.put(arguments, "unexpected", true)
        )

      assert unknown["error"]["code"] == "invalid_arguments"
    end)

    assert call_tool_error(session_id, 61, "symphony_task_get", %{
             "project_id" => "symphony",
             "identifier" => "SYM-999999"
           })["error"]["code"] == "task_not_found"

    assert call_tool_error(session_id, 62, "symphony_tasks_by_state", %{
             "project_id" => "symphony",
             "state" => "BACKLOG"
           })["error"]["code"] == "unknown_state"

    close_session(session_id)
  end

  test "keeps the MCP path exact and rejects non-local Host and Origin headers" do
    payload = initialize_payload(30)

    assert local_conn(host: "example.com")
           |> post("/mcp", Jason.encode!(payload))
           |> response(403) =~ "non-localhost"

    assert local_conn(origin: "https://example.com")
           |> post("/mcp", Jason.encode!(payload))
           |> response(403) =~ "non-localhost"

    assert local_conn()
           |> post("/mcp/", Jason.encode!(payload))
           |> json_response(404)
           |> get_in(["error", "code"]) == "not_found"
  end

  defp initialize_session do
    initialize = local_conn() |> post("/mcp", Jason.encode!(initialize_payload(1)))
    assert initialize.status == 200
    assert get_in(json_response(initialize, 200), ["result", "serverInfo", "name"]) == "symphony"
    assert get_in(json_response(initialize, 200), ["result", "capabilities"]) |> Map.keys() == ["tools"]
    assert [session_id] = get_resp_header(initialize, "mcp-session-id")

    initialized =
      local_conn(session_id: session_id)
      |> post(
        "/mcp",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/initialized",
          "params" => %{}
        })
      )

    assert initialized.status == 202
    session_id
  end

  defp initialize_payload(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @protocol_version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "symphony-test", "version" => "1.0.0"}
      }
    }
  end

  defp request(session_id, id, method, params) do
    local_conn(session_id: session_id)
    |> post(
      "/mcp",
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
    )
  end

  defp call_tool(session_id, id, name, arguments) do
    response =
      request(session_id, id, "tools/call", %{
        "name" => name,
        "arguments" => arguments
      })

    body = json_response(response, 200)
    refute get_in(body, ["result", "isError"])
    body |> get_in(["result", "content"]) |> List.first() |> Map.fetch!("text") |> Jason.decode!()
  end

  defp call_tool_error(session_id, id, name, arguments) do
    response =
      request(session_id, id, "tools/call", %{
        "name" => name,
        "arguments" => arguments
      })

    body = json_response(response, 200)
    assert get_in(body, ["result", "isError"]) == true
    body |> get_in(["result", "content"]) |> List.first() |> Map.fetch!("text") |> Jason.decode!()
  end

  defp valid_arguments(title) do
    %{
      "project_id" => "symphony",
      "title" => title,
      "type" => "Feature",
      "brief" => "Created through the MCP endpoint.",
      "acceptance_criteria" => ["The task is persisted through the canonical board writer."]
    }
  end

  defp close_session(session_id) do
    response = local_conn(session_id: session_id) |> delete("/mcp")
    assert response.status == 200
  end

  defp local_conn(opts \\ []) do
    conn = %{build_conn() | host: Keyword.get(opts, :host, "127.0.0.1"), port: 4000}

    conn
    |> put_req_header("origin", Keyword.get(opts, :origin, "http://127.0.0.1:4000"))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", @protocol_version)
    |> maybe_put_session(Keyword.get(opts, :session_id))
  end

  defp maybe_put_session(conn, nil), do: conn
  defp maybe_put_session(conn, session_id), do: put_req_header(conn, "mcp-session-id", session_id)
end
