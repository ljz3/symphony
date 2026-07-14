defmodule SymphonyElixir.OrchestratorTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.Task

  test "publication reconciliation skips active workpads and gates only the affected task" do
    bundle = publish_merging_bundle()
    active = task("active", "merging", "active-run")
    failing = task("failing", "merging", nil)
    ready = task("ready", "merging", nil)
    parent = self()

    publisher = fn task ->
      send(parent, {:published, task.id})
      if task.id == failing.id, do: {:error, :github_unavailable}, else: {:ok, "publication"}
    end

    updated =
      Orchestrator.reconcile_workpad_publications(
        struct(State, publication_errors: %{"stale" => :previous_failure}),
        [active, failing, ready],
        bundle,
        publisher
      )

    refute_receive {:published, "active"}
    assert_receive {:published, "failing"}
    assert_receive {:published, "ready"}
    assert updated.publication_errors == %{"failing" => :github_unavailable}

    refute Orchestrator.dispatch_eligible?(failing, bundle, updated)
    assert Orchestrator.dispatch_eligible?(ready, bundle, updated)

    assert {:reply, status, _state} = Orchestrator.handle_call(:status, self(), updated)
    assert status.publication_errors == %{"failing" => :github_unavailable}
  end

  defp publish_merging_bundle do
    bundle = Config.bundle!()

    columns =
      Enum.map(bundle.columns, fn
        %{id: "merging"} = column -> %{column | publish_workpad: true}
        column -> column
      end)

    %{bundle | columns: columns}
  end

  defp task(id, column_id, active_run_id) do
    %Task{
      id: id,
      identifier: "SYM-#{id}",
      number: System.unique_integer([:positive]),
      project_id: "symphony",
      title: id,
      type: :feature,
      branch: "feature/#{id}",
      priority: :normal,
      brief: "brief",
      acceptance_criteria: [],
      column_id: column_id,
      rank: 1_024,
      revision: 1,
      active_run_id: active_run_id,
      runtime_state: if(active_run_id, do: "running"),
      created_at: "now",
      updated_at: "now"
    }
  end
end
