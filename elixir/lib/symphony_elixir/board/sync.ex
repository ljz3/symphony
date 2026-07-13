defmodule SymphonyElixir.Board.Sync do
  @moduledoc "Retries optional board-remote synchronization independently of local commits."

  use GenServer

  alias SymphonyElixir.Board.History
  alias SymphonyElixir.Workflow

  @initial_backoff_ms 1_000
  @max_backoff_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec status() :: map()
  def status do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, :status)
      _ -> %{state: :not_started, ahead: nil, behind: nil, error: :not_started}
    end
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "board:events")
    Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "board:workflow")
    send(self(), :sync)
    {:ok, %{status: %{state: :unknown}, backoff_ms: @initial_backoff_ms}}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_info({:board_event, _event}, state) do
    send(self(), :sync)
    {:noreply, state}
  end

  def handle_info({:workflow_activated, _hash}, state) do
    status = %{state: :unknown, ahead: nil, behind: nil, error: nil}
    broadcast(status)
    send(self(), :sync)
    {:noreply, %{state | status: status, backoff_ms: @initial_backoff_ms}}
  end

  def handle_info(:sync, state) do
    case Workflow.current() do
      {:ok, %{board: %{remote: nil}}} ->
        status = %{configured: false, state: :local_only, ahead: 0, behind: 0, error: nil}
        broadcast(status)
        {:noreply, %{state | status: status, backoff_ms: @initial_backoff_ms}}

      {:ok, bundle} ->
        status = History.sync_status(bundle.project.id, bundle.board.remote)

        cond do
          status.state == :diverged ->
            broadcast(status)
            {:noreply, %{state | status: status}}

          status.state in [:ahead, :error] ->
            push_and_schedule(bundle, status, state)

          true ->
            schedule(10_000)
            broadcast(status)
            {:noreply, %{state | status: status, backoff_ms: @initial_backoff_ms}}
        end

      {:error, reason} ->
        status = %{state: :error, error: reason, ahead: nil, behind: nil}
        schedule(state.backoff_ms)
        broadcast(status)
        {:noreply, %{state | status: status, backoff_ms: min(state.backoff_ms * 2, @max_backoff_ms)}}
    end
  end

  defp schedule(delay), do: Process.send_after(self(), :sync, delay)

  defp push_and_schedule(bundle, status, state) do
    case History.push(bundle.project.id, bundle.board.remote) do
      :ok ->
        schedule(@initial_backoff_ms)
        next = History.sync_status(bundle.project.id, bundle.board.remote)
        broadcast(next)
        {:noreply, %{state | status: next, backoff_ms: @initial_backoff_ms}}

      {:error, reason} ->
        failed = Map.merge(status, %{state: :error, error: reason})
        schedule(state.backoff_ms)
        broadcast(failed)
        next_backoff = min(state.backoff_ms * 2, @max_backoff_ms)
        {:noreply, %{state | status: failed, backoff_ms: next_backoff}}
    end
  end

  defp broadcast(status) do
    Phoenix.PubSub.broadcast(SymphonyElixir.PubSub, "board:sync", {:board_sync_changed, status})
    Phoenix.PubSub.broadcast(SymphonyElixir.PubSub, "board:health", :board_health_changed)
  end
end
