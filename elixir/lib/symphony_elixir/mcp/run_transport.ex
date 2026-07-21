defmodule SymphonyElixir.MCP.RunTransport do
  @moduledoc """
  Owns one `MCP.Transport.StreamableHTTP.Plug` configuration per active
  `{run_id, invocation}` scope.

  Each scope gets its own SDK session table, so an MCP session id minted under
  one scope can never resolve inside another. Scopes are registered before an
  agent session receives its MCP URL and unregistered — closing every
  associated MCP transport/server process — when the agent session ends.
  Registration and teardown are both idempotent.
  """

  use GenServer

  require Logger

  alias MCP.Transport.StreamableHTTP.Plug, as: StreamableHTTPPlug
  alias MCP.Transport.StreamableHTTP.Server, as: HTTPTransport
  alias SymphonyElixir.MCP.RunHandler

  @instructions """
                Symphony exposes run-scoped tools for the claimed task: task context, workpad read/write,
                acceptance completion, review attestation, task transition, follow-up task creation, and
                project jobs. Use them exactly as the stage prompt describes; transitions and completions
                are checked against the canonical board state.
                """
                |> String.replace("\n", " ")
                |> String.trim()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec register_scope(String.t(), pos_integer(), GenServer.server()) :: {:ok, :registered | :already_registered} | {:error, term()}
  def register_scope(run_id, invocation, server \\ __MODULE__)
      when is_binary(run_id) and is_integer(invocation) and invocation >= 1 do
    GenServer.call(server, {:register_scope, run_id, invocation})
  end

  @spec unregister_scope(String.t(), pos_integer(), GenServer.server()) :: :ok
  def unregister_scope(run_id, invocation, server \\ __MODULE__)
      when is_binary(run_id) and is_integer(invocation) and invocation >= 1 do
    GenServer.call(server, {:unregister_scope, run_id, invocation})
  end

  @spec unregister_run(String.t(), GenServer.server()) :: :ok
  def unregister_run(run_id, server \\ __MODULE__) when is_binary(run_id) do
    GenServer.call(server, {:unregister_run, run_id})
  end

  @spec fetch_config(String.t(), pos_integer(), GenServer.server()) :: {:ok, term()} | :error
  def fetch_config(run_id, invocation, server \\ __MODULE__)
      when is_binary(run_id) and is_integer(invocation) and invocation >= 1 do
    GenServer.call(server, {:fetch_config, run_id, invocation})
  end

  @doc false
  @spec scope_count(GenServer.server()) :: non_neg_integer()
  def scope_count(server \\ __MODULE__), do: GenServer.call(server, :scope_count)

  @impl true
  def init(_opts), do: {:ok, %{scopes: %{}}}

  @impl true
  def handle_call({:register_scope, run_id, invocation}, _from, state) do
    key = {run_id, invocation}

    if Map.has_key?(state.scopes, key) do
      {:reply, {:ok, :already_registered}, state}
    else
      case build_config(run_id, invocation) do
        {:ok, config} -> {:reply, {:ok, :registered}, %{state | scopes: Map.put(state.scopes, key, config)}}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:unregister_scope, run_id, invocation}, _from, state) do
    {config, scopes} = Map.pop(state.scopes, {run_id, invocation})
    if config, do: close_scope(config)
    {:reply, :ok, %{state | scopes: scopes}}
  end

  def handle_call({:unregister_run, run_id}, _from, state) do
    {matching, scopes} =
      Enum.split_with(state.scopes, fn {{scope_run_id, _invocation}, _config} -> scope_run_id == run_id end)

    Enum.each(matching, fn {_key, config} -> close_scope(config) end)
    {:reply, :ok, %{state | scopes: Map.new(scopes)}}
  end

  def handle_call({:fetch_config, run_id, invocation}, _from, state) do
    case Map.fetch(state.scopes, {run_id, invocation}) do
      {:ok, config} -> {:reply, {:ok, config}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call(:scope_count, _from, state), do: {:reply, map_size(state.scopes), state}

  # The ETS session table is created inside this GenServer so the registry
  # owns it for the scope's whole lifetime.
  defp build_config(run_id, invocation) do
    {:ok,
     StreamableHTTPPlug.init(
       server_mod: RunHandler,
       server_opts: [
         server_info: %{name: "symphony-run", version: application_version()},
         instructions: @instructions
       ],
       handler_opts: [run_id: run_id, invocation: invocation],
       enable_json_response: true
     )}
  rescue
    error -> {:error, {:run_scope_init_failed, Exception.message(error)}}
  end

  # Best-effort: one corrupted scope must never crash the registry and take
  # every other run's tool channel down with it.
  defp close_scope(config) do
    config.sessions
    |> :ets.tab2list()
    |> Enum.each(fn {_session_id, transport_pid} -> HTTPTransport.close(transport_pid) end)

    :ets.delete(config.sessions)
    :ok
  rescue
    error ->
      Logger.warning("run MCP scope cleanup failed: #{Exception.message(error)}")
      :ok
  end

  defp application_version do
    case Application.spec(:symphony_elixir, :vsn) do
      nil -> "0.1.0"
      version -> to_string(version)
    end
  end
end
