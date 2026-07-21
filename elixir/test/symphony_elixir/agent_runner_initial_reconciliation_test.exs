defmodule SymphonyElixir.AgentRunnerInitialReconciliationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Board
  alias SymphonyElixir.Board.Commands
  alias SymphonyElixir.BoardFactory
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.Paths
  alias SymphonyElixir.Task
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.Worktree

  setup do
    original_workflow = Workflow.workflow_file_path()
    original_path = System.get_env("PATH")

    on_exit(fn ->
      System.put_env("PATH", original_path)
      Workflow.set_workflow_file_path(original_workflow)
      Workflow.Store.force_reload()
    end)

    %{original_path: original_path}
  end

  @tag timeout: 30_000
  test "reconciles the current head, fetched base, and cleanliness before workpad and Codex startup", %{
    original_path: original_path
  } do
    source = BoardFactory.workflow_source()
    fake_codex = Path.join(source.root, "initial_reconciliation_fake_codex.exs")
    fake_bin = Path.join(source.root, "fake-bin")
    File.mkdir_p!(fake_bin)

    File.write!(
      fake_codex,
      initial_reconciliation_fake_codex(Paths.workpads_root("symphony"), source.root, source.remote)
    )

    File.write!(Path.join(fake_bin, "gh"), fake_gh())
    File.chmod!(Path.join(fake_bin, "gh"), 0o755)

    github_url = "https://github.test/owner/repo.git"
    rewrite_key = "url.file://#{source.remote}.insteadOf"
    BoardFactory.git!(source.root, ["config", rewrite_key, github_url])
    BoardFactory.git!(source.root, ["remote", "set-url", "origin", github_url])

    command =
      "cd #{shell_escape(File.cwd!())} && MIX_ENV=test mise exec -- mix run --no-compile --no-deps-check --no-start #{shell_escape(fake_codex)}"

    configure_workflow(source, command,
      context: "{% if source.head_sha %}prompt-head={{ source.head_sha }} base={{ source.base_sha }} clean={{ source.clean }}{% endif %}\n",
      workpad: "{% if source.head_sha %}workpad-head={{ source.head_sha }} base={{ source.base_sha }} clean={{ source.clean }}{% endif %}\n"
    )

    System.put_env("PATH", fake_bin <> ":" <> original_path)

    {backlog, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Initial reconciliation")})
    {todo, _result} = BoardFactory.move(backlog, "todo")

    assert {:ok, %{"task" => claimed, "run" => run}} =
             Board.execute(%Commands.ClaimRun{task_id: todo["id"]},
               actor: %{type: :system, identity: "initial-reconciliation-test"},
               expected_revision: todo["revision"],
               idempotency_key: BoardFactory.unique("claim")
             )

    task = Task.from_map(claimed)
    assert {:ok, worktree} = Worktree.ensure(task)
    task_head = BoardFactory.git!(worktree, ["rev-parse", "HEAD"]) |> String.trim()
    stale_base = BoardFactory.git!(worktree, ["rev-parse", "origin/main"]) |> String.trim()

    upstream = source.root <> "-upstream"
    {_output, 0} = System.cmd("git", ["clone", source.remote, upstream], stderr_to_stdout: true)
    File.write!(Path.join(upstream, "upstream.txt"), "new target state\n")
    BoardFactory.git!(upstream, ["add", "upstream.txt"])

    BoardFactory.git!(upstream, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.com",
      "commit",
      "-m",
      "advance target"
    ])

    BoardFactory.git!(upstream, ["push", "origin", "main"])
    current_base = BoardFactory.git!(upstream, ["rev-parse", "HEAD"]) |> String.trim()
    refute current_base == stale_base
    assert BoardFactory.git!(source.root, ["rev-parse", "origin/main"]) |> String.trim() == stale_base

    assert :ok = AgentRunner.run(task.id, run["id"])

    assert {:ok, current} = Board.task(task.id)

    assert Map.take(current.source, ~w(head_sha base_sha clean)) == %{
             "head_sha" => task_head,
             "base_sha" => current_base,
             "clean" => true
           }

    assert {:ok, workpad} = Board.read_workpad(run["id"], 1)
    assert workpad == "workpad-head=#{task_head} base=#{current_base} clean=true\n"

    assert {:ok, completed_run} = Board.run(run["id"])
    assert completed_run["status"] == "completed"

    assert {:ok, %{"task" => blocked}} =
             Board.execute(
               %Commands.MoveTask{task_id: current.id, column_id: "blocked"},
               actor: %{type: :human, identity: "initial-reconciliation-test"},
               expected_revision: current.revision,
               idempotency_key: BoardFactory.unique("cleanup")
             )

    assert blocked["column_id"] == "blocked"
  end

  @tag timeout: 30_000
  test "a source reconciliation failure starts no Codex process and becomes an explicit failed run" do
    source = BoardFactory.workflow_source()
    marker = Path.join(source.root, "codex-started")
    fake_codex = Path.join(source.root, "must-not-start.sh")
    unexpected_branch = "unexpected-#{System.unique_integer([:positive, :monotonic])}"

    File.write!(fake_codex, "#!/bin/sh\nset -eu\nprintf started > #{shell_escape(marker)}\nexit 1\n")
    File.chmod!(fake_codex, 0o755)

    configure_workflow(source, shell_escape(fake_codex), before_run: "git switch -c #{unexpected_branch}")

    {backlog, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Failed initial reconciliation")})
    {todo, _result} = BoardFactory.move(backlog, "todo")
    task_id = todo["id"]

    state =
      struct(State,
        dispatch_enabled: true,
        recover_orphans: false,
        task_filter: &(&1.id == task_id),
        agent_runner: &AgentRunner.run/3,
        github_health: %{available: true, authenticated: true, error: nil},
        github_health_checked_at: System.monotonic_time(:millisecond)
      )

    assert {:noreply, running_state} = Orchestrator.handle_info(:reconcile, state)
    assert %{^task_id => runtime} = running_state.running
    assert_receive {ref, {:error, {:worktree_branch_mismatch, expected_branch}}}, 10_000
    assert ref == runtime.ref
    assert expected_branch == todo["branch"]

    assert {:noreply, _finished_state} =
             Orchestrator.handle_info(
               {ref, {:error, {:worktree_branch_mismatch, expected_branch}}},
               running_state
             )

    refute File.exists?(marker)
    assert {:ok, failed_task} = Board.task(task_id)
    assert failed_task.column_id == "blocked"
    assert is_nil(failed_task.active_run_id)

    assert [failed_run | _] = Board.runs(task_id)
    assert failed_run["status"] == "failed"
    assert failed_run["failure"] =~ "worktree_branch_mismatch"
  end

  defp configure_workflow(source, command, opts) do
    workflow =
      source.workflow
      |> File.read!()
      |> then(&Regex.replace(~r/^  command:.*$/m, &1, "  command: #{Jason.encode!(command)}"))
      |> configure_before_run(Keyword.get(opts, :before_run))

    File.write!(source.workflow, workflow)

    if context = Keyword.get(opts, :context) do
      File.write!(Path.join(source.root, "workflow/prompts/context.md"), context)
    end

    if workpad = Keyword.get(opts, :workpad) do
      File.write!(Path.join(source.root, "workflow/workpads/implementation.md"), workpad)
    end

    Workflow.set_workflow_file_path(source.workflow)
    assert :ok = Workflow.Store.force_reload()
    BoardFactory.await_activation()
  end

  defp configure_before_run(workflow, nil), do: workflow

  defp configure_before_run(workflow, command) do
    String.replace(workflow, "hooks:\n", "hooks:\n  before_run: #{Jason.encode!(command)}\n")
  end

  defp initial_reconciliation_fake_codex(workpads_root, source_root, remote) do
    """
    defmodule InitialReconciliationFakeCodex do
      @workpads_root #{inspect(workpads_root)}
      @source_root #{inspect(source_root)}
      @remote #{inspect(remote)}

      def main do
        assert_current_workpad!()
        loop(%{})
      end

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

      defp handle(%{"method" => "thread/start", "id" => id, "params" => %{"cwd" => workspace}}, state) do
        assert_current_workpad!()
        assert_current_git!(workspace)
        {Map.put(state, :workspace, workspace),
         %{"id" => id, "result" => %{"thread" => %{"id" => "initial-thread"}}}}
      end

      defp handle(%{"method" => "turn/start", "id" => id, "params" => params}, state) do
        prompt = get_in(params, ["input", Access.at(0), "text"])
        assert_fragment!(prompt, "prompt")
        turn_id = "initial-turn"

        outgoing = [
          %{"id" => id, "result" => %{"turn" => %{"id" => turn_id}}},
          tool_call("initial-context", "symphony_task_context", %{})
        ]

        {state |> Map.put(:phase, :context) |> Map.put(:turn_id, turn_id), outgoing}
      end

      defp handle(%{"result" => result}, %{phase: :context} = state) do
        current = successful_output!(result)
        expected = current_source!()

        unless current["source"] == expected do
          raise "stale initial task context: expected=\#{inspect(expected)} actual=\#{inspect(current["source"])}"
        end

        arguments = %{
          "column_id" => "automated_review",
          "expected_revision" => get_in(current, ["task", "revision"])
        }

        {Map.put(state, :phase, :transition),
         tool_call("initial-transition", "symphony_task_transition", arguments)}
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

      defp assert_current_workpad! do
        run_id = System.fetch_env!("SYMPHONY_RUN_ID")
        path = Path.join([@workpads_root, "records", run_id, "1.json"])
        content = path |> File.read!() |> Jason.decode!() |> Map.fetch!("content")
        assert_fragment!(content, "workpad")
      end

      defp assert_current_git!(workspace) do
        expected = current_source!()
        {status, 0} = System.cmd("git", ["-C", workspace, "status", "--porcelain=v1", "--untracked-files=all"])

        unless String.trim(status) == "" and expected["clean"] do
          raise "initial worktree was not clean"
        end
      end

      defp assert_fragment!(content, label) do
        expected = current_source!()
        fragment = "\#{label}-head=\#{expected["head_sha"]} base=\#{expected["base_sha"]} clean=true"

        unless String.contains?(content, fragment) do
          raise "stale \#{label}: expected fragment \#{inspect(fragment)} in \#{inspect(content)}"
        end
      end

      defp current_source! do
        branch = System.fetch_env!("SYMPHONY_TASK_BRANCH")
        {head, 0} = System.cmd("git", ["-C", @source_root, "rev-parse", "refs/heads/" <> branch])
        {base, 0} = System.cmd("git", ["--git-dir", @remote, "rev-parse", "refs/heads/main"])

        %{
          "head_sha" => String.trim(head),
          "base_sha" => String.trim(base),
          "clean" => true
        }
      end

      defp tool_call(id, tool, arguments) do
        %{
          "id" => id,
          "method" => "item/tool/call",
          "params" => %{"tool" => tool, "arguments" => arguments}
        }
      end

      defp successful_output!(%{"success" => true, "output" => output}), do: Jason.decode!(output)
      defp successful_output!(result), do: raise("tool failed: \#{inspect(result)}")
    end

    InitialReconciliationFakeCodex.main()
    """
  end

  defp fake_gh do
    """
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
