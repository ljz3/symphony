defmodule SymphonyElixirWeb.Router do
  @moduledoc "Loopback-only Kanban UI router."

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SymphonyElixirWeb do
    get("/board.css", StaticAssetController, :board_css)
    get("/favicon.png", StaticAssetController, :favicon)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", BoardLive, :index)
    live("/stats", StatsLive, :index)
    live("/tasks/:identifier", TaskLive, :show)
    live("/archive", ArchiveLive, :index)
  end

  scope "/", SymphonyElixirWeb do
    match(:*, "/*path", NotFoundController, :not_found)
  end
end
