defmodule SymphonyElixir.MCP.RunHandler do
  @moduledoc """
  Run-scoped MCP tool surface for agent backends without a dynamic-tool
  channel (KimiACP).

  Every MCP session is bound at initialize time to one `{run_id, invocation}`
  scope via static handler opts. Tool execution delegates to
  `SymphonyElixir.Codex.DynamicTool`, so board semantics, idempotency, and
  the terminal-transition replay rule are identical to the codex
  dynamic-tool channel. Per-session request ids are namespaced with a random
  nonce so identical JSON-RPC ids from separate MCP sessions cannot collide
  in the board idempotency store.
  """

  @behaviour MCP.Server.Handler

  require Logger

  alias SymphonyElixir.{Board, Codex.DynamicTool}

  @impl true
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    invocation = Keyword.fetch!(opts, :invocation)

    {:ok, %{run_id: run_id, invocation: invocation, session_nonce: Ecto.UUID.generate()}}
  end

  @impl true
  def handle_list_tools(_cursor, state) do
    case Board.run(state.run_id) do
      {:ok, run} -> {:ok, DynamicTool.tool_specs(run), nil, state}
      {:error, _reason} -> {:ok, [], nil, state}
    end
  end

  @impl true
  def handle_call_tool(name, arguments, context, state) do
    call_id = "mcp:#{state.session_nonce}:#{context.request_id}"

    case Board.run(state.run_id) do
      {:ok, run} ->
        result =
          DynamicTool.execute(name, arguments || %{},
            task_id: run["task_id"],
            run_id: state.run_id,
            invocation: state.invocation,
            call_id: call_id
          )

        {:ok, [%{"type" => "text", "text" => result["output"]}], not result["success"], state}

      {:error, reason} ->
        Logger.warning("run-scoped MCP call rejected: run unavailable run_id=#{state.run_id} reason=#{inspect(reason)}")

        payload = Jason.encode!(%{"error" => %{"reason" => "run_unavailable"}}, pretty: true)
        {:ok, [%{"type" => "text", "text" => payload}], true, state}
    end
  end
end
