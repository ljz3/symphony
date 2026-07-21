defmodule SymphonyElixir.Task do
  @moduledoc """
  Tracker-neutral task projected from the canonical board event stream.
  """

  alias SymphonyElixir.Workflow.Bundle

  @derive Jason.Encoder
  @enforce_keys [
    :id,
    :identifier,
    :number,
    :project_id,
    :title,
    :type,
    :branch,
    :priority,
    :brief,
    :acceptance_criteria,
    :column_id,
    :rank,
    :revision,
    :created_at,
    :updated_at
  ]
  defstruct [
    :id,
    :identifier,
    :number,
    :project_id,
    :title,
    :type,
    :branch,
    :priority,
    :brief,
    :column_id,
    :rank,
    :blocked_from_column_id,
    :desired_column_id,
    :runtime_state,
    :active_run_id,
    :created_at,
    :updated_at,
    :archived_at,
    :review_attestation,
    :merge_saga,
    acceptance_criteria: [],
    dependencies: [],
    stage_selections: %{},
    revision: 0,
    source: %{},
    github: %{},
    metadata: %{}
  ]

  @type task_type :: :feature | :bug_fix | :chore
  @type priority :: :urgent | :high | :normal | :low
  @type criterion :: %{
          required(:id) => String.t(),
          required(:text) => String.t(),
          required(:completed) => boolean(),
          required(:evidence) => [map()],
          required(:evidence_history) => [map()]
        }
  @type selection :: %{optional(String.t()) => %{optional(String.t()) => String.t() | nil}}
  @type t :: %__MODULE__{
          id: String.t(),
          identifier: String.t(),
          number: pos_integer(),
          project_id: String.t(),
          title: String.t(),
          type: task_type(),
          branch: String.t(),
          priority: priority(),
          brief: String.t(),
          acceptance_criteria: [criterion()],
          dependencies: [String.t()],
          stage_selections: selection(),
          column_id: String.t(),
          rank: integer(),
          revision: non_neg_integer(),
          blocked_from_column_id: String.t() | nil,
          desired_column_id: String.t() | nil,
          runtime_state: String.t() | nil,
          active_run_id: String.t() | nil,
          source: map(),
          github: map(),
          review_attestation: map() | nil,
          merge_saga: map() | nil,
          metadata: map(),
          created_at: String.t(),
          updated_at: String.t(),
          archived_at: String.t() | nil
        }

  @spec branch_for(task_type(), String.t()) :: String.t()
  def branch_for(:feature, identifier), do: "feature/#{identifier}"
  def branch_for(:bug_fix, identifier), do: "fix/#{identifier}"
  def branch_for(:chore, identifier), do: "chore/#{identifier}"

  @spec priority_weight(priority()) :: 0..3
  def priority_weight(:urgent), do: 0
  def priority_weight(:high), do: 1
  def priority_weight(:normal), do: 2
  def priority_weight(:low), do: 3

  @spec archived?(t()) :: boolean()
  def archived?(%__MODULE__{archived_at: archived_at}), do: not is_nil(archived_at)

  @spec terminal?(t(), Bundle.t()) :: boolean()
  def terminal?(%__MODULE__{column_id: column_id}, bundle) do
    case Bundle.column(bundle, column_id) do
      %{role: :terminal} -> true
      _ -> false
    end
  end

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    attrs = stringify_keys(map)

    struct!(__MODULE__, %{
      id: attrs["id"],
      identifier: attrs["identifier"],
      number: attrs["number"],
      project_id: attrs["project_id"],
      title: attrs["title"],
      type: atom_value(attrs["type"]),
      branch: attrs["branch"],
      priority: atom_value(attrs["priority"]),
      brief: attrs["brief"],
      acceptance_criteria: attrs["acceptance_criteria"] || [],
      dependencies: attrs["dependencies"] || [],
      stage_selections: normalize_selections(attrs["stage_selections"] || %{}),
      column_id: attrs["column_id"],
      rank: attrs["rank"],
      revision: attrs["revision"],
      blocked_from_column_id: attrs["blocked_from_column_id"],
      desired_column_id: attrs["desired_column_id"],
      runtime_state: attrs["runtime_state"],
      active_run_id: attrs["active_run_id"],
      source: attrs["source"] || %{},
      github: attrs["github"] || %{},
      review_attestation: attrs["review_attestation"],
      merge_saga: attrs["merge_saga"],
      metadata: attrs["metadata"] || %{},
      created_at: attrs["created_at"],
      updated_at: attrs["updated_at"],
      archived_at: attrs["archived_at"]
    })
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = task) do
    task
    |> Map.from_struct()
    |> stringify_keys()
  end

  # Selections committed before the multi-backend change carry no "backend"
  # key; they always mean the codex backend.
  defp normalize_selections(selections) when is_map(selections) do
    Map.new(selections, fn
      {stage_id, selection} when is_map(selection) ->
        {stage_id, Map.put_new(selection, "backend", "codex")}

      other ->
        other
    end)
  end

  defp normalize_selections(selections), do: selections

  defp atom_value(value) when is_atom(value), do: value
  defp atom_value(value) when is_binary(value), do: String.to_existing_atom(value)

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(nil), do: nil
  defp stringify_keys(value) when is_boolean(value), do: value
  defp stringify_keys(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_keys(value), do: value
end
