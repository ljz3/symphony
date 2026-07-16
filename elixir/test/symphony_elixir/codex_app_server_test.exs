defmodule SymphonyElixir.CodexAppServerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{BoardFactory, Paths, Workflow}
  alias SymphonyElixir.Codex.AppServer

  @tag timeout: 20_000
  test "waits for an app-server response beyond the former read deadline" do
    original_workflow = Workflow.workflow_file_path()
    source = BoardFactory.workflow_source()
    fake_codex = Path.join(source.root, "delayed_fake_codex.exs")
    File.write!(fake_codex, delayed_fake_codex())

    command =
      "cd #{shell_escape(File.cwd!())} && MIX_ENV=test mise exec -- mix run --no-compile --no-deps-check --no-start #{shell_escape(fake_codex)}"

    workflow =
      source.workflow
      |> File.read!()
      |> then(&Regex.replace(~r/^  command:.*$/m, &1, "  command: #{Jason.encode!(command)}"))

    File.write!(source.workflow, workflow)
    Workflow.set_workflow_file_path(source.workflow)
    assert :ok = Workflow.Store.force_reload()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow)
      Workflow.Store.force_reload()
    end)

    workspace = Path.join(Paths.runtime_root("symphony"), BoardFactory.unique("delayed-catalog"))
    File.mkdir_p!(workspace)

    started_at = System.monotonic_time(:millisecond)
    assert {:ok, [%{"model" => "delayed-model"}]} = AppServer.catalog(workspace)
    assert System.monotonic_time(:millisecond) - started_at >= 5_100
  end

  defp delayed_fake_codex do
    ~S"""
    defmodule DelayedFakeCodex do
      def main, do: loop()

      defp loop do
        case IO.read(:stdio, :line) do
          :eof ->
            :ok

          line ->
            line
            |> Jason.decode!()
            |> respond()

            loop()
        end
      end

      defp respond(%{"method" => "initialize", "id" => id}) do
        Process.sleep(5_200)
        IO.puts(Jason.encode!(%{"id" => id, "result" => %{}}))
      end

      defp respond(%{"method" => "model/list", "id" => id}) do
        IO.puts(
          Jason.encode!(%{
            "id" => id,
            "result" => %{"data" => [%{"model" => "delayed-model"}]}
          })
        )
      end

      defp respond(_message), do: :ok
    end

    DelayedFakeCodex.main()
    """
  end

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
