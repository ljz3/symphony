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
  def handle_info(:metrics_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  def handle_info(_message, socket), do: {:noreply, load(socket)}

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

  @impl true
  def render(assigns) do
    ~H"""
    <%= if @bundle do %>
    <section class="board-page">
      <header class="topbar">
        <div>
          <p class="eyebrow">{@bundle.project.key} · local authority</p>
          <h1>Symphony board</h1>
        </div>
        <nav class="topbar-actions">
          <Telemetry.live_status />
          <a href="/stats" class="button secondary">Stats</a>
          <a href="/archive" class="button secondary">Archive</a>
          <button type="button" class="secondary" phx-click={Phoenix.LiveView.JS.toggle(to: "#new-task-panel")}>New task</button>
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

      <section id="new-task-panel" class="task-panel" hidden>
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

      <div id="kanban" class="kanban" phx-hook="Kanban">
        <section :for={column <- @bundle.columns} class={"kanban-column role-#{column.role}"} data-column-id={column.id}>
          <header class="column-header">
            <h2>{column.name}</h2>
            <span>{length(tasks_in(@tasks, column.id))}</span>
          </header>
          <div class="card-stack" data-dropzone={column.id}>
            <article
              :for={task <- tasks_in(@tasks, column.id)}
              class={"task-card priority-#{task.priority}"}
              draggable={human_target?(@bundle, task)}
              data-task-id={task.id}
              data-task-revision={task.revision}
              data-active={task.runtime_state in ["starting", "running", "stopping"]}
            >
              <div class="card-meta"><span>{task.identifier}</span><span>{display_priority(task.priority)}</span></div>
              <h3><a href={"/tasks/#{task.identifier}"}>{task.title}</a></h3>
              <div class="badges">
                <span :if={task.dependencies != [] and not dependencies_done?(task, @tasks, @bundle)} class="badge waiting">Waiting</span>
                <span :if={task.runtime_state} class="badge running">{task.runtime_state}</span>
                <span :if={task.column_id == @blocked_column.id} class="badge blocked">Blocked</span>
                <a :if={task.github["url"]} class="badge pr" href={task.github["url"]} target="_blank">PR #{task.github["number"]}</a>
              </div>
              <div :if={@task_metrics[task.id]["run_count"] > 0} class="card-stats numeric">
                <span title={Telemetry.format_token_breakdown(@task_metrics[task.id])}>◈ {Telemetry.format_token_total(@task_metrics[task.id])}</span>
                <span>◷ {Telemetry.format_duration(Telemetry.live_duration_ms(@task_metrics[task.id]["agent_duration_ms"], @metrics["generated_at"], @now, @task_metrics[task.id]["active_run_count"]))}</span>
                <span>↻ {@task_metrics[task.id]["turn_count"]}</span>
              </div>
            </article>
          </div>
        </section>
      </div>
    </section>
    <% else %>
      <section class="board-page">
        <header class="topbar">
          <div><p class="eyebrow">Read-only diagnostics</p><h1>Symphony board</h1></div>
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

  defp human_target?(bundle, task), do: Map.get(bundle.human_transitions, task.column_id, []) != []
  defp display_priority(priority), do: priority |> Atom.to_string() |> String.capitalize()
  defp blank_nil(value) when value in [nil, ""], do: nil
  defp blank_nil(value), do: value

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

  defp format_error(reason), do: "Board command rejected: #{inspect(reason)}"

  defp schedule_runtime_tick, do: Process.send_after(self(), :metrics_tick, @runtime_tick_ms)
end
