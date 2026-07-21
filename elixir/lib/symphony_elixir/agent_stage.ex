defmodule SymphonyElixir.AgentStage do
  @moduledoc """
  Frozen configuration for one named agent stage.
  """

  @enforce_keys [:id, :prompt_path, :prompt, :workpad_template_path, :workpad_template, :allowed]
  defstruct @enforce_keys

  @typedoc """
  One permitted agent selection: `{backend, model, effort}`.

  `effort` is `nil` when the selection carries no thinking-effort choice.
  """
  @type model_option :: {String.t(), String.t(), String.t() | nil}

  @type t :: %__MODULE__{
          id: String.t(),
          prompt_path: Path.t(),
          prompt: String.t(),
          workpad_template_path: Path.t(),
          workpad_template: String.t(),
          allowed: [model_option()]
        }

  @spec pairs(t()) :: [model_option()]
  def pairs(%__MODULE__{allowed: allowed}) do
    Enum.sort(allowed)
  end

  @spec singleton_pair(t()) :: {:ok, model_option()} | :multiple
  def singleton_pair(%__MODULE__{} = stage) do
    case pairs(stage) do
      [pair] -> {:ok, pair}
      _ -> :multiple
    end
  end

  @spec permits?(t(), String.t(), String.t(), String.t() | nil) :: boolean()
  def permits?(%__MODULE__{} = stage, backend, model, effort) do
    {backend, model, effort} in stage.allowed
  end
end

defimpl Jason.Encoder, for: SymphonyElixir.AgentStage do
  def encode(stage, opts) do
    stage
    |> Map.from_struct()
    |> Map.update!(:allowed, fn allowed -> Enum.map(allowed, &Tuple.to_list/1) end)
    |> Jason.Encode.map(opts)
  end
end
