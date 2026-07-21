defmodule SymphonyElixir.ModelCatalogTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Backend.KimiACP
  alias SymphonyElixir.{BoardFactory, Config, ModelCatalog, Workflow}

  test "pairs returns the policy triples when catalogs are disabled" do
    stage = Config.bundle!().stages["implementation"]

    assert ModelCatalog.pairs(stage) == [{"codex", "gpt-5.5", "xhigh"}]
  end

  test "status reports per-backend catalog state" do
    status = ModelCatalog.status()

    # The test environment disables catalog probing entirely.
    assert status["codex"] == %{configured: false, state: :disabled}
  end

  test "pairs and status cover ACP backends when configured" do
    original_workflow = Workflow.workflow_file_path()
    source = BoardFactory.workflow_source()

    workflow =
      source.workflow
      |> File.read!()
      |> then(
        &Regex.replace(~r/codex:\n(?:  .+\n)+(?=\nprompts:)/, &1, """
        backends:
          codex:
            protocol: app_server
            command: codex app-server
          kimi:
            protocol: acp
            command: fake-kimi acp
            allow_unsandboxed: true
        """)
      )
      |> String.replace(
        "    allowed_model_efforts:\n      gpt-5.5: [xhigh]\n",
        """
            allowed_models:
              - {backend: codex, model: gpt-5.5, efforts: [xhigh]}
              - {backend: kimi, model: kimi-code/k3, efforts: [max]}
        """
      )

    File.write!(source.workflow, workflow)
    Workflow.set_workflow_file_path(source.workflow)
    assert :ok = Workflow.Store.force_reload()
    BoardFactory.await_activation()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow)
      Workflow.Store.force_reload()
    end)

    {:ok, expected} = Workflow.load(source.workflow)
    await_activation(expected.hash, 100)

    stage = Config.bundle!().stages["implementation"]

    assert ModelCatalog.pairs(stage) == [{"codex", "gpt-5.5", "xhigh"}, {"kimi", "kimi-code/k3", "max"}]

    # Probing is disabled in the test environment: the ACP catalog reports
    # itself disabled rather than spawning the fake command.
    :ok = KimiACP.Catalog.refresh()
    eventually(fn -> KimiACP.Catalog.status()["kimi"][:state] == :disabled end)

    assert ModelCatalog.status()["kimi"] == %{configured: false, state: :disabled}
  end

  defp await_activation(_hash, 0), do: raise("workflow activation timed out")

  defp await_activation(hash, attempts) do
    case Workflow.current() do
      {:ok, %{hash: ^hash}} ->
        :ok

      _other ->
        Process.sleep(20)
        await_activation(hash, attempts - 1)
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: flunk("condition did not become true")

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
