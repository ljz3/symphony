defmodule SymphonyElixir.Backend.CodexAppServer do
  @moduledoc """
  `AgentBackend` adapter for the Codex app-server JSON-RPC backend.

  This is a thin delegation layer over `SymphonyElixir.Codex.AppServer`; the
  session map, reconnection, dynamic-tool, and token-accounting behavior are
  unchanged. `cancel_turn/1` is a no-op because the codex interrupt path has
  always terminated the port directly.
  """

  @behaviour SymphonyElixir.AgentBackend

  alias SymphonyElixir.Board.Projection
  alias SymphonyElixir.Codex.{AppServer, RunStats}

  @impl true
  def start_session(workspace, opts) do
    case AppServer.start_session(workspace, opts) do
      {:ok, session} -> {:ok, Map.put(session, :backend, "codex")}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def prompt(session, prompt, task, opts) do
    case AppServer.run_turn(session, prompt, task, opts) do
      {:ok, result} ->
        {:ok,
         %{
           session: Map.fetch!(result, :session),
           stop_reason: :end_turn,
           turn_id: Map.get(result, :turn_id),
           meta: Map.take(result, [:result, :session_id, :thread_id, :effort, :model])
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def cancel_turn(_session), do: :ok

  @impl true
  def stop_session(session), do: AppServer.stop_session(session)

  @impl true
  def session_id(session), do: Map.get(session, :thread_id)

  @impl true
  def stats(run_id), do: RunStats.summary(Projection.run_telemetry(run_id))
end
