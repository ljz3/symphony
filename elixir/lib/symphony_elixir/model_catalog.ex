defmodule SymphonyElixir.ModelCatalog do
  @moduledoc """
  Per-backend model catalog facade for task-editing surfaces.

  Combines the codex app-server catalog with one catalog per ACP backend.
  When a backend's catalog is unavailable (or disabled), the workflow policy
  is trusted as-is for that backend — dispatch-time adapter validation stays
  the authoritative check.
  """

  alias SymphonyElixir.{AgentStage, Config}
  alias SymphonyElixir.Backend.KimiACP
  alias SymphonyElixir.Codex

  @spec pairs(AgentStage.t()) :: [AgentStage.model_option()]
  def pairs(%AgentStage{} = stage) do
    codex_options = Codex.Catalog.pairs(stage)

    acp_options =
      stage
      |> AgentStage.pairs()
      |> Enum.reject(fn {backend, _model, _effort} -> backend == "codex" end)
      |> Enum.group_by(fn {backend, _model, _effort} -> backend end)
      |> Enum.flat_map(fn {backend, options} -> KimiACP.Catalog.pairs(backend, options) end)

    Enum.sort(codex_options ++ acp_options)
  end

  @spec status() :: %{String.t() => map()}
  def status do
    Map.new(Config.backends(), fn {backend, config} -> {backend, backend_status(backend, config)} end)
  end

  defp backend_status("codex", _config) do
    case Codex.Catalog.status() do
      %{configured: false} ->
        %{configured: false, state: :disabled}

      %{loading: true} ->
        %{configured: true, state: :loading}

      %{available: true, models: models} ->
        %{configured: true, state: :available, model_count: length(models)}

      %{error: error} ->
        %{configured: true, state: {:failed, error}}
    end
  end

  defp backend_status(backend, _config) do
    case KimiACP.Catalog.status()[backend] do
      %{state: :available, options: options} -> %{configured: true, state: :available, model_count: length(options)}
      %{state: :failed, error: error} -> %{configured: true, state: {:failed, error}}
      %{state: :disabled} -> %{configured: false, state: :disabled}
      _ -> %{configured: true, state: :loading}
    end
  end
end
