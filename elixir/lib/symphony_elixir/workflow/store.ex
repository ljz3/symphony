defmodule SymphonyElixir.Workflow.Store do
  @moduledoc """
  Keeps the active workflow bundle and defers valid reloads while agents are busy.

  Invalid candidate bundles are retained as health information without replacing
  the last known good active bundle.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Workflow
  alias SymphonyElixir.Workflow.Bundle

  @poll_interval_ms 1_000

  defmodule State do
    @moduledoc false
    defstruct [:path, :stamp, :active, :pending, :error]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec current() :: {:ok, Bundle.t()} | {:error, term()}
  def current do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, :current)
      _ -> Workflow.load()
    end
  end

  @spec status() :: map()
  def status do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, :status)
      _ -> %{valid: false, pending: false, error: :not_started}
    end
  end

  @spec force_reload() :: :ok | {:error, term()}
  def force_reload do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(pid, :force_reload)

      _ ->
        case Workflow.load() do
          {:ok, _bundle} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl true
  def init(_opts) do
    path = Workflow.workflow_file_path()
    state = %State{path: path}
    schedule_poll()

    case load_candidate(path, state) do
      {:ok, loaded} -> {:ok, activate_or_defer(loaded)}
      {:error, reason, failed} -> {:ok, %{failed | error: reason}}
    end
  end

  @impl true
  def handle_call(:current, _from, %State{active: %Bundle{} = active} = state) do
    {:reply, {:ok, active}, maybe_activate_pending(state)}
  end

  def handle_call(:current, _from, %State{error: error} = state) do
    {:reply, {:error, error || :workflow_unavailable}, maybe_activate_pending(state)}
  end

  def handle_call(:status, _from, state) do
    reply = %{
      valid: is_struct(state.active, Bundle),
      active_hash: state.active && state.active.hash,
      pending: is_struct(state.pending, Bundle),
      pending_hash: state.pending && state.pending.hash,
      error: state.error,
      path: state.path
    }

    {:reply, reply, state}
  end

  def handle_call(:force_reload, _from, state) do
    case load_candidate(Workflow.workflow_file_path(), state) do
      {:ok, loaded} -> {:reply, :ok, activate_or_defer(loaded)}
      {:error, reason, failed} -> {:reply, {:error, reason}, %{failed | error: reason}}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    schedule_poll()

    state = maybe_activate_pending(state)
    path = Workflow.workflow_file_path()

    case current_stamp(path) do
      {:ok, stamp} when path == state.path and stamp == state.stamp ->
        {:noreply, state}

      {:ok, _stamp} ->
        case load_candidate(path, state) do
          {:ok, loaded} -> {:noreply, activate_or_defer(loaded)}
          {:error, reason, failed} -> {:noreply, %{failed | error: reason}}
        end

      {:error, reason} ->
        {:noreply, %{state | error: {:workflow_stat_failed, path, reason}}}
    end
  end

  defp load_candidate(path, state) do
    with {:ok, bundle} <- Workflow.load(path),
         :ok <- immutable_project(state.active, bundle),
         :ok <- retained_columns(state.active, bundle),
         {:ok, stamp} <- current_stamp(path) do
      {:ok, %{state | path: path, stamp: stamp, pending: bundle, error: nil}}
    else
      {:error, reason} ->
        Logger.error("workflow bundle rejected path=#{path} reason=#{inspect(reason)}")
        {:error, reason, %{state | path: path}}
    end
  end

  defp activate_or_defer(%State{pending: nil} = state), do: state

  defp activate_or_defer(%State{pending: pending} = state) do
    if runtime_busy?() do
      state
    else
      activate(%{state | pending: nil}, pending)
    end
  end

  defp maybe_activate_pending(%State{pending: nil} = state), do: state
  defp maybe_activate_pending(state), do: activate_or_defer(state)

  defp activate(state, bundle) do
    previous = state.active
    Elixir.Task.start(fn -> notify_policy_change(previous, bundle) end)
    Phoenix.PubSub.broadcast(SymphonyElixir.PubSub, "board:workflow", {:workflow_activated, bundle.hash})
    %{state | active: bundle, error: nil}
  rescue
    _error -> %{state | active: bundle, error: nil}
  end

  defp immutable_project(nil, _candidate), do: :ok

  defp immutable_project(%Bundle{project: project}, %Bundle{project: project}), do: :ok

  defp immutable_project(%Bundle{project: current}, %Bundle{project: candidate}) do
    {:error, {:immutable_project_identity_changed, current, candidate}}
  end

  defp retained_columns(nil, _candidate), do: :ok

  defp retained_columns(_active, candidate) do
    if Code.ensure_loaded?(SymphonyElixir.Board) and function_exported?(SymphonyElixir.Board, :live_column_ids, 0) do
      candidate_ids = MapSet.new(candidate.columns, & &1.id)
      removed = SymphonyElixir.Board.live_column_ids() |> Enum.reject(&MapSet.member?(candidate_ids, &1))
      if removed == [], do: :ok, else: {:error, {:live_columns_removed, removed}}
    else
      :ok
    end
  end

  defp runtime_busy? do
    Code.ensure_loaded?(SymphonyElixir.Board) and
      function_exported?(SymphonyElixir.Board, :busy?, 0) and
      SymphonyElixir.Board.busy?()
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end

  defp notify_policy_change(nil, _bundle), do: :ok

  defp notify_policy_change(previous, bundle) do
    if Code.ensure_loaded?(SymphonyElixir.Board) and
         function_exported?(SymphonyElixir.Board, :workflow_activated, 2) do
      SymphonyElixir.Board.workflow_activated(previous, bundle)
    end

    :ok
  end

  defp current_stamp(path) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         {:ok, content} <- File.read(path) do
      {:ok, {stat.mtime, stat.size, :erlang.phash2(content)}}
    end
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval_ms)
end
