defmodule SymphonyElixirWeb.TelemetryComponents do
  @moduledoc "Shared project/run telemetry components and formatting helpers."

  use Phoenix.Component

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:detail, :string, default: nil)
  attr(:class, :string, default: nil)

  @spec metric_card(map()) :: Phoenix.LiveView.Rendered.t()
  def metric_card(assigns) do
    ~H"""
    <article class={["metric-card", @class]}>
      <p class="metric-label">{@label}</p>
      <p class="metric-value numeric">{@value}</p>
      <p :if={@detail} class="metric-detail">{@detail}</p>
    </article>
    """
  end

  @spec live_status(map()) :: Phoenix.LiveView.Rendered.t()
  def live_status(assigns) do
    ~H"""
    <span class="connection-status connection-live"><span></span>Live</span>
    <span class="connection-status connection-offline"><span></span>Offline</span>
    """
  end

  @spec live_duration_ms(non_neg_integer() | nil, String.t() | nil, DateTime.t(), non_neg_integer()) ::
          non_neg_integer() | nil
  def live_duration_ms(nil, _generated_at, _now, _active_count), do: nil

  def live_duration_ms(base_ms, generated_at, %DateTime{} = now, active_count)
      when is_integer(base_ms) and base_ms >= 0 and is_integer(active_count) and active_count >= 0 do
    base_ms + elapsed_since(generated_at, now) * active_count
  end

  @spec advancing_duration_ms(non_neg_integer() | nil, String.t() | nil, DateTime.t()) :: non_neg_integer() | nil
  def advancing_duration_ms(nil, _generated_at, _now), do: nil

  def advancing_duration_ms(base_ms, generated_at, %DateTime{} = now) when is_integer(base_ms) and base_ms >= 0 do
    base_ms + elapsed_since(generated_at, now)
  end

  @spec format_duration(non_neg_integer() | nil) :: String.t()
  def format_duration(nil), do: "—"

  def format_duration(milliseconds) when is_integer(milliseconds) and milliseconds >= 0 do
    seconds = div(milliseconds, 1_000)
    days = div(seconds, 86_400)
    hours = div(rem(seconds, 86_400), 3_600)
    minutes = div(rem(seconds, 3_600), 60)
    remaining_seconds = rem(seconds, 60)

    cond do
      days > 0 -> "#{days}d #{hours}h #{minutes}m"
      hours > 0 -> "#{hours}h #{minutes}m #{remaining_seconds}s"
      true -> "#{minutes}m #{remaining_seconds}s"
    end
  end

  @spec format_count(non_neg_integer() | nil) :: String.t()
  def format_count(value) when is_integer(value) and value >= 0 do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  def format_count(_value), do: "—"

  @spec format_token_total(map() | nil) :: String.t()
  def format_token_total(%{"token_usage" => usage, "token_usage_state" => state}) do
    format_token_total(usage, state)
  end

  def format_token_total(_accounting), do: "—"

  @spec format_token_total(map() | nil, String.t()) :: String.t()
  def format_token_total(nil, _state), do: "—"

  def format_token_total(usage, state) when is_map(usage) do
    total = format_count(usage["total_tokens"])
    if state == "partial", do: "≥ #{total}", else: total
  end

  @spec format_token_breakdown(map() | nil) :: String.t()
  def format_token_breakdown(%{"token_usage" => usage}), do: format_usage_breakdown(usage)
  def format_token_breakdown(_accounting), do: "In — · Cached — · Out —"

  @spec format_usage_breakdown(map() | nil) :: String.t()
  def format_usage_breakdown(usage) when is_map(usage) do
    "In #{format_count(usage["input_tokens"])} · Cached #{format_count(usage["cached_input_tokens"])} · Out #{format_count(usage["output_tokens"])}"
  end

  def format_usage_breakdown(_usage), do: "In — · Cached — · Out —"

  @spec format_worker(String.t() | nil) :: String.t()
  def format_worker(nil), do: "local"
  def format_worker(worker), do: worker

  @spec partial?(map()) :: boolean()
  def partial?(%{"token_usage_state" => state}), do: state in ["partial", "unavailable"]
  def partial?(_metrics), do: false

  defp elapsed_since(nil, _now), do: 0

  defp elapsed_since(generated_at, now) do
    case DateTime.from_iso8601(generated_at) do
      {:ok, generated, _offset} -> max(0, DateTime.diff(now, generated, :millisecond))
      _ -> 0
    end
  end
end
