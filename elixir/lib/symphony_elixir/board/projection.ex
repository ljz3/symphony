defmodule SymphonyElixir.Board.Projection do
  @moduledoc """
  Transactional SQLite projection of canonical board events plus local workpads.
  """

  import Kernel, except: [apply: 2]

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.Board.Event
  alias SymphonyElixir.Codex.RunStats
  alias SymphonyElixir.{Repo, Task}

  @spec apply(Event.t(), term()) :: :ok | {:error, term()}
  def apply(%Event{} = event, result) do
    Repo.transaction(fn ->
      if projected?(event.sequence) do
        :already_projected
      else
        insert_event(event)
        apply_payload(event.payload)
        store_idempotency(event, result)
        put_meta("last_sequence", Integer.to_string(event.sequence))
        put_meta("history_head", event.git_oid || "")
      end
    end)
    |> case do
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, {:projection_apply_failed, event.sequence, reason}}
    end
  rescue
    error -> {:error, {:projection_apply_failed, event.sequence, error}}
  end

  @spec replay([Event.t()]) :: :ok | {:error, term()}
  def replay(events) when is_list(events) do
    last = last_sequence()

    events
    |> Enum.filter(&(&1.sequence > last))
    |> Enum.reduce_while(:ok, fn event, :ok ->
      case apply(event, event.payload["result"] || event.payload[:result] || %{}) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec rebuild([Event.t()]) :: :ok | {:error, term()}
  def rebuild(events) when is_list(events) do
    case clear_canonical_projection() do
      {:ok, _result} -> replay(events)
      {:error, reason} -> {:error, {:projection_rebuild_failed, reason}}
    end
  rescue
    error -> {:error, {:projection_rebuild_failed, error}}
  end

  defp clear_canonical_projection do
    tables = ~w(board_idempotency board_external_effects board_runs board_tasks board_events board_meta)
    Repo.transaction(fn -> Enum.each(tables, &clear_table/1) end)
  end

  defp clear_table(table), do: SQL.query!(Repo, "DELETE FROM #{table}", [])

  @spec list_tasks(keyword()) :: [Task.t()]
  def list_tasks(opts \\ []) do
    archived = Keyword.get(opts, :archived, false)
    archived_value = if archived, do: 1, else: 0

    SQL.query!(
      Repo,
      "SELECT task_json FROM board_tasks WHERE archived = ? ORDER BY priority ASC, rank ASC, number ASC",
      [archived_value]
    ).rows
    |> Enum.map(fn [json] -> json |> Jason.decode!() |> Task.from_map() end)
  end

  @spec get_task(String.t()) :: {:ok, Task.t()} | {:error, :not_found}
  def get_task(id_or_identifier) when is_binary(id_or_identifier) do
    case SQL.query!(
           Repo,
           "SELECT task_json FROM board_tasks WHERE id = ? OR identifier = ? LIMIT 1",
           [id_or_identifier, id_or_identifier]
         ).rows do
      [[json]] -> {:ok, json |> Jason.decode!() |> Task.from_map()}
      [] -> {:error, :not_found}
    end
  end

  @spec list_runs(String.t() | nil) :: [map()]
  def list_runs(task_id \\ nil) do
    {sql, params} =
      if is_binary(task_id) do
        {"SELECT run_json FROM board_runs WHERE task_id = ? ORDER BY updated_at DESC", [task_id]}
      else
        {"SELECT run_json FROM board_runs ORDER BY updated_at DESC", []}
      end

    SQL.query!(Repo, sql, params).rows
    |> Enum.map(fn [json] -> Jason.decode!(json) end)
  end

  @spec get_run(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_run(run_id) when is_binary(run_id) do
    case SQL.query!(Repo, "SELECT run_json FROM board_runs WHERE id = ?", [run_id]).rows do
      [[json]] -> {:ok, Jason.decode!(json)}
      [] -> {:error, :not_found}
    end
  end

  @spec last_sequence() :: non_neg_integer()
  def last_sequence do
    case SQL.query!(Repo, "SELECT value FROM board_meta WHERE key = 'last_sequence'", []).rows do
      [[value]] -> String.to_integer(value)
      [] -> 0
    end
  end

  @spec history_head() :: String.t() | nil
  def history_head do
    case SQL.query!(Repo, "SELECT value FROM board_meta WHERE key = 'history_head'", []).rows do
      [[""]] -> nil
      [[value]] -> value
      [] -> nil
    end
  end

  @spec next_task_number() :: pos_integer()
  def next_task_number do
    case SQL.query!(Repo, "SELECT COALESCE(MAX(number), 0) + 1 FROM board_tasks", []).rows do
      [[number]] -> number
    end
  end

  @spec max_rank(String.t()) :: integer()
  def max_rank(column_id) when is_binary(column_id) do
    case SQL.query!(Repo, "SELECT COALESCE(MAX(rank), 0) FROM board_tasks WHERE column_id = ? AND archived = 0", [column_id]).rows do
      [[rank]] -> rank
    end
  end

  @spec idempotent_result(String.t()) :: {:ok, map()} | :miss
  def idempotent_result(key) when is_binary(key) do
    case SQL.query!(Repo, "SELECT result_json FROM board_idempotency WHERE idempotency_key = ?", [key]).rows do
      [[json]] -> {:ok, Jason.decode!(json)}
      [] -> :miss
    end
  end

  @spec event_history(String.t() | nil) :: [map()]
  def event_history(task_id \\ nil) do
    {sql, params} =
      if task_id do
        {"SELECT event_json FROM board_events WHERE task_id = ? ORDER BY sequence ASC", [task_id]}
      else
        {"SELECT event_json FROM board_events ORDER BY sequence ASC", []}
      end

    SQL.query!(Repo, sql, params).rows
    |> Enum.map(fn [json] -> Jason.decode!(json) end)
  end

  @spec observe_run_telemetry(String.t(), map()) :: :ok | {:error, term()}
  def observe_run_telemetry(run_id, message) when is_binary(run_id) and is_map(message) do
    if RunStats.relevant?(message) do
      persist_run_telemetry(run_id, message)
    else
      :ok
    end
  end

  defp persist_run_telemetry(run_id, message) do
    Repo.transaction(fn -> update_run_telemetry(run_id, message) end)
    |> case do
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_run_telemetry(run_id, message) do
    current = run_telemetry_row(run_id) || RunStats.new()

    case RunStats.observe(current, message) do
      {:ok, updated} -> upsert_run_telemetry(run_id, updated)
      :ignore -> :unchanged
    end
  end

  @spec run_telemetry(String.t()) :: map() | nil
  def run_telemetry(run_id) when is_binary(run_id), do: run_telemetry_row(run_id)

  @spec list_run_telemetry() :: %{optional(String.t()) => map()}
  def list_run_telemetry do
    SQL.query!(Repo, "SELECT run_id, telemetry_json FROM board_run_telemetry", []).rows
    |> Map.new(fn [run_id, json] -> {run_id, Jason.decode!(json)} end)
  end

  @spec delete_run_telemetry(String.t()) :: :ok | {:error, term()}
  def delete_run_telemetry(run_id) when is_binary(run_id) do
    case SQL.query(Repo, "DELETE FROM board_run_telemetry WHERE run_id = ?", [run_id]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec write_workpad(String.t(), pos_integer(), String.t()) :: :ok | {:error, term()}
  def write_workpad(run_id, invocation, content)
      when is_binary(run_id) and is_integer(invocation) and invocation > 0 and is_binary(content) do
    case SQL.query(
           Repo,
           """
           INSERT INTO board_workpads(run_id, invocation, content, published, updated_at)
           VALUES (?, ?, ?, 0, ?)
           ON CONFLICT(run_id, invocation) DO UPDATE SET
             content = excluded.content,
             published = CASE WHEN board_workpads.content = excluded.content THEN board_workpads.published ELSE 0 END,
             publication_id = CASE WHEN board_workpads.content = excluded.content THEN board_workpads.publication_id ELSE NULL END,
             updated_at = excluded.updated_at
           """,
           [run_id, invocation, content, timestamp()]
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec put_workpad(map()) :: :ok | {:error, term()}
  def put_workpad(workpad) when is_map(workpad) do
    case SQL.query(
           Repo,
           """
           INSERT INTO board_workpads(run_id, invocation, content, published, publication_id, updated_at)
           VALUES (?, ?, ?, ?, ?, ?)
           ON CONFLICT(run_id, invocation) DO UPDATE SET
             content = excluded.content,
             published = excluded.published,
             publication_id = excluded.publication_id,
             updated_at = excluded.updated_at
           """,
           [
             value(workpad, :run_id),
             value(workpad, :invocation),
             value(workpad, :content),
             if(value(workpad, :published, false), do: 1, else: 0),
             value(workpad, :publication_id),
             value(workpad, :updated_at)
           ]
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec read_workpad(String.t(), pos_integer()) :: {:ok, String.t()} | {:error, :not_found}
  def read_workpad(run_id, invocation) when is_binary(run_id) and is_integer(invocation) do
    case SQL.query!(Repo, "SELECT content FROM board_workpads WHERE run_id = ? AND invocation = ?", [run_id, invocation]).rows do
      [[content]] -> {:ok, content}
      [] -> {:error, :not_found}
    end
  end

  @spec workpad_metadata(String.t()) :: [map()]
  def workpad_metadata(run_id) when is_binary(run_id) do
    SQL.query!(
      Repo,
      """
      SELECT invocation, published, publication_id, updated_at
      FROM board_workpads
      WHERE run_id = ?
      ORDER BY invocation ASC
      """,
      [run_id]
    ).rows
    |> Enum.map(fn [invocation, published, publication_id, updated_at] ->
      %{
        "invocation" => invocation,
        "published" => published == 1,
        "publication_id" => publication_id,
        "updated_at" => updated_at
      }
    end)
  end

  @spec list_workpads(String.t()) :: [map()]
  def list_workpads(run_id) when is_binary(run_id) do
    SQL.query!(
      Repo,
      """
      SELECT run_id, invocation, content, published, publication_id, updated_at
      FROM board_workpads
      WHERE run_id = ?
      ORDER BY invocation ASC
      """,
      [run_id]
    ).rows
    |> Enum.map(&workpad_map/1)
  end

  @spec all_workpads() :: [map()]
  def all_workpads do
    SQL.query!(
      Repo,
      """
      SELECT run_id, invocation, content, published, publication_id, updated_at
      FROM board_workpads
      ORDER BY run_id ASC, invocation ASC
      """,
      []
    ).rows
    |> Enum.map(fn [run_id, invocation, content, published, publication_id, updated_at] ->
      %{
        run_id: run_id,
        invocation: invocation,
        content: content,
        published: published == 1,
        publication_id: publication_id,
        updated_at: updated_at
      }
    end)
  end

  @spec replace_workpads([map()]) :: :ok | {:error, term()}
  def replace_workpads(workpads) when is_list(workpads) do
    Repo.transaction(fn ->
      SQL.query!(Repo, "DELETE FROM board_workpads", [])

      Enum.each(workpads, fn workpad ->
        SQL.query!(
          Repo,
          """
          INSERT INTO board_workpads(run_id, invocation, content, published, publication_id, updated_at)
          VALUES (?, ?, ?, ?, ?, ?)
          """,
          [
            value(workpad, :run_id),
            value(workpad, :invocation),
            value(workpad, :content),
            if(value(workpad, :published, false), do: 1, else: 0),
            value(workpad, :publication_id),
            value(workpad, :updated_at)
          ]
        )
      end)
    end)
    |> case do
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec unpublished_workpads(String.t()) :: [map()]
  def unpublished_workpads(task_id) when is_binary(task_id) do
    SQL.query!(
      Repo,
      """
      SELECT r.task_id, w.run_id, w.invocation, w.content, w.updated_at
      FROM board_workpads AS w
      JOIN board_runs AS r ON r.id = w.run_id
      WHERE r.task_id = ? AND w.published = 0
      ORDER BY r.updated_at ASC, w.invocation ASC
      """,
      [task_id]
    ).rows
    |> Enum.map(fn [task_id, run_id, invocation, content, updated_at] ->
      %{task_id: task_id, run_id: run_id, invocation: invocation, content: content, updated_at: updated_at}
    end)
  end

  @spec mark_workpads_published([map()], String.t()) :: :ok | {:error, term()}
  def mark_workpads_published(workpads, publication_id) when is_list(workpads) and is_binary(publication_id) do
    Repo.transaction(fn ->
      Enum.each(workpads, fn workpad ->
        SQL.query!(
          Repo,
          "UPDATE board_workpads SET published = 1, publication_id = ? WHERE run_id = ? AND invocation = ?",
          [publication_id, workpad.run_id, workpad.invocation]
        )
      end)
    end)
    |> case do
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec running?() :: boolean()
  def running? do
    case SQL.query!(Repo, "SELECT COUNT(*) FROM board_runs WHERE status IN ('starting', 'running', 'stopping')", []).rows do
      [[count]] -> count > 0
    end
  end

  defp projected?(sequence) do
    SQL.query!(Repo, "SELECT 1 FROM board_events WHERE sequence = ?", [sequence]).rows != []
  end

  defp insert_event(event) do
    SQL.query!(
      Repo,
      """
      INSERT INTO board_events(
        sequence, event_id, command_id, idempotency_key, task_id, run_id,
        task_revision, event_type, git_oid, event_json, inserted_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        event.sequence,
        event.event_id,
        event.command_id,
        event.idempotency_key,
        event.task_id,
        event.run_id,
        event.task_revision,
        event.type,
        event.git_oid,
        Event.encode(event),
        event.timestamp
      ]
    )
  end

  defp apply_payload(payload) do
    task = payload["task"] || payload[:task]
    tasks = payload["tasks"] || payload[:tasks] || []
    run = payload["run"] || payload[:run]
    external_effect = payload["external_effect"] || payload[:external_effect]

    if task, do: upsert_task(task)
    Enum.each(tasks, &upsert_task/1)
    if run, do: upsert_run(run)
    if external_effect, do: upsert_external_effect(external_effect)
    :ok
  end

  defp upsert_task(%Task{} = task), do: upsert_task(Task.to_map(task))

  defp upsert_task(task) when is_map(task) do
    task = stringify_keys(task)
    priority = task["priority"] |> priority_atom() |> Task.priority_weight()
    archived = if task["archived_at"], do: 1, else: 0
    json = Jason.encode!(task)

    SQL.query!(
      Repo,
      """
      INSERT INTO board_tasks(id, identifier, number, column_id, rank, priority, revision, archived, task_json, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        identifier = excluded.identifier,
        number = excluded.number,
        column_id = excluded.column_id,
        rank = excluded.rank,
        priority = excluded.priority,
        revision = excluded.revision,
        archived = excluded.archived,
        task_json = excluded.task_json,
        updated_at = excluded.updated_at
      """,
      [
        task["id"],
        task["identifier"],
        task["number"],
        task["column_id"],
        task["rank"],
        priority,
        task["revision"],
        archived,
        json,
        task["updated_at"]
      ]
    )
  end

  defp upsert_run(run) do
    run = stringify_keys(run)
    json = Jason.encode!(run)

    SQL.query!(
      Repo,
      """
      INSERT INTO board_runs(id, task_id, stage_id, status, run_json, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        status = excluded.status,
        run_json = excluded.run_json,
        updated_at = excluded.updated_at
      """,
      [run["id"], run["task_id"], run["stage_id"], run["status"], json, run["updated_at"]]
    )

    if run["status"] in ["completed", "stopped", "failed"] and is_map(run["stats"]) do
      SQL.query!(Repo, "DELETE FROM board_run_telemetry WHERE run_id = ?", [run["id"]])
    end
  end

  defp run_telemetry_row(run_id) do
    case SQL.query!(Repo, "SELECT telemetry_json FROM board_run_telemetry WHERE run_id = ?", [run_id]).rows do
      [[json]] -> Jason.decode!(json)
      [] -> nil
    end
  end

  defp upsert_run_telemetry(run_id, telemetry) do
    SQL.query!(
      Repo,
      """
      INSERT INTO board_run_telemetry(run_id, telemetry_json, updated_at)
      VALUES (?, ?, ?)
      ON CONFLICT(run_id) DO UPDATE SET
        telemetry_json = excluded.telemetry_json,
        updated_at = excluded.updated_at
      """,
      [run_id, Jason.encode!(telemetry), timestamp()]
    )
  end

  defp upsert_external_effect(effect) do
    effect = stringify_keys(effect)

    SQL.query!(
      Repo,
      """
      INSERT INTO board_external_effects(id, task_id, kind, state, effect_json, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET state = excluded.state, effect_json = excluded.effect_json, updated_at = excluded.updated_at
      """,
      [effect["id"], effect["task_id"], effect["kind"], effect["state"], Jason.encode!(effect), effect["updated_at"]]
    )
  end

  defp store_idempotency(event, result) do
    SQL.query!(
      Repo,
      "INSERT INTO board_idempotency(idempotency_key, command_id, event_id, result_json, inserted_at) VALUES (?, ?, ?, ?, ?)",
      [event.idempotency_key, event.command_id, event.event_id, Jason.encode!(result), event.timestamp]
    )
  end

  defp put_meta(key, value) do
    SQL.query!(
      Repo,
      "INSERT INTO board_meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      [key, value]
    )
  end

  defp priority_atom(value) when is_atom(value), do: value
  defp priority_atom("urgent"), do: :urgent
  defp priority_atom("high"), do: :high
  defp priority_atom("normal"), do: :normal
  defp priority_atom("low"), do: :low

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(nil), do: nil
  defp stringify_keys(value) when is_boolean(value), do: value
  defp stringify_keys(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_keys(value), do: value

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
  end

  defp workpad_map([run_id, invocation, content, published, publication_id, updated_at]) do
    %{
      "run_id" => run_id,
      "invocation" => invocation,
      "content" => content,
      "published" => published == 1,
      "publication_id" => publication_id,
      "updated_at" => updated_at
    }
  end

  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
