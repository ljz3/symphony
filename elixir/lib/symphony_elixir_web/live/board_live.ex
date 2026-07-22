defmodule SymphonyElixirWeb.BoardLive do
  @moduledoc "Interactive Kanban board and task creation surface."

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.AgentStage
  alias SymphonyElixir.Board
  alias SymphonyElixir.Board.Commands
  alias SymphonyElixir.ModelCatalog
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.StageSelection
  alias SymphonyElixir.Workflow
  alias SymphonyElixirWeb.TelemetryComponents, as: Telemetry

  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Enum.each([:tasks, :runs, :health, :workflow, :sync], &Board.subscribe/1)
      schedule_runtime_tick()
    end

    {:ok, socket |> assign(:now, DateTime.utc_now()) |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign_peek(socket, params["peek"])}
  end

  @impl true
  def handle_info(:metrics_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  def handle_info(_message, socket), do: {:noreply, socket |> load() |> refresh_peek()}

  @impl true
  def handle_event("create_task", %{"task" => params}, socket) do
    case create_attrs(params, socket.assigns.bundle) do
      {:ok, attrs} ->
        case Board.execute(%Commands.CreateTask{attrs: attrs},
               actor: %{type: :human, identity: "board-ui"},
               expected_revision: 0,
               idempotency_key: "ui-create:#{Ecto.UUID.generate()}"
             ) do
          {:ok, %{"task" => task}} ->
            {:noreply,
             socket
             |> put_flash(:info, "Created #{task["identifier"]}")
             |> push_navigate(to: "/tasks/#{task["identifier"]}")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, format_error(reason))}
        end

      :error ->
        {:noreply, put_flash(socket, :error, "Invalid backend / model / effort selection.")}
    end
  end

  def handle_event("move_task", params, socket) do
    with {:ok, task} <- Board.task(params["task_id"]),
         {:ok, revision} <- parse_integer(params["expected_revision"] || task.revision),
         {:ok, command} <- move_or_reorder(task, params) do
      case Board.execute(command,
             actor: %{type: :human, identity: "board-ui"},
             expected_revision: revision,
             idempotency_key: "ui-move:#{Ecto.UUID.generate()}"
           ) do
        {:ok, _result} -> {:noreply, load(socket)}
        {:error, reason} -> {:noreply, put_flash(socket, :error, format_error(reason))}
      end
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, format_error(reason))}
    end
  end

  def handle_event("open_peek", %{"identifier" => identifier}, socket) do
    {:noreply, push_patch(socket, to: "/?peek=#{identifier}")}
  end

  def handle_event("close_peek", _params, socket) do
    {:noreply, push_patch(socket, to: "/")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= if @bundle do %>
    <section class="board-page">
      <header class="topbar">
        <div class="topbar-title">
          <h1>Symphony</h1>
          <span class="topbar-key">{@bundle.project.key} · local authority</span>
        </div>
        <nav class="topbar-actions">
          <Telemetry.live_status />
          <a href="/stats" class="button secondary">Stats</a>
          <a href="/archive" class="button secondary">Archive</a>
          <button type="button" phx-click={Phoenix.LiveView.JS.toggle(to: "#new-task-panel")}>+ New task</button>
        </nav>
      </header>

      <section class="health-strip" aria-label="Project health">
        <.health_chip label="Workflow" value={health_value(@health.workflow)} />
        <.health_chip label="Lease" value={if(@health.lease.owned, do: "owned", else: "diagnostic")} />
        <.health_chip label="History" value={to_string(@health.board_sync.state)} />
        <.health_chip label="GitHub" value={github_health(@orchestrator)} />
        <.health_chip :for={{backend, status} <- Enum.sort(@catalog)} label={"#{backend} catalog"} value={catalog_health(status)} />
        <.health_chip label="Workers" value={worker_health(@orchestrator)} />
        <.health_chip label="Dispatch" value={dispatch_health(@orchestrator)} />
      </section>

      <section class="board-metrics" aria-label="Project statistics">
        <a href="/stats" class="board-metric">
          <span>Total tokens</span>
          <strong class="numeric">{Telemetry.format_token_total(@metrics["project"])}</strong>
        </a>
        <a href="/stats" class="board-metric">
          <span>Agent time</span>
          <strong class="numeric">{Telemetry.format_duration(Telemetry.live_duration_ms(@metrics["project"]["agent_duration_ms"], @metrics["generated_at"], @now, @metrics["counts"]["active_run_count"]))}</strong>
        </a>
        <a href="/stats" class="board-metric">
          <span>Project age</span>
          <strong class="numeric">{Telemetry.format_duration(Telemetry.advancing_duration_ms(@metrics["project"]["age_ms"], @metrics["generated_at"], @now))}</strong>
        </a>
        <a href="/stats" class="board-metric">
          <span>Active</span>
          <strong class="numeric">{@metrics["counts"]["active_run_count"]}</strong>
        </a>
        <a href="/stats" class="board-metric">
          <span>Blocked</span>
          <strong class="numeric">{@metrics["counts"]["blocked_task_count"]}</strong>
        </a>
      </section>

      <div id="new-task-panel" class="modal-root" hidden>
        <div class="modal-scrim" phx-click={Phoenix.LiveView.JS.hide(to: "#new-task-panel")}></div>
        <section class="task-panel modal-card">
          <div class="panel-heading">
            <div><p class="eyebrow">Create</p><h2>Execution-ready task</h2></div>
            <button type="button" class="ghost" phx-click={Phoenix.LiveView.JS.hide(to: "#new-task-panel")}>Close</button>
          </div>
          <form phx-submit="create_task" class="task-form">
            <label>Title<input name="task[title]" required /></label>
            <div class="form-grid">
              <label>Type<select name="task[type]"><option value="Feature">Feature</option><option value="Bug Fix">Bug Fix</option><option value="Chore">Chore</option></select></label>
              <label>Priority<select name="task[priority]"><option value="Normal">Normal</option><option value="Urgent">Urgent</option><option value="High">High</option><option value="Low">Low</option></select></label>
            </div>
            <label>Markdown brief<textarea name="task[brief]" rows="6" required></textarea></label>
            <label>Acceptance checklist <span>one item per line</span><textarea name="task[acceptance_criteria]" rows="5" required></textarea></label>
            <label>Dependencies<select name="task[dependencies][]" multiple><option :for={task <- @tasks} value={task.id}>{task.identifier} · {task.title}</option></select></label>
            <div :for={stage <- @multi_pair_stages} class="model-selection">
              <label>{stage.id} backend / model / effort
                <select name={"task[stage_selections][#{stage.id}]"} required>
                  <option :for={option <- ModelCatalog.pairs(stage)} value={StageSelection.encode(option)}>{StageSelection.label(option)}</option>
                </select>
              </label>
            </div>
            <button type="submit">Create in {@initial_column.name}</button>
          </form>
        </section>
      </div>

      <div id="kanban" class="kanban" phx-hook="Kanban">
        <section :for={column <- @bundle.columns} class={"kanban-column role-#{column.role}"} data-column-id={column.id}>
          <header class="column-header">
            <span class={"column-dot role-#{column.role}"}></span>
            <h2>{column.name}</h2>
            <span>{length(tasks_in(@tasks, column.id))}</span>
          </header>
          <div class="card-stack" data-dropzone={column.id}>
            <article
              :for={task <- tasks_in(@tasks, column.id)}
              id={"card-#{task.id}"}
              class={"task-card priority-#{task.priority}"}
              draggable={human_target?(@bundle, task)}
              data-task-id={task.id}
              data-task-revision={task.revision}
              data-active={task.runtime_state in ["starting", "running", "stopping"]}
              data-identifier={task.identifier}
              data-branch={task.branch}
              data-pr-url={task.github["url"]}
              data-moves={Jason.encode!(board_moves(@bundle, task))}
              phx-hook="HoverPeek"
            >
              <h3><.link patch="/?peek=#{task.identifier}">{task.title}</.link></h3>
              <div class="card-tags">
                <span class={"tag tag-type-#{task.type}"}>{display_type(task.type)}</span>
                <span class={"tag tag-priority-#{task.priority}"}>{display_priority(task.priority)}</span>
                <span :if={task.dependencies != [] and not dependencies_done?(task, @tasks, @bundle)} class="tag waiting">Waiting</span>
                <span :if={task.runtime_state} class="tag running"><span class="pulse-dot"></span>{task.runtime_state}</span>
                <span :if={task.column_id == @blocked_column.id} class="tag blocked">Blocked</span>
                <a :if={task.github["url"]} class="tag pr" href={task.github["url"]} target="_blank">PR #{task.github["number"]}</a>
              </div>
              <div class="card-meta numeric">
                <span class="card-id">{task.identifier}</span>
                <span :if={@task_metrics[task.id]["run_count"] > 0}>
                  ◈ {Telemetry.format_token_total(@task_metrics[task.id])} · ◷ {Telemetry.format_duration(Telemetry.live_duration_ms(@task_metrics[task.id]["agent_duration_ms"], @metrics["generated_at"], @now, @task_metrics[task.id]["active_run_count"]))} · ↻ {@task_metrics[task.id]["turn_count"]}
                </span>
              </div>
              <div class="peek-popover" hidden>
                <strong class="peek-title">{task.title}</strong>
                <p class="peek-brief">{brief_excerpt(task.brief)}</p>
                <dl class="peek-facts">
                  <div><dt>Acceptance</dt><dd>{acceptance_progress(task)}</dd></div>
                  <div><dt>Dependencies</dt><dd>{dependency_summary(task, @tasks, @bundle)}</dd></div>
                  <div><dt>Tokens</dt><dd class="numeric">{Telemetry.format_token_breakdown(@task_metrics[task.id])}</dd></div>
                  <div><dt>Branch</dt><dd>{task.branch}</dd></div>
                  <div><dt>Updated</dt><dd>{task.updated_at}</dd></div>
                </dl>
              </div>
            </article>
          </div>
        </section>
      </div>

      <div :if={@peek} class="drawer-root" phx-window-keydown="close_peek" phx-key="Escape">
        <div class="drawer-scrim" phx-click="close_peek"></div>
        <aside class="peek-drawer" aria-label="Task peek">
          <div class="drawer-head">
            <span class="drawer-id">{@peek.task.identifier}</span>
            <button type="button" class="ghost" phx-click="close_peek">Close</button>
          </div>
          <h2 class="drawer-title">{@peek.task.title}</h2>
          <div class="drawer-tags">
            <span class={"state-pill state-#{@peek.task.column_id}"}>{column_name(@bundle, @peek.task.column_id)}</span>
            <span class={"tag tag-priority-#{@peek.task.priority}"}>{display_priority(@peek.task.priority)}</span>
            <span class={"tag tag-type-#{@peek.task.type}"}>{display_type(@peek.task.type)}</span>
            <a :if={@peek.task.github["url"]} class="tag pr" href={@peek.task.github["url"]} target="_blank">PR #{@peek.task.github["number"]}</a>
          </div>
          <section>
            <h3>Brief</h3>
            <p class="drawer-brief">{@peek.task.brief}</p>
          </section>
          <section>
            <h3>Acceptance · {acceptance_progress(@peek.task)}</h3>
            <ul class="drawer-checklist">
              <li :for={criterion <- @peek.task.acceptance_criteria} class={if criterion["completed"], do: "done", else: ""}>
                {if criterion["completed"], do: "✓", else: "○"} {criterion["text"]}
              </li>
            </ul>
          </section>
          <section :if={@peek.latest_run}>
            <h3>Latest run</h3>
            <div class="drawer-facts">
              <div><dt>Stage</dt><dd>{@peek.latest_run["stage_id"]}</dd></div>
              <div><dt>Status</dt><dd>{@peek.latest_run["status"]}</dd></div>
              <div><dt>Model</dt><dd>{StageSelection.label({@peek.latest_run["backend"] || "codex", @peek.latest_run["model"], @peek.latest_run["effort"]})}</dd></div>
            </div>
          </section>
          <section>
            <h3>Facts</h3>
            <div class="drawer-facts">
              <div><dt>Branch</dt><dd><code>{@peek.task.branch}</code></dd></div>
              <div><dt>Dependencies</dt><dd>{dependency_summary(@peek.task, @tasks, @bundle)}</dd></div>
              <div><dt>Tokens</dt><dd class="numeric">{Telemetry.format_token_total(@peek.stats)} · {Telemetry.format_token_breakdown(@peek.stats)}</dd></div>
              <div><dt>Agent time</dt><dd class="numeric">{Telemetry.format_duration(Telemetry.live_duration_ms(@peek.stats["agent_duration_ms"], @metrics["generated_at"], @now, @peek.stats["active_run_count"]))}</dd></div>
              <div><dt>Turns</dt><dd class="numeric">{@peek.stats["turn_count"]}</dd></div>
              <div><dt>Revision</dt><dd>{@peek.task.revision}</dd></div>
            </div>
          </section>
          <a href={"/tasks/#{@peek.task.identifier}"} class="button secondary drawer-open-page">Open full page →</a>
        </aside>
      </div>
    </section>
    <% else %>
      <section class="board-page">
        <header class="topbar">
          <div class="topbar-title"><h1>Symphony</h1><span class="topbar-key">read-only diagnostics</span></div>
          <nav class="topbar-actions"><a href="/stats" class="button secondary">Stats</a><a href="/archive" class="button secondary">Archive</a></nav>
        </header>
        <section class="detail-card">
          <h2>Workflow bundle is invalid</h2>
          <p>Task history remains readable, but mutation and dispatch are gated until `WORKFLOW.yml` and every referenced template validate.</p>
          <pre>{inspect(@workflow_error)}</pre>
        </section>
        <section class="detail-card archive-list">
          <p :if={@tasks == []} class="empty">No projected tasks.</p>
          <article :for={task <- @tasks} class="archive-row">
            <div><strong>{task.identifier}</strong><span>{task.title}</span></div>
            <span>{task.column_id}</span><time>revision {task.revision}</time>
          </article>
        </section>
      </section>
    <% end %>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  defp health_chip(assigns) do
    ~H"""
    <span class={"health-chip health-#{health_class(@value)}"}><strong>{@label}</strong> {@value}</span>
    """
  end

  defp load(socket) do
    tasks = Board.tasks()
    metrics = Board.metrics()
    task_metrics = Map.new(metrics["tasks"], &{&1["task_id"], &1})

    case Workflow.current() do
      {:ok, bundle} ->
        socket
        |> assign(:bundle, bundle)
        |> assign(:workflow_error, nil)
        |> assign(:tasks, tasks)
        |> assign(:metrics, metrics)
        |> assign(:task_metrics, task_metrics)
        |> assign(:health, Board.health())
        |> assign(:orchestrator, Orchestrator.status())
        |> assign(:catalog, ModelCatalog.status())
        |> assign(:initial_column, Workflow.Bundle.initial_column(bundle))
        |> assign(:blocked_column, Workflow.Bundle.blocked_column(bundle))
        |> assign(:multi_pair_stages, Enum.filter(Map.values(bundle.stages), &(length(AgentStage.pairs(&1)) > 1)))

      {:error, reason} ->
        socket
        |> assign(:bundle, nil)
        |> assign(:workflow_error, reason)
        |> assign(:tasks, tasks)
        |> assign(:metrics, metrics)
        |> assign(:task_metrics, task_metrics)
        |> assign(:health, Board.health())
        |> assign(:orchestrator, Orchestrator.status())
        |> assign(:catalog, ModelCatalog.status())
        |> assign(:initial_column, nil)
        |> assign(:blocked_column, nil)
        |> assign(:multi_pair_stages, [])
    end
  end

  defp assign_peek(socket, nil), do: assign(socket, :peek, nil)

  defp assign_peek(socket, identifier) do
    case Board.task(identifier) do
      {:ok, task} ->
        {:ok, metrics} = Board.task_metrics(task.id)

        assign(socket, :peek, %{
          task: task,
          stats: metrics["stats"],
          latest_run: List.first(metrics["runs"] || [])
        })

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Task not found")
        |> assign(:peek, nil)
    end
  end

  defp refresh_peek(socket) do
    case socket.assigns[:peek] do
      nil -> socket
      %{task: task} -> assign_peek(socket, task.identifier)
    end
  end

  defp create_attrs(params, bundle) do
    criteria = params["acceptance_criteria"] |> to_string() |> String.split(~r/\R/, trim: true)
    dependencies = params["dependencies"] || []

    with {:ok, selections} <- parse_stage_selections(params["stage_selections"] || %{}, bundle) do
      {:ok,
       %{
         title: params["title"],
         type: params["type"],
         priority: params["priority"] || "Normal",
         brief: params["brief"],
         acceptance_criteria: criteria,
         dependencies: dependencies,
         stage_selections: selections
       }}
    end
  end

  defp parse_stage_selections(selections, bundle) do
    selections
    |> Enum.reduce_while({:ok, %{}}, fn {stage_id, encoded}, {:ok, acc} ->
      case StageSelection.decode(encoded) do
        {:ok, option} -> {:cont, {:ok, Map.put(acc, stage_id, StageSelection.to_map(option))}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, selected} -> {:ok, add_singleton_selections(selected, bundle)}
      :error -> :error
    end
  end

  defp add_singleton_selections(selected, bundle) do
    Enum.reduce(bundle.stages, selected, fn {stage_id, stage}, acc ->
      case AgentStage.singleton_pair(stage) do
        {:ok, option} -> Map.put_new(acc, stage_id, StageSelection.to_map(option))
        :multiple -> acc
      end
    end)
  end

  defp move_or_reorder(task, %{"column_id" => column_id} = params) when column_id == task.column_id do
    {:ok,
     %Commands.ReorderTask{
       task_id: task.id,
       before_task_id: blank_nil(params["before_task_id"]),
       after_task_id: blank_nil(params["after_task_id"])
     }}
  end

  defp move_or_reorder(%{column_id: "human_review"}, %{"column_id" => "rework"}) do
    {:error, :review_feedback_required}
  end

  defp move_or_reorder(task, %{"column_id" => column_id}) when is_binary(column_id) do
    {:ok, %Commands.MoveTask{task_id: task.id, column_id: column_id}}
  end

  defp move_or_reorder(_task, _params), do: {:error, :column_id_required}

  defp tasks_in(tasks, column_id), do: Enum.filter(tasks, &(&1.column_id == column_id))

  defp dependencies_done?(task, tasks, bundle) do
    done = Workflow.Bundle.done_column(bundle).id
    by_id = Map.new(tasks, &{&1.id, &1})
    Enum.all?(task.dependencies, &(by_id[&1] && by_id[&1].column_id == done))
  end

  # Move targets offered by the card context menu: the column's human
  # transitions, excluding the Human Review → Rework shortcut (feedback form
  # only, same rule as the task detail page).
  defp board_moves(bundle, task) do
    bundle.human_transitions
    |> Map.get(task.column_id, [])
    |> Enum.reject(fn id -> id == task.column_id or (task.column_id == "human_review" and id == "rework") end)
    |> Enum.flat_map(fn id ->
      case Workflow.Bundle.column(bundle, id) do
        nil -> []
        column -> [%{id: column.id, name: column.name}]
      end
    end)
  end

  defp brief_excerpt(nil), do: ""

  defp brief_excerpt(brief) do
    excerpt = brief |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(excerpt) > 220, do: String.slice(excerpt, 0, 220) <> "…", else: excerpt
  end

  defp acceptance_progress(task) do
    total = length(task.acceptance_criteria)
    done = Enum.count(task.acceptance_criteria, & &1["completed"])
    "#{done}/#{total} complete"
  end

  defp dependency_summary(%{dependencies: []}, _tasks, _bundle), do: "None"

  defp dependency_summary(task, tasks, bundle) do
    if dependencies_done?(task, tasks, bundle) do
      "#{length(task.dependencies)} · all done"
    else
      "#{length(task.dependencies)} · waiting"
    end
  end

  defp human_target?(bundle, task), do: Map.get(bundle.human_transitions, task.column_id, []) != []
  defp display_priority(priority), do: priority |> Atom.to_string() |> String.capitalize()
  defp display_type(:feature), do: "Feature"
  defp display_type(:bug_fix), do: "Bug Fix"
  defp display_type(:chore), do: "Chore"
  defp blank_nil(value) when value in [nil, ""], do: nil
  defp blank_nil(value), do: value

  defp column_name(_bundle, nil), do: "Unknown"

  defp column_name(bundle, id) do
    case Workflow.Bundle.column(bundle, id) do
      nil -> id
      column -> column.name
    end
  end

  defp github_health(%{github: %{available: true}}), do: "ready"
  defp github_health(_status), do: "unavailable"
  defp catalog_health(%{state: :available}), do: "ready"
  defp catalog_health(%{state: :loading}), do: "loading"
  defp catalog_health(%{state: :disabled}), do: "disabled"
  defp catalog_health(_status), do: "policy fallback"
  defp worker_health(%{dispatch_gate: :no_eligible_worker}), do: "unavailable"
  defp worker_health(_status), do: "ready"
  defp dispatch_health(%{dispatch_gate: nil}), do: "ready"
  defp dispatch_health(%{dispatch_gate: gate}), do: gate |> inspect() |> String.slice(0, 32)
  defp health_value(%{valid: true, pending: false, error: nil}), do: "valid"
  defp health_value(%{pending: true}), do: "pending"
  defp health_value(_status), do: "invalid"
  defp health_class(value) when value in ["valid", "owned", "synced", "local_only", "ready"], do: "good"
  defp health_class(value) when value in ["pending", "ahead", "behind", "unknown", "loading", "policy fallback"], do: "warn"
  defp health_class(_value), do: "bad"

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> {:error, :invalid_revision}
    end
  end

  defp format_error(:review_feedback_required),
    do: "Review feedback is required before Rework — open the task and use the feedback box."

  defp format_error(reason), do: "Board command rejected: #{inspect(reason)}"

  defp schedule_runtime_tick, do: Process.send_after(self(), :metrics_tick, @runtime_tick_ms)
end
