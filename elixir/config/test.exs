import Config

test_home =
  Path.join(
    System.tmp_dir!(),
    "symphony-elixir-test-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  )

config :symphony_elixir,
  symphony_home: test_home,
  dispatch_enabled: false,
  catalog_enabled: false

config :symphony_elixir, SymphonyElixirWeb.Endpoint, server: false
