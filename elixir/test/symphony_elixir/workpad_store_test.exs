defmodule SymphonyElixir.WorkpadStoreTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.Board
  alias SymphonyElixir.Board.{Commands, Projection, WorkpadStore}
  alias SymphonyElixir.BoardFactory
  alias SymphonyElixir.{Paths, Repo}

  test "sidecars restore multiple invocations and hash-matching publication state after projection loss" do
    {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Durable workpad")})
    {todo, _result} = BoardFactory.move(created, "todo")

    assert {:ok, %{"task" => claimed, "run" => run}} =
             Board.execute(%Commands.ClaimRun{task_id: todo["id"]},
               actor: :system,
               expected_revision: todo["revision"],
               idempotency_key: BoardFactory.unique("workpad-claim")
             )

    on_exit(fn -> cleanup_active_run(claimed["id"], run["id"]) end)

    assert :ok = Board.write_workpad(run["id"], 2, "second invocation")
    assert :ok = Board.write_workpad(run["id"], 1, "first invocation")

    workpads = Projection.unpublished_workpads(claimed["id"])
    publication_id = WorkpadStore.publication_id(claimed["id"], workpads)
    assert :ok = WorkpadStore.record_publication(publication_id, workpads)

    record_path =
      Paths.workpads_root("symphony")
      |> Path.join("records")
      |> Path.join(run["id"])
      |> Path.join("1.json")

    manifest_path =
      Paths.workpads_root("symphony")
      |> Path.join("publications")
      |> Path.join(publication_id <> ".json")

    assert File.regular?(record_path)
    assert File.regular?(manifest_path)
    assert Bitwise.band(File.stat!(record_path).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(manifest_path).mode, 0o777) == 0o600

    assert {:ok, _result} = SQL.query(Repo, "DELETE FROM board_workpads WHERE run_id = ?", [run["id"]])
    assert Board.workpads(run["id"]) == []
    assert :ok = WorkpadStore.reconcile()

    restored = Board.workpads(run["id"])
    assert Enum.map(restored, & &1["invocation"]) == [1, 2]
    assert Enum.map(restored, & &1["content"]) == ["first invocation", "second invocation"]
    assert Enum.all?(restored, &(&1["published"] == true))
    assert Enum.all?(restored, &(&1["publication_id"] == publication_id))

    assert :ok = Board.write_workpad(run["id"], 1, "changed first invocation")
    assert [%{"published" => false}] = Enum.filter(Board.workpads(run["id"]), &(&1["invocation"] == 1))

    assert {:ok, _result} = SQL.query(Repo, "DELETE FROM board_workpads WHERE run_id = ?", [run["id"]])
    assert :ok = WorkpadStore.reconcile()

    changed = Enum.find(Board.workpads(run["id"]), &(&1["invocation"] == 1))
    refute changed["published"]
    assert changed["publication_id"] == nil
  end

  test "a malformed sidecar fails store startup with its exact path" do
    root = Path.join(System.tmp_dir!(), "symphony-malformed-workpad-#{Ecto.UUID.generate()}")
    run_id = "malformed-#{Ecto.UUID.generate()}"
    directory = Path.join([root, "records", run_id])
    path = Path.join(directory, "1.json")
    File.mkdir_p!(directory)
    File.write!(path, "{not-json", [:binary])
    name = {:global, {__MODULE__, make_ref()}}
    previous_trap_exit = Process.flag(:trap_exit, true)

    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error, {:malformed_workpad_sidecar, ^path, _reason}} =
             WorkpadStore.start_link(name: name, project_id: "symphony", root: root)

    Process.flag(:trap_exit, previous_trap_exit)
  end

  test "publication IDs ignore timestamps and input order" do
    task_id = Ecto.UUID.generate()

    first = [
      %{run_id: "run-b", invocation: 2, content: "beta", updated_at: "first"},
      %{run_id: "run-a", invocation: 1, content: "alpha", updated_at: "second"}
    ]

    second = [
      %{run_id: "run-a", invocation: 1, content: "alpha", updated_at: "changed"},
      %{run_id: "run-b", invocation: 2, content: "beta", updated_at: "again"}
    ]

    assert WorkpadStore.publication_id(task_id, first) == WorkpadStore.publication_id(task_id, second)
  end

  defp cleanup_active_run(task_id, run_id) do
    case Board.task(task_id) do
      {:ok, %{active_run_id: ^run_id} = task} ->
        Board.execute(%Commands.RunFailed{task_id: task_id, run_id: run_id, reason: :test_cleanup},
          actor: :system,
          expected_revision: task.revision,
          idempotency_key: BoardFactory.unique("workpad-cleanup")
        )

      _ ->
        :ok
    end
  end
end
