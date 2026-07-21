defmodule SymphonyElixir.Board do
  @moduledoc """
  Public command/query boundary for Symphony's local Git-backed Kanban board.
  """

  alias SymphonyElixir.Board.{
    Commands,
    History,
    Lease,
    Metrics,
    Projection,
    Sync,
    WorkpadStore,
    WorkflowReloadPolicy,
    Writer
  }

  alias SymphonyElixir.ModelCatalog
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Task
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.Workflow.{Bundle, Store}

  @type actor_input ::
          :human
          | :agent
          | :system
          | String.t()
          | %{required(:type) => :human | :agent | :system, optional(:identity) => String.t()}

  @spec execute(Commands.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(command, opts) when is_list(opts) do
    with {:ok, actor} <- normalize_actor(Keyword.fetch!(opts, :actor)),
         expected_revision <- Keyword.get(opts, :expected_revision),
         idempotency_key when is_binary(idempotency_key) <- Keyword.fetch!(opts, :idempotency_key) do
      Writer.execute(command, actor, expected_revision, idempotency_key)
    else
      :error -> {:error, :idempotency_key_required}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_idempotency_key}
    end
  rescue
    KeyError -> {:error, :missing_command_option}
  end

  @spec tasks(keyword()) :: [Task.t()]
  def tasks(opts \\ []), do: Projection.list_tasks(opts)

  @spec task(String.t()) :: {:ok, Task.t()} | {:error, :not_found}
  def task(id_or_identifier), do: Projection.get_task(id_or_identifier)

  @spec runs(String.t() | nil) :: [map()]
  def runs(task_id \\ nil), do: Projection.list_runs(task_id)

  @spec run(String.t()) :: {:ok, map()} | {:error, :not_found}
  def run(run_id), do: Projection.get_run(run_id)

  @spec events(String.t() | nil) :: [map()]
  def events(task_id \\ nil), do: Projection.event_history(task_id)

  @spec metrics() :: map()
  def metrics, do: metrics_build().snapshot

  @spec metrics_for_stats() :: map()
  def metrics_for_stats, do: metrics_build().ui_snapshot

  @spec task_metrics(String.t()) :: {:ok, map()} | {:error, :not_found}
  def task_metrics(id_or_identifier) when is_binary(id_or_identifier) do
    with {:ok, task} <- task(id_or_identifier) do
      build = metrics_build()
      Metrics.task_metrics(build, task.id, runs(task.id))
    end
  end

  @spec state() :: map()
  def state do
    bundle =
      case Workflow.current() do
        {:ok, value} -> value
        _ -> nil
      end

    %{
      project: bundle && bundle.project,
      columns: bundle && bundle.columns,
      tasks: tasks(),
      runs: runs(),
      stats: metrics(),
      health: health()
    }
  end

  @spec health() :: map()
  def health do
    workflow_status = Store.status()
    lease_status = Lease.status()
    writer_status = safe_writer_state()

    bundle =
      case Workflow.current() do
        {:ok, value} -> value
        _ -> nil
      end

    sync =
      if bundle && Process.whereis(Sync),
        do: Sync.status(),
        else: %{state: :unavailable}

    orchestrator =
      safe_status(Orchestrator, :status, %{
        dispatch_gate: :orchestrator_unavailable,
        github: %{available: false, error: :orchestrator_unavailable},
        preflights: [],
        worker_health: [],
        publication_errors: %{}
      })

    %{
      workflow: workflow_status,
      lease: lease_status,
      projection: writer_status,
      board_sync: sync,
      github: orchestrator[:github] || %{available: false, error: :not_checked},
      preflights: orchestrator[:preflights] || [],
      publication_errors: orchestrator[:publication_errors] || %{},
      model_catalogs: safe_status(ModelCatalog, :status, %{}),
      workers: orchestrator
    }
  end

  @spec checkpoint() :: {:ok, map()} | {:error, term()}
  def checkpoint, do: Writer.checkpoint()

  @spec handoff() :: {:ok, map()} | {:error, term()}
  def handoff do
    with false <- busy?(),
         {:ok, bundle} <- Workflow.current(),
         {:ok, checkpoint} <- checkpoint(),
         :ok <- push_if_configured(bundle),
         :ok <- verify_handoff(bundle) do
      {:ok, checkpoint}
    else
      true -> {:error, :agents_running}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec reconcile(:take_local | :take_remote) :: {:ok, String.t()} | {:error, term()}
  def reconcile(strategy) when strategy in [:take_local, :take_remote] do
    with false <- busy?(),
         {:ok, bundle} <- Workflow.current(),
         remote when is_binary(remote) <- bundle.board.remote,
         {:ok, backup_ref} <- History.reconcile(bundle.project.id, remote, strategy),
         :ok <- Writer.reload_history() do
      {:ok, backup_ref}
    else
      true -> {:error, :agents_running}
      nil -> {:error, :board_remote_not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec write_workpad(String.t(), pos_integer(), String.t()) :: :ok | {:error, term()}
  def write_workpad(run_id, invocation, content), do: WorkpadStore.write(run_id, invocation, content)

  @spec write_workpad_template(String.t(), pos_integer(), String.t()) :: :ok | {:error, term()}
  def write_workpad_template(run_id, invocation, content),
    do: WorkpadStore.write_template(run_id, invocation, content)

  @spec latest_workpad(String.t(), String.t()) :: map() | nil
  def latest_workpad(task_id, current_run_id),
    do: WorkpadStore.latest_meaningful(task_id, current_run_id)

  @spec read_workpad(String.t(), pos_integer()) :: {:ok, String.t()} | {:error, :not_found}
  def read_workpad(run_id, invocation), do: Projection.read_workpad(run_id, invocation)

  @spec workpad_metadata(String.t()) :: [map()]
  def workpad_metadata(run_id), do: Projection.workpad_metadata(run_id)

  @spec workpads(String.t()) :: [map()]
  def workpads(run_id), do: Projection.list_workpads(run_id)

  @spec live_column_ids() :: [String.t()]
  def live_column_ids do
    tasks()
    |> Enum.map(& &1.column_id)
    |> Enum.uniq()
  rescue
    _error -> []
  catch
    :exit, _reason -> []
  end

  @spec busy?() :: boolean()
  def busy?, do: Projection.running?()

  @spec workflow_activated(Bundle.t(), Bundle.t()) :: :ok
  def workflow_activated(previous, current) do
    incompatible_paused_tasks(previous, current)
    :ok
  end

  @spec subscribe(:tasks | :runs | :health | :workflow | :sync | :events) :: :ok | {:error, term()}
  def subscribe(topic) do
    Phoenix.PubSub.subscribe(SymphonyElixir.PubSub, "board:#{topic}")
  end

  defp normalize_actor(%{type: type} = actor) when type in [:human, :agent, :system] do
    identity = Map.get(actor, :identity) || Map.get(actor, "identity") || Atom.to_string(type)
    {:ok, %{type: type, identity: to_string(identity)}}
  end

  defp normalize_actor(type) when type in [:human, :agent, :system] do
    {:ok, %{type: type, identity: Atom.to_string(type)}}
  end

  defp normalize_actor("human"), do: normalize_actor(:human)
  defp normalize_actor("agent"), do: normalize_actor(:agent)
  defp normalize_actor("system"), do: normalize_actor(:system)
  defp normalize_actor(actor), do: {:error, {:invalid_actor, actor}}

  defp push_if_configured(%Bundle{board: %{remote: nil}}), do: :ok
  defp push_if_configured(%Bundle{} = bundle), do: History.push(bundle.project.id, bundle.board.remote)

  defp verify_handoff(%Bundle{board: %{remote: nil}}), do: :ok

  defp verify_handoff(%Bundle{} = bundle) do
    with %{state: :synced, ahead: 0, behind: 0} <-
           History.sync_status(bundle.project.id, bundle.board.remote),
         :ok <- History.verify_remote(bundle.project.id, bundle.board.remote) do
      :ok
    else
      status -> {:error, {:handoff_verification_failed, status}}
    end
  end

  defp incompatible_paused_tasks(_previous, current) do
    tasks()
    |> WorkflowReloadPolicy.incompatible_tasks(current)
    |> Enum.each(&block_incompatible_task(&1, current))
  rescue
    _error -> :ok
  end

  defp block_incompatible_task(task, current) do
    command = %Commands.BlockTask{
      task_id: task.id,
      reason: "Workflow model policy changed; explicit reselection required"
    }

    execute(command,
      actor: %{type: :system, identity: "workflow-reload"},
      expected_revision: task.revision,
      idempotency_key: "workflow-policy:#{current.hash}:#{task.id}"
    )
  end

  defp safe_writer_state do
    Writer.state()
  catch
    :exit, _reason -> %{mutable: false, error: :writer_unavailable}
  end

  defp safe_status(module, function, fallback) do
    apply(module, function, [])
  rescue
    _error -> fallback
  catch
    :exit, _reason -> fallback
  end

  defp metrics_build do
    tasks = tasks() ++ tasks(archived: true)
    runtime = safe_status(Orchestrator, :status, %{online: false, running: [], rate_limits: []})

    column_ids =
      case Workflow.current() do
        {:ok, bundle} ->
          %{
            blocked: Bundle.blocked_column(bundle).id,
            done: Bundle.done_column(bundle).id
          }

        _ ->
          %{}
      end

    Metrics.build(
      tasks,
      runs(),
      Projection.list_run_telemetry(),
      runtime,
      column_ids,
      DateTime.utc_now()
    )
  end
end
