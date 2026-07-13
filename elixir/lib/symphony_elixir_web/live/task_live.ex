defmodule SymphonyElixirWeb.TaskLive do
  @moduledoc "Editable task detail, execution history, and transition surface."

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.AgentStage
  alias SymphonyElixir.Board
  alias SymphonyElixir.Board.Commands
  alias SymphonyElixir.Codex.Catalog
  alias SymphonyElixir.GitHub
  alias SymphonyElixir.Task
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.Worktree
  alias SymphonyElixirWeb.TelemetryComponents, as: Telemetry

  @runtime_tick_ms 1_000

  @impl true
  def mount(%{"identifier" => identifier}, _session, socket) do
    if connected?(socket) do
      Enum.each([:tasks, :runs, :health, :workflow, :sync], &Board.subscribe/1)
      schedule_runtime_tick()
    end

    {:ok, socket |> assign(:now, DateTime.utc_now()) |> load(identifier)}
  end

  @impl true
  def handle_params(%{"identifier" => identifier}, _uri, socket), do: {:noreply, load(socket, identifier)}

  @impl true
  def handle_info(:metrics_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  def handle_info(_message, socket), do: {:noreply, load(socket, socket.assigns.task.identifier)}

  @impl true
  def handle_event("update_task", %{"task" => params}, socket) do
    task = socket.assigns.task
    attrs = update_attrs(params, task, socket.assigns.bundle)

    command_result(
      socket,
      %Commands.UpdateTask{task_id: task.id, attrs: attrs},
      task.revision,
      "Updated #{task.identifier}"
    )
  end

  def handle_event("transition", %{"column_id" => column_id}, socket) do
    task = socket.assigns.task

    with :ok <- maybe_prepare_rework(task, column_id),
         command <- %Commands.MoveTask{task_id: task.id, column_id: column_id, reason: "Human transition"} do
      command_result(socket, command, task.revision, "Transition requested")
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, format_error(reason))}
    end
  end

  def handle_event("resume", _params, socket) do
    task = socket.assigns.task
    command_result(socket, %Commands.ResumeTask{task_id: task.id}, task.revision, "Task resumed")
  end

  def handle_event("archive", _params, socket) do
    task = socket.assigns.task

    case Board.execute(%Commands.ArchiveTask{task_id: task.id},
           actor: %{type: :human, identity: "board-ui"},
           expected_revision: task.revision,
           idempotency_key: "ui-archive:#{Ecto.UUID.generate()}"
         ) do
      {:ok, _result} -> {:noreply, push_navigate(socket, to: "/archive")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, format_error(reason))}
    end
  end

  def handle_event("complete_criterion", params, socket) do
    task = socket.assigns.task
    evidence = String.trim(params["evidence"] || "")

    command = %Commands.CompleteAcceptance{
      task_id: task.id,
      criterion_id: params["criterion_id"],
      evidence: if(evidence == "", do: [], else: [%{"kind" => "human_note", "value" => evidence}])
    }

    command_result(socket, command, task.revision, "Criterion completed")
  end

  def handle_event("reopen_criterion", %{"criterion_id" => criterion_id}, socket) do
    task = socket.assigns.task

    command_result(
      socket,
      %Commands.ReopenAcceptance{task_id: task.id, criterion_id: criterion_id, reason: "Reopened in board UI"},
      task.revision,
      "Criterion reopened"
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="detail-page">
      <header class="topbar detail-topbar">
        <div>
          <a href="/" class="back-link">← Board</a>
          <p class="eyebrow">{@task.identifier} · {display_type(@task.type)}</p>
          <h1>{@task.title}</h1>
        </div>
        <div class="topbar-actions">
          <Telemetry.live_status />
          <a href="/stats" class="button secondary">Stats</a>
          <a :if={@task.github["url"]} href={@task.github["url"]} target="_blank" class="button secondary">Open PR</a>
          <span class={"state-pill state-#{@task.column_id}"}>{column_name(@bundle, @task.column_id)}</span>
        </div>
      </header>

      <div class="detail-grid">
        <main class="detail-main">
          <section class="detail-card">
            <div class="section-heading"><div><p class="eyebrow">Contract</p><h2>Task details</h2></div><span class="revision">revision {@task.revision}</span></div>
            <form phx-submit="update_task" class="task-form">
              <label>Title<input name="task[title]" value={@task.title} required disabled={contract_frozen?(@task)} /></label>
              <div class="form-grid">
                <label>Type<input value={display_type(@task.type)} disabled /></label>
                <label>Priority<select name="task[priority]" disabled={contract_frozen?(@task)}><option :for={priority <- ~w(Urgent High Normal Low)} value={priority} selected={String.downcase(priority) == Atom.to_string(@task.priority)}>{priority}</option></select></label>
              </div>
              <label>Markdown brief<textarea name="task[brief]" rows="8" disabled={contract_frozen?(@task)}>{@task.brief}</textarea></label>

              <fieldset disabled={contract_frozen?(@task)}>
                <legend>Acceptance criteria</legend>
                <label :for={criterion <- @task.acceptance_criteria} class="criterion-edit">
                  <span>{criterion["id"]}</span>
                  <input name={"task[criteria][#{criterion["id"]}]"} value={criterion["text"]} />
                </label>
                <label>Add criteria <span>one item per line</span><textarea name="task[new_criteria]" rows="3"></textarea></label>
              </fieldset>

              <label>Dependencies
                <select name="task[dependencies][]" multiple disabled={contract_frozen?(@task)}>
                  <option :for={candidate <- @dependency_options} value={candidate.id} selected={candidate.id in @task.dependencies}>{candidate.identifier} · {candidate.title}</option>
                </select>
              </label>

              <div :for={stage <- @multi_pair_stages} class="model-selection">
                <label>{stage.id} model / effort
                  <select name={"task[stage_selections][#{stage.id}]"} disabled={contract_frozen?(@task)}>
                    <option :for={{model, effort} <- Catalog.pairs(stage)} value={model <> "\u001f" <> effort} selected={selected_pair?(@task, stage.id, model, effort)}>{model} · {effort}</option>
                  </select>
                </label>
              </div>

              <button type="submit" disabled={contract_frozen?(@task)}>Save contract</button>
            </form>
          </section>

          <section class="detail-card">
            <div class="section-heading"><div><p class="eyebrow">Acceptance</p><h2>Criteria and evidence</h2></div></div>
            <article :for={criterion <- @task.acceptance_criteria} class={"criterion #{if criterion["completed"], do: "complete", else: "open"}"}>
              <div><strong>{if criterion["completed"], do: "✓", else: "○"} {criterion["text"]}</strong><p>{length(criterion["evidence_history"])} evidence history entries</p></div>
              <form :if={!criterion["completed"]} phx-submit="complete_criterion" class="criterion-action">
                <input type="hidden" name="criterion_id" value={criterion["id"]} />
                <input name="evidence" placeholder="Evidence note (recommended)" />
                <button type="submit" class="secondary">Complete</button>
              </form>
              <button :if={criterion["completed"]} phx-click="reopen_criterion" phx-value-criterion_id={criterion["id"]} class="secondary">Reopen</button>
              <pre :if={criterion["evidence"] != []}>{Jason.encode!(criterion["evidence"], pretty: true)}</pre>
            </article>
          </section>

          <section class="detail-card">
            <div class="section-heading"><div><p class="eyebrow">Execution</p><h2>Runs and workpads</h2></div></div>
            <div class="run-summary-grid">
              <div><span>Total tokens</span><strong class="numeric">{Telemetry.format_token_total(@task_stats)}</strong><small>{Telemetry.format_token_breakdown(@task_stats)}</small></div>
              <div><span>Agent time</span><strong class="numeric">{Telemetry.format_duration(task_agent_time(@task_stats, @metrics_generated_at, @now))}</strong><small>summed across all runs</small></div>
              <div><span>Turns</span><strong class="numeric">{@task_stats["turn_count"]}</strong><small>{@task_stats["run_count"]} runs</small></div>
            </div>
            <p :if={@runs == []} class="empty">No runs yet.</p>
            <article :for={run <- @runs} class="run-card">
              <div class="run-heading"><strong>{run["stage_id"]}</strong><span>{run["status"]}</span><code>{run["model"]} · {run["effort"]}</code></div>
              <div class="run-stat-grid">
                <div><span>Elapsed</span><strong class="numeric">{Telemetry.format_duration(run_duration(run, @metrics_generated_at, @now))}</strong></div>
                <div><span>Turns</span><strong class="numeric">{run["effective_stats"]["turn_count"]}</strong></div>
                <div><span>Total tokens</span><strong class="numeric">{Telemetry.format_token_total(run["effective_stats"]["token_usage"], if(run["effective_stats"]["token_usage"], do: "complete", else: "unavailable"))}</strong></div>
                <div><span>Worker</span><strong>{Telemetry.format_worker(run["worker_host"])}</strong></div>
              </div>
              <p class="run-token-breakdown">{Telemetry.format_usage_breakdown(run["effective_stats"]["token_usage"])}</p>
              <div :if={run["activity"]} class="runtime-callout">
                <strong>{run["activity"]["summary"]}</strong><br /><span>{run["activity"]["at"]}</span>
              </div>
              <div class="run-actions">
                <code>{run["id"]}</code>
                <button
                  :if={run["session_id"]}
                  id={"copy-task-session-#{run["id"]}"}
                  type="button"
                  class="subtle-button"
                  phx-hook="CopyValue"
                  data-copy={run["session_id"]}
                >Copy session ID</button>
              </div>
              <pre :if={workpad(@workpads, run["id"])}>{workpad(@workpads, run["id"])}</pre>
            </article>
          </section>

          <section class="detail-card">
            <div class="section-heading"><div><p class="eyebrow">Canonical history</p><h2>Events</h2></div></div>
            <ol class="event-list">
              <li :for={event <- Enum.reverse(@events)}><code>#{event["sequence"]}</code><strong>{event["type"]}</strong><span>{event["timestamp"]}</span><small>{get_in(event, ["actor", "type"])} · {get_in(event, ["actor", "identity"])}</small></li>
            </ol>
          </section>
        </main>

        <aside class="detail-sidebar">
          <section class="detail-card sticky-card">
            <p class="eyebrow">Workflow</p>
            <h2>Move task</h2>
            <p :if={@task.runtime_state} class="runtime-callout">Observed runtime: <strong>{@task.runtime_state}</strong><br />Desired column: {@task.desired_column_id || "unchanged"}</p>
            <button
              :for={column <- @human_targets}
              phx-click="transition"
              phx-value-column_id={column.id}
              class="transition-button secondary"
              data-confirm={transition_confirmation(@task, column)}
            >
              {column.name}
            </button>
            <button :if={@task.column_id == @blocked_column.id} phx-click="resume" class="transition-button">Resume to {column_name(@bundle, @task.blocked_from_column_id)}</button>
            <button :if={Task.terminal?(@task, @bundle) and !Task.archived?(@task)} phx-click="archive" class="transition-button danger" data-confirm="Archive this task? Its event history remains canonical.">Archive</button>

            <dl class="task-facts">
              <dt>Branch</dt><dd><code>{@task.branch}</code></dd>
              <dt>Rank</dt><dd>{@task.rank}</dd>
              <dt>Dependencies</dt><dd>{length(@task.dependencies)}</dd>
              <dt>PR</dt><dd>{if @task.github["number"], do: "##{@task.github["number"]}", else: "Not created"}</dd>
              <dt>Tokens</dt><dd class="numeric">{Telemetry.format_token_total(@task_stats)}</dd>
              <dt>Agent time</dt><dd class="numeric">{Telemetry.format_duration(task_agent_time(@task_stats, @metrics_generated_at, @now))}</dd>
              <dt>Turns</dt><dd class="numeric">{@task_stats["turn_count"]}</dd>
            </dl>
          </section>
        </aside>
      </div>
    </section>
    """
  end

  defp load(socket, identifier) do
    case Board.task(identifier) do
      {:ok, task} ->
        {:ok, bundle} = Workflow.current()
        {:ok, task_metrics} = Board.task_metrics(task.id)
        runs = task_metrics["runs"]

        socket
        |> assign(:task, task)
        |> assign(:bundle, bundle)
        |> assign(:runs, runs)
        |> assign(:task_stats, task_metrics["stats"])
        |> assign(:metrics_generated_at, task_metrics["generated_at"])
        |> assign(:events, Board.events(task.id))
        |> assign(:workpads, load_workpads(runs))
        |> assign(:dependency_options, Enum.reject(Board.tasks(), &(&1.id == task.id)))
        |> assign(:blocked_column, Workflow.Bundle.blocked_column(bundle))
        |> assign(:human_targets, human_targets(bundle, task))
        |> assign(:multi_pair_stages, Enum.filter(Map.values(bundle.stages), &(length(AgentStage.pairs(&1)) > 1)))

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Task not found")
        |> push_navigate(to: "/")
    end
  end

  defp command_result(socket, command, revision, message) do
    case Board.execute(command,
           actor: %{type: :human, identity: "board-ui"},
           expected_revision: revision,
           idempotency_key: "ui-command:#{Ecto.UUID.generate()}"
         ) do
      {:ok, _result} -> {:noreply, socket |> put_flash(:info, message) |> load(socket.assigns.task.identifier)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, format_error(reason))}
    end
  end

  defp update_attrs(params, task, bundle) do
    criterion_params = Map.get(params, "criteria", %{})

    existing =
      Enum.map(task.acceptance_criteria, fn criterion ->
        %{
          "id" => criterion["id"],
          "text" => Map.get(criterion_params, criterion["id"], criterion["text"])
        }
      end)

    additions =
      params
      |> Map.get("new_criteria", "")
      |> String.split(~r/\R/, trim: true)

    %{
      title: params["title"] || task.title,
      priority: params["priority"] || Atom.to_string(task.priority),
      brief: params["brief"] || task.brief,
      acceptance_criteria: existing ++ additions,
      dependencies: params["dependencies"] || [],
      stage_selections: merge_stage_selections(task.stage_selections, params["stage_selections"] || %{}, bundle)
    }
  end

  defp merge_stage_selections(current, selections, bundle) do
    merged =
      Enum.reduce(selections, current, fn {stage_id, pair}, acc ->
        [model, effort] = String.split(pair, "\u001f", parts: 2)
        Map.put(acc, stage_id, %{"model" => model, "effort" => effort})
      end)

    add_singleton_selections(merged, bundle)
  end

  defp add_singleton_selections(selections, bundle) do
    Enum.reduce(bundle.stages, selections, fn {stage_id, stage}, acc ->
      case AgentStage.singleton_pair(stage) do
        {:ok, {model, effort}} -> Map.put_new(acc, stage_id, %{"model" => model, "effort" => effort})
        :multiple -> acc
      end
    end)
  end

  defp maybe_prepare_rework(%{column_id: "human_review", github: %{"number" => _number}} = task, "rework") do
    case Board.runs(task.id) do
      [%{"workspace_path" => path, "worker_host" => worker_host} | _] when is_binary(path) ->
        GitHub.convert_to_draft(task, path, worker_host: worker_host)

      [%{"worker_host" => worker_host} | _] ->
        GitHub.convert_to_draft(task, Worktree.path(task), worker_host: worker_host)

      _ ->
        GitHub.convert_to_draft(task, Worktree.path(task))
    end
  end

  defp maybe_prepare_rework(_task, _column_id), do: :ok

  defp human_targets(bundle, task) do
    ids = Map.get(bundle.human_transitions, task.column_id, [])
    Enum.filter(bundle.columns, &(&1.id in ids))
  end

  defp load_workpads(runs) do
    Map.new(runs, fn run ->
      content =
        case Board.read_workpad(run["id"], 1) do
          {:ok, value} -> value
          _ -> nil
        end

      {run["id"], content}
    end)
  end

  defp workpad(workpads, run_id), do: workpads[run_id]
  defp selected_pair?(task, stage_id, model, effort), do: task.stage_selections[stage_id] == %{"model" => model, "effort" => effort}
  defp contract_frozen?(task), do: task.runtime_state in ["starting", "running", "stopping"] or Task.archived?(task)
  defp column_name(_bundle, nil), do: "Unknown"

  defp column_name(bundle, id) do
    case Workflow.Bundle.column(bundle, id) do
      nil -> id
      column -> column.name
    end
  end

  defp display_type(:feature), do: "Feature"
  defp display_type(:bug_fix), do: "Bug Fix"
  defp display_type(:chore), do: "Chore"

  defp transition_confirmation(task, column) do
    cond do
      task.runtime_state in ["starting", "running", "stopping"] -> "Stop the active run and move this task to #{column.name}?"
      column.id == "cancelled" -> "Cancel this task and close its open pull request?"
      true -> nil
    end
  end

  defp task_agent_time(stats, generated_at, now) do
    Telemetry.live_duration_ms(stats["agent_duration_ms"], generated_at, now, stats["active_run_count"])
  end

  defp run_duration(run, generated_at, now) do
    if run["effective_stats"]["source"] == "live" do
      Telemetry.advancing_duration_ms(run["effective_stats"]["duration_ms"], generated_at, now)
    else
      run["effective_stats"]["duration_ms"]
    end
  end

  defp format_error(reason), do: "Board command rejected: #{inspect(reason)}"
  defp schedule_runtime_tick, do: Process.send_after(self(), :metrics_tick, @runtime_tick_ms)
end
