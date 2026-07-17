defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger
  alias SymphonyElixir.{Codex.DynamicTool, Config, PathSafety, SSH}

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @model_list_id 4
  @thread_resume_id 5
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @non_interactive_tool_input_answer "This is a non-interactive session. Operator input is unavailable."

  @type session :: %{
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          effort: String.t() | nil,
          model: String.t() | nil,
          thread_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          environment: %{optional(String.t()) => String.t()},
          dynamic_tool_specs: [map()]
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, task, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        case run_turn(session, prompt, task, opts) do
          {:ok, %{session: active_session} = turn_result} ->
            if active_session.port != session.port, do: stop_session(active_session)
            {:ok, Map.delete(turn_result, :session)}

          other ->
            other
        end
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    model = Keyword.get(opts, :model)
    effort = Keyword.get(opts, :effort)
    environment = Keyword.get(opts, :environment, %{})
    dynamic_tool_specs = Keyword.get(opts, :dynamic_tool_specs, DynamicTool.tool_specs())

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, port} <- start_port(expanded_workspace, worker_host, environment) do
      metadata = port_metadata(port, worker_host)

      with {:ok, session_policies} <- session_policies(expanded_workspace, worker_host),
           {:ok, thread_id} <-
             do_start_session(port, expanded_workspace, session_policies, model, dynamic_tool_specs) do
        {:ok,
         %{
           port: port,
           metadata: metadata,
           approval_policy: session_policies.approval_policy,
           auto_approve_requests: session_policies.approval_policy == "never",
           thread_sandbox: session_policies.thread_sandbox,
           turn_sandbox_policy: session_policies.turn_sandbox_policy,
           effort: effort,
           model: model,
           thread_id: thread_id,
           workspace: expanded_workspace,
           worker_host: worker_host,
           environment: environment,
           dynamic_tool_specs: dynamic_tool_specs
         }}
      else
        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @spec catalog(Path.t()) :: {:ok, [map()]} | {:error, term()}
  def catalog(workspace) when is_binary(workspace) do
    :ok = File.mkdir_p(workspace)

    with {:ok, expanded_workspace} <- validate_catalog_cwd(workspace),
         {:ok, port} <- start_port(expanded_workspace, nil, %{}) do
      try do
        with :ok <- send_initialize(port),
             {:ok, models} <- list_models(port),
             :ok <- validate_model_entries(models) do
          {:ok, models}
        end
      after
        stop_port(port)
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          approval_policy: approval_policy,
          turn_sandbox_policy: turn_sandbox_policy,
          effort: effort,
          thread_id: thread_id,
          workspace: workspace
        } = session,
        prompt,
        task,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    on_session_reconnected = Keyword.get(opts, :on_session_reconnected, fn _session -> :ok end)
    dynamic_tool_opts = Keyword.get(opts, :dynamic_tool_opts, [])

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments, call_metadata ->
        tool_opts = Keyword.put(dynamic_tool_opts, :call_id, to_string(call_metadata.call_id))
        DynamicTool.execute(tool, arguments, tool_opts)
      end)

    case start_turn(port, thread_id, prompt, task, workspace, approval_policy, turn_sandbox_policy, effort) do
      {:ok, turn_id} ->
        finish_started_turn(session, turn_id, task, on_message, tool_executor, on_session_reconnected)

      {:error, reason} ->
        Logger.error("Codex session failed for #{task_context(task)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  defp finish_started_turn(session, turn_id, task, on_message, tool_executor, on_session_reconnected) do
    %{thread_id: thread_id, effort: effort, model: model, metadata: metadata} = session
    session_id = "#{thread_id}-#{turn_id}"

    Logger.info(
      "Codex session started for #{task_context(task)} session_id=#{session_id} " <>
        "model=#{model_for_log(model)} effort=#{effort_for_log(effort)}"
    )

    emit_message(
      on_message,
      :session_started,
      %{session_id: session_id, thread_id: thread_id, turn_id: turn_id, effort: effort, model: model},
      metadata
    )

    case await_turn_with_reconnect(
           session,
           thread_id,
           turn_id,
           on_message,
           tool_executor,
           session.auto_approve_requests,
           on_session_reconnected
         ) do
      {:ok, result, active_session} ->
        Logger.info("Codex session completed for #{task_context(task)} session_id=#{session_id}")

        {:ok,
         %{
           result: result,
           session_id: session_id,
           thread_id: thread_id,
           turn_id: turn_id,
           effort: effort,
           model: model,
           session: active_session
         }}

      {:error, reason, active_session} ->
        if active_session.port != session.port, do: stop_session(active_session)

        Logger.warning("Codex session ended with error for #{task_context(task)} session_id=#{session_id}: #{inspect(reason)}")

        emit_message(on_message, :turn_ended_with_error, %{session_id: session_id, reason: reason}, metadata)
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp validate_catalog_cwd(workspace) do
    bundle = Config.bundle!()
    expanded = Path.expand(workspace)
    runtime_root = Path.expand(SymphonyElixir.Paths.runtime_root(bundle.project.id))

    with {:ok, canonical} <- PathSafety.canonicalize(expanded),
         {:ok, canonical_runtime_root} <- PathSafety.canonicalize(runtime_root),
         true <- String.starts_with?(canonical <> "/", canonical_runtime_root <> "/") do
      {:ok, canonical}
    else
      false -> {:error, {:invalid_catalog_cwd, expanded}}
      {:error, reason} -> {:error, {:invalid_catalog_cwd, reason}}
    end
  end

  defp start_port(workspace, nil, environment) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(Config.settings!().codex.command)],
            cd: String.to_charlist(workspace),
            env: port_environment(environment),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(workspace, worker_host, environment) when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace, environment)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp remote_launch_command(workspace, environment) when is_binary(workspace) do
    exports =
      environment
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{shell_escape(value)}" end)

    launch =
      if exports == "",
        do: "exec #{Config.settings!().codex.command}",
        else: "exec env #{exports} #{Config.settings!().codex.command}"

    [
      "cd #{shell_escape(workspace)}",
      launch
    ]
    |> Enum.join(" && ")
  end

  defp port_environment(environment) do
    Enum.map(environment, fn {key, value} ->
      {String.to_charlist(key), String.to_charlist(value)}
    end)
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp send_initialize(port) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp session_policies(workspace, nil) do
    Config.codex_runtime_settings(workspace)
  end

  defp session_policies(workspace, worker_host) when is_binary(worker_host) do
    Config.codex_runtime_settings(workspace, remote: true)
  end

  defp do_start_session(port, workspace, session_policies, model, dynamic_tool_specs) do
    with :ok <- send_initialize(port),
         :ok <- validate_model(port, model) do
      start_thread(port, workspace, session_policies, model, dynamic_tool_specs)
    end
  end

  defp validate_model(_port, nil), do: :ok

  defp validate_model(port, model) when is_binary(model) do
    with {:ok, models} <- list_models(port),
         :ok <- validate_model_entries(models) do
      ensure_model_available(models, model)
    end
  end

  defp validate_model(_port, model), do: {:error, {:invalid_model, model}}

  defp validate_model_entries(models) do
    if Enum.all?(models, &valid_model_entry?/1),
      do: :ok,
      else: {:error, {:invalid_model_list_payload, models}}
  end

  defp ensure_model_available(models, model) do
    if Enum.any?(models, &(Map.get(&1, "model") == model)),
      do: :ok,
      else: {:error, {:model_unavailable, model}}
  end

  defp valid_model_entry?(%{"model" => model}) when is_binary(model) and model != "", do: true
  defp valid_model_entry?(_entry), do: false

  defp list_models(port), do: list_models(port, nil, [], [])

  defp list_models(port, cursor, seen_cursors, acc) do
    params = maybe_put_model_cursor(%{"includeHidden" => true}, cursor)

    send_message(port, %{
      "method" => "model/list",
      "id" => @model_list_id,
      "params" => params
    })

    case await_response(port, @model_list_id) do
      {:ok, %{"data" => models, "nextCursor" => next_cursor}} when is_list(models) ->
        continue_model_list(port, next_cursor, seen_cursors, acc ++ models)

      {:ok, %{"data" => models}} when is_list(models) ->
        {:ok, acc ++ models}

      {:ok, payload} ->
        {:error, {:invalid_model_list_payload, payload}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp continue_model_list(_port, nil, _seen_cursors, models), do: {:ok, models}

  defp continue_model_list(port, next_cursor, seen_cursors, models)
       when is_binary(next_cursor) and next_cursor != "" do
    if next_cursor in seen_cursors do
      {:error, {:invalid_model_list_pagination, next_cursor}}
    else
      list_models(port, next_cursor, [next_cursor | seen_cursors], models)
    end
  end

  defp continue_model_list(_port, next_cursor, _seen_cursors, _models) do
    {:error, {:invalid_model_list_cursor, next_cursor}}
  end

  defp maybe_put_model_cursor(params, nil), do: params
  defp maybe_put_model_cursor(params, cursor), do: Map.put(params, "cursor", cursor)

  defp start_thread(
         port,
         workspace,
         %{approval_policy: approval_policy, thread_sandbox: thread_sandbox},
         model,
         dynamic_tool_specs
       ) do
    params =
      %{
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "cwd" => workspace,
        "dynamicTools" => dynamic_tool_specs
      }
      |> maybe_put_model(model)

    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => params
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => thread_payload}} ->
        case thread_payload do
          %{"id" => thread_id} -> {:ok, thread_id}
          _ -> {:error, {:invalid_thread_payload, thread_payload}}
        end

      other ->
        other
    end
  end

  defp resume_thread(port, thread_id) do
    send_message(port, %{
      "method" => "thread/resume",
      "id" => @thread_resume_id,
      "params" => %{"threadId" => thread_id}
    })

    case await_response(port, @thread_resume_id) do
      {:ok, %{"thread" => %{"id" => ^thread_id} = thread}} ->
        {:ok, thread}

      {:ok, %{"thread" => thread}} ->
        {:error, {:resumed_thread_mismatch, thread_id, thread}}

      {:ok, payload} ->
        {:error, {:invalid_thread_resume_payload, payload}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_model(params, nil), do: params
  defp maybe_put_model(params, model), do: Map.put(params, "model", model)

  defp start_turn(
         port,
         thread_id,
         prompt,
         task,
         workspace,
         approval_policy,
         turn_sandbox_policy,
         effort
       ) do
    params =
      %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ],
        "cwd" => workspace,
        "title" => "#{task.identifier}: #{task.title}",
        "approvalPolicy" => approval_policy,
        "sandboxPolicy" => turn_sandbox_policy
      }
      |> maybe_put_effort(effort)

    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => params
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp maybe_put_effort(params, nil), do: params
  defp maybe_put_effort(params, effort), do: Map.put(params, "effort", effort)

  defp await_turn_completion(
         port,
         thread_id,
         turn_id,
         on_message,
         tool_executor,
         auto_approve_requests
       ) do
    context = %{
      thread_id: thread_id,
      turn_id: turn_id,
      on_message: on_message,
      tool_executor: tool_executor,
      auto_approve_requests: auto_approve_requests,
      last_error_notification: nil
    }

    receive_loop(port, "", context)
  end

  defp await_turn_with_reconnect(
         session,
         thread_id,
         turn_id,
         on_message,
         tool_executor,
         auto_approve_requests,
         on_session_reconnected
       ) do
    case await_turn_completion(
           session.port,
           thread_id,
           turn_id,
           on_message,
           tool_executor,
           auto_approve_requests
         ) do
      {:ok, result} ->
        {:ok, result, session}

      {:error, reason} ->
        reconnect_turn(
          session,
          thread_id,
          turn_id,
          reason,
          on_message,
          tool_executor,
          auto_approve_requests,
          on_session_reconnected
        )
    end
  end

  defp reconnect_turn(
         session,
         thread_id,
         turn_id,
         reason,
         on_message,
         tool_executor,
         auto_approve_requests,
         on_session_reconnected
       ) do
    if reconnectable_transport_error?(reason) do
      resume_reconnect(
        session,
        thread_id,
        turn_id,
        reason,
        on_message,
        tool_executor,
        auto_approve_requests,
        on_session_reconnected
      )
    else
      {:error, reason, session}
    end
  end

  defp resume_reconnect(
         session,
         thread_id,
         turn_id,
         reason,
         on_message,
         tool_executor,
         auto_approve_requests,
         on_session_reconnected
       ) do
    case resume_session(session) do
      {:ok, resumed_session, thread} ->
        finish_reconnect(
          session,
          resumed_session,
          thread,
          %{
            thread_id: thread_id,
            turn_id: turn_id,
            on_message: on_message,
            tool_executor: tool_executor,
            auto_approve_requests: auto_approve_requests,
            on_session_reconnected: on_session_reconnected
          }
        )

      {:error, reconnect_reason} ->
        {:error, {:app_server_reconnect_failed, reason, reconnect_reason}, session}
    end
  end

  defp finish_reconnect(original_session, resumed_session, thread, continuation) do
    case notify_session_reconnected(continuation.on_session_reconnected, resumed_session) do
      :ok ->
        continue_resumed_turn(
          resumed_session,
          thread,
          continuation.thread_id,
          continuation.turn_id,
          continuation.on_message,
          continuation.tool_executor,
          continuation.auto_approve_requests,
          continuation.on_session_reconnected
        )

      {:error, callback_reason} ->
        stop_session(resumed_session)
        {:error, {:app_server_reconnect_callback_failed, callback_reason}, original_session}
    end
  end

  defp continue_resumed_turn(
         resumed_session,
         thread,
         thread_id,
         turn_id,
         on_message,
         tool_executor,
         auto_approve_requests,
         on_session_reconnected
       ) do
    case resumed_turn_result(thread, turn_id) do
      {:terminal, {:ok, result}} ->
        {:ok, result, resumed_session}

      {:terminal, {:error, reason}} ->
        {:error, reason, resumed_session}

      :active ->
        await_turn_with_reconnect(
          resumed_session,
          thread_id,
          turn_id,
          on_message,
          tool_executor,
          auto_approve_requests,
          on_session_reconnected
        )
    end
  end

  defp resume_session(session) do
    stop_port(session.port)

    with {:ok, port} <- start_port(session.workspace, session.worker_host, session.environment) do
      result =
        try do
          with :ok <- send_initialize(port),
               {:ok, thread} <- resume_thread(port, session.thread_id) do
            {:ok, %{session | port: port, metadata: port_metadata(port, session.worker_host)}, thread}
          end
        rescue
          error -> {:error, {:app_server_resume_exception, Exception.message(error)}}
        end

      case result do
        {:ok, _session, _thread} = success ->
          success

        {:error, _reason} = error ->
          stop_port(port)
          error
      end
    end
  end

  defp notify_session_reconnected(callback, session) when is_function(callback, 1) do
    case callback.(session) do
      :ok -> :ok
      other -> {:error, other}
    end
  rescue
    error -> {:error, {:callback_exception, Exception.message(error)}}
  end

  defp resumed_turn_result(%{"turns" => turns}, turn_id) when is_list(turns) do
    case Enum.find(turns, &(Map.get(&1, "id") == turn_id)) do
      %{"status" => "completed"} ->
        {:terminal, {:ok, :turn_completed}}

      %{"status" => "failed"} = turn ->
        {:terminal, {:error, {:turn_failed, Map.get(turn, "error")}}}

      %{"status" => status} = turn when status in ["interrupted", "cancelled"] ->
        {:terminal, {:error, {:turn_interrupted, turn}}}

      _ ->
        :active
    end
  end

  defp resumed_turn_result(_thread, _turn_id), do: :active

  defp reconnectable_transport_error?({:port_exit, _status}), do: true
  defp reconnectable_transport_error?(:port_closed), do: true
  defp reconnectable_transport_error?({:tool_result_delivery_failed, _call_id, _reason}), do: true
  defp reconnectable_transport_error?(_reason), do: false

  defp receive_loop(port, pending_line, context) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_incoming(port, complete_line, context)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(port, pending_line <> to_string(chunk), context)

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}

      {^port, :closed} ->
        {:error, :port_closed}
    end
  end

  defp handle_incoming(port, data, context) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, payload} ->
        handle_decoded_incoming(port, payload, payload_string, context)

      {:error, _reason} ->
        handle_non_json_incoming(port, payload_string, context)
    end
  end

  defp handle_decoded_incoming(
         port,
         %{
           "method" => "turn/completed",
           "params" => %{"turn" => %{"status" => status} = turn}
         } = payload,
         payload_string,
         %{on_message: on_message, last_error_notification: last_error_notification}
       ) do
    handle_turn_completed(
      on_message,
      payload,
      payload_string,
      port,
      turn,
      status,
      last_error_notification
    )
  end

  defp handle_decoded_incoming(
         port,
         %{"method" => "turn/completed"} = payload,
         payload_string,
         %{on_message: on_message}
       ) do
    handle_legacy_or_invalid_turn_completed(on_message, payload, payload_string, port)
  end

  defp handle_decoded_incoming(
         port,
         %{"method" => "error", "params" => params} = payload,
         payload_string,
         %{on_message: on_message} = context
       )
       when is_map(params) do
    emit_turn_error(on_message, payload, payload_string, port, params)

    context =
      if error_notification_for_active_turn?(params, context) do
        %{context | last_error_notification: params}
      else
        context
      end

    continue_receiving(port, context)
  end

  defp handle_decoded_incoming(
         port,
         %{"method" => "turn/failed", "params" => params} = payload,
         payload_string,
         %{on_message: on_message}
       ) do
    emit_turn_event(on_message, :turn_failed, payload, payload_string, port, params)
    {:error, {:turn_failed, params}}
  end

  defp handle_decoded_incoming(
         port,
         %{"method" => "turn/cancelled", "params" => params} = payload,
         payload_string,
         %{on_message: on_message}
       ) do
    emit_turn_event(on_message, :turn_cancelled, payload, payload_string, port, params)
    {:error, {:turn_cancelled, params}}
  end

  defp handle_decoded_incoming(
         port,
         %{"method" => method} = payload,
         payload_string,
         context
       )
       when is_binary(method) do
    handle_turn_method(port, payload, payload_string, method, context)
  end

  defp handle_decoded_incoming(port, payload, payload_string, %{on_message: on_message} = context) do
    emit_message(
      on_message,
      :other_message,
      %{
        payload: payload,
        raw: payload_string
      },
      metadata_from_message(port, payload)
    )

    continue_receiving(port, context)
  end

  defp handle_non_json_incoming(port, payload_string, %{on_message: on_message} = context) do
    log_non_json_stream_line(payload_string, "turn stream")

    if protocol_message_candidate?(payload_string) do
      emit_message(
        on_message,
        :malformed,
        %{
          payload: payload_string,
          raw: payload_string
        },
        metadata_from_message(port, %{raw: payload_string})
      )
    end

    continue_receiving(port, context)
  end

  defp continue_receiving(port, context), do: receive_loop(port, "", context)

  defp error_notification_for_active_turn?(params, context) do
    Map.get(params, "threadId") == context.thread_id and Map.get(params, "turnId") == context.turn_id
  end

  defp handle_turn_completed(
         on_message,
         payload,
         payload_string,
         port,
         turn,
         "completed",
         _last_error_notification
       ) do
    emit_turn_event(on_message, :turn_completed, payload, payload_string, port, turn)
    {:ok, :turn_completed}
  end

  defp handle_turn_completed(
         on_message,
         payload,
         payload_string,
         port,
         turn,
         "failed",
         last_error_notification
       ) do
    turn_error = Map.get(turn, "error") || notification_error(last_error_notification)
    emit_turn_event(on_message, :turn_failed, payload, payload_string, port, turn)
    {:error, {:turn_failed, turn_error}}
  end

  defp handle_turn_completed(
         on_message,
         payload,
         payload_string,
         port,
         turn,
         "interrupted",
         _last_error_notification
       ) do
    emit_turn_event(on_message, :turn_interrupted, payload, payload_string, port, turn)
    {:error, {:turn_interrupted, turn}}
  end

  defp handle_turn_completed(
         on_message,
         payload,
         payload_string,
         port,
         turn,
         status,
         _last_error_notification
       ) do
    emit_turn_event(on_message, :turn_protocol_error, payload, payload_string, port, turn)
    {:error, {:invalid_turn_status, status}}
  end

  defp handle_legacy_or_invalid_turn_completed(on_message, payload, payload_string, port) do
    if Map.has_key?(payload, "params") do
      emit_turn_event(on_message, :turn_protocol_error, payload, payload_string, port, payload["params"])
      {:error, {:invalid_turn_status, nil}}
    else
      emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)
      {:ok, :turn_completed}
    end
  end

  defp emit_turn_error(on_message, payload, payload_string, port, params) do
    emit_message(
      on_message,
      :turn_error,
      %{
        payload: payload,
        raw: payload_string,
        details: params,
        error: Map.get(params, "error"),
        will_retry: Map.get(params, "willRetry"),
        thread_id: Map.get(params, "threadId"),
        turn_id: Map.get(params, "turnId")
      },
      metadata_from_message(port, payload)
    )
  end

  defp notification_error(params) when is_map(params), do: Map.get(params, "error")
  defp notification_error(_params), do: nil

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(
         port,
         payload,
         payload_string,
         method,
         %{
           on_message: on_message,
           tool_executor: tool_executor,
           auto_approve_requests: auto_approve_requests
         } = context
       ) do
    metadata = metadata_from_message(port, payload)

    case maybe_handle_approval_request(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           tool_executor,
           auto_approve_requests
         ) do
      :input_required ->
        emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        continue_receiving(port, context)

      {:transport_lost, reason} ->
        {:error, reason}

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        if needs_input?(method, payload) do
          emit_message(
            on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}
        else
          emit_message(
            on_message,
            :notification,
            %{
              payload: payload,
              raw: payload_string
            },
            metadata
          )

          Logger.debug("Codex notification: #{inspect(method)}")
          continue_receiving(port, context)
        end
    end
  end

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    call_metadata = %{call_id: id, method: "item/tool/call", params: params}

    result =
      tool_executor
      |> execute_dynamic_tool(tool_name, arguments, call_metadata)
      |> normalize_dynamic_tool_result()

    case deliver_message(port, %{"id" => id, "result" => result}) do
      :ok ->
        event =
          case result do
            %{"success" => true} -> :tool_call_completed
            _ when is_nil(tool_name) -> :unsupported_tool_call
            _ -> :tool_call_failed
          end

        emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)
        :approved

      {:error, reason} ->
        {:transport_lost, {:tool_result_delivery_failed, id, reason}}
    end
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp execute_dynamic_tool(executor, tool_name, arguments, metadata) when is_function(executor, 3) do
    executor.(tool_name, arguments, metadata)
  end

  defp execute_dynamic_tool(executor, tool_name, arguments, _metadata) when is_function(executor, 2) do
    executor.(tool_name, arguments)
  end

  defp normalize_dynamic_tool_result(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) -> existing_items
        _ -> dynamic_tool_content_items(output)
      end

    result
    |> Map.put("output", output)
    |> Map.put("contentItems", content_items)
  end

  defp normalize_dynamic_tool_result(result) do
    %{
      "success" => false,
      "output" => inspect(result),
      "contentItems" => dynamic_tool_content_items(inspect(result))
    }
  end

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text), do: text
  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ) do
    :approval_required
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        reply_with_non_interactive_tool_input_answer(
          port,
          id,
          params,
          payload,
          payload_string,
          on_message,
          metadata
        )
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         false
       ) do
    reply_with_non_interactive_tool_input_answer(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata
    )
  end

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp reply_with_non_interactive_tool_input_answer(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata
       ) do
    case tool_request_user_input_unavailable_answers(params) do
      {:ok, answers} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :tool_input_auto_answered,
          %{payload: payload, raw: payload_string, answer: @non_interactive_tool_input_answer},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp tool_request_user_input_unavailable_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_question_id(question) do
          {:ok, question_id} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [@non_interactive_tool_input_answer]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map}
      _ -> :error
    end
  end

  defp tool_request_user_input_unavailable_answers(_params), do: :error

  defp tool_request_user_input_question_id(%{"id" => question_id}) when is_binary(question_id),
    do: {:ok, question_id}

  defp tool_request_user_input_question_id(_question), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    case tool_request_user_input_approval_option_label(options) do
      nil -> :error
      answer_label -> {:ok, question_id, answer_label}
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
  end

  defp await_response(port, request_id) do
    await_matching_response(port, request_id, "")
  end

  defp await_matching_response(port, request_id, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line)

      {^port, {:data, {:noeol, chunk}}} ->
        await_matching_response(port, request_id, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}

      {^port, :closed} ->
        {:error, :port_closed}
    end
  end

  defp handle_response(port, request_id, data) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        await_matching_response(port, request_id, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        await_matching_response(port, request_id, "")
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp task_context(%{id: task_id, identifier: identifier}) do
    "task_id=#{task_id} task_identifier=#{identifier}"
  end

  defp model_for_log(nil), do: "default"
  defp model_for_log(model), do: model

  defp effort_for_log(nil), do: "default"
  defp effort_for_log(effort), do: effort

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata(nil) |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp deliver_message(port, message) do
    send_message(port, message)
    :ok
  rescue
    ArgumentError -> {:error, :port_closed}
  end

  defp needs_input?("mcpServer/elicitation/request", payload) when is_map(payload), do: true

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
