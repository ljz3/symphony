defmodule SymphonyElixir.OrchestratorPreflightTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Board, BoardFactory, Orchestrator, Workflow}
  alias SymphonyElixir.Board.Commands

  setup do
    original_workflow = Workflow.workflow_file_path()
    original_path = System.get_env("PATH")
    source = BoardFactory.workflow_source()
    fake_bin = Path.join(source.root, "preflight-fake-bin")
    File.mkdir_p!(fake_bin)
    File.write!(Path.join(fake_bin, "gh"), fake_gh())
    File.chmod!(Path.join(fake_bin, "gh"), 0o755)

    github_url = "https://github.test/owner/repo.git"
    rewrite_key = "url.file://#{source.remote}.insteadOf"
    BoardFactory.git!(source.root, ["config", rewrite_key, github_url])
    BoardFactory.git!(source.root, ["remote", "set-url", "origin", github_url])

    System.put_env("PATH", fake_bin <> ":" <> original_path)
    Workflow.set_workflow_file_path(source.workflow)
    assert :ok = Workflow.Store.force_reload()
    BoardFactory.await_activation()

    on_exit(fn ->
      System.put_env("PATH", original_path)
      Workflow.set_workflow_file_path(original_workflow)
      Workflow.Store.force_reload()
    end)

    %{source: source, fake_bin: fake_bin}
  end

  @tag timeout: 20_000
  test "a long probe holds one reservation, creates no run, and task movement cancels it", %{source: source} do
    state_dir = fixture_dir(source, "long")
    attempts = Path.join(state_dir, "attempts")
    process_id = Path.join(state_dir, "pid")
    release = Path.join(state_dir, "release")

    command = """
    mkdir -p #{shell_escape(state_dir)}
    printf x >> #{shell_escape(attempts)}
    printf %s $$ > #{shell_escape(process_id)}
    while [ ! -f #{shell_escape(release)} ]; do sleep 0.05; done
    """

    {todo, _backlog} = queued_task("Long preflight")
    todo_id = todo["id"]
    configure_preflight(source, command, retry_after_failure_ms: 250, concurrency: 1)
    orchestrator = start_gate([todo_id])

    eventually(fn -> attempt_count(attempts) == 1 end)
    eventually(fn -> match?([%{task_id: ^todo_id, status: :running}], status(orchestrator).preflights) end)
    assert Board.runs(todo_id) == []

    Enum.each(1..8, fn _ -> send(orchestrator, :reconcile) end)
    Process.sleep(300)
    assert attempt_count(attempts) == 1
    assert Board.runs(todo_id) == []

    pid = process_id |> File.read!() |> String.trim() |> String.to_integer()
    {_backlog, _result} = BoardFactory.move(todo, "backlog")

    eventually(fn -> Enum.all?(status(orchestrator).preflights, &(&1.task_id != todo_id)) end)
    eventually(fn -> not os_process_alive?(pid) end)
    assert Board.runs(todo_id) == []
  end

  @tag timeout: 15_000
  test "an unchanged task notification preserves the active probe and claims once", %{source: source} do
    state_dir = fixture_dir(source, "unchanged-active")
    attempts = Path.join(state_dir, "attempts")
    release = Path.join(state_dir, "release")

    command = """
    mkdir -p #{shell_escape(state_dir)}
    printf x >> #{shell_escape(attempts)}
    while [ ! -f #{shell_escape(release)} ]; do sleep 0.05; done
    """

    {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Unchanged notification")})
    {todo, _result} = BoardFactory.move(created, "todo")

    assert {:ok, %{"task" => claimed, "run" => prior_run}} =
             Board.execute(%Commands.ClaimRun{task_id: todo["id"]},
               actor: :system,
               expected_revision: todo["revision"],
               idempotency_key: BoardFactory.unique("unchanged-prior-claim")
             )

    {review, _result} = BoardFactory.move(claimed, "automated_review", :agent)

    assert {:ok, %{"task" => current, "run" => completed_run}} =
             Board.execute(
               %Commands.RunFinished{
                 task_id: review["id"],
                 run_id: prior_run["id"],
                 outcome: %{},
                 stats: %{"turn_count" => 1, "token_usage" => nil}
               },
               actor: :system,
               expected_revision: review["revision"],
               idempotency_key: BoardFactory.unique("unchanged-prior-finish")
             )

    todo_id = current["id"]
    configure_preflight(source, command, retry_after_failure_ms: 250, concurrency: 1)
    orchestrator = start_gate([todo_id])
    on_exit(fn -> File.touch(release) end)

    eventually(fn -> attempt_count(attempts) == 1 end)
    eventually(fn -> match?([%{task_id: ^todo_id, status: :running}], status(orchestrator).preflights) end)

    assert {:ok, %{"run" => published_run}} =
             Board.execute(
               %Commands.RecordRunStatsPublication{
                 task_id: todo_id,
                 run_id: completed_run["id"],
                 destination: "pr_body",
                 publication_id: BoardFactory.unique("stats-publication")
               },
               actor: :system,
               expected_revision: current["revision"],
               idempotency_key: BoardFactory.unique("unchanged-stats-event")
             )

    assert published_run["stats_publication"]["destination"] == "pr_body"
    Process.sleep(350)

    assert attempt_count(attempts) == 1
    assert match?([%{task_id: ^todo_id, status: :running}], status(orchestrator).preflights)

    File.touch!(release)
    eventually(fn -> length(Board.runs(todo_id)) == 2 end)
    assert_no_active_run(todo_id)
    assert attempt_count(attempts) == 1
    assert length(Board.runs(todo_id)) == 2
  end

  @tag timeout: 15_000
  test "task movement cancels worktree preparation before the command starts", %{source: source} do
    state_dir = fixture_dir(source, "preparation")
    process_id = Path.join(state_dir, "pid")
    command_started = Path.join(state_dir, "command-started")

    after_create = """
    mkdir -p #{shell_escape(state_dir)}
    printf %s $$ > #{shell_escape(process_id)}
    exec sleep 600
    """

    {todo, _backlog} = queued_task("Preparation cancellation")
    todo_id = todo["id"]

    configure_preflight(
      source,
      "touch #{shell_escape(command_started)}",
      retry_after_failure_ms: 250,
      concurrency: 1,
      after_create: after_create
    )

    orchestrator = start_gate([todo_id])
    eventually(fn -> File.exists?(process_id) end)

    eventually(fn ->
      match?([%{task_id: ^todo_id, phase: :preparing_worktree}], status(orchestrator).preflights)
    end)

    pid = process_id |> File.read!() |> String.trim() |> String.to_integer()
    {_backlog, _result} = BoardFactory.move(todo, "backlog")

    eventually(fn -> Enum.all?(status(orchestrator).preflights, &(&1.task_id != todo_id)) end)
    eventually(fn -> not os_process_alive?(pid) end)
    refute File.exists?(command_started)
    assert Board.runs(todo_id) == []
  end

  @tag timeout: 20_000
  test "failure stays queued until its retry delay while another task claims exactly once", %{source: source} do
    state_dir = fixture_dir(source, "failure")
    attempts = Path.join(state_dir, "attempts")
    {failing, _backlog} = queued_task("Failing preflight")
    {passing, _backlog} = queued_task("Passing preflight")
    failing_id = failing["id"]
    passing_id = passing["id"]

    command = """
    mkdir -p #{shell_escape(state_dir)}
    if [ "$SYMPHONY_TASK_IDENTIFIER" = #{shell_escape(failing["identifier"])} ]; then
      printf x >> #{shell_escape(attempts)}
      printf 'configuration unavailable\n'
      exit 7
    fi
    sleep 0.2
    """

    configure_preflight(source, command, retry_after_failure_ms: 5_000, concurrency: 1)
    orchestrator = start_gate([failing_id, passing_id])

    eventually(fn -> length(Board.runs(passing_id)) == 1 end)

    eventually(fn ->
      Enum.any?(status(orchestrator).preflights, fn
        %{
          task_id: ^failing_id,
          status: :failed,
          reason: "exit_status_7: configuration unavailable"
        } ->
          true

        _ ->
          false
      end)
    end)

    assert attempt_count(attempts) == 1
    first_failure = Enum.find(status(orchestrator).preflights, &(&1.task_id == failing_id))

    send(orchestrator, {:task_changed, failing_id})
    Process.sleep(350)

    assert attempt_count(attempts) == 1
    assert Enum.find(status(orchestrator).preflights, &(&1.task_id == failing_id)) == first_failure
    assert Board.runs(failing_id) == []
    assert {:ok, failing_task} = Board.task(failing_id)
    assert failing_task.column_id == "todo"

    Enum.each(1..5, fn _ -> send(orchestrator, :reconcile) end)
    Process.sleep(400)
    assert attempt_count(attempts) == 1

    eventually(fn -> attempt_count(attempts) >= 2 end, 200)

    eventually(fn ->
      case Enum.filter(status(orchestrator).preflights, &(&1.task_id == failing_id)) do
        [%{status: :failed, fingerprint: fingerprint}] -> fingerprint == first_failure.fingerprint
        _ -> false
      end
    end)

    Process.sleep(1_100)
    assert length(Board.runs(passing_id)) == 1
    eventually(fn -> match?({:ok, %{runtime_state: nil}}, Board.task(passing_id)) end)
  end

  @tag timeout: 20_000
  test "silent SSH health probing is asynchronous and direct dispatch waits for explicit health", %{
    source: source,
    fake_bin: fake_bin
  } do
    state_dir = fixture_dir(source, "worker-health")
    started = Path.join(state_dir, "started")
    process_id = Path.join(state_dir, "pid")
    release = Path.join(state_dir, "release")
    completed = Path.join(state_dir, "completed")

    File.write!(
      Path.join(fake_bin, "ssh"),
      fake_ssh(started: started, process_id: process_id, release: release, completed: completed)
    )

    File.chmod!(Path.join(fake_bin, "ssh"), 0o755)
    configure_workers_without_preflight(source, "silent-worker")
    {todo, _backlog} = queued_task("Asynchronous worker health")
    todo_id = todo["id"]
    orchestrator = start_gate([todo_id])
    on_exit(fn -> File.touch(release) end)

    eventually(fn -> File.exists?(started) and File.exists?(process_id) end)
    probe_pid = process_id |> File.read!() |> String.trim() |> String.to_integer()
    parent = self()
    spawn(fn -> send(parent, {:responsive_status, status(orchestrator)}) end)

    assert_receive {:responsive_status, %{worker_health: [%{host: "silent-worker", status: :probing}]}}, 2_000
    assert Board.runs(todo_id) == []

    Process.sleep(5_200)
    assert os_process_alive?(probe_pid)
    assert match?([%{host: "silent-worker", status: :probing}], status(orchestrator).worker_health)

    {backlog, _result} = BoardFactory.move(todo, "backlog")
    eventually(fn -> match?({:ok, %{column_id: "backlog"}}, Board.task(todo_id)) end)
    assert status(orchestrator).online
    assert Board.runs(todo_id) == []

    configure_workers_without_preflight(source, nil)
    eventually(fn -> not os_process_alive?(probe_pid) end)
    eventually(fn -> status(orchestrator).worker_health == [] end)

    File.touch!(release)
    configure_workers_without_preflight(source, "silent-worker")
    {_todo, _result} = BoardFactory.move(backlog, "todo")
    eventually(fn -> File.exists?(completed) end)
    eventually(fn -> length(Board.runs(todo_id)) == 1 end)
    assert_no_active_run(todo_id)
    assert length(Board.runs(todo_id)) == 1
  end

  @tag timeout: 10_000
  test "worker health failure is current and retries only after terminal failure", %{
    source: source,
    fake_bin: fake_bin
  } do
    state_dir = fixture_dir(source, "worker-unhealthy")
    attempts = Path.join(state_dir, "attempts")

    File.write!(
      Path.join(fake_bin, "ssh"),
      "#!/bin/sh\nmkdir -p #{shell_escape(state_dir)}\nprintf x >> #{shell_escape(attempts)}\nexit 9\n"
    )

    File.chmod!(Path.join(fake_bin, "ssh"), 0o755)
    configure_workers_without_preflight(source, "failing-worker")
    {todo, _backlog} = queued_task("Failed worker health")
    orchestrator = start_gate([todo["id"]])

    eventually(fn ->
      match?(
        [%{host: "failing-worker", status: :unhealthy, reason: "exit_status_9", next_retry_at: retry}]
        when is_binary(retry),
        status(orchestrator).worker_health
      )
    end)

    assert attempt_count(attempts) == 1
    assert Board.runs(todo["id"]) == []
    assert status(orchestrator).online
    Process.sleep(500)
    assert attempt_count(attempts) == 1
  end

  @tag timeout: 20_000
  test "a revision change discards stale success and starts a fresh probe", %{source: source} do
    state_dir = fixture_dir(source, "revision")
    attempts = Path.join(state_dir, "attempts")
    {todo, _backlog} = queued_task("Revision preflight")

    command = """
    mkdir -p #{shell_escape(state_dir)}
    attempt=$(( $(wc -c < #{shell_escape(attempts)} 2>/dev/null || printf 0) + 1 ))
    printf x >> #{shell_escape(attempts)}
    while [ ! -f #{shell_escape(Path.join(state_dir, "release"))}-$attempt ]; do sleep 0.05; done
    """

    configure_preflight(source, command, retry_after_failure_ms: 250, concurrency: 1)
    _orchestrator = start_gate([todo["id"]])
    eventually(fn -> attempt_count(attempts) == 1 end)

    assert {:ok, %{"task" => updated}} =
             Board.execute(
               %Commands.UpdateTask{task_id: todo["id"], attrs: %{title: "Revision changed while probing"}},
               actor: %{type: :human, identity: "preflight-test"},
               expected_revision: todo["revision"],
               idempotency_key: BoardFactory.unique("preflight-revision")
             )

    eventually(fn -> attempt_count(attempts) == 2 end)
    assert updated["revision"] > todo["revision"]
    File.touch!(Path.join(state_dir, "release-1"))
    Process.sleep(250)
    assert Board.runs(todo["id"]) == []

    File.touch!(Path.join(state_dir, "release-2"))
    eventually(fn -> length(Board.runs(todo["id"])) == 1 end)
    eventually(fn -> match?({:ok, %{runtime_state: nil}}, Board.task(todo["id"])) end)
  end

  @tag timeout: 20_000
  test "workflow activation cancels the old hash and service restart reruns the current probe", %{source: source} do
    state_dir = fixture_dir(source, "workflow")
    old_started = Path.join(state_dir, "old-started")
    old_pid_file = Path.join(state_dir, "old-pid")
    old_release = Path.join(state_dir, "old-release")
    new_attempts = Path.join(state_dir, "new-attempts")
    new_pids = Path.join(state_dir, "new-pids")
    new_release = Path.join(state_dir, "new-release")
    {todo, _backlog} = queued_task("Workflow preflight")

    old_command = """
    mkdir -p #{shell_escape(state_dir)}
    touch #{shell_escape(old_started)}
    printf %s $$ > #{shell_escape(old_pid_file)}
    while [ ! -f #{shell_escape(old_release)} ]; do sleep 0.05; done
    """

    configure_preflight(source, old_command, retry_after_failure_ms: 250, concurrency: 1)
    orchestrator = start_gate([todo["id"]])
    eventually(fn -> File.exists?(old_started) end)
    [%{workflow_hash: old_hash}] = status(orchestrator).preflights
    old_pid = old_pid_file |> File.read!() |> String.trim() |> String.to_integer()

    new_command = """
    mkdir -p #{shell_escape(state_dir)}
    printf x >> #{shell_escape(new_attempts)}
    printf '%s\n' $$ >> #{shell_escape(new_pids)}
    while [ ! -f #{shell_escape(new_release)} ]; do sleep 0.05; done
    """

    configure_preflight(source, new_command, retry_after_failure_ms: 250, concurrency: 1)
    eventually(fn -> attempt_count(new_attempts) == 1 end)

    eventually(fn ->
      match?([%{workflow_hash: hash}] when hash != old_hash, status(orchestrator).preflights)
    end)

    eventually(fn -> not os_process_alive?(old_pid) end)
    File.touch!(old_release)
    Process.sleep(200)
    assert Board.runs(todo["id"]) == []

    name = Process.info(orchestrator, :registered_name) |> elem(1)
    Process.exit(orchestrator, :kill)
    eventually(fn -> is_pid(Process.whereis(name)) and Process.whereis(name) != orchestrator end)
    restarted = Process.whereis(name)
    eventually(fn -> attempt_count(new_attempts) == 2 end)
    assert length(status(restarted).preflights) == 1
    assert Board.runs(todo["id"]) == []

    [first_pid | _] = new_pids |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&String.to_integer/1)
    eventually(fn -> not os_process_alive?(first_pid) end)

    File.touch!(new_release)
    eventually(fn -> length(Board.runs(todo["id"])) == 1 end)
    eventually(fn -> match?({:ok, %{runtime_state: nil}}, Board.task(todo["id"])) end)
  end

  defp queued_task(title) do
    {backlog, _key} = BoardFactory.create_task(%{title: BoardFactory.unique(title)})
    {todo, _result} = BoardFactory.move(backlog, "todo")
    {todo, backlog}
  end

  defp configure_preflight(source, command, opts) do
    retry_after_failure_ms = Keyword.fetch!(opts, :retry_after_failure_ms)
    concurrency = Keyword.fetch!(opts, :concurrency)

    workflow = File.read!(source.workflow)

    workflow =
      Regex.replace(~r/^  max_concurrent_agents: \d+$/m, workflow, "  max_concurrent_agents: #{concurrency}")

    workflow = Regex.replace(~r/^  command:.*$/m, workflow, "  command: \"false\"")
    workflow = Regex.replace(~r/\ndispatch:\n.*\z/s, workflow, "")
    workflow = configure_after_create(workflow, Keyword.get(opts, :after_create))

    command_yaml =
      command
      |> String.trim()
      |> String.split("\n")
      |> Enum.map_join("\n", &("      " <> &1))

    dispatch =
      "\ndispatch:\n  preflight:\n    command: |-\n#{command_yaml}\n" <>
        "    retry_after_failure_ms: #{retry_after_failure_ms}\n"

    File.write!(source.workflow, workflow <> dispatch)
    assert :ok = Workflow.Store.force_reload()
    BoardFactory.await_activation()
  end

  defp configure_after_create(workflow, nil), do: workflow

  defp configure_after_create(workflow, command) do
    command_yaml =
      command
      |> String.trim()
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    String.replace(workflow, "hooks:\n", "hooks:\n  after_create: |-\n#{command_yaml}\n")
  end

  defp configure_workers_without_preflight(source, host) do
    workflow = File.read!(source.workflow)
    hosts = if is_binary(host), do: "[#{host}]", else: "[]"
    workflow = Regex.replace(~r/^  ssh_hosts:.*$/m, workflow, "  ssh_hosts: #{hosts}")
    workflow = Regex.replace(~r/^  command:.*$/m, workflow, "  command: \"false\"")
    workflow = Regex.replace(~r/\ndispatch:\n.*\z/s, workflow, "")
    File.write!(source.workflow, workflow)
    assert :ok = Workflow.Store.force_reload()
    BoardFactory.await_activation()
  end

  defp start_gate(task_ids) do
    selected = MapSet.new(task_ids)
    name = Module.concat(__MODULE__, "Gate#{System.unique_integer([:positive, :monotonic])}")

    start_supervised!({
      Orchestrator,
      name: name, dispatch_enabled: true, recover_orphans: false, task_filter: &MapSet.member?(selected, &1.id)
    })
  end

  defp status(orchestrator), do: GenServer.call(orchestrator, :status)

  defp fixture_dir(source, name) do
    path = Path.join(source.root, "preflight-state-#{name}")
    File.mkdir_p!(path)
    path
  end

  defp attempt_count(path) do
    case File.read(path) do
      {:ok, content} -> byte_size(content)
      {:error, :enoent} -> 0
    end
  end

  defp os_process_alive?(pid) do
    match?({_output, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
  end

  defp assert_no_active_run(task_id) do
    eventually(fn ->
      match?({:ok, %{runtime_state: nil, active_run_id: nil}}, Board.task(task_id))
    end)

    assert {:ok, %{runtime_state: nil, active_run_id: nil}} = Board.task(task_id)
  end

  defp eventually(predicate, attempts \\ 160)
  defp eventually(predicate, 0), do: assert(predicate.())

  defp eventually(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(50)
      eventually(predicate, attempts - 1)
    end
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

  defp fake_ssh(opts) do
    started = Keyword.fetch!(opts, :started)
    process_id = Keyword.fetch!(opts, :process_id)
    release = Keyword.fetch!(opts, :release)
    completed = Keyword.fetch!(opts, :completed)

    """
    #!/bin/sh
    set -eu
    if [ ! -f #{shell_escape(completed)} ]; then
      mkdir -p #{shell_escape(Path.dirname(started))}
      touch #{shell_escape(started)}
      printf %s $$ > #{shell_escape(process_id)}
      while [ ! -f #{shell_escape(release)} ]; do sleep 0.05; done
      touch #{shell_escape(completed)}
    fi
    exit 0
    """
  end

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
