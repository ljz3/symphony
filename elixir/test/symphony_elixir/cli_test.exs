defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.CLI

  @ack "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  setup do
    port = Application.get_env(:symphony_elixir, :server_port_override)
    env_port = System.get_env("SYMPHONY_PORT")

    on_exit(fn ->
      if port,
        do: Application.put_env(:symphony_elixir, :server_port_override, port),
        else: Application.delete_env(:symphony_elixir, :server_port_override)

      if env_port, do: System.put_env("SYMPHONY_PORT", env_port), else: System.delete_env("SYMPHONY_PORT")
    end)

    Application.delete_env(:symphony_elixir, :server_port_override)
    System.delete_env("SYMPHONY_PORT")
    :ok
  end

  test "requires the existing guardrail acknowledgement and a loopback port" do
    assert {:error, banner} = CLI.evaluate([])
    assert banner =~ "engineering preview"

    assert {:error, message} = CLI.evaluate([@ack])
    assert message =~ "loopback port is required"
    assert CLI.usage_message() =~ "WORKFLOW.yml"
  end

  test "runs board status with explicit machine-local startup options" do
    deps = %{
      file_regular?: &File.regular?/1,
      ensure_all_started: fn -> {:ok, []} end
    }

    assert {:ok, %{project: %{id: "symphony"}}} =
             CLI.evaluate([@ack, "--port", "0", "board", "status", "WORKFLOW.yml"], deps)
  end

  test "rejects missing workflow files and unguarded reconcile choices" do
    deps = %{file_regular?: fn _ -> false end, ensure_all_started: fn -> {:ok, []} end}

    assert {:error, message} = CLI.evaluate([@ack, "--port", "0", "/missing/WORKFLOW.yml"], deps)
    assert message =~ "Workflow file not found"

    assert {:error, usage} = CLI.evaluate([@ack, "--port", "0", "board", "reconcile"], deps)
    assert usage =~ "Usage:"
  end
end
