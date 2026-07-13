defmodule SymphonyElixir.HistoryTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Board.{Event, History}
  alias SymphonyElixir.BoardFactory
  alias SymphonyElixir.Paths

  test "appends immutable events with CAS and replays them in global sequence" do
    project_id = BoardFactory.unique("history")
    first = event(project_id, 1, "first")

    assert {:ok, committed} = History.append(project_id, first, nil)
    assert byte_size(committed.git_oid) == 40
    committed_oid = committed.git_oid

    assert {:error, {:history_head_changed, "wrong", ^committed_oid}} =
             History.append(project_id, event(project_id, 2, "second"), "wrong")

    assert {:ok, [replayed]} = History.events(project_id)
    assert replayed.sequence == 1
    assert replayed.type == "first"
    assert replayed.git_oid == committed.git_oid
  end

  test "detects divergence and preserves the losing local head before taking remote" do
    project_id = BoardFactory.unique("divergence")
    remote = Path.join(System.tmp_dir!(), BoardFactory.unique("board-remote") <> ".git")
    clone = Path.join(System.tmp_dir!(), BoardFactory.unique("board-clone"))
    {_, 0} = System.cmd("git", ["init", "--bare", "--initial-branch=main", remote], stderr_to_stdout: true)

    {:ok, first} = History.append(project_id, event(project_id, 1, "first"), nil)
    assert :ok = History.push(project_id, remote)
    {_, 0} = System.cmd("git", ["clone", remote, clone], stderr_to_stdout: true)

    {:ok, local_second} = History.append(project_id, event(project_id, 2, "local_second"), first.git_oid)
    remote_event = event(project_id, 2, "remote_second")
    path = Path.join(clone, "events/#{String.pad_leading("2", 20, "0")}-#{remote_event.event_id}.json")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Event.encode(remote_event))
    BoardFactory.git!(clone, ["add", "."])
    BoardFactory.git!(clone, ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "remote second"])
    BoardFactory.git!(clone, ["push", "origin", "main"])

    assert %{state: :diverged, ahead: 1, behind: 1} = History.sync_status(project_id, remote)
    assert {:ok, backup_ref} = History.reconcile(project_id, remote, :take_remote)
    assert backup_ref =~ "refs/backups/reconcile/"

    repo = Paths.history_git(project_id)
    {backup_oid, 0} = System.cmd("git", ["--git-dir", repo, "rev-parse", backup_ref], stderr_to_stdout: true)
    assert String.trim(backup_oid) == local_second.git_oid
    assert {:ok, [_first, second]} = History.events(project_id)
    assert second.type == "remote_second"
  end

  defp event(project_id, sequence, type) do
    Event.new(
      sequence: sequence,
      project_id: project_id,
      task_revision: sequence,
      actor: %{type: :system, identity: "test"},
      type: type,
      payload: %{"result" => %{"type" => type}},
      idempotency_key: BoardFactory.unique("key")
    )
  end
end
