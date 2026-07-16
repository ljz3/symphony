defmodule SymphonyElixir.Board.WorkpadStore do
  @moduledoc """
  Owns Symphony's private, versioned workpad sidecars and publication manifests.

  Sidecars are authoritative over the replaceable SQLite projection. Every
  workpad write reaches an atomically renamed, synced file before SQLite is
  updated, and publication manifests are durable before rows become published.
  """

  use GenServer

  alias SymphonyElixir.Board.Projection
  alias SymphonyElixir.Paths
  alias SymphonyElixir.Workflow

  @record_format_version 2
  @manifest_format_version 1
  @sha256_pattern ~r/\A[0-9a-f]{64}\z/

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec write(String.t(), pos_integer(), String.t()) :: :ok | {:error, term()}
  def write(run_id, invocation, content)
      when is_binary(run_id) and is_integer(invocation) and invocation > 0 and is_binary(content) do
    GenServer.call(__MODULE__, {:write, run_id, invocation, content, false})
  end

  @spec write_template(String.t(), pos_integer(), String.t()) :: :ok | {:error, term()}
  def write_template(run_id, invocation, content)
      when is_binary(run_id) and is_integer(invocation) and invocation > 0 and is_binary(content) do
    GenServer.call(__MODULE__, {:write, run_id, invocation, content, true})
  end

  @spec latest_meaningful(String.t(), String.t()) :: map() | nil
  def latest_meaningful(task_id, current_run_id)
      when is_binary(task_id) and is_binary(current_run_id) do
    runs = Projection.list_runs(task_id)

    case Enum.find(runs, &(&1["id"] == current_run_id and &1["task_id"] == task_id)) do
      nil -> nil
      current -> latest_for_run(current) || latest_terminal(runs, current_run_id)
    end
  end

  @spec record_publication(String.t(), [map()]) :: :ok | {:error, term()}
  def record_publication(publication_id, workpads)
      when is_binary(publication_id) and is_list(workpads) and workpads != [] do
    GenServer.call(__MODULE__, {:record_publication, publication_id, workpads})
  end

  @spec reconcile() :: :ok | {:error, term()}
  def reconcile, do: GenServer.call(__MODULE__, :reconcile, :infinity)

  @spec publication_id(String.t(), [map()]) :: String.t()
  def publication_id(task_id, workpads) when is_binary(task_id) and is_list(workpads) do
    entries = publication_entries(workpads)

    :crypto.hash(:sha256, Jason.encode!(%{"task_id" => task_id, "records" => entries}))
    |> Base.encode16(case: :lower)
  end

  @impl true
  def init(opts) do
    project_id = Keyword.get_lazy(opts, :project_id, &current_project_id/0)
    root = Keyword.get(opts, :root, Paths.workpads_root(project_id))
    state = %{project_id: project_id, root: root}

    case do_reconcile(state) do
      :ok -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:write, run_id, invocation, content, template?}, _from, state) do
    {:reply, write_record(state, run_id, invocation, content, template?), state}
  end

  def handle_call({:record_publication, publication_id, workpads}, _from, state) do
    {:reply, persist_publication(state, publication_id, workpads), state}
  end

  def handle_call(:reconcile, _from, state) do
    {:reply, do_reconcile(state), state}
  end

  defp current_project_id do
    case Workflow.project_identity() do
      {:ok, %{id: id}} -> id
      _ -> "unconfigured"
    end
  end

  defp write_record(state, run_id, invocation, content, template?) do
    with :ok <- safe_component(run_id),
         :ok <- ensure_layout(state.root),
         {:ok, record} <- current_or_new_record(state.root, run_id, invocation, content, template?),
         {:ok, publication_id} <- matching_publication(state.root, record) do
      Projection.put_workpad(
        Map.merge(record, %{
          published: is_binary(publication_id),
          publication_id: publication_id
        })
      )
    end
  end

  defp current_or_new_record(root, run_id, invocation, content, template?) do
    path = record_path(root, run_id, invocation)

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        current_record(root, path, content)

      {:ok, _stat} ->
        {:error, {:malformed_workpad_sidecar, path, :not_a_regular_file}}

      {:error, :enoent} ->
        template_sha256 = if template?, do: content_sha256(content), else: nil
        persist_record(root, fresh_record(run_id, invocation, content, timestamp(), template_sha256))

      {:error, reason} ->
        {:error, {:malformed_workpad_sidecar, path, reason}}
    end
  end

  defp current_record(root, path, content) do
    with {:ok, existing} <- read_record(path) do
      if existing.content == content,
        do: {:ok, existing},
        else:
          persist_record(
            root,
            fresh_record(
              existing.run_id,
              existing.invocation,
              content,
              timestamp(),
              existing.template_sha256
            )
          )
    end
  end

  defp persist_record(root, record) do
    path = record_path(root, record.run_id, record.invocation)

    with :ok <- private_directory(Path.dirname(path)),
         :ok <- atomic_json(path, encode_record(record)) do
      {:ok, record}
    end
  end

  defp persist_publication(state, publication_id, workpads) do
    with :ok <- safe_component(publication_id),
         :ok <- ensure_layout(state.root),
         {:ok, records} <- ensure_publication_records(state.root, workpads),
         manifest <- publication_manifest(publication_id, workpads, records),
         :ok <- persist_manifest(state.root, manifest) do
      Projection.mark_workpads_published(workpads, publication_id)
    end
  end

  defp ensure_publication_records(root, workpads) do
    Enum.reduce_while(workpads, {:ok, []}, fn workpad, {:ok, records} ->
      run_id = value(workpad, :run_id)
      invocation = value(workpad, :invocation)
      content = value(workpad, :content)
      path = record_path(root, run_id, invocation)

      result =
        if File.exists?(path) do
          read_record(path)
        else
          updated_at = value(workpad, :updated_at, timestamp())
          template_sha256 = value(workpad, :template_sha256)
          persist_record(root, fresh_record(run_id, invocation, content, updated_at, template_sha256))
        end

      case result do
        {:ok, %{content: ^content} = record} -> {:cont, {:ok, [record | records]}}
        {:ok, record} -> {:halt, {:error, {:workpad_content_changed, run_id, invocation, record.content_sha256}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp publication_manifest(publication_id, workpads, records) do
    task_ids =
      workpads
      |> Enum.map(&value(&1, :task_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    %{
      format_version: @manifest_format_version,
      publication_id: publication_id,
      task_id: List.first(task_ids),
      created_at: timestamp(),
      records:
        records
        |> Enum.map(&manifest_entry/1)
        |> Enum.sort_by(&{&1.run_id, &1.invocation, &1.content_sha256})
    }
  end

  defp persist_manifest(root, manifest) do
    path = manifest_path(root, manifest.publication_id)

    if File.exists?(path) do
      case read_manifest(path) do
        {:ok, existing} -> compare_manifest_records(existing.records, manifest.records, path)
        {:error, reason} -> {:error, reason}
      end
    else
      atomic_json(path, encode_manifest(manifest))
    end
  end

  defp compare_manifest_records(records, records, _path), do: :ok
  defp compare_manifest_records(_existing, _requested, path), do: {:error, {:publication_manifest_conflict, path}}

  defp do_reconcile(state) do
    with :ok <- ensure_layout(state.root),
         projection <- Projection.all_workpads(),
         :ok <- export_projection_records(state.root, projection),
         :ok <- export_projection_manifests(state.root, projection),
         {:ok, records} <- load_records(state.root),
         {:ok, manifests} <- load_manifests(state.root),
         hydrated <- hydrate_publications(records, manifests) do
      Projection.replace_workpads(hydrated)
    end
  end

  defp export_projection_records(root, projection) do
    Enum.reduce_while(projection, :ok, &export_projection_record(&1, &2, root))
  end

  defp export_projection_record(workpad, :ok, root) do
    path = record_path(root, workpad.run_id, workpad.invocation)

    if File.exists?(path) do
      {:cont, :ok}
    else
      record =
        fresh_record(
          workpad.run_id,
          workpad.invocation,
          workpad.content,
          workpad.updated_at,
          workpad.template_sha256
        )

      persist_projection_record(root, record)
    end
  end

  defp persist_projection_record(root, record) do
    case persist_record(root, record) do
      {:ok, _record} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp export_projection_manifests(root, projection) do
    projection
    |> Enum.filter(&(&1.published and is_binary(&1.publication_id)))
    |> Enum.group_by(& &1.publication_id)
    |> Enum.reduce_while(:ok, &export_projection_manifest(&1, &2, root))
  end

  defp export_projection_manifest({publication_id, workpads}, :ok, root) do
    if File.exists?(manifest_path(root, publication_id)) do
      {:cont, :ok}
    else
      persist_projection_manifest(root, legacy_manifest(publication_id, workpads))
    end
  end

  defp persist_projection_manifest(root, manifest) do
    case persist_manifest(root, manifest) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp legacy_manifest(publication_id, workpads) do
    %{
      format_version: @manifest_format_version,
      publication_id: publication_id,
      task_id: projection_task_id(workpads),
      created_at: workpads |> Enum.map(& &1.updated_at) |> Enum.max(fn -> timestamp() end),
      records:
        workpads
        |> Enum.map(fn workpad ->
          %{run_id: workpad.run_id, invocation: workpad.invocation, content_sha256: content_sha256(workpad.content)}
        end)
        |> Enum.sort_by(&{&1.run_id, &1.invocation, &1.content_sha256})
    }
  end

  defp projection_task_id([workpad | _workpads]) do
    case Projection.get_run(workpad.run_id) do
      {:ok, run} -> run["task_id"]
      _ -> nil
    end
  end

  defp load_records(root) do
    root
    |> Path.join("records/*/*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, records} ->
      case read_record(path) do
        {:ok, record} -> {:cont, {:ok, [record | records]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp load_manifests(root) do
    root
    |> Path.join("publications/*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, manifests} ->
      case read_manifest(path) do
        {:ok, manifest} -> {:cont, {:ok, [manifest | manifests]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, manifests} -> {:ok, Enum.reverse(manifests)}
      error -> error
    end
  end

  defp hydrate_publications(records, manifests) do
    published = publication_index(records, manifests)

    Enum.map(records, fn record ->
      publication_id = published[record_key(record)]

      record
      |> Map.put(:published, is_binary(publication_id))
      |> Map.put(:publication_id, publication_id)
    end)
  end

  defp publication_index(records, manifests) do
    records_by_key = Map.new(records, &{record_key(&1), &1})
    Enum.reduce(manifests, %{}, &index_manifest(&1, &2, records_by_key))
  end

  defp index_manifest(manifest, published, records_by_key) do
    Enum.reduce(manifest.records, published, &index_manifest_entry(&1, &2, records_by_key, manifest.publication_id))
  end

  defp index_manifest_entry(entry, published, records_by_key, publication_id) do
    key = record_key(entry)

    case records_by_key[key] do
      %{content_sha256: hash} when hash == entry.content_sha256 -> Map.put_new(published, key, publication_id)
      _ -> published
    end
  end

  defp matching_publication(root, record) do
    with {:ok, manifests} <- load_manifests(root) do
      publication_id =
        manifests
        |> Enum.find(&manifest_matches_record?(&1, record))
        |> then(&(&1 && &1.publication_id))

      {:ok, publication_id}
    end
  end

  defp manifest_matches_record?(manifest, record) do
    Enum.any?(manifest.records, fn entry ->
      record_key(entry) == record_key(record) and entry.content_sha256 == record.content_sha256
    end)
  end

  defp read_record(path) do
    with {:ok, json} <- File.read(path),
         {:ok, decoded} <- Jason.decode(json),
         {:ok, record} <- validate_record(decoded, path) do
      {:ok, record}
    else
      {:error, reason} -> {:error, {:malformed_workpad_sidecar, path, reason}}
    end
  end

  defp validate_record(record, path) do
    expected_run_id = path |> Path.dirname() |> Path.basename()
    expected_invocation = path |> Path.basename(".json") |> Integer.parse()

    with %{
           "format_version" => version,
           "run_id" => run_id,
           "invocation" => invocation,
           "content" => content,
           "content_sha256" => hash,
           "updated_at" => updated_at
         } <- record,
         true <- version in [1, @record_format_version],
         true <- is_binary(run_id) and run_id == expected_run_id,
         {^invocation, ""} <- expected_invocation,
         true <- invocation > 0,
         true <- is_binary(content) and is_binary(updated_at),
         {:ok, template_sha256} <- validate_template_sha256(version, record),
         true <- hash == content_sha256(content) do
      {:ok,
       %{
         run_id: run_id,
         invocation: invocation,
         content: content,
         content_sha256: hash,
         updated_at: updated_at,
         template_sha256: template_sha256
       }}
    else
      _ -> {:error, :invalid_record}
    end
  end

  defp validate_template_sha256(1, _record), do: {:ok, nil}

  defp validate_template_sha256(@record_format_version, %{"template_sha256" => nil}),
    do: {:ok, nil}

  defp validate_template_sha256(@record_format_version, %{"template_sha256" => hash})
       when is_binary(hash) do
    if Regex.match?(@sha256_pattern, hash),
      do: {:ok, hash},
      else: {:error, :invalid_template_sha256}
  end

  defp validate_template_sha256(_version, _record), do: {:error, :invalid_template_sha256}

  defp read_manifest(path) do
    with {:ok, json} <- File.read(path),
         {:ok, decoded} <- Jason.decode(json),
         {:ok, manifest} <- validate_manifest(decoded, path) do
      {:ok, manifest}
    else
      {:error, reason} -> {:error, {:malformed_publication_manifest, path, reason}}
    end
  end

  defp validate_manifest(manifest, path) do
    expected_id = Path.basename(path, ".json")

    with %{
           "format_version" => @manifest_format_version,
           "publication_id" => publication_id,
           "created_at" => created_at,
           "records" => entries
         } <- manifest,
         true <- publication_id == expected_id and is_binary(created_at),
         true <- is_list(entries) and entries != [],
         {:ok, records} <- validate_manifest_entries(entries) do
      {:ok,
       %{
         publication_id: publication_id,
         task_id: manifest["task_id"],
         created_at: created_at,
         records: Enum.sort_by(records, &{&1.run_id, &1.invocation, &1.content_sha256})
       }}
    else
      _ -> {:error, :invalid_manifest}
    end
  end

  defp validate_manifest_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, records} ->
      case entry do
        %{"run_id" => run_id, "invocation" => invocation, "content_sha256" => hash}
        when is_binary(run_id) and is_integer(invocation) and invocation > 0 and is_binary(hash) ->
          {:cont, {:ok, [%{run_id: run_id, invocation: invocation, content_sha256: hash} | records]}}

        _ ->
          {:halt, {:error, :invalid_manifest_entry}}
      end
    end)
  end

  defp encode_record(record) do
    %{
      "format_version" => @record_format_version,
      "run_id" => record.run_id,
      "invocation" => record.invocation,
      "content" => record.content,
      "content_sha256" => record.content_sha256,
      "updated_at" => record.updated_at,
      "template_sha256" => record.template_sha256
    }
  end

  defp encode_manifest(manifest) do
    %{
      "format_version" => @manifest_format_version,
      "publication_id" => manifest.publication_id,
      "task_id" => manifest.task_id,
      "created_at" => manifest.created_at,
      "records" =>
        Enum.map(manifest.records, fn entry ->
          %{
            "run_id" => entry.run_id,
            "invocation" => entry.invocation,
            "content_sha256" => entry.content_sha256
          }
        end)
    }
  end

  defp publication_entries(workpads) do
    workpads
    |> Enum.map(fn workpad ->
      %{
        "run_id" => value(workpad, :run_id),
        "invocation" => value(workpad, :invocation),
        "content_sha256" => content_sha256(value(workpad, :content))
      }
    end)
    |> Enum.sort_by(&{&1["run_id"], &1["invocation"], &1["content_sha256"]})
  end

  defp manifest_entry(record) do
    %{run_id: record.run_id, invocation: record.invocation, content_sha256: record.content_sha256}
  end

  defp fresh_record(run_id, invocation, content, updated_at, template_sha256) do
    %{
      run_id: run_id,
      invocation: invocation,
      content: content,
      content_sha256: content_sha256(content),
      updated_at: updated_at,
      template_sha256: template_sha256
    }
  end

  defp content_sha256(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp latest_terminal(runs, current_run_id) do
    runs
    |> Enum.filter(&(&1["id"] != current_run_id and &1["status"] in ["completed", "failed", "stopped"]))
    |> Enum.sort_by(&{&1["finished_at"] || "", &1["id"]}, :desc)
    |> Enum.find_value(&latest_for_run/1)
  end

  defp latest_for_run(run) do
    run["id"]
    |> Projection.list_workpads()
    |> Enum.filter(&meaningful?/1)
    |> Enum.max_by(& &1["invocation"], fn -> nil end)
    |> case do
      nil ->
        nil

      workpad ->
        %{
          "run_id" => run["id"],
          "stage_id" => run["stage_id"],
          "status" => run["status"],
          "finished_at" => run["finished_at"],
          "invocation" => workpad["invocation"],
          "updated_at" => workpad["updated_at"],
          "content" => workpad["content"]
        }
    end
  end

  defp meaningful?(%{"template_sha256" => nil}), do: true

  defp meaningful?(%{"template_sha256" => template_sha256, "content" => content}) do
    content_sha256(content) != template_sha256
  end

  defp record_key(record), do: {record.run_id, record.invocation}

  defp record_path(root, run_id, invocation) do
    Path.join([root, "records", run_id, "#{invocation}.json"])
  end

  defp manifest_path(root, publication_id) do
    Path.join([root, "publications", publication_id <> ".json"])
  end

  defp ensure_layout(root) do
    [root, Path.join(root, "records"), Path.join(root, "publications")]
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case private_directory(path) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:workpad_directory_failed, path, reason}}}
      end
    end)
  end

  defp private_directory(path) do
    case File.mkdir_p(path) do
      :ok -> File.chmod(path, 0o700)
      {:error, reason} -> {:error, reason}
    end
  end

  defp atomic_json(path, value) do
    temporary = path <> ".tmp-#{Ecto.UUID.generate()}"
    body = Jason.encode!(value, pretty: true) <> "\n"

    try do
      case :file.open(String.to_charlist(temporary), [:write, :binary, :exclusive]) do
        {:ok, file} -> write_and_rename(file, temporary, path, body)
        {:error, reason} -> {:error, {:atomic_workpad_write_failed, path, reason}}
      end
    after
      File.rm(temporary)
    end
  end

  defp write_and_rename(file, temporary, path, body) do
    result =
      with :ok <- File.chmod(temporary, 0o600),
           :ok <- :file.write(file, body) do
        :file.sync(file)
      end

    close_result = :file.close(file)

    with :ok <- result,
         :ok <- close_result,
         :ok <- File.rename(temporary, path) do
      File.chmod(path, 0o600)
    else
      {:error, reason} -> {:error, {:atomic_workpad_write_failed, path, reason}}
    end
  end

  defp safe_component(<<first, rest::binary>> = component)
       when first in ?a..?z or first in ?A..?Z or first in ?0..?9 do
    safe_component_tail(rest, component)
  end

  defp safe_component(component), do: {:error, {:unsafe_workpad_component, component}}

  defp safe_component_tail(<<>>, _component), do: :ok

  defp safe_component_tail(<<character, rest::binary>>, component)
       when character in ?a..?z or character in ?A..?Z or character in ?0..?9 or
              character in [?., ?_, ?-] do
    safe_component_tail(rest, component)
  end

  defp safe_component_tail(_rest, component), do: {:error, {:unsafe_workpad_component, component}}

  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
  end
end
