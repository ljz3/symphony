defmodule SymphonyElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :symphony_elixir,
      version: "0.1.0",
      elixir: "~> 1.19",
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      test_coverage: [
        summary: [
          threshold: 100
        ],
        ignore_modules: [
          Mix.Tasks.PrBody.Check,
          Mix.Tasks.Specs.Check,
          Mix.Tasks.Workspace.BeforeRemove,
          SymphonyElixir,
          SymphonyElixir.Application,
          SymphonyElixir.AgentRunner,
          SymphonyElixir.Board,
          SymphonyElixir.Board.Checkpoint,
          SymphonyElixir.Board.Commands,
          SymphonyElixir.Board.Event,
          SymphonyElixir.Board.History,
          SymphonyElixir.Board.Lease,
          SymphonyElixir.Board.Metrics,
          SymphonyElixir.Board.Projection,
          SymphonyElixir.Board.Storage,
          SymphonyElixir.Board.Sync,
          SymphonyElixir.Board.Validator,
          SymphonyElixir.Board.Writer,
          SymphonyElixir.CLI,
          SymphonyElixir.Config,
          SymphonyElixir.Config.Schema,
          SymphonyElixir.Codex.Activity,
          SymphonyElixir.Codex.AppServer,
          SymphonyElixir.Codex.Catalog,
          SymphonyElixir.Codex.DynamicTool,
          SymphonyElixir.GitHub,
          SymphonyElixir.GitHub.Client,
          SymphonyElixir.HttpServer,
          SymphonyElixir.LogFile,
          SymphonyElixir.MCP.Handler,
          SymphonyElixir.MCP.Transport,
          SymphonyElixir.Orchestrator,
          SymphonyElixir.Orchestrator.State,
          SymphonyElixir.Paths,
          SymphonyElixir.PathSafety,
          SymphonyElixir.PromptBuilder,
          SymphonyElixir.Repo,
          SymphonyElixir.SpecsCheck,
          SymphonyElixir.SSH,
          SymphonyElixir.Task,
          SymphonyElixir.TaskCreateTool,
          SymphonyElixir.Workflow,
          SymphonyElixir.Workflow.Bundle,
          SymphonyElixir.Workflow.Store,
          SymphonyElixir.Worktree,
          SymphonyElixirWeb.ArchiveLive,
          SymphonyElixirWeb.BoardApiController,
          SymphonyElixirWeb.BoardLive,
          SymphonyElixirWeb.Endpoint,
          SymphonyElixirWeb.ErrorHTML,
          SymphonyElixirWeb.ErrorJSON,
          SymphonyElixirWeb.Layouts,
          SymphonyElixirWeb.MCPDispatcher,
          SymphonyElixirWeb.TaskLive,
          SymphonyElixirWeb.StaticAssetController,
          SymphonyElixirWeb.StaticAssets,
          SymphonyElixirWeb.StatsLive,
          SymphonyElixirWeb.TelemetryComponents,
          SymphonyElixirWeb.Router,
          SymphonyElixirWeb.Router.Helpers
        ]
      ],
      test_ignore_filters: [
        "test/support/board_factory.exs"
      ],
      dialyzer: [
        plt_add_apps: [:mix]
      ],
      escript: escript(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {SymphonyElixir.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.12"},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix, "~> 1.8.9"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.2"},
      {:req, "~> 0.6"},
      {:jason, "~> 1.4"},
      {:mcp_elixir_sdk, "~> 1.1.0"},
      {:yaml_elixir, "~> 2.12"},
      {:solid, "~> 1.3"},
      {:ecto_sql, "~> 3.14"},
      {:ecto_sqlite3, "~> 0.24.1"},
      {:exqlite, "~> 0.38"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      build: ["escript.build"],
      lint: ["specs.check", "credo --strict"]
    ]
  end

  defp escript do
    [
      app: nil,
      include_priv_for: [:exqlite],
      main_module: SymphonyElixir.CLI,
      name: "symphony",
      path: "bin/symphony"
    ]
  end
end
