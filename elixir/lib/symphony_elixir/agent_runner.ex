defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes one frozen stage run in a persistent task Git worktree.
  """

  require Logger

  alias SymphonyElixir.Board
  alias SymphonyElixir.Board.{Commands, Projection}
  alias SymphonyElixir.Codex.{AppServer, DynamicTool, RunStats}
  alias SymphonyElixir.{Config, GitHub, PromptBuilder, Task, Worktree}

  @github_retry_initial_ms 1_000
  @github_retry_max_ms 60_000

  @spec run(String.t(), String.t(), pid() | nil, keyword()) :: :ok | {:error, term()}
  def run(task_id, run_id, recipient \\ nil, opts \\ [])
      when is_binary(task_id) and is_binary(run_id) do
    with {:ok, task} <- Board.task(task_id),
         {:ok, run} <- Board.run(run_id),
         :ok <- validate_scope(task, run),
         worker_host <- run["worker_host"],
         {:ok, worktree} <- Worktree.ensure(task, worker_host),
         :ok <- Worktree.run_hook(:before_run, task, worktree, worker_host),
         :ok <- ensure_workpad(task, run, opts) do
      result = run_session(task, run, worktree, worker_host, recipient, opts)

      case Worktree.run_hook(:after_run, task, worktree, worker_host) do
        :ok -> result
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:agent_runner_exception, error, __STACKTRACE__}}
  end

  defp run_session(task, run, worktree, worker_host, recipient, opts) do
    case AppServer.start_session(worktree,
           worker_host: worker_host,
           model: run["model"],
           effort: run["effort"],
           environment: managed_environment(task, run),
           dynamic_tool_specs: DynamicTool.tool_specs(run)
         ) do
      {:ok, session} ->
        try do
          with :ok <- notify_session(recipient, task, run, session, worktree),
               :ok <- mark_run_started(task.id, run["id"], session.thread_id, worktree) do
            run_turns(session, task.id, run["id"], worktree, recipient, opts)
          end
        after
          AppServer.stop_session(session)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec reconcile_source(String.t(), String.t(), Path.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def reconcile_source(task_id, run_id, worktree, worker_host \\ nil) do
    with {:ok, task} <- Board.task(task_id),
         {:ok, run} <- Board.run(run_id),
         :ok <- validate_scope(task, run),
         {:ok, info} <- Worktree.reconcile(task, worktree, worker_host),
         {:ok, base_sha} <- Worktree.base_head(worktree, worker_host) do
      if source_unchanged?(task, info, base_sha) do
        :ok
      else
        record_source_head(task, run, info, base_sha)
      end
    end
  end

  defp run_turns(session, task_id, run_id, worktree, recipient, opts) do
    context = %{
      task_id: task_id,
      run_id: run_id,
      worktree: worktree,
      recipient: recipient,
      invocation: Keyword.get(opts, :invocation, 1),
      opts: opts
    }

    do_run_turns(session, context, 1)
  end

  defp do_run_turns(session, context, turn) do
    with :ok <- stop_requested_between_turns(context.task_id),
         {:ok, task} <- Board.task(context.task_id),
         {:ok, run} <- Board.run(context.run_id),
         :ok <- validate_scope(task, run),
         prompt <- turn_prompt(task, run, turn, context.opts),
         {:ok, %{session: active_session}} <-
           AppServer.run_turn(session, prompt, task,
             on_message:
               message_handler(
                 context.recipient,
                 context.task_id,
                 context.run_id,
                 context.worktree,
                 run["worker_host"]
               ),
             on_session_reconnected: fn reconnected_session ->
               notify_session(
                 context.recipient,
                 task,
                 run,
                 reconnected_session,
                 context.worktree
               )
             end,
             dynamic_tool_opts: [
               task_id: context.task_id,
               run_id: context.run_id,
               invocation: context.invocation
             ]
           ),
         :ok <- reconcile_source(context.task_id, context.run_id, context.worktree, run["worker_host"]),
         :ok <- reconcile_github(context.task_id, context.run_id, context.worktree, @github_retry_initial_ms),
         {:ok, refreshed} <- Board.task(context.task_id) do
      cond do
        refreshed.desired_column_id ->
          finish_run(refreshed, context.run_id, %{reason: "human_stop"})

        refreshed.column_id != run["start_column_id"] ->
          finish_run(refreshed, context.run_id, %{turns: turn, transitioned_to: refreshed.column_id})

        true ->
          do_run_turns(active_session, context, turn + 1)
      end
    else
      {:error, :graceful_stop_requested} ->
        with {:ok, task} <- Board.task(context.task_id) do
          finish_run(task, context.run_id, %{reason: "human_stop"})
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp turn_prompt(task, run, 1, opts), do: PromptBuilder.build_prompt(task, run, opts)
  defp turn_prompt(_task, _run, turn, _opts), do: PromptBuilder.continuation_prompt(turn)

  defp ensure_workpad(task, run, opts) do
    invocation = Keyword.get(opts, :invocation, 1)

    case Board.read_workpad(run["id"], invocation) do
      {:ok, _content} ->
        :ok

      {:error, :not_found} ->
        content = PromptBuilder.render_workpad(task, run, invocation: invocation)
        Board.write_workpad_template(run["id"], invocation, content)
    end
  end

  defp mark_run_started(task_id, run_id, session_id, worktree) do
    with {:ok, task} <- Board.task(task_id),
         {:ok, _result} <-
           Board.execute(
             %Commands.RunStarted{
               task_id: task_id,
               run_id: run_id,
               session_id: session_id,
               workspace_path: worktree
             },
             actor: %{type: :system, identity: "orchestrator"},
             expected_revision: task.revision,
             idempotency_key: "run-started:#{run_id}"
           ) do
      :ok
    end
  end

  defp finish_run(task, run_id, outcome) do
    case Board.execute(
           %Commands.RunFinished{
             task_id: task.id,
             run_id: run_id,
             outcome: outcome,
             stats: RunStats.summary(Projection.run_telemetry(run_id))
           },
           actor: %{type: :system, identity: "orchestrator"},
           expected_revision: task.revision,
           idempotency_key: "run-finished:#{run_id}"
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_github(task_id, run_id, worktree, backoff_ms) do
    with {:ok, task} <- Board.task(task_id),
         {:ok, run} <- Board.run(run_id),
         :ok <- validate_scope(task, run) do
      maybe_reconcile_github(task, run, worktree, backoff_ms)
    end
  end

  defp maybe_reconcile_github(task, run, worktree, backoff_ms) do
    if terminal_or_merged?(task) do
      :ok
    else
      reconcile_draft_pull_request(task, run, worktree, backoff_ms)
    end
  end

  defp reconcile_draft_pull_request(task, run, worktree, backoff_ms) do
    case GitHub.ensure_draft_pull_request(task, worktree,
           worker_host: run["worker_host"],
           run_id: run["id"]
         ) do
      {:ok, metadata} ->
        link_pull_request(task.id, run["id"], metadata)

      {:error, :no_meaningful_committed_diff} ->
        :ok

      {:error, reason} ->
        wait_for_github(task.id, run["id"], worktree, reason, backoff_ms)
    end
  end

  defp wait_for_github(task_id, run_id, worktree, reason, backoff_ms) do
    notify_github_wait(task_id, run_id, reason, backoff_ms)

    receive do
      :stop -> {:error, :graceful_stop_requested}
    after
      backoff_ms ->
        reconcile_github(task_id, run_id, worktree, min(backoff_ms * 2, @github_retry_max_ms))
    end
  end

  defp terminal_or_merged?(task) do
    bundle = Config.bundle!()
    Task.terminal?(task, bundle) or get_in(task.github, ["merged", "merged"]) == true
  end

  defp link_pull_request(task_id, run_id, metadata) do
    with {:ok, task} <- Board.task(task_id),
         {:ok, run} <- Board.run(run_id) do
      unchanged =
        task.github["number"] == metadata.number and task.github["head_sha"] == metadata.head_sha and
          task.github["draft"] == metadata.draft and
          (metadata.created_by_run_id != run_id or run["pull_request_created"] == true)

      if unchanged do
        :ok
      else
        execute_pull_request_link(task, run_id, metadata)
      end
    end
  end

  defp message_handler(recipient, task_id, run_id, worktree, worker_host) do
    fn message ->
      persist_run_telemetry(run_id, message)
      if is_pid(recipient), do: send(recipient, {:runner_update, task_id, run_id, message})

      if tool_event?(message), do: reconcile_after_tool_event(task_id, run_id, worktree, worker_host)

      :ok
    end
  end

  defp persist_run_telemetry(run_id, message) do
    case Projection.observe_run_telemetry(run_id, message) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("run telemetry update failed run_id=#{run_id} reason=#{inspect(reason)}")
    end
  end

  defp tool_event?(%{event: event}) when event in [:tool_call_completed, :tool_call_failed], do: true
  defp tool_event?(%{"event" => event}) when event in ["tool_call_completed", "tool_call_failed"], do: true
  defp tool_event?(_message), do: false

  defp source_unchanged?(task, info, base_sha) do
    task.source["head_sha"] == info.head_sha and task.source["clean"] == info.clean and
      task.source["base_sha"] == base_sha
  end

  defp record_source_head(task, run, info, base_sha) do
    command = %Commands.RecordSourceHead{
      task_id: task.id,
      head_sha: info.head_sha,
      base_sha: base_sha,
      clean: info.clean
    }

    case Board.execute(command,
           actor: %{type: :agent, identity: run["id"]},
           expected_revision: task.revision,
           idempotency_key: "source:#{run["id"]}:#{info.head_sha}:#{info.clean}:#{task.revision}"
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_pull_request_link(task, run_id, metadata) do
    command = %Commands.LinkPullRequest{
      task_id: task.id,
      run_id: run_id,
      number: metadata.number,
      url: metadata.url,
      head_sha: metadata.head_sha,
      state: metadata.state,
      draft: metadata.draft,
      created_by_run_id: metadata.created_by_run_id
    }

    case Board.execute(command,
           actor: %{type: :system, identity: "github"},
           expected_revision: task.revision,
           idempotency_key: "pr-link:#{run_id}:#{metadata.number}:#{metadata.head_sha}:#{metadata.draft}"
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_after_tool_event(task_id, run_id, worktree, worker_host) do
    case reconcile_source(task_id, run_id, worktree, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "source reconciliation after tool call failed task_id=#{task_id} " <>
            "run_id=#{run_id} reason=#{inspect(reason)}"
        )
    end
  end

  defp notify_session(recipient, task, run, session, worktree) do
    if is_pid(recipient) do
      send(recipient, {:runner_session, task.id, run["id"], session, worktree})
    end

    :ok
  end

  defp notify_github_wait(task_id, run_id, reason, backoff_ms) do
    Phoenix.PubSub.broadcast(
      SymphonyElixir.PubSub,
      "board:health",
      {:github_wait, task_id, run_id, reason, backoff_ms}
    )
  rescue
    _error -> :ok
  end

  defp stop_requested_between_turns(task_id) do
    receive do
      :stop -> {:error, :graceful_stop_requested}
    after
      0 ->
        case Board.task(task_id) do
          {:ok, %{runtime_state: "stopping"}} -> {:error, :graceful_stop_requested}
          _ -> :ok
        end
    end
  end

  defp validate_scope(%Task{} = task, run) do
    if run["task_id"] == task.id and task.active_run_id == run["id"] and
         run["status"] in ["starting", "running", "stopping"] do
      :ok
    else
      {:error, :run_scope_not_active}
    end
  end

  defp managed_environment(task, run) do
    %{
      "SYMPHONY_MANAGED_RUN" => "1",
      "SYMPHONY_TASK_ID" => task.id,
      "SYMPHONY_TASK_IDENTIFIER" => task.identifier,
      "SYMPHONY_TASK_BRANCH" => task.branch,
      "SYMPHONY_RUN_ID" => run["id"]
    }
  end
end
