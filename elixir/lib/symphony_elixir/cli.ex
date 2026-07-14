defmodule SymphonyElixir.CLI do
  @moduledoc "Escript entrypoint for the loopback Kanban service and board maintenance commands."

  alias SymphonyElixir.{Board, Config, LogFile, Paths, Workflow}
  alias SymphonyElixir.CLI.StartupError

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @exqlite_nif_entry_prefix "exqlite/priv/sqlite3_nif."
  @switches [
    {@acknowledgement_switch, :boolean},
    logs_root: :string,
    port: :integer,
    symphony_home: :string,
    worktrees_root: :string,
    take_local: :boolean,
    take_remote: :boolean
  ]

  @type command :: :run | :status | :checkpoint | :handoff | {:reconcile, :take_local | :take_remote}
  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type listener_info :: %{optional(:command) => String.t(), optional(:pid) => pos_integer()}
  @type deps :: %{
          required(:file_regular?) => (String.t() -> boolean()),
          required(:ensure_all_started) => (-> ensure_started_result()),
          optional(:listener_info) => (non_neg_integer() -> listener_info() | nil)
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        wait_for_shutdown()

      {:ok, result} ->
        IO.puts(Jason.encode!(json_safe(result), pretty: true))
        System.halt(0)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:ok, term()} | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    with {opts, positional, []} <- OptionParser.parse(args, strict: @switches),
         :ok <- require_guardrails_acknowledgement(opts),
         {:ok, command, workflow_path} <- parse_command(positional, opts),
         :ok <- apply_local_overrides(opts),
         :ok <- require_port(opts),
         :ok <- start(workflow_path, deps) do
      execute_command(command)
    else
      {_opts, _positional, _invalid} -> {:error, usage_message()}
      {:error, message} when is_binary(message) -> {:error, message}
    end
  end

  @spec usage_message() :: String.t()
  def usage_message do
    """
    Usage:
      symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails --port <port> [path-to-WORKFLOW.yml]
      symphony board status|checkpoint|handoff [options] [path-to-WORKFLOW.yml]
      symphony board reconcile --take-local|--take-remote [options] [path-to-WORKFLOW.yml]

    Machine-local options: --symphony-home, --worktrees-root, --logs-root, --port.
    SYMPHONY_PORT may be used instead of --port. The server always binds to loopback.
    """
    |> String.trim()
  end

  @spec acknowledgement_banner() :: String.t()
  def acknowledgement_banner do
    lines = [
      "This Symphony implementation is an engineering preview.",
      "Codex runs unattended with the configured project policy.",
      "SymphonyElixir is not a supported product and is presented as-is.",
      "Pass --i-understand-that-this-will-be-running-without-the-usual-guardrails to proceed."
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    body = Enum.map(lines, &"│ #{String.pad_trailing(&1, width)} │")

    [IO.ANSI.red(), IO.ANSI.bright(), Enum.join(["╭#{border}╮", "│ #{String.duplicate(" ", width)} │" | body] ++ ["│ #{String.duplicate(" ", width)} │", "╰#{border}╯"], "\n"), IO.ANSI.reset()]
    |> IO.iodata_to_binary()
  end

  @spec wait_for_shutdown() :: no_return()
  def wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        reference = Process.monitor(pid)

        receive do
          {:DOWN, ^reference, :process, ^pid, :normal} -> System.halt(0)
          {:DOWN, ^reference, :process, ^pid, _reason} -> System.halt(1)
        end
    end
  end

  defp parse_command(positional, opts) do
    {command, workflow_parts} =
      case positional do
        ["board", "status" | rest] -> {:status, rest}
        ["board", "checkpoint" | rest] -> {:checkpoint, rest}
        ["board", "handoff" | rest] -> {:handoff, rest}
        ["board", "reconcile" | rest] -> {reconcile_command(opts), rest}
        rest -> {:run, rest}
      end

    with command when not is_nil(command) <- command,
         {:ok, workflow_path} <- workflow_path(workflow_parts) do
      {:ok, command, workflow_path}
    else
      nil -> {:error, usage_message()}
      {:error, message} -> {:error, message}
    end
  end

  defp reconcile_command(opts) do
    case {Keyword.get(opts, :take_local, false), Keyword.get(opts, :take_remote, false)} do
      {true, false} -> {:reconcile, :take_local}
      {false, true} -> {:reconcile, :take_remote}
      _ -> nil
    end
  end

  defp workflow_path([]), do: {:ok, Path.expand("WORKFLOW.yml")}
  defp workflow_path([path]), do: {:ok, Path.expand(path)}
  defp workflow_path(_paths), do: {:error, usage_message()}

  defp apply_local_overrides(opts) do
    with :ok <- maybe_path_override(opts, :symphony_home),
         :ok <- maybe_path_override(opts, :worktrees_root),
         :ok <- maybe_logs_override(opts) do
      maybe_port_override(opts)
    end
  end

  defp maybe_path_override(opts, key) do
    case Keyword.get(opts, key) do
      nil -> :ok
      path when is_binary(path) and path != "" -> Paths.put_override(key, Path.expand(path))
      _ -> {:error, usage_message()}
    end
  end

  defp maybe_logs_override(opts) do
    case Keyword.get(opts, :logs_root) do
      nil ->
        :ok

      root when is_binary(root) and root != "" ->
        expanded = Path.expand(root)
        :ok = Paths.put_override(:logs_root, expanded)
        Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(expanded))
        :ok

      _ ->
        {:error, usage_message()}
    end
  end

  defp maybe_port_override(opts) do
    case Keyword.get(opts, :port) do
      nil ->
        :ok

      port when is_integer(port) and port >= 0 and port <= 65_535 ->
        Application.put_env(:symphony_elixir, :server_port_override, port)
        :ok

      _ ->
        {:error, usage_message()}
    end
  end

  defp require_port(_opts) do
    if is_integer(Config.server_port()),
      do: :ok,
      else: {:error, "A loopback port is required. Pass --port or set SYMPHONY_PORT.\n\n#{usage_message()}"}
  end

  defp start(path, deps) do
    if deps.file_regular?.(path) do
      :ok = Workflow.set_workflow_file_path(path)
      start_application(path, deps)
    else
      {:error, "Workflow file not found: #{path}"}
    end
  end

  defp start_application(path, deps) do
    case prepare_escript_native_dependencies() do
      :ok -> ensure_all_started(path, deps)
      {:error, reason} -> {:error, startup_error_message(path, reason, deps)}
    end
  end

  defp ensure_all_started(path, deps) do
    case deps.ensure_all_started.() do
      {:ok, _apps} -> :ok
      {:error, reason} -> {:error, startup_error_message(path, reason, deps)}
    end
  end

  defp startup_error_message(path, reason, deps) do
    port = Config.server_port()

    StartupError.format(path, reason,
      port: port,
      listener: listener_info(deps, port),
      log_file: startup_log_file()
    )
  end

  defp listener_info(deps, port) when is_integer(port) do
    case Map.get(deps, :listener_info) do
      listener_info when is_function(listener_info, 1) -> listener_info.(port)
      _missing -> nil
    end
  end

  defp listener_info(_deps, _port), do: nil

  defp startup_log_file do
    Application.get_env(:symphony_elixir, :log_file) || LogFile.default_log_file()
  end

  defp execute_command(:run), do: :ok
  defp execute_command(:status), do: {:ok, Board.state()}
  defp execute_command(:checkpoint), do: Board.checkpoint()
  defp execute_command(:handoff), do: Board.handoff()
  defp execute_command({:reconcile, strategy}), do: Board.reconcile(strategy)

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false),
      do: :ok,
      else: {:error, acknowledgement_banner()}
  end

  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end,
      listener_info: &runtime_listener_info/1
    }
  end

  defp runtime_listener_info(port) when is_integer(port) and port > 0 do
    with executable when is_binary(executable) <- System.find_executable("lsof"),
         {output, 0} <-
           System.cmd(
             executable,
             ["-nP", "-iTCP:#{port}", "-sTCP:LISTEN", "-Fpc"],
             stderr_to_stdout: true
           ),
         [_, pid, command] <- Regex.run(~r/(?:\A|\n)p(\d+)\nc([^\n]+)/, output),
         {pid, ""} <- Integer.parse(pid) do
      %{pid: pid, command: command}
    else
      _unavailable -> nil
    end
  rescue
    _error -> nil
  end

  defp runtime_listener_info(_port), do: nil

  defp prepare_escript_native_dependencies do
    script_path = :escript.script_name() |> List.to_string() |> Path.expand()

    if Path.basename(script_path) == "symphony" do
      case extract_exqlite_nif(script_path) do
        :ok -> :ok
        {:error, reason} -> {:error, {:native_dependency_preparation_failed, script_path, reason}}
      end
    else
      :ok
    end
  end

  defp extract_exqlite_nif(script_path) do
    with {:ok, sections} <- :escript.extract(String.to_charlist(script_path), []),
         {:ok, archive} when is_binary(archive) <- Keyword.fetch(sections, :archive),
         {:ok, entries} <- :zip.extract(archive, [:memory]),
         {entry_name, nif} when is_binary(nif) <- find_exqlite_nif(entries) do
      cache_exqlite_nif(entry_name, nif)
    else
      nil -> {:error, :embedded_exqlite_nif_not_found}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_escript_archive}
    end
  end

  defp find_exqlite_nif(entries) do
    Enum.find(entries, fn {entry_name, _contents} ->
      entry_name
      |> List.to_string()
      |> String.starts_with?(@exqlite_nif_entry_prefix)
    end)
  end

  defp cache_exqlite_nif(entry_name, nif) do
    digest = :sha256 |> :crypto.hash(nif) |> Base.encode16(case: :lower)

    user_cache = :filename.basedir(:user_cache, ~c"symphony") |> List.to_string()
    cache_root = Path.join([user_cache, "escript", digest, "exqlite"])

    ebin_path = Path.join(cache_root, "ebin")
    priv_path = Path.join(cache_root, "priv")
    nif_path = Path.join(priv_path, entry_name |> List.to_string() |> Path.basename())

    with :ok <- File.mkdir_p(ebin_path),
         :ok <- File.mkdir_p(priv_path),
         :ok <- write_cached_nif(nif_path, nif),
         true <- :code.add_patha(String.to_charlist(ebin_path)) do
      verify_exqlite_priv_path(priv_path)
    else
      {:error, _reason} = error -> error
    end
  end

  defp verify_exqlite_priv_path(expected_path) do
    case :code.priv_dir(:exqlite) do
      path when is_list(path) ->
        if Path.expand(List.to_string(path)) == Path.expand(expected_path),
          do: :ok,
          else: {:error, {:unexpected_exqlite_priv_dir, List.to_string(path)}}

      error ->
        {:error, {:unresolved_exqlite_priv_dir, error}}
    end
  end

  defp write_cached_nif(path, nif) do
    case File.read(path) do
      {:ok, ^nif} ->
        :ok

      _missing_or_stale ->
        temporary_path = "#{path}.#{System.pid()}.#{System.unique_integer([:positive])}.tmp"

        result =
          with :ok <- File.write(temporary_path, nif, [:binary, :exclusive]),
               :ok <- File.rename(temporary_path, path) do
            File.chmod(path, 0o600)
          end

        File.rm(temporary_path)

        case result do
          {:error, :eexist} -> verify_cached_nif(path, nif)
          other -> other
        end
    end
  end

  defp verify_cached_nif(path, expected) do
    case File.read(path) do
      {:ok, ^expected} -> :ok
      {:ok, _other} -> {:error, {:native_cache_content_mismatch, path}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp json_safe(%_{} = struct), do: struct |> Map.from_struct() |> json_safe()
  defp json_safe(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key, json_safe(value)} end)
  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(tuple) when is_tuple(tuple), do: inspect(tuple)
  defp json_safe(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp json_safe(value), do: value
end
