defmodule SymphonyElixir.AgentBackend do
  @moduledoc """
  Behaviour and dispatch seam for agent backends.

  Two adapters exist: `SymphonyElixir.Backend.CodexAppServer` (protocol
  `"app_server"`, reserved for the backend named `"codex"`) and
  `SymphonyElixir.Backend.KimiACP` (protocol `"acp"`). All agent-session
  interaction from the orchestrator and the agent runner goes through this
  module so backends stay interchangeable.
  """

  require Logger

  alias SymphonyElixir.ACP.Client, as: ACPClient
  alias SymphonyElixir.Backend.CodexAppServer
  alias SymphonyElixir.Config

  @typedoc "Configured backend name from the workflow `backends:` section."
  @type backend_name :: String.t()

  @typedoc "Opaque adapter session. Always tagged with the `:backend` name."
  @type session :: map()

  @typedoc "Successful stop reasons a prompt turn may report."
  @type stop_reason :: :end_turn | :max_tokens | :max_turn_requests

  @typedoc """
  Result of one prompt turn. `:session` is the currently active session,
  which may differ from the input session when the adapter reconnected.
  """
  @type prompt_result :: %{
          required(:session) => session(),
          required(:stop_reason) => stop_reason(),
          required(:turn_id) => String.t() | nil,
          optional(:meta) => map()
        }

  @doc "Start a backend session rooted at a validated workspace directory."
  @callback start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}

  @doc "Run one prompt turn, returning the active session and stop reason."
  @callback prompt(session(), String.t(), SymphonyElixir.Task.t(), keyword()) ::
              {:ok, prompt_result()} | {:error, term()}

  @doc "Request cancellation of the in-flight turn. Best-effort; always returns `:ok`."
  @callback cancel_turn(session()) :: :ok

  @doc "Terminate the session and its process. Must be idempotent."
  @callback stop_session(session()) :: :ok

  @doc "The backend session identifier used for logs, events, and status views."
  @callback session_id(session()) :: String.t() | nil

  @doc "Summarize the run's recorded telemetry for RunFinished/RunFailed stats."
  @callback stats(run_id :: String.t()) :: map()

  @spec module_for(backend_name()) :: {:ok, module()} | {:error, term()}
  def module_for(backend) when is_binary(backend) do
    with {:ok, bundle} <- Config.bundle() do
      case Map.fetch(bundle.backends, backend) do
        {:ok, %{protocol: "app_server"}} -> {:ok, SymphonyElixir.Backend.CodexAppServer}
        {:ok, %{protocol: "acp"}} -> {:ok, SymphonyElixir.Backend.KimiACP}
        {:ok, config} -> {:error, {:unknown_backend_protocol, backend, config[:protocol]}}
        :error -> {:error, {:unknown_backend, backend}}
      end
    end
  end

  @spec module_for!(backend_name()) :: module()
  def module_for!(backend) when is_binary(backend) do
    case module_for(backend) do
      {:ok, module} ->
        module

      {:error, reason} ->
        raise ArgumentError, "cannot resolve agent backend #{inspect(backend)}: #{inspect(reason)}"
    end
  end

  @doc """
  Cancel any in-flight turn, then stop the session. Used on the orchestrator
  interrupt path; falls back to closing the raw port when the backend cannot
  be resolved so legacy sessions are still terminated.
  """
  @spec terminate_session(backend_name(), session()) :: :ok
  def terminate_session(backend, session) do
    case module_for(backend) do
      {:ok, module} ->
        module.cancel_turn(session)
        module.stop_session(session)

      {:error, reason} ->
        Logger.warning("terminating session with unresolved backend=#{backend} reason=#{inspect(reason)}")
        if is_port(session[:port]), do: Port.close(session[:port])
        if is_pid(session[:client]), do: ACPClient.stop(session[:client])
    end

    :ok
  end

  @spec session_id(backend_name(), session()) :: String.t() | nil
  def session_id(backend, session) do
    case module_for(backend) do
      {:ok, module} -> module.session_id(session)
      {:error, _reason} -> nil
    end
  end

  @doc """
  Run-finish stats for a run, summarized by the run's own backend. Falls back
  to the codex summarizer when the backend is no longer resolvable so legacy
  runs still finalize.
  """
  @spec stats(backend_name(), String.t()) :: map()
  def stats(backend, run_id) do
    case module_for(backend) do
      {:ok, module} -> module.stats(run_id)
      {:error, _reason} -> CodexAppServer.stats(run_id)
    end
  end
end
