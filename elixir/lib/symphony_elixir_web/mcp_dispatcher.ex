defmodule SymphonyElixirWeb.MCPDispatcher do
  @moduledoc """
  Dispatches MCP routes before Phoenix consumes the JSON request body.

  `/mcp` is the shared project endpoint. `/mcp/runs/:run_id/:invocation` is
  a run-scoped bridge: the bearer token is verified and the request is handed
  only to that scope's isolated Plug configuration.
  """

  @behaviour Plug

  alias MCP.Transport.StreamableHTTP.Plug, as: StreamableHTTPPlug
  alias SymphonyElixir.MCP.{RunBridge, Transport}

  @local_hosts ["localhost", "127.0.0.1", "::1"]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{request_path: "/mcp"} = conn, _opts) do
    if local_request?(conn) do
      conn
      |> Transport.dispatch()
      |> Plug.Conn.halt()
    else
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(403, "Forbidden: non-localhost origin")
      |> Plug.Conn.halt()
    end
  end

  def call(%Plug.Conn{path_info: ["mcp", "runs", run_id, invocation], method: method} = conn, _opts)
      when method in ["POST", "GET", "DELETE"] do
    if local_request?(conn) do
      case RunBridge.authorize(conn, run_id, invocation) do
        {:ok, config} ->
          conn
          |> StreamableHTTPPlug.call(config)
          |> Plug.Conn.halt()

        :error ->
          forbidden(conn)
      end
    else
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(403, "Forbidden: non-localhost origin")
      |> Plug.Conn.halt()
    end
  end

  def call(conn, _opts), do: conn

  defp forbidden(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(403, "Forbidden")
    |> Plug.Conn.halt()
  end

  defp local_request?(conn) do
    conn.host in @local_hosts and local_origins?(Plug.Conn.get_req_header(conn, "origin"))
  end

  defp local_origins?([]), do: true
  defp local_origins?(origins), do: Enum.all?(origins, &local_origin?/1)

  defp local_origin?(origin) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] -> host in @local_hosts
      _uri -> false
    end
  end
end
