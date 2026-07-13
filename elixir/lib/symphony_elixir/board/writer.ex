defmodule SymphonyElixir.Board.Writer do
  @moduledoc """
  Serialized command writer that commits Git before updating the SQLite projection.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Board.{Checkpoint, Commands, Event, History, Lease, Projection, Sync, Validator}
  alias SymphonyElixir.Paths
  alias SymphonyElixir.Workflow

  defmodule State do
    @moduledoc false
    defstruct [:project_id, :head, :projection_error, :workflow_error]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec execute(term(), map(), non_neg_integer() | nil, String.t()) ::
          {:ok, map()} | {:error, term()}
  def execute(command, actor, expected_revision, idempotency_key) do
    GenServer.call(__MODULE__, {:execute, command, actor, expected_revision, idempotency_key}, :infinity)
  end

  @spec checkpoint() :: {:ok, map()} | {:error, term()}
  def checkpoint, do: GenServer.call(__MODULE__, :checkpoint, :infinity)

  @spec state() :: map()
  def state, do: GenServer.call(__MODULE__, :state)

  @spec reload_history() :: :ok | {:error, term()}
  def reload_history, do: GenServer.call(__MODULE__, :reload_history, :infinity)

  @impl true
  def init(_opts) do
    case Workflow.current() do
      {:ok, bundle} ->
        initialize_project(bundle.project.id, nil)

      {:error, workflow_error} ->
        case Workflow.project_identity() do
          {:ok, %{id: project_id}} -> initialize_project(project_id, workflow_error)
          {:error, reason} -> {:stop, {:workflow_identity_unavailable, workflow_error, reason}}
        end
    end
  end

  @impl true
  def handle_call({:execute, command, actor, expected_revision, key}, _from, state) do
    with :ok <- owner_check(),
         :ok <- idempotency_key(key),
         :miss <- Projection.idempotent_result(key),
         :ok <- divergence_gate(),
         {:ok, state} <- repair_projection(state),
         {:ok, bundle} <- Workflow.current(),
         :ok <- same_project(state, bundle),
         :ok <- expected_revision(command, expected_revision),
         {:ok, mutation} <- Validator.validate(command, actor, bundle),
         event <- build_event(state, bundle, mutation, actor, key),
         {:ok, committed} <- History.append(state.project_id, event, state.head),
         :ok <- Projection.apply(committed, mutation.result) do
      broadcast(committed)
      maybe_schedule_checkpoint(committed.sequence)
      {:reply, {:ok, mutation.result}, %{state | head: committed.git_oid, projection_error: nil, workflow_error: nil}}
    else
      {:ok, result} ->
        {:reply, {:ok, result}, state}

      {:error, {:projection_apply_failed, _sequence, _reason} = reason} ->
        new_head = projection_or_history_head(state)
        {:reply, {:error, reason}, %{state | head: new_head, projection_error: reason}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:checkpoint, _from, state) do
    case Checkpoint.create() do
      {:ok, checkpoint} -> {:reply, {:ok, checkpoint}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:state, _from, state) do
    workflow_error =
      case Workflow.current() do
        {:ok, _bundle} -> nil
        {:error, reason} -> reason
      end

    {:reply,
     %{
       project_id: state.project_id,
       head: state.head,
       projection_head: Projection.history_head(),
       last_sequence: Projection.last_sequence(),
       projection_error: state.projection_error,
       workflow_error: workflow_error,
       mutable:
         Lease.owner?() and is_nil(state.projection_error) and is_nil(workflow_error) and
           divergence_gate() == :ok
     }, state}
  end

  def handle_call(:reload_history, _from, state) do
    with {:ok, events} <- History.events(state.project_id),
         :ok <- Projection.rebuild(events) do
      head =
        case List.last(events) do
          nil -> nil
          event -> event.git_oid
        end

      {:reply, :ok, %{state | head: head, projection_error: nil}}
    else
      {:error, reason} -> {:reply, {:error, reason}, %{state | projection_error: reason}}
    end
  end

  defp build_event(state, bundle, mutation, actor, key) do
    Event.new(
      sequence: Projection.last_sequence() + 1,
      project_id: bundle.project.id,
      task_id: mutation.task_id,
      run_id: mutation.run_id,
      task_revision: mutation.task_revision,
      actor: actor,
      type: mutation.event_type,
      payload: mutation.payload,
      idempotency_key: key,
      command_id: Ecto.UUID.generate(),
      timestamp: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
    )
    |> then(fn event -> if state.head, do: event, else: event end)
  end

  defp expected_revision(%Commands.CreateTask{}, expected) do
    if expected in [nil, 0], do: :ok, else: {:error, {:unexpected_revision_for_create, expected}}
  end

  defp expected_revision(%_{} = command, expected) do
    check_task_revision(Map.get(command, :task_id), expected)
  end

  defp expected_revision(command, expected) when is_map(command) do
    check_task_revision(Map.get(command, :task_id) || Map.get(command, "task_id"), expected)
  end

  defp check_task_revision(nil, expected) do
    if expected in [nil, 0], do: :ok, else: {:error, {:unexpected_revision, expected}}
  end

  defp check_task_revision(task_id, expected) do
    if is_integer(expected) and expected >= 0 do
      case Projection.get_task(task_id) do
        {:ok, %{revision: ^expected}} -> :ok
        {:ok, task} -> {:error, {:stale_task_revision, task_id, expected, task.revision}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, {:expected_revision_required, task_id}}
    end
  end

  defp repair_projection(%State{projection_error: nil} = state), do: {:ok, state}

  defp repair_projection(state) do
    with {:ok, events} <- History.events(state.project_id),
         :ok <- Projection.replay(events) do
      head =
        case List.last(events) do
          nil -> nil
          event -> event.git_oid
        end

      {:ok, %{state | head: head, projection_error: nil}}
    end
  end

  defp initialize_project(project_id, workflow_error) do
    with :ok <- Paths.ensure_project_layout(project_id),
         {:ok, _repo} <- History.ensure_repo(project_id),
         {:ok, events} <- History.events(project_id),
         :ok <- synchronize_projection(events) do
      head =
        case List.last(events) do
          nil -> nil
          event -> event.git_oid
        end

      {:ok, %State{project_id: project_id, head: head, workflow_error: workflow_error}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp synchronize_projection(events) do
    if projection_matches_history?(events) do
      Projection.replay(events)
    else
      Projection.rebuild(events)
    end
  end

  defp projection_matches_history?(events) do
    sequence = Projection.last_sequence()

    cond do
      sequence > length(events) ->
        false

      sequence == 0 ->
        is_nil(Projection.history_head())

      true ->
        Enum.at(events, sequence - 1).git_oid == Projection.history_head()
    end
  rescue
    _error -> false
  end

  defp divergence_gate do
    remote =
      case Workflow.current() do
        {:ok, bundle} -> bundle.board.remote
        {:error, _reason} -> nil
      end

    remote_status_gate(remote, Sync.status())
  end

  defp remote_status_gate(nil, _status), do: :ok

  defp remote_status_gate(_remote, status) do
    case status do
      %{state: :diverged} -> {:error, :board_history_diverged}
      %{state: :behind} -> {:error, :board_history_behind}
      %{configured: false} -> {:error, :board_sync_pending}
      %{state: state} when state in [:unknown, :not_started] -> {:error, :board_sync_pending}
      _ -> :ok
    end
  end

  defp owner_check do
    if Lease.owner?(), do: :ok, else: {:error, :project_lease_not_owned}
  end

  defp idempotency_key(key) do
    if is_binary(key) and String.trim(key) != "", do: :ok, else: {:error, :invalid_idempotency_key}
  end

  defp same_project(state, bundle) do
    if state.project_id == bundle.project.id, do: :ok, else: {:error, :project_identity_changed}
  end

  defp broadcast(event) do
    messages = [
      {"board:events", {:board_event, event}},
      {"board:health", :board_health_changed}
    ]

    messages = if event.task_id, do: [{"board:tasks", {:task_changed, event.task_id}} | messages], else: messages
    messages = if event.run_id, do: [{"board:runs", {:run_changed, event.run_id}} | messages], else: messages

    Enum.each(messages, fn {topic, message} ->
      Phoenix.PubSub.broadcast(SymphonyElixir.PubSub, topic, message)
    end)
  rescue
    _error -> :ok
  end

  defp maybe_schedule_checkpoint(sequence) when rem(sequence, 100) == 0 do
    Task.start(fn -> checkpoint() end)
    :ok
  end

  defp maybe_schedule_checkpoint(_sequence), do: :ok

  defp projection_or_history_head(state) do
    case History.head(state.project_id) do
      {:ok, head} -> head
      _ -> state.head
    end
  end
end
