defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime accessors for the active `WORKFLOW.yml` bundle and local overrides.
  """

  alias SymphonyElixir.AgentStage
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.Workflow.Bundle

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @type codex_selection :: %{model: String.t(), effort: String.t()}

  @spec bundle() :: {:ok, Bundle.t()} | {:error, term()}
  def bundle, do: Workflow.current()

  @spec bundle!() :: Bundle.t()
  def bundle! do
    case bundle() do
      {:ok, bundle} -> bundle
      {:error, reason} -> raise ArgumentError, format_config_error(reason)
    end
  end

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case bundle() do
      {:ok, bundle} -> {:ok, Schema.from_bundle(bundle)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} -> settings
      {:error, reason} -> raise ArgumentError, format_config_error(reason)
    end
  end

  @spec stage(String.t()) :: {:ok, AgentStage.t()} | {:error, term()}
  def stage(stage_id) when is_binary(stage_id) do
    case Map.fetch(bundle!().stages, stage_id) do
      {:ok, stage} -> {:ok, stage}
      :error -> {:error, {:unknown_stage, stage_id}}
    end
  end

  @spec validate_codex_selection(String.t(), codex_selection()) :: :ok | {:error, term()}
  def validate_codex_selection(stage_id, %{model: model, effort: effort}) do
    with {:ok, stage} <- stage(stage_id) do
      if AgentStage.permits?(stage, model, effort) do
        :ok
      else
        {:error, {:model_effort_not_permitted, stage_id, model, effort}}
      end
    end
  end

  @doc false
  @spec validate_codex_selection(codex_selection()) :: :ok | {:error, term()}
  def validate_codex_selection(%{model: model, effort: effort}) do
    if Enum.any?(bundle!().stages, fn {_id, stage} -> AgentStage.permits?(stage, model, effort) end) do
      :ok
    else
      {:error, {:model_effort_not_permitted, model, effort}}
    end
  end

  @doc false
  @spec allowed_codex_model_efforts() :: %{optional(String.t()) => [String.t()]}
  def allowed_codex_model_efforts do
    Enum.reduce(bundle!().stages, %{}, fn {_id, stage}, acc ->
      Map.merge(acc, stage.allowed_model_efforts, fn _model, left, right -> Enum.uniq(left ++ right) end)
    end)
  end

  @doc false
  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(_state), do: settings!().agent.max_concurrent_agents

  @doc false
  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    bundle = bundle!()
    Enum.join([bundle.base_prompt, bundle.context_prompt], "\n\n")
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) || System.get_env("SYMPHONY_PORT") do
      port when is_integer(port) and port >= 0 -> port
      port when is_binary(port) -> parse_port(port)
      _ -> nil
    end
  end

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} -> policy
      {:error, reason} -> raise ArgumentError, "invalid Codex sandbox policy: #{inspect(reason)}"
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings(),
         {:ok, policy} <- Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
      {:ok,
       %{
         approval_policy: settings.codex.approval_policy,
         thread_sandbox: settings.codex.thread_sandbox,
         turn_sandbox_policy: policy
       }}
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    case bundle() do
      {:ok, _bundle} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_port(port) do
    case Integer.parse(port) do
      {value, ""} when value >= 0 and value <= 65_535 -> value
      _ -> nil
    end
  end

  defp format_config_error(reason) do
    "Invalid WORKFLOW.yml bundle: #{inspect(reason)}"
  end
end
