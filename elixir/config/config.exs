import Config

config :phoenix, :json_library, Jason

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false

config :symphony_elixir,
  ecto_repos: [SymphonyElixir.Repo]

config :symphony_elixir, SymphonyElixir.Repo,
  pool_size: 1,
  journal_mode: :wal,
  temp_store: :memory,
  busy_timeout: 5_000,
  cache_size: -64_000,
  foreign_keys: :on

import_config "#{config_env()}.exs"
