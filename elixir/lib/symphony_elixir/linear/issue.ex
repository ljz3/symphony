defmodule SymphonyElixir.Linear.Issue do
  @moduledoc """
  Normalized Linear issue representation used by the orchestrator.
  """

  @model_label_prefix "model:"
  @effort_label_prefix "effort:"

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    blocked_by: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          labels: [String.t()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end

  @spec codex_model(t()) ::
          {:ok, String.t() | nil}
          | {:error, {:empty_model_label, String.t()} | {:multiple_model_labels, [String.t()]}}
  def codex_model(issue), do: codex_label(issue, @model_label_prefix, :model)

  @spec codex_effort(t()) ::
          {:ok, String.t() | nil}
          | {:error, {:empty_effort_label, String.t()} | {:multiple_effort_labels, [String.t()]}}
  def codex_effort(issue), do: codex_label(issue, @effort_label_prefix, :effort)

  @spec codex_selection(t()) ::
          {:ok, %{model: String.t() | nil, effort: String.t() | nil}}
          | {
              :error,
              [
                {:empty_model_label, String.t()}
                | {:multiple_model_labels, [String.t()]}
                | {:empty_effort_label, String.t()}
                | {:multiple_effort_labels, [String.t()]}
              ]
            }
  def codex_selection(%__MODULE__{} = issue) do
    case {codex_model(issue), codex_effort(issue)} do
      {{:ok, model}, {:ok, effort}} ->
        {:ok, %{model: model, effort: effort}}

      {model_result, effort_result} ->
        errors =
          [model_result, effort_result]
          |> Enum.flat_map(fn
            {:error, reason} -> [reason]
            _ -> []
          end)

        {:error, errors}
    end
  end

  @spec routable?(t(), [String.t()]) :: boolean()
  def routable?(%__MODULE__{assigned_to_worker: true, labels: labels}, required_labels)
      when is_list(labels) and is_list(required_labels) do
    issue_labels = MapSet.new(labels, &normalize_label/1)
    Enum.all?(required_labels, &MapSet.member?(issue_labels, normalize_label(&1)))
  end

  def routable?(%__MODULE__{}, _required_labels), do: false

  defp codex_label(%__MODULE__{labels: labels}, label_prefix, label_type) when is_list(labels) do
    matching_labels =
      Enum.filter(labels, fn
        label when is_binary(label) ->
          label
          |> String.trim()
          |> String.downcase()
          |> String.starts_with?(label_prefix)

        _ ->
          false
      end)

    case matching_labels do
      [] ->
        {:ok, nil}

      [label] ->
        value =
          label
          |> String.trim()
          |> String.slice(byte_size(label_prefix)..-1//1)
          |> String.trim()

        if value == "" do
          {:error, empty_codex_label_error(label_type, label)}
        else
          {:ok, value}
        end

      labels ->
        {:error, multiple_codex_label_error(label_type, labels)}
    end
  end

  defp codex_label(%__MODULE__{}, _label_prefix, _label_type), do: {:ok, nil}

  defp empty_codex_label_error(:model, label), do: {:empty_model_label, label}
  defp empty_codex_label_error(:effort, label), do: {:empty_effort_label, label}

  defp multiple_codex_label_error(:model, labels), do: {:multiple_model_labels, labels}
  defp multiple_codex_label_error(:effort, labels), do: {:multiple_effort_labels, labels}

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end
end
