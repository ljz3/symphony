defmodule SymphonyElixirWebTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Board
  alias SymphonyElixir.Board.{Commands, Projection}
  alias SymphonyElixir.BoardFactory
  alias SymphonyElixir.HttpServer
  alias SymphonyElixirWeb.Endpoint

  @endpoint Endpoint

  setup do
    start_supervised!(Endpoint)
    :ok
  end

  test "renders the Kanban, task detail, archive, and read-only JSON routes" do
    {task, _} = BoardFactory.create_task(%{title: BoardFactory.unique("Web")})

    board = build_conn() |> get("/")
    assert html_response(board, 200) =~ "Symphony board"
    assert html_response(board, 200) =~ task["title"]

    detail = build_conn() |> get("/tasks/#{task["identifier"]}")
    assert html_response(detail, 200) =~ task["branch"]

    assert html_response(build_conn() |> get("/archive"), 200) =~ "Archive"
    assert html_response(build_conn() |> get("/stats"), 200) =~ "Symphony stats"

    state = build_conn() |> get("/api/v1/state")
    assert json_response(state, 200)["project"] == %{"id" => "symphony", "key" => "SYM"}
    assert get_in(json_response(state, 200), ["stats", "project", "token_usage_state"]) in ["complete", "partial", "unavailable"]

    task_response = build_conn() |> get("/api/v1/tasks/#{task["identifier"]}")
    assert json_response(task_response, 200)["task"]["id"] == task["id"]
    assert json_response(task_response, 200)["stats"]["run_count"] == 0

    assert json_response(build_conn() |> post("/api/v1/state"), 405)["error"]["code"] == "method_not_allowed"
    assert json_response(build_conn() |> post("/api/v1/refresh"), 202) == %{"accepted" => true}
  end

  test "LiveView creation enforces the complete task form" do
    {:ok, view, _html} = live(build_conn(), "/")

    result =
      view
      |> form("#new-task-panel form",
        task: %{
          title: BoardFactory.unique("Created in UI"),
          type: "Chore",
          priority: "High",
          brief: "Created from LiveView.",
          acceptance_criteria: "First criterion\nSecond criterion"
        }
      )
      |> render_submit()

    assert {:error, {:live_redirect, %{to: path}}} = result
    assert path =~ "/tasks/SYM-"
  end

  test "live run telemetry appears in task, stats, board, and JSON surfaces" do
    {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Live telemetry")})
    {todo, _result} = BoardFactory.move(created, "todo")

    assert {:ok, %{"task" => claimed, "run" => run}} =
             Board.execute(%Commands.ClaimRun{task_id: todo["id"]},
               actor: :system,
               expected_revision: todo["revision"],
               idempotency_key: BoardFactory.unique("web-stats-claim")
             )

    assert {:ok, %{"task" => running}} =
             Board.execute(
               %Commands.RunStarted{
                 task_id: claimed["id"],
                 run_id: run["id"],
                 session_id: "thread-web-stats",
                 workspace_path: "/tmp/web-stats"
               },
               actor: :system,
               expected_revision: claimed["revision"],
               idempotency_key: BoardFactory.unique("web-stats-start")
             )

    run_id = run["id"]

    on_exit(fn ->
      case Board.task(running["id"]) do
        {:ok, %{active_run_id: ^run_id} = task} ->
          Board.execute(
            %Commands.RunFailed{task_id: task.id, run_id: run_id, reason: :test_cleanup},
            actor: :system,
            expected_revision: task.revision,
            idempotency_key: BoardFactory.unique("web-stats-on-exit")
          )

        _ ->
          :ok
      end
    end)

    assert :ok =
             Projection.observe_run_telemetry(run["id"], %{
               event: :session_started,
               thread_id: "thread-web-stats",
               turn_id: "turn-web-stats"
             })

    assert :ok =
             Projection.observe_run_telemetry(run["id"], %{
               payload: %{
                 "method" => "thread/tokenUsage/updated",
                 "params" => %{
                   "tokenUsage" => %{
                     "total" => %{
                       "inputTokens" => 900,
                       "cachedInputTokens" => 600,
                       "outputTokens" => 100,
                       "totalTokens" => 1_000
                     }
                   }
                 }
               }
             })

    assert html_response(build_conn() |> get("/"), 200) =~ "1,000"
    stats = html_response(build_conn() |> get("/stats"), 200)
    assert stats =~ "1,000"
    assert stats =~ "Copy ID"
    assert stats =~ "Codex sessions"
    assert stats =~ "Completed tasks"
    assert stats =~ "Usage by model, stage, and effort"
    assert stats =~ run["model"]
    assert stats =~ run["stage_id"]
    assert stats =~ run["effort"]
    assert stats =~ ~s(<th scope="row"><strong>#{run["model"]}</strong>)
    assert stats =~ ~s(aria-label="#{run["model"]}, #{run["stage_id"]} stage")
    assert stats =~ ~s(aria-label="#{run["model"]}, #{run["stage_id"]} stage, #{run["effort"]} effort")

    detail = html_response(build_conn() |> get("/tasks/#{created["identifier"]}"), 200)
    assert detail =~ "1,000"
    assert detail =~ "Copy session ID"

    response = build_conn() |> get("/api/v1/tasks/#{created["identifier"]}") |> json_response(200)
    assert response["stats"]["token_usage"]["total_tokens"] == 1_000
    assert hd(response["runs"])["stats"] == nil
    assert hd(response["runs"])["effective_stats"]["source"] == "live"
    assert hd(response["runs"])["effective_stats"]["token_usage"]["cached_input_tokens"] == 600

    state = build_conn() |> get("/api/v1/state") |> json_response(200)
    model = Enum.find(state["stats"]["models"], &(&1["model"] == run["model"]))
    stage = Enum.find(model["stages"], &(&1["stage_id"] == run["stage_id"]))
    refute Map.has_key?(stage, "efforts")
    assert state["stats"]["counts"]["session_count"] >= 1
    assert model["session_count"] >= 1
    assert model["active_session_count"] >= 1
    assert model["active_run_count"] >= 1
    assert stage["active_session_count"] >= 1
    assert stage["token_usage"]["total_tokens"] >= 1_000

    assert {:ok, _result} =
             Board.execute(
               %Commands.RunFailed{task_id: running["id"], run_id: run["id"], reason: :test_cleanup},
               actor: :system,
               expected_revision: running["revision"],
               idempotency_key: BoardFactory.unique("web-stats-cleanup")
             )
  end

  test "task HTML renders every workpad invocation for completed, failed, and stopped runs without exposing content in JSON" do
    Enum.each(["completed", "failed", "stopped"], fn status ->
      {task, run, contents} = terminal_run_with_workpads(status)
      detail = html_response(build_conn() |> get("/tasks/#{task["identifier"]}"), 200)

      assert detail =~ run["id"]
      assert detail =~ status
      assert detail =~ "Invocation 1"
      assert detail =~ "Invocation 2"
      assert detail =~ Enum.at(contents, 0)
      assert detail =~ Enum.at(contents, 1)

      payload =
        build_conn()
        |> get("/api/v1/tasks/#{task["identifier"]}")
        |> json_response(200)
        |> Jason.encode!()

      Enum.each(contents, &refute(payload =~ &1))
    end)
  end

  test "HTTP startup rejects non-loopback bind addresses" do
    assert {:error, {:non_loopback_http_host, "0.0.0.0"}} =
             HttpServer.start_link(host: "0.0.0.0", port: 0)
  end

  defp terminal_run_with_workpads(status) do
    {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("#{status} HTML workpad")})
    {todo, _result} = BoardFactory.move(created, "todo")

    assert {:ok, %{"task" => claimed, "run" => run}} =
             Board.execute(%Commands.ClaimRun{task_id: todo["id"]},
               actor: :system,
               expected_revision: todo["revision"],
               idempotency_key: BoardFactory.unique("web-workpad-claim")
             )

    contents = ["#{status} invocation one #{run["id"]}", "#{status} invocation two #{run["id"]}"]
    assert :ok = Board.write_workpad(run["id"], 2, Enum.at(contents, 1))
    assert :ok = Board.write_workpad(run["id"], 1, Enum.at(contents, 0))

    terminal_task =
      case status do
        "completed" ->
          assert {:ok, %{"task" => transitioned}} =
                   Board.execute(%Commands.MoveTask{task_id: claimed["id"], column_id: "automated_review"},
                     actor: %{type: :agent, identity: run["id"]},
                     expected_revision: claimed["revision"],
                     idempotency_key: BoardFactory.unique("web-workpad-complete-transition")
                   )

          assert {:ok, %{"task" => completed, "run" => %{"status" => "completed"}}} =
                   Board.execute(%Commands.RunFinished{task_id: transitioned["id"], run_id: run["id"], outcome: %{}},
                     actor: :system,
                     expected_revision: transitioned["revision"],
                     idempotency_key: BoardFactory.unique("web-workpad-complete")
                   )

          completed

        "failed" ->
          assert {:ok, %{"task" => blocked, "run" => %{"status" => "failed"}}} =
                   Board.execute(%Commands.RunFailed{task_id: claimed["id"], run_id: run["id"], reason: :test},
                     actor: :system,
                     expected_revision: claimed["revision"],
                     idempotency_key: BoardFactory.unique("web-workpad-failed")
                   )

          blocked

        "stopped" ->
          assert {:ok, %{"task" => stopping}} =
                   Board.execute(%Commands.MoveTask{task_id: claimed["id"], column_id: "cancelled"},
                     actor: :human,
                     expected_revision: claimed["revision"],
                     idempotency_key: BoardFactory.unique("web-workpad-stop")
                   )

          assert {:ok, %{"task" => stopped, "run" => %{"status" => "stopped"}}} =
                   Board.execute(%Commands.RunFinished{task_id: stopping["id"], run_id: run["id"], outcome: %{}},
                     actor: :system,
                     expected_revision: stopping["revision"],
                     idempotency_key: BoardFactory.unique("web-workpad-stopped")
                   )

          stopped
      end

    {:ok, terminal_run} = Board.run(run["id"])
    {terminal_task, terminal_run, contents}
  end
end
