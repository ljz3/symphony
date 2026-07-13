defmodule SymphonyElixir.RunStatsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.RunStats

  test "tracks unique turns and accepts only cumulative token snapshots" do
    telemetry = RunStats.new()

    assert {:ok, telemetry} =
             RunStats.observe(telemetry, %{
               event: :session_started,
               thread_id: "thread-1",
               turn_id: "turn-1"
             })

    assert :ignore =
             RunStats.observe(telemetry, %{
               event: :session_started,
               thread_id: "thread-1",
               turn_id: "turn-1"
             })

    assert {:ok, telemetry} =
             RunStats.observe(telemetry, %{
               event: :notification,
               payload: %{
                 "method" => "thread/tokenUsage/updated",
                 "params" => %{
                   "tokenUsage" => %{
                     "total" => %{
                       "inputTokens" => 1_000,
                       "cachedInputTokens" => 700,
                       "outputTokens" => 250,
                       "totalTokens" => 1_250
                     },
                     "last" => %{"totalTokens" => 50}
                   }
                 }
               }
             })

    assert :ignore =
             RunStats.observe(telemetry, %{
               event: :notification,
               payload: %{
                 "method" => "thread/tokenUsage/updated",
                 "params" => %{
                   "tokenUsage" => %{
                     "total" => %{
                       "inputTokens" => 800,
                       "cachedInputTokens" => 600,
                       "outputTokens" => 200,
                       "totalTokens" => 1_000
                     }
                   }
                 }
               }
             })

    assert {:ok, telemetry} =
             RunStats.observe(telemetry, %{
               "event" => "session_started",
               "thread_id" => "thread-1",
               "turn_id" => "turn-2"
             })

    assert RunStats.summary(telemetry) == %{
             "turn_count" => 2,
             "token_usage" => %{
               "input_tokens" => 1_000,
               "cached_input_tokens" => 700,
               "output_tokens" => 250,
               "total_tokens" => 1_250
             }
           }
  end

  test "accepts legacy total_token_usage and normalizes snake-case fields" do
    message = %{
      payload: %{
        "method" => "codex/event/token_count",
        "params" => %{
          "msg" => %{
            "payload" => %{
              "info" => %{
                "total_token_usage" => %{
                  "input_tokens" => 90,
                  "cached_input_tokens" => 50,
                  "output_tokens" => 10
                },
                "last_token_usage" => %{"total_tokens" => 5}
              }
            }
          }
        }
      }
    }

    assert RunStats.absolute_token_usage(message) == %{
             "input_tokens" => 90,
             "cached_input_tokens" => 50,
             "output_tokens" => 10,
             "total_tokens" => 100
           }
  end

  test "ignores generic, delta-only, and turn-completed usage" do
    messages = [
      %{usage: %{"input_tokens" => 10, "output_tokens" => 1}},
      %{
        payload: %{
          "method" => "thread/tokenUsage/updated",
          "params" => %{"tokenUsage" => %{"last" => %{"totalTokens" => 10}}}
        }
      },
      %{
        payload: %{
          "method" => "turn/completed",
          "params" => %{"usage" => %{"input_tokens" => 10, "output_tokens" => 1}}
        }
      },
      %{
        payload: %{
          "method" => "turn/completed",
          "info" => %{"total_token_usage" => %{"input_tokens" => 10, "output_tokens" => 1}}
        }
      }
    ]

    assert Enum.all?(messages, &(RunStats.absolute_token_usage(&1) == nil))
    refute Enum.any?(messages, &RunStats.relevant?/1)
  end

  test "ignores missing session identifiers and malformed cumulative paths" do
    session = %{event: :session_started, thread_id: nil, turn_id: ""}
    malformed = %{payload: %{"method" => "thread/tokenUsage/updated", "params" => "invalid"}}

    assert RunStats.relevant?(session)
    assert :ignore = RunStats.observe(RunStats.new(), session)
    assert RunStats.absolute_token_usage(malformed) == nil
  end
end
