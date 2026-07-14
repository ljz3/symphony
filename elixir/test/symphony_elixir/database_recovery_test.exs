defmodule SymphonyElixir.DatabaseRecoveryTest do
  use ExUnit.Case, async: false

  alias Exqlite.Basic
  alias SymphonyElixir.DatabaseRecovery

  test "healthy read-only checks leave the database bytes unchanged" do
    root = temporary_root("healthy")
    database = Path.join(root, "board.sqlite3")
    assert {:ok, connection} = Basic.open(database)
    assert :ok = Basic.close(connection)
    before = File.read!(database)

    assert :healthy = DatabaseRecovery.health(database)
    assert File.read!(database) == before
    refute File.exists?(database <> "-wal")
    refute File.exists?(database <> "-shm")
  end

  test "indeterminate health preserves the complete database family byte-for-byte" do
    root = temporary_root("indeterminate")
    database = Path.join(root, "board.sqlite3")
    recovery_root = Path.join(root, "recovery")
    write_family(database)
    before = family_snapshot(database)

    assert {:error, {:database_health_indeterminate, ^database, :nif_unavailable}} =
             DatabaseRecovery.prepare("recovery-test", database,
               recovery_root: recovery_root,
               health_check: fn ^database -> {:indeterminate, :nif_unavailable} end
             )

    assert family_snapshot(database) == before
    refute File.exists?(recovery_root)
  end

  test "confirmed corruption validates a replacement before retaining the original family" do
    root = temporary_root("confirmed")
    database = Path.join(root, "board.sqlite3")
    recovery_root = Path.join(root, "recovery")
    write_family(database)
    before = family_snapshot(database)

    assert {:error, {:replacement_validation_failed, _staged, :still_corrupt}} =
             DatabaseRecovery.prepare("recovery-test", database,
               recovery_root: recovery_root,
               health_check: fn
                 ^database -> {:confirmed_corrupt, :quick_check_failed}
                 _staged -> {:confirmed_corrupt, :still_corrupt}
               end,
               replacement_builder: fn staged -> File.write(staged, "invalid replacement", [:binary]) end
             )

    assert family_snapshot(database) == before
    refute File.exists?(recovery_root)

    assert :ok =
             DatabaseRecovery.prepare("recovery-test", database,
               recovery_root: recovery_root,
               health_check: fn
                 ^database -> {:confirmed_corrupt, :quick_check_failed}
                 _staged -> :healthy
               end,
               replacement_builder: fn staged -> File.write(staged, "validated replacement", [:binary]) end
             )

    assert File.read!(database) == "validated replacement"
    assert [quarantine] = recovery_root |> File.ls!() |> Enum.map(&Path.join(recovery_root, &1))
    assert File.dir?(quarantine)

    assert Map.new(["", "-wal", "-shm"], fn suffix ->
             path = Path.join(quarantine, Path.basename(database <> suffix))
             {suffix, File.read!(path)}
           end) == before
  end

  test "replacement installation failure rolls the quarantined family back" do
    root = temporary_root("rollback")
    database = Path.join(root, "board.sqlite3")
    recovery_root = Path.join(root, "recovery")
    write_family(database)
    before = family_snapshot(database)

    rename = fn source, destination ->
      if destination == database and String.contains?(source, ".recovery-staging-") do
        {:error, :injected_install_failure}
      else
        File.rename(source, destination)
      end
    end

    assert {:error, {:replacement_install_failed, ^database, :injected_install_failure}} =
             DatabaseRecovery.prepare("recovery-test", database,
               recovery_root: recovery_root,
               health_check: fn
                 ^database -> {:confirmed_corrupt, :quick_check_failed}
                 _staged -> :healthy
               end,
               replacement_builder: fn staged -> File.write(staged, "validated replacement", [:binary]) end,
               rename: rename
             )

    assert family_snapshot(database) == before

    assert recovery_root
           |> Path.join("**/*")
           |> Path.wildcard()
           |> Enum.reject(&File.dir?/1) == []
  end

  defp temporary_root(label) do
    root = Path.join(System.tmp_dir!(), "symphony-recovery-#{label}-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp write_family(database) do
    File.write!(database, "database-before", [:binary])
    File.write!(database <> "-wal", "wal-before", [:binary])
    File.write!(database <> "-shm", "shm-before", [:binary])
  end

  defp family_snapshot(database) do
    Map.new(["", "-wal", "-shm"], fn suffix -> {suffix, File.read!(database <> suffix)} end)
  end
end
