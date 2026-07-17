defmodule SymphonyElixir.DeterministicMerge.WorkerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config
  alias SymphonyElixir.DeterministicMerge.Worker
  alias SymphonyElixir.Task

  setup do
    assert :none = Worker.active()

    on_exit(fn ->
      case Worker.active() do
        {:ok, _task_id, pid, _guard} -> release_and_wait(pid)
        :none -> :ok
      end
    end)

    %{bundle: Config.bundle!(), task: task("merge-worker")}
  end

  test "owns one registered slot and returns the existing worker", %{bundle: bundle, task: task} do
    parent = self()
    task_id = task.id

    runner = fn _task, _bundle, [] ->
      send(parent, {:runner_started, self()})

      receive do
        :release -> {:ok, :pending}
      end
    end

    expected_guard = Worker.semantic_guard(task, bundle)
    assert {:ok, ^task_id, pid, ^expected_guard} = Worker.ensure_started(task, bundle, runner)
    assert_receive {:runner_started, ^pid}
    assert {:ok, ^task_id, ^pid, ^expected_guard} = Worker.active()

    other_task = %{task | id: "other-merge-worker"}
    assert {:ok, ^task_id, ^pid, ^expected_guard} = Worker.ensure_started(other_task, bundle, runner)

    ref = Process.monitor(pid)
    send(pid, :release)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    eventually(fn -> Worker.active() == :none end)
  end

  test "reports a supervisor refusal without invoking the runner", %{bundle: bundle, task: task} do
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one, max_children: 0)
    parent = self()
    runner = fn _task, _bundle, [] -> send(parent, :unexpected_invocation) end

    assert {:error, :max_children} =
             Worker.ensure_started(task, bundle, runner, supervisor: supervisor)

    refute_receive :unexpected_invocation
    assert :none = Worker.active()
  end

  test "reports a legacy registered worker without an invented semantic guard" do
    parent = self()
    task_id = "legacy-merge-worker"

    pid =
      spawn(fn ->
        {:ok, _owner} =
          Registry.register(SymphonyElixir.DeterministicMerge.WorkerRegistry, :active, task_id)

        send(parent, {:legacy_worker_registered, self()})

        receive do
          :release -> :ok
        end
      end)

    assert_receive {:legacy_worker_registered, ^pid}
    assert {:ok, ^task_id, ^pid, nil} = Worker.active()

    ref = Process.monitor(pid)
    send(pid, :release)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    eventually(fn -> Worker.active() == :none end)
  end

  test "logs a non-success result and releases its identity", %{bundle: bundle, task: task} do
    task_id = task.id

    log =
      capture_log(fn ->
        assert {:ok, ^task_id, pid, _guard} =
                 Worker.ensure_started(task, bundle, fn _, _, [] -> {:error, :expected} end)

        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      end)

    assert log =~ "deterministic merge worker failed"
    assert log =~ "{:error, :expected}"
    eventually(fn -> Worker.active() == :none end)
  end

  test "escalates an explicit cancellation when a runner does not cooperate", %{bundle: bundle, task: task} do
    parent = self()

    runner = fn _task, _bundle, [] ->
      send(parent, {:stubborn_runner_started, self()})

      receive do
        :never_sent -> {:ok, :unexpected}
      end
    end

    assert {:ok, task_id, pid, _guard} = Worker.ensure_started(task, bundle, runner)
    assert_receive {:stubborn_runner_started, ^pid}
    ref = Process.monitor(pid)

    assert :ok = Worker.cancel(pid, task_id)
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 3_000
    eventually(fn -> Worker.active() == :none end)
  end

  defp task(id) do
    %Task{
      id: id,
      identifier: "SYM-MERGE-WORKER",
      number: 1,
      project_id: "symphony",
      title: "Merge worker",
      type: :feature,
      branch: "feature/merge-worker",
      priority: :normal,
      brief: "brief",
      acceptance_criteria: [],
      column_id: "merging",
      rank: 1_024,
      revision: 1,
      created_at: "2026-07-16T00:00:00Z",
      updated_at: "2026-07-16T00:00:00Z"
    }
  end

  defp eventually(assertion, attempts \\ 100)

  defp eventually(assertion, attempts) when attempts > 0 do
    if assertion.() do
      :ok
    else
      Process.sleep(10)
      eventually(assertion, attempts - 1)
    end
  end

  defp eventually(assertion, 0), do: assert(assertion.())

  defp release_and_wait(pid) do
    ref = Process.monitor(pid)
    send(pid, :release)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      2_000 -> flunk("merge worker did not stop during test cleanup")
    end
  end
end
