defmodule SymphonyElixir.Worktree do
  @moduledoc """
  Creates and reuses persistent, service-managed source Git worktrees per task.

  Existing paths are never deleted or adopted without a matching Symphony marker.
  """

  require Logger

  alias SymphonyElixir.{Config, Paths, PathSafety, SSH, Task}

  @type worker_host :: String.t() | nil

  @spec ensure(Task.t(), worker_host()) :: {:ok, Path.t()} | {:error, term()}
  def ensure(%Task{} = task, worker_host \\ nil) do
    if worker_host do
      ensure_remote(task, worker_host)
    else
      ensure_local(task)
    end
  end

  @spec path(Task.t()) :: Path.t()
  def path(%Task{} = task) do
    bundle = Config.bundle!()
    Path.join(Paths.worktrees_root(bundle.project.id), task.identifier)
  end

  @spec head(Path.t(), worker_host()) :: {:ok, String.t()} | {:error, term()}
  def head(worktree, worker_host \\ nil) do
    if worker_host do
      remote_git(worker_host, worktree, ["rev-parse", "HEAD"])
    else
      git(worktree, ["rev-parse", "HEAD"])
    end
    |> trim_result()
  end

  @spec clean?(Path.t(), worker_host()) :: {:ok, boolean()} | {:error, term()}
  def clean?(worktree, worker_host \\ nil) do
    result =
      if worker_host do
        remote_git(worker_host, worktree, ["status", "--porcelain=v1", "--untracked-files=all"])
      else
        git(worktree, ["status", "--porcelain=v1", "--untracked-files=all"])
      end

    case result do
      {:ok, output} -> {:ok, String.trim(output) == ""}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec base_head(Path.t(), worker_host()) :: {:ok, String.t()} | {:error, term()}
  def base_head(worktree, worker_host \\ nil) do
    bundle = Config.bundle!()
    remote = if worker_host, do: "origin", else: bundle.source.remote

    if worker_host do
      remote_git(worker_host, worktree, ["rev-parse", "#{remote}/#{bundle.source.default_branch}"])
    else
      git(worktree, ["rev-parse", "#{remote}/#{bundle.source.default_branch}"])
    end
    |> trim_result()
  end

  @spec changed_paths(Task.t(), Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term()}
  def changed_paths(%Task{}, worktree, worker_host \\ nil) do
    with {:ok, base} <- base_head(worktree, worker_host),
         {:ok, comparison_base} <- merge_base(worktree, base, worker_host) do
      result =
        if worker_host do
          remote_git(worker_host, worktree, ["diff", "--name-only", "#{comparison_base}..HEAD"])
        else
          git(worktree, ["diff", "--name-only", "#{comparison_base}..HEAD"])
        end

      case result do
        {:ok, output} -> {:ok, String.split(output, ~r/\R/, trim: true)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp merge_base(worktree, base, nil) do
    git(worktree, ["merge-base", base, "HEAD"])
    |> trim_result()
  end

  defp merge_base(worktree, base, host) do
    remote_git(host, worktree, ["merge-base", base, "HEAD"])
    |> trim_result()
  end

  @spec push(Task.t(), Path.t(), worker_host()) :: :ok | {:error, term()}
  def push(%Task{} = task, worktree, worker_host \\ nil) do
    bundle = Config.bundle!()
    remote = if worker_host, do: "origin", else: bundle.source.remote

    result =
      if worker_host do
        remote_git(worker_host, worktree, ["push", "--set-upstream", remote, task.branch])
      else
        git(worktree, ["push", "--set-upstream", remote, task.branch])
      end

    case result do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec reconcile(Task.t(), Path.t(), worker_host()) :: {:ok, map()} | {:error, term()}
  def reconcile(%Task{} = task, worktree, worker_host \\ nil) do
    with {:ok, head_sha} <- head(worktree, worker_host),
         {:ok, clean} <- clean?(worktree, worker_host),
         {:ok, branch} <- current_branch(worktree, worker_host),
         true <- branch == task.branch do
      {:ok, %{head_sha: head_sha, clean: clean, branch: branch, worktree: worktree, worker_host: worker_host}}
    else
      false -> {:error, {:worktree_branch_mismatch, task.branch}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec run_hook(:after_create | :before_run | :after_run | :before_remove, Task.t(), Path.t(), worker_host()) ::
          :ok | {:error, term()}
  def run_hook(kind, %Task{} = task, worktree, worker_host \\ nil) do
    hooks = Config.settings!().hooks

    case Map.get(hooks, kind) do
      nil -> :ok
      command -> execute_hook(command, kind, task, worktree, worker_host, hooks.timeout_ms)
    end
  end

  @spec remove(Task.t(), worker_host()) :: :ok | {:error, term()}
  def remove(%Task{} = task, worker_host \\ nil) do
    if worker_host do
      remove_remote(task, worker_host)
    else
      remove_local(task)
    end
  end

  defp ensure_local(task) do
    bundle = Config.bundle!()
    worktree = path(task)
    root = Paths.worktrees_root(bundle.project.id)

    with :ok <- File.mkdir_p(root),
         :ok <- validate_local_destination(worktree, root, bundle.source.root),
         {:ok, result} <- existing_or_create(task, worktree, bundle),
         :ok <- write_marker(task, worktree, bundle),
         :ok <- maybe_after_create(result.created, task, worktree) do
      {:ok, worktree}
    end
  end

  defp existing_or_create(task, worktree, bundle) do
    if File.exists?(worktree) do
      with :ok <- validate_marker(task, worktree, bundle),
           {:ok, branch} <- current_branch(worktree, nil),
           true <- branch == task.branch,
           :ok <- validate_common_repository(worktree, bundle.source.root) do
        {:ok, %{created: false}}
      else
        false -> {:error, {:worktree_branch_collision, worktree, task.branch}}
        {:error, reason} -> {:error, reason}
      end
    else
      create_local(task, worktree, bundle)
    end
  end

  defp create_local(task, worktree, bundle) do
    source = bundle.source

    with {:ok, _output} <- git(source.root, ["fetch", "--prune", source.remote, source.default_branch]),
         false <- local_branch_exists?(source.root, task.branch),
         false <- worktree_path_registered?(source.root, worktree),
         {:ok, _output} <-
           git(source.root, [
             "worktree",
             "add",
             "-b",
             task.branch,
             worktree,
             "#{source.remote}/#{source.default_branch}"
           ]) do
      {:ok, %{created: true}}
    else
      true -> {:error, {:task_branch_or_worktree_collision, task.branch, worktree}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_local_destination(worktree, root, source_root) do
    expanded = Path.expand(worktree)
    expanded_root = Path.expand(root)

    with false <- expanded == Path.expand(source_root),
         true <- String.starts_with?(expanded, expanded_root <> "/"),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root),
         {:ok, canonical_parent} <- PathSafety.canonicalize(Path.dirname(expanded)),
         true <-
           canonical_parent == canonical_root or
             String.starts_with?(canonical_parent <> "/", canonical_root <> "/") do
      :ok
    else
      true -> {:error, {:worktree_is_source_repository, expanded}}
      false -> {:error, {:unsafe_worktree_path, expanded, expanded_root}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_common_repository(worktree, source_root) do
    with {:ok, common} <- git(worktree, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
         {:ok, source_git} <- git(source_root, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) do
      if Path.expand(String.trim(common)) == Path.expand(String.trim(source_git)) do
        :ok
      else
        {:error, {:worktree_object_store_mismatch, worktree}}
      end
    end
  end

  defp local_branch_exists?(source_root, branch) do
    match?({:ok, _output}, git(source_root, ["show-ref", "--verify", "--quiet", "refs/heads/#{branch}"]))
  end

  defp worktree_path_registered?(source_root, path) do
    case git(source_root, ["worktree", "list", "--porcelain"]) do
      {:ok, output} ->
        output
        |> String.split("\n")
        |> Enum.any?(fn line -> line == "worktree #{Path.expand(path)}" end)

      {:error, _reason} ->
        false
    end
  end

  defp marker_path(task) do
    bundle = Config.bundle!()
    Path.join([Paths.runtime_root(bundle.project.id), "worktree-markers", "#{task.identifier}.json"])
  end

  defp write_marker(task, worktree, bundle) do
    marker = %{
      "task_id" => task.id,
      "identifier" => task.identifier,
      "branch" => task.branch,
      "path" => Path.expand(worktree),
      "source_root" => Path.expand(bundle.source.root),
      "created_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    path = marker_path(task)
    :ok = File.mkdir_p(Path.dirname(path))
    File.write(path, Jason.encode!(marker, pretty: true), [:binary])
  end

  defp validate_marker(task, worktree, bundle) do
    with {:ok, json} <- File.read(marker_path(task)),
         {:ok, marker} <- Jason.decode(json),
         true <- marker["task_id"] == task.id,
         true <- marker["branch"] == task.branch,
         true <- marker["path"] == Path.expand(worktree),
         true <- marker["source_root"] == Path.expand(bundle.source.root) do
      :ok
    else
      false -> {:error, {:worktree_marker_mismatch, worktree}}
      {:error, reason} -> {:error, {:unmanaged_existing_worktree, worktree, reason}}
    end
  end

  defp maybe_after_create(true, task, worktree), do: run_hook(:after_create, task, worktree, nil)
  defp maybe_after_create(false, _task, _worktree), do: :ok

  defp remove_local(task) do
    bundle = Config.bundle!()
    worktree = path(task)
    marker = marker_path(task)

    cond do
      File.exists?(worktree) ->
        with :ok <- validate_marker(task, worktree, bundle),
             {:ok, true} <- clean?(worktree),
             :ok <- run_hook(:before_remove, task, worktree),
             {:ok, _output} <- git(bundle.source.root, ["worktree", "remove", worktree]),
             :ok <- delete_local_branch(bundle.source.root, task.branch) do
          remove_marker(marker)
        else
          {:ok, false} -> {:error, {:dirty_worktree_not_removed, worktree}}
          {:error, reason} -> {:error, reason}
        end

      File.exists?(marker) ->
        with :ok <- validate_marker(task, worktree, bundle),
             :ok <- delete_local_branch(bundle.source.root, task.branch) do
          remove_marker(marker)
        end

      true ->
        :ok
    end
  end

  defp delete_local_branch(source_root, branch) do
    ref = "refs/heads/#{branch}"

    case git(source_root, ["show-ref", "--verify", "--quiet", ref]) do
      {:ok, _output} ->
        case git(source_root, ["branch", "--delete", "--force", "--", branch]) do
          {:ok, _output} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, {:git_failed, ^source_root, ["show-ref", "--verify", "--quiet", ^ref], 1, _output}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_marker(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:worktree_marker_remove_failed, path, reason}}
    end
  end

  defp ensure_remote(task, host) do
    bundle = Config.bundle!()
    root = Paths.worktrees_root(bundle.project.id)
    mirror = Path.join(root, ".mirrors/#{bundle.project.id}.git")
    mirror_marker = Path.join(root, ".mirrors/#{bundle.project.id}.remote")
    worktree = Path.join(root, task.identifier)
    marker = remote_marker_path(root, task)
    marker_value = remote_marker_value(task, worktree, mirror)
    remote_url = source_remote_url(bundle.source.root, bundle.source.remote)

    script = """
    set -eu
    root=#{shell_escape(root)}
    mirror=#{shell_escape(mirror)}
    mirror_marker=#{shell_escape(mirror_marker)}
    worktree=#{shell_escape(worktree)}
    marker=#{shell_escape(marker)}
    marker_value=#{shell_escape(marker_value)}
    remote=#{shell_escape(remote_url)}
    branch=#{shell_escape(task.branch)}
    base=#{shell_escape(bundle.source.default_branch)}
    created=0
    mkdir -p "$root" "$(dirname "$mirror")" "$(dirname "$marker")"
    if [ -d "$mirror" ]; then
      test -f "$mirror_marker"
      test "$(cat "$mirror_marker")" = "$remote"
    else
      test ! -e "$mirror"
      git clone --mirror "$remote" "$mirror"
      printf '%s' "$remote" > "$mirror_marker"
    fi
    git --git-dir="$mirror" fetch --prune origin "$base"
    if [ -e "$worktree" ]; then
      test -f "$marker" || exit 43
      test "$(cat "$marker")" = "$marker_value" || exit 43
      test "$(git -C "$worktree" branch --show-current)" = "$branch"
    else
      test ! -e "$marker" || exit 43
      if git --git-dir="$mirror" show-ref --verify --quiet "refs/heads/$branch"; then exit 42; fi
      git --git-dir="$mirror" worktree add -b "$branch" "$worktree" "origin/$base"
      printf '%s' "$marker_value" > "$marker"
      created=1
    fi
    printf '\nSYMPHONY_RESULT\t%s\t%s\n' "$created" "$worktree"
    """

    case SSH.run(host, script, timeout: bundle.hooks.timeout_ms) do
      {:ok, {output, 0}} -> complete_remote_ensure(output, task, host)
      {:ok, {output, 42}} -> {:error, {:remote_branch_collision, host, task.branch, output}}
      {:ok, {output, 43}} -> {:error, {:unmanaged_remote_worktree, host, worktree, output}}
      {:ok, {output, status}} -> {:error, {:remote_worktree_failed, host, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_remote(task, host) do
    bundle = Config.bundle!()
    root = Paths.worktrees_root(bundle.project.id)
    mirror = Path.join(root, ".mirrors/#{bundle.project.id}.git")
    worktree = Path.join(root, task.identifier)
    marker = remote_marker_path(root, task)
    marker_value = remote_marker_value(task, worktree, mirror)

    case validate_remote_marker(host, worktree, marker, marker_value, bundle.hooks.timeout_ms) do
      :missing ->
        :ok

      :worktree_missing ->
        remove_remote_branch(task, host, mirror, marker, marker_value, bundle)

      :ok ->
        remove_managed_remote(task, host, worktree, mirror, marker, marker_value, bundle)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp complete_remote_ensure(output, task, host) do
    with {:ok, created, worktree} <- parse_remote_result(output),
         :ok <- maybe_after_create_remote(created, task, worktree, host) do
      {:ok, worktree}
    end
  end

  defp parse_remote_result(output) do
    result_line =
      output
      |> String.split(~r/\R/, trim: true)
      |> Enum.find(&String.starts_with?(&1, "SYMPHONY_RESULT\t"))

    case result_line && String.split(result_line, "\t", parts: 3) do
      ["SYMPHONY_RESULT", created, worktree] when created in ["0", "1"] ->
        {:ok, created == "1", worktree}

      _ ->
        {:error, {:invalid_remote_worktree_result, output}}
    end
  end

  defp maybe_after_create_remote(true, task, worktree, host) do
    run_hook(:after_create, task, worktree, host)
  end

  defp maybe_after_create_remote(false, _task, _worktree, _host), do: :ok

  defp validate_remote_marker(host, worktree, marker, marker_value, timeout) do
    script = """
    set -eu
    worktree=#{shell_escape(worktree)}
    marker=#{shell_escape(marker)}
    marker_value=#{shell_escape(marker_value)}
    if [ ! -e "$worktree" ]; then
      if [ ! -e "$marker" ]; then exit 44; fi
      test -f "$marker"
      test "$(cat "$marker")" = "$marker_value"
      exit 45
    fi
    test -f "$marker"
    test "$(cat "$marker")" = "$marker_value"
    """

    case SSH.run(host, script, timeout: timeout) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {_output, 44}} -> :missing
      {:ok, {_output, 45}} -> :worktree_missing
      {:ok, {output, status}} -> {:error, {:unmanaged_remote_worktree, host, worktree, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_managed_remote(task, host, worktree, mirror, marker, marker_value, bundle) do
    with {:ok, true} <- clean?(worktree, host),
         :ok <- run_hook(:before_remove, task, worktree, host) do
      script = """
      set -eu
      marker=#{shell_escape(marker)}
      marker_value=#{shell_escape(marker_value)}
      branch=#{shell_escape(task.branch)}
      test -f "$marker"
      test "$(cat "$marker")" = "$marker_value"
      git --git-dir=#{shell_escape(mirror)} worktree remove #{shell_escape(worktree)}
      if git --git-dir=#{shell_escape(mirror)} show-ref --verify --quiet "refs/heads/$branch"; then
        git --git-dir=#{shell_escape(mirror)} branch --delete --force -- "$branch"
      fi
      rm -f "$marker"
      """

      case SSH.run(host, script, timeout: bundle.hooks.timeout_ms) do
        {:ok, {_output, 0}} -> :ok
        {:ok, {output, status}} -> {:error, {:remote_worktree_remove_failed, host, status, output}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, false} -> {:error, {:dirty_worktree_not_removed, host, worktree}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_remote_branch(task, host, mirror, marker, marker_value, bundle) do
    script = """
    set -eu
    marker=#{shell_escape(marker)}
    marker_value=#{shell_escape(marker_value)}
    branch=#{shell_escape(task.branch)}
    test -f "$marker"
    test "$(cat "$marker")" = "$marker_value"
    if git --git-dir=#{shell_escape(mirror)} show-ref --verify --quiet "refs/heads/$branch"; then
      git --git-dir=#{shell_escape(mirror)} branch --delete --force -- "$branch"
    fi
    rm -f "$marker"
    """

    case SSH.run(host, script, timeout: bundle.hooks.timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:remote_branch_remove_failed, host, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remote_marker_path(root, task) do
    Path.join(root, ".symphony-markers/#{task.identifier}.marker")
  end

  defp remote_marker_value(task, worktree, mirror) do
    Enum.join([task.id, task.identifier, task.branch, worktree, mirror], "\n")
  end

  defp execute_hook(command, kind, task, worktree, nil, timeout_ms) do
    env = hook_env(task)

    hook_task =
      Elixir.Task.async(fn ->
        System.cmd("bash", ["-lc", command], cd: worktree, env: env, stderr_to_stdout: true)
      end)

    case Elixir.Task.yield(hook_task, timeout_ms) || Elixir.Task.shutdown(hook_task, :brutal_kill) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:worktree_hook_failed, kind, status, output}}
      nil -> {:error, {:worktree_hook_timeout, kind, timeout_ms}}
    end
  end

  defp execute_hook(command, kind, task, worktree, host, timeout_ms) do
    exports = hook_env(task) |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{shell_escape(value)}" end)
    script = "cd #{shell_escape(worktree)} && env #{exports} bash -lc #{shell_escape(command)}"

    case SSH.run(host, script, timeout: timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:worktree_hook_failed, kind, host, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp hook_env(task) do
    [
      {"SYMPHONY_TASK_ID", task.id},
      {"SYMPHONY_TASK_IDENTIFIER", task.identifier},
      {"SYMPHONY_TASK_BRANCH", task.branch}
    ]
  end

  defp current_branch(worktree, nil), do: git(worktree, ["branch", "--show-current"]) |> trim_result()

  defp current_branch(worktree, host) do
    remote_git(host, worktree, ["branch", "--show-current"])
    |> trim_result()
  end

  defp source_remote_url(root, remote) do
    case git(root, ["remote", "get-url", remote]) do
      {:ok, url} -> String.trim(url)
      {:error, reason} -> raise "source remote unavailable: #{inspect(reason)}"
    end
  end

  defp remote_git(host, worktree, args) do
    command = "git -C #{shell_escape(worktree)} " <> Enum.map_join(args, " ", &shell_escape/1)

    case SSH.run(host, command, timeout: Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, status}} -> {:error, {:remote_git_failed, host, args, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp git(directory, args) do
    case System.cmd("git", ["-C", directory | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_failed, directory, args, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:git_command_failed, directory, args, Exception.message(error)}}
  end

  defp trim_result({:ok, value}), do: {:ok, String.trim(value)}
  defp trim_result({:error, reason}), do: {:error, reason}

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
