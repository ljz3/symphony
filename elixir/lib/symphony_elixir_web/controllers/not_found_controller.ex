defmodule SymphonyElixirWeb.NotFoundController do
  @moduledoc "Generic JSON 404 fallback for paths outside the LiveView and static-asset surface."

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    conn
    |> put_status(404)
    |> json(%{error: %{code: "not_found", message: "Route not found"}})
  end
end
