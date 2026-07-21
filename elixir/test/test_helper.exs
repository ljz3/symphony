exclude = if System.get_env("SYMPHONY_RUN_LIVE_E2E") == "1", do: [], else: [:live]
exclude = if System.get_env("SYMPHONY_RUN_LIVE_KIMI") == "1", do: exclude, else: [:live_kimi | exclude]
ExUnit.start(exclude: exclude)
Code.require_file("support/board_factory.exs", __DIR__)
