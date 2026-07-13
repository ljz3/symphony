defmodule SymphonyElixir.PathSafetyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PathSafety

  test "canonicalizes symlink segments and preserves nonexistent tails" do
    root = Path.join(System.tmp_dir!(), "path-safety-#{Ecto.UUID.generate()}")
    real = Path.join(root, "real")
    link = Path.join(root, "link")
    File.mkdir_p!(real)
    File.ln_s!(real, link)

    assert {:ok, canonical} = PathSafety.canonicalize(Path.join(link, "future/file.txt"))
    assert {:ok, expected} = PathSafety.canonicalize(Path.join(real, "future/file.txt"))
    assert canonical == expected
  end
end
