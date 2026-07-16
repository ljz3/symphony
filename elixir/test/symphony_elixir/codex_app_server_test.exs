defmodule SymphonyElixir.CodexAppServerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{BoardFactory, Paths, Workflow}
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

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
