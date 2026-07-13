defmodule SymphonyElixir.TaskCreateTool do
  @moduledoc """
  Shared contract for the task-creation tool exposed to Codex and MCP clients.
  """

  @name "symphony_task_create"
  @dynamic_description "Create an execution-ready follow-up task in Backlog."

  @mcp_description """
                   Create an execution-ready task in this Symphony project's Backlog. Supply the exact project_id
                   you independently intend to modify; never guess or substitute a project ID after a mismatch.
                   """
                   |> String.replace("\n", " ")
                   |> String.trim()

  @base_required ["title", "type", "brief", "acceptance_criteria"]
  @optional ["priority", "dependencies", "stage_selections"]
  @mcp_required ["project_id" | @base_required]
  @mcp_allowed @mcp_required ++ @optional

  @base_properties %{
    "title" => %{"type" => "string", "minLength" => 1},
    "type" => %{"type" => "string", "enum" => ["Feature", "Bug Fix", "Chore"]},
    "priority" => %{"type" => "string", "enum" => ["Urgent", "High", "Normal", "Low"]},
    "brief" => %{"type" => "string", "minLength" => 1},
    "acceptance_criteria" => %{
      "type" => "array",
      "minItems" => 1,
      "items" => %{"type" => "string", "minLength" => 1}
    },
    "dependencies" => %{"type" => "array", "items" => %{"type" => "string"}},
    "stage_selections" => %{"type" => "object", "additionalProperties" => %{"type" => "object"}}
  }

  @project_property %{
    "type" => "string",
    "minLength" => 1,
    "description" => "Exact workflow project ID the caller independently intends to modify. Do not guess or replace it after a mismatch."
  }

  @spec name() :: String.t()
  def name, do: @name

  @spec dynamic_description() :: String.t()
  def dynamic_description, do: @dynamic_description

  @spec mcp_description() :: String.t()
  def mcp_description, do: @mcp_description

  @spec input_schema(boolean()) :: map()
  def input_schema(require_project_id) when is_boolean(require_project_id) do
    properties =
      if require_project_id,
        do: Map.put(@base_properties, "project_id", @project_property),
        else: @base_properties

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => if(require_project_id, do: @mcp_required, else: @base_required),
      "properties" => properties
    }
  end

  @spec mcp_tool_spec() :: map()
  def mcp_tool_spec do
    %{
      "name" => @name,
      "description" => @mcp_description,
      "inputSchema" => input_schema(true),
      "annotations" => %{
        "title" => "Create Symphony backlog task",
        "readOnlyHint" => false,
        "destructiveHint" => false,
        "idempotentHint" => false,
        "openWorldHint" => false
      }
    }
  end

  @spec validate_mcp_arguments(term()) :: {:ok, map()} | {:error, term()}
  def validate_mcp_arguments(arguments) when is_map(arguments) do
    with :ok <- string_keys(arguments),
         :ok <- known_fields(arguments),
         :ok <- required_fields(arguments),
         :ok <- nonempty_string_field(arguments, "project_id"),
         :ok <- nonempty_string_field(arguments, "title"),
         :ok <- enum_field(arguments, "type", ["Feature", "Bug Fix", "Chore"]),
         :ok <- nonempty_string_field(arguments, "brief"),
         :ok <- optional_enum_field(arguments, "priority", ["Urgent", "High", "Normal", "Low"]),
         :ok <- acceptance_criteria(arguments),
         :ok <- optional_string_list(arguments, "dependencies"),
         :ok <- optional_object_map(arguments, "stage_selections") do
      {:ok,
       arguments
       |> Map.delete("project_id")
       |> Map.put_new("priority", "Normal")}
    end
  end

  def validate_mcp_arguments(_arguments), do: {:error, :arguments_must_be_object}

  defp string_keys(arguments) do
    if Enum.all?(Map.keys(arguments), &is_binary/1),
      do: :ok,
      else: {:error, :arguments_must_use_string_keys}
  end

  defp known_fields(arguments) do
    unknown = arguments |> Map.keys() |> Enum.reject(&(&1 in @mcp_allowed)) |> Enum.sort()
    if unknown == [], do: :ok, else: {:error, {:unknown_fields, unknown}}
  end

  defp required_fields(arguments) do
    missing = Enum.reject(@mcp_required, &Map.has_key?(arguments, &1))
    if missing == [], do: :ok, else: {:error, {:missing_fields, missing}}
  end

  defp nonempty_string_field(arguments, field) do
    case arguments[field] do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, {:invalid_field, field}}, else: :ok

      _value ->
        {:error, {:invalid_field, field}}
    end
  end

  defp enum_field(arguments, field, values) do
    if arguments[field] in values, do: :ok, else: {:error, {:invalid_field, field}}
  end

  defp optional_enum_field(arguments, field, values) do
    case Map.fetch(arguments, field) do
      :error -> :ok
      {:ok, value} -> if(value in values, do: :ok, else: {:error, {:invalid_field, field}})
    end
  end

  defp acceptance_criteria(arguments) do
    case arguments["acceptance_criteria"] do
      values when is_list(values) and values != [] ->
        if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")),
          do: :ok,
          else: {:error, {:invalid_field, "acceptance_criteria"}}

      _values ->
        {:error, {:invalid_field, "acceptance_criteria"}}
    end
  end

  defp optional_string_list(arguments, field) do
    case Map.fetch(arguments, field) do
      :error ->
        :ok

      {:ok, values} when is_list(values) ->
        if Enum.all?(values, &is_binary/1), do: :ok, else: {:error, {:invalid_field, field}}

      {:ok, _values} ->
        {:error, {:invalid_field, field}}
    end
  end

  defp optional_object_map(arguments, field) do
    case Map.fetch(arguments, field) do
      :error ->
        :ok

      {:ok, values} when is_map(values) ->
        validate_object_map(values, field)

      {:ok, _values} ->
        {:error, {:invalid_field, field}}
    end
  end

  defp validate_object_map(values, field) do
    if Enum.all?(values, fn {key, value} -> is_binary(key) and is_map(value) end),
      do: :ok,
      else: {:error, {:invalid_field, field}}
  end
end
