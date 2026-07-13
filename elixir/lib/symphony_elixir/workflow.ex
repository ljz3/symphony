defmodule SymphonyElixir.Workflow do
  @moduledoc """
  Loads the strict `WORKFLOW.yml` configuration and referenced Solid templates.
  """

  alias SymphonyElixir.Workflow.{Bundle, Store}

  @workflow_file_name "WORKFLOW.yml"

  @spec workflow_file_path() :: Path.t()
  def workflow_file_path do
    Application.get_env(:symphony_elixir, :workflow_file_path) ||
      Path.join(File.cwd!(), @workflow_file_name)
  end

  @spec set_workflow_file_path(Path.t()) :: :ok
  def set_workflow_file_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, :workflow_file_path, Path.expand(path))
    maybe_reload_store()
    :ok
  end

  @spec clear_workflow_file_path() :: :ok
  def clear_workflow_file_path do
    Application.delete_env(:symphony_elixir, :workflow_file_path)
    maybe_reload_store()
    :ok
  end

  @spec current() :: {:ok, Bundle.t()} | {:error, term()}
  def current do
    case Process.whereis(Store) do
      pid when is_pid(pid) -> Store.current()
      _ -> load()
    end
  end

  @spec load() :: {:ok, Bundle.t()} | {:error, term()}
  def load, do: load(workflow_file_path())

  @spec load(Path.t()) :: {:ok, Bundle.t()} | {:error, term()}
  def load(path) when is_binary(path) do
    expanded_path = Path.expand(path)

    with {:ok, content} <- read_workflow(expanded_path),
         {:ok, decoded} <- decode_yaml(content) do
      Bundle.load(decoded, expanded_path)
    end
  end

  @spec project_identity() :: {:ok, %{id: String.t(), key: String.t()}} | {:error, term()}
  def project_identity do
    path = workflow_file_path()

    with {:ok, content} <- read_workflow(path),
         {:ok, decoded} <- decode_yaml(content),
         %{} = project <- Map.get(decoded, "project"),
         id when is_binary(id) <- Map.get(project, "id"),
         key when is_binary(key) <- Map.get(project, "key"),
         :ok <- validate_identity(id, key) do
      {:ok, %{id: id, key: key}}
    else
      nil -> {:error, :missing_project}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_project_identity}
    end
  end

  defp read_workflow(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:missing_workflow_file, path, reason}}
    end
  end

  defp decode_yaml(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, decoded} when is_map(decoded) -> {:ok, stringify_keys(decoded)}
      {:ok, _decoded} -> {:error, :workflow_document_not_a_map}
      {:error, reason} -> {:error, {:workflow_parse_error, reason}}
    end
  end

  defp validate_identity(id, key) do
    cond do
      not Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/, id) ->
        {:error, :invalid_project_id}

      not Regex.match?(~r/\A[A-Z][A-Z0-9]*\z/, key) ->
        {:error, :invalid_project_key}

      true ->
        :ok
    end
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp maybe_reload_store do
    if Process.whereis(Store), do: Store.force_reload()
    :ok
  end
end
