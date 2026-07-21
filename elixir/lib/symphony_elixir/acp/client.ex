defmodule SymphonyElixir.ACP.Client do
  @moduledoc """
  Minimal Agent Client Protocol (ACP) JSON-RPC transport over stdio.

  Owns a port running an ACP agent command (e.g. `kimi acp`). stdout is
  reserved exclusively for JSON-RPC framing; the agent's stderr is redirected
  to a caller-supplied log file via shell redirection, never merged into
  stdout. All events are delivered to the subscriber process as plain
  messages:

    * `{:acp_response, ref, {:ok, result} | {:error, term()}}` — answer to `request_async/4`
    * `{:acp_notification, method, params, raw}` — agent notification
    * `{:acp_request, id, method, params, raw}` — agent-initiated request; answer with `respond/3` or `respond_error/4`
    * `{:acp_malformed, line}` — undecodable stdout line
    * `{:acp_exit, reason}` — the port exited, closed, or overflowed the frame cap
  """

  use GenServer

  require Logger

  @port_line_bytes 1_048_576
  @max_buffer_bytes 8 * 1_048_576

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {subscriber, opts} = Keyword.pop(opts, :subscriber, self())
    GenServer.start_link(__MODULE__, Keyword.put(opts, :subscriber, subscriber))
  end

  @spec request_async(pid(), String.t(), map(), timeout()) :: {:ok, reference()} | {:error, term()}
  def request_async(client, method, params, timeout \\ 30_000) do
    GenServer.call(client, {:request_async, method, params, timeout})
  end

  @spec notify(pid(), String.t(), map()) :: :ok
  def notify(client, method, params) do
    GenServer.cast(client, {:notify, method, params})
  end

  @spec respond(pid(), term(), term()) :: :ok
  def respond(client, id, result) do
    GenServer.cast(client, {:respond, id, %{"result" => result}})
  end

  @spec respond_error(pid(), term(), integer(), String.t()) :: :ok
  def respond_error(client, id, code, message) do
    GenServer.cast(client, {:respond, id, %{"error" => %{"code" => code, "message" => message}}})
  end

  @spec stop(pid()) :: :ok
  def stop(client) when is_pid(client) do
    if Process.alive?(client) do
      GenServer.stop(client, :normal, 5_000)
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    command = Keyword.fetch!(opts, :command)
    cwd = Keyword.fetch!(opts, :cwd)
    environment = Keyword.get(opts, :environment, %{})
    stderr_log = Keyword.get(opts, :stderr_log)
    subscriber = Keyword.fetch!(opts, :subscriber)

    case start_port(command, cwd, environment, stderr_log) do
      {:ok, port} ->
        Process.monitor(subscriber)

        {:ok,
         %{
           port: port,
           buffer: "",
           next_id: 1,
           pending: %{},
           subscriber: subscriber,
           stderr_log: stderr_log
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:request_async, method, params, timeout}, {caller, _tag}, state) do
    id = state.next_id
    ref = make_ref()
    payload = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    case send_payload(state.port, payload) do
      :ok ->
        timer =
          case timeout do
            :infinity -> nil
            timeout -> Process.send_after(self(), {:request_timeout, id, ref}, timeout)
          end

        entry = %{ref: ref, caller: caller, timer: timer, method: method}
        {:reply, {:ok, ref}, %{state | next_id: id + 1, pending: Map.put(state.pending, id, entry)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:notify, method, params}, state) do
    _ = send_payload(state.port, %{"jsonrpc" => "2.0", "method" => method, "params" => params})
    {:noreply, state}
  end

  def handle_cast({:respond, id, body}, state) do
    _ = send_payload(state.port, Map.merge(%{"jsonrpc" => "2.0", "id" => id}, body))
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    line = state.buffer <> chunk
    handle_line(line, %{state | buffer: ""})
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    buffer = state.buffer <> chunk

    if byte_size(buffer) > @max_buffer_bytes do
      Logger.error("acp frame exceeded #{@max_buffer_bytes} bytes; closing transport")
      deliver_exit(state, {:acp_message_too_large, byte_size(buffer)})
      {:stop, :normal, %{state | buffer: ""}}
    else
      {:noreply, %{state | buffer: buffer}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    deliver_exit(state, {:port_exit, status})
    {:stop, :normal, state}
  end

  def handle_info({port, :closed}, %{port: port} = state) do
    deliver_exit(state, :port_closed)
    {:stop, :normal, state}
  end

  def handle_info({:request_timeout, id, ref}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {entry, pending} ->
        send(entry.caller, {:acp_response, ref, {:error, :acp_request_timeout}})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{subscriber: pid} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Never strand a caller blocked on a prompt: a stopping transport must
    # explicitly fail every pending request and notify the subscriber.
    deliver_exit(state, :transport_stopped)
    close_port(state.port)
    :ok
  end

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"id" => id, "method" => method} = payload} when not is_nil(id) ->
        send(state.subscriber, {:acp_request, id, method, Map.get(payload, "params"), line})
        {:noreply, state}

      {:ok, %{"id" => id, "result" => result}} ->
        answer_pending(state, id, {:ok, result})

      {:ok, %{"id" => id, "error" => error}} ->
        answer_pending(state, id, {:error, {:acp_error, error}})

      {:ok, %{"method" => method} = payload} ->
        send(state.subscriber, {:acp_notification, method, Map.get(payload, "params"), line})
        {:noreply, state}

      {:ok, _other} ->
        send(state.subscriber, {:acp_malformed, line})
        {:noreply, state}

      {:error, _reason} ->
        send(state.subscriber, {:acp_malformed, line})
        {:noreply, state}
    end
  end

  defp answer_pending(state, id, result) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        Logger.debug("acp response for unknown id=#{inspect(id)}")
        {:noreply, state}

      {entry, pending} ->
        if entry.timer, do: Process.cancel_timer(entry.timer)
        send(entry.caller, {:acp_response, entry.ref, result})
        {:noreply, %{state | pending: pending}}
    end
  end

  defp deliver_exit(state, reason) do
    Enum.each(state.pending, fn {_id, entry} ->
      if entry.timer, do: Process.cancel_timer(entry.timer)
      send(entry.caller, {:acp_response, entry.ref, {:error, reason}})
    end)

    send(state.subscriber, {:acp_exit, reason})
  end

  defp start_port(command, cwd, environment, stderr_log) do
    bash = System.find_executable("bash")

    if is_nil(bash) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(bash)},
          [
            :binary,
            :exit_status,
            args: [~c"-lc", String.to_charlist(wrap_command(command, stderr_log))],
            cd: String.to_charlist(cwd),
            env: port_environment(environment),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  # stdout stays JSON-RPC-only: stderr goes to the log file, never the stream.
  defp wrap_command(command, nil), do: "exec #{command}"
  defp wrap_command(command, stderr_log), do: "exec #{command} 2>> #{shell_escape(stderr_log)}"

  defp shell_escape(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  defp port_environment(environment) do
    Enum.map(environment, fn {key, value} ->
      {String.to_charlist(key), String.to_charlist(value)}
    end)
  end

  defp send_payload(port, payload) do
    Port.command(port, Jason.encode!(payload) <> "\n")
    :ok
  rescue
    error -> {:error, {:acp_send_failed, Exception.message(error)}}
  end

  defp close_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
        rescue
          ArgumentError -> :ok
        end
    end
  end
end
