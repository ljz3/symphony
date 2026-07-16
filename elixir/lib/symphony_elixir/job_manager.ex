defmodule SymphonyElixir.JobManager do
  @moduledoc """
  Owns durable, blocking project jobs and replies only when a job is terminal.

  Calls are idempotent by run and app-server call ID. Concurrent calls with the
  same task, job, normalized arguments, and source fingerprint attach to one
  active worker without introducing a polling API.
  """

  use GenServer

  alias SymphonyElixir.{JobStore, JobSupervisor, Paths, SSH, Workflow}

  @git_diff_args ["--binary", "--full-index", "--no-ext-diff", "--no-textconv"]
  @remote_fingerprint_wrapper """
  set -euo pipefail
  export LC_ALL=C
  cd -- "$1"

  emit_component() {
    printf '%s\\000%s\\000' "$1" "$2"
  }

  emit_component head "$(git rev-parse --verify HEAD)"
  emit_component staged "$(git diff --cached --binary --full-index --no-ext-diff --no-textconv | git hash-object --stdin)"
  emit_component unstaged "$(git diff --binary --full-index --no-ext-diff --no-textconv | git hash-object --stdin)"

  while IFS= read -r -d '' path; do
    if [ -L "$path" ]; then
      type=symlink
      content_kind=target
      content_hash=$(readlink "./$path" | git hash-object --stdin)
    elif [ -f "$path" ]; then
      type=regular
      content_kind=bytes
      content_hash=$(git hash-object --no-filters -- "$path")
    elif [ -d "$path" ]; then
      type=directory
      content_kind=metadata
      content_hash=$(printf '%s' directory | git hash-object --stdin)
    elif [ -p "$path" ]; then
      type=fifo
      content_kind=metadata
      content_hash=$(printf '%s' fifo | git hash-object --stdin)
    elif [ -S "$path" ]; then
      type=socket
      content_kind=metadata
      content_hash=$(printf '%s' socket | git hash-object --stdin)
    elif [ -b "$path" ]; then
      type=device
      content_kind=block
      content_hash=$(printf '%s' block-device | git hash-object --stdin)
    elif [ -c "$path" ]; then
      type=device
      content_kind=character
      content_hash=$(printf '%s' character-device | git hash-object --stdin)
    elif [ -e "$path" ]; then
      type=other
      content_kind=metadata
      content_hash=$(printf '%s' other | git hash-object --stdin)
    else
      printf 'untracked path disappeared: %s\n' "$path" >&2
      exit 66
    fi

    emit_component untracked_path "$path"
    emit_component untracked_type "$type"
    emit_component untracked_content_kind "$content_kind"
    emit_component untracked_content "$content_hash"
  done < <(git ls-files --others --exclude-standard -z)
  """

  defmodule State do
    @moduledoc false
    defstruct root: nil,
              worker_supervisor: JobSupervisor,
              records: %{},
              calls: %{},
              active_single_flight: %{},
              workers: %{},
              monitors: %{},
              waiters: %{}
  end

  @type request :: %{
          required(:task_id) => String.t(),
          required(:task_identifier) => String.t(),
          required(:task_branch) => String.t(),
          required(:run_id) => String.t(),
          required(:call_id) => String.t(),
          required(:job) => map(),
          required(:arguments) => [String.t()],
          required(:workspace) => Path.t(),
          required(:worker_host) => String.t() | nil,
          required(:source_fingerprint) => String.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec run(request(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def run(request, server \\ __MODULE__) when is_map(request) do
    GenServer.call(server, {:run, request}, :infinity)
  end

  @spec result(String.t(), String.t(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def result(run_id, call_id, server \\ __MODULE__)
      when is_binary(run_id) and is_binary(call_id) do
    GenServer.call(server, {:result, run_id, call_id}, :infinity)
  end

  @spec cancel_run(String.t(), GenServer.server()) :: :ok
  def cancel_run(run_id, server \\ __MODULE__) when is_binary(run_id) do
    GenServer.call(server, {:cancel_run, run_id}, :infinity)
  end

  @spec active_for_run(String.t(), GenServer.server()) :: map() | nil
  def active_for_run(run_id, server \\ __MODULE__) when is_binary(run_id) do
    GenServer.call(server, {:active_for_run, run_id}, :infinity)
  end

  @spec source_fingerprint(Path.t(), String.t() | nil) :: String.t() | {:error, term()}
  def source_fingerprint(workspace, nil) when is_binary(workspace) do
    with git when is_binary(git) <- System.find_executable("git"),
         {:ok, head} <- git_output(git, workspace, ["rev-parse", "--verify", "HEAD"]),
         {:ok, staged} <- git_output(git, workspace, ["diff", "--cached" | @git_diff_args]),
         {:ok, unstaged} <- git_output(git, workspace, ["diff" | @git_diff_args]),
         {:ok, untracked_paths} <-
           git_output(git, workspace, ["ls-files", "--others", "--exclude-standard", "-z"]),
         {:ok, untracked} <- untracked_components(workspace, untracked_paths) do
      fingerprint_components([
        {"head", head},
        {"staged_diff", staged},
        {"unstaged_diff", unstaged}
        | untracked
      ])
    else
      nil -> {:error, :git_not_found}
      {:error, reason} -> {:error, {:source_fingerprint_failed, reason}}
    end
  rescue
    error -> {:error, {:source_fingerprint_failed, Exception.message(error)}}
  end

  def source_fingerprint(workspace, worker_host)
      when is_binary(workspace) and is_binary(worker_host) do
    command =
      "/bin/bash -c #{shell_escape(@remote_fingerprint_wrapper)} " <>
        "symphony-source-fingerprint #{shell_escape(workspace)}"

    case SSH.run(worker_host, command) do
      {:ok, {output, 0}} -> fingerprint_components([{"remote_git_state", output}])
      {:ok, {output, exit_code}} -> {:error, {:source_fingerprint_failed, worker_host, exit_code, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init(opts) do
    root = Keyword.get_lazy(opts, :root, &default_root/0)
    worker_supervisor = Keyword.get(opts, :worker_supervisor, JobSupervisor)

    with {:ok, records} <- JobStore.load(root),
         {:ok, recovered} <- interrupt_orphans(root, records) do
      {:ok, index_records(%State{root: root, worker_supervisor: worker_supervisor}, recovered)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:run, request}, from, state) do
    case normalize_request(request) do
      {:ok, normalized} -> attach_or_start(normalized, from, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:result, run_id, call_id}, _from, state) do
    reply =
      with {:ok, job_id} <- fetch_call(state, run_id, call_id),
           record <- Map.fetch!(state.records, job_id),
           false <- record["status"] == "running",
           {:ok, result} <- JobStore.result(record) do
        {:ok, result}
      else
        true -> {:error, :job_running}
        :error -> {:error, :job_not_found}
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:active_for_run, run_id}, _from, state) do
    active =
      state.records
      |> Map.values()
      |> Enum.filter(&(&1["run_id"] == run_id and &1["status"] == "running"))
      |> Enum.max_by(&{&1["started_at"] || "", &1["job_id"]}, fn -> nil end)

    {:reply, active, state}
  end

  def handle_call({:cancel_run, run_id}, _from, state) do
    state.records
    |> Enum.filter(fn {_job_id, record} -> record["run_id"] == run_id and record["status"] == "running" end)
    |> Enum.each(fn {job_id, _record} ->
      case state.workers[job_id] do
        pid when is_pid(pid) -> SymphonyElixir.JobWorker.cancel(pid)
        _ -> :ok
      end
    end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:job_terminal, job_id, status, exit_code, reason}, state) do
    case state.records[job_id] do
      %{"status" => "running"} = record ->
        finished_at = timestamp()

        updated =
          record
          |> Map.put("status", status)
          |> Map.put("exit_code", exit_code)
          |> Map.put("finished_at", finished_at)
          |> Map.put("elapsed_ms", elapsed_ms(record["started_at"], finished_at))
          |> maybe_put_reason(reason)

        case JobStore.persist(state.root, updated) do
          :ok -> reply_terminal(job_id, updated, state)
          {:error, persist_reason} -> reply_error(job_id, persist_reason, state)
        end

      _record ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {job_id, monitors} ->
        state = %{state | monitors: monitors}
        handle_worker_down(job_id, reason, state)
    end
  end

  defp handle_worker_down(job_id, reason, state) do
    case state.records[job_id] do
      %{"status" => "running"} = record -> interrupt_worker(job_id, reason, record, state)
      _record -> {:noreply, state}
    end
  end

  defp interrupt_worker(job_id, reason, record, state) do
    finished_at = timestamp()

    updated =
      record
      |> Map.put("status", "interrupted")
      |> Map.put("exit_code", nil)
      |> Map.put("finished_at", finished_at)
      |> Map.put("elapsed_ms", elapsed_ms(record["started_at"], finished_at))
      |> Map.put("failure_reason", inspect({:worker_exit, reason}))

    case JobStore.persist(state.root, updated) do
      :ok -> reply_terminal(job_id, updated, state)
      {:error, persist_reason} -> reply_error(job_id, persist_reason, state)
    end
  end

  defp attach_or_start(request, from, state) do
    call_key = {request.run_id, request.call_id}

    case state.calls[call_key] do
      nil -> attach_single_or_start(request, from, state)
      job_id -> attach_existing(job_id, from, state)
    end
  end

  defp attach_single_or_start(request, from, state) do
    case state.active_single_flight[request.single_flight_key] do
      nil -> start_job(request, from, state)
      job_id -> attach_single(job_id, request, from, state)
    end
  end

  defp attach_existing(job_id, from, state) do
    record = Map.fetch!(state.records, job_id)

    if record["status"] == "running" do
      {:noreply, add_waiter(state, job_id, from)}
    else
      {:reply, JobStore.result(record), state}
    end
  end

  defp attach_single(job_id, request, from, state) do
    record = Map.fetch!(state.records, job_id)
    call_ids = Enum.uniq(record["call_ids"] ++ [request.call_id])
    updated = Map.put(record, "call_ids", call_ids)

    case JobStore.persist(state.root, updated) do
      :ok ->
        state =
          state
          |> put_in([Access.key(:records), job_id], updated)
          |> put_in([Access.key(:calls), {request.run_id, request.call_id}], job_id)
          |> add_waiter(job_id, from)

        {:noreply, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp start_job(request, from, state) do
    job_id = Ecto.UUID.generate()
    started_at = timestamp()
    executable = request.executable
    argv = Enum.map(request.job["arguments"], &substitute_job_id(&1, job_id)) ++ request.arguments

    attrs = %{
      "job_id" => job_id,
      "job" => request.job["id"],
      "status" => "running",
      "exit_code" => nil,
      "task_id" => request.task_id,
      "task_identifier" => request.task_identifier,
      "task_branch" => request.task_branch,
      "run_id" => request.run_id,
      "call_ids" => [request.call_id],
      "single_flight_key" => request.single_flight_key,
      "started_at" => started_at,
      "finished_at" => nil,
      "elapsed_ms" => nil,
      "source_fingerprint" => request.source_fingerprint,
      "executable" => executable,
      "arguments" => argv,
      "environment" => request.job["environment"],
      "workspace" => request.workspace,
      "worker_host" => request.worker_host
    }

    case JobStore.create(state.root, attrs) do
      {:ok, record} ->
        case start_worker(state.worker_supervisor, worker_request(request, record, executable, argv)) do
          {:ok, pid} ->
            ref = Process.monitor(pid)

            next =
              state
              |> put_in([Access.key(:records), job_id], record)
              |> put_in([Access.key(:calls), {request.run_id, request.call_id}], job_id)
              |> put_in([Access.key(:active_single_flight), request.single_flight_key], job_id)
              |> put_in([Access.key(:workers), job_id], pid)
              |> put_in([Access.key(:monitors), ref], job_id)
              |> add_waiter(job_id, from)

            {:noreply, next}

          {:error, reason} ->
            interrupt_unstarted(record, reason, request, state)
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp normalize_request(request) do
    with {:ok, task_id} <- required_string(request, :task_id),
         {:ok, task_identifier} <- required_string(request, :task_identifier),
         {:ok, task_branch} <- required_string(request, :task_branch),
         {:ok, run_id} <- required_string(request, :run_id),
         {:ok, call_id} <- required_string(request, :call_id),
         {:ok, workspace} <- required_string(request, :workspace),
         {:ok, source_fingerprint} <- required_string(request, :source_fingerprint),
         {:ok, job} <- normalize_job(request[:job]),
         {:ok, arguments} <- passthrough_arguments(job, request[:arguments]),
         {:ok, executable} <- resolve_executable(workspace, job["executable"]),
         :ok <- validate_worker_host(request[:worker_host]) do
      single_flight_key =
        :crypto.hash(
          :sha256,
          Jason.encode!(%{
            task_id: task_id,
            job: job["id"],
            arguments: arguments,
            fixed_arguments: job["arguments"],
            source_fingerprint: source_fingerprint
          })
        )
        |> Base.encode16(case: :lower)

      {:ok,
       %{
         task_id: task_id,
         task_identifier: task_identifier,
         task_branch: task_branch,
         run_id: run_id,
         call_id: call_id,
         job: job,
         executable: executable,
         arguments: arguments,
         workspace: workspace,
         worker_host: request[:worker_host],
         source_fingerprint: source_fingerprint,
         single_flight_key: single_flight_key
       }}
    end
  end

  defp normalize_job(job) when is_map(job) do
    job = Map.new(job, fn {key, value} -> {to_string(key), value} end)

    with id when is_binary(id) and id != "" <- job["id"],
         executable when is_binary(executable) and executable != "" <- job["executable"],
         arguments when is_list(arguments) <- job["arguments"],
         true <- Enum.all?(arguments, &is_binary/1),
         environment when is_map(environment) <- job["environment"],
         true <- Enum.all?(environment, fn {key, value} -> valid_environment_key?(key) and is_binary(value) end),
         {:ok, policy} <- normalize_policy(job["passthrough_arguments"]) do
      {:ok,
       %{
         "id" => id,
         "executable" => executable,
         "arguments" => arguments,
         "passthrough_arguments" => policy,
         "environment" => environment
       }}
    else
      false -> {:error, :invalid_frozen_job_definition}
      nil -> {:error, :invalid_frozen_job_definition}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_frozen_job_definition}
    end
  end

  defp normalize_job(_job), do: {:error, :invalid_frozen_job_definition}

  defp passthrough_arguments(job, arguments) when is_list(arguments) do
    if Enum.all?(arguments, &is_binary/1) do
      case {job["passthrough_arguments"], arguments} do
        {:required, []} -> {:error, :job_arguments_required}
        {:forbidden, [_ | _]} -> {:error, :job_arguments_forbidden}
        {_policy, values} -> {:ok, values}
      end
    else
      {:error, :invalid_job_arguments}
    end
  end

  defp passthrough_arguments(_job, _arguments), do: {:error, :invalid_job_arguments}

  defp normalize_policy(value) when value in [:required, "required"], do: {:ok, :required}
  defp normalize_policy(value) when value in [:optional, "optional"], do: {:ok, :optional}
  defp normalize_policy(value) when value in [:forbidden, "forbidden"], do: {:ok, :forbidden}
  defp normalize_policy(_value), do: {:error, :invalid_job_passthrough_policy}

  defp required_string(request, key) do
    case request[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_job_request, key}}
    end
  end

  defp validate_worker_host(nil), do: :ok
  defp validate_worker_host(host) when is_binary(host) and host != "", do: :ok
  defp validate_worker_host(_host), do: {:error, :invalid_job_worker_host}

  defp worker_request(request, record, executable, argv) do
    environment =
      Map.merge(request.job["environment"], %{
        "SYMPHONY_MANAGED_RUN" => "1",
        "SYMPHONY_JOB_EXECUTOR" => "1",
        "SYMPHONY_TASK_ID" => request.task_id,
        "SYMPHONY_TASK_IDENTIFIER" => request.task_identifier,
        "SYMPHONY_TASK_BRANCH" => request.task_branch,
        "SYMPHONY_RUN_ID" => request.run_id,
        "SYMPHONY_JOB_ID" => record["job_id"],
        "SYMPHONY_JOB_STDOUT" => record["stdout_path"],
        "SYMPHONY_JOB_STDERR" => record["stderr_artifact"]
      })

    %{
      record: record,
      executable: executable,
      argv: argv,
      environment: environment,
      workspace: request.workspace,
      worker_host: request.worker_host
    }
  end

  defp start_worker(nil, _request), do: {:error, :job_worker_supervisor_unavailable}
  defp start_worker(JobSupervisor, request), do: JobSupervisor.start_job(request, self())

  defp start_worker(supervisor, request) do
    DynamicSupervisor.start_child(
      supervisor,
      {SymphonyElixir.JobWorker, request: request, manager: self()}
    )
  end

  defp reply_terminal(job_id, record, state) do
    state = put_in(state.records[job_id], record)

    case JobStore.result(record) do
      {:ok, result} ->
        Enum.each(Map.get(state.waiters, job_id, []), &GenServer.reply(&1, {:ok, result}))
        {:noreply, remove_active_job(state, job_id, record)}

      {:error, reason} ->
        reply_error(job_id, reason, state)
    end
  end

  defp interrupt_unstarted(record, reason, request, state) do
    finished_at = timestamp()

    interrupted =
      record
      |> Map.put("status", "interrupted")
      |> Map.put("finished_at", finished_at)
      |> Map.put("elapsed_ms", elapsed_ms(record["started_at"], finished_at))
      |> Map.put("failure_reason", inspect({:job_worker_start_failed, reason}))

    with :ok <- JobStore.persist(state.root, interrupted),
         {:ok, result} <- JobStore.result(interrupted) do
      next =
        state
        |> put_in([Access.key(:records), record["job_id"]], interrupted)
        |> put_in([Access.key(:calls), {request.run_id, request.call_id}], record["job_id"])

      {:reply, {:ok, result}, next}
    else
      {:error, persist_reason} -> {:reply, {:error, persist_reason}, state}
    end
  end

  defp reply_error(job_id, reason, state) do
    Enum.each(Map.get(state.waiters, job_id, []), &GenServer.reply(&1, {:error, reason}))

    record = state.records[job_id] || %{}
    {:noreply, remove_active_job(state, job_id, record)}
  end

  defp remove_active_job(state, job_id, record) do
    monitor_refs = for {ref, ^job_id} <- state.monitors, do: ref
    Enum.each(monitor_refs, &Process.demonitor(&1, [:flush]))

    %{
      state
      | records: Map.put(state.records, job_id, record),
        active_single_flight: Map.delete(state.active_single_flight, record["single_flight_key"]),
        workers: Map.delete(state.workers, job_id),
        monitors: Map.drop(state.monitors, monitor_refs),
        waiters: Map.delete(state.waiters, job_id)
    }
  end

  defp add_waiter(state, job_id, from) do
    update_in(state.waiters[job_id], fn waiters -> [from | waiters || []] end)
  end

  defp fetch_call(state, run_id, call_id) do
    case Map.fetch(state.calls, {run_id, call_id}) do
      {:ok, job_id} -> {:ok, job_id}
      :error -> :error
    end
  end

  defp interrupt_orphans(root, records) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
      case JobStore.interrupt_running(root, record) do
        {:ok, updated} -> {:cont, {:ok, [updated | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, recovered} -> {:ok, Enum.reverse(recovered)}
      error -> error
    end
  end

  defp index_records(state, records) do
    Enum.reduce(records, state, fn record, acc ->
      calls =
        Enum.reduce(record["call_ids"], acc.calls, fn call_id, call_acc ->
          Map.put(call_acc, {record["run_id"], call_id}, record["job_id"])
        end)

      %{acc | records: Map.put(acc.records, record["job_id"], record), calls: calls}
    end)
  end

  defp default_root do
    project_id =
      case Workflow.project_identity() do
        {:ok, %{id: id}} -> id
        _ -> "unconfigured"
      end

    Paths.jobs_root(project_id)
  end

  defp resolve_executable(workspace, executable) do
    if Path.type(executable) == :relative and String.contains?(executable, "/") do
      expanded_workspace = Path.expand(workspace)
      expanded_executable = Path.expand(executable, expanded_workspace)

      if String.starts_with?(expanded_executable, expanded_workspace <> "/"),
        do: {:ok, expanded_executable},
        else: {:error, {:job_executable_outside_worktree, executable}}
    else
      {:ok, executable}
    end
  end

  defp valid_environment_key?(key) when is_binary(key),
    do: Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, key)

  defp valid_environment_key?(_key), do: false

  defp substitute_job_id("$SYMPHONY_JOB_ID", job_id), do: job_id
  defp substitute_job_id(argument, _job_id), do: argument

  defp git_output(git, workspace, arguments) do
    case System.cmd(git, ["-C", workspace | arguments], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, exit_code} -> {:error, {:git_failed, exit_code, output}}
    end
  end

  defp untracked_components(workspace, paths) do
    paths
    |> :binary.split(<<0>>, [:global])
    |> Enum.reject(&(&1 == ""))
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, components} ->
      case untracked_identity(Path.join(workspace, path)) do
        {:ok, type, content} ->
          {:cont,
           {:ok,
            [
              {"untracked_content", content},
              {"untracked_type", type},
              {"untracked_path", path}
              | components
            ]}}

        {:error, reason} ->
          {:halt, {:error, {:untracked_file_unreadable, path, reason}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end

  defp untracked_identity(path) do
    with {:ok, stat} <- File.lstat(path) do
      case stat.type do
        :regular -> with {:ok, content} <- File.read(path), do: {:ok, "regular", content}
        :symlink -> with {:ok, target} <- File.read_link(path), do: {:ok, "symlink", target}
        type -> {:ok, Atom.to_string(type), <<>>}
      end
    end
  end

  defp fingerprint_components(components) do
    components
    |> Enum.reduce(:crypto.hash_init(:sha256), fn {tag, value}, context ->
      :crypto.hash_update(context, [
        <<byte_size(tag)::unsigned-big-integer-size(64)>>,
        tag,
        <<byte_size(value)::unsigned-big-integer-size(64)>>,
        value
      ])
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp maybe_put_reason(record, nil), do: Map.delete(record, "failure_reason")
  defp maybe_put_reason(record, reason), do: Map.put(record, "failure_reason", inspect(reason))

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp elapsed_ms(started_at, finished_at) do
    with {:ok, started, _offset} <- DateTime.from_iso8601(started_at),
         {:ok, finished, _offset} <- DateTime.from_iso8601(finished_at) do
      max(DateTime.diff(finished, started, :millisecond), 0)
    else
      _ -> 0
    end
  end

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
