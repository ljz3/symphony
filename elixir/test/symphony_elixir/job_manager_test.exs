defmodule SymphonyElixir.JobManagerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.JobManager

  setup do
    workspace = Path.join(System.tmp_dir!(), "symphony-job-#{Ecto.UUID.generate()}")
    File.mkdir_p!(workspace)

    {_, 0} = System.cmd("git", ["init", "--initial-branch=main", workspace], stderr_to_stdout: true)
    File.write!(Path.join(workspace, "tracked.txt"), "source\n")
    git!(workspace, ["add", "."])
    git!(workspace, ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "source"])

    %{workspace: workspace}
  end

  test "returns complete stdout, preserves stderr, literal arguments, and managed identity", %{workspace: workspace} do
    payload = String.duplicate("0123456789abcdef", 12_000)

    script =
      write_script!(workspace, "capture.sh", """
      #!/bin/sh
      set -eu
      printf '%s' "$2"
      printf '%s\\n' "$3" >&2
      printf '\\n%s|%s|%s|%s|%s|%s|%s' \
        "$SYMPHONY_MANAGED_RUN" "$SYMPHONY_JOB_EXECUTOR" "$SYMPHONY_TASK_ID" \
        "$SYMPHONY_TASK_IDENTIFIER" "$SYMPHONY_TASK_BRANCH" "$SYMPHONY_RUN_ID" \
        "$SYMPHONY_JOB_ID"
      """)

    request =
      request(workspace,
        executable: "./#{Path.basename(script)}",
        arguments: ["$SYMPHONY_JOB_ID"],
        passthrough: [payload, "semi; dollar$ parens() wildcard*"],
        environment: %{"CUSTOM_JOB_ENV" => "present"}
      )

    assert {:ok, result} = JobManager.run(request)

    assert Map.keys(result) |> Enum.sort() ==
             ~w(elapsed_ms exit_code finished_at job job_id output output_encoding source_fingerprint started_at status stderr_artifact)

    assert result["status"] == "completed"
    assert result["exit_code"] == 0
    assert result["output_encoding"] == "utf8"
    assert String.starts_with?(result["output"], payload)

    assert result["output"] =~
             "\n1|1|task-id|FOODMAP-1|feature/FOODMAP-1|run-id|#{result["job_id"]}"

    assert File.read!(result["stderr_artifact"]) == "semi; dollar$ parens() wildcard*\n"
    assert byte_size(result["output"]) > 131_072
    assert is_binary(result["source_fingerprint"])
    assert is_binary(result["started_at"])
    assert is_binary(result["finished_at"])
    assert is_integer(result["elapsed_ms"])
  end

  test "reports nonzero exits without mixing stderr into stdout", %{workspace: workspace} do
    write_script!(workspace, "failure.sh", """
    #!/bin/sh
    printf 'useful stdout'
    printf 'actionable stderr' >&2
    exit 23
    """)

    assert {:ok, result} =
             JobManager.run(request(workspace, executable: "./failure.sh", passthrough_policy: :forbidden))

    assert result["status"] == "failed"
    assert result["exit_code"] == 23
    assert result["output"] == "useful stdout"
    assert File.read!(result["stderr_artifact"]) == "actionable stderr"
  end

  test "resolves bare executables through the configured PATH", %{workspace: workspace} do
    bin = Path.join(workspace, "bin")
    File.mkdir_p!(bin)
    name = "project-job-#{System.unique_integer([:positive])}"

    write_script!(bin, name, """
    #!/bin/sh
    printf 'resolved from PATH'
    """)

    assert {:ok, result} =
             JobManager.run(
               request(workspace,
                 executable: name,
                 passthrough_policy: :forbidden,
                 environment: %{"PATH" => bin}
               )
             )

    assert result["status"] == "completed"
    assert result["output"] == "resolved from PATH"
  end

  test "rejects a relative executable that escapes the managed worktree", %{workspace: workspace} do
    assert {:error, {:job_executable_outside_worktree, "../outside"}} =
             JobManager.run(
               request(workspace,
                 executable: "../outside",
                 passthrough_policy: :forbidden
               )
             )
  end

  test "source fingerprint covers every staged, unstaged, binary, renamed, deleted, and untracked byte", %{
    workspace: workspace
  } do
    clean = JobManager.source_fingerprint(workspace, nil)

    File.write!(Path.join(workspace, "tracked.txt"), "unstaged-one\n")
    unstaged_one = JobManager.source_fingerprint(workspace, nil)
    File.write!(Path.join(workspace, "tracked.txt"), "unstaged-two\n")
    unstaged_two = JobManager.source_fingerprint(workspace, nil)

    git!(workspace, ["add", "tracked.txt"])
    staged_one = JobManager.source_fingerprint(workspace, nil)
    File.write!(Path.join(workspace, "tracked.txt"), "staged-two\n")
    git!(workspace, ["add", "tracked.txt"])
    staged_two = JobManager.source_fingerprint(workspace, nil)

    File.write!(Path.join(workspace, "tracked.txt"), <<0, 255, 1>>)
    binary_one = JobManager.source_fingerprint(workspace, nil)
    File.write!(Path.join(workspace, "tracked.txt"), <<0, 254, 1>>)
    binary_two = JobManager.source_fingerprint(workspace, nil)

    git!(workspace, ["restore", "--staged", "tracked.txt"])
    git!(workspace, ["restore", "tracked.txt"])
    tracked_path = Path.join(workspace, "tracked.txt")
    moved_path = Path.join(System.tmp_dir!(), "fingerprint-deleted-#{System.unique_integer([:positive])}")
    File.rename!(tracked_path, moved_path)

    deleted =
      try do
        JobManager.source_fingerprint(workspace, nil)
      after
        File.rename!(moved_path, tracked_path)
      end

    git!(workspace, ["mv", "tracked.txt", "renamed.txt"])
    renamed = JobManager.source_fingerprint(workspace, nil)

    git!(workspace, ["reset", "--hard", "HEAD"])
    untracked_path = Path.join(workspace, "untracked.bin")
    File.write!(untracked_path, <<1, 0, 255>>)
    untracked_one = JobManager.source_fingerprint(workspace, nil)
    File.write!(untracked_path, <<2, 0, 255>>)
    untracked_two = JobManager.source_fingerprint(workspace, nil)

    fingerprints = [
      clean,
      unstaged_one,
      unstaged_two,
      staged_one,
      staged_two,
      binary_one,
      binary_two,
      deleted,
      renamed,
      untracked_one,
      untracked_two
    ]

    assert Enum.all?(fingerprints, &is_binary/1)
    assert Enum.uniq(fingerprints) == fingerprints
  end

  test "runs on a configured worker and returns remote artifacts locally", %{workspace: workspace} do
    original_path = System.get_env("PATH")
    fake_bin = Path.join(workspace, "fake-ssh-bin")
    File.mkdir_p!(fake_bin)

    write_script!(fake_bin, "ssh", """
    #!/bin/sh
    for argument in "$@"; do command=$argument; done
    exec /bin/sh -c "$command"
    """)

    write_script!(workspace, "remote.sh", """
    #!/bin/sh
    printf 'remote:%s' "$1"
    printf 'remote stderr' >&2
    """)

    System.put_env("PATH", fake_bin <> ":" <> original_path)
    on_exit(fn -> System.put_env("PATH", original_path) end)

    request =
      request(workspace, executable: "./remote.sh", passthrough: ["literal;value"])
      |> Map.put(:worker_host, "fake-worker")

    assert {:ok, result} = JobManager.run(request)
    assert result["status"] == "completed"
    assert result["output"] == "remote:literal;value"
    assert File.read!(result["stderr_artifact"]) == "remote stderr"
  end

  test "remote execution resolves the project command with a project-only PATH", %{workspace: workspace} do
    original_path = System.get_env("PATH")
    fake_bin = Path.join(workspace, "path-fake-ssh")
    project_bin = Path.join(workspace, "project-bin")
    File.mkdir_p!(fake_bin)
    File.mkdir_p!(project_bin)

    write_script!(fake_bin, "ssh", """
    #!/bin/sh
    for argument in "$@"; do command=$argument; done
    exec /bin/sh -c "$command"
    """)

    name = "remote-project-job"

    write_script!(project_bin, name, """
    #!/bin/sh
    printf 'project PATH works'
    """)

    System.put_env("PATH", fake_bin <> ":" <> original_path)
    on_exit(fn -> System.put_env("PATH", original_path) end)

    request =
      request(workspace,
        executable: name,
        passthrough_policy: :forbidden,
        environment: %{"PATH" => project_bin}
      )
      |> Map.put(:worker_host, "fake-worker")

    assert {:ok, result} = JobManager.run(request)
    assert result["status"] == "completed"
    assert result["output"] == "project PATH works"
  end

  @tag timeout: 15_000
  test "cancel before a remote child control line still reaches terminal cancelled", %{workspace: workspace} do
    original_path = System.get_env("PATH")
    fake_bin = Path.join(workspace, "silent-fake-ssh")
    ssh_pid = Path.join(workspace, "silent-ssh.pid")
    File.mkdir_p!(fake_bin)

    write_script!(fake_bin, "ssh", """
    #!/bin/sh
    printf '%s' "$$" > "$FAKE_SSH_PID_FILE"
    exec /bin/sleep 300
    """)

    System.put_env("PATH", fake_bin <> ":" <> original_path)
    System.put_env("FAKE_SSH_PID_FILE", ssh_pid)

    on_exit(fn ->
      System.put_env("PATH", original_path)
      System.delete_env("FAKE_SSH_PID_FILE")
      kill_pid_file(ssh_pid)
    end)

    run_id = "cancel-before-child-#{Ecto.UUID.generate()}"

    request =
      request(workspace, executable: "./never-runs", passthrough_policy: :forbidden)
      |> Map.put(:run_id, run_id)
      |> Map.put(:worker_host, "silent-worker")

    job = Task.async(fn -> JobManager.run(request) end)
    eventually(fn -> File.exists?(ssh_pid) end)
    transport_pid = ssh_pid |> File.read!() |> String.trim()
    assert process_alive?(transport_pid)
    assert :ok = JobManager.cancel_run(run_id)
    assert {:ok, {:ok, result}} = Task.yield(job, 8_000)
    assert result["status"] == "cancelled"
    eventually(fn -> not process_alive?(transport_pid) end)
  end

  @tag timeout: 30_000
  test "a hanging remote TERM signal cannot block force escalation or descendant cleanup", %{workspace: workspace} do
    original_path = System.get_env("PATH")
    fake_bin = Path.join(workspace, "hanging-signal-ssh")
    signal_pid = Path.join(workspace, "signal-ssh.pid")
    child_pid_path = Path.join(workspace, "remote-child.pid")
    File.mkdir_p!(fake_bin)

    write_script!(fake_bin, "ssh", """
    #!/bin/sh
    for argument in "$@"; do command=$argument; done
    case "$command" in
      *"kill -TERM"*)
        printf '%s' "$$" > "$FAKE_SIGNAL_PID_FILE"
        exec /bin/sleep 300
        ;;
      *) exec /bin/sh -c "$command" ;;
    esac
    """)

    write_script!(workspace, "remote-tree.sh", """
    #!/bin/sh
    sleep 300 &
    child=$!
    printf '%s' "$child" > "$1"
    wait "$child"
    """)

    System.put_env("PATH", fake_bin <> ":" <> original_path)
    System.put_env("FAKE_SIGNAL_PID_FILE", signal_pid)

    on_exit(fn ->
      System.put_env("PATH", original_path)
      System.delete_env("FAKE_SIGNAL_PID_FILE")
      kill_pid_file(signal_pid)
      kill_pid_file(child_pid_path)
    end)

    run_id = "hanging-signal-#{Ecto.UUID.generate()}"

    request =
      request(workspace, executable: "./remote-tree.sh", passthrough: [child_pid_path])
      |> Map.put(:run_id, run_id)
      |> Map.put(:worker_host, "signal-worker")

    job = Task.async(fn -> JobManager.run(request) end)
    eventually(fn -> File.exists?(child_pid_path) end, 400)
    child_pid = child_pid_path |> File.read!() |> String.trim()
    assert process_alive?(child_pid)
    assert :ok = JobManager.cancel_run(run_id)
    eventually(fn -> File.exists?(signal_pid) end)

    assert {:ok, {:ok, result}} = Task.yield(job, 8_000)
    assert result["status"] == "cancelled"
    eventually(fn -> not process_alive?(child_pid) end, 400)
  end

  @tag timeout: 30_000
  test "a failed remote TERM signal cannot prevent force escalation or descendant cleanup", %{
    workspace: workspace
  } do
    original_path = System.get_env("PATH")
    fake_bin = Path.join(workspace, "failed-signal-ssh")
    signal_marker = Path.join(workspace, "failed-signal-attempted")
    child_pid_path = Path.join(workspace, "failed-signal-child.pid")
    File.mkdir_p!(fake_bin)

    write_script!(fake_bin, "ssh", """
    #!/bin/sh
    for argument in "$@"; do command=$argument; done
    case "$command" in
      *"kill -TERM"*)
        printf attempted > "$FAKE_SIGNAL_MARKER"
        exit 47
        ;;
      *) exec /bin/sh -c "$command" ;;
    esac
    """)

    write_script!(workspace, "failed-signal-tree.sh", """
    #!/bin/sh
    sleep 300 &
    child=$!
    printf '%s' "$child" > "$1"
    wait "$child"
    """)

    System.put_env("PATH", fake_bin <> ":" <> original_path)
    System.put_env("FAKE_SIGNAL_MARKER", signal_marker)

    on_exit(fn ->
      System.put_env("PATH", original_path)
      System.delete_env("FAKE_SIGNAL_MARKER")
      kill_pid_file(child_pid_path)
    end)

    run_id = "failed-signal-#{Ecto.UUID.generate()}"

    request =
      request(workspace, executable: "./failed-signal-tree.sh", passthrough: [child_pid_path])
      |> Map.put(:run_id, run_id)
      |> Map.put(:worker_host, "failed-signal-worker")

    job = Task.async(fn -> JobManager.run(request) end)
    eventually(fn -> File.exists?(child_pid_path) end, 400)
    child_pid = child_pid_path |> File.read!() |> String.trim()
    assert process_alive?(child_pid)
    assert :ok = JobManager.cancel_run(run_id)
    eventually(fn -> File.exists?(signal_marker) end)

    assert {:ok, {:ok, result}} = Task.yield(job, 8_000)
    assert result["status"] == "cancelled"
    eventually(fn -> not process_alive?(child_pid) end, 400)
  end

  test "encodes invalid UTF-8 stdout losslessly instead of truncating or raising", %{workspace: workspace} do
    write_script!(workspace, "binary-output.sh", """
    #!/bin/sh
    printf '\\377\\000A'
    """)

    assert {:ok, result} =
             JobManager.run(
               request(workspace,
                 executable: "./binary-output.sh",
                 passthrough_policy: :forbidden
               )
             )

    assert result["status"] == "completed"
    assert result["output_encoding"] == "base64"
    assert {:ok, <<255, 0, 65>>} = Base.decode64(result["output"])
    assert is_binary(Jason.encode!(result))
  end

  test "same call is durable-idempotent and identical active calls single-flight", %{workspace: workspace} do
    fifo = Path.join(workspace, "release.fifo")
    {_, 0} = System.cmd("mkfifo", [fifo])

    write_script!(workspace, "wait.sh", """
    #!/bin/sh
    read -r value < "$1"
    printf '%s' "$value"
    """)

    first = request(workspace, executable: "./wait.sh", passthrough: [fifo], call_id: "call-a")
    second = %{first | call_id: "call-b"}

    task_a = Task.async(fn -> JobManager.run(first) end)
    task_b = Task.async(fn -> JobManager.run(second) end)
    Process.sleep(100)
    assert Task.yield(task_a, 0) == nil
    assert Task.yield(task_b, 0) == nil

    File.write!(fifo, "released\n")
    assert {:ok, {:ok, result_a}} = Task.yield(task_a, 5_000)
    assert {:ok, {:ok, result_b}} = Task.yield(task_b, 5_000)
    assert result_a["job_id"] == result_b["job_id"]
    assert result_a["output"] == "released"

    assert {:ok, duplicate} = JobManager.run(first)
    assert duplicate == result_a
  end

  test "cancelling a run terminates the job process group", %{workspace: workspace} do
    child_pid_path = Path.join(workspace, "child.pid")

    write_script!(workspace, "tree.sh", """
    #!/bin/sh
    sleep 300 &
    child=$!
    printf '%s' "$child" > "$1"
    wait "$child"
    """)

    job =
      Task.async(fn ->
        JobManager.run(request(workspace, executable: "./tree.sh", passthrough: [child_pid_path]))
      end)

    eventually(fn -> File.exists?(child_pid_path) end)
    child_pid = child_pid_path |> File.read!() |> String.trim()
    assert process_alive?(child_pid)

    assert :ok = JobManager.cancel_run("run-id")
    assert {:ok, {:ok, result}} = Task.yield(job, 10_000)
    assert result["status"] == "cancelled"
    refute process_alive?(child_pid)
  end

  test "startup marks unrecoverable running records interrupted", %{workspace: workspace} do
    root = Path.join(workspace, "recovery")
    File.mkdir_p!(Path.join(root, "orphan"))

    File.write!(Path.join(root, "orphan/stdout"), "partial")
    File.write!(Path.join(root, "orphan/stderr"), "")

    File.write!(
      Path.join(root, "orphan/job.json"),
      Jason.encode!(%{
        "format_version" => 1,
        "job_id" => "orphan",
        "job" => "validation",
        "status" => "running",
        "task_id" => "task-id",
        "run_id" => "run-id",
        "call_ids" => ["call-id"],
        "single_flight_key" => "single",
        "stdout_path" => Path.join(root, "orphan/stdout"),
        "stderr_artifact" => Path.join(root, "orphan/stderr"),
        "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "source_fingerprint" => "source"
      })
    )

    name = String.to_atom("job_manager_#{System.unique_integer([:positive])}")
    assert {:ok, pid} = JobManager.start_link(name: name, root: root, worker_supervisor: nil)
    assert {:ok, result} = JobManager.result("run-id", "call-id", name)
    assert result["status"] == "interrupted"
    assert result["output"] == "partial"
    GenServer.stop(pid)
  end

  test "records an interrupted result when spawning cannot begin", %{workspace: workspace} do
    root = Path.join(workspace, "unavailable-supervisor")
    name = String.to_atom("job_manager_#{System.unique_integer([:positive])}")
    assert {:ok, pid} = JobManager.start_link(name: name, root: root, worker_supervisor: nil)

    assert {:ok, result} =
             JobManager.run(
               request(workspace, executable: "./never-started", passthrough_policy: :forbidden),
               name
             )

    assert result["status"] == "interrupted"
    assert result["exit_code"] == nil
    assert {:ok, ^result} = JobManager.result("run-id", result_call_id(root, result["job_id"]), name)
    GenServer.stop(pid)
  end

  defp request(workspace, overrides) do
    passthrough = Keyword.get(overrides, :passthrough, [])

    %{
      task_id: "task-id",
      task_identifier: "FOODMAP-1",
      task_branch: "feature/FOODMAP-1",
      run_id: "run-id",
      call_id: Keyword.get(overrides, :call_id, Ecto.UUID.generate()),
      job: %{
        "id" => "validation",
        "executable" => Keyword.fetch!(overrides, :executable),
        "arguments" => Keyword.get(overrides, :arguments, []),
        "passthrough_arguments" => Keyword.get(overrides, :passthrough_policy, :required),
        "environment" => Keyword.get(overrides, :environment, %{})
      },
      arguments: passthrough,
      workspace: workspace,
      worker_host: nil,
      source_fingerprint: JobManager.source_fingerprint(workspace, nil)
    }
  end

  defp write_script!(workspace, name, content) do
    path = Path.join(workspace, name)
    File.write!(path, content)
    File.chmod!(path, 0o755)
    path
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

  defp process_alive?(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))
  end

  defp kill_pid_file(path) do
    if File.exists?(path) do
      pid = path |> File.read!() |> String.trim()
      System.cmd("kill", ["-KILL", pid], stderr_to_stdout: true)
    end

    :ok
  end

  defp result_call_id(root, job_id) do
    root
    |> Path.join("#{job_id}/job.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("call_ids")
    |> hd()
  end

  defp git!(root, args) do
    case System.cmd("git", ["-C", root | args], stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise "git failed (#{status}): #{output}"
    end
  end
end
