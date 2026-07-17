defmodule SymphonyElixir.JobStore do
  @moduledoc """
  Persists project-job identity and terminal state outside model context.

  Stdout and stderr are durable sibling artifacts. The JSON record contains only
  execution metadata, so complete stdout is neither duplicated nor truncated.
  """

  @format_version 1
  @record_name "job.json"
  @stdout_name "stdout"
  @stderr_name "stderr"

  @spec load(Path.t()) :: {:ok, [map()]} | {:error, term()}
  def load(root) when is_binary(root) do
    with :ok <- private_directory(root) do
      root
      |> Path.join("*/#{@record_name}")
      |> Path.wildcard()
      |> Enum.sort()
      |> load_records()
    end
  end

  defp load_records(paths) do
    Enum.reduce_while(paths, {:ok, []}, &load_record/2)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp load_record(path, {:ok, records}) do
    case read_record(path) do
      {:ok, record} -> {:cont, {:ok, [record | records]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  @spec create(Path.t(), map()) :: {:ok, map()} | {:error, term()}
  def create(root, attrs) when is_binary(root) and is_map(attrs) do
    job_id = Map.fetch!(attrs, "job_id")
    directory = Path.join(root, job_id)
    stdout_path = Path.join(directory, @stdout_name)
    stderr_path = Path.join(directory, @stderr_name)

    record =
      attrs
      |> Map.put("format_version", @format_version)
      |> Map.put("stdout_path", stdout_path)
      |> Map.put("stderr_artifact", stderr_path)

    with :ok <- safe_component(job_id),
         :ok <- private_directory(directory),
         :ok <- private_file(stdout_path, ""),
         :ok <- private_file(stderr_path, ""),
         :ok <- persist(root, record) do
      {:ok, record}
    end
  end

  @spec persist(Path.t(), map()) :: :ok | {:error, term()}
  def persist(root, %{"job_id" => job_id} = record) when is_binary(root) and is_binary(job_id) do
    with :ok <- safe_component(job_id),
         :ok <- private_directory(Path.join(root, job_id)) do
      atomic_json(record_path(root, job_id), record)
    end
  end

  @spec interrupt_running(Path.t(), map()) :: {:ok, map()} | {:error, term()}
  def interrupt_running(root, %{"status" => "running"} = record) do
    finished_at = timestamp()

    updated =
      record
      |> Map.put("status", "interrupted")
      |> Map.put("exit_code", nil)
      |> Map.put("finished_at", finished_at)
      |> Map.put("elapsed_ms", elapsed_ms(record["started_at"], finished_at))

    with :ok <- persist(root, updated), do: {:ok, updated}
  end

  def interrupt_running(_root, record), do: {:ok, record}

  @spec result(map()) :: {:ok, map()} | {:error, term()}
  def result(record) when is_map(record) do
    case File.read(record["stdout_path"]) do
      {:ok, output} ->
        {encoded_output, output_encoding} = encode_output(output)

        {:ok,
         %{
           "job_id" => record["job_id"],
           "job" => record["job"],
           "status" => record["status"],
           "exit_code" => record["exit_code"],
           "output" => encoded_output,
           "output_encoding" => output_encoding,
           "stderr_artifact" => record["stderr_artifact"],
           "started_at" => record["started_at"],
           "finished_at" => record["finished_at"],
           "elapsed_ms" => record["elapsed_ms"],
           "source_fingerprint" => record["source_fingerprint"]
         }}

      {:error, reason} ->
        {:error, {:job_stdout_unreadable, record["job_id"], record["stdout_path"], reason}}
    end
  end

  defp encode_output(output) do
    if String.valid?(output), do: {output, "utf8"}, else: {Base.encode64(output), "base64"}
  end

  defp read_record(path) do
    with {:ok, json} <- File.read(path),
         {:ok, record} <- Jason.decode(json),
         :ok <- validate_record(record, path) do
      {:ok, record}
    else
      {:error, %Jason.DecodeError{} = reason} -> {:error, {:invalid_job_record, path, reason}}
      {:error, reason} -> {:error, {:invalid_job_record, path, reason}}
    end
  end

  defp validate_record(%{"format_version" => @format_version, "job_id" => job_id, "status" => status} = record, path)
       when is_binary(job_id) and status in ["running", "completed", "failed", "cancelled", "interrupted"] do
    required = ~w(job task_id run_id call_ids single_flight_key stdout_path stderr_artifact started_at source_fingerprint)

    if Enum.all?(required, &Map.has_key?(record, &1)) and valid_record_values?(record, path),
      do: :ok,
      else: {:error, :missing_required_fields}
  end

  defp validate_record(_record, _path), do: {:error, :unsupported_record}

  defp valid_record_values?(record, path) do
    directory = Path.dirname(path)

    Enum.all?(~w(job task_id run_id single_flight_key started_at source_fingerprint), &nonempty_string?(record[&1])) and
      is_list(record["call_ids"]) and record["call_ids"] != [] and
      Enum.all?(record["call_ids"], &nonempty_string?/1) and
      valid_deliveries?(record) and
      record["job_id"] == Path.basename(directory) and
      record["stdout_path"] == Path.join(directory, @stdout_name) and
      record["stderr_artifact"] == Path.join(directory, @stderr_name)
  end

  defp nonempty_string?(value), do: is_binary(value) and value != ""

  defp valid_deliveries?(%{"deliveries" => deliveries}) do
    is_list(deliveries) and deliveries != [] and Enum.all?(deliveries, &valid_delivery?/1)
  end

  defp valid_deliveries?(_legacy_record), do: true

  defp valid_delivery?(%{"run_id" => run_id, "call_id" => call_id} = delivery) do
    map_size(delivery) == 2 and nonempty_string?(run_id) and nonempty_string?(call_id)
  end

  defp valid_delivery?(_delivery), do: false

  defp record_path(root, job_id), do: Path.join([root, job_id, @record_name])

  defp private_directory(path) do
    with :ok <- File.mkdir_p(path),
         :ok <- File.chmod(path, 0o700) do
      :ok
    else
      {:error, reason} -> {:error, {:job_directory_failed, path, reason}}
    end
  end

  defp private_file(path, content) do
    with :ok <- File.write(path, content, [:binary]),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, reason} -> {:error, {:job_artifact_failed, path, reason}}
    end
  end

  defp atomic_json(path, value) do
    temporary = path <> ".tmp-#{Ecto.UUID.generate()}"
    encoded = Jason.encode!(value)

    result =
      with :ok <- private_file(temporary, encoded),
           {:ok, :ok} <- File.open(temporary, [:read, :binary], &:file.sync/1) do
        File.rename(temporary, path)
      end

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, {:job_record_write_failed, path, reason}}
    end
  end

  defp safe_component(value) when is_binary(value) do
    if value != "" and Path.basename(value) == value and value not in [".", ".."],
      do: :ok,
      else: {:error, {:unsafe_job_id, value}}
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp elapsed_ms(started_at, finished_at) do
    with {:ok, started, _offset} <- DateTime.from_iso8601(started_at),
         {:ok, finished, _offset} <- DateTime.from_iso8601(finished_at) do
      max(DateTime.diff(finished, started, :millisecond), 0)
    else
      _ -> 0
    end
  end
end
