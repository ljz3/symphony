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

  test "record v2 preserves the initial template hash and selects only meaningful content" do
    {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Meaningful workpad")})
    run_id = "meaningful-#{Ecto.UUID.generate()}"
    insert_run(run_id, created["id"], "failed", "2026-01-02T00:00:00Z")

    on_exit(fn ->
      SQL.query!(Repo, "DELETE FROM board_workpads WHERE run_id = ?", [run_id])
      SQL.query!(Repo, "DELETE FROM board_runs WHERE id = ?", [run_id])
    end)

    template = "# Generated template\n"
    assert :ok = Board.write_workpad_template(run_id, 1, template)
    assert Board.latest_workpad(created["id"], run_id) == nil

    record_path =
      Paths.workpads_root("symphony")
      |> Path.join("records")
      |> Path.join(run_id)
      |> Path.join("1.json")

    record = record_path |> File.read!() |> Jason.decode!()
    assert record["format_version"] == 2
    assert record["template_sha256"] == sha256(template)

    assert :ok = Board.write_workpad(run_id, 1, template <> "Evidence\n")

    assert %{
             "run_id" => selected_run_id,
             "invocation" => 1,
             "content" => "# Generated template\nEvidence\n"
           } = Board.latest_workpad(created["id"], run_id)

    assert selected_run_id == run_id
    assert [%{"template_sha256" => template_hash}] = Board.workpads(run_id)
    assert template_hash == sha256(template)

    assert {:ok, _result} = SQL.query(Repo, "DELETE FROM board_workpads WHERE run_id = ?", [run_id])
    assert :ok = WorkpadStore.reconcile()

    assert [%{"template_sha256" => ^template_hash}] = Board.workpads(run_id)
    assert File.read!(record_path) |> Jason.decode!() |> Map.fetch!("format_version") == 2
    refute active_run_for?(created["id"])
  end

  test "legacy v1 sidecars remain readable and conservatively meaningful" do
    {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Legacy workpad")})
    run_id = "legacy-#{Ecto.UUID.generate()}"
    insert_run(run_id, created["id"], "failed", "2026-01-02T00:00:00Z")

    on_exit(fn ->
      SQL.query!(Repo, "DELETE FROM board_workpads WHERE run_id = ?", [run_id])
      SQL.query!(Repo, "DELETE FROM board_runs WHERE id = ?", [run_id])
    end)

    assert :ok = Board.write_workpad(run_id, 3, "legacy evidence")

    record_path =
      Paths.workpads_root("symphony")
      |> Path.join("records")
      |> Path.join(run_id)
      |> Path.join("3.json")

    legacy =
      record_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("format_version", 1)
      |> Map.delete("template_sha256")

    File.write!(record_path, Jason.encode!(legacy, pretty: true) <> "\n")
    assert {:ok, _result} = SQL.query(Repo, "DELETE FROM board_workpads WHERE run_id = ?", [run_id])
    assert :ok = WorkpadStore.reconcile()

    assert [%{"template_sha256" => nil}] = Board.workpads(run_id)

    assert %{"invocation" => 3, "content" => "legacy evidence"} =
             Board.latest_workpad(created["id"], run_id)

    assert File.read!(record_path) |> Jason.decode!() |> Map.fetch!("format_version") == 1
    refute active_run_for?(created["id"])
  end

  test "terminal selection orders by finished time, run id, then highest invocation" do
    {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Ordered workpads")})
    suffix = Ecto.UUID.generate()
    current_id = "current-#{suffix}"
    older_id = "a-terminal-#{suffix}"
    selected_id = "z-terminal-#{suffix}"
    active_id = "zz-active-#{suffix}"

    run_ids = [current_id, older_id, selected_id, active_id]

    on_exit(fn ->
      Enum.each(run_ids, fn run_id ->
        SQL.query!(Repo, "DELETE FROM board_workpads WHERE run_id = ?", [run_id])
        SQL.query!(Repo, "DELETE FROM board_runs WHERE id = ?", [run_id])
      end)
    end)

    insert_run(current_id, created["id"], "running", nil)
    insert_run(older_id, created["id"], "failed", "2026-01-01T00:00:00Z")
    insert_run(selected_id, created["id"], "stopped", "2026-01-01T00:00:00Z")
    insert_run(active_id, created["id"], "running", nil)

    assert :ok =
             Projection.put_workpad(%{
               run_id: current_id,
               invocation: 9,
               content: "untouched current",
               template_sha256: sha256("untouched current"),
               updated_at: "2026-01-02T00:00:00Z"
             })

    assert :ok = Projection.put_workpad(workpad(older_id, 8, "older terminal"))
    assert :ok = Projection.put_workpad(workpad(selected_id, 1, "lower invocation"))
    assert :ok = Projection.put_workpad(workpad(selected_id, 4, "selected terminal"))
    assert :ok = Projection.put_workpad(workpad(active_id, 99, "active must not win"))

    assert %{
             "run_id" => ^selected_id,
             "status" => "stopped",
             "invocation" => 4,
             "content" => "selected terminal"
           } = Board.latest_workpad(created["id"], current_id)
  end

  defp cleanup_active_run(task_id, run_id) do
    case Board.task(task_id) do
      {:ok, %{active_run_id: ^run_id} = task} ->
        assert {:ok, _result} =
                 Board.execute(%Commands.RunFailed{task_id: task_id, run_id: run_id, reason: :test_cleanup},
                   actor: :system,
                   expected_revision: task.revision,
                   idempotency_key: BoardFactory.unique("workpad-cleanup")
                 )

        :ok

      _ ->
        :ok
    end
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp active_run_for?(task_id) do
    Enum.any?(Board.runs(task_id), &(&1["status"] in ["starting", "running", "stopping"]))
  end

  defp insert_run(id, task_id, status, finished_at) do
    run = %{
      "id" => id,
      "task_id" => task_id,
      "stage_id" => "implementation",
      "status" => status,
      "finished_at" => finished_at,
      "updated_at" => finished_at || "2026-01-02T00:00:00Z"
    }

    SQL.query!(
      Repo,
      "INSERT INTO board_runs(id, task_id, stage_id, status, run_json, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
      [id, task_id, "implementation", status, Jason.encode!(run), run["updated_at"]]
    )
  end

  defp workpad(run_id, invocation, content) do
    %{
      run_id: run_id,
      invocation: invocation,
      content: content,
      template_sha256: nil,
      updated_at: "2026-01-02T00:00:00Z"
    }
  end
end
