defmodule SymphonyElixir.CodexAppServerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{BoardFactory, JobManager, Paths, Workflow}
  alias SymphonyElixir.Codex.AppServer

  @tag timeout: 20_000
  test "waits for an app-server response beyond the former read deadline" do
    original_workflow = Workflow.workflow_file_path()
    source = BoardFactory.workflow_source()
    fake_codex = Path.join(source.root, "delayed_fake_codex.exs")
    File.write!(fake_codex, delayed_fake_codex())

    command =
      "cd #{shell_escape(File.cwd!())} && MIX_ENV=test mise exec -- mix run --no-compile --no-deps-check --no-start #{shell_escape(fake_codex)}"

    workflow =
      source.workflow
      |> File.read!()
      |> then(&Regex.replace(~r/^  command:.*$/m, &1, "  command: #{Jason.encode!(command)}"))

    File.write!(source.workflow, workflow)
    Workflow.set_workflow_file_path(source.workflow)
    assert :ok = Workflow.Store.force_reload()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow)
      Workflow.Store.force_reload()
    end)

    workspace = Path.join(Paths.runtime_root("symphony"), BoardFactory.unique("delayed-catalog"))
    File.mkdir_p!(workspace)

    started_at = System.monotonic_time(:millisecond)
    assert {:ok, [%{"model" => "delayed-model"}]} = AppServer.catalog(workspace)
    assert System.monotonic_time(:millisecond) - started_at >= 5_100
  end

  test "passes managed identity and the frozen run tool schema to thread start" do
    original_workflow = Workflow.workflow_file_path()
    source = BoardFactory.workflow_source()
    fake_codex = Path.join(source.root, "capture_fake_codex.exs")
    capture = Path.join(source.root, "captured-thread.json")
    File.write!(fake_codex, capture_fake_codex())

    command =
      "cd #{shell_escape(File.cwd!())} && MIX_ENV=test mise exec -- mix run --no-compile --no-deps-check --no-start #{shell_escape(fake_codex)}"

    workflow =
      source.workflow
      |> File.read!()
      |> then(&Regex.replace(~r/^  command:.*$/m, &1, "  command: #{Jason.encode!(command)}"))

    File.write!(source.workflow, workflow)
    Workflow.set_workflow_file_path(source.workflow)
    assert :ok = Workflow.Store.force_reload()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow)
      Workflow.Store.force_reload()
    end)

    workspace = Path.join(Paths.worktrees_root("symphony"), BoardFactory.unique("managed-app-server"))
    File.mkdir_p!(workspace)

    specs = [
      %{
        "name" => "symphony_job_run",
        "description" => "frozen",
        "inputSchema" => %{"type" => "object", "additionalProperties" => false}
      }
    ]

    environment = %{
      "SYMPHONY_MANAGED_RUN" => "1",
      "SYMPHONY_TASK_ID" => "task-id",
      "SYMPHONY_TASK_IDENTIFIER" => "FOODMAP-1",
      "SYMPHONY_TASK_BRANCH" => "feature/FOODMAP-1",
      "SYMPHONY_RUN_ID" => "run-id",
      "CAPTURE_PATH" => capture
    }

    assert {:ok, session} =
             AppServer.start_session(workspace,
               environment: environment,
               dynamic_tool_specs: specs
             )

    AppServer.stop_session(session)
    captured = capture |> File.read!() |> Jason.decode!()
    assert captured["dynamicTools"] == specs
    assert captured["managed"] == environment
  end

  test "keeps one tool call pending without starting a continuation" do
    original_workflow = Workflow.workflow_file_path()
    source = BoardFactory.workflow_source()
    fake_codex = Path.join(source.root, "blocking_tool_fake_codex.exs")
    File.write!(fake_codex, blocking_tool_fake_codex())

    command =
      "cd #{shell_escape(File.cwd!())} && MIX_ENV=test mise exec -- mix run --no-compile --no-deps-check --no-start #{shell_escape(fake_codex)}"

    workflow =
      source.workflow
      |> File.read!()
      |> then(&Regex.replace(~r/^  command:.*$/m, &1, "  command: #{Jason.encode!(command)}"))

    File.write!(source.workflow, workflow)
    Workflow.set_workflow_file_path(source.workflow)
    assert :ok = Workflow.Store.force_reload()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow)
      Workflow.Store.force_reload()
    end)

    workspace = Path.join(Paths.worktrees_root("symphony"), BoardFactory.unique("blocking-tool"))
    File.mkdir_p!(workspace)
    specs = [%{"name" => "symphony_job_run", "description" => "blocking", "inputSchema" => %{}}]

    parent = self()

    executor = fn tool, arguments, metadata ->
      send(parent, {:tool_started, tool, arguments, metadata.call_id})

      receive do
        :release_job ->
          %{"success" => true, "output" => "complete", "contentItems" => []}
      end
    end

    turn =
      Task.async(fn ->
        {:ok, session} = AppServer.start_session(workspace, dynamic_tool_specs: specs)

        try do
          AppServer.run_turn(
            session,
            "Run the project job.",
            %{id: "task-id", identifier: "FOODMAP-1", title: "Blocking job"},
            tool_executor: executor
          )
        after
          AppServer.stop_session(session)
        end
      end)

    assert_receive {:tool_started, "symphony_job_run", %{"job" => "validation", "arguments" => []}, "job-call"},
                   5_000

    assert Task.yield(turn, 100) == nil
    send(turn.pid, :release_job)
    assert {:ok, {:ok, %{result: :turn_completed}}} = Task.yield(turn, 5_000)
  end

  @tag timeout: 20_000
  test "reconnects a dropped app-server during a blocking job and replays one durable tool call" do
    original_workflow = Workflow.workflow_file_path()
    source = BoardFactory.workflow_source()
    fake_codex = Path.join(source.root, "reconnecting_fake_codex.exs")
    fake_state = Path.join(source.root, "reconnecting-state")
    method_log = Path.join(source.root, "reconnecting-methods")
    File.write!(fake_codex, reconnecting_fake_codex())

    command =
      "cd #{shell_escape(File.cwd!())} && MIX_ENV=test mise exec -- mix run --no-compile --no-deps-check --no-start #{shell_escape(fake_codex)}"

    workflow =
      source.workflow
      |> File.read!()
      |> then(&Regex.replace(~r/^  command:.*$/m, &1, "  command: #{Jason.encode!(command)}"))

    File.write!(source.workflow, workflow)
    Workflow.set_workflow_file_path(source.workflow)
    assert :ok = Workflow.Store.force_reload()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow)
      Workflow.Store.force_reload()
    end)

    workspace = Path.join(Paths.worktrees_root("symphony"), BoardFactory.unique("reconnecting-tool"))
    File.mkdir_p!(workspace)
    {_, 0} = System.cmd("git", ["init", "--initial-branch=main", workspace], stderr_to_stdout: true)
    File.write!(Path.join(workspace, "tracked"), "source")
    git!(workspace, ["add", "."])
    git!(workspace, ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "source"])

    fifo = Path.join(workspace, "release.fifo")
    count = Path.join(workspace, "job-count")
    {_, 0} = System.cmd("mkfifo", [fifo])

    write_script!(workspace, "blocking-job.sh", """
    #!/bin/sh
    current=0
    if test -f "$1"; then current=$(cat "$1"); fi
    current=$((current + 1))
    printf '%s' "$current" > "$1"
    read -r value < "$2"
    printf '%s' "$value"
    """)

    parent = self()

    executor = fn _tool, _arguments, metadata ->
      send(parent, {:reconnecting_tool_call, metadata.call_id})

      {:ok, result} =
        JobManager.run(%{
          task_id: "task-id",
          task_identifier: "FOODMAP-1",
          task_branch: "feature/FOODMAP-1",
          run_id: "reconnecting-run",
          call_id: to_string(metadata.call_id),
          job: %{
            "id" => "validation",
            "executable" => "./blocking-job.sh",
            "arguments" => [],
            "passthrough_arguments" => :required,
            "environment" => %{}
          },
          arguments: [count, fifo],
          workspace: workspace,
          worker_host: nil,
          source_fingerprint: "reconnecting-source"
        })

      output = Jason.encode!(result)
      %{"success" => true, "output" => output, "contentItems" => [%{"type" => "inputText", "text" => output}]}
    end

    environment = %{"FAKE_STATE" => fake_state, "FAKE_METHOD_LOG" => method_log}
    specs = [%{"name" => "symphony_job_run", "description" => "blocking", "inputSchema" => %{}}]

    turn =
      Task.async(fn ->
        {:ok, session} =
          AppServer.start_session(workspace,
            environment: environment,
            dynamic_tool_specs: specs
          )

        try do
          AppServer.run_turn(
            session,
            "Run validation.",
            %{id: "task-id", identifier: "FOODMAP-1", title: "Reconnect"},
            tool_executor: executor,
            on_session_reconnected: fn resumed_session ->
              send(parent, {:app_server_reconnected, resumed_session.thread_id})
              :ok
            end
          )
        after
          AppServer.stop_session(session)
        end
      end)

    assert_receive {:reconnecting_tool_call, "job-call"}, 5_000
    eventually(fn -> File.exists?(count) and File.read!(count) == "1" end)
    Process.sleep(100)
    File.write!(fifo, "complete\n")

    assert {:ok, {:ok, %{result: :turn_completed}}} = Task.yield(turn, 10_000)
    assert_receive {:app_server_reconnected, "persisted-thread"}, 5_000
    assert_receive {:reconnecting_tool_call, "job-call"}, 5_000
    assert File.read!(count) == "1"

    methods = File.read!(method_log)
    assert ~r/^turn\/start$/m |> Regex.scan(methods) |> length() == 1
    assert methods =~ "thread/resume"
  end

  defp delayed_fake_codex do
    ~S"""
    defmodule DelayedFakeCodex do
      def main, do: loop()

      defp loop do
        case IO.read(:stdio, :line) do
          :eof ->
            :ok

          line ->
            line
            |> Jason.decode!()
            |> respond()

            loop()
        end
      end

      defp respond(%{"method" => "initialize", "id" => id}) do
        Process.sleep(5_200)
        IO.puts(Jason.encode!(%{"id" => id, "result" => %{}}))
      end

      defp respond(%{"method" => "model/list", "id" => id}) do
        IO.puts(
          Jason.encode!(%{
            "id" => id,
            "result" => %{"data" => [%{"model" => "delayed-model"}]}
          })
        )
      end

      defp respond(_message), do: :ok
    end

    DelayedFakeCodex.main()
    """
  end

  defp capture_fake_codex do
    ~S"""
    defmodule CaptureFakeCodex do
      def main, do: loop()

      defp loop do
        case IO.read(:stdio, :line) do
          :eof -> :ok
          line ->
            line |> Jason.decode!() |> respond()
            loop()
        end
      end

      defp respond(%{"method" => "initialize", "id" => id}),
        do: IO.puts(Jason.encode!(%{"id" => id, "result" => %{}}))

      defp respond(%{"method" => "model/list", "id" => id}) do
        IO.puts(Jason.encode!(%{"id" => id, "result" => %{"data" => []}}))
      end

      defp respond(%{"method" => "thread/start", "id" => id, "params" => params}) do
        managed =
          ~w(SYMPHONY_MANAGED_RUN SYMPHONY_TASK_ID SYMPHONY_TASK_IDENTIFIER SYMPHONY_TASK_BRANCH SYMPHONY_RUN_ID CAPTURE_PATH)
          |> Map.new(&{&1, System.fetch_env!(&1)})

        File.write!(System.fetch_env!("CAPTURE_PATH"), Jason.encode!(Map.put(params, "managed", managed)))
        IO.puts(Jason.encode!(%{"id" => id, "result" => %{"thread" => %{"id" => "capture-thread"}}}))
      end

      defp respond(_message), do: :ok
    end

    CaptureFakeCodex.main()
    """
  end

  defp blocking_tool_fake_codex do
    ~S"""
    defmodule BlockingToolFakeCodex do
      def main, do: loop(%{})

      defp loop(state) do
        case IO.read(:stdio, :line) do
          :eof -> :ok
          line ->
            {state, outgoing} = line |> Jason.decode!() |> respond(state)
            outgoing |> List.wrap() |> Enum.each(&IO.puts(Jason.encode!(&1)))
            loop(state)
        end
      end

      defp respond(%{"method" => "initialize", "id" => id}, state),
        do: {state, %{"id" => id, "result" => %{}}}

      defp respond(%{"method" => "model/list", "id" => id}, state),
        do: {state, %{"id" => id, "result" => %{"data" => []}}}

      defp respond(%{"method" => "thread/start", "id" => id}, state),
        do: {state, %{"id" => id, "result" => %{"thread" => %{"id" => "blocking-thread"}}}}

      defp respond(%{"method" => "turn/start", "id" => id}, state) do
        response = %{"id" => id, "result" => %{"turn" => %{"id" => "blocking-turn"}}}

        call = %{
          "id" => "job-call",
          "method" => "item/tool/call",
          "params" => %{
            "tool" => "symphony_job_run",
            "arguments" => %{"job" => "validation", "arguments" => []}
          }
        }

        {Map.put(state, :waiting, true), [response, call]}
      end

      defp respond(%{"id" => "job-call", "result" => %{"success" => true}}, state) do
        completed = %{
          "method" => "turn/completed",
          "params" => %{"turn" => %{"id" => "blocking-turn", "status" => "completed"}}
        }

        {Map.delete(state, :waiting), completed}
      end

      defp respond(_message, state), do: {state, []}
    end

    BlockingToolFakeCodex.main()
    """
  end

  defp reconnecting_fake_codex do
    ~S"""
    defmodule ReconnectingFakeCodex do
      def main do
        attempt = next_attempt!()
        loop(attempt)
      end

      defp loop(attempt) do
        case IO.read(:stdio, :line) do
          :eof -> :ok
          line ->
            message = Jason.decode!(line)
            log_method(message)

            case respond(message, attempt) do
              :exit -> System.halt(91)
              outgoing -> outgoing |> List.wrap() |> Enum.each(&IO.puts(Jason.encode!(&1)))
            end

            loop(attempt)
        end
      end

      defp respond(%{"method" => "initialize", "id" => id}, _attempt),
        do: %{"id" => id, "result" => %{}}

      defp respond(%{"method" => "initialized"}, _attempt), do: []

      defp respond(%{"method" => "thread/start", "id" => id}, 1),
        do: %{"id" => id, "result" => %{"thread" => %{"id" => "persisted-thread"}}}

      defp respond(%{"method" => "turn/start", "id" => id}, 1) do
        IO.puts(Jason.encode!(%{"id" => id, "result" => %{"turn" => %{"id" => "persisted-turn"}}}))
        IO.puts(Jason.encode!(tool_call()))
        :exit
      end

      defp respond(
             %{
               "method" => "thread/resume",
               "id" => id,
               "params" => %{"threadId" => "persisted-thread"}
             },
             attempt
           )
           when attempt > 1 do
        response = %{
          "id" => id,
          "result" => %{
            "thread" => %{
              "id" => "persisted-thread",
              "status" => %{"type" => "active"},
              "turns" => [%{"id" => "persisted-turn", "status" => "inProgress", "items" => []}]
            }
          }
        }

        [response, tool_call()]
      end

      defp respond(%{"id" => "job-call", "result" => %{"success" => true}}, attempt) when attempt > 1 do
        %{
          "method" => "turn/completed",
          "params" => %{"turn" => %{"id" => "persisted-turn", "status" => "completed"}}
        }
      end

      defp respond(_message, _attempt), do: []

      defp tool_call do
        %{
          "id" => "job-call",
          "method" => "item/tool/call",
          "params" => %{
            "tool" => "symphony_job_run",
            "arguments" => %{"job" => "validation", "arguments" => []}
          }
        }
      end

      defp next_attempt! do
        path = System.fetch_env!("FAKE_STATE")
        current = if File.exists?(path), do: path |> File.read!() |> String.to_integer(), else: 0
        next = current + 1
        File.write!(path, Integer.to_string(next))
        next
      end

      defp log_method(%{"method" => method}) do
        File.write!(System.fetch_env!("FAKE_METHOD_LOG"), method <> "\n", [:append])
      end

      defp log_method(_message), do: :ok
    end

    ReconnectingFakeCodex.main()
    """
  end

  defp write_script!(workspace, name, content) do
    path = Path.join(workspace, name)
    File.write!(path, content)
    File.chmod!(path, 0o755)
    path
  end

  defp git!(root, args) do
    case System.cmd("git", ["-C", root | args], stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise "git failed (#{status}): #{output}"
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: flunk("condition did not become true")

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
