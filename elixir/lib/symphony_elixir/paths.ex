defmodule SymphonyElixir.Paths do
  @moduledoc """
  Resolves machine-local Symphony storage paths.

  Workflow configuration deliberately cannot override these paths. Operators may
  set them through CLI-provided application overrides or environment variables.
  """

  @default_project_id "unconfigured"
  @safe_project_id ~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/

  @spec symphony_home() :: Path.t()
  def symphony_home do
    local_override(:symphony_home, "SYMPHONY_HOME", Path.join(System.user_home!(), ".symphony"))
  end

  @spec project_root(String.t()) :: Path.t()
  def project_root(project_id) when is_binary(project_id) do
    Path.join(symphony_home(), safe_project_id!(project_id))
  end

  @spec current_project_root() :: Path.t()
  def current_project_root do
    project_root(current_project_id())
  end

  @spec history_git(String.t()) :: Path.t()
  def history_git(project_id), do: Path.join(project_root(project_id), "history.git")

  @spec runtime_root(String.t()) :: Path.t()
  def runtime_root(project_id), do: Path.join(project_root(project_id), "runtime")

  @spec workpads_root(String.t()) :: Path.t()
  def workpads_root(project_id), do: Path.join(project_root(project_id), "workpads")

  @spec jobs_root(String.t()) :: Path.t()
  def jobs_root(project_id), do: Path.join(runtime_root(project_id), "jobs")

  @spec database(String.t()) :: Path.t()
  def database(project_id), do: Path.join(runtime_root(project_id), "board.sqlite3")

  @spec recovery_root(String.t()) :: Path.t()
  def recovery_root(project_id), do: Path.join(runtime_root(project_id), "recovery")

  @spec lease_root(String.t()) :: Path.t()
  def lease_root(project_id), do: Path.join(runtime_root(project_id), "lease")

  @spec logs_root(String.t()) :: Path.t()
  def logs_root(project_id) do
    local_override(:logs_root, "SYMPHONY_LOGS_ROOT", Path.join(runtime_root(project_id), "logs"))
  end

  @spec worktrees_root(String.t()) :: Path.t()
  def worktrees_root(project_id) do
    local_override(
      :worktrees_root,
      "SYMPHONY_WORKTREES_ROOT",
      Path.join(project_root(project_id), "worktrees")
    )
  end

  @spec ensure_project_layout(String.t()) :: :ok | {:error, term()}
  def ensure_project_layout(project_id) do
    paths = [
      project_root(project_id),
      runtime_root(project_id),
      workpads_root(project_id),
      jobs_root(project_id),
      lease_root(project_id),
      logs_root(project_id),
      worktrees_root(project_id)
    ]

    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case File.mkdir_p(path) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:mkdir_failed, path, reason}}}
      end
    end)
  end

  @spec put_override(atom(), Path.t() | nil) :: :ok
  def put_override(key, nil) when key in [:symphony_home, :worktrees_root, :logs_root] do
    Application.delete_env(:symphony_elixir, key)
    :ok
  end

  def put_override(key, path)
      when key in [:symphony_home, :worktrees_root, :logs_root] and is_binary(path) do
    Application.put_env(:symphony_elixir, key, Path.expand(path))
    :ok
  end

  defp current_project_id do
    case SymphonyElixir.Workflow.project_identity() do
      {:ok, %{id: id}} -> id
      _ -> @default_project_id
    end
  end

  defp safe_project_id!(project_id) do
    if Regex.match?(@safe_project_id, project_id) do
      project_id
    else
      raise ArgumentError, "unsafe project id: #{inspect(project_id)}"
    end
  end

  defp local_override(application_key, environment_key, default) do
    case Application.get_env(:symphony_elixir, application_key) || System.get_env(environment_key) do
      value when is_binary(value) and value != "" -> Path.expand(value)
      _ -> Path.expand(default)
    end
  end
end
