defmodule SymphonyElixir.Board.Metrics do
  @moduledoc """
  Builds read-only project, task, and effective run accounting snapshots.

  Canonical terminal run statistics remain authoritative. Active runs overlay
  the transient SQLite telemetry high-water mark and elapsed wall-clock time.
  """

  alias SymphonyElixir.Codex.RunStats
  alias SymphonyElixir.Task

  @active_statuses ["starting", "running", "stopping"]
  @zero_usage %{
    "input_tokens" => 0,
    "cached_input_tokens" => 0,
    "output_tokens" => 0,
    "total_tokens" => 0
  }

  @type build_result :: %{
          required(:snapshot) => map(),
          required(:task_summaries) => %{optional(String.t()) => map()},
          required(:run_metrics) => %{optional(String.t()) => map()}
        }

  @spec build([Task.t()], [map()], %{optional(String.t()) => map()}, map(), String.t() | nil, DateTime.t()) ::
          build_result()
  def build(tasks, runs, telemetry, runtime, blocked_column_id, %DateTime{} = now)
      when is_list(tasks) and is_list(runs) and is_map(telemetry) and is_map(runtime) do
    task_by_id = Map.new(tasks, &{&1.id, &1})
    runtime_by_run = runtime_by_run(runtime)

    run_metrics =
      Map.new(runs, fn run ->
        metric = effective_run(run, telemetry[run["id"]], runtime_by_run[run["id"]], task_by_id[run["task_id"]], now)
        {run["id"], metric}
      end)

    metrics_by_task = Enum.group_by(Map.values(run_metrics), & &1["task_id"])

    task_summaries =
      Map.new(tasks, fn task ->
        summary = task_summary(task, Map.get(metrics_by_task, task.id, []))
        {task.id, summary}
      end)

    project_runs = Map.values(run_metrics)
    project_accounting = aggregate(project_runs)
    first_run_at = earliest_claimed_at(runs)

    counts = %{
      "task_count" => length(tasks),
      "archived_task_count" => Enum.count(tasks, &Task.archived?/1),
      "active_run_count" => Enum.count(project_runs, & &1["active"]),
      "blocked_task_count" => blocked_task_count(tasks, blocked_column_id),
      "run_count" => length(project_runs),
      "turn_count" => project_accounting["turn_count"]
    }

    project =
      project_accounting
      |> Map.put("first_run_at", first_run_at)
      |> Map.put("age_ms", elapsed_ms(first_run_at, now))

    snapshot = %{
      "generated_at" => iso8601(now),
      "counts" => counts,
      "project" => project,
      "runtime" => runtime_summary(runtime, now),
      "active_runs" => active_runs(project_runs),
      "tasks" => sorted_task_summaries(Map.values(task_summaries))
    }

    %{snapshot: snapshot, task_summaries: task_summaries, run_metrics: run_metrics}
  end

  @spec task_metrics(build_result(), String.t(), [map()]) :: {:ok, map()} | {:error, :not_found}
  def task_metrics(build, task_id, runs) when is_map(build) and is_binary(task_id) and is_list(runs) do
    case build.task_summaries[task_id] do
      nil ->
        {:error, :not_found}

      summary ->
        presented_runs =
          Enum.map(runs, fn run ->
            metric = build.run_metrics[run["id"]]

            run
            |> Map.put("effective_stats", metric["effective_stats"])
            |> put_optional_activity(metric["activity"])
          end)

        {:ok,
         %{
           "generated_at" => build.snapshot["generated_at"],
           "stats" => summary,
           "runs" => presented_runs
         }}
    end
  end

  defp effective_run(run, telemetry, runtime, task, now) do
    active = run["status"] in @active_statuses
    effective_stats = if active, do: live_stats(run, telemetry, now), else: terminal_stats(run)

    %{
      "run_id" => run["id"],
      "task_id" => run["task_id"],
      "task_identifier" => run["task_identifier"] || (task && task.identifier),
      "task_title" => task && task.title,
      "status" => run["status"],
      "stage_id" => run["stage_id"],
      "model" => run["model"],
      "effort" => run["effort"],
      "worker_host" => run["worker_host"],
      "session_id" => run["session_id"] || runtime_value(runtime, :session_id),
      "claimed_at" => run["claimed_at"],
      "started_at" => run["started_at"],
      "finished_at" => run["finished_at"],
      "active" => active,
      "effective_stats" => effective_stats,
      "activity" => activity(runtime)
    }
  end

  defp live_stats(run, telemetry, now) do
    summary = RunStats.summary(telemetry)

    %{
      "source" => "live",
      "duration_ms" => active_duration_ms(run, now),
      "turn_count" => non_negative_integer(summary["turn_count"]) || 0,
      "token_usage" => normalized_usage(summary["token_usage"])
    }
  end

  defp terminal_stats(run) do
    stats = run["stats"] || %{}

    %{
      "source" => "canonical",
      "duration_ms" => non_negative_integer(stats["duration_ms"]) || terminal_duration_ms(run) || 0,
      "turn_count" => non_negative_integer(stats["turn_count"]) || 0,
      "token_usage" => normalized_usage(stats["token_usage"])
    }
  end

  defp task_summary(task, metrics) do
    accounting = aggregate(metrics)

    accounting
    |> Map.merge(%{
      "task_id" => task.id,
      "task_identifier" => task.identifier,
      "title" => task.title,
      "column_id" => task.column_id,
      "archived" => Task.archived?(task),
      "active_run_count" => Enum.count(metrics, & &1["active"]),
      "last_run_at" => latest_run_at(metrics)
    })
  end

  defp aggregate(metrics) do
    usage_values = Enum.map(metrics, &get_in(&1, ["effective_stats", "token_usage"]))
    known_usage = Enum.filter(usage_values, &is_map/1)
    unknown_count = length(usage_values) - length(known_usage)

    {usage, state} = aggregate_usage(metrics, known_usage, unknown_count)

    %{
      "run_count" => length(metrics),
      "turn_count" => Enum.reduce(metrics, 0, &(get_in(&1, ["effective_stats", "turn_count"]) + &2)),
      "agent_duration_ms" => Enum.reduce(metrics, 0, &(get_in(&1, ["effective_stats", "duration_ms"]) + &2)),
      "token_usage" => usage,
      "token_usage_state" => state,
      "unknown_token_run_count" => unknown_count
    }
  end

  defp aggregate_usage([], _known, 0), do: {@zero_usage, "complete"}
  defp aggregate_usage(_metrics, [], _unknown), do: {nil, "unavailable"}

  defp aggregate_usage(_metrics, known, unknown) do
    usage =
      Enum.reduce(known, @zero_usage, fn current, acc ->
        Map.new(@zero_usage, fn {key, _zero} -> {key, acc[key] + current[key]} end)
      end)

    {usage, if(unknown == 0, do: "complete", else: "partial")}
  end

  defp active_runs(metrics) do
    metrics
    |> Enum.filter(& &1["active"])
    |> Enum.sort_by(&(&1["started_at"] || &1["claimed_at"] || ""))
  end

  defp sorted_task_summaries(summaries) do
    Enum.sort_by(summaries, fn summary ->
      total = get_in(summary, ["token_usage", "total_tokens"])
      known_rank = if is_integer(total), do: 0, else: 1
      {known_rank, -(total || 0), summary["task_identifier"]}
    end)
  end

  defp runtime_by_run(runtime) do
    runtime
    |> runtime_value(:running, [])
    |> Map.new(fn entry -> {runtime_value(entry, :run_id), entry} end)
  end

  defp runtime_summary(runtime, now) do
    started_at = runtime_value(runtime, :started_at)

    %{
      "online" => runtime_value(runtime, :online, false),
      "started_at" => started_at,
      "uptime_ms" => elapsed_ms(started_at, now),
      "rate_limits" => runtime_value(runtime, :rate_limits, [])
    }
  end

  defp activity(runtime) when is_map(runtime) do
    summary = runtime_value(runtime, :last_activity)
    at = runtime_value(runtime, :last_activity_at)

    if is_binary(summary) and summary != "", do: %{"summary" => summary, "at" => at}, else: nil
  end

  defp activity(_runtime), do: nil

  defp put_optional_activity(run, activity) when is_map(activity), do: Map.put(run, "activity", activity)
  defp put_optional_activity(run, _activity), do: Map.delete(run, "activity")

  defp active_duration_ms(run, now) do
    elapsed_ms(run["started_at"] || run["claimed_at"], now) || 0
  end

  defp terminal_duration_ms(run) do
    elapsed_between(run["started_at"] || run["claimed_at"], run["finished_at"])
  end

  defp elapsed_between(started_at, finished_at) do
    with {:ok, started} <- parse_datetime(started_at),
         {:ok, finished} <- parse_datetime(finished_at) do
      max(0, DateTime.diff(finished, started, :millisecond))
    else
      _ -> nil
    end
  end

  defp elapsed_ms(nil, _now), do: nil

  defp elapsed_ms(started_at, %DateTime{} = now) do
    case parse_datetime(started_at) do
      {:ok, started} -> max(0, DateTime.diff(now, started, :millisecond))
      _ -> nil
    end
  end

  defp earliest_claimed_at(runs) do
    runs
    |> Enum.map(&(&1["claimed_at"] || &1["started_at"]))
    |> Enum.filter(&is_binary/1)
    |> Enum.min(fn -> nil end)
  end

  defp latest_run_at(metrics) do
    metrics
    |> Enum.map(&(&1["finished_at"] || &1["started_at"] || &1["claimed_at"]))
    |> Enum.filter(&is_binary/1)
    |> Enum.max(fn -> nil end)
  end

  defp blocked_task_count(tasks, blocked_column_id) do
    Enum.count(tasks, fn task ->
      not Task.archived?(task) and task.column_id == (blocked_column_id || "blocked")
    end)
  end

  defp normalized_usage(usage) when is_map(usage) do
    keys = ~w(input_tokens cached_input_tokens output_tokens total_tokens)

    if Enum.all?(keys, &(is_integer(usage[&1]) and usage[&1] >= 0)) do
      Map.take(usage, keys)
    end
  end

  defp normalized_usage(_usage), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: nil

  defp parse_datetime(%DateTime{} = value), do: {:ok, value}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp parse_datetime(_value), do: :error

  defp runtime_value(map, key, default \\ nil)
  defp runtime_value(map, key, default) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp runtime_value(_map, _key, default), do: default

  defp iso8601(%DateTime{} = value), do: value |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
end
