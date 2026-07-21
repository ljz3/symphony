defmodule SymphonyElixir.BackendSchedulingTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Board
  alias SymphonyElixir.Board.Commands
  alias SymphonyElixir.BoardFactory
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.Workflow

  @stage_ids ~w(implementation automated_review rework merge_conflict)

  setup do
    original_workflow = Workflow.workflow_file_path()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow)
      Workflow.Store.force_reload()
    end)

    :ok
  end

  test "kimi task dispatches locally in a local-only pool" do
    source = BoardFactory.workflow_source()
    mutate_workflow(source, ssh_hosts: "[]", local_worker: false)

    parent = self()
    kimi_task = create_backend_task("kimi-local", "kimi")

    state = dispatch_state(parent, task_filter: &(&1.id == kimi_task["id"]))
    assert {:noreply, _next} = Orchestrator.handle_info(:reconcile, state)

    assert_receive {:agent_runner_called, task_id, run_id}
    assert task_id == kimi_task["id"]

    {:ok, run} = Board.run(run_id)
    assert run["backend"] == "kimi"
    assert run["worker_host"] == nil
  end

  test "kimi dispatches locally in a mixed pool while codex uses the healthy remote" do
    source = BoardFactory.workflow_source()
    mutate_workflow(source, ssh_hosts: ~s(["builder-a"]), local_worker: true)

    parent = self()
    kimi_task = create_backend_task("kimi-mixed", "kimi")
    codex_task = create_backend_task("codex-mixed", "codex")

    state =
      dispatch_state(parent,
        task_filter: &(&1.id in [kimi_task["id"], codex_task["id"]]),
        worker_health: %{"builder-a" => healthy_worker()}
      )

    assert {:noreply, _next} = Orchestrator.handle_info(:reconcile, state)

    assert_receive {:agent_runner_called, kimi_id, kimi_run_id}
    assert_receive {:agent_runner_called, codex_id, codex_run_id}
    assert {kimi_id, codex_id} == {kimi_task["id"], codex_task["id"]}

    {:ok, kimi_run} = Board.run(kimi_run_id)
    {:ok, codex_run} = Board.run(codex_run_id)
    assert kimi_run["worker_host"] == nil
    assert codex_run["worker_host"] == "builder-a"
  end

  test "kimi task blocks deterministically in a remote-only pool while codex still dispatches" do
    source = BoardFactory.workflow_source()
    mutate_workflow(source, ssh_hosts: ~s(["builder-a"]), local_worker: false)

    parent = self()
    # The kimi task is created first and therefore ranked ahead of the codex
    # task: an ineligible candidate must not stall later eligible ones.
    kimi_task = create_backend_task("kimi-remote-only", "kimi")
    codex_task = create_backend_task("codex-remote-only", "codex")

    state =
      dispatch_state(parent,
        task_filter: &(&1.id in [kimi_task["id"], codex_task["id"]]),
        worker_health: %{"builder-a" => healthy_worker()}
      )

    assert {:noreply, _next} = Orchestrator.handle_info(:reconcile, state)

    assert_receive {:agent_runner_called, codex_id, codex_run_id}
    assert codex_id == codex_task["id"]
    refute_receive {:agent_runner_called, _, _}

    {:ok, codex_run} = Board.run(codex_run_id)
    assert codex_run["worker_host"] == "builder-a"

    {:ok, blocked} = Board.task(kimi_task["id"])
    assert blocked.column_id == "blocked"
    assert blocked.active_run_id == nil
  end

  test "claim validation rejects an ACP backend with a remote worker host" do
    source = BoardFactory.workflow_source()
    mutate_workflow(source, ssh_hosts: ~s(["builder-a"]), local_worker: false)

    kimi_task = create_backend_task("kimi-remote-claim", "kimi")

    assert {:error, {:backend_remote_unsupported, "kimi"}} =
             Board.execute(%Commands.ClaimRun{task_id: kimi_task["id"], worker_host: "builder-a"},
               actor: :system,
               expected_revision: kimi_task["revision"],
               idempotency_key: BoardFactory.unique("remote-kimi-claim")
             )
  end

  defp create_backend_task(label, backend) do
    selections =
      Map.new(@stage_ids, fn stage_id ->
        {stage_id, selection_for(backend)}
      end)

    {task, _key} =
      BoardFactory.create_task(%{title: BoardFactory.unique(label), stage_selections: selections})

    {todo, _result} = BoardFactory.move(task, "todo")
    todo
  end

  defp selection_for("kimi"), do: %{"backend" => "kimi", "model" => "kimi-code/k3", "effort" => "max"}
  defp selection_for(_backend), do: %{"backend" => "codex", "model" => "gpt-5.5", "effort" => "xhigh"}

  defp mutate_workflow(source, opts) do
    ssh_hosts = Keyword.fetch!(opts, :ssh_hosts)
    local_worker = Keyword.fetch!(opts, :local_worker)

    workflow =
      source.workflow
      |> File.read!()
      |> then(&Regex.replace(~r/^  ssh_hosts:.*$/m, &1, "  ssh_hosts: #{ssh_hosts}\n  local_worker: #{local_worker}"))
      |> then(
        &Regex.replace(~r/codex:\n(?:  .+\n)+(?=\nprompts:)/, &1, """
        backends:
          codex:
            protocol: app_server
            command: codex app-server
          kimi:
            protocol: acp
            command: fake-kimi acp
            allow_unsandboxed: true
        """)
      )
      |> String.replace(
        "    allowed_model_efforts:\n      gpt-5.5: [xhigh]\n",
        """
            allowed_models:
              - {backend: codex, model: gpt-5.5, efforts: [xhigh]}
              - {backend: kimi, model: kimi-code/k3, efforts: [max]}
        """
      )

    File.write!(source.workflow, workflow)
    Workflow.set_workflow_file_path(source.workflow)
    assert :ok = Workflow.Store.force_reload()
    BoardFactory.await_activation()

    # force_reload only defers activation while the board is busy; wait until
    # the mutated bundle is actually active before driving claims.
    {:ok, expected} = Workflow.load(source.workflow)
    await_activation(expected.hash, 100)
  end

  defp await_activation(_hash, 0), do: raise("workflow activation timed out")

  defp await_activation(hash, attempts) do
    case Workflow.current() do
      {:ok, %{hash: ^hash}} ->
        :ok

      _other ->
        Process.sleep(20)
        await_activation(hash, attempts - 1)
    end
  end

  defp dispatch_state(parent, overrides) do
    defaults = [
      dispatch_enabled: true,
      recover_orphans: false,
      agent_runner: fn task_id, run_id, _recipient ->
        send(parent, {:agent_runner_called, task_id, run_id})
        fail_claimed_run(task_id, run_id)
        :ok
      end,
      github_health: %{available: true, authenticated: true, error: nil},
      github_health_checked_at: System.monotonic_time(:millisecond)
    ]

    struct(State, Keyword.merge(defaults, overrides))
  end

  # Claimed runs must finish so the board goes idle again; otherwise later
  # workflow activations stay deferred for the rest of the file.
  defp fail_claimed_run(task_id, run_id) do
    with {:ok, task} <- Board.task(task_id) do
      Board.execute(%Commands.RunFailed{task_id: task_id, run_id: run_id, reason: :test_complete},
        actor: :system,
        expected_revision: task.revision,
        idempotency_key: BoardFactory.unique("run-failed")
      )
    end

    :ok
  end

  defp healthy_worker do
    %{status: :healthy, refresh_at_ms: System.monotonic_time(:millisecond) + 60_000}
  end
end
