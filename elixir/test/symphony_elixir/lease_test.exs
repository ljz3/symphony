defmodule SymphonyElixir.Board.LeaseTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Board.Lease

  test "reclaims a dead same-machine lease after the hostname changes" do
    root = temporary_directory()
    path = Path.join(root, "owner.json")
    write_owner(path, "old-hostname", "same-machine", 123_456)

    assert {:ok, lease} =
             Lease.start_link(
               name: unique_name(),
               project_id: "lease-test",
               path: path,
               hostname: "new-hostname",
               machine_id: "same-machine",
               os_pid: 654_321,
               process_alive?: fn 123_456 -> false end
             )

    assert :sys.get_state(lease).owned

    assert %{"hostname" => "new-hostname", "machine_id" => "same-machine", "os_pid" => 654_321} =
             read_owner(path)

    assert [_backup] = Path.wildcard(path <> ".stale-*")
    GenServer.stop(lease)
    refute File.exists?(path)
  end

  test "does not reclaim a dead lease from a different machine" do
    root = temporary_directory()
    path = Path.join(root, "owner.json")
    existing = write_owner(path, "shared-hostname", "other-machine", 123_456)

    assert {:ok, lease} =
             Lease.start_link(
               name: unique_name(),
               project_id: "lease-test",
               path: path,
               hostname: "shared-hostname",
               machine_id: "this-machine",
               os_pid: 654_321,
               process_alive?: fn 123_456 -> false end
             )

    refute :sys.get_state(lease).owned
    assert read_owner(path) == existing
    GenServer.stop(lease)
    assert File.exists?(path)
  end

  defp temporary_directory do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-lease-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp write_owner(path, hostname, machine_id, os_pid) do
    owner = %{
      "lease_id" => Ecto.UUID.generate(),
      "hostname" => hostname,
      "machine_id" => machine_id,
      "os_pid" => os_pid
    }

    File.write!(path, Jason.encode!(owner))
    owner
  end

  defp read_owner(path), do: path |> File.read!() |> Jason.decode!()

  defp unique_name do
    {:global, {__MODULE__, System.unique_integer([:positive, :monotonic])}}
  end
end
