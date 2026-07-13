defmodule SymphonyElixirWeb.MCPDispatcher do
  @moduledoc "Dispatches the exact `/mcp` route before Phoenix consumes its JSON request body."

  @behaviour Plug

  alias SymphonyElixir.MCP.Transport

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

  def call(conn, _opts), do: conn

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
