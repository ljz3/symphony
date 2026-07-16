defmodule SymphonyElixir.SSHTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SymphonyElixir.SSH

  test "OpenSSH status 255 is a captured structured transport error" do
    with_fake_ssh(255, "ssh: connect to host worker.example port 22: Connection refused\n", fn ->
      parent = self()

      leaked =
        capture_io(:stderr, fn ->
          send(parent, {:ssh_result, SSH.run("worker.example", "true")})
        end)

      assert leaked == ""

      assert_receive {:ssh_result, {:error, {:ssh_transport_failed, 255, "ssh: connect to host worker.example port 22: Connection refused\n"}}}
    end)
  end

  test "remote command failures other than 255 remain natural command results" do
    with_fake_ssh(17, "remote command failed naturally\n", fn ->
      parent = self()

      leaked =
        capture_io(:stderr, fn ->
          send(parent, {:ssh_result, SSH.run("worker.example", "exit 17")})
        end)

      assert leaked == ""
      assert_receive {:ssh_result, {:ok, {"remote command failed naturally\n", 17}}}
    end)
  end

  defp with_fake_ssh(status, diagnostic, callback) do
    root = Path.join(System.tmp_dir!(), "symphony-fake-ssh-#{Ecto.UUID.generate()}")
    executable = Path.join(root, "ssh")
    original_path = System.get_env("PATH")
    File.mkdir_p!(root)

    File.write!(
      executable,
      "#!/bin/sh\nprintf '%s' #{shell_escape(diagnostic)} >&2\nexit #{status}\n"
    )

    File.chmod!(executable, 0o755)
    System.put_env("PATH", root <> ":" <> original_path)

    try do
      callback.()
    after
      System.put_env("PATH", original_path)
    end
  end

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
