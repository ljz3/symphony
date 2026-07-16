defmodule SymphonyElixir.AgentRunnerDeadlineTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{AgentRunner, Board, BoardFactory, Workflow}
  alias SymphonyElixir.Board.Commands

  @tag timeout: 30_000
  test "continues in one session beyond the former turn limit until transition" do
    original_workflow = Workflow.workflow_file_path()
    original_path = System.get_env("PATH")
    source = BoardFactory.workflow_source()
    fake_codex = Path.join(source.root, "many_turn_fake_codex.exs")
    fake_bin = Path.join(source.root, "fake-bin")
    File.mkdir_p!(fake_bin)
    File.write!(fake_codex, many_turn_fake_codex())
    File.write!(Path.join(fake_bin, "gh"), fake_gh())
    File.chmod!(Path.join(fake_bin, "gh"), 0o755)

    github_url = "https://github.test/owner/repo.git"
    rewrite_key = "url.file://#{source.remote}.insteadOf"
    BoardFactory.git!(source.root, ["config", rewrite_key, github_url])
    BoardFactory.git!(source.root, ["remote", "set-url", "origin", github_url])

    command =
      "cd #{shell_escape(File.cwd!())} && MIX_ENV=test mise exec -- mix run --no-compile --no-deps-check --no-start #{shell_escape(fake_codex)}"

    workflow =
      source.workflow
      |> File.read!()
      |> then(&Regex.replace(~r/^  command:.*$/m, &1, "  command: #{Jason.encode!(command)}"))

    File.write!(source.workflow, workflow)
    System.put_env("PATH", fake_bin <> ":" <> original_path)
    Workflow.set_workflow_file_path(source.workflow)
    assert :ok = Workflow.Store.force_reload()

    on_exit(fn ->
      System.put_env("PATH", original_path)
      Workflow.set_workflow_file_path(original_workflow)
      Workflow.Store.force_reload()
    end)

    {backlog, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Many turns")})
    {todo, _result} = BoardFactory.move(backlog, "todo")

    assert {:ok, %{"task" => claimed, "run" => run}} =
             Board.execute(%Commands.ClaimRun{task_id: todo["id"]},
               actor: %{type: :system, identity: "deadline-test"},
               expected_revision: todo["revision"],
               idempotency_key: BoardFactory.unique("claim")
             )

    assert :ok = AgentRunner.run(claimed["id"], run["id"])
    assert {:ok, task} = Board.task(claimed["id"])
    assert task.column_id == "automated_review"
    assert {:ok, completed_run} = Board.run(run["id"])
    assert get_in(completed_run, ["stats", "turn_count"]) == 21
  end

  defp many_turn_fake_codex do
    ~S"""
    defmodule ManyTurnFakeCodex do
      def main, do: loop(%{turn_count: 0})

      defp loop(state) do
        case IO.read(:stdio, :line) do
          :eof ->
            :ok

          line ->
            message = Jason.decode!(line)
            {next, outgoing} = handle(message, state)
            outgoing |> List.wrap() |> Enum.each(&IO.puts(Jason.encode!(&1)))
            loop(next)
        end
      end

      defp handle(%{"method" => "initialize", "id" => id}, state),
        do: {state, %{"id" => id, "result" => %{}}}

      defp handle(%{"method" => "initialized"}, state), do: {state, []}

      defp handle(%{"method" => "model/list", "id" => id}, state) do
        {state, %{"id" => id, "result" => %{"data" => [%{"model" => "gpt-5.5"}]}}}
      end

      defp handle(%{"method" => "thread/start", "id" => id}, state) do
        {state, %{"id" => id, "result" => %{"thread" => %{"id" => "many-turn-thread"}}}}
      end

      defp handle(%{"method" => "turn/start", "id" => id}, state) do
        turn_count = state.turn_count + 1
        turn_id = "turn-#{turn_count}"
        response = %{"id" => id, "result" => %{"turn" => %{"id" => turn_id}}}

        if turn_count < 21 do
          completed = %{
            "method" => "turn/completed",
            "params" => %{"turn" => %{"id" => turn_id, "status" => "completed"}}
          }

          {%{state | turn_count: turn_count}, [response, completed]}
        else
          context = tool_call("context-21", "symphony_task_context", %{})
          {%{state | turn_count: turn_count} |> Map.put(:phase, :context) |> Map.put(:turn_id, turn_id), [response, context]}
        end
      end

      defp handle(%{"result" => result}, %{phase: :context} = state) do
        task = successful_output!(result)["task"]

        arguments = %{
          "column_id" => "automated_review",
          "expected_revision" => task["revision"]
        }

        {Map.put(state, :phase, :transition),
         tool_call("transition-21", "symphony_task_transition", arguments)}
      end

      defp handle(%{"result" => result}, %{phase: :transition} = state) do
        successful_output!(result)

        completed = %{
          "method" => "turn/completed",
          "params" => %{"turn" => %{"id" => state.turn_id, "status" => "completed"}}
        }

        {Map.put(state, :phase, :completed), completed}
      end

      defp handle(_message, state), do: {state, []}

      defp tool_call(id, tool, arguments) do
        %{
          "id" => id,
          "method" => "item/tool/call",
          "params" => %{"tool" => tool, "arguments" => arguments}
        }
      end

      defp successful_output!(%{"success" => true, "output" => output}), do: Jason.decode!(output)
      defp successful_output!(result), do: raise("tool failed: #{inspect(result)}")
    end

    ManyTurnFakeCodex.main()
    """
  end

  defp fake_gh do
    ~S"""
    #!/bin/sh
    set -eu
    case "${1:-}" in
      auth) exit 0 ;;
      api) printf '%s' '{}' ;;
      *) exit 2 ;;
    esac
    """
  end

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
