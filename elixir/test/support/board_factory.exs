defmodule SymphonyElixir.BoardFactory do
  alias SymphonyElixir.Board
  alias SymphonyElixir.Board.Commands
  alias SymphonyElixir.Workflow

  def unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}-#{Ecto.UUID.generate()}"

  def create_task(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          title: unique("Task"),
          type: "Feature",
          priority: "Normal",
          brief: "A complete Markdown brief.",
          acceptance_criteria: ["The behavior is verified."]
        },
        overrides
      )

    key = unique("create")

    {:ok, %{"task" => task}} =
      Board.execute(%Commands.CreateTask{attrs: attrs},
        actor: %{type: :human, identity: "test"},
        expected_revision: 0,
        idempotency_key: key
      )

    {task, key}
  end

  def move(task, column_id, actor \\ :human) do
    {:ok, %{"task" => updated} = result} =
      Board.execute(%Commands.MoveTask{task_id: task["id"], column_id: column_id},
        actor: actor,
        expected_revision: task["revision"],
        idempotency_key: unique("move")
      )

    {updated, result}
  end

  def workflow_source do
    root = Path.join(System.tmp_dir!(), unique("symphony-workflow"))
    remote = root <> "-remote.git"
    File.mkdir_p!(root)

    {_, 0} = System.cmd("git", ["init", "--bare", "--initial-branch=main", remote], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["init", "--initial-branch=main", root], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["-C", root, "remote", "add", "origin", remote], stderr_to_stdout: true)

    source_root = File.cwd!()
    workflow = File.read!(Path.join(source_root, "WORKFLOW.yml"))
    unique_concurrency = 1_000 + System.unique_integer([:positive, :monotonic])
    workflow = String.replace(workflow, "max_concurrent_agents: 10", "max_concurrent_agents: #{unique_concurrency}")
    workflow = Regex.replace(~r/hooks:\n(?:  .+\n?)+\z/, workflow, "hooks:\n")
    File.write!(Path.join(root, "WORKFLOW.yml"), workflow)
    File.cp_r!(Path.join(source_root, "workflow"), Path.join(root, "workflow"))
    File.write!(Path.join(root, "sample.txt"), "sample\n")

    git!(root, ["add", "."])
    git!(root, ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "initial"])
    git!(root, ["push", "-u", "origin", "main"])
    {_, 0} = System.cmd("git", ["--git-dir", remote, "symbolic-ref", "HEAD", "refs/heads/main"], stderr_to_stdout: true)
    git!(root, ["remote", "set-head", "origin", "main"])

    {:ok, canonical_root} = SymphonyElixir.PathSafety.canonicalize(root)
    %{root: canonical_root, remote: remote, workflow: Path.join(root, "WORKFLOW.yml")}
  end

  def git!(root, args) do
    case System.cmd("git", ["-C", root | args], stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise "git failed (#{status}): #{output}"
    end
  end

  @doc """
  Wait until the workflow store has activated the latest valid bundle.

  `Workflow.Store.force_reload/0` defers activation while the board is busy,
  so a test that proceeds to claim/dispatch immediately after a reload can
  otherwise observe the previous bundle.
  """
  def await_activation(attempts \\ 200) do
    status = Workflow.Store.status()

    cond do
      status[:valid] == true and status[:pending] == false ->
        :ok

      attempts <= 0 ->
        raise "workflow activation timed out"

      true ->
        Process.sleep(20)
        await_activation(attempts - 1)
    end
  end
end
