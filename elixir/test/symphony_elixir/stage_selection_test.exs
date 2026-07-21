defmodule SymphonyElixir.StageSelectionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.StageSelection

  test "round-trips selections with and without effort" do
    for option <- [{"codex", "gpt-5.5", "xhigh"}, {"kimi", "kimi-code/k3", nil}] do
      assert {:ok, ^option} = StageSelection.decode(StageSelection.encode(option))
    end
  end

  test "rejects malformed identifiers" do
    assert :error = StageSelection.decode("not-base64!!")
    assert :error = StageSelection.decode(Base.url_encode64("not json"))
    assert :error = StageSelection.decode(Base.url_encode64(Jason.encode!(%{"b" => 1, "m" => "x", "e" => nil})))
    assert :error = StageSelection.decode(Base.url_encode64(Jason.encode!(%{"b" => "x", "m" => "y"})))
    assert :error = StageSelection.decode(Base.url_encode64(Jason.encode!(%{"b" => "x", "m" => "y", "e" => 3})))
    assert :error = StageSelection.decode(123)
  end

  test "labels include effort only when present" do
    assert StageSelection.label({"codex", "gpt-5.5", "xhigh"}) == "codex · gpt-5.5 · xhigh"
    assert StageSelection.label({"kimi", "kimi-code/k3", nil}) == "kimi · kimi-code/k3"
  end

  test "maps expose the canonical three-key shape" do
    assert StageSelection.to_map({"kimi", "m", nil}) == %{"backend" => "kimi", "model" => "m", "effort" => nil}
  end
end
