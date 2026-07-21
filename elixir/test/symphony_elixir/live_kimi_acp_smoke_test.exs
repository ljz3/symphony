defmodule SymphonyElixir.LiveKimiACPSmokeTest do
  @moduledoc """
  Opt-in smoke test against a real `kimi` CLI in ACP mode.

  Requires the `kimi` executable on PATH and a completed `kimi login`. Run with:

      SYMPHONY_RUN_LIVE_KIMI=1 mix test --only live_kimi

  It is excluded from the normal deterministic suite.
  """

  use ExUnit.Case, async: false

  alias SymphonyElixir.Backend.KimiACP
  alias SymphonyElixir.{BoardFactory, HttpServer, Paths, Task, Workflow}

  @moduletag :live_kimi
  @moduletag timeout: 300_000

  setup do
    if is_nil(System.find_executable("kimi")) do
      raise "kimi CLI not found on PATH; install it and run `kimi login` before the live smoke test"
    end

    original_workflow = Workflow.workflow_file_path()
    source = BoardFactory.workflow_source()

    workflow =
      source.workflow
      |> File.read!()
      |> then(
        &Regex.replace(~r/codex:\n(?:  .+\n)+(?=\nprompts:)/, &1, """
        backends:
          kimi:
            protocol: acp
            command: kimi acp
            allow_unsandboxed: true
        """)
      )
      |> String.replace(
        "    allowed_model_efforts:\n      gpt-5.5: [xhigh]\n",
        """
            allowed_models:
              - {backend: kimi, model: kimi-code/kimi-for-coding}
        """
      )

    File.write!(source.workflow, workflow)
    Workflow.set_workflow_file_path(source.workflow)
    assert :ok = Workflow.Store.force_reload()
    BoardFactory.await_activation()

    start_supervised!({HttpServer, port: 0})

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow)
      Workflow.Store.force_reload()
    end)

    :ok
  end

  test "a real kimi acp session is configured and answers a trivial prompt" do
    workspace = Path.join(Paths.worktrees_root("symphony"), BoardFactory.unique("live-kimi"))
    File.mkdir_p!(workspace)
    run_id = BoardFactory.unique("live-run")

    assert {:ok, session} =
             KimiACP.start_session(workspace,
               backend: "kimi",
               run_id: run_id,
               model: nil,
               effort: nil
             )

    assert is_binary(session.session_id)

    task = %Task{
      id: "live-task",
      identifier: "SYM-LIVE",
      number: 1,
      project_id: "symphony",
      title: "Live smoke",
      type: :feature,
      branch: "feature/SYM-LIVE",
      priority: :normal,
      brief: "brief",
      acceptance_criteria: [],
      column_id: "in_progress",
      rank: 1,
      revision: 1,
      created_at: "now",
      updated_at: "now"
    }

    assert {:ok, %{stop_reason: :end_turn}} =
             KimiACP.prompt(session, "Reply with exactly: ok", task, [])

    assert :ok = KimiACP.stop_session(session)
    assert :ok = KimiACP.stop_session(session)
  end
end
