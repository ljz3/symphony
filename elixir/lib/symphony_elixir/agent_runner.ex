defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @codex_selection_assistance_state "Failed Need Assistance"

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(Issue.t(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    case Issue.codex_selection(issue) do
      {:ok, %{model: model, effort: effort} = selection} ->
        case Config.validate_codex_selection(selection) do
          :ok ->
            run_with_codex_selection(issue, model, effort, codex_update_recipient, opts)

          {:error, reasons} ->
            hand_off_or_fail_codex_selection(issue, reasons, opts)
        end

      {:error, reasons} ->
        hand_off_or_fail_codex_selection(issue, reasons, opts)
    end
  end

  defp hand_off_or_fail_codex_selection(issue, reasons, opts) do
    case hand_off_codex_selection_error(issue, reasons, opts) do
      :ok -> :ok
      {:error, handoff_reason} -> fail_agent_run(issue, handoff_reason)
    end
  end

  defp run_with_codex_selection(issue, model, effort, codex_update_recipient, opts) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)
    opts = opts |> Keyword.put(:codex_model, model) |> Keyword.put(:codex_effort, effort)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)} model=#{model_for_log(model)} effort=#{effort_for_log(effort)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok -> :ok
      {:error, reason} -> fail_agent_run(issue, reason)
    end
  end

  defp fail_agent_run(issue, reason) do
    Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
    raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    model = Keyword.get(opts, :codex_model)
    effort = Keyword.get(opts, :codex_effort)

    case AppServer.start_session(workspace, worker_host: worker_host, model: model, effort: effort) do
      {:ok, session} ->
        try do
          do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
        after
          AppServer.stop_session(session)
        end

      {:error, {:model_unavailable, ^model} = reason} ->
        hand_off_codex_selection_error(issue, reason, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp hand_off_codex_selection_error(%Issue{id: issue_id} = issue, reason, opts)
       when is_binary(issue_id) do
    comment = codex_selection_comment(reason)
    create_comment = Keyword.get(opts, :tracker_commenter, &Tracker.create_comment/2)
    update_issue_state = Keyword.get(opts, :tracker_state_updater, &Tracker.update_issue_state/2)

    with :ok <- create_comment.(issue_id, comment),
         :ok <- update_issue_state.(issue_id, @codex_selection_assistance_state) do
      Logger.warning("Codex selection failed for #{issue_context(issue)}; moved issue to #{@codex_selection_assistance_state}: #{inspect(reason)}")

      :ok
    else
      {:error, handoff_reason} ->
        {:error, {:codex_selection_handoff_failed, reason, handoff_reason}}

      handoff_result ->
        {:error, {:codex_selection_handoff_failed, reason, handoff_result}}
    end
  end

  defp hand_off_codex_selection_error(issue, reason, _opts) do
    {:error, {:codex_selection_handoff_failed, reason, {:invalid_issue_id, Map.get(issue, :id)}}}
  end

  defp codex_selection_comment(reason) do
    """
    Symphony could not start this task because one or more Codex selection labels are invalid.

    #{codex_selection_reason(reason)}

    Use at most one label of each form: `model:<model-id>` and `effort:<reasoning-effort>`. Label values must match the `codex.allowed_model_efforts` policy in `WORKFLOW.md` exactly. Remove either label to retain the matching setting from `codex.command` or normal Codex configuration.

    #{allowed_codex_model_efforts()}
    """
    |> String.trim()
  end

  defp codex_selection_reason(reasons) when is_list(reasons) do
    Enum.map_join(reasons, "\n", &codex_selection_reason/1)
  end

  defp codex_selection_reason({:empty_model_label, label}) do
    "The model label `#{escape_markdown_code(label)}` does not contain a model ID."
  end

  defp codex_selection_reason({:multiple_model_labels, labels}) do
    rendered_labels = Enum.map_join(labels, ", ", &"`#{escape_markdown_code(&1)}`")
    "The task has multiple model labels: #{rendered_labels}."
  end

  defp codex_selection_reason({:empty_effort_label, label}) do
    "The reasoning-effort label `#{escape_markdown_code(label)}` does not contain an effort value."
  end

  defp codex_selection_reason({:multiple_effort_labels, labels}) do
    rendered_labels = Enum.map_join(labels, ", ", &"`#{escape_markdown_code(&1)}`")
    "The task has multiple reasoning-effort labels: #{rendered_labels}."
  end

  defp codex_selection_reason({:model_unavailable, model}) do
    "The model label `model:#{escape_markdown_code(model)}` selects a model Codex did not report as available."
  end

  defp codex_selection_reason({:model_not_permitted, model}) do
    "The model label `model:#{escape_markdown_code(model)}` is not permitted by `codex.allowed_model_efforts`."
  end

  defp codex_selection_reason({:effort_not_permitted, effort}) do
    "The reasoning-effort label `effort:#{escape_markdown_code(effort)}` is not permitted by `codex.allowed_model_efforts`."
  end

  defp codex_selection_reason({:model_effort_not_permitted, model, effort}) do
    "The combination `model:#{escape_markdown_code(model)}` and `effort:#{escape_markdown_code(effort)}` is not permitted by `codex.allowed_model_efforts`."
  end

  defp allowed_codex_model_efforts do
    combinations =
      Config.allowed_codex_model_efforts()
      |> Enum.sort_by(fn {model, _efforts} -> model end)
      |> Enum.flat_map(fn {model, efforts} ->
        Enum.map(efforts, fn effort -> "- `model:#{escape_markdown_code(model)}` + `effort:#{escape_markdown_code(effort)}`" end)
      end)

    "Allowed combinations from `codex.allowed_model_efforts`:\n" <> Enum.join(combinations, "\n")
  end

  defp escape_markdown_code(value), do: value |> to_string() |> String.replace("`", "\\`")

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp model_for_log(nil), do: "default"
  defp model_for_log(model), do: model

  defp effort_for_log(nil), do: "default"
  defp effort_for_log(effort), do: effort

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
