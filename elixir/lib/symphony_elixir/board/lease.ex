defmodule SymphonyElixir.Board.Lease do
  @moduledoc """
  Process-level project ownership lease.

  The lease is acquired with an exclusive file create. A stale lease from the same
  machine is reclaimed only after its recorded OS process is no longer alive.
  """

  use GenServer

  alias SymphonyElixir.Paths

  @lease_file "owner.json"
  @linux_machine_id_paths ["/etc/machine-id", "/var/lib/dbus/machine-id"]

  defmodule State do
    @moduledoc false
    defstruct [:project_id, :path, :owner, owned: false]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec owner?() :: boolean()
  def owner? do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, :owner?)
      _ -> false
    end
  end

  @spec status() :: map()
  def status do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, :status)
      _ -> %{owned: false, owner: nil, error: :not_started}
    end
  end

  @impl true
  def init(opts) do
    project_id = Keyword.get_lazy(opts, :project_id, &current_project_id/0)
    path = Keyword.get(opts, :path, Path.join(Paths.lease_root(project_id), @lease_file))
    :ok = File.mkdir_p(Path.dirname(path))
    owner = owner_envelope(opts)
    process_alive? = Keyword.get(opts, :process_alive?, &os_process_alive?/1)

    case acquire(path, owner, process_alive?) do
      :ok ->
        {:ok, %State{project_id: project_id, path: path, owner: owner, owned: true}}

      {:error, :already_exists} ->
        existing = read_owner(path)
        {:ok, %State{project_id: project_id, path: path, owner: existing, owned: false}}

      {:error, reason} ->
        {:stop, {:lease_acquire_failed, path, reason}}
    end
  end

  @impl true
  def handle_call(:owner?, _from, state), do: {:reply, state.owned, state}

  def handle_call(:status, _from, state) do
    {:reply, %{owned: state.owned, owner: state.owner, path: state.path}, state}
  end

  @impl true
  def terminate(_reason, %State{owned: true, path: path, owner: owner}) do
    expected_lease_id = owner["lease_id"]

    case read_owner(path) do
      %{"lease_id" => lease_id} when lease_id == expected_lease_id -> File.rm(path)
      _ -> :ok
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp acquire(path, owner, process_alive?) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        result = IO.binwrite(io, Jason.encode!(owner, pretty: true))
        File.close(io)
        result

      {:error, :eexist} ->
        maybe_reclaim_stale(path, owner, process_alive?)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_reclaim_stale(path, owner, process_alive?) do
    existing = read_owner(path)

    if stale_local_owner?(existing, owner, process_alive?) do
      backup = path <> ".stale-" <> Integer.to_string(System.system_time(:second))

      case File.rename(path, backup) do
        :ok -> acquire(path, owner, process_alive?)
        {:error, :enoent} -> acquire(path, owner, process_alive?)
        {:error, _reason} -> {:error, :already_exists}
      end
    else
      {:error, :already_exists}
    end
  end

  defp stale_local_owner?(%{"os_pid" => pid} = existing, owner, process_alive?)
       when is_integer(pid) and is_function(process_alive?, 1) do
    same_machine?(existing, owner) and not process_alive?.(pid)
  end

  defp stale_local_owner?(_existing, _owner, _process_alive?), do: false

  defp same_machine?(%{"machine_id" => existing}, %{"machine_id" => current})
       when is_binary(existing) and existing != "" and is_binary(current) and current != "" do
    existing == current
  end

  defp same_machine?(%{"hostname" => existing}, %{"hostname" => current})
       when is_binary(existing) and is_binary(current) do
    existing == current
  end

  defp same_machine?(_existing, _current), do: false

  defp os_process_alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  rescue
    _error -> true
  end

  defp read_owner(path) do
    with {:ok, json} <- File.read(path),
         {:ok, owner} <- Jason.decode(json) do
      owner
    else
      _ -> nil
    end
  end

  defp owner_envelope(opts) do
    hostname = Keyword.get_lazy(opts, :hostname, &node_hostname/0)
    os_pid = Keyword.get_lazy(opts, :os_pid, fn -> System.pid() |> String.to_integer() end)
    machine_id = Keyword.get_lazy(opts, :machine_id, &machine_id/0)

    %{
      "lease_id" => Ecto.UUID.generate(),
      "hostname" => hostname,
      "os_pid" => os_pid,
      "beam_node" => Atom.to_string(node()),
      "started_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
    |> maybe_put_machine_id(machine_id)
  end

  defp maybe_put_machine_id(owner, machine_id) when is_binary(machine_id) and machine_id != "",
    do: Map.put(owner, "machine_id", machine_id)

  defp maybe_put_machine_id(owner, _machine_id), do: owner

  defp machine_id do
    case :os.type() do
      {:unix, :darwin} -> darwin_machine_id()
      {:unix, _name} -> linux_machine_id()
      _other -> nil
    end
    |> machine_id_fingerprint()
  end

  defp darwin_machine_id do
    with {output, 0} <-
           System.cmd("ioreg", ["-rd1", "-c", "IOPlatformExpertDevice"], stderr_to_stdout: true),
         [_, machine_id] <- Regex.run(~r/"IOPlatformUUID"\s*=\s*"([^"]+)"/, output) do
      machine_id
    else
      _ -> nil
    end
  rescue
    _error -> nil
  end

  defp linux_machine_id do
    Enum.find_value(@linux_machine_id_paths, fn path ->
      case File.read(path) do
        {:ok, machine_id} -> nonempty_string(machine_id)
        {:error, _reason} -> nil
      end
    end)
  end

  defp machine_id_fingerprint(machine_id) do
    case nonempty_string(machine_id) do
      nil ->
        nil

      machine_id ->
        :sha256
        |> :crypto.hash("symphony-machine:" <> String.downcase(machine_id))
        |> Base.encode16(case: :lower)
    end
  end

  defp nonempty_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp nonempty_string(_value), do: nil

  defp node_hostname do
    {:ok, hostname} = :inet.gethostname()
    List.to_string(hostname)
  catch
    _kind, _reason -> "unknown"
  end

  defp current_project_id do
    case SymphonyElixir.Workflow.project_identity() do
      {:ok, %{id: id}} -> id
      _ -> "unconfigured"
    end
  end
end
