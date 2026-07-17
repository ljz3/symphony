defmodule SymphonyElixir.DeterministicMerge do
  @moduledoc """
  Executes the deadline-free, model-free squash-merge saga for a system merge column.

  Every external operation goes through an injectable boundary. Canonical board
  checkpoints are committed before clean-update pushes and guarded PR merges so a
  restarted reconciliation can observe and finish the same effect safely.
  """

  alias SymphonyElixir.Board
  alias SymphonyElixir.Board.Commands
  alias SymphonyElixir.DeterministicMerge.SystemBoundary
  alias SymphonyElixir.ReviewAttestation
  alias SymphonyElixir.Task
  alias SymphonyElixir.Workflow.Bundle

  @type result ::
          {:ok, :completed | :conflict | :review_required | :blocked | :pending}
          | {:error, term()}

  @spec run(Task.t(), Bundle.t(), keyword()) :: result()
  def run(%Task{} = task, %Bundle{} = bundle, opts) when is_list(opts) do
    boundary =
      Keyword.get(opts, :boundary, &SystemBoundary.call/3)

    with :ok <- merge_entry_invariants(task, bundle),
         {:ok, context} <- boundary.(:ensure_worktree, task, base_context(task, bundle, opts)) do
      reconcile(task, bundle, context, boundary, opts)
    else
      {:error, {:transient, _reason}} -> {:ok, :pending}
      {:error, reason} -> block(task, reason, opts)
    end
  end

  @spec conflict_id(String.t(), String.t(), String.t(), [String.t()]) :: String.t()
  def conflict_id(task_id, task_head, target_head, paths) do
    :crypto.hash(:sha256, Enum.join([task_id, task_head, target_head | Enum.sort(paths)], "\0"))
    |> Base.encode16(case: :lower)
  end

  defp reconcile(task, bundle, context, boundary, opts) do
    case get_in(task.merge_saga || %{}, ["checkpoint"]) do
      "clean_update_started" -> recover_clean_update(task, bundle, context, boundary, opts)
      _checkpoint -> inspect_merge_readiness(task, bundle, context, boundary, opts)
    end
  end

  defp inspect_merge_readiness(task, bundle, context, boundary, opts) do
    with {:ok, source_head} <- boundary.(:source_head, task, context),
         {:ok, snapshot} <- boundary.(:review_snapshot, task, context) do
      context = Map.merge(context, %{source_head: source_head, snapshot: snapshot})
      route_snapshot(task, bundle, context, boundary, opts)
    else
      {:error, {:transient, _reason}} -> {:ok, :pending}
      {:error, :pull_request_not_linked} -> block(task, :pull_request_not_linked, opts)
      {:error, reason} -> block(task, {:merge_snapshot_failed, reason}, opts)
    end
  end

  defp route_snapshot(task, bundle, %{snapshot: snapshot} = context, boundary, opts) do
    case snapshot_state(snapshot) do
      :merged ->
        recover_merged_pull_request(task, bundle, context, boundary, opts)

      {:not_open, state} ->
        block(task, {:pull_request_not_open, state}, opts)

      :open ->
        route_open_snapshot(task, bundle, context, boundary, opts)
    end
  end

  defp snapshot_state(snapshot) do
    case snapshot_value(snapshot, :state) do
      state when state in ["MERGED", "merged"] -> :merged
      state when state in ["OPEN", "open"] -> :open
      state -> {:not_open, state}
    end
  end

  defp route_open_snapshot(task, bundle, context, boundary, opts) do
    case review_gate(task, context) do
      :ready -> run_project_readiness(task, bundle, context, boundary, opts)
      {:review, reason} -> require_review(task, reason, opts)
    end
  end

  defp review_gate(task, %{snapshot: snapshot} = context) do
    [
      {changed_pull_request_identity?(task, snapshot), "linked or observed pull-request identity changed after review"},
      {stale_review_head?(task, context), "reviewed source or pull-request head changed"},
      {changed_feedback?(task, snapshot), "pull-request feedback changed after review"},
      {changed_checks?(task, snapshot), "required check contexts changed after review"},
      {changed_criteria?(task), "acceptance criteria or evidence changed after review"},
      {not criteria_complete?(task), "acceptance criteria or evidence changed after review"},
      {snapshot_value(snapshot, :draft) != false, "pull request is draft or otherwise not ready"},
      {snapshot_value(snapshot, :approved) != true, "pull-request approval is missing or changed"},
      {snapshot_value(snapshot, :unresolved_review_threads) != 0, "pull-request review threads are unresolved"},
      {snapshot_value(snapshot, :required_checks_green) != true, "required checks are not green"}
    ]
    |> Enum.find_value(:ready, fn
      {true, reason} -> {:review, reason}
      {false, _reason} -> nil
    end)
  end

  defp run_project_readiness(task, bundle, context, boundary, opts) do
    case boundary.(:readiness, task, context) do
      {:ok, _evidence} -> revalidate_after_readiness(task, bundle, context, boundary, opts)
      {:error, {:readiness_failed, _status, _output} = reason} -> require_review(task, inspect(reason), opts)
      {:error, {:invariant, _reason} = reason} -> block(task, {:readiness_process_failed, reason}, opts)
      {:error, _reason} -> {:ok, :pending}
    end
  end

  defp revalidate_after_readiness(task, bundle, context, boundary, opts) do
    case refresh_merge_state(task, context, boundary, opts) do
      {:ok, current, refreshed} ->
        case merge_entry_invariants(current, bundle) do
          :ok -> route_refreshed_after_readiness(current, bundle, refreshed, boundary, opts)
          {:error, _reason} -> {:ok, :review_required}
        end

      {:error, _current, {:transient, _reason}} ->
        {:ok, :pending}

      {:error, current, :pull_request_not_linked} ->
        require_review(current, "pull request identity changed after readiness", opts)

      {:error, current, reason} ->
        block(current, {:post_readiness_revalidation_failed, reason}, opts)
    end
  end

  defp route_refreshed_after_readiness(task, bundle, %{snapshot: snapshot} = context, boundary, opts) do
    case snapshot_state(snapshot) do
      :open ->
        case review_gate(task, context) do
          :ready -> fetch_target(task, bundle, context, boundary, opts)
          {:review, reason} -> require_review(task, reason, opts)
        end

      :merged ->
        recover_merged_pull_request(task, bundle, context, boundary, opts)

      {:not_open, state} ->
        block(task, {:pull_request_not_open, state}, opts)
    end
  end

  defp fetch_target(task, bundle, context, boundary, opts) do
    case boundary.(:fetch_target, task, context) do
      {:ok, target_head} ->
        context = Map.put(context, :target_head, target_head)

        if snapshot_value(context.snapshot, :mergeable) == "CONFLICTING",
          do: verify_github_conflict(task, bundle, context, boundary, opts),
          else: compare_target(task, bundle, context, boundary, opts)

      {:error, {:transient, _reason}} ->
        {:ok, :pending}

      {:error, reason} ->
        block(task, {:target_fetch_failed, reason}, opts)
    end
  end

  defp compare_target(task, bundle, context, boundary, opts) do
    case boundary.(:target_ancestor, task, context) do
      {:ok, true} -> begin_squash(task, bundle, context, boundary, opts)
      {:ok, false} -> begin_clean_update(task, bundle, context, boundary, opts)
      {:error, {:transient, _reason}} -> {:ok, :pending}
      {:error, reason} -> block(task, {:target_comparison_failed, reason}, opts)
    end
  end

  defp begin_clean_update(task, bundle, context, boundary, opts) do
    attrs = %{"task_head" => context.source_head, "target_head" => context.target_head}

    with {:ok, checkpointed} <- checkpoint(task, "clean_update_started", attrs, opts) do
      perform_clean_update(checkpointed, bundle, context, boundary, opts)
    end
  end

  defp recover_clean_update(task, bundle, context, boundary, opts) do
    attrs = get_in(task.merge_saga || %{}, ["attrs"]) || %{}
    original_head = attrs["task_head"]
    target_head = attrs["target_head"]

    if valid_clean_update_checkpoint?(task, original_head, target_head) do
      resume_clean_update_checkpoint(
        task,
        bundle,
        Map.put(context, :target_head, target_head),
        original_head,
        boundary,
        opts
      )
    else
      block(task, :invalid_clean_update_checkpoint, opts)
    end
  end

  defp valid_clean_update_checkpoint?(task, original_head, target_head) do
    git_sha?(original_head) and git_sha?(target_head) and original_head == reviewed_head(task)
  end

  defp resume_clean_update_checkpoint(task, bundle, context, original_head, boundary, opts) do
    case refresh_merge_state(task, context, boundary, opts) do
      {:ok, current, refreshed} ->
        continue_clean_update_recovery(
          current,
          bundle,
          refreshed,
          original_head,
          boundary,
          opts
        )

      {:error, _current, {:transient, _reason}} ->
        {:ok, :pending}

      {:error, current, :pull_request_not_linked} ->
        require_review(current, "pull request identity changed during clean-update recovery", opts)

      {:error, current, reason} ->
        block(current, {:clean_update_recovery_failed, reason}, opts)
    end
  end

  defp continue_clean_update_recovery(task, bundle, context, original_head, boundary, opts) do
    with :ok <- merge_entry_invariants(task, bundle),
         :open <- snapshot_state(context.snapshot),
         :ready <- clean_update_identity_gate(task, context) do
      remote_head = snapshot_value(context.snapshot, :head_sha)

      cond do
        not git_sha?(remote_head) ->
          block(task, :invalid_clean_update_remote_head, opts)

        remote_head != original_head ->
          require_review(
            task,
            "remote pull-request head changed during clean-update recovery",
            opts,
            remote_head
          )

        context.source_head == original_head ->
          resume_original_clean_update(task, bundle, context, original_head, boundary, opts)

        true ->
          continue_local_clean_update_recovery(task, context, boundary, opts)
      end
    else
      {:error, _reason} -> {:ok, :review_required}
      {:not_open, state} -> block(task, {:pull_request_not_open, state}, opts)
      {:review, reason} -> require_review(task, reason, opts)
    end
  end

  defp resume_original_clean_update(task, bundle, context, original_head, boundary, opts) do
    case clean_update_push_gate(task, context, original_head) do
      :ready -> perform_clean_update(task, bundle, context, boundary, opts)
      {:review, reason} -> require_review(task, reason, opts)
    end
  end

  defp continue_local_clean_update_recovery(task, context, boundary, opts) do
    case clean_update_push_gate(task, context, context.source_head) do
      :ready ->
        case boundary.(:target_ancestor, task, context) do
          {:ok, true} -> revalidate_clean_update(task, context, boundary, opts)
          {:ok, false} -> require_review(task, "source head changed during target update", opts)
          {:error, {:transient, _reason}} -> {:ok, :pending}
          {:error, reason} -> block(task, {:clean_update_recovery_failed, reason}, opts)
        end

      {:review, reason} ->
        require_review(task, reason, opts)
    end
  end

  defp perform_clean_update(task, bundle, context, boundary, opts) do
    case boundary.(:merge_target, task, context) do
      {:ok, updated_head} when is_binary(updated_head) ->
        revalidate_clean_update(
          task,
          Map.put(context, :source_head, updated_head),
          boundary,
          opts
        )

      {:conflict, paths} ->
        record_conflict(task, bundle, context, paths, opts)

      {:error, {:transient, _reason}} ->
        {:ok, :pending}

      {:error, {:stale, _reason}} ->
        require_review(task, "task branch changed while updating the target", opts)

      {:error, reason} ->
        block(task, {:target_merge_failed, reason}, opts)
    end
  end

  defp revalidate_clean_update(task, context, boundary, opts) do
    expected_local_head = context.source_head

    case refresh_merge_state(task, context, boundary, opts) do
      {:ok, current, refreshed} ->
        route_revalidated_clean_update(current, refreshed, expected_local_head, boundary, opts)

      {:error, _current, {:transient, _reason}} ->
        {:ok, :pending}

      {:error, current, :pull_request_not_linked} ->
        require_review(current, "pull request identity changed before clean-update push", opts)

      {:error, current, reason} ->
        block(current, {:clean_update_revalidation_failed, reason}, opts)
    end
  end

  defp route_revalidated_clean_update(task, context, expected_local_head, boundary, opts) do
    with :ok <- merge_entry_invariants(task, context.bundle),
         :open <- snapshot_state(context.snapshot),
         :ready <- clean_update_identity_gate(task, context),
         :ready <- clean_update_push_gate(task, context, expected_local_head) do
      reviewed = reviewed_head(task)
      remote_head = snapshot_value(context.snapshot, :head_sha)

      cond do
        remote_head == reviewed ->
          push_clean_update(task, context, boundary, opts)

        remote_head == expected_local_head ->
          require_review(
            task,
            "target branch update was already pushed; exact-head review required",
            opts,
            remote_head
          )

        git_sha?(remote_head) ->
          require_review(task, "remote pull-request head changed before clean-update push", opts, remote_head)

        true ->
          block(task, :invalid_clean_update_remote_head, opts)
      end
    else
      {:error, _reason} -> {:ok, :review_required}
      {:not_open, state} -> block(task, {:pull_request_not_open, state}, opts)
      {:review, reason} -> require_review(task, reason, opts)
    end
  end

  defp push_clean_update(task, context, boundary, opts) do
    case boundary.(:push_head, task, context) do
      :ok ->
        require_review(
          task,
          "target branch merged into task branch; exact-head review required",
          opts,
          context.source_head
        )

      {:error, {:transient, _reason}} ->
        {:ok, :pending}

      {:error, {:stale, _reason}} ->
        require_review(task, "task branch changed while pushing target update", opts)

      {:error, reason} ->
        block(task, {:clean_update_push_failed, reason}, opts)
    end
  end

  defp verify_github_conflict(task, bundle, context, boundary, opts) do
    case boundary.(:probe_conflict, task, context) do
      {:conflict, paths} -> record_conflict(task, bundle, context, paths, opts)
      {:ok, :clean} -> require_review(task, "GitHub mergeability changed; review the current head", opts)
      {:error, {:transient, _reason}} -> {:ok, :pending}
      {:error, reason} -> block(task, {:github_conflict_verification_failed, reason}, opts)
    end
  end

  defp record_conflict(task, bundle, context, paths, opts) do
    paths = paths |> Enum.uniq() |> Enum.sort()
    id = conflict_id(task.id, context.source_head, context.target_head, paths)
    previous = get_in(task.merge_saga || %{}, ["last_conflict"])

    occurrence =
      if is_map(previous) and previous["task_head"] == context.source_head and
           previous["target_head"] == context.target_head,
         do: "repeat",
         else: "first"

    execute(
      %Commands.RecordMergeConflict{
        task_id: task.id,
        task_head: context.source_head,
        target_head: context.target_head,
        conflicted_paths: paths,
        conflict_id: id
      },
      task,
      "merge-conflict:#{id}:#{occurrence}",
      opts
    )
    |> case do
      {:ok, %Task{column_id: column_id}} ->
        if column_id == Bundle.blocked_column(bundle).id,
          do: {:ok, :blocked},
          else: {:ok, :conflict}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp begin_squash(task, bundle, context, boundary, opts) do
    attrs = %{"reviewed_head_sha" => reviewed_head(task), "target_head" => context.target_head}

    with {:ok, checkpointed} <- checkpoint(task, "squash_started", attrs, opts) do
      revalidate_before_squash(checkpointed, bundle, context, boundary, opts)
    end
  end

  defp revalidate_before_squash(task, bundle, context, boundary, opts) do
    case refresh_merge_state(task, context, boundary, opts) do
      {:ok, current, refreshed} ->
        route_revalidated_squash(current, bundle, refreshed, boundary, opts)

      {:error, _current, {:transient, _reason}} ->
        {:ok, :pending}

      {:error, current, :pull_request_not_linked} ->
        require_review(current, "pull request identity changed before guarded squash", opts)

      {:error, current, reason} ->
        block(current, {:guarded_squash_revalidation_failed, reason}, opts)
    end
  end

  defp route_revalidated_squash(task, bundle, %{snapshot: snapshot} = context, boundary, opts) do
    case merge_entry_invariants(task, bundle) do
      :ok ->
        route_current_squash_snapshot(task, bundle, context, snapshot, boundary, opts)

      {:error, _reason} ->
        {:ok, :review_required}
    end
  end

  defp route_current_squash_snapshot(task, bundle, context, snapshot, boundary, opts) do
    case snapshot_state(snapshot) do
      :open -> route_open_revalidated_squash(task, bundle, context, boundary, opts)
      :merged -> recover_merged_pull_request(task, bundle, context, boundary, opts)
      {:not_open, state} -> block(task, {:pull_request_not_open, state}, opts)
    end
  end

  defp route_open_revalidated_squash(task, bundle, context, boundary, opts) do
    case review_gate(task, context) do
      :ready -> guarded_squash(task, bundle, context, boundary, opts)
      {:review, reason} -> require_review(task, reason, opts)
    end
  end

  defp guarded_squash(task, bundle, context, boundary, opts) do
    case boundary.(:guarded_squash, task, Map.put(context, :reviewed_head, reviewed_head(task))) do
      {:ok, merge_sha} -> verify_reachability(task, bundle, context, merge_sha, boundary, opts)
      {:conflict, _provider_reason} -> verify_github_conflict(task, bundle, context, boundary, opts)
      {:error, {:transient, _reason}} -> {:ok, :pending}
      {:error, {:stale, _reason}} -> require_review(task, "pull-request head changed before guarded squash", opts)
      {:error, {:missing_or_closed_pr, reason}} -> block(task, reason, opts)
      {:error, reason} -> block(task, {:guarded_squash_failed, reason}, opts)
    end
  end

  defp recover_merged_pull_request(task, bundle, context, boundary, opts) do
    checkpoint = get_in(task.merge_saga || %{}, ["checkpoint"])
    merge_sha = snapshot_value(context.snapshot, :merge_sha)

    if checkpoint in ["squash_started", "reachability_pending"] and git_sha?(merge_sha) and
         matching_review_attestation?(task, context) do
      verify_reachability(task, bundle, context, merge_sha, boundary, opts)
    else
      block(task, :pull_request_merged_without_matching_saga_checkpoint, opts)
    end
  end

  defp verify_reachability(task, _bundle, context, merge_sha, boundary, opts) do
    with {:ok, target_head} <- boundary.(:fetch_target, task, context),
         reachability_context <- Map.merge(context, %{merge_sha: merge_sha, target_head: target_head}),
         {:ok, reachable} <- boundary.(:reachable, task, reachability_context) do
      route_reachability(reachable, task, merge_sha, target_head, opts)
    else
      {:error, {:transient, _reason}} -> {:ok, :pending}
      {:error, reason} -> block(task, {:merge_reachability_failed, reason}, opts)
    end
  end

  defp route_reachability(true, task, merge_sha, target_head, opts) do
    complete(task, merge_sha, target_head, opts)
  end

  defp route_reachability(false, task, merge_sha, target_head, opts) do
    attrs = %{"merge_sha" => merge_sha, "target_head" => target_head}

    case checkpoint(task, "reachability_pending", attrs, opts) do
      {:ok, _checkpointed} -> {:ok, :pending}
      {:error, reason} -> {:error, reason}
    end
  end

  defp complete(task, merge_sha, target_head, opts) do
    execute(
      %Commands.CompleteDeterministicMerge{
        task_id: task.id,
        reviewed_head_sha: reviewed_head(task),
        merge_sha: merge_sha,
        target_head: target_head
      },
      task,
      "merge-completed:#{task.id}:#{merge_sha}",
      opts
    )
    |> case do
      {:ok, _task} -> {:ok, :completed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_review(task, reason, opts, head_sha \\ nil) do
    key = "review-required:#{task.id}:#{task.revision}:#{fingerprint(reason)}"

    case execute(
           %Commands.InvalidateReviewAttestation{task_id: task.id, reason: reason, head_sha: head_sha},
           task,
           key,
           opts
         ) do
      {:ok, _task} -> {:ok, :review_required}
      {:error, reason} -> {:error, reason}
    end
  end

  defp block(task, reason, opts) do
    reason = inspect(reason)
    key = "merge-blocked:#{task.id}:#{task.revision}:#{fingerprint(reason)}"

    case execute(%Commands.BlockTask{task_id: task.id, reason: reason}, task, key, opts) do
      {:ok, _task} -> {:ok, :blocked}
      {:error, board_reason} -> {:error, board_reason}
    end
  end

  defp checkpoint(task, name, attrs, opts) do
    key = "merge-checkpoint:#{task.id}:#{task.revision}:#{name}:#{fingerprint(attrs)}"

    execute(
      %Commands.RecordMergeCheckpoint{task_id: task.id, checkpoint: name, attrs: attrs},
      task,
      key,
      opts
    )
  end

  defp execute(command, task, key, opts) do
    executor = Keyword.get(opts, :board_executor, &Board.execute/2)

    with {:ok, %{"task" => task_map}} <-
           executor.(command,
             actor: %{type: :system, identity: "deterministic-merge"},
             expected_revision: task.revision,
             idempotency_key: key
           ) do
      {:ok, Task.from_map(task_map)}
    end
  end

  defp merge_entry_invariants(task, bundle) do
    with %{role: :merge} <- Bundle.column(bundle, task.column_id),
         %{} <- bundle.merge,
         nil <- task.active_run_id,
         nil <- task.runtime_state,
         %{
           "verdict" => "pass",
           "reviewed_head_sha" => head,
           "criteria_fingerprint" => criteria_fingerprint,
           "pull_request_number" => pull_request_number
         } <- task.review_attestation,
         true <- git_sha?(head),
         true <- is_binary(criteria_fingerprint),
         true <- is_integer(pull_request_number) and pull_request_number > 0 do
      :ok
    else
      _ -> {:error, :invalid_system_merge_entry}
    end
  end

  defp stale_review_head?(task, context) do
    reviewed = reviewed_head(task)
    snapshot = context.snapshot

    context.source_head != reviewed or snapshot_value(snapshot, :source_head_sha) != reviewed or
      snapshot_value(snapshot, :head_sha) != reviewed or task.source["head_sha"] != reviewed or
      task.github["head_sha"] != reviewed
  end

  defp matching_review_attestation?(task, context) do
    not changed_pull_request_identity?(task, context.snapshot) and
      not changed_criteria?(task) and
      not changed_feedback?(task, context.snapshot) and
      not changed_checks?(task, context.snapshot) and
      not stale_review_head?(task, context)
  end

  defp changed_pull_request_identity?(task, snapshot) do
    attested = task.review_attestation["pull_request_number"]

    not (is_integer(attested) and attested > 0 and task.github["number"] == attested and
           snapshot_value(snapshot, :number) == attested)
  end

  defp changed_feedback?(task, snapshot) do
    snapshot_value(snapshot, :feedback_fingerprint) != task.review_attestation["feedback_fingerprint"]
  end

  defp changed_checks?(task, snapshot) do
    snapshot_value(snapshot, :checks_fingerprint) != task.review_attestation["checks_fingerprint"]
  end

  defp changed_criteria?(task) do
    task.review_attestation["criteria_fingerprint"] !=
      ReviewAttestation.criteria_fingerprint(task.acceptance_criteria)
  end

  defp clean_update_identity_gate(task, context) do
    reviewed = reviewed_head(task)

    [
      {changed_pull_request_identity?(task, context.snapshot), "linked or observed pull-request identity changed during clean update"},
      {changed_criteria?(task), "acceptance criteria or evidence changed during clean update"},
      {snapshot_value(context.snapshot, :draft) != false, "pull request is draft or otherwise not ready"},
      {task.source["head_sha"] != reviewed or task.github["head_sha"] != reviewed, "canonical source or pull-request head changed during clean update"}
    ]
    |> first_review_reason()
  end

  defp clean_update_push_gate(task, context, expected_local_head) do
    snapshot = context.snapshot

    [
      {context.source_head != expected_local_head or
         snapshot_value(snapshot, :source_head_sha) != expected_local_head, "local source head changed before clean-update push"},
      {changed_feedback?(task, snapshot), "pull-request feedback changed after review"},
      {changed_checks?(task, snapshot), "required check contexts changed after review"},
      {not criteria_complete?(task), "acceptance criteria or evidence changed after review"},
      {snapshot_value(snapshot, :draft) != false, "pull request is draft or otherwise not ready"},
      {snapshot_value(snapshot, :approved) != true, "pull-request approval is missing or changed"},
      {snapshot_value(snapshot, :unresolved_review_threads) != 0, "pull-request review threads are unresolved"},
      {snapshot_value(snapshot, :required_checks_green) != true, "required checks are not green"}
    ]
    |> first_review_reason()
  end

  defp first_review_reason(checks) do
    Enum.find_value(checks, :ready, fn
      {true, reason} -> {:review, reason}
      {false, _reason} -> nil
    end)
  end

  defp criteria_complete?(task) do
    Enum.all?(task.acceptance_criteria, fn criterion ->
      criterion["completed"] == true and is_list(criterion["evidence"]) and criterion["evidence"] != []
    end)
  end

  defp reviewed_head(task), do: task.review_attestation["reviewed_head_sha"]

  defp refresh_merge_state(task, context, boundary, opts) do
    loader = Keyword.get(opts, :task_loader, &Board.task/1)

    case loader.(task.id) do
      {:ok, %Task{} = current} ->
        refresh_external_state(current, context, boundary)

      {:ok, task_map} when is_map(task_map) ->
        refresh_external_state(Task.from_map(task_map), context, boundary)

      {:error, reason} ->
        {:error, task, {:task_reload_failed, reason}}

      other ->
        {:error, task, {:invalid_task_reload_result, other}}
    end
  end

  defp refresh_external_state(task, context, boundary) do
    with {:ok, source_head} <- boundary.(:source_head, task, context),
         {:ok, snapshot} <- boundary.(:review_snapshot, task, context) do
      {:ok, task, Map.merge(context, %{source_head: source_head, snapshot: snapshot})}
    else
      {:error, reason} -> {:error, task, reason}
    end
  end

  defp base_context(task, bundle, opts) do
    location =
      Keyword.get_lazy(opts, :location, fn ->
        opts
        |> Keyword.get_lazy(:run_history, fn -> Board.runs(task.id) end)
        |> last_location()
      end)

    %{
      bundle: bundle,
      worktree: location[:worktree],
      worker_host: location[:worker_host],
      readiness_command: bundle.merge.readiness_command
    }
  end

  defp last_location(runs) do
    case runs do
      [%{"workspace_path" => path, "worker_host" => host} | _] when is_binary(path) ->
        %{worktree: path, worker_host: host}

      [%{"worker_host" => host} | _] ->
        %{worktree: nil, worker_host: host}

      _ ->
        %{worktree: nil, worker_host: nil}
    end
  end

  defp snapshot_value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp git_sha?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{40,64}\z/i, value)

  defp fingerprint(value) do
    :crypto.hash(:sha256, if(is_binary(value), do: value, else: Jason.encode!(value)))
    |> Base.encode16(case: :lower)
  end

  defmodule SystemBoundary do
    @moduledoc false

    alias SymphonyElixir.GitHub
    alias SymphonyElixir.GitHub.Client
    alias SymphonyElixir.{ManagedCommand, SSH, Worktree}

    @spec call(atom(), SymphonyElixir.Task.t(), map()) :: term()
    def call(:ensure_worktree, task, context) do
      worktree_module = Map.get(context, :worktree_module, Worktree)

      case context.worktree do
        path when is_binary(path) ->
          case worktree_module.reconcile(task, path, context.worker_host) do
            {:ok, _state} -> {:ok, Map.put(context, :worktree, path)}
            {:error, {:ssh_transport_failed, 255, _diagnostic} = reason} -> {:error, {:transient, reason}}
            {:error, reason} -> {:error, {:invariant, {:worktree_reconcile_failed, reason}}}
          end

        nil ->
          case worktree_module.ensure(task, context.worker_host) do
            {:ok, path} -> {:ok, Map.put(context, :worktree, path)}
            {:error, reason} -> {:error, classify_failure(reason)}
          end
      end
    end

    def call(:source_head, _task, context) do
      worktree_module = Map.get(context, :worktree_module, Worktree)

      context.worktree
      |> worktree_module.head(context.worker_host)
      |> classify_result()
    end

    def call(:review_snapshot, task, context) do
      task
      |> GitHub.review_snapshot(context.worktree, worker_host: context.worker_host)
      |> classify_result()
    end

    def call(:readiness, task, context), do: readiness(task, context)

    def call(:fetch_target, _task, context) do
      remote = remote(context)
      branch = context.bundle.source.default_branch

      with {:ok, _output} <- git(context, ["fetch", "--prune", remote, branch]),
           {:ok, output} <- git(context, ["rev-parse", "#{remote}/#{branch}"]) do
        {:ok, String.trim(output)}
      end
    end

    def call(:target_ancestor, _task, context) do
      case git_status(context, ["merge-base", "--is-ancestor", context.target_head, "HEAD"]) do
        {:ok, _output, 0} -> {:ok, true}
        {:ok, _output, 1} -> {:ok, false}
        {:ok, output, status} -> {:error, {:git_failed, status, String.trim(output)}}
        {:error, reason} -> {:error, reason}
      end
    end

    def call(:merge_target, _task, context), do: merge_target(context, true)
    def call(:probe_conflict, _task, context), do: merge_target(context, false)

    def call(:push_head, task, context) do
      remote = remote(context)

      case git(context, ["push", remote, "HEAD:refs/heads/#{task.branch}"]) do
        {:ok, _output} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    def call(:guarded_squash, task, context) do
      directory = github_directory(context)
      number = task.github["number"]

      with true <- is_integer(number) and number > 0,
           {:ok, _output} <-
             Client.run(
               [
                 "pr",
                 "merge",
                 Integer.to_string(number),
                 "--squash",
                 "--match-head-commit",
                 context.reviewed_head
               ],
               cd: directory
             ),
           {:ok, pr} <-
             Client.json(
               ["pr", "view", Integer.to_string(number), "--json", "headRefOid,mergeCommit,state"],
               cd: directory
             ),
           true <- pr["headRefOid"] == context.reviewed_head,
           "MERGED" <- pr["state"],
           merge_sha when is_binary(merge_sha) <- get_in(pr, ["mergeCommit", "oid"]) do
        {:ok, merge_sha}
      else
        false ->
          {:error, {:stale, :guarded_head_mismatch}}

        state when state in ["CLOSED", "closed"] ->
          {:error, {:missing_or_closed_pr, state}}

        state when is_binary(state) ->
          {:error, {:transient, {:merge_not_terminal, state}}}

        {:error, reason} ->
          case classify_merge_failure(reason) do
            {:conflict, _reason} = conflict -> conflict
            classified -> {:error, classified}
          end

        _ ->
          {:error, {:invariant, :invalid_guarded_merge_result}}
      end
    end

    def call(:reachable, _task, context) do
      case git_status(context, ["merge-base", "--is-ancestor", context.merge_sha, context.target_head]) do
        {:ok, _output, 0} -> {:ok, true}
        {:ok, _output, 1} -> {:ok, false}
        {:ok, output, status} -> {:error, {:git_failed, status, String.trim(output)}}
        {:error, reason} -> {:error, reason}
      end
    end

    def call(operation, _task, _context), do: {:error, {:invariant, {:unsupported_merge_operation, operation}}}

    defp merge_target(context, commit?) do
      args =
        if commit?,
          do: ["merge", "--no-edit", context.target_head],
          else: ["merge", "--no-commit", "--no-ff", context.target_head]

      case git_status(context, args) do
        {:ok, _output, 0} when commit? ->
          with {:ok, output} <- git(context, ["rev-parse", "HEAD"]) do
            {:ok, String.trim(output)}
          end

        {:ok, _output, 0} ->
          case abort_merge(context, true) do
            :ok -> {:ok, :clean}
            {:error, reason} -> {:error, reason}
          end

        {:ok, output, _status} ->
          conflict_or_failure(context, args, output)

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp conflict_or_failure(context, args, output) do
      case git(context, ["diff", "--name-only", "--diff-filter=U"]) do
        {:ok, paths_output} ->
          paths = String.split(paths_output, ~r/\R/, trim: true) |> Enum.sort()
          route_conflict_paths(paths, context, args, output)

        {:error, reason} ->
          abort_with_result(context, {:error, reason})
      end
    end

    defp route_conflict_paths([], context, args, output) do
      abort_with_result(context, {:error, {:git_failed, args, String.trim(output)}})
    end

    defp route_conflict_paths(paths, context, _args, _output) do
      case abort_merge(context) do
        :ok -> {:conflict, paths}
        {:error, reason} -> {:error, reason}
      end
    end

    defp abort_with_result(context, result) do
      case abort_merge(context, true) do
        :ok -> result
        {:error, _reason} = error -> error
      end
    end

    defp abort_merge(context, allow_no_merge? \\ false) do
      case git_status(context, ["merge", "--abort"]) do
        {:ok, output, status} ->
          cond do
            status == 0 -> :ok
            allow_no_merge? and status == 128 -> verify_no_merge_in_progress(context)
            true -> {:error, {:merge_abort_failed, status, output}}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp verify_no_merge_in_progress(context) do
      case git_status(context, ["rev-parse", "-q", "--verify", "MERGE_HEAD"]) do
        {:ok, _output, 1} -> :ok
        {:ok, output, status} -> {:error, {:merge_abort_unverified, status, String.trim(output)}}
        {:error, reason} -> {:error, reason}
      end
    end

    defp readiness(task, context) do
      command = context.readiness_command
      env = readiness_env(task)

      case ManagedCommand.run(command, context.worktree, env, context.worker_host,
             cancellation_message: {:cancel_deterministic_merge, task.id},
             cancellation_reason: :merge_readiness_cancelled
           ) do
        {:ok, {output, 0}} -> {:ok, output}
        {:ok, {output, status}} -> {:error, {:readiness_failed, status, output}}
        {:error, :bash_not_found} -> {:error, {:invariant, :bash_not_found}}
        {:error, reason} when is_binary(context.worker_host) -> {:error, {:transient, reason}}
        {:error, reason} -> {:error, {:readiness_transport_failed, inspect(reason)}}
      end
    rescue
      error -> {:error, {:readiness_transport_failed, Exception.message(error)}}
    end

    defp readiness_env(task) do
      [
        {"SYMPHONY_TASK_ID", task.id},
        {"SYMPHONY_TASK_IDENTIFIER", task.identifier},
        {"SYMPHONY_TASK_BRANCH", task.branch},
        {"SYMPHONY_REVIEWED_HEAD_SHA", task.review_attestation["reviewed_head_sha"]}
      ]
    end

    defp git(context, args) do
      case git_status(context, args) do
        {:ok, output, 0} -> {:ok, output}
        {:ok, output, status} -> {:error, classify_failure({:git_failed, args, status, String.trim(output)})}
        {:error, reason} -> {:error, reason}
      end
    end

    defp git_status(%{git_status_runner: runner} = context, args) when is_function(runner, 2) do
      runner.(context, args)
    end

    defp git_status(context, args) do
      if context.worker_host do
        command =
          ["git", "-C", context.worktree | args]
          |> Enum.map_join(" ", &shell_escape/1)

        case SSH.run(context.worker_host, command) do
          {:ok, {output, status}} -> {:ok, output, status}
          {:error, reason} -> {:error, {:transient, reason}}
        end
      else
        case System.find_executable("git") do
          nil ->
            {:error, {:invariant, :git_not_found}}

          git ->
            {output, status} = System.cmd(git, ["-C", context.worktree | args], stderr_to_stdout: true)
            {:ok, output, status}
        end
      end
    rescue
      error -> {:error, {:git_transport_failed, args, Exception.message(error)}}
    end

    defp remote(%{worker_host: host}) when is_binary(host), do: "origin"
    defp remote(context), do: context.bundle.source.remote

    defp github_directory(%{worker_host: nil, worktree: worktree}), do: worktree
    defp github_directory(context), do: context.bundle.source.root

    defp classify_result({:ok, value}), do: {:ok, value}
    defp classify_result({:error, reason}), do: {:error, classify_failure(reason)}

    defp classify_merge_failure(reason) do
      text = merge_failure_text(reason)

      cond do
        String.contains?(text, "conflict") -> {:conflict, reason}
        String.contains?(text, ["head commit", "head branch", "match-head"]) -> {:stale, reason}
        true -> classify_failure(reason)
      end
    end

    defp merge_failure_text({:gh_failed, _args, _status, output}) when is_binary(output),
      do: String.downcase(output)

    defp merge_failure_text(reason), do: inspect(reason) |> String.downcase()

    defp classify_failure({kind, _reason} = tagged) when kind in [:transient, :stale, :invariant], do: tagged

    defp classify_failure(reason) do
      text = inspect(reason) |> String.downcase()

      cond do
        String.contains?(text, ["non-fast-forward", "fetch first", "stale info"]) ->
          {:stale, reason}

        String.contains?(text, [
          "network",
          "timeout",
          "timed out",
          "connection",
          "authentication",
          "authorization",
          "not logged",
          "rate limit",
          "could not resolve",
          "remote end hung up",
          "process",
          "transport"
        ]) ->
          {:transient, reason}

        true ->
          {:invariant, reason}
      end
    end

    defp shell_escape(value) do
      "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"
    end
  end
end
