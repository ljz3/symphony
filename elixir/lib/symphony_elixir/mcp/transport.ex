defmodule SymphonyElixir.MCP.Transport do
  @moduledoc """
  Owns the runtime Streamable HTTP MCP session registry used by the shared Phoenix endpoint.
  """

  use GenServer

  alias MCP.Transport.StreamableHTTP.Plug, as: StreamableHTTPPlug
  alias SymphonyElixir.MCP.Handler

  @instructions """
                Symphony exposes one write tool that creates an execution-ready Backlog task. Supply the exact
                project_id you independently intend to modify. If it does not match, stop and verify the project;
                never guess, substitute, or retry with a project ID learned from the server.
                """
                |> String.replace("\n", " ")
                |> String.trim()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec dispatch(Plug.Conn.t(), GenServer.server()) :: Plug.Conn.t()
  def dispatch(conn, server \\ __MODULE__) do
    config = GenServer.call(server, :plug_config)
    StreamableHTTPPlug.call(conn, config)
  end

  @impl true
  def init(_opts) do
    config =
      StreamableHTTPPlug.init(
        server_mod: Handler,
        server_opts: [
          server_info: %{name: "symphony", version: application_version()},
          instructions: @instructions
        ],
        enable_json_response: true
      )

    {:ok, config}
  end

  @impl true
  def handle_call(:plug_config, _from, config), do: {:reply, config, config}

  defp application_version do
    case Application.spec(:symphony_elixir, :vsn) do
      nil -> "0.1.0"
      version -> to_string(version)
    end
  end
end
