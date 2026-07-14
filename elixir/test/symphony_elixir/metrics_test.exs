defmodule SymphonyElixir.MetricsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Board.Metrics
  alias SymphonyElixir.Codex.Activity
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Task

  test "aggregates canonical and live accounting across active and archived tasks" do
    now = ~U[2026-07-13 12:00:00Z]
    active_task = task("task-active", "SYM-1", "in_progress")
    archived_task = task("task-archived", "SYM-2", "done", "2026-07-13T11:59:30Z")
    blocked_task = task("task-blocked", "SYM-3", "blocked")

    terminal_run = %{
      "id" => "run-terminal",
      "task_id" => active_task.id,
      "task_identifier" => active_task.identifier,
      "stage_id" => "implementation",
      "status" => "completed",
      "model" => "gpt-5",
      "effort" => "high",
      "claimed_at" => "2026-07-13T11:58:50Z",
      "started_at" => "2026-07-13T11:59:00Z",
      "finished_at" => "2026-07-13T11:59:10Z",
      "stats" => %{
        "duration_ms" => 10_000,
        "turn_count" => 2,
        "token_usage" => usage(100, 60, 20, 120)
      }
    }

    active_run = %{
      "id" => "run-active",
      "task_id" => active_task.id,
      "task_identifier" => active_task.identifier,
      "stage_id" => "review",
      "status" => "running",
      "model" => "gpt-5",
      "effort" => "medium",
      "worker_host" => "worker-a",
      "claimed_at" => "2026-07-13T11:59:35Z",
      "started_at" => "2026-07-13T11:59:40Z"
    }

    archived_run = %{
      "id" => "run-archived",
      "task_id" => archived_task.id,
      "task_identifier" => archived_task.identifier,
      "stage_id" => "implementation",
      "status" => "failed",
      "model" => "gpt-5",
      "effort" => "low",
      "claimed_at" => "2026-07-13T11:58:00Z",
      "started_at" => "2026-07-13T11:58:05Z",
      "finished_at" => "2026-07-13T11:58:10Z",
      "stats" => %{"duration_ms" => 5_000, "turn_count" => 0, "token_usage" => nil}
    }

    telemetry = %{
      "run-active" => %{
        "thread_id" => "thread-live",
        "turn_ids" => ["turn-1", "turn-2"],
        "token_usage" => usage(50, 20, 10, 60)
      }
    }

    rate_limits = [%{"worker" => "worker-a", "observed_at" => "2026-07-13T11:59:50Z", "limits" => %{}}]

    runtime = %{
      online: true,
      started_at: "2026-07-13T11:59:00Z",
      rate_limits: rate_limits,
      running: [
        %{
          run_id: "run-active",
          session_id: "thread-live",
          last_activity: "command started",
          last_activity_at: "2026-07-13T11:59:55Z"
        }
      ]
    }

    runs = [terminal_run, active_run, archived_run]

    build =
      Metrics.build(
        [active_task, archived_task, blocked_task],
        runs,
        telemetry,
        runtime,
        %{blocked: "blocked", done: "done"},
        now
      )

    snapshot = build.snapshot

    assert snapshot["counts"] == %{
             "task_count" => 3,
             "archived_task_count" => 1,
             "active_run_count" => 1,
             "blocked_task_count" => 1,
             "completed_task_count" => 1,
             "run_count" => 3,
             "session_count" => 1,
             "turn_count" => 4
           }

    assert snapshot["project"]["agent_duration_ms"] == 35_000
    assert snapshot["project"]["age_ms"] == 120_000
    assert snapshot["project"]["token_usage_state"] == "partial"
    assert snapshot["project"]["unknown_token_run_count"] == 1
    assert snapshot["project"]["token_usage"] == usage(150, 80, 30, 180)
    assert snapshot["runtime"]["uptime_ms"] == 60_000
    assert snapshot["runtime"]["rate_limits"] == rate_limits

    assert [live] = snapshot["active_runs"]
    assert live["session_id"] == "thread-live"
    assert live["effective_stats"]["duration_ms"] == 20_000
    assert live["effective_stats"]["turn_count"] == 2
    assert live["activity"] == %{"summary" => "command started", "at" => "2026-07-13T11:59:55Z"}

    assert [model] = snapshot["models"]
    assert model["session_count"] == 1
    assert model["active_session_count"] == 1

    task_summary = build.task_summaries[active_task.id]
    assert task_summary["token_usage_state"] == "complete"
    assert task_summary["token_usage"] == usage(150, 80, 30, 180)
    assert task_summary["agent_duration_ms"] == 30_000

    assert {:ok, presented} = Metrics.task_metrics(build, active_task.id, [active_run, terminal_run])
    assert presented["generated_at"] == snapshot["generated_at"]
    assert hd(presented["runs"])["effective_stats"]["source"] == "live"
    assert List.last(presented["runs"])["stats"] == terminal_run["stats"]
    refute Map.has_key?(List.last(presented["runs"]), "activity")
  end

  test "groups exact models by stage and deduplicates completed tasks and sessions" do
    now = ~U[2026-07-13 12:00:00Z]
    completed_task = task("completed-models", "SYM-20", "done")
    active_task = task("active-models", "SYM-21", "in_progress")
    cancelled_task = task("cancelled-models", "SYM-22", "cancelled")

    runs = [
      run("alpha-implementation", completed_task, "alpha", "implementation", "thread-shared", usage(80, 40, 20, 100)),
      run("alpha-review", completed_task, "alpha", "review", "thread-shared", usage(160, 80, 40, 200)),
      run("beta-merging", completed_task, "beta", "merging", "thread-beta", usage(240, 120, 60, 300)),
      run("alpha-prestart", active_task, "alpha", "implementation", nil, usage(320, 160, 80, 400), "failed")
      |> Map.put("started_at", nil),
      run("beta-cancelled", cancelled_task, "beta", "merging", nil, nil, "stopped"),
      run("unknown-model", active_task, nil, nil, "thread-unknown", usage(40, 20, 10, 50), "running")
    ]

    build =
      Metrics.build(
        [completed_task, active_task, cancelled_task],
        runs,
        %{},
        %{online: false, running: []},
        %{blocked: "blocked", done: "done"},
        now
      )

    assert build.snapshot["counts"]["completed_task_count"] == 1
    assert build.snapshot["counts"]["session_count"] == 3
    assert Enum.map(build.snapshot["models"], & &1["model"]) == ["alpha", "beta", nil]

    alpha = Enum.find(build.snapshot["models"], &(&1["model"] == "alpha"))
    assert alpha["task_count"] == 2
    assert alpha["completed_task_count"] == 1
    assert alpha["session_count"] == 1
    assert alpha["active_session_count"] == 0
    assert alpha["run_count"] == 3
    assert alpha["token_usage"] == usage(560, 280, 140, 700)
    assert alpha["token_usage_state"] == "complete"
    assert Enum.map(alpha["stages"], & &1["stage_id"]) == ["implementation", "review"]

    implementation = Enum.find(alpha["stages"], &(&1["stage_id"] == "implementation"))
    review = Enum.find(alpha["stages"], &(&1["stage_id"] == "review"))
    assert implementation["task_count"] == 2
    assert implementation["completed_task_count"] == 1
    assert review["task_count"] == 1
    assert review["completed_task_count"] == 1

    beta = Enum.find(build.snapshot["models"], &(&1["model"] == "beta"))
    assert beta["task_count"] == 2
    assert beta["completed_task_count"] == 1
    assert beta["session_count"] == 1
    assert beta["active_session_count"] == 0
    assert beta["token_usage"] == usage(240, 120, 60, 300)
    assert beta["token_usage_state"] == "partial"

    unknown = List.last(build.snapshot["models"])
    assert unknown["model"] == nil
    assert [%{"stage_id" => nil}] = unknown["stages"]
    assert unknown["session_count"] == 1
    assert unknown["active_session_count"] == 1
    assert hd(unknown["stages"])["active_session_count"] == 1
  end

  test "separates efforts under each model stage without changing the public snapshot" do
    now = ~U[2026-07-13 12:00:00Z]
    completed_task = task("effort-completed", "SYM-25", "done")
    active_task = task("effort-active", "SYM-26", "in_progress")

    high_effort =
      run("effort-high", completed_task, "alpha", "implementation", "thread-high", usage(80, 40, 20, 100))

    low_effort =
      run("effort-low", completed_task, "alpha", "implementation", "thread-low", usage(160, 80, 40, 200))
      |> Map.put("effort", "low")

    unknown_effort =
      run("effort-unknown", active_task, "alpha", "implementation", "thread-unknown", nil, "running")
      |> Map.put("effort", nil)

    build =
      Metrics.build(
        [completed_task, active_task],
        [high_effort, low_effort, unknown_effort],
        %{},
        %{online: false, running: []},
        %{blocked: "blocked", done: "done"},
        now
      )

    public_alpha = hd(build.snapshot["models"])
    public_stage = hd(public_alpha["stages"])
    refute Map.has_key?(public_stage, "efforts")

    ui_alpha = hd(build.ui_snapshot["models"])
    ui_stage = hd(ui_alpha["stages"])
    assert ui_stage["run_count"] == 3
    assert ui_stage["task_count"] == 2
    assert ui_stage["completed_task_count"] == 1
    assert ui_stage["session_count"] == 3
    assert ui_stage["token_usage"] == usage(240, 120, 60, 300)
    assert ui_stage["token_usage_state"] == "partial"

    assert Enum.map(ui_stage["efforts"], & &1["effort"]) == ["low", "high", nil]

    low = Enum.find(ui_stage["efforts"], &(&1["effort"] == "low"))
    high = Enum.find(ui_stage["efforts"], &(&1["effort"] == "high"))
    unknown = Enum.find(ui_stage["efforts"], &is_nil(&1["effort"]))

    assert low["token_usage"] == usage(160, 80, 40, 200)
    assert low["token_usage_state"] == "complete"
    assert low["completed_task_count"] == 1
    assert high["token_usage"] == usage(80, 40, 20, 100)
    assert high["completed_task_count"] == 1
    assert unknown["token_usage"] == nil
    assert unknown["token_usage_state"] == "unavailable"
    assert unknown["completed_task_count"] == 0
    assert ui_alpha["token_usage"] == usage(240, 120, 60, 300)
  end

  test "credits completed tasks only to models whose runs started" do
    now = ~U[2026-07-13 12:00:00Z]
    completed_task = task("completed-after-retry", "SYM-23", "done")

    failed_prestart =
      run("alpha-prestart", completed_task, "alpha", "implementation", nil, nil, "failed")
      |> Map.put("started_at", nil)

    completed =
      run("beta-completed", completed_task, "beta", "implementation", "thread-beta", usage(80, 40, 20, 100))

    build =
      Metrics.build(
        [completed_task],
        [failed_prestart, completed],
        %{},
        %{online: false, running: []},
        %{blocked: "blocked", done: "done"},
        now
      )

    alpha = Enum.find(build.snapshot["models"], &(&1["model"] == "alpha"))
    beta = Enum.find(build.snapshot["models"], &(&1["model"] == "beta"))

    assert build.snapshot["counts"]["completed_task_count"] == 1
    assert alpha["completed_task_count"] == 0
    assert hd(alpha["stages"])["completed_task_count"] == 0
    assert beta["completed_task_count"] == 1
    assert hd(beta["stages"])["completed_task_count"] == 1
  end

  test "counts distinct active sessions separately from active runs" do
    now = ~U[2026-07-13 12:00:00Z]
    active_task = task("active-sessions", "SYM-24", "in_progress")

    runs = [
      run("active-session-one", active_task, "alpha", "implementation", "thread-active", nil, "running"),
      run("active-session-two", active_task, "alpha", "review", "thread-active", nil, "stopping"),
      run("active-without-session", active_task, "alpha", "implementation", nil, nil, "starting"),
      run("terminal-session", active_task, "alpha", "merging", "thread-terminal", nil)
    ]

    build =
      Metrics.build(
        [active_task],
        runs,
        %{},
        %{online: false, running: []},
        %{blocked: "blocked", done: "done"},
        now
      )

    assert [alpha] = build.snapshot["models"]
    assert alpha["session_count"] == 2
    assert alpha["active_run_count"] == 3
    assert alpha["active_session_count"] == 1

    implementation = Enum.find(alpha["stages"], &(&1["stage_id"] == "implementation"))
    assert implementation["active_run_count"] == 2
    assert implementation["active_session_count"] == 1
  end

  test "distinguishes empty, explicit-zero, and unavailable token usage" do
    now = ~U[2026-07-13 12:00:00Z]
    empty_task = task("empty", "SYM-10", "backlog")
    zero_task = task("zero", "SYM-11", "done")

    zero_run = %{
      "id" => "zero-run",
      "task_id" => zero_task.id,
      "task_identifier" => zero_task.identifier,
      "stage_id" => "implementation",
      "status" => "completed",
      "claimed_at" => "2026-07-13T11:59:00Z",
      "finished_at" => "2026-07-13T11:59:01Z",
      "stats" => %{"duration_ms" => 1_000, "turn_count" => 1, "token_usage" => usage(0, 0, 0, 0)}
    }

    build =
      Metrics.build(
        [empty_task, zero_task],
        [zero_run],
        %{},
        %{online: false, running: []},
        %{blocked: "blocked", done: "done"},
        now
      )

    assert build.task_summaries[empty_task.id]["token_usage"] == usage(0, 0, 0, 0)
    assert build.task_summaries[empty_task.id]["token_usage_state"] == "complete"
    assert build.task_summaries[zero_task.id]["token_usage"] == usage(0, 0, 0, 0)
    assert build.task_summaries[zero_task.id]["token_usage_state"] == "complete"
  end

  test "terminal canonical stats replace leftover live telemetry without double counting" do
    now = ~U[2026-07-13 12:00:00Z]
    completed_task = task("completed", "SYM-12", "done")

    run = %{
      "id" => "handoff-run",
      "task_id" => completed_task.id,
      "task_identifier" => completed_task.identifier,
      "stage_id" => "implementation",
      "status" => "completed",
      "claimed_at" => "2026-07-13T11:59:00Z",
      "started_at" => "2026-07-13T11:59:10Z",
      "finished_at" => "2026-07-13T11:59:30Z",
      "stats" => %{"duration_ms" => 20_000, "turn_count" => 2, "token_usage" => usage(100, 60, 20, 120)}
    }

    stale_telemetry = %{
      "handoff-run" => %{
        "thread_id" => "thread-handoff",
        "turn_ids" => ["turn-1"],
        "token_usage" => usage(80, 50, 10, 90)
      }
    }

    build =
      Metrics.build(
        [completed_task],
        [run],
        stale_telemetry,
        %{online: false, running: []},
        %{blocked: "blocked", done: "done"},
        now
      )

    summary = build.task_summaries[completed_task.id]

    assert summary["run_count"] == 1
    assert summary["turn_count"] == 2
    assert summary["agent_duration_ms"] == 20_000
    assert summary["token_usage"] == usage(100, 60, 20, 120)
    assert build.run_metrics["handoff-run"]["effective_stats"]["source"] == "canonical"
  end

  test "activity summaries omit raw payloads and normalize rate limits" do
    update = %{
      event: :notification,
      payload: %{
        "method" => "item/commandExecution/outputDelta",
        "params" => %{"delta" => "SECRET OUTPUT\n\e[31m"}
      }
    }

    assert Activity.summary(update) == "command output streaming"
    refute Activity.summary(update) =~ "SECRET"

    unknown = %{
      event: "SECRET\nEVENT",
      payload: %{"method" => "secret/method\e[31m", "params" => %{"prompt" => "must-not-leak"}}
    }

    assert Activity.summary(unknown) == "Codex activity"
    refute Activity.summary(unknown) =~ "SECRET"

    assert Activity.summary(%{payload: %{"method" => "item/started", "params" => %{"item" => %{"type" => "secret prompt"}}}}) ==
             "item started"

    rate_update = %{
      payload: %{
        "method" => "account/rateLimits/updated",
        "params" => %{
          "rateLimits" => %{
            "limitId" => "codex",
            "primary" => %{"usedPercent" => 25, "windowDurationMins" => 300, "resetsAt" => 123},
            "credits" => %{"hasCredits" => false, "unlimited" => false, "balance" => 0},
            "authToken" => "must-not-leak"
          }
        }
      }
    }

    assert Activity.rate_limits(rate_update) == %{
             "limit_id" => "codex",
             "primary" => %{"used_percent" => 25, "window_duration_mins" => 300, "reset_at" => 123},
             "credits" => %{"has_credits" => false, "unlimited" => false, "balance" => 0}
           }
  end

  test "orchestrator retains safe activity and coalesces per-run broadcasts" do
    runtime = %{
      run_id: "run-live",
      worker_host: "worker-a",
      workspace_path: "/tmp/worktree",
      session: nil,
      last_activity: nil,
      last_activity_at: nil,
      stopping: false
    }

    state = %Orchestrator.State{
      started_at: "2026-07-13T11:59:00Z",
      running: %{"task-live" => runtime}
    }

    update = %{
      event: :notification,
      timestamp: ~U[2026-07-13 12:00:00Z],
      payload: %{
        "method" => "account/rateLimits/updated",
        "params" => %{"rateLimits" => %{"primary" => %{"remaining" => 80, "limit" => 100}}}
      }
    }

    assert {:noreply, updated} = Orchestrator.handle_info({:runner_update, "task-live", "run-live", update}, state)
    assert updated.running["task-live"].last_activity == "rate limits updated"
    assert get_in(updated.rate_limits, ["worker-a", "limits", "primary", "remaining"]) == 80
    assert MapSet.to_list(updated.telemetry_broadcasts) == ["run-live"]

    assert {:noreply, coalesced} = Orchestrator.handle_info({:runner_update, "task-live", "run-live", update}, updated)
    assert MapSet.to_list(coalesced.telemetry_broadcasts) == ["run-live"]

    assert_receive {:broadcast_run_update, "run-live"}, 500
    refute_receive {:broadcast_run_update, "run-live"}, 75

    assert {:reply, status, _state} = Orchestrator.handle_call(:status, self(), coalesced)
    assert status.online
    assert status.started_at == "2026-07-13T11:59:00Z"
    assert hd(status.running).last_activity == "rate limits updated"
    refute Map.has_key?(hd(status.running), :last_update)

    restarted = %Orchestrator.State{started_at: "2026-07-13T12:01:00Z"}
    assert restarted.rate_limits == %{}
    assert restarted.running == %{}
  end

  defp task(id, identifier, column_id, archived_at \\ nil) do
    %Task{
      id: id,
      identifier: identifier,
      number: identifier |> String.replace("SYM-", "") |> String.to_integer(),
      project_id: "symphony",
      title: "Task #{identifier}",
      type: :feature,
      branch: "feature/#{identifier}",
      priority: :normal,
      brief: "Brief",
      acceptance_criteria: [],
      column_id: column_id,
      rank: 1_024,
      revision: 1,
      created_at: "2026-07-13T11:00:00Z",
      updated_at: "2026-07-13T11:00:00Z",
      archived_at: archived_at
    }
  end

  defp usage(input, cached, output, total) do
    %{
      "input_tokens" => input,
      "cached_input_tokens" => cached,
      "output_tokens" => output,
      "total_tokens" => total
    }
  end

  defp run(id, task, model, stage_id, session_id, token_usage, status \\ "completed") do
    %{
      "id" => id,
      "task_id" => task.id,
      "task_identifier" => task.identifier,
      "stage_id" => stage_id,
      "status" => status,
      "model" => model,
      "effort" => "high",
      "session_id" => session_id,
      "claimed_at" => "2026-07-13T11:59:00Z",
      "started_at" => "2026-07-13T11:59:00Z",
      "finished_at" => "2026-07-13T11:59:01Z",
      "stats" => %{"duration_ms" => 1_000, "turn_count" => 1, "token_usage" => token_usage}
    }
  end
end
