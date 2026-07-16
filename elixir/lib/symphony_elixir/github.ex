defmodule SymphonyElixir.GitHub do
  @moduledoc """
  GitHub pull-request lifecycle and resumable external-effect gates implemented
  exclusively through the service-owned `gh` CLI client.
  """

  alias SymphonyElixir.Board.{Projection, WorkpadStore}
  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.Paths
  alias SymphonyElixir.Task
  alias SymphonyElixir.Worktree

  @green_states ["SUCCESS", "NEUTRAL", "SKIPPED"]
  @no_checks_pattern ~r/\Ano (?:required )?checks reported on the '.+' branch\z/

  @spec health() :: map()
  def health do
    bundle = Config.bundle!()

    with {:ok, url} <- source_remote_url(bundle),
         {:ok, host} <- github_host(url),
         {:ok, _output} <- Client.run(["auth", "status", "--hostname", host]),
         {:ok, _output} <- Client.run(["api", "--hostname", host, "rate_limit"]) do
      %{available: true, authenticated: true, host: host, remote_url: url, error: nil}
    else
      {:error, reason} -> %{available: false, authenticated: false, host: nil, remote_url: nil, error: reason}
    end
  rescue
    error -> %{available: false, authenticated: false, host: nil, remote_url: nil, error: error}
  end

  @spec ensure_dispatch_ready() :: :ok | {:error, term()}
  def ensure_dispatch_ready do
    case health() do
      %{available: true, authenticated: true} -> :ok
      health -> {:error, {:github_unavailable, health}}
    end
  end

  @spec meaningful_commit?(Task.t(), Path.t()) :: {:ok, boolean()} | {:error, term()}
  def meaningful_commit?(%Task{} = task, worktree) do
    meaningful_commit?(task, worktree, [])
  end

  @spec meaningful_commit?(Task.t(), Path.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def meaningful_commit?(%Task{} = task, worktree, opts) do
    with {:ok, paths} <- Worktree.changed_paths(task, worktree, Keyword.get(opts, :worker_host)) do
      {:ok, paths != []}
    end
  end

  @spec ensure_draft_pull_request(Task.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ensure_draft_pull_request(%Task{} = task, worktree, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    run_id = Keyword.get(opts, :run_id)
    gh_directory = github_directory(worktree, worker_host)

    with :ok <- ensure_dispatch_ready(),
         {:ok, true} <- meaningful_commit?(task, worktree, opts),
         {:ok, head_sha} <- Worktree.head(worktree, worker_host),
         :ok <- Worktree.push(task, worktree, worker_host),
         {:ok, pull_request, created_by_run_id} <- find_or_create_pull_request(task, gh_directory, run_id),
         true <- pull_request["headRefOid"] == head_sha do
      {:ok,
       %{
         number: pull_request["number"],
         url: pull_request["url"],
         head_sha: pull_request["headRefOid"],
         state: String.downcase(pull_request["state"] || "OPEN"),
         draft: pull_request["isDraft"] == true,
         created_by_run_id: created_by_run_id
       }}
    else
      {:ok, false} -> {:error, :no_meaningful_committed_diff}
      false -> {:error, :pushed_pull_request_head_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec publish_workpads(Task.t(), Path.t(), keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def publish_workpads(%Task{} = task, worktree, opts \\ []) do
    gh_directory = github_directory(worktree, Keyword.get(opts, :worker_host))
    workpads = Projection.unpublished_workpads(task.id)
    publication_recorder = Keyword.get(opts, :publication_recorder, &WorkpadStore.record_publication/2)

    case workpads do
      [] ->
        {:ok, nil}

      _ ->
        with {:ok, number} <- pull_request_number(task),
             publication_id <- publication_id(task, workpads),
             {:ok, already_published} <- publication_exists?(gh_directory, number, publication_id),
             :ok <- maybe_post_publication(gh_directory, number, publication_id, workpads, already_published),
             :ok <- publication_recorder.(publication_id, workpads) do
          {:ok, publication_id}
        end
    end
  end

  @spec publish_run_stats(Task.t(), map()) :: {:ok, map() | nil} | {:error, term()}
  def publish_run_stats(%Task{} = task, run) when is_map(run) do
    with true <- is_map(run["stats"]),
         true <- run["status"] in ["completed", "stopped", "failed"] do
      if run["pull_request_created"] == true do
        publish_run_stats_to_pr_body(task, run)
      else
        publish_run_stats_to_workpad_comment(task, run)
      end
    else
      false -> {:error, :run_stats_unavailable}
    end
  end

  @spec mark_ready(Task.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def mark_ready(%Task{} = task, worktree, opts \\ []) do
    gh_directory = github_directory(worktree, Keyword.get(opts, :worker_host))

    with {:ok, readiness} <- readiness(task, worktree, opts),
         :ok <- require_ready(readiness),
         {:ok, publication_id} <- publish_workpads(task, worktree, opts),
         {:ok, number} <- pull_request_number(task),
         :ok <- maybe_mark_ready(gh_directory, number, readiness.pull_request_draft) do
      {:ok,
       %{
         completed: true,
         publication_id: publication_id,
         checked_at: timestamp(),
         prerequisites: readiness
       }}
    end
  end

  @spec readiness(Task.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def readiness(%Task{} = task, worktree, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    gh_directory = github_directory(worktree, worker_host)

    with {:ok, number} <- pull_request_number(task),
         {:ok, true} <- Worktree.clean?(worktree, worker_host),
         {:ok, head_sha} <- Worktree.head(worktree, worker_host),
         {:ok, pr} <-
           Client.json(
             [
               "pr",
               "view",
               Integer.to_string(number),
               "--json",
               "isDraft,headRefOid,reviewDecision,state,statusCheckRollup,url"
             ],
             cd: gh_directory
           ),
         {:ok, unresolved_threads} <- unresolved_review_threads(gh_directory, number),
         {:ok, required_checks} <- required_checks(gh_directory, number) do
      criteria_complete =
        Enum.all?(task.acceptance_criteria, fn criterion ->
          criterion["completed"] == true and is_list(criterion["evidence"]) and criterion["evidence"] != []
        end)

      {:ok,
       %{
         clean_worktree: true,
         pushed_matching_head: pr["headRefOid"] == head_sha,
         criteria_completed_and_evidenced: criteria_complete,
         no_requested_changes: pr["reviewDecision"] != "CHANGES_REQUESTED",
         no_unresolved_review_threads: unresolved_threads == 0,
         required_checks_green: checks_green?(required_checks),
         pull_request_open: pr["state"] == "OPEN",
         pull_request_draft: pr["isDraft"] == true,
         unresolved_review_threads: unresolved_threads,
         required_checks: required_checks,
         url: pr["url"]
       }}
    else
      {:ok, false} -> {:error, :worktree_not_clean}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the exact current source/PR head and deterministic feedback/check fingerprints for review attestation."
  @spec review_snapshot(Task.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def review_snapshot(%Task{} = task, worktree, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    directory = github_directory(worktree, worker_host)

    with {:ok, number} <- pull_request_number(task),
         {:ok, true} <- Worktree.clean?(worktree, worker_host),
         {:ok, source_head} <- Worktree.head(worktree, worker_host),
         {:ok, pr} <-
           Client.json(
             [
               "pr",
               "view",
               Integer.to_string(number),
               "--json",
               "number,headRefOid,mergeCommit,mergeable,reviewDecision,state,statusCheckRollup,url"
             ],
             cd: directory
           ),
         {:ok, threads} <- review_threads_snapshot(directory, number),
         {:ok, checks} <- required_checks(directory, number) do
      feedback = %{
        "mergeable" => pr["mergeable"],
        "review_decision" => pr["reviewDecision"],
        "threads" => threads
      }

      {:ok,
       %{
         number: pr["number"],
         url: pr["url"],
         state: pr["state"],
         head_sha: pr["headRefOid"],
         source_head_sha: source_head,
         approved: pr["reviewDecision"] == "APPROVED",
         mergeable: pr["mergeable"],
         merge_sha: get_in(pr, ["mergeCommit", "oid"]),
         unresolved_review_threads: Enum.count(threads, &(&1["is_resolved"] != true)),
         required_checks_green: checks_green?(checks),
         feedback_fingerprint: fingerprint(feedback),
         checks_fingerprint: fingerprint(checks |> Enum.map(&check_fingerprint_fields/1) |> Enum.sort()),
         observed_at: timestamp()
       }}
    else
      {:ok, false} -> {:error, :worktree_not_clean}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec convert_to_draft(Task.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def convert_to_draft(%Task{} = task, worktree, opts \\ []) do
    gh_directory = github_directory(worktree, Keyword.get(opts, :worker_host))

    with {:ok, number} <- pull_request_number(task),
         {:ok, pr} <- Client.json(["pr", "view", Integer.to_string(number), "--json", "isDraft"], cd: gh_directory) do
      if pr["isDraft"] == true do
        :ok
      else
        mark_pull_request_draft(number, gh_directory)
      end
    end
  end

  @spec close(Task.t(), Path.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def close(%Task{} = task, worktree, reason, opts \\ []) when is_binary(reason) do
    gh_directory = github_directory(worktree, Keyword.get(opts, :worker_host))

    with {:ok, number} <- pull_request_number(task),
         {:ok, pr} <- Client.json(["pr", "view", Integer.to_string(number), "--json", "state"], cd: gh_directory) do
      if pr["state"] in ["CLOSED", "MERGED"] do
        :ok
      else
        close_pull_request(number, reason, gh_directory)
      end
    end
  end

  defp mark_pull_request_draft(number, directory) do
    case Client.run(["pr", "ready", "--undo", Integer.to_string(number)], cd: directory) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp close_pull_request(number, reason, directory) do
    args = ["pr", "close", Integer.to_string(number), "--comment", "Cancelled by Symphony: #{reason}"]

    case Client.run(args, cd: directory) do
      {:ok, _output} -> :ok
      {:error, close_reason} -> {:error, close_reason}
    end
  end

  @spec merged_and_reachable(Task.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def merged_and_reachable(%Task{} = task, worktree, opts \\ []) do
    bundle = Config.bundle!()
    gh_directory = github_directory(worktree, Keyword.get(opts, :worker_host))

    with {:ok, number} <- pull_request_number(task),
         {:ok, pr} <- Client.json(["pr", "view", Integer.to_string(number), "--json", "state,mergeCommit,url"], cd: gh_directory),
         "MERGED" <- pr["state"],
         %{"oid" => merge_sha} <- pr["mergeCommit"],
         {:ok, _output} <- git(gh_directory, ["fetch", bundle.source.remote, bundle.source.default_branch]),
         {:ok, _output} <-
           git(gh_directory, ["merge-base", "--is-ancestor", merge_sha, "#{bundle.source.remote}/#{bundle.source.default_branch}"]) do
      {:ok, %{merged: true, merge_sha: merge_sha, merge_reachable: true, url: pr["url"]}}
    else
      state when is_binary(state) -> {:error, {:pull_request_not_merged, state}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :merge_sha_unavailable}
    end
  end

  defp find_or_create_pull_request(task, worktree, run_id) do
    with {:ok, pulls} <-
           Client.json(
             [
               "pr",
               "list",
               "--head",
               task.branch,
               "--state",
               "open",
               "--limit",
               "1",
               "--json",
               "number,url,isDraft,headRefOid,state,body"
             ],
             cd: worktree
           ) do
      case pulls do
        [pull_request] -> {:ok, pull_request, pull_request_creator_run_id(pull_request["body"])}
        [] -> create_pull_request(task, worktree, run_id)
      end
    end
  end

  defp create_pull_request(task, worktree, run_id) do
    bundle = Config.bundle!()

    with {:ok, body_file} <- temporary_body(task, draft_body(task, run_id)),
         {:ok, url} <-
           Client.run(
             [
               "pr",
               "create",
               "--draft",
               "--base",
               bundle.source.default_branch,
               "--head",
               task.branch,
               "--title",
               "#{task.identifier}: #{task.title}",
               "--body-file",
               body_file
             ],
             cd: worktree
           ),
         {:ok, pull_request} <-
           Client.json(["pr", "view", String.trim(url), "--json", "number,url,isDraft,headRefOid,state"], cd: worktree) do
      File.rm(body_file)
      {:ok, pull_request, run_id}
    end
  end

  defp draft_body(task, run_id) do
    checklist = Enum.map_join(task.acceptance_criteria, "\n", &"- [ ] #{&1["text"]}")
    creator_marker = if is_binary(run_id), do: "<!-- symphony-pr-creator-run:#{run_id} -->\n", else: ""

    """
    <!-- symphony-task:#{task.id} -->
    #{creator_marker}## Symphony task

    **#{task.identifier} · #{display_type(task.type)}**

    #{task.brief}

    ## Acceptance criteria

    #{checklist}

    _This draft is managed by Symphony. Run workpads are published as separate comments at review handoffs._
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp pull_request_creator_run_id(body) when is_binary(body) do
    case Regex.run(~r/<!-- symphony-pr-creator-run:([^\s]+) -->/, body) do
      [_, run_id] -> run_id
      _ -> nil
    end
  end

  defp pull_request_creator_run_id(_body), do: nil

  defp publication_exists?(worktree, number, publication_id) do
    with {:ok, comment} <- publication_comment(worktree, number, publication_id) do
      {:ok, not is_nil(comment)}
    end
  end

  defp maybe_post_publication(_worktree, _number, _publication_id, _workpads, true), do: :ok

  defp maybe_post_publication(worktree, number, publication_id, workpads, false) do
    body =
      ([publication_marker(publication_id), "## Symphony run workpads"] ++
         Enum.map(workpads, fn workpad ->
           """
           ### Run #{workpad.run_id} · invocation #{workpad.invocation}

           #{workpad.content}
           """
         end))
      |> Enum.join("\n\n")

    with {:ok, file} <- temporary_text("publication", body),
         {:ok, _output} <- Client.run(["pr", "comment", Integer.to_string(number), "--body-file", file], cd: worktree) do
      File.rm(file)
      :ok
    end
  end

  defp publish_run_stats_to_pr_body(task, run) do
    directory = Config.bundle!().source.root

    with {:ok, number} <- pull_request_number(task),
         {:ok, %{"body" => body}} <-
           Client.json(["pr", "view", Integer.to_string(number), "--json", "body"], cd: directory),
         :ok <- maybe_append_pr_stats(directory, number, body || "", run) do
      {:ok,
       %{
         destination: "pr_body",
         publication_id: run_stats_publication_id(run, "pr_body", Integer.to_string(number))
       }}
    else
      {:ok, _unexpected} -> {:error, :invalid_pull_request_body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp publish_run_stats_to_workpad_comment(task, run) do
    case workpad_publication_id(run["id"]) do
      nil ->
        {:ok, nil}

      publication_id ->
        directory = Config.bundle!().source.root

        with {:ok, number} <- pull_request_number(task),
             {:ok, comment} <- publication_comment(directory, number, publication_id),
             :ok <- append_comment_stats(directory, comment, publication_id, run) do
          {:ok,
           %{
             destination: "workpad_comment",
             publication_id: run_stats_publication_id(run, "workpad_comment", publication_id)
           }}
        end
    end
  end

  defp maybe_append_pr_stats(directory, number, body, run) do
    marker = run_stats_marker(run["id"])

    if String.contains?(body, marker) do
      :ok
    else
      updated_body = append_markdown_block(body, run_stats_block(run))
      with_temporary_text("run-stats", updated_body, &edit_pull_request_body(directory, number, &1))
    end
  end

  defp edit_pull_request_body(directory, number, file) do
    case Client.run(["pr", "edit", Integer.to_string(number), "--body-file", file], cd: directory) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_comment_stats(_directory, nil, publication_id, _run),
    do: {:error, {:workpad_publication_comment_not_found, publication_id}}

  defp append_comment_stats(directory, comment, _publication_id, run) do
    body = comment["body"] || ""
    marker = run_stats_marker(run["id"])

    if String.contains?(body, marker) do
      :ok
    else
      append_comment_stats_body(directory, comment, body, run)
    end
  end

  defp append_comment_stats_body(directory, comment, body, run) do
    with {:ok, repo} <- repository(directory),
         comment_id when is_integer(comment_id) or is_binary(comment_id) <- comment["id"],
         updated_body <- append_markdown_block(body, run_stats_block(run)) do
      with_temporary_text(
        "run-stats-comment",
        updated_body,
        &patch_comment_body(directory, repo, comment_id, &1)
      )
    else
      nil -> {:error, :github_comment_id_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp patch_comment_body(directory, repo, comment_id, file) do
    args = [
      "api",
      "--method",
      "PATCH",
      "repos/#{repo}/issues/comments/#{comment_id}",
      "-F",
      "body=@#{file}"
    ]

    case Client.run(args, cd: directory) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp publication_comment(directory, number, publication_id) do
    with {:ok, repo} <- repository(directory),
         {:ok, comments} <-
           Client.json(
             ["api", "--paginate", "repos/#{repo}/issues/#{number}/comments"],
             cd: directory
           ) do
      marker = publication_marker(publication_id)
      {:ok, Enum.find(comments, &String.contains?(&1["body"] || "", marker))}
    end
  end

  defp workpad_publication_id(run_id) do
    run_id
    |> Projection.workpad_metadata()
    |> Enum.find_value(fn
      %{"published" => true, "publication_id" => publication_id} when is_binary(publication_id) -> publication_id
      _metadata -> nil
    end)
  end

  defp run_stats_block(run) do
    stats = run["stats"]
    usage = stats["token_usage"]
    token_cells = token_cells(usage)

    """
    #{run_stats_marker(run["id"])}
    ### Symphony run stats · #{humanize_stage(run["stage_id"])}

    | Status | Model | Effort | Runtime | Turns | Input | Cached input | Output | Total |
    | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
    | #{markdown_cell(run["status"])} | #{markdown_cell(run["model"])} | #{markdown_cell(run["effort"])} | #{format_duration(stats["duration_ms"])} | #{stats["turn_count"]} | #{token_cells.input} | #{token_cells.cached} | #{token_cells.output} | #{token_cells.total} |
    """
    |> String.trim()
  end

  defp token_cells(usage) when is_map(usage) do
    %{
      input: format_count(usage["input_tokens"]),
      cached: format_count(usage["cached_input_tokens"]),
      output: format_count(usage["output_tokens"]),
      total: format_count(usage["total_tokens"])
    }
  end

  defp token_cells(_usage), do: %{input: "—", cached: "—", output: "—", total: "—"}

  defp run_stats_publication_id(run, destination, target) do
    :crypto.hash(:sha256, Jason.encode!(%{run_id: run["id"], destination: destination, target: target}))
    |> Base.encode16(case: :lower)
  end

  defp run_stats_marker(run_id), do: "<!-- symphony-run-stats:#{run_id} -->"

  defp append_markdown_block(body, block) do
    case String.trim_trailing(body) do
      "" -> block <> "\n"
      trimmed -> trimmed <> "\n\n" <> block <> "\n"
    end
  end

  defp with_temporary_text(prefix, content, callback) do
    with {:ok, file} <- temporary_text(prefix, content) do
      try do
        callback.(file)
      after
        File.rm(file)
      end
    end
  end

  defp humanize_stage(stage_id) when is_binary(stage_id) do
    stage_id |> String.replace("_", " ") |> String.capitalize()
  end

  defp humanize_stage(_stage_id), do: "Unknown stage"

  defp markdown_cell(nil), do: "default"
  defp markdown_cell(value), do: value |> to_string() |> String.replace("|", "\\|")

  defp format_duration(milliseconds) when is_integer(milliseconds) and milliseconds < 1_000,
    do: "#{milliseconds}ms"

  defp format_duration(milliseconds) when is_integer(milliseconds) and milliseconds >= 1_000 do
    seconds = div(milliseconds, 1_000)
    hours = div(seconds, 3_600)
    minutes = seconds |> rem(3_600) |> div(60)
    remaining_seconds = rem(seconds, 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m #{remaining_seconds}s"
      minutes > 0 -> "#{minutes}m #{remaining_seconds}s"
      true -> "#{seconds}s"
    end
  end

  defp format_duration(_milliseconds), do: "0ms"

  defp format_count(value) when is_integer(value) and value >= 0 do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp format_count(_value), do: "—"

  defp unresolved_review_threads(worktree, number) do
    with {:ok, repo} <- repository(worktree),
         [owner, name] <- String.split(repo, "/", parts: 2) do
      review_threads_page(worktree, owner, name, number, nil, 0, %{})
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_github_repository_name}
    end
  end

  defp review_threads_snapshot(worktree, number) do
    with {:ok, repo} <- repository(worktree),
         [owner, name] <- String.split(repo, "/", parts: 2) do
      review_threads_snapshot_page(worktree, owner, name, number, nil, [], %{})
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_github_repository_name}
    end
  end

  defp review_threads_snapshot_page(worktree, owner, name, number, cursor, accumulated, seen) do
    query =
      "query($owner:String!,$name:String!,$number:Int!,$after:String){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100,after:$after){nodes{id isResolved}pageInfo{hasNextPage endCursor}}}}}"

    args =
      [
        "api",
        "graphql",
        "-f",
        "query=#{query}",
        "-F",
        "owner=#{owner}",
        "-F",
        "name=#{name}",
        "-F",
        "number=#{number}"
      ] ++ if(cursor, do: ["-f", "after=#{cursor}"], else: [])

    with {:ok, response} <- Client.json(args, cd: worktree),
         threads when is_map(threads) <-
           get_in(response, ["data", "repository", "pullRequest", "reviewThreads"]),
         nodes when is_list(nodes) <- threads["nodes"],
         page_info when is_map(page_info) <- threads["pageInfo"],
         {:ok, hydrated} <- hydrate_review_threads(worktree, nodes) do
      normalized = accumulated ++ hydrated
      next_cursor = page_info["endCursor"]

      cond do
        page_info["hasNextPage"] != true ->
          {:ok, Enum.sort_by(normalized, & &1["id"])}

        not is_binary(next_cursor) or next_cursor == "" ->
          {:error, :invalid_review_thread_cursor}

        Map.has_key?(seen, next_cursor) ->
          {:error, {:repeated_review_thread_cursor, next_cursor}}

        true ->
          review_threads_snapshot_page(
            worktree,
            owner,
            name,
            number,
            next_cursor,
            normalized,
            Map.put(seen, next_cursor, true)
          )
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_review_threads_payload}
    end
  end

  defp hydrate_review_threads(worktree, threads) do
    Enum.reduce_while(threads, {:ok, []}, fn thread, {:ok, acc} ->
      case review_thread_comments(worktree, thread["id"]) do
        {:ok, comments} ->
          normalized = %{
            "id" => thread["id"],
            "is_resolved" => thread["isResolved"] == true,
            "comments" => comments
          }

          {:cont, {:ok, [normalized | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, hydrated} -> {:ok, Enum.reverse(hydrated)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp review_thread_comments(worktree, thread_id) when is_binary(thread_id) do
    review_thread_comments_page(worktree, thread_id, nil, [], %{})
  end

  defp review_thread_comments(_worktree, _thread_id), do: {:error, :invalid_review_thread_id}

  defp review_thread_comments_page(worktree, thread_id, cursor, accumulated, seen) do
    query =
      "query($id:ID!,$after:String){node(id:$id){... on PullRequestReviewThread{comments(first:100,after:$after){nodes{id updatedAt}pageInfo{hasNextPage endCursor}}}}}"

    args =
      ["api", "graphql", "-f", "query=#{query}", "-F", "id=#{thread_id}"] ++
        if(cursor, do: ["-f", "after=#{cursor}"], else: [])

    with {:ok, response} <- Client.json(args, cd: worktree),
         comments when is_map(comments) <- get_in(response, ["data", "node", "comments"]),
         nodes when is_list(nodes) <- comments["nodes"],
         page_info when is_map(page_info) <- comments["pageInfo"] do
      normalized = accumulated ++ Enum.map(nodes, &Map.take(&1, ["id", "updatedAt"]))
      next_cursor = page_info["endCursor"]

      cond do
        page_info["hasNextPage"] != true ->
          {:ok, Enum.sort_by(normalized, & &1["id"])}

        not is_binary(next_cursor) or next_cursor == "" ->
          {:error, {:invalid_review_comment_cursor, thread_id}}

        Map.has_key?(seen, next_cursor) ->
          {:error, {:repeated_review_comment_cursor, thread_id, next_cursor}}

        true ->
          review_thread_comments_page(
            worktree,
            thread_id,
            next_cursor,
            normalized,
            Map.put(seen, next_cursor, true)
          )
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:invalid_review_comments_payload, thread_id}}
    end
  end

  defp check_fingerprint_fields(check), do: Map.take(check, ["bucket", "name", "state", "workflow"])

  defp fingerprint(value) do
    :crypto.hash(:sha256, Jason.encode!(value))
    |> Base.encode16(case: :lower)
  end

  defp review_threads_page(worktree, owner, name, number, cursor, count, seen) do
    query =
      "query($owner:String!,$name:String!,$number:Int!,$after:String){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100,after:$after){nodes{isResolved}pageInfo{hasNextPage endCursor}}}}}"

    args =
      [
        "api",
        "graphql",
        "-f",
        "query=#{query}",
        "-F",
        "owner=#{owner}",
        "-F",
        "name=#{name}",
        "-F",
        "number=#{number}"
      ] ++ if(cursor, do: ["-f", "after=#{cursor}"], else: [])

    with {:ok, response} <- Client.json(args, cd: worktree),
         threads when is_map(threads) <-
           get_in(response, ["data", "repository", "pullRequest", "reviewThreads"]),
         nodes when is_list(nodes) <- threads["nodes"],
         page_info when is_map(page_info) <- threads["pageInfo"] do
      updated_count = count + Enum.count(nodes, &(&1["isResolved"] != true))
      next_cursor = page_info["endCursor"]

      cond do
        page_info["hasNextPage"] != true ->
          {:ok, updated_count}

        not is_binary(next_cursor) or next_cursor == "" ->
          {:error, :invalid_review_thread_cursor}

        Map.has_key?(seen, next_cursor) ->
          {:error, {:repeated_review_thread_cursor, next_cursor}}

        true ->
          review_threads_page(
            worktree,
            owner,
            name,
            number,
            next_cursor,
            updated_count,
            Map.put(seen, next_cursor, true)
          )
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_review_threads_payload}
    end
  end

  defp required_checks(worktree, number) do
    args = ["pr", "checks", Integer.to_string(number), "--required", "--json", "name,state,workflow,bucket"]

    with {:ok, output, status} <-
           Client.run_with_status(args, cd: worktree, accepted_statuses: [0, 1, 8]) do
      parse_required_checks(args, output, status)
    end
  end

  defp parse_required_checks(args, output, status) do
    case Jason.decode(output) do
      {:ok, checks} when is_list(checks) -> {:ok, checks}
      {:ok, decoded} -> {:error, {:gh_invalid_required_checks, args, decoded}}
      {:error, %Jason.DecodeError{} = error} -> normalize_no_checks(args, output, status, error)
    end
  end

  defp normalize_no_checks(args, output, status, error) do
    if status == 1 and Regex.match?(@no_checks_pattern, String.trim(output)) do
      {:ok, []}
    else
      {:error, {:gh_invalid_json, args, error}}
    end
  end

  defp checks_green?([]), do: true

  defp checks_green?(checks) do
    Enum.all?(checks, fn check ->
      check["state"] in @green_states or check["bucket"] in ["pass", "skipping"]
    end)
  end

  defp require_ready(readiness) do
    failed =
      readiness
      |> Map.take([
        :clean_worktree,
        :pushed_matching_head,
        :criteria_completed_and_evidenced,
        :no_requested_changes,
        :no_unresolved_review_threads,
        :required_checks_green,
        :pull_request_open
      ])
      |> Enum.filter(fn {_key, value} -> value != true end)
      |> Enum.map(&elem(&1, 0))

    if failed == [], do: :ok, else: {:error, {:pull_request_not_ready, failed}}
  end

  defp maybe_mark_ready(_worktree, _number, false), do: :ok

  defp maybe_mark_ready(worktree, number, true) do
    case Client.run(["pr", "ready", Integer.to_string(number)], cd: worktree) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp pull_request_number(%Task{github: %{"number" => number}}) when is_integer(number), do: {:ok, number}
  defp pull_request_number(_task), do: {:error, :pull_request_not_linked}

  defp publication_id(task, workpads) do
    WorkpadStore.publication_id(task.id, workpads)
  end

  defp publication_marker(publication_id), do: "<!-- symphony-workpad-publication:#{publication_id} -->"

  defp repository(worktree) do
    with {:ok, %{"nameWithOwner" => name}} <- Client.json(["repo", "view", "--json", "nameWithOwner"], cd: worktree) do
      {:ok, name}
    end
  end

  defp github_directory(worktree, nil), do: worktree
  defp github_directory(_worktree, _worker_host), do: Config.bundle!().source.root

  defp source_remote_url(bundle) do
    git(bundle.source.root, ["config", "--get", "remote.#{bundle.source.remote}.url"])
    |> case do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp github_host(url) do
    cond do
      match = Regex.run(~r{\Ahttps?://([^/]+)/}, url) -> {:ok, Enum.at(match, 1)}
      match = Regex.run(~r{\A(?:ssh://)?git@([^:/]+)[:/]}, url) -> {:ok, Enum.at(match, 1)}
      true -> {:error, {:source_remote_not_github, url}}
    end
  end

  defp temporary_body(task, body), do: temporary_text("#{task.identifier}-pr-body", body)

  defp temporary_text(label, body) do
    project_id = Config.bundle!().project.id
    root = Paths.runtime_root(project_id)
    :ok = File.mkdir_p(root)
    path = Path.join(root, "#{label}-#{Ecto.UUID.generate()}.md")

    case File.write(path, body, [:binary]) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:temporary_file_failed, path, reason}}
    end
  end

  defp display_type(:feature), do: "Feature"
  defp display_type(:bug_fix), do: "Bug Fix"
  defp display_type(:chore), do: "Chore"

  defp git(directory, args) do
    case System.cmd("git", ["-C", directory | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_failed, directory, args, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:git_command_failed, directory, args, Exception.message(error)}}
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
  end
end
