defmodule SymphonyElixir.Board.Lease do
  @moduledoc """
  Process-level project ownership lease.

  The lease is acquired with an exclusive file create. A same-host stale lease is
  reclaimed only after its recorded OS process is no longer alive.
  """

  use GenServer

  alias SymphonyElixir.Paths

  @lease_file "owner.json"

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
    owner = owner_envelope()

    case acquire(path, owner) do
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

  defp acquire(path, owner) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        result = IO.binwrite(io, Jason.encode!(owner, pretty: true))
        File.close(io)
        result

      {:error, :eexist} ->
        maybe_reclaim_stale(path, owner)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_reclaim_stale(path, owner) do
    existing = read_owner(path)

    if stale_local_owner?(existing) do
      backup = path <> ".stale-" <> Integer.to_string(System.system_time(:second))

      case File.rename(path, backup) do
        :ok -> acquire(path, owner)
        {:error, :enoent} -> acquire(path, owner)
        {:error, _reason} -> {:error, :already_exists}
      end
    else
      {:error, :already_exists}
    end
  end

  defp stale_local_owner?(%{"hostname" => hostname, "os_pid" => pid}) when is_integer(pid) do
    hostname == node_hostname() and not os_process_alive?(pid)
  end

  defp stale_local_owner?(_owner), do: false

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

  defp owner_envelope do
    %{
      "lease_id" => Ecto.UUID.generate(),
      "hostname" => node_hostname(),
      "os_pid" => System.pid() |> String.to_integer(),
      "beam_node" => Atom.to_string(node()),
      "started_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

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
