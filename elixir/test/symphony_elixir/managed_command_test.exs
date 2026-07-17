defmodule SymphonyElixir.ManagedCommandTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ManagedCommand
  alias SymphonyElixir.ManagedCommand.Worker

  test "reports worker crashes instead of waiting forever" do
    runner = Task.async(fn -> ManagedCommand.run("sleep 2", System.tmp_dir!(), []) end)
    worker = eventually(fn -> managed_worker_monitoring(runner.pid) end)

    Process.exit(worker, :kill)

    assert {:error, {:managed_command_worker_exit, :killed}} = Task.await(runner)
  end

  test "normalizes local command startup failures" do
    assert {:error, {:managed_command_start_failed, message}} = ManagedCommand.run("true", <<0>>, [])
    assert message =~ "invalid port name"
  end

  test "handles terminal port messages and cancellation checks" do
    normal = worker_state(port: :normal_port)
    normal_ref = normal.ref

    assert {:stop, :normal, %{terminal_sent: true, port: nil}} =
             Worker.handle_info({:normal_port, :closed}, normal)

    assert_receive {:managed_command_result, ^normal_ref, {:error, :managed_command_port_closed}}

    cancelled = worker_state(port: :cancelled_port, cancel_reason: :cancelled)
    cancelled_ref = cancelled.ref

    assert {:stop, :normal, %{terminal_sent: true, port: nil}} =
             Worker.handle_info({:cancelled_port, :closed}, cancelled)

    assert_receive {:managed_command_result, ^cancelled_ref, {:error, :cancelled}}

    checking = worker_state(port: nil, cancel_reason: :cancelled)
    checking_ref = checking.ref

    assert {:stop, :normal, %{terminal_sent: true}} = Worker.handle_info(:check_process_death, checking)
    assert_receive {:managed_command_result, ^checking_ref, {:error, :cancelled}}

    state = worker_state()
    assert {:noreply, ^state} = Worker.handle_info(:unrelated, state)
  end

  test "buffers partial identities and cancels malformed identities" do
    marker = "__SYMPHONY_MANAGED_COMMAND_test__"
    state = worker_state(port: :identity_port, marker: marker)

    assert {:noreply, pending} =
             Worker.handle_info({:identity_port, {:data, "prefix" <> marker <> "12"}}, state)

    assert pending.control_buffer == "prefix" <> marker <> "12"

    assert {:noreply, parsed} = Worker.handle_info({:identity_port, {:data, "\noutput"}}, pending)
    assert parsed.pgid == 12
    assert parsed.control_buffer == ""
    assert parsed.output == ["prefixoutput"]

    malformed = worker_state(port: :malformed_port, marker: marker)

    assert {:noreply, cancelling} =
             Worker.handle_info({:malformed_port, {:data, marker <> "not-a-pid\n"}}, malformed)

    assert cancelling.cancel_reason == :managed_command_identity_invalid
    assert is_reference(cancelling.escalation_timer)
    assert {:noreply, ^cancelling} = Worker.handle_cast({:cancel, :replacement_reason}, cancelling)
    Process.cancel_timer(cancelling.escalation_timer)
  end

  test "preserves pre-wrapper SSH transport failures and reports other missing identities" do
    transport =
      worker_state(
        port: :transport_port,
        worker_host: "builder",
        control_buffer: "Permission denied (publickey).\n"
      )

    transport_ref = transport.ref

    assert {:stop, :normal, _state} =
             Worker.handle_info({:transport_port, {:exit_status, 255}}, transport)

    assert_receive {:managed_command_result, ^transport_ref, {:error, {:ssh_transport_failed, 255, "Permission denied (publickey).\n"}}}

    missing = worker_state(port: :missing_port, worker_host: "builder", control_buffer: "unexpected")
    missing_ref = missing.ref
    assert {:stop, :normal, _state} = Worker.handle_info({:missing_port, {:exit_status, 0}}, missing)
    assert_receive {:managed_command_result, ^missing_ref, {:error, :managed_command_identity_missing}}
  end

  test "keeps checking live or indeterminate remote process groups" do
    fake_root = fake_ssh_directory()

    with_path(fake_root <> ":" <> System.get_env("PATH"), fn ->
      System.put_env("FAKE_MANAGED_SSH_MODE", "alive")
      live = worker_state(port: :live_port, cancel_reason: :cancelled, pgid: 123, worker_host: "builder")

      assert {:noreply, checking} = Worker.handle_info(:check_process_death, live)
      assert is_reference(checking.death_check_timer)
      Process.cancel_timer(checking.death_check_timer)

      existing_timer = make_ref()
      live = %{live | death_check_timer: existing_timer}
      assert {:noreply, %{death_check_timer: ^existing_timer}} = Worker.handle_info(:escalate_cancellation, live)

      System.put_env("FAKE_MANAGED_SSH_MODE", "transport")
      unknown = worker_state(port: :unknown_port, cancel_reason: :cancelled, pgid: 456, worker_host: "builder")

      assert {:noreply, checking} = Worker.handle_info(:check_process_death, unknown)
      assert is_reference(checking.death_check_timer)
      Process.cancel_timer(checking.death_check_timer)
    end)
  after
    System.delete_env("FAKE_MANAGED_SSH_MODE")
  end

  test "handles unavailable and failing local signal executables" do
    empty_path = temporary_directory("managed-command-empty-path")

    with_path(empty_path, fn ->
      assert :ok =
               Worker.terminate(
                 :normal,
                 worker_state(cancel_reason: :cancelled, pgid: 123, worker_host: nil)
               )

      signalling =
        worker_state(
          port: :signal_port,
          cancel_reason: :cancelled,
          pgid: nil,
          transport_pid: 456
        )

      signalling_ref = signalling.ref

      assert {:stop, :normal, _state} = Worker.handle_info(:escalate_cancellation, signalling)
      assert_receive {:managed_command_result, ^signalling_ref, {:error, :cancelled}}

      unknown = worker_state(port: :unknown_local, cancel_reason: :cancelled, pgid: 789)
      assert {:noreply, checking} = Worker.handle_info(:check_process_death, unknown)
      assert is_reference(checking.death_check_timer)
      Process.cancel_timer(checking.death_check_timer)

      no_transport = worker_state(port: :no_transport, cancel_reason: :cancelled, pgid: nil)
      no_transport_ref = no_transport.ref
      assert {:stop, :normal, _state} = Worker.handle_info(:escalate_cancellation, no_transport)
      assert_receive {:managed_command_result, ^no_transport_ref, {:error, :cancelled}}
    end)

    invalid_group = worker_state(port: :broken_local, cancel_reason: :cancelled, pgid: %{})
    assert {:noreply, checking} = Worker.handle_info(:check_process_death, invalid_group)
    assert is_reference(checking.death_check_timer)
    Process.cancel_timer(checking.death_check_timer)
  end

  defp worker_state(overrides \\ []) do
    Map.merge(
      %{
        caller: self(),
        caller_ref: make_ref(),
        owner: self(),
        owner_ref: make_ref(),
        ref: make_ref(),
        command: "true",
        directory: System.tmp_dir!(),
        environment: [],
        worker_host: nil,
        token: "test",
        marker: "__SYMPHONY_MANAGED_COMMAND_test__",
        port: :fake_port,
        transport_pid: nil,
        pgid: nil,
        control_buffer: "",
        output: [],
        cancel_reason: nil,
        escalation_timer: nil,
        death_check_timer: nil,
        kill_sent: false,
        terminal_sent: false
      },
      Map.new(overrides)
    )
  end

  defp managed_worker_monitoring(caller) do
    case Process.info(caller, :monitored_by) do
      {:monitored_by, monitors} -> Enum.find(monitors, &managed_worker?/1)
      nil -> nil
    end
  end

  defp managed_worker?(pid) when pid == self(), do: false

  defp managed_worker?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        Keyword.get(dictionary, :"$initial_call") == {Worker, :init, 1}

      nil ->
        false
    end
  end

  defp eventually(callback, attempts \\ 100)

  defp eventually(callback, attempts) when attempts > 0 do
    case callback.() do
      nil ->
        Process.sleep(10)
        eventually(callback, attempts - 1)

      result ->
        result
    end
  end

  defp eventually(callback, 0), do: flunk("condition did not become true: #{inspect(callback)}")

  defp fake_ssh_directory do
    root = temporary_directory("managed-command-fake-ssh")
    executable = Path.join(root, "ssh")

    File.write!(executable, """
    #!/bin/sh
    case "${FAKE_MANAGED_SSH_MODE:-alive}" in
      alive) exit 0 ;;
      transport) printf '%s' 'transport unavailable' >&2; exit 255 ;;
    esac
    """)

    File.chmod!(executable, 0o755)
    root
  end

  defp temporary_directory(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{Ecto.UUID.generate()}")
    File.mkdir_p!(path)
    path
  end

  defp with_path(path, callback) do
    original = System.get_env("PATH")
    System.put_env("PATH", path)

    try do
      callback.()
    after
      System.put_env("PATH", original)
    end
  end
end
