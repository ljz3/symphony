defmodule SymphonyElixir.Board.Validator do
  @moduledoc false

  alias SymphonyElixir.AgentStage
  alias SymphonyElixir.Board.Commands
  alias SymphonyElixir.Board.Projection
  alias SymphonyElixir.Codex.RunStats
  alias SymphonyElixir.JobManager
  alias SymphonyElixir.ReviewAttestation
  alias SymphonyElixir.Task
  alias SymphonyElixir.Workflow.Bundle
  alias SymphonyElixir.Workflow.Bundle.Column

  @rank_gap 1_024
  @active_runtime_states ["starting", "running", "stopping"]

  @type mutation :: %{
          required(:event_type) => String.t(),
          required(:task_id) => String.t() | nil,
          required(:run_id) => String.t() | nil,
          required(:task_revision) => non_neg_integer(),
          required(:payload) => map(),
          required(:result) => map()
        }

  @spec validate(Commands.t(), map(), Bundle.t()) :: {:ok, mutation()} | {:error, term()}
  def validate(%Commands.CreateTask{attrs: attrs}, _actor, bundle) when is_map(attrs) do
    create_task(attrs, bundle)
  end

  def validate(%Commands.UpdateTask{task_id: task_id, attrs: attrs}, actor, bundle)
      when is_binary(task_id) and is_map(attrs) do
    with {:ok, task} <- Projection.get_task(task_id),
         :ok <- mutable_contract?(task, actor),
         :ok <- reject_immutable_fields(attrs),
         {:ok, updated} <- update_task(task, attrs, bundle, actor) do
      updated = invalidate_attestation_for_criteria(updated, bundle)
      mutation("task_updated", updated, nil)
    end
  end

  def validate(%Commands.MoveTask{} = command, actor, bundle) do
    with {:ok, task} <- Projection.get_task(command.task_id),
         {:ok, target} <- fetch_column(bundle, command.column_id) do
      move_task(task, target, command, actor, bundle)
    end
  end

  def validate(%Commands.ReorderTask{} = command, _actor, _bundle) do
    reorder_task(command)
  end

  def validate(%Commands.ArchiveTask{task_id: task_id}, _actor, bundle) do
    with {:ok, task} <- Projection.get_task(task_id),
         false <- Task.archived?(task),
         false <- active?(task),
         true <- Task.terminal?(task, bundle) do
      updated = bump(task, %{archived_at: now()})
      mutation("task_archived", updated, nil)
    else
      true -> {:error, :task_not_archivable}
      false -> {:error, :task_not_archivable}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(%Commands.CompleteAcceptance{} = command, actor, bundle) do
    with {:ok, task} <- Projection.get_task(command.task_id),
         :ok <- agent_evidence(actor, command.evidence),
         {:ok, criteria} <-
           complete_criterion(
             task.acceptance_criteria,
             command.criterion_id,
             command.evidence,
             actor
           ) do
      task = task |> bump(%{acceptance_criteria: criteria}) |> invalidate_attestation_for_criteria(bundle)
      mutation("acceptance_completed", task, nil)
    end
  end

  def validate(%Commands.ReopenAcceptance{} = command, actor, bundle) do
    with :ok <- human_actor(actor),
         {:ok, task} <- Projection.get_task(command.task_id),
         {:ok, criteria} <- reopen_criterion(task.acceptance_criteria, command.criterion_id, command.reason, actor) do
      task = task |> bump(%{acceptance_criteria: criteria}) |> invalidate_attestation_for_criteria(bundle)
      mutation("acceptance_reopened", task, nil)
    end
  end

  def validate(%Commands.BlockTask{} = command, _actor, bundle) do
    with {:ok, task} <- Projection.get_task(command.task_id),
         {:ok, reason} <- nonempty(command.reason, :block_reason) do
      block_task(task, reason, bundle, nil)
    end
  end

  def validate(%Commands.ResumeTask{task_id: task_id}, actor, bundle) do
    with :ok <- human_actor(actor),
         {:ok, task} <- Projection.get_task(task_id),
         %Column{id: blocked_id} <- Bundle.blocked_column(bundle),
         true <- task.column_id == blocked_id,
         target_id when is_binary(target_id) <- task.blocked_from_column_id,
         {:ok, _target} <- fetch_column(bundle, target_id) do
      updated =
        bump(task, %{
          column_id: target_id,
          blocked_from_column_id: nil,
          desired_column_id: nil,
          runtime_state: nil,
          active_run_id: nil,
          metadata: Map.delete(task.metadata, "blocked_reason")
        })

      mutation("task_resumed", updated, nil)
    else
      false -> {:error, :task_not_blocked}
      nil -> {:error, :missing_blocked_resume_column}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(%Commands.ClaimRun{} = command, actor, bundle) do
    with :ok <- system_actor(actor),
         {:ok, task} <- Projection.get_task(command.task_id),
         false <- Task.archived?(task),
         false <- active?(task),
         {:ok, column} <- fetch_column(bundle, task.column_id),
         :dispatch <- column.role,
         :ok <- conflict_claim_allowed(task, column, bundle),
         :ok <- dependencies_satisfied(task, bundle),
         {:ok, selection} <- fetch_stage_selection(task, column.stage_id, bundle),
         :ok <- validate_backend_worker(selection, command.worker_host, bundle) do
      claim_run(task, column, selection, command.worker_host, bundle)
    else
      true -> {:error, :task_not_dispatchable}
      false -> {:error, :task_not_dispatchable}
      role when is_atom(role) -> {:error, {:column_not_dispatchable, role}}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(%Commands.RunStarted{} = command, actor, _bundle) do
    with :ok <- system_actor(actor),
         {:ok, task} <- Projection.get_task(command.task_id),
         {:ok, run} <- Projection.get_run(command.run_id),
         :ok <- active_run(task, run),
         true <- run["status"] == "starting" do
      timestamp = now()

      run =
        Map.merge(run, %{
          "status" => "running",
          "session_id" => command.session_id,
          "workspace_path" => command.workspace_path,
          "started_at" => timestamp,
          "updated_at" => timestamp
        })

      task = bump(task, %{runtime_state: "running"})
      mutation("run_started", task, run)
    else
      false -> {:error, :run_not_starting}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(%Commands.RunFinished{} = command, actor, bundle) do
    with :ok <- system_actor(actor),
         {:ok, task} <- Projection.get_task(command.task_id),
         {:ok, run} <- Projection.get_run(command.run_id),
         :ok <- active_run(task, run) do
      finish_run(task, run, command.outcome || %{}, command.stats, bundle)
    end
  end

  def validate(%Commands.RunFailed{} = command, actor, bundle) do
    with {:ok, task} <- Projection.get_task(command.task_id),
         {:ok, run} <- Projection.get_run(command.run_id),
         :ok <- run_failure_actor(actor, run),
         :ok <- active_run(task, run) do
      block_task(task, inspect(command.reason), bundle, failed_run(run, command.reason, command.stats))
    end
  end

  def validate(%Commands.RecordSourceHead{} = command, actor, bundle) do
    with :ok <- system_or_agent_actor(actor),
         {:ok, task} <- Projection.get_task(command.task_id),
         true <- sha?(command.head_sha),
         true <- is_nil(command.base_sha) or sha?(command.base_sha) do
      source = %{
        "head_sha" => command.head_sha,
        "base_sha" => command.base_sha,
        "clean" => command.clean == true,
        "recorded_at" => now()
      }

      task =
        task
        |> bump(%{source: Map.merge(task.source, source)})
        |> invalidate_attestation_for_head(command.head_sha, bundle, "source_head_changed")

      mutation("source_head_recorded", task, nil)
    else
      false -> {:error, :invalid_source_sha}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(%Commands.LinkPullRequest{} = command, actor, bundle) do
    with :ok <- system_actor(actor),
         {:ok, task} <- Projection.get_task(command.task_id),
         {:ok, run} <- Projection.get_run(command.run_id),
         :ok <- active_run(task, run),
         true <- is_integer(command.number) and command.number > 0,
         true <- nonblank?(command.url),
         true <- sha?(command.head_sha) do
      github = %{
        "number" => command.number,
        "url" => command.url,
        "head_sha" => command.head_sha,
        "state" => command.state || "open",
        "draft" => command.draft == true,
        "linked_at" => now()
      }

      task =
        task
        |> bump(%{github: Map.merge(task.github, github)})
        |> invalidate_attestation_for_pull_request(command.number, command.head_sha, bundle)

      run = pull_request_creator_run(task.id, run, command.created_by_run_id)

      mutation("pull_request_linked", task, run)
    else
      false -> {:error, :invalid_pull_request_metadata}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(%Commands.RecordGitHubOutcome{} = command, actor, _bundle) do
    with :ok <- system_or_agent_actor(actor),
         {:ok, task} <- Projection.get_task(command.task_id),
         true <- nonblank?(command.kind),
         true <- is_map(command.attrs) do
      outcome = stringify_keys(command.attrs) |> Map.put("recorded_at", now())
      github = task.github |> Map.put(command.kind, outcome) |> project_github_outcome(command.kind, outcome)
      task = bump(task, %{github: github})

      external_effect = %{
        id: "#{task.id}:github:#{command.kind}",
        task_id: task.id,
        kind: "github_#{command.kind}",
        state: "completed",
        attrs: outcome,
        updated_at: outcome["recorded_at"]
      }

      mutation("github_#{command.kind}_recorded", task, nil, %{external_effect: external_effect})
    else
      false -> {:error, :invalid_github_outcome}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(%Commands.RecordReviewAttestation{} = command, actor, bundle) do
    with :ok <- agent_actor(actor),
         {:ok, task} <- Projection.get_task(command.task_id),
         {:ok, run} <- Projection.get_run(command.run_id),
         :ok <- active_run(task, run),
         {:ok, merge} <- configured_merge(bundle),
         :ok <- active_review_run(task, run, bundle, merge),
         :ok <- valid_review_attestation(command, task),
         :ok <- review_route(command, task, bundle, merge) do
      reviewed_at = now()

      attestation = %{
        "verdict" => command.verdict,
        "reviewed_head_sha" => command.reviewed_head_sha,
        "route" => command.route,
        "plan_policy" => stringify_keys(command.plan_policy),
        "validation_evidence" => stringify_keys(command.validation_evidence),
        "findings" => stringify_keys(command.findings),
        "feedback_fingerprint" => value(command.provider_snapshot, :feedback_fingerprint),
        "checks_fingerprint" => value(command.provider_snapshot, :checks_fingerprint),
        "criteria_fingerprint" => ReviewAttestation.criteria_fingerprint(task.acceptance_criteria),
        "pull_request_number" => value(command.provider_snapshot, :number),
        "reviewer_identity" => actor.identity,
        "run_id" => run["id"],
        "reviewed_at" => reviewed_at
      }

      task = bump(task, %{review_attestation: attestation})
      route_review_attestation(task, run, command, bundle)
    end
  end

  def validate(%Commands.InvalidateReviewAttestation{} = command, actor, bundle) do
    with :ok <- system_actor(actor),
         {:ok, task} <- Projection.get_task(command.task_id),
         {:ok, reason} <- nonempty(command.reason, :attestation_invalidation_reason),
         {:ok, merge} <- configured_merge(bundle),
         true <- is_nil(command.head_sha) or sha?(command.head_sha),
         %Column{} = review <- Bundle.column(bundle, merge.review_column) do
      {source, github} = invalidated_heads(task, command.head_sha)

      saga =
        merge_saga(task)
        |> Map.put("checkpoint", "review_required")
        |> Map.put("reason", reason)
        |> Map.put("updated_at", now())

      updated =
        bump(task, %{
          column_id: review.id,
          rank: Projection.max_rank(review.id) + @rank_gap,
          review_attestation: nil,
          merge_saga: saga,
          source: source,
          github: github,
          blocked_from_column_id: nil,
          desired_column_id: nil,
          runtime_state: nil,
          active_run_id: nil
        })

      mutation("review_attestation_invalidated", updated, nil)
    else
      false -> {:error, :invalid_attestation_invalidation_head}
      nil -> {:error, :merge_review_column_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(%Commands.RecordMergeCheckpoint{} = command, actor, bundle) do
    with :ok <- system_actor(actor),
         {:ok, task} <- Projection.get_task(command.task_id),
         :ok <- task_in_merge_column(task, bundle),
         true <- command.checkpoint in ["clean_update_started", "squash_started", "reachability_pending"],
         true <- is_map(command.attrs) do
      saga =
        merge_saga(task)
        |> Map.put("checkpoint", command.checkpoint)
        |> Map.put("attrs", stringify_keys(command.attrs))
        |> Map.put("updated_at", now())

      task = bump(task, %{merge_saga: saga})
      mutation("merge_checkpoint_recorded", task, nil)
    else
      false -> {:error, :invalid_merge_checkpoint}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(%Commands.RecordMergeConflict{} = command, actor, bundle) do
    with :ok <- system_actor(actor),
         {:ok, task} <- Projection.get_task(command.task_id),
         :ok <- task_in_merge_column(task, bundle),
         true <- sha?(command.task_head) and sha?(command.target_head),
         :ok <- verified_conflict_paths(command.conflicted_paths),
         true <- command.conflict_id == conflict_id(task.id, command.task_head, command.target_head, command.conflicted_paths) do
      record_or_block_conflict(task, command, bundle)
    else
      false -> {:error, :invalid_merge_conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(%Commands.CompleteMergeConflictResolution{} = command, actor, bundle) do
    proof = stringify_keys(command.proof)

    with {:ok, task} <- Projection.get_task(command.task_id),
         {:ok, run} <- Projection.get_run(command.run_id),
         :ok <- conflict_resolution_actor(actor, run),
         :ok <- active_run(task, run),
         {:ok, merge} <- configured_merge(bundle),
         :ok <- active_conflict_resolution_run(task, run, bundle, merge),
         :ok <- valid_conflict_resolution_proof(proof, task, run) do
      complete_conflict_resolution(task, proof, bundle, merge)
    end
  end

  def validate(%Commands.CompleteDeterministicMerge{} = command, actor, bundle) do
    with :ok <- system_actor(actor),
         {:ok, task} <- Projection.get_task(command.task_id),
         :ok <- task_in_merge_column(task, bundle),
         %{"verdict" => "pass", "reviewed_head_sha" => reviewed_head} <- task.review_attestation,
         true <- reviewed_head == command.reviewed_head_sha,
         true <-
           task.review_attestation["criteria_fingerprint"] ==
             ReviewAttestation.criteria_fingerprint(task.acceptance_criteria),
         true <- sha?(command.merge_sha) and sha?(command.target_head),
         %Column{} = done <- Bundle.done_column(bundle) do
      recorded_at = now()

      github =
        Map.put(task.github, "merged", %{
          "merged" => true,
          "merge_sha" => command.merge_sha,
          "merge_reachable" => true,
          "reviewed_head_sha" => reviewed_head,
          "recorded_at" => recorded_at
        })

      saga =
        merge_saga(task)
        |> Map.put("checkpoint", "completed")
        |> Map.put("merge_sha", command.merge_sha)
        |> Map.put("target_head", command.target_head)
        |> Map.put("updated_at", recorded_at)

      updated =
        bump(task, %{
          column_id: done.id,
          rank: Projection.max_rank(done.id) + @rank_gap,
          github: github,
          merge_saga: saga,
          runtime_state: nil,
          active_run_id: nil,
          desired_column_id: nil
        })

      mutation("deterministic_merge_completed", updated, nil)
    else
      false -> {:error, :invalid_merge_completion}
      nil -> {:error, :merge_completion_invariant_broken}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :passing_review_attestation_required}
    end
  end

  def validate(%Commands.RecordRunStatsPublication{} = command, actor, _bundle) do
    with :ok <- system_actor(actor),
         {:ok, task} <- Projection.get_task(command.task_id),
         {:ok, run} <- Projection.get_run(command.run_id),
         true <- run["task_id"] == task.id,
         true <- run["status"] in ["completed", "stopped", "failed"],
         true <- is_map(run["stats"]),
         true <- command.destination in ["pr_body", "workpad_comment"],
         true <- nonblank?(command.publication_id) do
      recorded_at = now()

      publication = %{
        "destination" => command.destination,
        "publication_id" => command.publication_id,
        "published_at" => recorded_at
      }

      run =
        run
        |> Map.put("stats_publication", publication)
        |> Map.put("updated_at", recorded_at)

      external_effect = %{
        id: "#{run["id"]}:github:run_stats",
        task_id: task.id,
        kind: "github_run_stats",
        state: "completed",
        attrs: publication,
        updated_at: recorded_at
      }

      mutation("run_stats_published", task, run, %{external_effect: external_effect})
    else
      false -> {:error, :invalid_run_stats_publication}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(command, _actor, _bundle), do: {:error, {:unsupported_command, command}}

  defp create_task(attrs, bundle) do
    with {:ok, title} <- value_string(attrs, :title),
         {:ok, type} <- task_type(value(attrs, :type)),
         {:ok, priority} <- priority(value(attrs, :priority, :normal)),
         {:ok, brief} <- value_string(attrs, :brief),
         {:ok, criteria} <- acceptance(value(attrs, :acceptance_criteria, value(attrs, :acceptance_checklist))),
         {:ok, dependencies} <- resolve_dependencies(value(attrs, :dependencies, []), nil),
         {:ok, selections} <- resolve_stage_selections(value(attrs, :stage_selections, %{}), bundle) do
      number = Projection.next_task_number()
      identifier = "#{bundle.project.key}-#{number}"
      timestamp = now()

      task = %Task{
        id: Ecto.UUID.generate(),
        identifier: identifier,
        number: number,
        project_id: bundle.project.id,
        title: title,
        type: type,
        branch: Task.branch_for(type, identifier),
        priority: priority,
        brief: brief,
        acceptance_criteria: criteria,
        dependencies: dependencies,
        stage_selections: selections,
        column_id: Bundle.initial_column(bundle).id,
        rank: Projection.max_rank(Bundle.initial_column(bundle).id) + @rank_gap,
        revision: 1,
        created_at: timestamp,
        updated_at: timestamp
      }

      mutation("task_created", task, nil)
    end
  end

  defp update_task(task, attrs, bundle, actor) do
    with {:ok, title} <- optional_value_string(attrs, :title, task.title),
         {:ok, brief} <- optional_value_string(attrs, :brief, task.brief),
         {:ok, priority} <- optional_priority(attrs, task.priority),
         {:ok, criteria} <- optional_acceptance(attrs, task.acceptance_criteria, actor),
         {:ok, dependencies} <- optional_dependencies(attrs, task),
         :ok <- dependency_cycle_free(task.id, dependencies),
         {:ok, selections} <- optional_stage_selections(attrs, task.stage_selections, bundle) do
      {:ok,
       bump(task, %{
         title: title,
         brief: brief,
         priority: priority,
         acceptance_criteria: criteria,
         dependencies: dependencies,
         stage_selections: selections
       })}
    end
  end

  defp move_task(task, target, command, actor, bundle) do
    with false <- Task.archived?(task),
         :ok <- move_permission(task, target, command.force, actor, bundle),
         :ok <- done_prerequisites(task, target),
         :ok <- ready_prerequisites(task, target) do
      cond do
        active?(task) and actor.type == :human and not command.force ->
          task = bump(task, %{desired_column_id: target.id, runtime_state: "stopping"})
          mutation("task_stop_requested", task, nil)

        target.role == :blocked ->
          block_task(task, command.reason || "Moved to Blocked", bundle, nil)

        true ->
          rank = command.rank || Projection.max_rank(target.id) + @rank_gap

          task =
            bump(task, %{
              column_id: target.id,
              rank: rank,
              blocked_from_column_id: nil,
              desired_column_id: nil
            })

          mutation("task_transitioned", task, nil)
      end
    else
      true -> {:error, :task_archived}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reorder_task(command) do
    with {:ok, task} <- Projection.get_task(command.task_id),
         false <- Task.archived?(task),
         false <- active?(task),
         {:ok, before_task} <- optional_neighbor(command.before_task_id, task),
         {:ok, after_task} <- optional_neighbor(command.after_task_id, task),
         :ok <- neighbor_order(before_task, after_task) do
      before_rank = if before_task, do: before_task.rank, else: 0
      after_rank = if after_task, do: after_task.rank, else: Projection.max_rank(task.column_id) + @rank_gap * 2

      if after_rank - before_rank > 1 do
        updated = bump(task, %{rank: div(before_rank + after_rank, 2)})
        mutation("task_reordered", updated, nil)
      else
        compact_ranks(task, before_task, after_task)
      end
    else
      true -> {:error, :task_not_reorderable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp compact_ranks(task, before_task, after_task) do
    tasks =
      Projection.list_tasks()
      |> Enum.filter(&(&1.column_id == task.column_id and &1.priority == task.priority and &1.id != task.id))

    insert_index =
      cond do
        after_task -> Enum.find_index(tasks, &(&1.id == after_task.id)) || length(tasks)
        before_task -> (Enum.find_index(tasks, &(&1.id == before_task.id)) || -1) + 1
        true -> length(tasks)
      end

    ordered = List.insert_at(tasks, insert_index, task)

    updated =
      ordered
      |> Enum.with_index(1)
      |> Enum.map(fn {candidate, index} ->
        rank = index * @rank_gap
        if candidate.rank == rank, do: candidate, else: bump(candidate, %{rank: rank})
      end)

    primary = Enum.find(updated, &(&1.id == task.id))
    mutation("task_ranks_compacted", primary, nil, %{tasks: updated})
  end

  defp claim_run(task, column, selection, worker_host, bundle) do
    claimed_column = if column.on_claim, do: Bundle.column(bundle, column.on_claim), else: column
    stage = Map.fetch!(bundle.stages, column.stage_id)
    timestamp = now()
    run_id = Ecto.UUID.generate()

    run = %{
      "id" => run_id,
      "task_id" => task.id,
      "task_identifier" => task.identifier,
      "stage_id" => stage.id,
      "start_column_id" => claimed_column.id,
      "claimed_from_column_id" => column.id,
      "status" => "starting",
      "backend" => selection["backend"],
      "model" => selection["model"],
      "effort" => selection["effort"],
      "worker_host" => worker_host,
      "bundle_hash" => bundle.hash,
      "pull_request_created" => false,
      "frozen_stage" => frozen_stage(stage),
      "frozen_bundle" => frozen_bundle(bundle, stage),
      "claimed_at" => timestamp,
      "updated_at" => timestamp
    }

    task =
      bump(task, %{
        column_id: claimed_column.id,
        active_run_id: run_id,
        runtime_state: "starting",
        desired_column_id: nil
      })

    mutation("run_claimed", task, run)
  end

  defp frozen_stage(stage) do
    %{
      "id" => stage.id,
      "prompt_path" => stage.prompt_path,
      "prompt" => stage.prompt,
      "workpad_template_path" => stage.workpad_template_path,
      "workpad_template" => stage.workpad_template,
      "allowed" => Enum.map(stage.allowed, fn {backend, model, effort} -> [backend, model, effort] end)
    }
  end

  defp frozen_bundle(bundle, stage) do
    %{
      "hash" => bundle.hash,
      "base_prompt_path" => bundle.base_prompt_path,
      "base_prompt" => bundle.base_prompt,
      "context_prompt_path" => bundle.context_prompt_path,
      "context_prompt" => bundle.context_prompt,
      "stage" => frozen_stage(stage),
      "jobs" => frozen_jobs(bundle.jobs),
      "columns" => Enum.map(bundle.columns, &column_map/1),
      "agent_transitions" => bundle.agent_transitions,
      "human_transitions" => bundle.human_transitions
    }
  end

  defp frozen_jobs(jobs) do
    Map.new(jobs, fn {id, job} ->
      {id,
       job
       |> Map.from_struct()
       |> stringify_keys()}
    end)
  end

  defp column_map(column) do
    column
    |> Map.from_struct()
    |> stringify_keys()
  end

  defp finish_run(task, run, outcome, stats, bundle) do
    cond do
      is_binary(task.desired_column_id) ->
        target = Bundle.column(bundle, task.desired_column_id)
        finished = completed_run(run, outcome, "stopped", stats)

        task =
          bump(task, %{
            column_id: target.id,
            rank: Projection.max_rank(target.id) + @rank_gap,
            active_run_id: nil,
            runtime_state: nil,
            desired_column_id: nil
          })

        mutation("run_stopped", task, finished)

      task.column_id == run["start_column_id"] ->
        block_task(task, "Agent invocation ended without a required stage transition", bundle, failed_run(run, :missing_transition))

      true ->
        finished = completed_run(run, outcome, "completed", stats)
        task = bump(task, %{active_run_id: nil, runtime_state: nil, desired_column_id: nil})
        mutation("run_finished", task, finished)
    end
  end

  defp block_task(task, reason, bundle, run) do
    blocked = Bundle.blocked_column(bundle)
    prior = if task.column_id == blocked.id, do: task.blocked_from_column_id, else: task.column_id

    metadata =
      task.metadata
      |> Map.put("blocked_reason", reason)
      |> Map.put("blocked_at", now())

    task =
      bump(task, %{
        column_id: blocked.id,
        blocked_from_column_id: prior,
        desired_column_id: nil,
        runtime_state: nil,
        active_run_id: nil,
        metadata: metadata
      })

    mutation("task_blocked", task, run)
  end

  defp mutation(event_type, task, run, extra \\ %{}) do
    result = %{
      "task" => Task.to_map(task),
      "run" => run,
      "event_type" => event_type
    }

    payload =
      %{
        "task" => Task.to_map(task),
        "run" => run,
        "result" => result
      }
      |> Map.merge(stringify_keys(extra))

    {:ok,
     %{
       event_type: event_type,
       task_id: task.id,
       run_id: run && run["id"],
       task_revision: task.revision,
       payload: payload,
       result: result
     }}
  end

  defp configured_merge(%{merge: %{} = merge}), do: {:ok, merge}
  defp configured_merge(_bundle), do: {:error, :deterministic_merge_not_configured}

  defp invalidated_heads(task, nil), do: {task.source, task.github}

  defp invalidated_heads(task, head) do
    recorded_at = now()

    {
      task.source |> Map.put("head_sha", head) |> Map.put("recorded_at", recorded_at),
      Map.put(task.github, "head_sha", head)
    }
  end

  defp active_review_run(task, run, bundle, merge) do
    with %Column{role: :dispatch, stage_id: stage_id} <- Bundle.column(bundle, merge.review_column),
         true <- task.column_id == merge.review_column,
         true <- run["stage_id"] == stage_id do
      :ok
    else
      false -> {:error, :review_tool_requires_active_automated_review_run}
      nil -> {:error, :merge_review_column_missing}
      _ -> {:error, :review_tool_requires_active_automated_review_run}
    end
  end

  defp active_conflict_resolution_run(task, run, bundle, merge) do
    with %Column{role: :dispatch, stage_id: stage_id} <- Bundle.column(bundle, merge.conflict_column),
         true <- task.column_id == merge.conflict_column,
         true <- run["stage_id"] == stage_id,
         %{"checkpoint" => "conflict_recorded", "last_conflict" => %{} = _conflict} <- task.merge_saga do
      :ok
    else
      _ -> {:error, :merge_conflict_run_not_current}
    end
  end

  defp conflict_resolution_actor(%{type: :agent, identity: identity}, %{"id" => identity}), do: :ok
  defp conflict_resolution_actor(_actor, _run), do: {:error, :merge_conflict_run_not_current}

  defp valid_conflict_resolution_proof(proof, task, run) when is_map(proof) do
    conflict = task.merge_saga["last_conflict"]
    job = proof["job"]
    pull_request = proof["pull_request"]
    frozen_jobs = get_in(run, ["frozen_bundle", "jobs"])
    frozen_job = (is_map(job) and is_map(frozen_jobs)) && frozen_jobs[job["job"]]

    with true <- exact_conflict_proof_keys?(proof),
         true <- canonical_conflict_proof?(proof, conflict, run),
         true <- canonical_conflict_heads?(task, conflict, proof),
         true <- valid_conflict_source_proof?(proof, conflict),
         true <- valid_conflict_job?(job, run, frozen_job, proof),
         true <- valid_conflict_pull_request?(pull_request, task, proof) do
      :ok
    else
      _ -> {:error, :invalid_merge_conflict_resolution_proof}
    end
  end

  defp valid_conflict_resolution_proof(_proof, _task, _run),
    do: {:error, :invalid_merge_conflict_resolution_proof}

  defp exact_conflict_proof_keys?(proof) do
    Map.keys(proof) |> Enum.sort() ==
      ~w(conflict_id conflicted_paths final_head_sha job merge_commit_sha pull_request remote_head_sha run_id source_fingerprint target_head task_head)
  end

  defp canonical_conflict_proof?(proof, conflict, run) do
    is_map(conflict) and proof["conflict_id"] == conflict["id"] and
      proof["task_head"] == conflict["task_head"] and proof["target_head"] == conflict["target_head"] and
      proof["conflicted_paths"] == conflict["conflicted_paths"] and proof["run_id"] == run["id"]
  end

  defp canonical_conflict_heads?(task, conflict, proof) do
    allowed_heads = [conflict["task_head"], proof["final_head_sha"]]

    task.source["head_sha"] in allowed_heads and task.source["clean"] == true and
      task.github["head_sha"] in allowed_heads
  end

  defp valid_conflict_source_proof?(proof, conflict) do
    sha?(proof["final_head_sha"]) and proof["final_head_sha"] != conflict["task_head"] and
      proof["remote_head_sha"] == proof["final_head_sha"] and sha?(proof["merge_commit_sha"]) and
      sha256?(proof["source_fingerprint"])
  end

  defp valid_conflict_job?(job, run, frozen_job, proof) do
    is_map(job) and
      Map.keys(job) |> Enum.sort() ==
        ~w(exit_code job job_definition_fingerprint job_id run_id source_fingerprint status) and
      is_map(frozen_job) and nonblank?(job["job_id"]) and job["run_id"] == run["id"] and
      job["status"] == "completed" and job["exit_code"] == 0 and
      job["source_fingerprint"] == proof["source_fingerprint"] and
      job["job_definition_fingerprint"] == JobManager.job_definition_fingerprint(frozen_job)
  end

  defp valid_conflict_pull_request?(pull_request, task, proof) do
    is_map(pull_request) and Map.keys(pull_request) |> Enum.sort() == ~w(head_sha number state) and
      is_integer(pull_request["number"]) and pull_request["number"] > 0 and
      pull_request["number"] == task.github["number"] and pull_request["state"] == "OPEN" and
      pull_request["head_sha"] == proof["final_head_sha"]
  end

  defp complete_conflict_resolution(task, proof, bundle, merge) do
    timestamp = now()
    review = Bundle.column(bundle, merge.review_column)

    saga =
      merge_saga(task)
      |> Map.put("checkpoint", "conflict_resolved")
      |> Map.put("resolution", stringify_keys(proof))
      |> Map.put("updated_at", timestamp)

    updated =
      bump(task, %{
        column_id: review.id,
        rank: Projection.max_rank(review.id) + @rank_gap,
        source:
          task.source
          |> Map.put("head_sha", proof["final_head_sha"])
          |> Map.put("clean", true)
          |> Map.put("recorded_at", timestamp),
        github: Map.put(task.github, "head_sha", proof["final_head_sha"]),
        review_attestation: nil,
        merge_saga: saga,
        blocked_from_column_id: nil,
        desired_column_id: nil
      })

    mutation("merge_conflict_resolved", updated, nil)
  end

  defp valid_review_attestation(command, task) do
    with true <- command.verdict in ["pass", "rework"],
         true <- sha?(command.reviewed_head_sha),
         true <- task.source["head_sha"] == command.reviewed_head_sha,
         true <- task.github["head_sha"] == command.reviewed_head_sha,
         :ok <- valid_plan_policy(command.plan_policy),
         :ok <- valid_validation_evidence(command.validation_evidence),
         :ok <- valid_findings(command.findings),
         :ok <- valid_provider_snapshot(command.provider_snapshot, task, command.reviewed_head_sha) do
      :ok
    else
      false -> {:error, :review_attestation_head_or_payload_invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_plan_policy(policy) when is_map(policy) do
    policy = stringify_keys(policy)

    if Map.keys(policy) |> Enum.sort() == ["status", "summary"] and
         policy["status"] in ["not_required", "followed", "deviation"] and
         nonblank?(policy["summary"]),
       do: :ok,
       else: {:error, :invalid_review_plan_policy}
  end

  defp valid_plan_policy(_policy), do: {:error, :invalid_review_plan_policy}

  defp valid_validation_evidence(evidence) when is_list(evidence) and evidence != [] do
    if Enum.all?(evidence, &valid_validation_item?/1),
      do: :ok,
      else: {:error, :invalid_review_validation_evidence}
  end

  defp valid_validation_evidence(_evidence), do: {:error, :invalid_review_validation_evidence}

  defp valid_validation_item?(item) when is_map(item) do
    item = stringify_keys(item)
    allowed = ~w(artifact command exit_status result)

    Enum.all?(Map.keys(item), &(&1 in allowed)) and nonblank?(item["command"]) and
      nonblank?(item["result"]) and optional_string?(item["artifact"]) and
      (is_nil(item["exit_status"]) or is_integer(item["exit_status"]))
  end

  defp valid_validation_item?(_item), do: false

  defp valid_findings(findings) when is_list(findings) do
    if Enum.all?(findings, &valid_finding?/1), do: :ok, else: {:error, :invalid_review_findings}
  end

  defp valid_findings(_findings), do: {:error, :invalid_review_findings}

  defp valid_finding?(finding) when is_map(finding) do
    finding = stringify_keys(finding)
    allowed = ~w(line path severity summary)

    Enum.all?(Map.keys(finding), &(&1 in allowed)) and
      finding["severity"] in ["blocker", "high", "medium", "low", "note"] and
      nonblank?(finding["summary"]) and optional_string?(finding["path"]) and
      (is_nil(finding["line"]) or (is_integer(finding["line"]) and finding["line"] > 0))
  end

  defp valid_finding?(_finding), do: false

  defp valid_provider_snapshot(snapshot, task, reviewed_head) when is_map(snapshot) do
    with number when is_integer(number) and number > 0 <- value(snapshot, :number),
         true <- number == task.github["number"],
         true <- value(snapshot, :head_sha) == reviewed_head,
         true <- value(snapshot, :source_head_sha) == reviewed_head,
         state when state in ["OPEN", "open"] <- value(snapshot, :state),
         draft when is_boolean(draft) <- value(snapshot, :draft),
         fingerprint when is_binary(fingerprint) and fingerprint != "" <- value(snapshot, :feedback_fingerprint),
         checks when is_binary(checks) and checks != "" <- value(snapshot, :checks_fingerprint) do
      :ok
    else
      _ -> {:error, :invalid_review_provider_snapshot}
    end
  end

  defp valid_provider_snapshot(_snapshot, _task, _reviewed_head),
    do: {:error, :invalid_review_provider_snapshot}

  defp review_route(%{verdict: "pass"} = command, task, bundle, merge) do
    with %Column{id: merge_column} <- Enum.find(bundle.columns, &(&1.role == :merge)),
         true <- command.route == merge_column,
         true <- criteria_complete?(task),
         true <- value(command.plan_policy, :status) in ["not_required", "followed"],
         true <- no_open_findings?(command.findings),
         true <- value(command.provider_snapshot, :draft) == false,
         true <- value(command.provider_snapshot, :approved) == true,
         true <- value(command.provider_snapshot, :required_checks_green) == true,
         true <- value(command.provider_snapshot, :unresolved_review_threads) == 0,
         true <- merge.review_column == task.column_id do
      :ok
    else
      false -> {:error, :passing_review_not_merge_ready}
      nil -> {:error, :merge_column_missing}
    end
  end

  defp review_route(%{verdict: "rework"} = command, task, bundle, merge) do
    target = Bundle.column(bundle, command.route)

    with %Column{role: role} when role in [:dispatch, :blocked] <- target,
         true <- command.route != merge.review_column,
         true <- Bundle.transition_allowed?(bundle, :agent, task.column_id, command.route),
         true <- command.findings != [] do
      :ok
    else
      false -> {:error, :invalid_review_rework_route}
      nil -> {:error, :invalid_review_rework_route}
      _ -> {:error, :invalid_review_rework_route}
    end
  end

  defp project_github_outcome(github, "ready", %{"completed" => true}),
    do: github |> Map.put("draft", false) |> Map.delete("rework_draft")

  defp project_github_outcome(github, "rework_draft", %{"completed" => true}),
    do: Map.put(github, "draft", true)

  defp project_github_outcome(github, _kind, _outcome), do: github

  defp route_review_attestation(task, run, %{verdict: "rework", route: route} = command, bundle) do
    target = Bundle.column(bundle, route)

    if target.role == :blocked do
      reason = Enum.map_join(command.findings, "; ", &value(&1, :summary))
      block_task(task, reason, bundle, failed_run(run, {:review_rework, reason}))
    else
      rank = Projection.max_rank(target.id) + @rank_gap
      updated = bump(task, %{column_id: target.id, rank: rank, blocked_from_column_id: nil, desired_column_id: nil})
      mutation("review_attestation_recorded", updated, run)
    end
  end

  defp route_review_attestation(task, run, command, bundle) do
    target = Bundle.column(bundle, command.route)
    rank = Projection.max_rank(target.id) + @rank_gap
    updated = bump(task, %{column_id: target.id, rank: rank, blocked_from_column_id: nil, desired_column_id: nil})
    mutation("review_attestation_recorded", updated, run)
  end

  defp criteria_complete?(task) do
    Enum.all?(task.acceptance_criteria, fn criterion ->
      criterion["completed"] == true and is_list(criterion["evidence"]) and criterion["evidence"] != []
    end)
  end

  defp no_open_findings?(findings) do
    Enum.all?(findings, &(value(&1, :severity) not in ["blocker", "high"]))
  end

  defp invalidate_attestation_for_head(%Task{review_attestation: nil} = task, _head, _bundle, _reason), do: task

  defp invalidate_attestation_for_head(task, head, bundle, reason) do
    if task.review_attestation["reviewed_head_sha"] == head do
      task
    else
      invalidate_attestation(task, bundle, reason)
    end
  end

  defp invalidate_attestation_for_pull_request(%Task{review_attestation: nil} = task, _number, _head, _bundle),
    do: task

  defp invalidate_attestation_for_pull_request(task, number, head, bundle) do
    if task.review_attestation["reviewed_head_sha"] == head and
         task.review_attestation["pull_request_number"] == number do
      task
    else
      invalidate_attestation(task, bundle, "pull_request_identity_changed")
    end
  end

  defp invalidate_attestation_for_criteria(%Task{review_attestation: nil} = task, _bundle), do: task

  defp invalidate_attestation_for_criteria(task, bundle) do
    if task.review_attestation["criteria_fingerprint"] ==
         ReviewAttestation.criteria_fingerprint(task.acceptance_criteria) do
      task
    else
      invalidate_attestation(task, bundle, "acceptance_criteria_changed")
    end
  end

  defp invalidate_attestation(task, bundle, reason) do
    task = %{task | review_attestation: nil}

    case {bundle.merge, Bundle.column(bundle, task.column_id)} do
      {%{} = merge, %Column{role: :merge}} ->
        review = Bundle.column(bundle, merge.review_column)

        %{
          task
          | column_id: review.id,
            rank: Projection.max_rank(review.id) + @rank_gap,
            merge_saga:
              merge_saga(task)
              |> Map.put("checkpoint", "review_required")
              |> Map.put("reason", reason)
              |> Map.put("updated_at", now())
        }

      _ ->
        task
    end
  end

  defp task_in_merge_column(task, bundle) do
    case Bundle.column(bundle, task.column_id) do
      %Column{role: :merge} -> :ok
      _ -> {:error, :task_not_merge_pending}
    end
  end

  defp verified_conflict_paths(paths) when is_list(paths) and paths != [] do
    valid =
      paths == Enum.sort(Enum.uniq(paths)) and
        Enum.all?(paths, fn path ->
          is_binary(path) and path != "" and Path.type(path) == :relative and
            ".." not in Path.split(path)
        end)

    if valid, do: :ok, else: {:error, :invalid_conflicted_paths}
  end

  defp verified_conflict_paths(_paths), do: {:error, :invalid_conflicted_paths}

  defp conflict_id(task_id, task_head, target_head, paths) do
    :crypto.hash(:sha256, Enum.join([task_id, task_head, target_head | paths], "\0"))
    |> Base.encode16(case: :lower)
  end

  defp record_or_block_conflict(task, command, bundle) do
    conflict = %{
      "id" => command.conflict_id,
      "task_head" => command.task_head,
      "target_head" => command.target_head,
      "conflicted_paths" => command.conflicted_paths,
      "recorded_at" => now()
    }

    previous = get_in(merge_saga(task), ["last_conflict"])

    if is_map(previous) and previous["task_head"] == command.task_head and
         previous["target_head"] == command.target_head do
      saga =
        merge_saga(task)
        |> Map.put("checkpoint", "blocked_repeated_conflict")
        |> Map.put("last_conflict", conflict)
        |> Map.put("updated_at", now())

      task = %{task | merge_saga: saga, review_attestation: nil}

      block_task(
        task,
        "Repeated merge conflict for task head #{command.task_head} and target head #{command.target_head}",
        bundle,
        nil
      )
    else
      merge = bundle.merge
      target = Bundle.column(bundle, merge.conflict_column)

      saga =
        merge_saga(task)
        |> Map.put("checkpoint", "conflict_recorded")
        |> Map.put("last_conflict", conflict)
        |> Map.put("updated_at", now())

      updated =
        bump(task, %{
          column_id: target.id,
          rank: Projection.max_rank(target.id) + @rank_gap,
          review_attestation: nil,
          merge_saga: saga,
          runtime_state: nil,
          active_run_id: nil,
          desired_column_id: nil
        })

      mutation("merge_conflict_recorded", updated, nil)
    end
  end

  defp conflict_claim_allowed(task, column, %{merge: %{} = merge}) when column.id == merge.conflict_column do
    case task.merge_saga do
      %{
        "checkpoint" => "conflict_recorded",
        "last_conflict" => %{"conflicted_paths" => paths, "task_head" => head, "target_head" => target}
      }
      when is_list(paths) and paths != [] and is_binary(head) and is_binary(target) ->
        :ok

      _ ->
        {:error, :verified_merge_conflict_required}
    end
  end

  defp conflict_claim_allowed(_task, _column, _bundle), do: :ok

  defp merge_saga(%Task{merge_saga: saga}) when is_map(saga), do: saga
  defp merge_saga(_task), do: %{}

  defp optional_string?(nil), do: true
  defp optional_string?(value), do: is_binary(value)

  defp mutable_contract?(task, actor) do
    cond do
      actor.type == :agent -> {:error, :agent_cannot_edit_task_contract}
      active?(task) -> {:error, :task_contract_frozen}
      Task.archived?(task) -> {:error, :task_archived}
      true -> :ok
    end
  end

  defp reject_immutable_fields(attrs) do
    immutable = ~w(id identifier number type branch project_id)a
    present = Enum.filter(immutable, &has_key?(attrs, &1))
    if present == [], do: :ok, else: {:error, {:immutable_task_fields, present}}
  end

  defp move_permission(_task, _target, true, %{type: :system}, _bundle), do: :ok

  defp move_permission(_task, %Column{role: :merge}, _force, %{type: :agent}, _bundle),
    do: {:error, :merge_column_requires_review_attestation}

  defp move_permission(task, target, _force, %{type: :agent}, %{merge: merge} = bundle)
       when not is_nil(merge) and task.column_id == merge.conflict_column do
    cond do
      target.id == merge.review_column -> {:error, :merge_conflict_resolution_required}
      target.id == Bundle.blocked_column(bundle).id -> :ok
      true -> {:error, :merge_conflict_must_return_to_review}
    end
  end

  defp move_permission(task, target, _force, actor, bundle) when actor.type in [:human, :agent] do
    if Bundle.transition_allowed?(bundle, actor.type, task.column_id, target.id) do
      if actor.type == :agent and not active?(task) do
        {:error, :agent_transition_outside_active_run}
      else
        :ok
      end
    else
      {:error, {:transition_not_allowed, actor.type, task.column_id, target.id}}
    end
  end

  defp move_permission(_task, _target, _force, actor, _bundle), do: {:error, {:invalid_actor, actor}}

  defp done_prerequisites(task, %Column{satisfies_dependencies: true}) do
    merged = get_in(task.github, ["merged", "merged"]) == true
    reachable = get_in(task.github, ["merged", "merge_reachable"]) == true
    if merged and reachable, do: :ok, else: {:error, :done_requires_reachable_merge}
  end

  defp done_prerequisites(_task, _target), do: :ok

  defp ready_prerequisites(task, %Column{mark_pr_ready: true}) do
    if get_in(task.github, ["ready", "completed"]) == true do
      :ok
    else
      {:error, :human_review_requires_completed_readiness_saga}
    end
  end

  defp ready_prerequisites(_task, _target), do: :ok

  defp dependencies_satisfied(task, bundle) do
    done_id = Bundle.done_column(bundle).id

    Enum.reduce_while(task.dependencies, :ok, fn dependency_id, :ok ->
      case Projection.get_task(dependency_id) do
        {:ok, %{column_id: ^done_id}} -> {:cont, :ok}
        {:ok, dependency} -> {:halt, {:error, {:dependency_not_done, dependency.identifier}}}
        {:error, _reason} -> {:halt, {:error, {:missing_dependency, dependency_id}}}
      end
    end)
  end

  defp fetch_stage_selection(task, stage_id, bundle) do
    stage = Map.fetch!(bundle.stages, stage_id)

    case Map.get(task.stage_selections, stage_id) do
      %{"model" => model} = selection ->
        backend = selection["backend"] || "codex"
        effort = selection["effort"]

        if AgentStage.permits?(stage, backend, model, effort) do
          {:ok, %{"backend" => backend, "model" => model, "effort" => effort}}
        else
          {:error, :stage_selection_incompatible}
        end

      _ ->
        {:error, :missing_stage_selection}
    end
  end

  defp validate_backend_worker(selection, worker_host, bundle) do
    backend = selection["backend"] || "codex"

    case Map.get(bundle.backends, backend) do
      %{protocol: "acp"} when is_binary(worker_host) ->
        {:error, {:backend_remote_unsupported, backend}}

      _ ->
        :ok
    end
  end

  defp resolve_stage_selections(selections, bundle) when is_map(selections) do
    selections = stringify_keys(selections)

    bundle
    |> Bundle.reachable_stage_ids()
    |> Enum.reduce_while({:ok, %{}}, fn stage_id, {:ok, acc} ->
      stage = Map.fetch!(bundle.stages, stage_id)

      case resolve_selection(stage, selections[stage_id]) do
        {:ok, selection} -> {:cont, {:ok, Map.put(acc, stage_id, selection)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp resolve_stage_selections(_selections, _bundle), do: {:error, :invalid_stage_selections}

  defp resolve_selection(stage, nil) do
    case AgentStage.singleton_pair(stage) do
      {:ok, {backend, model, effort}} -> {:ok, %{"backend" => backend, "model" => model, "effort" => effort}}
      :multiple -> {:error, {:stage_selection_required, stage.id}}
    end
  end

  defp resolve_selection(stage, %{"model" => model} = selection) do
    backend = selection["backend"] || "codex"
    effort = selection["effort"]

    if AgentStage.permits?(stage, backend, model, effort) do
      {:ok, %{"backend" => backend, "model" => model, "effort" => effort}}
    else
      {:error, {:stage_selection_not_permitted, stage.id, backend, model, effort}}
    end
  end

  defp resolve_selection(stage, _selection), do: {:error, {:invalid_stage_selection, stage.id}}

  defp optional_stage_selections(attrs, current, bundle) do
    if has_key?(attrs, :stage_selections) do
      resolve_stage_selections(value(attrs, :stage_selections), bundle)
    else
      resolve_stage_selections(current, bundle)
    end
  end

  defp acceptance(values) when is_list(values) and values != [] do
    values
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case criterion(value, index) do
        {:ok, criterion} -> {:cont, {:ok, [criterion | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, criteria} -> {:ok, Enum.reverse(criteria)}
      error -> error
    end
  end

  defp acceptance(_values), do: {:error, :acceptance_checklist_required}

  defp criterion(text, _index) when is_binary(text) do
    with {:ok, text} <- nonempty(text, :criterion_text) do
      {:ok, fresh_criterion(Ecto.UUID.generate(), text)}
    end
  end

  defp criterion(%{} = criterion, index) do
    id = value(criterion, :id, Ecto.UUID.generate())
    text = value(criterion, :text)

    with true <- nonblank?(id),
         {:ok, text} <- nonempty(text, {:criterion_text, index}) do
      {:ok, fresh_criterion(id, text)}
    else
      false -> {:error, {:invalid_criterion_id, index}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp criterion(_value, index), do: {:error, {:invalid_criterion, index}}

  defp fresh_criterion(id, text) do
    %{"id" => id, "text" => text, "completed" => false, "evidence" => [], "evidence_history" => []}
  end

  defp optional_acceptance(attrs, current, actor) do
    if has_key?(attrs, :acceptance_criteria) or has_key?(attrs, :acceptance_checklist) do
      key = if has_key?(attrs, :acceptance_criteria), do: :acceptance_criteria, else: :acceptance_checklist

      with {:ok, parsed} <- acceptance(value(attrs, key)) do
        {:ok, merge_criteria(current, parsed, actor)}
      end
    else
      {:ok, current}
    end
  end

  defp merge_criteria(current, parsed, actor) do
    current_by_id = Map.new(current, &{&1["id"], &1})

    Enum.map(parsed, &merge_criterion(&1, current_by_id[&1["id"]], actor))
  end

  defp merge_criterion(criterion, %{"text" => text} = existing, actor) do
    if text == criterion["text"] do
      existing
    else
      history_entry = evidence_history_entry(existing, "criterion_text_edited", actor)

      criterion
      |> Map.put("evidence_history", existing["evidence_history"] ++ [history_entry])
      |> Map.put("completed", false)
      |> Map.put("evidence", [])
    end
  end

  defp merge_criterion(criterion, nil, _actor), do: criterion

  defp complete_criterion(criteria, id, evidence, actor) do
    update_criterion(criteria, id, fn criterion ->
      entry = %{"at" => now(), "actor" => actor_json(actor), "evidence" => stringify_keys(evidence)}

      criterion
      |> Map.put("completed", true)
      |> Map.put("evidence", stringify_keys(evidence))
      |> Map.update!("evidence_history", &(&1 ++ [entry]))
    end)
  end

  defp reopen_criterion(criteria, id, reason, actor) do
    update_criterion(criteria, id, fn criterion ->
      entry = evidence_history_entry(criterion, reason || "reopened", actor)

      criterion
      |> Map.put("completed", false)
      |> Map.put("evidence", [])
      |> Map.update!("evidence_history", &(&1 ++ [entry]))
    end)
  end

  defp update_criterion(criteria, id, function) do
    if Enum.any?(criteria, &(&1["id"] == id)) do
      {:ok, Enum.map(criteria, fn criterion -> if criterion["id"] == id, do: function.(criterion), else: criterion end)}
    else
      {:error, {:criterion_not_found, id}}
    end
  end

  defp evidence_history_entry(criterion, reason, actor) do
    %{
      "at" => now(),
      "actor" => actor_json(actor),
      "reason" => reason,
      "completed" => criterion["completed"],
      "evidence" => criterion["evidence"]
    }
  end

  defp agent_evidence(%{type: :agent}, evidence) when is_list(evidence) and evidence != [], do: :ok
  defp agent_evidence(%{type: :agent}, _evidence), do: {:error, :agent_completion_requires_evidence}
  defp agent_evidence(_actor, evidence) when is_list(evidence), do: :ok
  defp agent_evidence(_actor, _evidence), do: {:error, :invalid_evidence}

  defp resolve_dependencies(dependencies, self_id) when is_list(dependencies) do
    dependencies
    |> Enum.reduce_while({:ok, []}, fn dependency, {:ok, acc} ->
      case Projection.get_task(to_string(dependency)) do
        {:ok, task} when task.id != self_id -> {:cont, {:ok, [task.id | acc]}}
        {:ok, _task} -> {:halt, {:error, :task_cannot_depend_on_itself}}
        {:error, _reason} -> {:halt, {:error, {:dependency_not_found, dependency}}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, ids |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp resolve_dependencies(_dependencies, _self_id), do: {:error, :invalid_dependencies}

  defp optional_dependencies(attrs, task) do
    if has_key?(attrs, :dependencies) do
      resolve_dependencies(value(attrs, :dependencies), task.id)
    else
      {:ok, task.dependencies}
    end
  end

  defp dependency_cycle_free(task_id, candidate_dependencies) do
    tasks = Projection.list_tasks() ++ Projection.list_tasks(archived: true)
    graph = Map.new(tasks, fn task -> {task.id, if(task.id == task_id, do: candidate_dependencies, else: task.dependencies)} end)

    if cycle?(task_id, graph, %{}) do
      {:error, :dependency_cycle}
    else
      :ok
    end
  end

  defp cycle?(node, graph, visiting) do
    if Map.has_key?(visiting, node) do
      true
    else
      visiting = Map.put(visiting, node, true)
      Enum.any?(Map.get(graph, node, []), &cycle?(&1, graph, visiting))
    end
  end

  defp optional_neighbor(nil, _task), do: {:ok, nil}

  defp optional_neighbor(id, task) do
    case Projection.get_task(id) do
      {:ok, neighbor}
      when neighbor.column_id == task.column_id and neighbor.priority == task.priority ->
        {:ok, neighbor}

      {:ok, _neighbor} ->
        {:error, {:invalid_rank_neighbor, id}}

      {:error, _reason} ->
        {:error, {:rank_neighbor_not_found, id}}
    end
  end

  defp neighbor_order(nil, nil), do: :ok
  defp neighbor_order(%Task{}, nil), do: :ok
  defp neighbor_order(nil, %Task{}), do: :ok

  defp neighbor_order(before_task, after_task) do
    if before_task.rank < after_task.rank, do: :ok, else: {:error, :rank_neighbors_out_of_order}
  end

  defp optional_priority(attrs, current) do
    if has_key?(attrs, :priority), do: priority(value(attrs, :priority)), else: {:ok, current}
  end

  defp optional_value_string(attrs, key, current) do
    if has_key?(attrs, key), do: value_string(attrs, key), else: {:ok, current}
  end

  defp task_type(value) when value in [:feature, "feature", "Feature"], do: {:ok, :feature}
  defp task_type(value) when value in [:bug_fix, "bug_fix", "bug fix", "Bug Fix"], do: {:ok, :bug_fix}
  defp task_type(value) when value in [:chore, "chore", "Chore"], do: {:ok, :chore}
  defp task_type(value), do: {:error, {:invalid_task_type, value}}

  defp priority(value) when value in [:urgent, "urgent", "Urgent"], do: {:ok, :urgent}
  defp priority(value) when value in [:high, "high", "High"], do: {:ok, :high}
  defp priority(value) when value in [:normal, "normal", "Normal"], do: {:ok, :normal}
  defp priority(value) when value in [:low, "low", "Low"], do: {:ok, :low}
  defp priority(value), do: {:error, {:invalid_priority, value}}

  defp fetch_column(bundle, id) do
    case Bundle.column(bundle, id) do
      %Column{} = column -> {:ok, column}
      nil -> {:error, {:unknown_column, id}}
    end
  end

  defp active?(task), do: task.runtime_state in @active_runtime_states

  defp active_run(task, run) do
    if task.active_run_id == run["id"] and run["task_id"] == task.id and run["status"] in @active_runtime_states do
      :ok
    else
      {:error, :run_not_active_for_task}
    end
  end

  defp completed_run(run, outcome, status, stats) do
    finished_at = now()

    Map.merge(run, %{
      "status" => status,
      "outcome" => stringify_keys(outcome),
      "stats" => final_run_stats(run, stats, finished_at),
      "finished_at" => finished_at,
      "updated_at" => finished_at
    })
  end

  defp failed_run(run, reason, stats \\ nil) do
    finished_at = now()

    Map.merge(run, %{
      "status" => "failed",
      "failure" => inspect(reason),
      "stats" => final_run_stats(run, stats, finished_at),
      "finished_at" => finished_at,
      "updated_at" => finished_at
    })
  end

  defp final_run_stats(run, stats, finished_at) do
    stats = stats || RunStats.summary(Projection.run_telemetry(run["id"]))
    stats = stringify_keys(stats)

    %{
      "duration_ms" => run_duration_ms(run, finished_at),
      "turn_count" => non_negative_integer(stats["turn_count"]),
      "token_usage" => normalized_token_usage(stats["token_usage"])
    }
  end

  defp normalized_token_usage(usage) when is_map(usage) do
    usage = stringify_keys(usage)
    keys = ~w(input_tokens cached_input_tokens output_tokens total_tokens)

    if Enum.all?(keys, &(is_integer(usage[&1]) and usage[&1] >= 0)) do
      Map.take(usage, keys)
    end
  end

  defp normalized_token_usage(_usage), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: 0

  defp run_duration_ms(run, finished_at) do
    started_at = run["started_at"] || run["claimed_at"]

    with {:ok, started, _offset} <- DateTime.from_iso8601(started_at || ""),
         {:ok, finished, _offset} <- DateTime.from_iso8601(finished_at) do
      max(0, DateTime.diff(finished, started, :millisecond))
    else
      _ -> 0
    end
  end

  defp pull_request_creator_run(_task_id, %{"id" => created_by_run_id} = run, created_by_run_id),
    do: Map.put(run, "pull_request_created", true)

  defp pull_request_creator_run(task_id, run, created_by_run_id) when is_binary(created_by_run_id) do
    case Projection.get_run(created_by_run_id) do
      {:ok, %{"task_id" => ^task_id} = creator_run} -> Map.put(creator_run, "pull_request_created", true)
      _other -> run
    end
  end

  defp pull_request_creator_run(_task_id, run, _created_by_run_id), do: run

  defp bump(task, attrs) do
    task
    |> Map.merge(attrs)
    |> Map.put(:revision, task.revision + 1)
    |> Map.put(:updated_at, now())
  end

  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp has_key?(map, key), do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp value_string(map, key) do
    map |> value(key) |> nonempty(key)
  end

  defp nonempty(value, context) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: {:error, {:required_text, context}}, else: {:ok, trimmed}
  end

  defp nonempty(_value, context), do: {:error, {:required_text, context}}

  defp human_actor(%{type: :human}), do: :ok
  defp human_actor(actor), do: {:error, {:human_actor_required, actor}}

  defp agent_actor(%{type: :agent}), do: :ok
  defp agent_actor(actor), do: {:error, {:agent_actor_required, actor}}

  defp system_actor(%{type: :system}), do: :ok
  defp system_actor(actor), do: {:error, {:system_actor_required, actor}}

  defp system_or_agent_actor(%{type: type}) when type in [:system, :agent], do: :ok
  defp system_or_agent_actor(actor), do: {:error, {:system_or_agent_actor_required, actor}}

  defp run_failure_actor(%{type: :system}, _run), do: :ok
  defp run_failure_actor(%{type: :agent, identity: identity}, %{"id" => identity}), do: :ok
  defp run_failure_actor(actor, _run), do: {:error, {:run_failure_actor_not_permitted, actor}}

  defp actor_json(actor), do: %{"type" => Atom.to_string(actor.type), "identity" => actor.identity}

  defp sha?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{40,64}\z/i, value)
  defp sha256?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/i, value)
  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(nil), do: nil
  defp stringify_keys(value) when is_boolean(value), do: value
  defp stringify_keys(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_keys(value) when is_tuple(value), do: inspect(value)
  defp stringify_keys(value), do: value

  defp now do
    DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
  end
end
