defmodule SymphonyElixir.MergeConflictResolution do
  @moduledoc """
  Verifies a conflict-stage repair before its one atomic return to review.

  The proof binds the current conflict run to a clean, pushed merge of the
  recorded parent pair, resolution changes restricted to the recorded paths,
  one successful frozen job for the exact final source, and the live pull
  request head.
  """

  alias SymphonyElixir.{Config, GitHub, JobManager, SSH, Task}

  @type conflict :: %{
          required(String.t()) => String.t() | [String.t()]
        }

  @spec verify(Task.t(), map(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(%Task{} = task, run, worktree, opts \\ [])
      when is_map(run) and is_binary(worktree) and is_list(opts) do
    source_snapshotter = Keyword.get(opts, :source_snapshotter, &source_snapshot/4)
    source_fingerprinter = Keyword.get(opts, :source_fingerprinter, &JobManager.source_fingerprint/2)
    job_success_finder = Keyword.get(opts, :job_success_finder, &JobManager.successful_for_source/3)
    provider_snapshotter = Keyword.get(opts, :provider_snapshotter, &GitHub.pull_request_source_snapshot/3)
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, conflict} <- current_conflict(task),
         :ok <- current_conflict_run(task, run),
         :ok <- canonical_recorded_heads(task, conflict),
         {:ok, source} <- source_snapshotter.(task, worktree, conflict, opts),
         :ok <- valid_source_snapshot(source, conflict),
         source_fingerprint when is_binary(source_fingerprint) <-
           source_fingerprinter.(worktree, worker_host),
         {:ok, frozen_jobs} <- frozen_jobs(run),
         {:ok, job} <- job_success_finder.(run["id"], frozen_jobs, source_fingerprint),
         :ok <- valid_job_proof(job, run, frozen_jobs, source_fingerprint),
         {:ok, provider} <- provider_snapshotter.(task, worktree, worker_host: worker_host),
         :ok <- valid_provider_snapshot(provider, task, source),
         {:ok, final_source} <- source_snapshotter.(task, worktree, conflict, opts),
         true <- final_source == source,
         final_fingerprint when is_binary(final_fingerprint) <-
           source_fingerprinter.(worktree, worker_host),
         true <- final_fingerprint == source_fingerprint do
      {:ok, resolution_proof(run, conflict, source, source_fingerprint, job, provider)}
    else
      false -> {:error, :merge_conflict_source_changed_during_verification}
      {:error, reason} -> {:error, reason}
      _value -> {:error, :merge_conflict_source_fingerprint_failed}
    end
  end

  @doc false
  @spec source_snapshot(Task.t(), Path.t(), conflict(), keyword()) :: {:ok, map()} | {:error, term()}
  def source_snapshot(%Task{} = task, worktree, conflict, opts)
      when is_binary(worktree) and is_map(conflict) and is_list(opts) do
    system_runner = Keyword.get(opts, :system_command_runner, &System.cmd/3)

    runner =
      Keyword.get(
        opts,
        :git_runner,
        &default_git_runner(&1, &2, Keyword.get(opts, :worker_host), system_runner)
      )

    remote = if Keyword.get(opts, :worker_host), do: "origin", else: Config.bundle!().source.remote

    with {:ok, status, 0} <- runner.(worktree, ["status", "--porcelain=v1", "--untracked-files=all"]),
         :ok <- clean_status(status),
         {:ok, head, 0} <- runner.(worktree, ["rev-parse", "HEAD"]),
         final_head when is_binary(final_head) <- normalize_sha(head),
         {:ok, remote_output, 0} <-
           runner.(worktree, ["ls-remote", "--heads", remote, "refs/heads/#{task.branch}"]),
         {:ok, remote_head} <- remote_head(remote_output),
         :ok <- pushed_head(remote_head, final_head),
         {:ok, history} <- history_proof(runner, worktree, final_head, conflict) do
      {:ok,
       %{
         "clean" => true,
         "final_head_sha" => final_head,
         "remote_head_sha" => remote_head,
         "merge_commit_sha" => history.merge_commit_sha,
         "conflicted_paths" => history.conflicted_paths
       }}
    else
      nil -> {:error, :merge_conflict_invalid_source_head}
      {:error, reason} -> {:error, reason}
      _value -> {:error, :merge_conflict_source_inspection_failed}
    end
  end

  defp history_proof(runner, worktree, _final_head, conflict) do
    with {:ok, history, 0} <- runner.(worktree, ["rev-list", "--first-parent", "--parents", "HEAD"]),
         merge_commit when is_binary(merge_commit) <- merge_commit(history, conflict),
         {:ok, merge_tree, merge_status} <-
           runner.(worktree, [
             "merge-tree",
             "--write-tree",
             "--name-only",
             "--no-messages",
             conflict["task_head"],
             conflict["target_head"]
           ]),
         true <- merge_status == 1,
         {:ok, automatic_tree, conflicted_paths} <- parse_merge_tree(merge_tree),
         true <- conflicted_paths == conflict["conflicted_paths"],
         {:ok, resolution_paths, 0} <-
           runner.(worktree, ["diff", "--name-only", automatic_tree, "#{merge_commit}^{tree}"]),
         :ok <- recorded_paths_only(resolution_paths, conflicted_paths),
         :ok <- followup_paths(runner, worktree, merge_commit, conflicted_paths) do
      {:ok, %{merge_commit_sha: merge_commit, conflicted_paths: conflicted_paths}}
    else
      false -> {:error, :merge_conflict_stale}
      nil -> {:error, :merge_conflict_wrong_topology}
      {:error, reason} -> {:error, reason}
      _value -> {:error, :merge_conflict_history_inspection_failed}
    end
  end

  defp followup_paths(runner, worktree, merge_commit, recorded_paths) do
    case runner.(worktree, ["rev-list", "--first-parent", "#{merge_commit}..HEAD"]) do
      {:ok, output, 0} -> inspect_followup_commits(lines(output), runner, worktree, recorded_paths)
      {:ok, _output, status} -> {:error, {:merge_conflict_git_failed, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp inspect_followup_commits(commits, runner, worktree, recorded_paths) do
    Enum.reduce_while(commits, :ok, fn commit, :ok ->
      commit
      |> followup_diff(runner, worktree)
      |> followup_reduction(recorded_paths)
    end)
  end

  defp followup_diff(commit, runner, worktree) do
    runner.(worktree, [
      "diff-tree",
      "--no-commit-id",
      "--name-only",
      "-r",
      "#{commit}^1",
      commit
    ])
  end

  defp followup_reduction({:ok, changed, 0}, recorded_paths) do
    case recorded_paths_only(changed, recorded_paths) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp followup_reduction({:ok, _output, status}, _recorded_paths),
    do: {:halt, {:error, {:merge_conflict_git_failed, status}}}

  defp followup_reduction({:error, reason}, _recorded_paths),
    do: {:halt, {:error, reason}}

  defp current_conflict(%Task{
         merge_saga: %{
           "checkpoint" => "conflict_recorded",
           "last_conflict" =>
             %{
               "id" => id,
               "task_head" => task_head,
               "target_head" => target_head,
               "conflicted_paths" => paths
             } = conflict
         }
       })
       when is_binary(id) and is_binary(task_head) and is_binary(target_head) and is_list(paths) and
              paths != [] do
    if paths == Enum.sort(Enum.uniq(paths)), do: {:ok, conflict}, else: {:error, :merge_conflict_stale}
  end

  defp current_conflict(_task), do: {:error, :merge_conflict_stale}

  defp current_conflict_run(task, run) do
    if task.active_run_id == run["id"] and run["task_id"] == task.id and
         run["status"] in ["starting", "running", "stopping"],
       do: :ok,
       else: {:error, :merge_conflict_run_not_current}
  end

  defp canonical_recorded_heads(task, conflict) do
    if task.source["head_sha"] == conflict["task_head"] and
         task.github["head_sha"] == conflict["task_head"],
       do: :ok,
       else: {:error, :merge_conflict_stale}
  end

  defp frozen_jobs(%{"frozen_bundle" => %{"jobs" => jobs}}) when is_map(jobs) and map_size(jobs) > 0,
    do: {:ok, jobs}

  defp frozen_jobs(_run), do: {:error, :conflict_validation_missing}

  defp valid_source_snapshot(source, conflict) do
    valid =
      is_map(source) and source["clean"] == true and sha?(source["final_head_sha"]) and
        source["remote_head_sha"] == source["final_head_sha"] and
        sha?(source["merge_commit_sha"]) and
        source["conflicted_paths"] == conflict["conflicted_paths"]

    if valid, do: :ok, else: {:error, :merge_conflict_invalid_source_proof}
  end

  defp valid_job_proof(job, run, frozen_jobs, source_fingerprint) when is_map(job) do
    frozen_job = frozen_jobs[job["job"]]

    valid =
      is_map(frozen_job) and nonblank?(job["job_id"]) and job["run_id"] == run["id"] and
        job["status"] == "completed" and job["exit_code"] == 0 and
        job["source_fingerprint"] == source_fingerprint and
        job["job_definition_fingerprint"] == JobManager.job_definition_fingerprint(frozen_job)

    if valid, do: :ok, else: {:error, :merge_conflict_invalid_validation_proof}
  end

  defp valid_job_proof(_job, _run, _frozen_jobs, _source_fingerprint),
    do: {:error, :merge_conflict_invalid_validation_proof}

  defp valid_provider_snapshot(provider, task, source) do
    valid =
      is_map(provider) and is_integer(provider["number"]) and provider["number"] > 0 and
        provider["number"] == task.github["number"] and
        provider["state"] == "OPEN" and provider["head_sha"] == source["final_head_sha"]

    if valid, do: :ok, else: {:error, :merge_conflict_pull_request_head_mismatch}
  end

  defp resolution_proof(run, conflict, source, source_fingerprint, job, provider) do
    %{
      "conflict_id" => conflict["id"],
      "task_head" => conflict["task_head"],
      "target_head" => conflict["target_head"],
      "conflicted_paths" => conflict["conflicted_paths"],
      "run_id" => run["id"],
      "final_head_sha" => source["final_head_sha"],
      "remote_head_sha" => source["remote_head_sha"],
      "merge_commit_sha" => source["merge_commit_sha"],
      "source_fingerprint" => source_fingerprint,
      "job" => Map.take(job, ~w(job_id job status exit_code run_id source_fingerprint job_definition_fingerprint)),
      "pull_request" => %{
        "number" => provider["number"],
        "head_sha" => provider["head_sha"],
        "state" => provider["state"]
      }
    }
  end

  defp merge_commit(history, %{"task_head" => expected_task, "target_head" => expected_target}) do
    history
    |> lines()
    |> Enum.find_value(fn line ->
      case String.split(line, " ", trim: true) do
        [commit, task_head, target_head]
        when task_head == expected_task and target_head == expected_target ->
          normalize_sha(commit)

        _parts ->
          nil
      end
    end)
  end

  defp parse_merge_tree(output) do
    case lines(output) do
      [tree | paths] ->
        case normalize_sha(tree) do
          nil -> {:error, :merge_conflict_invalid_automatic_tree}
          automatic_tree -> {:ok, automatic_tree, Enum.sort(paths)}
        end

      [] ->
        {:error, :merge_conflict_invalid_automatic_tree}
    end
  end

  defp recorded_paths_only(output, recorded_paths) do
    outside = lines(output) -- recorded_paths
    if outside == [], do: :ok, else: {:error, {:merge_conflict_out_of_scope_paths, Enum.sort(outside)}}
  end

  defp remote_head(output) do
    case lines(output) do
      [line] ->
        case line |> String.split(~r/\s+/, trim: true) |> List.first() |> normalize_sha() do
          nil -> {:error, :merge_conflict_unpushed}
          head -> {:ok, head}
        end

      _lines ->
        {:error, :merge_conflict_unpushed}
    end
  end

  defp clean_status(output) do
    if String.trim(output) == "", do: :ok, else: {:error, :merge_conflict_worktree_dirty}
  end

  defp pushed_head(head, head), do: :ok
  defp pushed_head(_remote_head, _final_head), do: {:error, :merge_conflict_unpushed}

  defp default_git_runner(worktree, arguments, nil, system_runner) do
    case System.find_executable("git") do
      nil ->
        {:error, :git_not_found}

      git ->
        {output, status} = system_runner.(git, ["-C", worktree | arguments], stderr_to_stdout: true)
        {:ok, output, status}
    end
  rescue
    error -> {:error, {:git_transport_failed, Exception.message(error)}}
  end

  defp default_git_runner(worktree, arguments, worker_host, _system_runner) when is_binary(worker_host) do
    command = ["git", "-C", worktree | arguments] |> Enum.map_join(" ", &shell_escape/1)

    case SSH.run(worker_host, command) do
      {:ok, {output, status}} -> {:ok, output, status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lines(value), do: String.split(value, ~r/\R/, trim: true)

  defp normalize_sha(value) when is_binary(value) do
    value = String.trim(value)
    if sha?(value), do: String.downcase(value), else: nil
  end

  defp normalize_sha(_value), do: nil
  defp sha?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{40,64}\z/i, value)
  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
  defp shell_escape(value), do: "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
end
