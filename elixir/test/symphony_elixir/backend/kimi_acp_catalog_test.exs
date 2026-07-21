defmodule SymphonyElixir.Backend.KimiACPCatalogTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Backend.KimiACP
  alias SymphonyElixir.Backend.KimiACP.Catalog, as: KimiCatalog
  alias SymphonyElixir.{BoardFactory, Paths, Workflow}
  alias SymphonyElixir.Codex.Catalog, as: CodexCatalog

  @catalog_fake_env %{
    "FAKE_ACP_MODELS" => ~s(["kimi-code/k3","other"]),
    "FAKE_ACP_THINKING_BY_MODEL" => ~s({"kimi-code/k3":["max"]})
  }

  test "catalog_options learns model and effort pairs from the live agent" do
    ctx = kimi_workflow(@catalog_fake_env)
    workspace = Path.join(Paths.runtime_root("symphony"), BoardFactory.unique("catalog"))

    assert {:ok, [{"kimi-code/k3", "max"}]} =
             KimiACP.catalog_options(workspace, backend: "kimi", models: ["kimi-code/k3"])

    assert {:ok, all_options} = KimiACP.catalog_options(workspace, backend: "kimi", models: [])
    assert Enum.sort(all_options) == Enum.sort([{"kimi-code/k3", "max"}, {"other", nil}])

    session_news =
      ctx.capture
      |> capture_events()
      |> Enum.filter(&(&1["type"] == "session/new"))

    # Each catalog_options call opens one scratch ACP session (no MCP servers).
    assert length(session_news) == 2
    assert Enum.all?(session_news, &(&1["params"]["mcpServers"] == []))
  end

  test "catalog caches probed options and filters model/effort pairs" do
    previous_catalog_enabled = Application.get_env(:symphony_elixir, :catalog_enabled)
    on_exit(fn -> Application.put_env(:symphony_elixir, :catalog_enabled, previous_catalog_enabled) end)
    Application.put_env(:symphony_elixir, :catalog_enabled, true)

    kimi_workflow(@catalog_fake_env, stage_policy: :structured)

    assert is_pid(Process.whereis(KimiCatalog))
    assert :ok = KimiCatalog.refresh()
    eventually(fn -> match?(%{state: :available}, KimiCatalog.status()["kimi"]) end)

    assert KimiCatalog.status()["kimi"][:options] == [{"kimi-code/k3", "max"}]

    triples = [
      {"kimi", "kimi-code/k3", "max"},
      {"kimi", "kimi-code/k3", "low"},
      {"kimi", "other", nil}
    ]

    assert KimiCatalog.pairs("kimi", triples) == [{"kimi", "kimi-code/k3", "max"}]
    assert KimiCatalog.pairs("unknown-backend", triples) == triples

    Application.put_env(:symphony_elixir, :catalog_enabled, false)
    assert :ok = KimiCatalog.refresh()
    eventually(fn -> KimiCatalog.status()["kimi"][:state] == :disabled end)

    assert KimiCatalog.pairs("kimi", triples) == triples
  end

  test "codex catalog stays disabled without spawning codex on a kimi-only workflow" do
    previous_catalog_enabled = Application.get_env(:symphony_elixir, :catalog_enabled)
    on_exit(fn -> Application.put_env(:symphony_elixir, :catalog_enabled, previous_catalog_enabled) end)
    Application.put_env(:symphony_elixir, :catalog_enabled, true)

    kimi_workflow(%{}, include_codex: false, stage_policy: :structured)

    for _cycle <- 1..3 do
      assert :ok = CodexCatalog.refresh()

      eventually(fn ->
        status = CodexCatalog.status()
        status[:loading] == false and status[:configured] == false
      end)

      status = CodexCatalog.status()
      assert status[:configured] == false
      assert status[:available] == false
      assert status[:error] == nil
    end
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp kimi_workflow(fake_env, opts \\ []) do
    original_workflow = Workflow.workflow_file_path()
    source = BoardFactory.workflow_source()
    capture = Path.join(source.root, "fake-acp-capture.jsonl")
    command = fake_command(fake_env, source.root, capture)

    yaml =
      source.workflow
      |> File.read!()
      |> replace_backends_section(command, Keyword.get(opts, :include_codex, true))
      |> maybe_structured_stage_policy(Keyword.get(opts, :stage_policy, :legacy))

    File.write!(source.workflow, yaml)
    Workflow.set_workflow_file_path(source.workflow)
    assert :ok = Workflow.Store.force_reload()
    BoardFactory.await_activation()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow)
      Workflow.Store.force_reload()
    end)

    %{source: source, capture: capture}
  end

  # The ACP client wraps the backend command with `exec <command>`, so the
  # command must be a single simple command: the cd/env setup lives in a
  # launcher script.
  defp fake_command(fake_env, source_root, capture) do
    exports =
      fake_env
      |> Map.put("FAKE_ACP_CAPTURE", capture)
      |> Map.put("MIX_ENV", "test")
      |> Enum.map_join("\n", fn {key, value} -> "export #{key}=#{shell_escape(value)}" end)

    script = Path.join(source_root, "fake-kimi-acp.sh")

    File.write!(script, """
    #!/bin/sh
    set -e
    cd #{shell_escape(File.cwd!())}
    #{exports}
    exec mise exec -- mix run --no-compile --no-deps-check --no-start test/fixtures/fake_kimi_acp.exs
    """)

    "sh #{shell_escape(script)}"
  end

  defp replace_backends_section(workflow, command, include_codex) do
    codex =
      if include_codex do
        "  codex:\n" <>
          "    protocol: app_server\n" <>
          "    command: \"codex --config shell_environment_policy.inherit=all app-server\"\n"
      else
        ""
      end

    backends =
      "backends:\n" <>
        codex <>
        "  kimi:\n" <>
        "    protocol: acp\n" <>
        "    command: #{Jason.encode!(command)}\n" <>
        "    allow_unsandboxed: true\n"

    Regex.replace(~r/^codex:\n(?:  [^\n]*\n)+/m, workflow, backends)
  end

  defp maybe_structured_stage_policy(workflow, :legacy), do: workflow

  defp maybe_structured_stage_policy(workflow, :structured) do
    String.replace(
      workflow,
      "    allowed_model_efforts:\n      gpt-5.5: [xhigh]\n",
      "    allowed_models:\n      - backend: kimi\n        model: kimi-code/k3\n        efforts:\n          - max\n"
    )
  end

  defp capture_events(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      {:error, _reason} ->
        []
    end
  end

  defp eventually(fun, timeout_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition did not become true")
      else
        Process.sleep(50)
        do_eventually(fun, deadline)
      end
    end
  end

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
