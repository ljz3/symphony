defmodule SymphonyElixir.CLI.StartupError do
  @moduledoc false

  alias SymphonyElixir.Repo.StartupError, as: DatabaseStartupError

  @file_reasons [
    :eacces,
    :eagain,
    :ebusy,
    :eexist,
    :eio,
    :eisdir,
    :eloop,
    :emfile,
    :enfile,
    :enoent,
    :enomem,
    :enospc,
    :enotdir,
    :enotempty,
    :eperm,
    :erofs
  ]

  @workflow_error_tags [
    :invalid_boolean,
    :invalid_column_role,
    :invalid_efforts,
    :invalid_id,
    :invalid_model,
    :invalid_non_negative_integer,
    :invalid_positive_integer,
    :invalid_stage,
    :invalid_string,
    :invalid_string_list,
    :missing_model_policy,
    :missing_string,
    :missing_workflow_file,
    :source_git_root_unavailable,
    :template_parse_error,
    :template_read_failed,
    :unknown_workflow_keys,
    :workflow_parse_error
  ]

  @component_labels %{
    SymphonyElixir.Board.Lease => "Project lease",
    SymphonyElixir.Board.Storage => "Board projection storage",
    SymphonyElixir.Board.Sync => "Board history sync",
    SymphonyElixir.Board.WorkpadStore => "Workpad store",
    SymphonyElixir.Board.Writer => "Board event writer",
    SymphonyElixir.Codex.Catalog => "Codex model catalog",
    SymphonyElixir.HttpServer => "HTTP server",
    SymphonyElixir.MCP.Transport => "MCP transport",
    SymphonyElixir.Orchestrator => "Orchestrator",
    SymphonyElixir.Repo => "SQLite database",
    SymphonyElixir.Workflow.Store => "Workflow loader",
    SymphonyElixirWeb.Endpoint => "HTTP endpoint"
  }

  @type listener_info :: %{optional(:command) => String.t(), optional(:pid) => pos_integer()}

  @spec format(Path.t(), term(), keyword()) :: String.t()
  def format(workflow_path, reason, opts \\ []) when is_binary(workflow_path) do
    failure = decompose(reason, [])
    description = describe(failure.reason, opts)

    components =
      failure.components
      |> Enum.map(&component_label/1)
      |> then(&if(&1 == [] and description.component, do: [description.component], else: &1))
      |> Enum.dedup()

    [
      "Failed to start Symphony.",
      "",
      "Workflow: #{one_line(Path.expand(workflow_path))}",
      component_line(components),
      "Reason: #{sentence(description.summary)}",
      "Next: #{sentence(description.next)}",
      log_line(Keyword.get(opts, :log_file))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp decompose(
         {application, {failure, {module, :start, args}}},
         components
       )
       when is_atom(application) and is_atom(module) and is_list(args) do
    decompose(failure, components)
  end

  defp decompose({:symphony_elixir, failure}, components), do: decompose(failure, components)
  defp decompose({:shutdown, failure}, components), do: decompose(failure, components)
  defp decompose({:EXIT, failure}, components), do: decompose(failure, components)

  defp decompose({:bad_return, {{module, :start, args}, failure}}, components)
       when is_atom(module) and is_list(args) do
    decompose(failure, components)
  end

  defp decompose({:failed_to_start_child, child, failure}, components) do
    decompose(failure, components ++ [child])
  end

  defp decompose({%{__exception__: true} = exception, stacktrace}, components)
       when is_list(stacktrace) do
    %{components: components, reason: exception}
  end

  defp decompose(reason, components), do: %{components: components, reason: reason}

  defp describe(:eaddrinuse, opts) do
    port = Keyword.get(opts, :port)
    listener = Keyword.get(opts, :listener)

    description(
      port_conflict_summary(port, listener),
      port_conflict_next(port, listener)
    )
  end

  defp describe({:non_loopback_http_host, host}, _opts) do
    description(
      "The HTTP server refused non-loopback address #{inspect(host)}",
      "Bind Symphony to 127.0.0.1 or ::1; remote HTTP exposure is intentionally unsupported"
    )
  end

  defp describe({:workflow_identity_unavailable, workflow_error, identity_error}, _opts) do
    details =
      [workflow_error, identity_error]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&workflow_error_summary/1)
      |> Enum.uniq()
      |> Enum.join("; ")

    description(
      "WORKFLOW.yml does not provide a usable project identity: #{details}",
      "Fix `project.id` and `project.key` in WORKFLOW.yml, then restart Symphony"
    )
  end

  defp describe(%DatabaseStartupError{database: database, reason: reason}, _opts) do
    description(
      database_summary(database, reason),
      "Preserve the database, WAL, and SHM files; fix the reported access or storage problem, then retry"
    )
  end

  defp describe(%RuntimeError{message: "database startup aborted" <> _rest = message}, _opts) do
    description(
      one_line(message),
      "Preserve the database, WAL, and SHM files; fix the reported access or storage problem, then retry"
    )
  end

  defp describe({:lease_acquire_failed, path, reason}, _opts) do
    description(
      "Could not acquire the project lease at #{path}: #{term_summary(reason)}",
      "Check the lease directory permissions; never remove an existing lease until its recorded owner is verified dead"
    )
  end

  defp describe({:malformed_workpad_sidecar, path, reason}, _opts) do
    description(
      "Workpad sidecar #{path} is invalid: #{term_summary(reason)}",
      "Repair or restore that sidecar; Symphony intentionally will not overwrite or discard it"
    )
  end

  defp describe({:malformed_publication_manifest, path, reason}, _opts) do
    description(
      "Workpad publication manifest #{path} is invalid: #{term_summary(reason)}",
      "Repair or restore that manifest; Symphony intentionally will not overwrite or discard it"
    )
  end

  defp describe({:projection_migration_failed, version, reason}, _opts) do
    description(
      "Board projection migration #{version} failed: #{term_summary(reason)}",
      "Preserve the SQLite database family and inspect the startup log before retrying"
    )
  end

  defp describe({:projection_rebuild_failed, reason}, _opts) do
    description(
      "The SQLite board projection could not be rebuilt: #{term_summary(reason)}",
      "Preserve the canonical history and SQLite database family, then inspect the startup log"
    )
  end

  defp describe({:mkdir_failed, path, reason}, _opts) do
    description(
      "Could not create required directory #{path}: #{term_summary(reason)}",
      "Create a writable parent directory or correct its permissions, then retry"
    )
  end

  defp describe({:native_dependency_preparation_failed, script_path, reason}, _opts) do
    description(
      native_dependency_summary(script_path, reason),
      "Rebuild the executable with `mix build`; if the cache is unwritable, correct its permissions and retry",
      "Embedded SQLite library"
    )
  end

  defp describe(reason, _opts) do
    if workflow_error?(reason) do
      description(
        "WORKFLOW.yml is invalid: #{workflow_error_summary(reason)}",
        "Fix the workflow or referenced template, then restart Symphony"
      )
    else
      description(
        "Unexpected startup failure: #{term_summary(reason)}",
        "Inspect the startup log for the complete report, correct the underlying problem, and retry"
      )
    end
  end

  defp description(summary, next, component \\ nil) do
    %{summary: summary, next: next, component: component}
  end

  defp port_conflict_summary(port, listener) do
    base =
      if is_integer(port),
        do: "Loopback port #{port} is already in use",
        else: "The requested loopback port is already in use"

    case listener do
      %{pid: pid, command: command} when is_integer(pid) and is_binary(command) ->
        "#{base} (listener: #{safe_command(command)}, PID #{pid})"

      %{pid: pid} when is_integer(pid) ->
        "#{base} (PID #{pid})"

      _other ->
        base
    end
  end

  defp port_conflict_next(port, %{pid: pid}) when is_integer(port) and is_integer(pid) do
    "If this is the existing Symphony instance, open http://127.0.0.1:#{port}/. " <>
      "Otherwise inspect PID #{pid} with `ps -p #{pid} -o command=`, stop it gracefully with " <>
      "`kill -TERM #{pid}`, or pass a different --port"
  end

  defp port_conflict_next(port, _listener) when is_integer(port) do
    "If Symphony is already running, open http://127.0.0.1:#{port}/. " <>
      "Otherwise identify and stop the listener, or pass a different --port"
  end

  defp port_conflict_next(_port, _listener) do
    "Identify and stop the existing listener, or pass a different --port"
  end

  defp database_summary(database, {:database_health_indeterminate, _path, reason}) do
    "SQLite database #{database} could not be verified safely: #{term_summary(reason)}"
  end

  defp database_summary(database, reason) do
    "SQLite startup failed for #{database}: #{term_summary(reason)}"
  end

  defp native_dependency_summary(script_path, :embedded_exqlite_nif_not_found) do
    "Executable #{script_path} does not contain the required Exqlite native library"
  end

  defp native_dependency_summary(script_path, reason) do
    "Could not prepare the embedded SQLite library from #{script_path}: #{term_summary(reason)}"
  end

  defp workflow_error?(reason)
       when reason in [
              :invalid_project_id,
              :invalid_project_identity,
              :invalid_project_key,
              :missing_project,
              :workflow_document_not_a_map
            ],
       do: true

  defp workflow_error?(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    elem(reason, 0) in @workflow_error_tags
  end

  defp workflow_error?(_reason), do: false

  defp workflow_error_summary({:missing_workflow_file, path, reason}) do
    "could not read #{path}: #{term_summary(reason)}"
  end

  defp workflow_error_summary({:workflow_parse_error, reason}) do
    "YAML parsing failed: #{term_summary(reason)}"
  end

  defp workflow_error_summary(:workflow_document_not_a_map),
    do: "the YAML document must contain a map at its root"

  defp workflow_error_summary(:missing_project), do: "the `project` map is missing"
  defp workflow_error_summary(:invalid_project_identity), do: "`project.id` or `project.key` is missing"
  defp workflow_error_summary(:invalid_project_id), do: "`project.id` has an invalid format"
  defp workflow_error_summary(:invalid_project_key), do: "`project.key` must be uppercase alphanumeric text"

  defp workflow_error_summary({:unknown_workflow_keys, context, keys}) do
    "unknown keys under #{term_summary(context)}: #{term_summary(keys)}"
  end

  defp workflow_error_summary({:template_read_failed, path, reason}) do
    "could not read template #{path}: #{term_summary(reason)}"
  end

  defp workflow_error_summary({:template_parse_error, path, reason}) do
    "template #{path} could not be parsed: #{term_summary(reason)}"
  end

  defp workflow_error_summary(reason), do: term_summary(reason)

  defp component_line([]), do: nil
  defp component_line(components), do: "Component: #{Enum.join(components, " → ")}"

  defp component_label({SymphonyElixirWeb.Endpoint, :http}), do: "HTTP endpoint"
  defp component_label(:listener), do: "TCP listener"

  defp component_label(component) when is_atom(component) do
    Map.get(@component_labels, component, inspect(component))
  end

  defp component_label(component), do: inspect_compact(component)

  defp log_line(path) when is_binary(path) and path != "", do: "Log: #{one_line(Path.expand(path))}"
  defp log_line(_path), do: nil

  defp term_summary(%{__exception__: true} = exception) do
    exception |> Exception.message() |> one_line() |> truncate()
  end

  defp term_summary(reason) when reason in @file_reasons do
    reason |> :file.format_error() |> IO.iodata_to_binary() |> one_line()
  end

  defp term_summary(reason) when is_atom(reason), do: humanize(reason)
  defp term_summary(reason) when is_binary(reason), do: reason |> one_line() |> truncate()
  defp term_summary(reason) when is_number(reason), do: to_string(reason)

  defp term_summary(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case Tuple.to_list(reason) do
      [tag | values] when is_atom(tag) ->
        details = Enum.map_join(values, ": ", &term_summary/1)
        if details == "", do: humanize(tag), else: "#{humanize(tag)}: #{details}"

      _values ->
        inspect_compact(reason)
    end
  end

  defp term_summary(reason) when is_list(reason) do
    rendered = reason |> Enum.take(6) |> Enum.map_join(", ", &term_summary/1)
    if length(reason) > 6, do: rendered <> ", …", else: rendered
  end

  defp term_summary(reason), do: inspect_compact(reason)

  defp humanize(reason) do
    reason
    |> Atom.to_string()
    |> String.replace("_", " ")
  end

  defp safe_command(command) do
    command
    |> Path.basename()
    |> one_line()
    |> truncate(80)
  end

  defp inspect_compact(value) do
    inspect(value, limit: 8, printable_limit: 240, pretty: false)
  end

  defp one_line(value) do
    value
    |> to_string()
    |> String.replace(~r/[\r\n\t]+/, " ")
    |> String.replace(~r/\s{2,}/, " ")
    |> String.trim()
  end

  defp truncate(value, max_length \\ 300) do
    if String.length(value) > max_length,
      do: String.slice(value, 0, max_length - 1) <> "…",
      else: value
  end

  defp sentence(value) do
    value = one_line(value)
    if String.ends_with?(value, [".", "!", "?"]), do: value, else: value <> "."
  end
end
