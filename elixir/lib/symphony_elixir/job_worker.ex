defmodule SymphonyElixir.JobWorker do
  @moduledoc false

  use GenServer

  alias SymphonyElixir.SSH

  @cancel_escalation_ms 5_000
  @wrapper """
  set -m
  "$@" > "$SYMPHONY_JOB_STDOUT" 2> "$SYMPHONY_JOB_STDERR" &
  child=$!
  printf 'child:%s\\n' "$child"
  wait "$child"
  exit $?
  """
  @remote_wrapper """
  set -e
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    export "$1"
    shift
  done
  [ "$#" -gt 0 ] || exit 125
  shift
  set -m
  "$@" > "$SYMPHONY_JOB_STDOUT" 2> "$SYMPHONY_JOB_STDERR" &
  child=$!
  printf 'child:%s\n' "$child"
  wait "$child"
  exit $?
  """

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec cancel(pid()) :: :ok
  def cancel(pid) when is_pid(pid) do
    GenServer.cast(pid, :cancel)
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :request).record["job_id"]},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @impl true
  def init(opts) do
    manager = Keyword.fetch!(opts, :manager)
    request = Keyword.fetch!(opts, :request)

    state = %{
      manager: manager,
      manager_ref: Process.monitor(manager),
      record: request.record,
      executable: request.executable,
      argv: request.argv,
      environment: request.environment,
      workspace: request.workspace,
      worker_host: request.worker_host,
      port: nil,
      transport_pid: nil,
      child_pgid: nil,
      cancel_requested: false,
      escalation_timer: nil,
      terminal_sent: false
    }

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, %{worker_host: nil} = state) do
    case open_local_port(state) do
      {:ok, port} -> {:noreply, attach_port(state, port)}
      {:error, reason} -> stop_with_terminal(state, "interrupted", nil, reason)
    end
  end

  def handle_continue(:start, state) do
    case open_remote_port(state) do
      {:ok, port} -> {:noreply, attach_port(state, port)}
      {:error, reason} -> stop_with_terminal(state, "interrupted", nil, reason)
    end
  end

  @impl true
  def handle_cast(:cancel, state) do
    {:noreply, request_cancel(state)}
  end

  @impl true
  def handle_info({port, {:data, {:eol, data}}}, %{port: port} = state) do
    {:noreply, handle_control_line(to_string(data), state)}
  end

  def handle_info({port, {:data, {:noeol, data}}}, %{port: port} = state) do
    {:noreply, handle_control_line(to_string(data), state)}
  end

  def handle_info({port, {:exit_status, exit_code}}, %{port: port} = state) do
    case fetch_remote_artifacts(state) do
      :ok ->
        status =
          cond do
            state.cancel_requested -> "cancelled"
            exit_code == 0 -> "completed"
            true -> "failed"
          end

        stop_with_terminal(state, status, exit_code, nil)

      {:error, reason} ->
        stop_with_terminal(state, "interrupted", exit_code, reason)
    end
  end

  def handle_info({:escalate_cancel, job_id}, %{record: %{"job_id" => job_id}} = state) do
    state =
      state
      |> Map.put(:escalation_timer, nil)
      |> signal_group_async("KILL")
      |> signal_transport("KILL")

    stop_with_terminal(state, "cancelled", nil, :cancel_escalated)
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{manager_ref: ref} = state) do
    state = request_cancel(state)
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_reference(state.escalation_timer), do: Process.cancel_timer(state.escalation_timer)

    if is_port(state.port) and Port.info(state.port) do
      unless state.terminal_sent do
        _ =
          state
          |> Map.put(:cancel_requested, true)
          |> signal_group_async("KILL")
          |> signal_transport("KILL")
      end

      close_port(state.port)
    end

    :ok
  end

  defp open_local_port(state) do
    case System.find_executable("bash") do
      nil ->
        {:error, :bash_not_found}

      bash ->
        options = [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: Enum.map(["-c", @wrapper, "symphony-job", state.executable | state.argv], &String.to_charlist/1),
          cd: String.to_charlist(state.workspace),
          env: Enum.map(state.environment, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end),
          line: 4_096
        ]

        {:ok, Port.open({:spawn_executable, String.to_charlist(bash)}, options)}
    end
  rescue
    error -> {:error, {:job_port_open_failed, Exception.message(error)}}
  end

  defp open_remote_port(state) do
    remote_root = remote_artifact_root(state)
    remote_stdout = Path.join(remote_root, "stdout")
    remote_stderr = Path.join(remote_root, "stderr")

    environment =
      state.environment
      |> Map.put("SYMPHONY_JOB_STDOUT", remote_stdout)
      |> Map.put("SYMPHONY_JOB_STDERR", remote_stderr)

    environment_arguments =
      environment
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)

    command =
      [
        "mkdir -p #{shell_escape(remote_root)}",
        "chmod 700 #{shell_escape(remote_root)}",
        "> #{shell_escape(remote_stdout)}",
        "> #{shell_escape(remote_stderr)}",
        "cd #{shell_escape(state.workspace)}",
        "/bin/bash -c #{shell_escape(@remote_wrapper)} symphony-job " <>
          shell_join(environment_arguments ++ ["--", state.executable | state.argv])
      ]
      |> Enum.join(" && ")

    SSH.start_port(state.worker_host, command, line: 4_096)
  end

  defp handle_control_line("child:" <> pid, state) do
    case Integer.parse(String.trim(pid)) do
      {pgid, ""} when pgid > 0 ->
        state = %{state | child_pgid: pgid}
        if state.cancel_requested, do: signal_group_async(state, "TERM"), else: state

      _ ->
        state
    end
  end

  defp handle_control_line(_line, state), do: state

  defp request_cancel(state) do
    state
    |> Map.put(:cancel_requested, true)
    |> schedule_escalation()
    |> signal_group_async("TERM")
  end

  defp schedule_escalation(%{escalation_timer: nil} = state) do
    timer = Process.send_after(self(), {:escalate_cancel, state.record["job_id"]}, @cancel_escalation_ms)
    %{state | escalation_timer: timer}
  end

  defp schedule_escalation(state), do: state

  defp signal_group_async(%{child_pgid: nil} = state, _signal), do: state

  defp signal_group_async(state, signal) do
    pgid = state.child_pgid
    worker_host = state.worker_host
    _ = Task.start(fn -> signal_process_group(pgid, signal, worker_host) end)
    state
  end

  defp signal_transport(%{transport_pid: nil} = state, _signal), do: state

  defp signal_transport(state, signal) do
    _ = signal_process(state.transport_pid, signal)
    state
  end

  defp signal_process_group(pgid, signal, nil) do
    case System.find_executable("kill") do
      nil -> {:error, :kill_not_found}
      kill -> System.cmd(kill, ["-#{signal}", "--", "-#{pgid}"], stderr_to_stdout: true)
    end
  end

  defp signal_process_group(pgid, signal, worker_host) do
    SSH.run(worker_host, "kill -#{signal} -- -#{pgid}")
  end

  defp signal_process(pid, signal) do
    kill = if File.exists?("/bin/kill"), do: "/bin/kill", else: System.find_executable("kill")

    case kill do
      nil -> {:error, :kill_not_found}
      kill -> System.cmd(kill, ["-#{signal}", "--", to_string(pid)], stderr_to_stdout: true)
    end
  end

  defp attach_port(state, port) do
    transport_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    %{state | port: port, transport_pid: transport_pid}
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp fetch_remote_artifacts(%{worker_host: nil}), do: :ok

  defp fetch_remote_artifacts(state) do
    remote_root = remote_artifact_root(state)

    with {:ok, stdout} <- read_remote_artifact(state.worker_host, Path.join(remote_root, "stdout")),
         {:ok, stderr} <- read_remote_artifact(state.worker_host, Path.join(remote_root, "stderr")),
         :ok <- File.write(state.record["stdout_path"], stdout, [:binary]),
         :ok <- File.write(state.record["stderr_artifact"], stderr, [:binary]) do
      :ok
    else
      {:error, reason} -> {:error, {:remote_job_artifact_failed, state.worker_host, reason}}
    end
  end

  defp read_remote_artifact(worker_host, path) do
    case SSH.run(worker_host, "base64 < #{shell_escape(path)}", stderr_to_stdout: true) do
      {:ok, {encoded, 0}} ->
        encoded
        |> String.replace(~r/\s+/, "")
        |> Base.decode64()

      {:ok, {output, exit_code}} ->
        {:error, {:remote_artifact_read_failed, path, exit_code, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remote_artifact_root(state) do
    Path.join("/tmp/symphony-project-jobs", state.record["job_id"])
  end

  defp shell_join(arguments), do: Enum.map_join(arguments, " ", &shell_escape/1)

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end

  defp stop_with_terminal(state, status, exit_code, reason) do
    unless state.terminal_sent do
      send(state.manager, {:job_terminal, state.record["job_id"], status, exit_code, reason})
    end

    {:stop, :normal, %{state | terminal_sent: true}}
  end
end
