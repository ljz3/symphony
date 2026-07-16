defmodule SymphonyElixirWebTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [put_req_header: 3]

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

  test "renders the Kanban, task detail, archive, and generic former-API 404s" do
    {task, _} = BoardFactory.create_task(%{title: BoardFactory.unique("Web")})

    board = build_conn() |> get("/")
    assert html_response(board, 200) =~ "Symphony board"
    assert html_response(board, 200) =~ task["title"]

    detail = build_conn() |> get("/tasks/#{task["identifier"]}")
    assert html_response(detail, 200) =~ task["branch"]

    assert html_response(build_conn() |> get("/archive"), 200) =~ "Archive"
    assert html_response(build_conn() |> get("/stats"), 200) =~ "Symphony stats"

    former_api_paths = [
      "/api/v1/state",
      "/api/v1/tasks/#{task["identifier"]}",
      "/api/v1/refresh"
    ]

    Enum.each(former_api_paths, fn path ->
      Enum.each([:get, :post, :put, :patch, :delete, :head, :options], fn method ->
        response = former_api_request(method, path)
        assert response.status == 404

        if method != :head do
          assert json_response(response, 404)["error"]["code"] == "not_found"
        end
      end)
    end)
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

  test "live run telemetry appears in task, stats, and board surfaces" do
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

    assert {:ok, _result} =
             Board.execute(
               %Commands.RunFailed{task_id: running["id"], run_id: run["id"], reason: :test_cleanup},
               actor: :system,
               expected_revision: running["revision"],
               idempotency_key: BoardFactory.unique("web-stats-cleanup")
             )
  end

  test "task HTML renders every workpad invocation for completed, failed, and stopped runs" do
    Enum.each(["completed", "failed", "stopped"], fn status ->
      {task, run, contents} = terminal_run_with_workpads(status)
      detail = html_response(build_conn() |> get("/tasks/#{task["identifier"]}"), 200)

      assert detail =~ run["id"]
      assert detail =~ status
      assert detail =~ "Invocation 1"
      assert detail =~ "Invocation 2"
      assert detail =~ Enum.at(contents, 0)
      assert detail =~ Enum.at(contents, 1)
    end)
  end

  test "HTTP startup rejects non-loopback bind addresses" do
    assert {:error, {:non_loopback_http_host, "0.0.0.0"}} =
             HttpServer.start_link(host: "0.0.0.0", port: 0)
  end

  defp former_api_request(:get, path), do: get(build_conn(), path)
  defp former_api_request(:post, path), do: post(json_conn(), path, "{}")
  defp former_api_request(:put, path), do: put(json_conn(), path, "{}")
  defp former_api_request(:patch, path), do: patch(json_conn(), path, "{}")
  defp former_api_request(:delete, path), do: delete(build_conn(), path)
  defp former_api_request(:head, path), do: head(build_conn(), path)
  defp former_api_request(:options, path), do: options(build_conn(), path)

  defp json_conn, do: put_req_header(build_conn(), "content-type", "application/json")

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
