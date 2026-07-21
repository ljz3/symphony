defmodule SymphonyElixir.WorkspaceSafety do
  @moduledoc """
  Workspace path validation shared by agent backends.

  Task sessions must run inside a managed worktree under the configured
  worktree root (never the worktree root itself, never the Symphony source
  checkout, and never through a symlink escape). Catalog probes run in scratch
  directories under the project runtime root. Remote task paths keep their
  remote semantics and are never expanded as local paths.
  """

  alias SymphonyElixir.{Config, Paths, PathSafety}

  @spec validate_task_cwd(Path.t(), String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def validate_task_cwd(workspace, nil) when is_binary(workspace), do: validate_local_task_cwd(workspace)

  def validate_task_cwd(workspace, worker_host) when is_binary(workspace) and is_binary(worker_host),
    do: validate_remote_task_cwd(workspace, worker_host)

  @spec validate_local_task_cwd(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def validate_local_task_cwd(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  @spec validate_remote_task_cwd(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def validate_remote_task_cwd(workspace, worker_host)
      when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  @spec validate_catalog_cwd(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def validate_catalog_cwd(workspace, project_id) when is_binary(workspace) and is_binary(project_id) do
    expanded = Path.expand(workspace)
    runtime_root = Path.expand(Paths.runtime_root(project_id))

    with {:ok, canonical} <- PathSafety.canonicalize(expanded),
         {:ok, canonical_runtime_root} <- PathSafety.canonicalize(runtime_root),
         true <- String.starts_with?(canonical <> "/", canonical_runtime_root <> "/") do
      {:ok, canonical}
    else
      false -> {:error, {:invalid_catalog_cwd, expanded}}
      {:error, reason} -> {:error, {:invalid_catalog_cwd, reason}}
    end
  end
end
