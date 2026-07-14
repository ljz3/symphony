defmodule SymphonyElixir.CLI.StartupErrorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI.StartupError
  alias SymphonyElixir.Repo

  @workflow "/projects/example/WORKFLOW.yml"
  @log "/state/example/runtime/logs/symphony.log"

  test "unwraps the full OTP child path for a port conflict" do
    listener_failure = {:failed_to_start_child, :listener, :eaddrinuse}
    endpoint_failure = {:failed_to_start_child, {SymphonyElixirWeb.Endpoint, :http}, {:shutdown, listener_failure}}
    http_failure = {:failed_to_start_child, SymphonyElixir.HttpServer, {:shutdown, endpoint_failure}}
    reason = application_failure(http_failure)

    message =
      StartupError.format(@workflow, reason,
        port: 4000,
        listener: %{pid: 28_279, command: "beam.smp"},
        log_file: @log
      )

    expected_reason =
      "Reason: Loopback port 4000 is already in use (listener: beam.smp, PID 28279)."

    assert message =~ "Component: HTTP server → HTTP endpoint → TCP listener"
    assert message =~ expected_reason
    assert message =~ "If this is the existing Symphony instance, open http://127.0.0.1:4000/."
    assert message =~ "stop it gracefully with `kill -TERM 28279`"
    assert message =~ "Log: #{@log}"
    refute message =~ "failed_to_start_child"
  end

  test "explains invalid workflow identity failures" do
    identity_failure =
      {:workflow_identity_unavailable, {:workflow_parse_error, "unexpected ':' on line 4"}, :invalid_project_identity}

    reason = application_failure({:failed_to_start_child, SymphonyElixir.Board.Writer, identity_failure})

    message = StartupError.format(@workflow, reason, log_file: @log)

    assert message =~ "Component: Board event writer"
    assert message =~ "WORKFLOW.yml does not provide a usable project identity"
    assert message =~ "YAML parsing failed: unexpected ':' on line 4"
    assert message =~ "Fix `project.id` and `project.key`"
  end

  test "preserves structured database recovery guidance" do
    database = "/state/example/runtime/board.sqlite3"

    exception = %Repo.StartupError{
      database: database,
      reason: {:database_health_indeterminate, database, {:open_failed, :eacces}}
    }

    reason = application_failure({:failed_to_start_child, Repo, {exception, []}})
    message = StartupError.format(@workflow, reason, log_file: @log)

    assert message =~ "Component: SQLite database"

    assert message =~
             "SQLite database #{database} could not be verified safely: open failed: permission denied."

    assert message =~ "Preserve the database, WAL, and SHM files"
    refute message =~ "database_health_indeterminate"
  end

  test "identifies the exact malformed durable sidecar" do
    sidecar = "/state/example/workpads/records/run-1/1.json"
    sidecar_failure = {:malformed_workpad_sidecar, sidecar, :invalid_json}
    reason = application_failure({:failed_to_start_child, SymphonyElixir.Board.WorkpadStore, sidecar_failure})

    message = StartupError.format(@workflow, reason, log_file: @log)

    assert message =~ "Component: Workpad store"
    assert message =~ "Workpad sidecar #{sidecar} is invalid: invalid json."
    assert message =~ "will not overwrite or discard it"
  end

  test "keeps unknown failures concise and points to the log" do
    boot_failure = {:unexpected_boot_failure, {:remote_service, :unavailable}}
    reason = application_failure({:failed_to_start_child, SymphonyElixir.Orchestrator, boot_failure})

    message = StartupError.format(@workflow, reason, log_file: @log)

    assert message =~ "Component: Orchestrator"

    assert message =~
             "Unexpected startup failure: unexpected boot failure: remote service: unavailable."

    assert message =~ "Inspect the startup log for the complete report"
    refute message =~ "failed_to_start_child"
  end

  defp application_failure(failure) do
    {:symphony_elixir, {{:shutdown, failure}, {SymphonyElixir.Application, :start, [:normal, []]}}}
  end
end
