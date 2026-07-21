defmodule SymphonyElixir.CurrentState do
  @moduledoc """
  Projects the bounded current task state shared by prompts and dynamic tools.

  This is an explicit allowlist. Canonical task/run maps contain durable history,
  raw provider payloads, and frozen execution contracts that must not be copied
  into model context.
  """

  alias SymphonyElixir.{Board, JobManager, Orchestrator, Task}
  alias SymphonyElixir.Workflow.Bundle

  @task_fields ~w(id identifier title type priority brief branch column_id revision)
  @run_fields ~w(id stage_id status backend model effort worker_host claimed_at started_at updated_at)
  @source_fields ~w(head_sha base_sha clean)
  @github_fields ~w(number url state draft head_sha)
  @preflight_fields ~w(status phase fingerprint reason started_at last_activity_at completed_at next_retry_at)
  @job_fields ~w(job_id job status started_at finished_at elapsed_ms source_fingerprint)
  @attestation_fields ~w(verdict reviewed_head_sha route feedback_fingerprint checks_fingerprint criteria_fingerprint pull_request_number reviewer_identity run_id reviewed_at)
  @plan_policy_fields ~w(status summary)
  @validation_evidence_fields ~w(command result artifact exit_status)
  @finding_fields ~w(severity summary path line)
  @merge_conflict_fields ~w(id task_head target_head conflicted_paths recorded_at)

  @spec project(Task.t(), map(), Bundle.t() | map(), keyword()) :: map()
  def project(%Task{} = task, run, workflow, opts \\ []) when is_map(run) do
    %{
      "task" => task_projection(task),
      "run" => take_present(run, @run_fields),
      "source" => take_present(task.source, @source_fields),
      "github" => github_projection(task.github),
      "review_attestation" => review_attestation_projection(task.review_attestation),
      "merge_conflict" => merge_conflict_projection(task.merge_saga),
      "criteria" => Enum.map(task.acceptance_criteria, &criterion_projection/1),
      "dependencies" => dependency_projections(task.dependencies, workflow),
      "allowed_transitions" => allowed_transition_projections(task.column_id, workflow),
      "preflight" => preflight_projection(task.id, opts),
      "job" => job_projection(run, opts)
    }
    |> reject_nil_values()
  end

  defp task_projection(task) do
    task
    |> Task.to_map()
    |> take_present(@task_fields)
    |> maybe_put_block(task)
  end

  defp maybe_put_block(projected, task) do
    block =
      %{
        "from_column_id" => task.blocked_from_column_id,
        "reason" => task.metadata["blocked_reason"]
      }
      |> reject_nil_values()

    if map_size(block) == 0, do: projected, else: Map.put(projected, "block", block)
  end

  defp github_projection(github) do
    github
    |> take_present(@github_fields)
    |> maybe_put("ready", get_in(github, ["ready", "completed"]))
    |> maybe_put("merged", get_in(github, ["merged", "merged"]))
    |> maybe_put("merge_sha", get_in(github, ["merged", "merge_sha"]))
    |> maybe_put("reachable", get_in(github, ["merged", "merge_reachable"]))
  end

  defp criterion_projection(criterion) do
    take_present(criterion, ~w(id text completed evidence))
  end

  defp review_attestation_projection(attestation) when is_map(attestation) do
    attestation
    |> take_present(@attestation_fields)
    |> maybe_put("plan_policy", nested_projection(attestation["plan_policy"], @plan_policy_fields))
    |> maybe_put("validation_evidence", nested_list_projection(attestation["validation_evidence"], @validation_evidence_fields))
    |> maybe_put("findings", nested_list_projection(attestation["findings"], @finding_fields))
    |> reject_nil_values()
  end

  defp review_attestation_projection(_attestation), do: nil

  defp merge_conflict_projection(%{"checkpoint" => "conflict_recorded", "last_conflict" => conflict})
       when is_map(conflict),
       do: take_present(conflict, @merge_conflict_fields)

  defp merge_conflict_projection(_saga), do: nil

  defp nested_projection(value, fields) when is_map(value), do: take_present(value, fields)
  defp nested_projection(_value, _fields), do: nil

  defp nested_list_projection(values, fields) when is_list(values), do: Enum.map(values, &take_present(&1, fields))
  defp nested_list_projection(_values, _fields), do: nil

  defp dependency_projections(ids, workflow) do
    Enum.flat_map(ids, fn id ->
      case Board.task(id) do
        {:ok, dependency} ->
          [
            %{
              "id" => dependency.id,
              "identifier" => dependency.identifier,
              "title" => dependency.title,
              "column_id" => dependency.column_id,
              "satisfied" => satisfies_dependencies?(dependency.column_id, workflow)
            }
          ]

        {:error, _reason} ->
          []
      end
    end)
  end

  defp allowed_transition_projections(column_id, workflow) do
    allowed_ids = workflow_transitions(workflow)[column_id] || []

    workflow
    |> workflow_columns()
    |> Enum.filter(&(column_value(&1, "id") in allowed_ids))
    |> Enum.map(fn column ->
      %{
        "id" => column_value(column, "id"),
        "name" => column_value(column, "name"),
        "role" => column_value(column, "role") |> stringify_atom()
      }
    end)
  end

  defp satisfies_dependencies?(column_id, workflow) do
    workflow
    |> workflow_columns()
    |> Enum.find(&(column_value(&1, "id") == column_id))
    |> case do
      nil -> false
      column -> column_value(column, "satisfies_dependencies") == true
    end
  end

  defp preflight_projection(task_id, opts) do
    opts
    |> Keyword.get_lazy(:preflights, fn ->
      current_preflights(Keyword.get(opts, :orchestrator_status, &Orchestrator.status/0))
    end)
    |> Enum.find(&(value(&1, "task_id") == task_id))
    |> case do
      nil ->
        nil

      preflight ->
        preflight
        |> take_present(@preflight_fields)
        |> Map.update("status", nil, &stringify_atom/1)
        |> Map.update("phase", nil, &stringify_atom/1)
        |> reject_nil_values()
    end
  end

  defp current_preflights(status_provider) do
    status_provider.()[:preflights] || []
  catch
    :exit, _reason -> []
  end

  defp job_projection(run, opts) do
    job = active_job(run["id"], Keyword.get(opts, :job_manager, JobManager))

    case job do
      job when is_map(job) -> take_present(job, @job_fields)
      _ -> nil
    end
  end

  defp active_job(run_id, server) do
    JobManager.active_for_run(run_id, server)
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  defp workflow_columns(%Bundle{columns: columns}), do: columns
  defp workflow_columns(%{"columns" => columns}) when is_list(columns), do: columns
  defp workflow_columns(_workflow), do: []

  defp workflow_transitions(%Bundle{agent_transitions: transitions}), do: transitions
  defp workflow_transitions(%{"agent_transitions" => transitions}) when is_map(transitions), do: transitions
  defp workflow_transitions(_workflow), do: %{}

  defp column_value(%_{} = column, key), do: Map.get(column, String.to_existing_atom(key))
  defp column_value(column, key) when is_map(column), do: value(column, key)

  defp take_present(map, fields) when is_map(map) do
    Map.new(fields, fn field -> {field, value(map, field)} end)
    |> reject_nil_values()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, String.to_existing_atom(key)))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp stringify_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_atom(value), do: value
end
