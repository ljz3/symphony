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
             ~w(elapsed_ms exit_code finished_at job job_id output source_fingerprint started_at status stderr_artifact)

    assert result["status"] == "completed"
    assert result["exit_code"] == 0
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
