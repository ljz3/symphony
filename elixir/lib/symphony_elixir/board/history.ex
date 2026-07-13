defmodule SymphonyElixir.Board.History do
  @moduledoc """
  Canonical bare-Git board history using temporary indexes, `commit-tree`, and
  compare-and-swap `update-ref` operations.
  """

  alias SymphonyElixir.Board.Event
  alias SymphonyElixir.Board.Storage
  alias SymphonyElixir.Paths

  @main_ref "refs/heads/main"
  @checkpoints_ref "refs/heads/checkpoints"
  @zero_oid String.duplicate("0", 40)

  @spec ensure_repo(String.t()) :: {:ok, Path.t()} | {:error, term()}
  def ensure_repo(project_id) when is_binary(project_id) do
    repo = Paths.history_git(project_id)

    cond do
      File.dir?(repo) and File.regular?(Path.join(repo, "HEAD")) ->
        {:ok, repo}

      File.exists?(repo) ->
        {:error, {:invalid_history_repository, repo}}

      true ->
        with :ok <- Paths.ensure_project_layout(project_id),
             {:ok, _output} <- git(nil, ["init", "--bare", "--initial-branch=main", repo]) do
          {:ok, repo}
        end
    end
  end

  @spec head(String.t(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def head(project_id, ref \\ @main_ref) do
    with {:ok, repo} <- ensure_repo(project_id) do
      case git(repo, ["rev-parse", "--verify", ref]) do
        {:ok, oid} -> {:ok, String.trim(oid)}
        {:error, {:git_failed, _args, 128, _output}} -> {:ok, nil}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec append(String.t(), Event.t(), String.t() | nil) ::
          {:ok, Event.t()} | {:error, term()}
  def append(project_id, %Event{} = event, expected_head) do
    with {:ok, repo} <- ensure_repo(project_id),
         {:ok, actual_head} <- head(project_id),
         :ok <- compare_head(expected_head, actual_head),
         {:ok, oid} <- commit_event(repo, project_id, event, actual_head),
         :ok <- update_ref(repo, @main_ref, oid, actual_head) do
      {:ok, %{event | git_oid: oid}}
    end
  end

  @spec events(String.t()) :: {:ok, [Event.t()]} | {:error, term()}
  def events(project_id) do
    with {:ok, repo} <- ensure_repo(project_id),
         {:ok, commits} <- commits(repo, @main_ref),
         {:ok, events} <- decode_commits(repo, commits),
         :ok <- validate_sequence(events) do
      {:ok, events}
    end
  end

  @spec event_count(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def event_count(project_id) do
    case events(project_id) do
      {:ok, events} -> {:ok, length(events)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec push(String.t(), String.t()) :: :ok | {:error, term()}
  def push(project_id, remote_url) when is_binary(remote_url) do
    with {:ok, repo} <- ensure_repo(project_id),
         :ok <- configure_remote(repo, remote_url),
         {:ok, checkpoints_head} <- head(project_id, @checkpoints_ref),
         refspecs <-
           ["#{@main_ref}:#{@main_ref}"] ++
             if(checkpoints_head, do: ["#{@checkpoints_ref}:#{@checkpoints_ref}"], else: []),
         {:ok, _output} <- git(repo, ["push", "board" | refspecs]) do
      :ok
    end
  end

  @spec sync_status(String.t(), String.t() | nil) :: map()
  def sync_status(_project_id, nil), do: %{configured: false, state: :local_only, ahead: 0, behind: 0}

  def sync_status(project_id, remote_url) when is_binary(remote_url) do
    with {:ok, repo} <- ensure_repo(project_id),
         :ok <- configure_remote(repo, remote_url),
         {:ok, _output} <- git(repo, ["fetch", "board", "+refs/heads/main:refs/remotes/board/main"]),
         {:ok, counts} <- git(repo, ["rev-list", "--left-right", "--count", "#{@main_ref}...refs/remotes/board/main"]) do
      sync_counts(counts)
    else
      {:error, reason} -> %{configured: true, state: :error, ahead: nil, behind: nil, error: reason}
    end
  end

  @spec reconcile(String.t(), String.t(), :take_local | :take_remote) ::
          {:ok, String.t()} | {:error, term()}
  def reconcile(project_id, remote_url, strategy) when strategy in [:take_local, :take_remote] do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")

    with {:ok, repo} <- ensure_repo(project_id),
         :ok <- configure_remote(repo, remote_url),
         {:ok, _output} <- git(repo, ["fetch", "board", "+refs/heads/main:refs/remotes/board/main"]),
         {:ok, local} <- required_ref(repo, @main_ref),
         {:ok, remote} <- required_ref(repo, "refs/remotes/board/main") do
      reconcile_heads(repo, local, remote, strategy, timestamp)
    end
  end

  @spec verify_remote(String.t(), String.t()) :: :ok | {:error, term()}
  def verify_remote(project_id, remote_url) when is_binary(remote_url) do
    with {:ok, repo} <- ensure_repo(project_id),
         :ok <- configure_remote(repo, remote_url),
         {:ok, local_main} <- required_ref(repo, @main_ref),
         {:ok, local_checkpoints} <- head(project_id, @checkpoints_ref),
         {:ok, output} <-
           git(repo, [
             "ls-remote",
             "board",
             @main_ref,
             @checkpoints_ref
           ]),
         remote_refs <- parse_ls_remote(output),
         true <- remote_refs[@main_ref] == local_main,
         true <- is_nil(local_checkpoints) or remote_refs[@checkpoints_ref] == local_checkpoints do
      :ok
    else
      false -> {:error, :remote_oid_verification_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec commit_checkpoint(String.t(), pos_integer(), String.t(), Path.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def commit_checkpoint(project_id, sequence, event_oid, database_path, checksum) do
    with {:ok, repo} <- ensure_repo(project_id),
         {:ok, parent} <- head(project_id, @checkpoints_ref),
         {:ok, database} <- File.read(database_path),
         manifest <- checkpoint_manifest(sequence, event_oid, checksum),
         files <- [
           {"checkpoints/#{padded(sequence)}.sqlite3", database},
           {"checkpoints/#{padded(sequence)}.json", Jason.encode!(manifest, pretty: true)}
         ],
         {:ok, oid} <- commit_files(repo, project_id, @checkpoints_ref, parent, files, "checkpoint #{sequence}"),
         :ok <- update_ref(repo, @checkpoints_ref, oid, parent) do
      {:ok, oid}
    end
  end

  @spec latest_checkpoint(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def latest_checkpoint(project_id) do
    with {:ok, repo} <- ensure_repo(project_id),
         {:ok, head_oid} <- head(project_id, @checkpoints_ref) do
      latest_checkpoint_at(repo, head_oid)
    end
  end

  @spec extract_checkpoint(String.t(), map(), Path.t()) :: :ok | {:error, term()}
  def extract_checkpoint(project_id, manifest, destination) do
    with {:ok, repo} <- ensure_repo(project_id),
         commit when is_binary(commit) <- manifest["commit_oid"],
         sequence when is_integer(sequence) <- manifest["sequence"],
         {:ok, database} <- git(repo, ["show", "#{commit}:checkpoints/#{padded(sequence)}.sqlite3"]),
         checksum <- Base.encode16(:crypto.hash(:sha256, database), case: :lower),
         true <- checksum == manifest["sha256"],
         :ok <- File.write(destination, database, [:binary]) do
      :ok
    else
      false -> {:error, :checkpoint_checksum_mismatch}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_checkpoint_manifest}
    end
  end

  defp commit_event(repo, project_id, event, parent) do
    path = "events/#{padded(event.sequence)}-#{event.event_id}.json"
    commit_files(repo, project_id, @main_ref, parent, [{path, Event.encode(event)}], "#{event.sequence}: #{event.type}")
  end

  defp commit_files(repo, project_id, _ref, parent, files, message) do
    index = Path.join(Paths.runtime_root(project_id), "git-index-#{Ecto.UUID.generate()}")
    env = git_environment(index)

    try do
      with {:ok, _output} <- read_tree(repo, parent, env),
           :ok <- add_files(repo, files, env),
           {:ok, tree} <- git(repo, ["write-tree"], env),
           {:ok, oid} <- commit_tree(repo, String.trim(tree), parent, message, env) do
        {:ok, String.trim(oid)}
      end
    after
      File.rm(index)
      File.rm(index <> ".lock")
    end
  end

  defp read_tree(repo, nil, env), do: git(repo, ["read-tree", "--empty"], env)
  defp read_tree(repo, parent, env), do: git(repo, ["read-tree", "#{parent}^{tree}"], env)

  defp add_files(repo, files, env) do
    Enum.reduce_while(files, :ok, fn {path, content}, :ok ->
      temporary = temporary_blob_path(env)

      try do
        with :ok <- File.write(temporary, content, [:binary]),
             {:ok, blob} <- git(repo, ["hash-object", "-w", temporary], env),
             {:ok, _output} <- git(repo, ["update-index", "--add", "--cacheinfo", "100644,#{String.trim(blob)},#{path}"], env) do
          {:cont, :ok}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      after
        File.rm(temporary)
      end
    end)
  end

  defp commit_tree(repo, tree, parent, message, env) do
    args = ["commit-tree", tree] ++ if(parent, do: ["-p", parent], else: []) ++ ["-m", message]
    git(repo, args, env)
  end

  defp update_ref(repo, ref, oid, nil) do
    case git(repo, ["update-ref", ref, oid, @zero_oid]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:history_compare_and_swap_failed, ref, nil, reason}}
    end
  end

  defp update_ref(repo, ref, oid, expected) do
    case git(repo, ["update-ref", ref, oid, expected]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:history_compare_and_swap_failed, ref, expected, reason}}
    end
  end

  defp commits(repo, ref) do
    case git(repo, ["rev-list", "--reverse", ref]) do
      {:ok, output} -> {:ok, String.split(output, ~r/\s+/, trim: true)}
      {:error, {:git_failed, _args, 128, _output}} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_commits(repo, commits) do
    Enum.reduce_while(commits, {:ok, []}, fn oid, {:ok, acc} ->
      with {:ok, paths} <- git(repo, ["diff-tree", "--root", "--no-commit-id", "--name-only", "-r", oid, "--", "events"]),
           [path] <- String.split(paths, ~r/\s+/, trim: true),
           {:ok, json} <- git(repo, ["show", "#{oid}:#{path}"]),
           {:ok, event} <- Event.decode(json) do
        {:cont, {:ok, [%{event | git_oid: oid} | acc]}}
      else
        paths when is_list(paths) -> {:halt, {:error, {:invalid_event_commit, oid, paths}}}
        {:error, reason} -> {:halt, {:error, {:event_decode_failed, oid, reason}}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  end

  defp validate_sequence(events) do
    actual = Enum.map(events, & &1.sequence)
    expected = if events == [], do: [], else: Enum.to_list(1..length(events))
    if actual == expected, do: :ok, else: {:error, {:invalid_event_sequence, expected, actual}}
  end

  defp compare_head(expected, expected), do: :ok
  defp compare_head(expected, actual), do: {:error, {:history_head_changed, expected, actual}}

  defp configure_remote(repo, url) do
    case git(repo, ["remote", "get-url", "board"]) do
      {:ok, current} when is_binary(current) ->
        maybe_update_remote(repo, url, current)

      {:error, _reason} ->
        normalize_git_status(git(repo, ["remote", "add", "board", url]))
    end
  end

  defp sync_counts(counts) do
    case counts |> String.trim() |> String.split() |> Enum.map(&String.to_integer/1) do
      [ahead, behind] ->
        %{configured: true, state: sync_state(ahead, behind), ahead: ahead, behind: behind, error: nil}

      _ ->
        %{configured: true, state: :error, ahead: nil, behind: nil, error: :invalid_rev_list_output}
    end
  end

  defp sync_state(ahead, behind) when ahead > 0 and behind > 0, do: :diverged
  defp sync_state(ahead, _behind) when ahead > 0, do: :ahead
  defp sync_state(_ahead, behind) when behind > 0, do: :behind
  defp sync_state(_ahead, _behind), do: :synced

  defp reconcile_heads(repo, local, remote, :take_remote, timestamp) do
    backup = "refs/backups/reconcile/#{timestamp}-local"

    with {:ok, _output} <- git(repo, ["update-ref", backup, local]),
         :ok <- update_ref(repo, @main_ref, remote, local) do
      {:ok, backup}
    end
  end

  defp reconcile_heads(repo, _local, remote, :take_local, timestamp) do
    backup = "refs/backups/reconcile/#{timestamp}-remote"
    lease = "--force-with-lease=refs/heads/main:#{remote}"

    with {:ok, _output} <- git(repo, ["update-ref", backup, remote]),
         {:ok, _output} <- git(repo, ["push", lease, "board", "#{@main_ref}:#{@main_ref}"]) do
      {:ok, backup}
    end
  end

  defp latest_checkpoint_at(_repo, nil), do: {:ok, nil}

  defp latest_checkpoint_at(repo, oid) do
    with {:ok, paths} <- git(repo, ["ls-tree", "-r", "--name-only", oid, "checkpoints"]),
         manifest_path when is_binary(manifest_path) <- latest_manifest_path(paths),
         {:ok, json} <- git(repo, ["show", "#{oid}:#{manifest_path}"]),
         {:ok, manifest} <- Jason.decode(json) do
      {:ok, Map.merge(manifest, %{"commit_oid" => oid, "manifest_path" => manifest_path})}
    else
      nil -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_update_remote(repo, url, current) do
    if String.trim(current) == url do
      :ok
    else
      normalize_git_status(git(repo, ["remote", "set-url", "board", url]))
    end
  end

  defp normalize_git_status({:ok, _output}), do: :ok
  defp normalize_git_status({:error, reason}), do: {:error, reason}

  defp required_ref(repo, ref) do
    case git(repo, ["rev-parse", "--verify", ref]) do
      {:ok, oid} -> {:ok, String.trim(oid)}
      {:error, reason} -> {:error, {:missing_ref, ref, reason}}
    end
  end

  defp parse_ls_remote(output) do
    output
    |> String.split(~r/\R/, trim: true)
    |> Map.new(fn line ->
      [oid, ref] = String.split(line, ~r/\s+/, parts: 2)
      {ref, oid}
    end)
  end

  defp checkpoint_manifest(sequence, event_oid, checksum) do
    %{
      "format_version" => 1,
      "projection_migration_version" => Storage.migration_version(),
      "sequence" => sequence,
      "event_oid" => event_oid,
      "sha256" => checksum,
      "created_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp latest_manifest_path(paths) do
    paths
    |> String.split(~r/\s+/, trim: true)
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.max(fn -> nil end)
  end

  defp padded(sequence), do: sequence |> Integer.to_string() |> String.pad_leading(20, "0")

  defp git_environment(index) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    [
      {"GIT_INDEX_FILE", index},
      {"GIT_AUTHOR_NAME", "Symphony Board"},
      {"GIT_AUTHOR_EMAIL", "board@symphony.local"},
      {"GIT_COMMITTER_NAME", "Symphony Board"},
      {"GIT_COMMITTER_EMAIL", "board@symphony.local"},
      {"GIT_AUTHOR_DATE", now},
      {"GIT_COMMITTER_DATE", now}
    ]
  end

  defp temporary_blob_path(env) do
    {"GIT_INDEX_FILE", index} = List.keyfind(env, "GIT_INDEX_FILE", 0)
    index <> "-blob-#{Ecto.UUID.generate()}"
  end

  defp git(repo, args, env \\ []) do
    command_args = if repo, do: ["--git-dir", repo | args], else: args
    opts = [stderr_to_stdout: true, env: env]

    case System.cmd("git", command_args, opts) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_failed, args, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:git_command_failed, args, Exception.message(error)}}
  end
end
