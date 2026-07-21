defmodule SymphonyElixir.StageSelection do
  @moduledoc """
  Encodes and decodes the opaque stage-selection identifiers used by web forms.

  A selection is a `{backend, model, effort}` triple where `effort` may be
  `nil`. The wire form is base64url-encoded JSON so form values stay opaque and
  tampering is detected at decode time.
  """

  alias SymphonyElixir.AgentStage

  @spec encode(AgentStage.model_option()) :: String.t()
  def encode({backend, model, effort}) do
    %{"b" => backend, "m" => model, "e" => effort}
    |> Jason.encode!()
    |> Base.url_encode64()
  end

  @spec decode(String.t()) :: {:ok, AgentStage.model_option()} | :error
  def decode(encoded) when is_binary(encoded) do
    with {:ok, json} <- Base.url_decode64(encoded),
         {:ok, %{"b" => backend, "m" => model, "e" => effort}} <- Jason.decode(json),
         true <- is_binary(backend) and is_binary(model) and (is_binary(effort) or is_nil(effort)) do
      {:ok, {backend, model, effort}}
    else
      _ -> :error
    end
  end

  def decode(_encoded), do: :error

  @spec to_map(AgentStage.model_option()) :: %{String.t() => String.t() | nil}
  def to_map({backend, model, effort}) do
    %{"backend" => backend, "model" => model, "effort" => effort}
  end

  @spec label(AgentStage.model_option()) :: String.t()
  def label({backend, model, nil}), do: "#{backend} · #{model}"
  def label({backend, model, effort}), do: "#{backend} · #{model} · #{effort}"
end
