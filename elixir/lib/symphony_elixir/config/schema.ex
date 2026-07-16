defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  alias SymphonyElixir.{Paths, PathSafety}
  alias SymphonyElixir.Workflow.Bundle

  @enforce_keys [
    :project,
    :source,
    :board,
    :agent,
    :codex,
    :hooks,
    :jobs,
    :dispatch,
    :merge,
    :workspace,
    :worker,
    :server
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          project: map(),
          source: map(),
          board: map(),
          agent: map(),
          codex: map(),
          hooks: map(),
          jobs: map(),
          dispatch: map(),
          merge: map() | nil,
          workspace: map(),
          worker: map(),
          server: map()
        }

  @spec from_bundle(Bundle.t()) :: t()
  def from_bundle(%Bundle{} = bundle) do
    project_id = bundle.project.id
    workspace_root = Paths.worktrees_root(project_id)

    %__MODULE__{
      project: bundle.project,
      source: bundle.source,
      board: bundle.board,
      agent: bundle.agent,
      codex: Map.put(bundle.codex, :turn_sandbox_policy, nil),
      hooks: bundle.hooks,
      jobs: bundle.jobs,
      dispatch: bundle.dispatch,
      merge: bundle.merge,
      workspace: %{root: workspace_root},
      worker: %{
        ssh_hosts: bundle.agent.ssh_hosts,
        max_concurrent_agents_per_host: bundle.agent.max_concurrent_agents_per_host
      },
      server: %{host: "127.0.0.1", port: nil}
    }
  end

  @spec resolve_runtime_turn_sandbox_policy(t(), Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    case settings.codex.thread_sandbox do
      "danger-full-access" ->
        {:ok, %{"type" => "dangerFullAccess"}}

      "read-only" ->
        {:ok,
         %{
           "type" => "readOnly",
           "networkAccess" => settings.codex.network_access
         }}

      "workspace-write" ->
        resolve_workspace_write_policy(settings, workspace, opts)

      sandbox ->
        {:error, {:unsupported_turn_sandbox, sandbox}}
    end
  end

  defp resolve_workspace_write_policy(settings, workspace, opts) do
    root = workspace || settings.workspace.root

    if Keyword.get(opts, :remote, false) do
      {:ok, default_turn_sandbox_policy([root], settings.codex.network_access)}
    else
      with true <- is_binary(root) and root != "",
           {:ok, canonical} <- PathSafety.canonicalize(Path.expand(root)),
           {:ok, git_common_dir} <- resolve_git_common_dir(settings.source.root) do
        {:ok,
         default_turn_sandbox_policy(
           Enum.uniq([canonical, git_common_dir]),
           settings.codex.network_access
         )}
      else
        false -> {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, root}}}
        {:error, reason} -> {:error, {:unsafe_turn_sandbox_policy, reason}}
      end
    end
  end

  defp resolve_git_common_dir(source_root) when is_binary(source_root) and source_root != "" do
    with git when is_binary(git) <- System.find_executable("git"),
         {output, 0} <-
           System.cmd(
             git,
             ["-C", source_root, "rev-parse", "--path-format=absolute", "--git-common-dir"],
             stderr_to_stdout: true
           ),
         common_dir when common_dir != "" <- String.trim(output),
         {:ok, canonical} <-
           common_dir
           |> Path.expand(source_root)
           |> PathSafety.canonicalize(),
         true <- File.dir?(canonical) do
      {:ok, canonical}
    else
      nil ->
        {:error, :git_executable_unavailable}

      {output, status} when is_binary(output) and is_integer(status) ->
        {:error, {:git_common_dir_failed, status, String.trim(output)}}

      "" ->
        {:error, :empty_git_common_dir}

      false ->
        {:error, :invalid_git_common_dir}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_git_common_dir(source_root),
    do: {:error, {:invalid_source_root, source_root}}

  defp default_turn_sandbox_policy(writable_roots, network_access) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => writable_roots,
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => network_access,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end
end
