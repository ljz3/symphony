defmodule SymphonyElixir.AgentStage do
  @moduledoc """
  Frozen configuration for one named agent stage.
  """

  @derive Jason.Encoder
  @enforce_keys [:id, :prompt_path, :prompt, :workpad_template_path, :workpad_template, :allowed_model_efforts]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          prompt_path: Path.t(),
          prompt: String.t(),
          workpad_template_path: Path.t(),
          workpad_template: String.t(),
          allowed_model_efforts: %{required(String.t()) => [String.t()]}
        }

  @spec pairs(t()) :: [{String.t(), String.t()}]
  def pairs(%__MODULE__{allowed_model_efforts: allowed}) do
    allowed
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {model, efforts} -> Enum.map(efforts, &{model, &1}) end)
  end

  @spec singleton_pair(t()) :: {:ok, {String.t(), String.t()}} | :multiple
  def singleton_pair(%__MODULE__{} = stage) do
    case pairs(stage) do
      [pair] -> {:ok, pair}
      _ -> :multiple
    end
  end

  @spec permits?(t(), String.t(), String.t()) :: boolean()
  def permits?(%__MODULE__{} = stage, model, effort) do
    effort in Map.get(stage.allowed_model_efforts, model, [])
  end
end
