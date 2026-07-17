defmodule SymphonyElixir.ManagedCommand do
  @moduledoc """
  Runs a shell command without a productive-work deadline while owning its process tree.

  Normal execution waits indefinitely for the command's natural exit. Only explicit
  cancellation, owner loss, or caller loss starts TERM followed by bounded KILL
  escalation. Cancellation does not return until the owned process group is gone.
  """

  alias SymphonyElixir.ManagedCommand.Worker

  @type worker_host :: String.t() | nil
  @type command_result :: {:ok, {binary(), non_neg_integer()}} | {:error, term()}

  @spec run(String.t(), Path.t(), [{String.t(), String.t()}], worker_host(), keyword()) :: command_result()
  def run(command, directory, environment, worker_host \\ nil, opts \\ [])
      when is_binary(command) and is_binary(directory) and is_list(environment) and is_list(opts) do
    ref = make_ref()
    owner = Keyword.get(opts, :owner, self())
    cancellation_message = Keyword.get(opts, :cancellation_message)
    cancellation_reason = Keyword.get(opts, :cancellation_reason, :managed_command_cancelled)

    worker_opts = [
      caller: self(),
      owner: owner,
      ref: ref,
      command: command,
      directory: directory,
      environment: environment,
      worker_host: worker_host
    ]

    with {:ok, worker} <- Worker.start(worker_opts) do
      monitor = Process.monitor(worker)
      await(worker, monitor, ref, cancellation_message, cancellation_reason)
    end
  end

  defp await(worker, monitor, ref, cancellation_message, cancellation_reason) do
    receive do
      {:managed_command_result, ^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        {:error, {:managed_command_worker_exit, reason}}

      message when not is_nil(cancellation_message) and message == cancellation_message ->
        Worker.cancel(worker, cancellation_reason)
        await(worker, monitor, ref, nil, cancellation_reason)
    end
  end

  defmodule Worker do
    @moduledoc false

    use GenServer

    alias SymphonyElixir.SSH

    @cancel_escalation_ms 1_000
    @death_check_ms 25
    @wrapper """
    set -m
    /bin/bash -lc "$2" &
    child=$!
    printf '__SYMPHONY_MANAGED_COMMAND_%s__%s\n' "$1" "$child"
    set +m
    wait "$child"
    exit $?
    """

    @spec start(keyword()) :: GenServer.on_start()
    def start(opts), do: GenServer.start(__MODULE__, opts)

    @spec cancel(pid(), term()) :: :ok
    def cancel(worker, reason) when is_pid(worker) do
      GenServer.cast(worker, {:cancel, reason})
    end

    @impl true
    def init(opts) do
      caller = Keyword.fetch!(opts, :caller)
      owner = Keyword.fetch!(opts, :owner)
      token = Ecto.UUID.generate()

      state = %{
        caller: caller,
        caller_ref: Process.monitor(caller),
        owner: owner,
        owner_ref: Process.monitor(owner),
        ref: Keyword.fetch!(opts, :ref),
        command: Keyword.fetch!(opts, :command),
        directory: Keyword.fetch!(opts, :directory),
        environment: Keyword.fetch!(opts, :environment),
        worker_host: Keyword.fetch!(opts, :worker_host),
        token: token,
        marker: "__SYMPHONY_MANAGED_COMMAND_#{token}__",
        port: nil,
        transport_pid: nil,
        pgid: nil,
        control_buffer: <<>>,
        output: [],
        cancel_reason: nil,
        escalation_timer: nil,
        death_check_timer: nil,
        kill_sent: false,
        terminal_sent: false
      }

      {:ok, state, {:continue, :start}}
    end

    @impl true
    def handle_continue(:start, state) do
      case open_port(state) do
        {:ok, port} -> {:noreply, attach_port(state, port)}
        {:error, reason} -> finish(state, {:error, reason})
      end
    end

    @impl true
    def handle_cast({:cancel, reason}, state) do
      {:noreply, begin_cancellation(state, reason)}
    end

    @impl true
    def handle_info({port, {:data, data}}, %{port: port} = state) do
      state = consume_output(state, data)
      {:noreply, maybe_signal_after_identity(state)}
    end

    def handle_info(
          {port, {:exit_status, 255}},
          %{port: port, cancel_reason: nil, pgid: nil, worker_host: worker_host} = state
        )
        when is_binary(worker_host) do
      finish(state, {:error, {:ssh_transport_failed, 255, state.control_buffer}})
    end

    def handle_info({port, {:exit_status, status}}, %{port: port, cancel_reason: nil} = state) do
      case state.pgid do
        nil -> finish(state, {:error, :managed_command_identity_missing})
        _pgid -> finish(state, {:ok, {command_output(state), status}})
      end
    end

    def handle_info({port, {:exit_status, _status}}, %{port: port} = state) do
      maybe_finish_cancellation(%{state | port: nil})
    end

    def handle_info({port, :closed}, %{port: port, cancel_reason: nil} = state) do
      finish(%{state | port: nil}, {:error, :managed_command_port_closed})
    end

    def handle_info({port, :closed}, %{port: port} = state) do
      maybe_finish_cancellation(%{state | port: nil})
    end

    def handle_info({:DOWN, ref, :process, _pid, _reason}, %{caller_ref: ref} = state) do
      {:noreply, begin_cancellation(state, :managed_command_caller_down)}
    end

    def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
      {:noreply, begin_cancellation(state, :preflight_owner_down)}
    end

    def handle_info(:escalate_cancellation, state) do
      state =
        state
        |> Map.put(:escalation_timer, nil)
        |> Map.put(:kill_sent, true)
        |> signal_group("KILL")
        |> signal_transport("KILL")

      maybe_finish_cancellation(state)
    end

    def handle_info(:check_process_death, state) do
      state = %{state | death_check_timer: nil}
      maybe_finish_cancellation(state)
    end

    def handle_info(_message, state), do: {:noreply, state}

    @impl true
    def terminate(_reason, state) do
      cancel_timer(state.escalation_timer)
      cancel_timer(state.death_check_timer)

      if state.cancel_reason && state.pgid do
        _ = signal_group_sync(state.pgid, "KILL", state.worker_host)
      end

      close_port(state.port)
      :ok
    end

    defp open_port(%{worker_host: nil} = state) do
      case System.find_executable("bash") do
        nil ->
          {:error, :bash_not_found}

        bash ->
          options = [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args:
              Enum.map(
                ["-c", @wrapper, "symphony-managed-command", state.token, state.command],
                &String.to_charlist/1
              ),
            cd: String.to_charlist(state.directory),
            env: Enum.map(state.environment, &port_env/1)
          ]

          {:ok, Port.open({:spawn_executable, String.to_charlist(bash)}, options)}
      end
    rescue
      error -> {:error, {:managed_command_start_failed, Exception.message(error)}}
    end

    defp open_port(state) do
      exports =
        state.environment
        |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{shell_escape(value)}" end)

      command =
        "cd #{shell_escape(state.directory)} && env #{exports} /bin/bash -c " <>
          shell_escape(@wrapper) <>
          " symphony-managed-command #{shell_escape(state.token)} #{shell_escape(state.command)}"

      SSH.start_port(state.worker_host, command)
    end

    defp attach_port(state, port) do
      {:os_pid, transport_pid} = Port.info(port, :os_pid)
      %{state | port: port, transport_pid: transport_pid}
    end

    defp consume_output(%{pgid: nil} = state, data) do
      buffer = state.control_buffer <> data

      case extract_identity(buffer, state.marker) do
        {:ok, pgid, output} -> %{state | pgid: pgid, control_buffer: <<>>, output: [output]}
        :pending -> %{state | control_buffer: buffer}
        :invalid -> begin_cancellation(state, :managed_command_identity_invalid)
      end
    end

    defp consume_output(state, data), do: %{state | output: [data | state.output]}

    defp extract_identity(buffer, marker) do
      case :binary.match(buffer, marker) do
        :nomatch ->
          :pending

        {marker_start, marker_size} ->
          identity_start = marker_start + marker_size
          remainder = binary_part(buffer, identity_start, byte_size(buffer) - identity_start)
          extract_identity_line(buffer, remainder, marker_start, identity_start)
      end
    end

    defp extract_identity_line(buffer, remainder, marker_start, identity_start) do
      case :binary.match(remainder, "\n") do
        :nomatch -> :pending
        {newline_start, 1} -> parse_identity(buffer, remainder, marker_start, identity_start, newline_start)
      end
    end

    defp parse_identity(buffer, remainder, marker_start, identity_start, newline_start) do
      identity = binary_part(remainder, 0, newline_start) |> String.trim()

      case Integer.parse(identity) do
        {pgid, ""} when pgid > 0 ->
          before = binary_part(buffer, 0, marker_start)
          after_start = identity_start + newline_start + 1
          after_identity = binary_part(buffer, after_start, byte_size(buffer) - after_start)
          {:ok, pgid, before <> after_identity}

        _ ->
          :invalid
      end
    end

    defp maybe_signal_after_identity(%{cancel_reason: nil} = state), do: state
    defp maybe_signal_after_identity(%{pgid: nil} = state), do: state
    defp maybe_signal_after_identity(state), do: signal_group(state, if(state.kill_sent, do: "KILL", else: "TERM"))

    defp begin_cancellation(%{cancel_reason: nil} = state, reason) do
      timer = Process.send_after(self(), :escalate_cancellation, @cancel_escalation_ms)

      state
      |> Map.put(:cancel_reason, reason)
      |> Map.put(:escalation_timer, timer)
      |> signal_group("TERM")
    end

    defp begin_cancellation(state, _reason), do: state

    defp maybe_finish_cancellation(%{pgid: nil, port: nil} = state), do: finish(state, {:error, state.cancel_reason})

    defp maybe_finish_cancellation(state) do
      case process_group_alive?(state) do
        false ->
          finish(state, {:error, state.cancel_reason})

        true ->
          {:noreply, schedule_death_check(state)}

        :unknown ->
          {:noreply, schedule_death_check(state)}
      end
    end

    defp schedule_death_check(%{death_check_timer: nil} = state) do
      timer = Process.send_after(self(), :check_process_death, @death_check_ms)
      %{state | death_check_timer: timer}
    end

    defp schedule_death_check(state), do: state

    defp signal_group(%{pgid: nil} = state, _signal), do: state

    defp signal_group(state, signal) do
      pgid = state.pgid
      worker_host = state.worker_host
      _ = Task.start(fn -> signal_group_sync(pgid, signal, worker_host) end)
      state
    end

    defp signal_group_sync(pgid, signal, nil) do
      case System.find_executable("kill") do
        nil -> {:error, :kill_not_found}
        kill -> System.cmd(kill, ["-#{signal}", "--", "-#{pgid}"], stderr_to_stdout: true)
      end
    end

    defp signal_group_sync(pgid, signal, worker_host) do
      SSH.run(worker_host, "kill -#{signal} -- -#{pgid}")
    end

    defp signal_transport(%{transport_pid: nil} = state, _signal), do: state

    defp signal_transport(state, signal) do
      _ = signal_process(state.transport_pid, signal)
      state
    end

    defp signal_process(pid, signal) do
      case System.find_executable("kill") do
        nil -> {:error, :kill_not_found}
        kill -> System.cmd(kill, ["-#{signal}", "--", Integer.to_string(pid)], stderr_to_stdout: true)
      end
    end

    defp process_group_alive?(%{pgid: nil}), do: false

    defp process_group_alive?(%{pgid: pgid, worker_host: nil}) do
      case System.find_executable("kill") do
        nil -> :unknown
        kill -> match?({_output, 0}, System.cmd(kill, ["-0", "--", "-#{pgid}"], stderr_to_stdout: true))
      end
    rescue
      _error -> :unknown
    end

    defp process_group_alive?(%{pgid: pgid, worker_host: worker_host}) do
      case SSH.run(worker_host, "kill -0 -- -#{pgid}") do
        {:ok, {_output, 0}} -> true
        {:ok, {_output, _status}} -> false
        {:error, _reason} -> :unknown
      end
    end

    defp command_output(state) do
      state.output
      |> Enum.reverse()
      |> IO.iodata_to_binary()
    end

    defp finish(state, result) do
      cancel_timer(state.escalation_timer)
      cancel_timer(state.death_check_timer)
      close_port(state.port)

      unless state.terminal_sent do
        send(state.caller, {:managed_command_result, state.ref, result})
      end

      {:stop, :normal, %{state | terminal_sent: true, port: nil}}
    end

    defp cancel_timer(reference) when is_reference(reference), do: Process.cancel_timer(reference)
    defp cancel_timer(_reference), do: :ok

    defp close_port(port) when is_port(port) do
      if Port.info(port), do: Port.close(port)
      :ok
    end

    defp close_port(_port), do: :ok

    defp port_env({key, value}), do: {String.to_charlist(key), String.to_charlist(value)}
    defp shell_escape(value), do: "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
