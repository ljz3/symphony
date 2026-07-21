defmodule SymphonyElixir.Backend.KimiACP do
  @moduledoc """
  `AgentBackend` adapter for the Kimi CLI in ACP mode (`kimi acp`).

  Speaks the Agent Client Protocol over stdio via `SymphonyElixir.ACP.Client`.
  Sessions are local-only and unsandboxed (trusted-local-process model; the
  workflow opts in with `allow_unsandboxed: true`). There is no resume: a
  transport failure fails the run and the task moves to Blocked, matching
  Symphony's no-retry-queue rule.

  Model, thinking effort, and permission mode are applied through kimi's
  documented session config options (`model`, `thinking`, `mode`): the model
  is set first, the complete returned configuration state is consumed, and
  the effort is validated and set only when the selected model supports it.
  """

  @behaviour SymphonyElixir.AgentBackend

  require Logger

  alias SymphonyElixir.ACP.Client, as: ACPClient
  alias SymphonyElixir.Board.Projection
  alias SymphonyElixir.{Config, Paths, WorkspaceSafety}
  alias SymphonyElixir.MCP.RunBridge

  @protocol_version 1
  @handshake_timeout_ms 30_000
  @request_timeout_ms 30_000
  @auth_required_code -32_000

  # ------------------------------------------------------------------
  # AgentBackend callbacks
  # ------------------------------------------------------------------

  @impl true
  def start_session(workspace, opts) do
    backend = Keyword.fetch!(opts, :backend)
    run_id = Keyword.fetch!(opts, :run_id)
    invocation = Keyword.get(opts, :invocation, 1)

    with :ok <- require_local_worker(Keyword.get(opts, :worker_host)),
         {:ok, expanded_workspace} <- WorkspaceSafety.validate_local_task_cwd(workspace),
         {:ok, bridge} <- RunBridge.register(run_id, invocation) do
      case boot(expanded_workspace, backend, bridge, opts) do
        {:ok, session} ->
          {:ok, session}

        {:error, reason} ->
          RunBridge.unregister(run_id, invocation)
          {:error, reason}
      end
    end
  end

  @impl true
  def prompt(session, prompt, task, opts) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn = session.turn + 1
    turn_id = "prompt-#{turn}"

    Logger.info(
      "Kimi session started for task_id=#{task.id} session_id=#{session.session_id} " <>
        "turn=#{turn} model=#{session.model || "default"} effort=#{session.effort || "default"}"
    )

    emit_message(on_message, :session_started, %{
      session_id: "#{session.session_id}-#{turn_id}",
      thread_id: session.session_id,
      turn_id: turn_id,
      model: session.model,
      effort: session.effort
    })

    params = %{"sessionId" => session.session_id, "prompt" => [%{"type" => "text", "text" => prompt}]}

    case ACPClient.request_async(session.client, "session/prompt", params, :infinity) do
      {:ok, ref} ->
        await_prompt(%{session | turn: turn}, ref, turn_id, on_message)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def cancel_turn(session) do
    ACPClient.notify(session.client, "session/cancel", %{"sessionId" => session.session_id})
  end

  @impl true
  def stop_session(session) do
    ACPClient.stop(session.client)
    RunBridge.unregister(session.run_id, session.invocation)
    :ok
  end

  @impl true
  def session_id(session), do: Map.get(session, :session_id)

  @impl true
  def stats(run_id) do
    case Projection.run_telemetry(run_id) do
      nil ->
        %{"session_id" => nil, "turn_count" => 0, "token_usage" => nil}

      telemetry ->
        %{
          "session_id" => telemetry["thread_id"],
          "turn_count" => telemetry |> Map.get("turn_ids", []) |> Enum.uniq() |> length(),
          "token_usage" => nil
        }
    end
  end

  # ------------------------------------------------------------------
  # Session boot: spawn, handshake, config options
  # ------------------------------------------------------------------

  defp require_local_worker(nil), do: :ok
  defp require_local_worker(worker_host) when is_binary(worker_host), do: {:error, :acp_remote_unsupported}

  defp boot(workspace, backend, bridge, opts) do
    backend_config = Config.backend!(backend)
    stderr_log = stderr_log_path(Keyword.fetch!(opts, :run_id))
    File.mkdir_p!(Path.dirname(stderr_log))

    client_opts = [
      command: backend_config.command,
      cwd: workspace,
      environment: Keyword.get(opts, :environment, %{}),
      stderr_log: stderr_log,
      subscriber: self()
    ]

    case ACPClient.start_link(client_opts) do
      {:ok, client} ->
        case handshake_and_configure(client, workspace, backend_config, bridge, opts) do
          {:ok, session_id} ->
            {:ok,
             %{
               backend: backend,
               client: client,
               session_id: session_id,
               model: Keyword.get(opts, :model),
               effort: Keyword.get(opts, :effort),
               workspace: workspace,
               run_id: Keyword.fetch!(opts, :run_id),
               invocation: Keyword.get(opts, :invocation, 1),
               stderr_log: stderr_log,
               turn: 0
             }}

          {:error, reason} ->
            ACPClient.stop(client)
            log_stderr_tail(stderr_log, reason)
            {:error, reason}
        end

      {:error, reason} ->
        log_stderr_tail(stderr_log, reason)
        {:error, reason}
    end
  end

  defp handshake_and_configure(client, workspace, backend_config, bridge, opts) do
    with {:ok, hello} <- initialize(client),
         :ok <- verify_capabilities(hello),
         :ok <- maybe_authenticate(client, hello),
         {:ok, session_id, config_options} <- session_new(client, workspace, bridge),
         :ok <- apply_selection(client, session_id, config_options, backend_config, opts) do
      {:ok, session_id}
    end
  end

  defp initialize(client) do
    params = %{
      "protocolVersion" => @protocol_version,
      "clientCapabilities" => %{"session" => %{"configOptions" => %{"boolean" => %{}}}},
      "clientInfo" => %{"name" => "symphony-orchestrator", "title" => "Symphony Orchestrator", "version" => "0.1.0"}
    }

    case await(ACPClient.request_async(client, "initialize", params, @handshake_timeout_ms)) do
      {:ok, %{"protocolVersion" => @protocol_version} = hello} ->
        {:ok, hello}

      {:ok, %{"protocolVersion" => other}} ->
        {:error, {:unsupported_acp_protocol_version, other}}

      {:ok, other} ->
        {:error, {:unsupported_kimi_acp_shape, {:initialize, other}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_capabilities(hello) do
    if get_in(hello, ["agentCapabilities", "mcpCapabilities", "http"]) == true do
      :ok
    else
      {:error, :mcp_http_capability_missing}
    end
  end

  defp maybe_authenticate(client, hello) do
    auth_methods = Map.get(hello, "authMethods", [])

    if Enum.any?(auth_methods, &(&1["id"] == "login")) do
      case await(ACPClient.request_async(client, "authenticate", %{"methodId" => "login"}, @request_timeout_ms)) do
        {:ok, _result} -> :ok
        {:error, {:acp_error, %{"code" => @auth_required_code}}} -> {:error, {:acp_auth_required, "kimi login"}}
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp session_new(client, workspace, bridge) do
    params = %{
      "cwd" => workspace,
      "mcpServers" => [
        %{
          "name" => "symphony",
          "type" => "http",
          "url" => bridge.url,
          "headers" => [%{"name" => "Authorization", "value" => "Bearer #{bridge.token}"}]
        }
      ]
    }

    case await(ACPClient.request_async(client, "session/new", params, @handshake_timeout_ms)) do
      {:ok, %{"sessionId" => session_id} = result} when is_binary(session_id) ->
        {:ok, session_id, Map.get(result, "configOptions", [])}

      {:ok, other} ->
        {:error, {:unsupported_kimi_acp_shape, {:session_new, other}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Documented kimi config IDs: model, thinking, mode. The model is set
  # first; every set returns the complete updated option state, which is
  # threaded through the remaining selections.
  defp apply_selection(client, session_id, config_options, backend_config, opts) do
    model = Keyword.get(opts, :model)
    effort = Keyword.get(opts, :effort)
    permission_mode = backend_config[:permission_mode] || "auto"

    with {:ok, options} <- maybe_set_model(client, session_id, config_options, model),
         {:ok, options} <- maybe_set_effort(client, session_id, options, model, effort) do
      set_mode(client, session_id, options, permission_mode)
    end
  end

  defp maybe_set_model(_client, _session_id, options, nil), do: {:ok, options}

  defp maybe_set_model(client, session_id, options, model) do
    with {:ok, option} <- fetch_required_option(options, "model", "model"),
         :ok <- require_option_value(option, model, {:model_unavailable, model}) do
      set_config_option(client, session_id, option["id"], model)
    end
  end

  defp maybe_set_effort(_client, _session_id, options, _model, nil), do: {:ok, options}

  defp maybe_set_effort(client, session_id, options, model, effort) do
    case Enum.find(options, &(&1["id"] == "thinking")) do
      nil ->
        {:error, {:effort_unsupported, model, effort}}

      option ->
        with {:ok, _validated} <- validate_option_shape(option, "thinking", "thought_level"),
             :ok <- require_option_value(option, effort, {:effort_unsupported, model, effort}) do
          set_config_option(client, session_id, option["id"], effort)
        end
    end
  end

  defp set_mode(client, session_id, options, permission_mode) do
    with {:ok, option} <- fetch_required_option(options, "mode", "mode"),
         :ok <- require_option_value(option, permission_mode, {:permission_mode_unavailable, permission_mode}),
         {:ok, _options} <- set_config_option(client, session_id, option["id"], permission_mode) do
      :ok
    end
  end

  defp fetch_required_option(options, id, category) do
    case Enum.find(options, &(&1["id"] == id)) do
      nil -> {:error, {:unsupported_kimi_acp_shape, {:missing_option, id}}}
      option -> validate_option_shape(option, id, category)
    end
  end

  defp validate_option_shape(option, id, category) do
    with :ok <- require_select_type(option, id),
         :ok <- require_option_category(option, id, category) do
      {:ok, option}
    end
  end

  defp require_select_type(%{"type" => "select", "options" => values}, _id) when is_list(values), do: :ok

  defp require_select_type(other, id),
    do: {:error, {:unsupported_kimi_acp_shape, {:option_type, id, Map.get(other, "type")}}}

  defp require_option_category(option, id, category) do
    case Map.get(option, "category") do
      nil -> :ok
      ^category -> :ok
      other -> {:error, {:unsupported_kimi_acp_shape, {:option_category, id, other}}}
    end
  end

  defp require_option_value(option, value, error) do
    if Enum.any?(option["options"], &(&1["value"] == value)), do: :ok, else: {:error, error}
  end

  defp set_config_option(client, session_id, config_id, value) do
    params = %{"sessionId" => session_id, "configId" => config_id, "value" => value}

    case await(ACPClient.request_async(client, "session/set_config_option", params, @request_timeout_ms)) do
      {:ok, %{"configOptions" => options}} when is_list(options) -> {:ok, options}
      {:ok, other} -> {:error, {:unsupported_kimi_acp_shape, {:set_config_option, other}}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ------------------------------------------------------------------
  # Catalog probing
  # ------------------------------------------------------------------

  @doc """
  Learn the available `(model, effort)` options of a Kimi backend by opening a
  scratch ACP session and reading the complete config-option state returned
  after setting each candidate model. `models` restricts the probe to the
  given policy models; an empty list probes every advertised model.
  """
  @spec catalog_options(Path.t(), keyword()) :: {:ok, [{String.t(), String.t() | nil}]} | {:error, term()}
  def catalog_options(workspace, opts) do
    backend = Keyword.fetch!(opts, :backend)
    models = Keyword.get(opts, :models, [])
    backend_config = Config.backend!(backend)

    with {:ok, workspace} <- WorkspaceSafety.validate_catalog_cwd(workspace, Config.bundle!().project.id),
         :ok <- File.mkdir_p(workspace) do
      client_opts = [
        command: backend_config.command,
        cwd: workspace,
        environment: %{},
        subscriber: self()
      ]

      case ACPClient.start_link(client_opts) do
        {:ok, client} ->
          try do
            with {:ok, hello} <- initialize(client),
                 :ok <- maybe_authenticate(client, hello),
                 {:ok, session_id, config_options} <- catalog_session_new(client, workspace) do
              learn_catalog_options(client, session_id, config_options, models)
            end
          after
            ACPClient.stop(client)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp catalog_session_new(client, workspace) do
    params = %{"cwd" => workspace, "mcpServers" => []}

    case await(ACPClient.request_async(client, "session/new", params, @handshake_timeout_ms)) do
      {:ok, %{"sessionId" => session_id} = result} when is_binary(session_id) ->
        {:ok, session_id, Map.get(result, "configOptions", [])}

      {:ok, other} ->
        {:error, {:unsupported_kimi_acp_shape, {:session_new, other}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp learn_catalog_options(client, session_id, config_options, models) do
    with {:ok, model_option} <- fetch_required_option(config_options, "model", "model") do
      probe_catalog_models(client, session_id, model_option, models)
    end
  end

  defp probe_catalog_models(client, session_id, model_option, models) do
    advertised = Enum.map(model_option["options"], & &1["value"])
    candidates = if models == [], do: advertised, else: Enum.filter(models, &(&1 in advertised))

    Enum.reduce_while(candidates, {:ok, []}, fn model, {:ok, acc} ->
      case probe_catalog_model(client, session_id, model_option["id"], model) do
        {:ok, tuples} -> {:cont, {:ok, tuples ++ acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp probe_catalog_model(client, session_id, config_id, model) do
    case set_config_option(client, session_id, config_id, model) do
      {:ok, options} ->
        case thinking_values(options) do
          [] -> {:ok, [{model, nil}]}
          efforts -> {:ok, Enum.map(efforts, &{model, &1})}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp thinking_values(options) do
    case Enum.find(options, &(&1["id"] == "thinking")) do
      %{"options" => values} when is_list(values) -> Enum.map(values, & &1["value"])
      _ -> []
    end
  end

  # ------------------------------------------------------------------
  # Prompt turn
  # ------------------------------------------------------------------

  defp await_prompt(session, ref, turn_id, on_message) do
    receive do
      {:acp_response, ^ref, {:ok, %{"stopReason" => stop_reason}}} ->
        finish_turn(session, stop_reason, turn_id, on_message)

      {:acp_response, ^ref, {:ok, other}} ->
        {:error, {:unsupported_kimi_acp_shape, {:prompt_result, other}}}

      {:acp_response, ^ref, {:error, reason}} ->
        {:error, reason}

      {:acp_notification, "session/update", params, raw} ->
        handle_session_update(params, raw, on_message)
        await_prompt(session, ref, turn_id, on_message)

      {:acp_notification, method, params, raw} ->
        emit_message(on_message, :notification, %{payload: %{"method" => method, "params" => params}, raw: raw})
        await_prompt(session, ref, turn_id, on_message)

      {:acp_request, id, "session/request_permission", params, raw} ->
        outcome = answer_permission(session.client, id, params)
        emit_message(on_message, :approval_auto_approved, %{payload: params, raw: raw, outcome: outcome})
        await_prompt(session, ref, turn_id, on_message)

      {:acp_request, id, method, _params, raw} ->
        ACPClient.respond_error(session.client, id, -32_601, "Method not found")
        emit_message(on_message, :other_message, %{payload: %{"method" => method}, raw: raw})
        await_prompt(session, ref, turn_id, on_message)

      {:acp_malformed, line} ->
        Logger.warning("malformed kimi acp output: #{String.slice(line, 0, 200)}")
        emit_message(on_message, :malformed, %{raw: line})
        await_prompt(session, ref, turn_id, on_message)

      {:acp_exit, reason} ->
        {:error, reason}
    end
  end

  defp finish_turn(session, stop_reason, turn_id, on_message) do
    case stop_reason do
      "end_turn" ->
        emit_message(on_message, :turn_completed, %{stop_reason: "end_turn"})
        {:ok, %{session: session, stop_reason: :end_turn, turn_id: turn_id}}

      "max_tokens" ->
        emit_message(on_message, :turn_completed, %{stop_reason: "max_tokens"})
        {:ok, %{session: session, stop_reason: :max_tokens, turn_id: turn_id}}

      "max_turn_requests" ->
        emit_message(on_message, :turn_completed, %{stop_reason: "max_turn_requests"})
        {:ok, %{session: session, stop_reason: :max_turn_requests, turn_id: turn_id}}

      "refusal" ->
        emit_message(on_message, :turn_failed, %{stop_reason: "refusal"})
        {:error, {:acp_refusal, session.session_id}}

      "cancelled" ->
        emit_message(on_message, :turn_cancelled, %{})
        {:error, :turn_cancelled}

      other ->
        emit_message(on_message, :turn_failed, %{stop_reason: other})
        {:error, {:acp_unknown_stop_reason, other}}
    end
  end

  defp handle_session_update(params, raw, on_message) do
    case params do
      %{"update" => %{"sessionUpdate" => _kind} = update} ->
        method = "kimi/#{update["sessionUpdate"]}"
        emit_message(on_message, :notification, %{payload: %{"method" => method, "params" => update}, raw: raw})

      _other ->
        emit_message(on_message, :other_message, %{payload: params, raw: raw})
    end
  end

  # Deterministic permission policy: prefer the first agent-supplied
  # allow_once option, then the first allow_always option, otherwise cancel.
  # Elicitation questions (no allow-kind options) are cancelled — no
  # free-text answer can be invented through this channel.
  defp answer_permission(client, id, params) do
    options = Map.get(params || %{}, "options", [])

    choice =
      Enum.find(options, &(&1["kind"] == "allow_once")) ||
        Enum.find(options, &(&1["kind"] == "allow_always"))

    outcome =
      case choice do
        %{"optionId" => option_id} -> %{"outcome" => "selected", "optionId" => option_id}
        _ -> %{"outcome" => "cancelled"}
      end

    :ok = ACPClient.respond(client, id, %{"outcome" => outcome})
    outcome
  end

  # ------------------------------------------------------------------
  # Shared helpers
  # ------------------------------------------------------------------

  defp await({:ok, ref}) do
    receive do
      {:acp_response, ^ref, result} -> result
    end
  end

  defp await({:error, reason}), do: {:error, reason}

  defp stderr_log_path(run_id) do
    bundle = Config.bundle!()
    Path.join([Paths.runtime_root(bundle.project.id), "acp", "#{run_id}.stderr.log"])
  end

  defp log_stderr_tail(stderr_log, reason) do
    case File.read(stderr_log) do
      {:ok, content} when content != "" ->
        tail = content |> String.trim() |> String.slice(-500..-1//1)
        Logger.warning("kimi acp startup failed reason=#{inspect(reason)} stderr_tail=#{tail}")

      _ ->
        Logger.warning("kimi acp startup failed reason=#{inspect(reason)}")
    end
  end

  defp default_on_message(_message), do: :ok

  defp emit_message(on_message, event, details) when is_function(on_message, 1) do
    message =
      details
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end
end
