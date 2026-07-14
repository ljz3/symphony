defmodule SymphonyElixirWeb.StatsLive do
  @moduledoc "Live project accounting and active Codex session observability."

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Board
  alias SymphonyElixirWeb.TelemetryComponents, as: Telemetry

  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Enum.each([:tasks, :runs, :health, :workflow], &Board.subscribe/1)
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
  def render(assigns) do
    ~H"""
    <section class="stats-page">
      <header class="topbar stats-topbar">
        <div>
          <a href="/" class="back-link">← Board</a>
          <p class="eyebrow">Durable project accounting</p>
          <h1>Symphony stats</h1>
        </div>
        <nav class="topbar-actions">
          <Telemetry.live_status />
          <a href="/archive" class="button secondary">Archive</a>
        </nav>
      </header>

      <section class="metric-grid" aria-label="Project totals">
        <Telemetry.metric_card
          label="Total tokens"
          value={Telemetry.format_token_total(@metrics["project"])}
          detail={Telemetry.format_token_breakdown(@metrics["project"])}
          class={if Telemetry.partial?(@metrics["project"]), do: "metric-partial"}
        />
        <Telemetry.metric_card
          label="Agent time"
          value={Telemetry.format_duration(project_agent_time(@metrics, @now))}
          detail="Summed across every run"
        />
        <Telemetry.metric_card
          label="Project age"
          value={Telemetry.format_duration(project_age(@metrics, @now))}
          detail={if @metrics["project"]["first_run_at"], do: "Since first run claim", else: "No runs yet"}
        />
        <Telemetry.metric_card
          label="Service uptime"
          value={Telemetry.format_duration(service_uptime(@metrics, @now))}
          detail={if @metrics["runtime"]["online"], do: "Current orchestrator process", else: "Orchestrator offline"}
        />
        <Telemetry.metric_card label="Active agents" value={to_string(@metrics["counts"]["active_run_count"])} detail="Starting, running, or stopping" />
        <Telemetry.metric_card label="Blocked tasks" value={to_string(@metrics["counts"]["blocked_task_count"])} detail="Non-archived tasks" />
        <Telemetry.metric_card label="Codex sessions" value={Telemetry.format_count(@metrics["counts"]["session_count"])} detail="Distinct started threads" />
        <Telemetry.metric_card label="Completed tasks" value={Telemetry.format_count(@metrics["counts"]["completed_task_count"])} detail="Current and archived Done tasks" />
        <Telemetry.metric_card label="Turns" value={Telemetry.format_count(@metrics["counts"]["turn_count"])} detail="Unique Codex turns" />
        <Telemetry.metric_card label="Runs" value={Telemetry.format_count(@metrics["counts"]["run_count"])} detail={"Across #{@metrics["counts"]["task_count"]} tasks"} />
      </section>

      <section class="detail-card stats-section">
        <div class="section-heading">
          <div><p class="eyebrow">All durable history</p><h2>Usage by model, stage, and effort</h2></div>
          <span class="revision">highest known token spend first</span>
        </div>
        <p class="stats-note">Completed tasks are distinct Done tasks with a started run in each grouping. A task can contribute to multiple model, stage, or effort rows.</p>
        <p :if={@metrics["models"] == []} class="empty">No model usage yet.</p>
        <div :if={@metrics["models"] != []} class="table-wrap">
          <table class="stats-table model-usage-table">
            <thead>
              <tr>
                <th>Model / stage / effort</th>
                <th>Tasks</th>
                <th>Completed</th>
                <th>Sessions</th>
                <th>Runs</th>
                <th>Turns</th>
                <th>Agent time</th>
                <th>Tokens</th>
              </tr>
            </thead>
            <tbody>
              <%= for model <- @metrics["models"] do %>
                <tr class="model-summary-row">
                  <th scope="row"><strong>{model_label(model["model"])}</strong><small>All stages · efforts combined</small></th>
                  <td class="numeric">{Telemetry.format_count(model["task_count"])}</td>
                  <td class="numeric">{Telemetry.format_count(model["completed_task_count"])}</td>
                  <td class="numeric"><span>{Telemetry.format_count(model["session_count"])}</span><small>{Telemetry.format_count(model["active_session_count"])} active</small></td>
                  <td class="numeric">{Telemetry.format_count(model["run_count"])}</td>
                  <td class="numeric">{Telemetry.format_count(model["turn_count"])}</td>
                  <td class="numeric">{Telemetry.format_duration(group_agent_time(model, @metrics, @now))}</td>
                  <td class="numeric"><span>{Telemetry.format_token_total(model)}</span><small>{Telemetry.format_token_breakdown(model)}</small><span :if={Telemetry.partial?(model)} class="badge waiting">{model["token_usage_state"]}</span></td>
                </tr>
                <%= for stage <- model["stages"] do %>
                  <tr class="model-stage-row">
                    <th scope="row" aria-label={stage_accessible_label(model["model"], stage["stage_id"])}><span class="stage-label">{stage_label(stage["stage_id"])}</span><small>All efforts combined</small></th>
                    <td class="numeric">{Telemetry.format_count(stage["task_count"])}</td>
                    <td class="numeric">{Telemetry.format_count(stage["completed_task_count"])}</td>
                    <td class="numeric"><span>{Telemetry.format_count(stage["session_count"])}</span><small>{Telemetry.format_count(stage["active_session_count"])} active</small></td>
                    <td class="numeric">{Telemetry.format_count(stage["run_count"])}</td>
                    <td class="numeric">{Telemetry.format_count(stage["turn_count"])}</td>
                    <td class="numeric">{Telemetry.format_duration(group_agent_time(stage, @metrics, @now))}</td>
                    <td class="numeric"><span>{Telemetry.format_token_total(stage)}</span><small>{Telemetry.format_token_breakdown(stage)}</small><span :if={Telemetry.partial?(stage)} class="badge waiting">{stage["token_usage_state"]}</span></td>
                  </tr>
                  <tr :for={effort <- stage["efforts"]} class="model-effort-row">
                    <th scope="row" aria-label={effort_accessible_label(model["model"], stage["stage_id"], effort["effort"])}><span class="effort-label">{effort_label(effort["effort"])}</span></th>
                    <td class="numeric">{Telemetry.format_count(effort["task_count"])}</td>
                    <td class="numeric">{Telemetry.format_count(effort["completed_task_count"])}</td>
                    <td class="numeric"><span>{Telemetry.format_count(effort["session_count"])}</span><small>{Telemetry.format_count(effort["active_session_count"])} active</small></td>
                    <td class="numeric">{Telemetry.format_count(effort["run_count"])}</td>
                    <td class="numeric">{Telemetry.format_count(effort["turn_count"])}</td>
                    <td class="numeric">{Telemetry.format_duration(group_agent_time(effort, @metrics, @now))}</td>
                    <td class="numeric"><span>{Telemetry.format_token_total(effort)}</span><small>{Telemetry.format_token_breakdown(effort)}</small><span :if={Telemetry.partial?(effort)} class="badge waiting">{effort["token_usage_state"]}</span></td>
                  </tr>
                <% end %>
              <% end %>
            </tbody>
          </table>
        </div>
      </section>

      <section class="detail-card stats-section">
        <div class="section-heading">
          <div><p class="eyebrow">Current runtime</p><h2>Active sessions</h2></div>
          <span class="revision">oldest first</span>
        </div>
        <p :if={@metrics["active_runs"] == []} class="empty">No active Codex sessions.</p>
        <div :if={@metrics["active_runs"] != []} class="table-wrap">
          <table class="stats-table active-runs-table">
            <thead>
              <tr>
                <th>Task / stage</th>
                <th>Status</th>
                <th>Model / worker</th>
                <th>Elapsed / turns</th>
                <th>Tokens</th>
                <th>Latest activity</th>
                <th>Session</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={run <- @metrics["active_runs"]}>
                <td><a class="table-primary" href={"/tasks/#{run["task_identifier"]}"}>{run["task_identifier"]}</a><small>{run["stage_id"]}</small></td>
                <td><span class="badge running">{run["status"]}</span></td>
                <td><span>{run["model"]} · {run["effort"]}</span><small>{Telemetry.format_worker(run["worker_host"])}</small></td>
                <td class="numeric"><span>{Telemetry.format_duration(active_run_time(run, @metrics, @now))}</span><small>{run["effective_stats"]["turn_count"]} turns</small></td>
                <td class="numeric"><span>{Telemetry.format_token_total(run["effective_stats"]["token_usage"], if(run["effective_stats"]["token_usage"], do: "complete", else: "unavailable"))}</span><small>{Telemetry.format_usage_breakdown(run["effective_stats"]["token_usage"])}</small></td>
                <td><span>{get_in(run, ["activity", "summary"]) || "Waiting for Codex activity"}</span><small>{get_in(run, ["activity", "at"]) || "—"}</small></td>
                <td>
                  <button
                    :if={run["session_id"]}
                    id={"copy-session-#{run["run_id"]}"}
                    type="button"
                    class="subtle-button"
                    phx-hook="CopyValue"
                    data-copy={run["session_id"]}
                  >Copy ID</button>
                  <span :if={!run["session_id"]} class="muted">—</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="detail-card stats-section">
        <div class="section-heading">
          <div><p class="eyebrow">Current service session</p><h2>Rate limits by worker</h2></div>
        </div>
        <p :if={@metrics["runtime"]["rate_limits"] == []} class="empty">No rate-limit snapshot has been observed since the orchestrator started.</p>
        <div class="rate-limit-grid">
          <article :for={entry <- @metrics["runtime"]["rate_limits"]} class="rate-limit-card">
            <div class="run-heading"><strong>{entry["worker"]}</strong><time>{entry["observed_at"]}</time></div>
            <pre>{rate_limit_json(entry["limits"])}</pre>
          </article>
        </div>
      </section>

      <section class="detail-card stats-section">
        <div class="section-heading">
          <div><p class="eyebrow">All durable history</p><h2>Usage by task</h2></div>
          <span class="revision">highest known token spend first</span>
        </div>
        <p :if={@metrics["tasks"] == []} class="empty">No tasks yet.</p>
        <div :if={@metrics["tasks"] != []} class="table-wrap">
          <table class="stats-table task-usage-table">
            <thead><tr><th>Task</th><th>State</th><th>Runs</th><th>Turns</th><th>Agent time</th><th>Tokens</th></tr></thead>
            <tbody>
              <tr :for={task <- @metrics["tasks"]}>
                <td><a class="table-primary" href={"/tasks/#{task["task_identifier"]}"}>{task["task_identifier"]} · {task["title"]}</a></td>
                <td><span class="badge">{task["column_id"]}</span><span :if={task["archived"]} class="badge archived">Archived</span></td>
                <td class="numeric">{task["run_count"]}</td>
                <td class="numeric">{task["turn_count"]}</td>
                <td class="numeric">{Telemetry.format_duration(task_agent_time(task, @metrics, @now))}</td>
                <td class="numeric"><span>{Telemetry.format_token_total(task)}</span><small>{Telemetry.format_token_breakdown(task)}</small><span :if={Telemetry.partial?(task)} class="badge waiting">{task["token_usage_state"]}</span></td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </section>
    """
  end

  defp load(socket), do: assign(socket, :metrics, Board.metrics_for_stats())

  defp project_agent_time(metrics, now) do
    Telemetry.live_duration_ms(
      metrics["project"]["agent_duration_ms"],
      metrics["generated_at"],
      now,
      metrics["counts"]["active_run_count"]
    )
  end

  defp project_age(metrics, now) do
    Telemetry.advancing_duration_ms(metrics["project"]["age_ms"], metrics["generated_at"], now)
  end

  defp service_uptime(metrics, now) do
    Telemetry.advancing_duration_ms(metrics["runtime"]["uptime_ms"], metrics["generated_at"], now)
  end

  defp active_run_time(run, metrics, now) do
    Telemetry.advancing_duration_ms(run["effective_stats"]["duration_ms"], metrics["generated_at"], now)
  end

  defp task_agent_time(task, metrics, now) do
    Telemetry.live_duration_ms(
      task["agent_duration_ms"],
      metrics["generated_at"],
      now,
      task["active_run_count"]
    )
  end

  defp group_agent_time(group, metrics, now) do
    Telemetry.live_duration_ms(
      group["agent_duration_ms"],
      metrics["generated_at"],
      now,
      group["active_run_count"]
    )
  end

  defp model_label(nil), do: "Unknown model"
  defp model_label(model), do: model
  defp stage_label(nil), do: "Unknown stage"
  defp stage_label(stage), do: stage
  defp effort_label(nil), do: "Unknown effort"
  defp effort_label(effort), do: effort

  defp stage_accessible_label(model, stage) do
    "#{model_label(model)}, #{stage_label(stage)} stage"
  end

  defp effort_accessible_label(model, stage, effort) do
    "#{model_label(model)}, #{stage_label(stage)} stage, #{effort_label(effort)} effort"
  end

  defp rate_limit_json(limits), do: Jason.encode!(limits, pretty: true)
  defp schedule_runtime_tick, do: Process.send_after(self(), :metrics_tick, @runtime_tick_ms)
end
