defmodule SymphonyElixirWeb.BoardApiController do
  @moduledoc "Read-only board API plus an orchestration refresh signal."

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Board, Orchestrator, Task}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, json_safe(Board.state()))
  end

  @spec task(Conn.t(), map()) :: Conn.t()
  def task(conn, %{"identifier" => identifier}) do
    case Board.task(identifier) do
      {:ok, task} ->
        {:ok, task_metrics} = Board.task_metrics(task.id)

        payload = %{
          task: Task.to_map(task),
          stats: task_metrics["stats"],
          runs: task_metrics["runs"],
          events: Board.events(task.id)
        }

        json(conn, json_safe(payload))

      {:error, :not_found} ->
        error_response(conn, 404, "task_not_found", "Task not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    :ok = Orchestrator.refresh()

    conn
    |> put_status(202)
    |> json(%{accepted: true})
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp json_safe(%_{} = struct), do: struct |> Map.from_struct() |> json_safe()

  defp json_safe(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, json_safe(value)} end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(tuple) when is_tuple(tuple), do: inspect(tuple)
  defp json_safe(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp json_safe(value), do: value
end
