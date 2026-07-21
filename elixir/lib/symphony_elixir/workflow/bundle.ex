defmodule SymphonyElixir.Workflow.Bundle do
  @moduledoc """
  A fully loaded, validated workflow and template bundle.

  The struct is immutable for the lifetime of an agent run. Hot reload swaps the
  active bundle only at a runtime quiescence point.
  """

  alias SymphonyElixir.AgentStage

  defmodule Job do
    @moduledoc "A validated project job definition."
    @derive Jason.Encoder
    @enforce_keys [:id, :executable, :arguments, :passthrough_arguments, :environment]
    defstruct @enforce_keys

    @type passthrough_arguments :: :required | :optional | :forbidden
    @type t :: %__MODULE__{
            id: String.t(),
            executable: String.t(),
            arguments: [String.t()],
            passthrough_arguments: passthrough_arguments(),
            environment: %{optional(String.t()) => String.t()}
          }
  end

  defmodule Column do
    @moduledoc "A workflow column."
    @derive Jason.Encoder
    @enforce_keys [:id, :name, :role, :position]
    defstruct [
      :id,
      :name,
      :role,
      :position,
      :stage_id,
      :on_claim,
      initial: false,
      publish_workpad: false,
      mark_pr_ready: false,
      satisfies_dependencies: false,
      successful: false
    ]

    @type role :: :dispatch | :merge | :pause | :blocked | :terminal
    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            role: role(),
            position: non_neg_integer(),
            stage_id: String.t() | nil,
            on_claim: String.t() | nil,
            initial: boolean(),
            publish_workpad: boolean(),
            mark_pr_ready: boolean(),
            satisfies_dependencies: boolean(),
            successful: boolean()
          }
  end

  @derive {Jason.Encoder,
           only: [
             :project,
             :source,
             :board,
             :agent,
             :backends,
             :codex,
             :hooks,
             :jobs,
             :dispatch,
             :merge,
             :columns,
             :human_transitions,
             :agent_transitions,
             :hash,
             :loaded_at
           ]}
  @enforce_keys [
    :path,
    :project,
    :source,
    :board,
    :agent,
    :backends,
    :hooks,
    :jobs,
    :dispatch,
    :merge,
    :base_prompt_path,
    :base_prompt,
    :context_prompt_path,
    :context_prompt,
    :stages,
    :columns,
    :human_transitions,
    :agent_transitions,
    :hash,
    :loaded_at
  ]
  defstruct @enforce_keys ++ [:codex]

  @type backend_config :: %{required(atom()) => String.t() | boolean() | nil}
  @type transition_map :: %{optional(String.t()) => [String.t()]}
  @type t :: %__MODULE__{
          path: Path.t(),
          project: %{id: String.t(), key: String.t()},
          source: map(),
          board: map(),
          agent: map(),
          backends: %{required(String.t()) => backend_config()},
          codex: backend_config() | nil,
          hooks: map(),
          jobs: %{optional(String.t()) => Job.t()},
          dispatch: %{preflight: map() | nil},
          merge: map() | nil,
          base_prompt_path: Path.t(),
          base_prompt: String.t(),
          context_prompt_path: Path.t(),
          context_prompt: String.t(),
          stages: %{required(String.t()) => AgentStage.t()},
          columns: [Column.t()],
          human_transitions: transition_map(),
          agent_transitions: transition_map(),
          hash: String.t(),
          loaded_at: String.t()
        }

  @root_keys ~w(project source board agent backends codex prompts stages columns transitions hooks jobs dispatch merge)
  @roles %{
    "dispatch" => :dispatch,
    "merge" => :merge,
    "pause" => :pause,
    "blocked" => :blocked,
    "terminal" => :terminal
  }

  @spec load(map(), Path.t()) :: {:ok, t()} | {:error, term()}
  def load(config, path) when is_map(config) and is_binary(path) do
    with :ok <- reject_schema_version(config),
         :ok <- validate_known_keys(config, @root_keys, "workflow"),
         {:ok, project} <- parse_project(config["project"]),
         {:ok, source} <- parse_source(config["source"] || %{}, path),
         {:ok, board} <- parse_board(config["board"] || %{}),
         {:ok, agent} <- parse_agent(config["agent"] || %{}),
         {:ok, backends} <- parse_backends(config),
         {:ok, hooks} <- parse_hooks(config["hooks"] || %{}),
         {:ok, jobs} <- parse_jobs(config["jobs"]),
         {:ok, dispatch} <- parse_dispatch(config["dispatch"]),
         {:ok, prompts} <- parse_prompts(config["prompts"], path),
         {:ok, stages} <- parse_stages(config["stages"], path, backends),
         {:ok, columns} <- parse_columns(config["columns"], stages),
         {:ok, merge} <- parse_merge(config["merge"]),
         {:ok, human_transitions, agent_transitions} <-
           parse_transitions(config["transitions"], columns),
         :ok <- validate_column_semantics(columns, stages, merge, human_transitions, agent_transitions) do
      loaded_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      hash = bundle_hash(config, prompts, stages)

      {:ok,
       %__MODULE__{
         path: path,
         project: project,
         source: source,
         board: board,
         agent: agent,
         backends: backends,
         codex: backends["codex"],
         hooks: hooks,
         jobs: jobs,
         dispatch: dispatch,
         merge: merge,
         base_prompt_path: prompts.base_path,
         base_prompt: prompts.base,
         context_prompt_path: prompts.context_path,
         context_prompt: prompts.context,
         stages: stages,
         columns: columns,
         human_transitions: human_transitions,
         agent_transitions: agent_transitions,
         hash: hash,
         loaded_at: loaded_at
       }}
    end
  end

  @spec column(t(), String.t()) :: Column.t() | nil
  def column(%__MODULE__{columns: columns}, id), do: Enum.find(columns, &(&1.id == id))

  @spec initial_column(t()) :: Column.t()
  def initial_column(%__MODULE__{columns: columns}), do: Enum.find(columns, & &1.initial)

  @spec blocked_column(t()) :: Column.t()
  def blocked_column(%__MODULE__{columns: columns}), do: Enum.find(columns, &(&1.role == :blocked))

  @spec done_column(t()) :: Column.t()
  def done_column(%__MODULE__{columns: columns}), do: Enum.find(columns, & &1.satisfies_dependencies)

  @spec transition_allowed?(t(), :human | :agent, String.t(), String.t()) :: boolean()
  def transition_allowed?(%__MODULE__{} = bundle, actor_type, from, to) do
    transitions = if actor_type == :agent, do: bundle.agent_transitions, else: bundle.human_transitions
    to in Map.get(transitions, from, [])
  end

  @spec reachable_stage_ids(t()) :: [String.t()]
  def reachable_stage_ids(%__MODULE__{} = bundle) do
    bundle.columns
    |> Enum.filter(&(&1.role == :dispatch))
    |> Enum.map(& &1.stage_id)
    |> Enum.uniq()
  end

  defp reject_schema_version(config) do
    if Map.has_key?(config, "schema_version") or Map.has_key?(config, "version") do
      {:error, :user_visible_schema_version_forbidden}
    else
      :ok
    end
  end

  defp parse_project(%{} = project) do
    with :ok <- validate_known_keys(project, ~w(id key), "project"),
         {:ok, id} <- required_string(project, "id", "project.id"),
         {:ok, key} <- required_string(project, "key", "project.key"),
         true <- Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/, id),
         true <- Regex.match?(~r/\A[A-Z][A-Z0-9]*\z/, key) do
      {:ok, %{id: id, key: key}}
    else
      false -> {:error, :invalid_project_identity}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_project(_project), do: {:error, :missing_project}

  defp parse_source(source, workflow_path) do
    with :ok <- validate_known_keys(source, ~w(remote), "source"),
         {:ok, remote} <- optional_string(source, "remote", "origin"),
         {:ok, root} <- source_root(workflow_path),
         {:ok, default_branch} <- default_branch(root, remote) do
      {:ok, %{root: root, remote: remote, default_branch: default_branch}}
    end
  end

  defp parse_board(board) do
    with :ok <- validate_known_keys(board, ~w(remote), "board"),
         {:ok, remote} <- nullable_string(board, "remote") do
      {:ok, %{remote: remote}}
    end
  end

  defp parse_agent(agent) do
    keys = ~w(max_concurrent_agents ssh_hosts max_concurrent_agents_per_host local_worker)

    with :ok <- reject_execution_limits(agent, ~w(max_turns_per_run), "agent"),
         :ok <- validate_known_keys(agent, keys, "agent"),
         {:ok, concurrency} <- positive_integer(agent, "max_concurrent_agents", 4),
         {:ok, hosts} <- string_list(agent, "ssh_hosts", []),
         {:ok, host_capacity} <- nullable_positive_integer(agent, "max_concurrent_agents_per_host"),
         {:ok, local_worker} <- boolean(agent, "local_worker", false) do
      {:ok,
       %{
         max_concurrent_agents: concurrency,
         ssh_hosts: hosts,
         max_concurrent_agents_per_host: host_capacity,
         local_worker: local_worker
       }}
    end
  end

  defp parse_backends(config) do
    declared = config["backends"]
    legacy = config["codex"]

    with :ok <- validate_backends_section(declared),
         :ok <- reject_duplicate_codex(declared, legacy),
         {:ok, backends} <- parse_declared_backends(declared || %{}),
         {:ok, backends} <- merge_legacy_codex(backends, legacy) do
      ensure_backend_present(backends, declared, legacy)
    end
  end

  defp validate_backends_section(nil), do: :ok
  defp validate_backends_section(%{}), do: :ok
  defp validate_backends_section(_declared), do: {:error, :invalid_backends}

  defp reject_duplicate_codex(declared, legacy) do
    if is_map(declared) and Map.has_key?(declared, "codex") and not is_nil(legacy) do
      {:error, {:duplicate_backend_definition, "codex"}}
    else
      :ok
    end
  end

  defp parse_declared_backends(declared) do
    declared
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {name, backend_config}, {:ok, acc} ->
      case parse_backend(name, backend_config) do
        {:ok, backend} -> {:cont, {:ok, Map.put(acc, name, backend)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_backend(name, %{} = backend_config) do
    with :ok <- valid_id(name, "backend"),
         {:ok, protocol} <- required_string(backend_config, "protocol", "backends.#{name}.protocol"),
         :ok <- validate_backend_protocol(name, protocol) do
      parse_backend_config(name, protocol, backend_config)
    end
  end

  defp parse_backend(name, _config), do: {:error, {:invalid_backend, name}}

  defp validate_backend_protocol(_name, "app_server"), do: :ok
  defp validate_backend_protocol(_name, "acp"), do: :ok
  defp validate_backend_protocol(name, protocol), do: {:error, {:unknown_backend_protocol, name, protocol}}

  defp parse_backend_config("codex", "app_server", backend_config) do
    codex_backend_config(backend_config, "backends.codex", ~w(protocol command approval_policy sandbox network_access))
  end

  defp parse_backend_config(name, "app_server", _backend_config) do
    {:error, {:app_server_protocol_requires_codex_name, name}}
  end

  defp parse_backend_config(name, "acp", backend_config) do
    context = "backends.#{name}"
    keys = ~w(protocol command permission_mode allow_unsandboxed)

    with :ok <- validate_known_keys(backend_config, keys, context),
         {:ok, command} <- required_string(backend_config, "command", "#{context}.command"),
         {:ok, permission_mode} <- optional_string(backend_config, "permission_mode", "auto"),
         :ok <- require_unsandboxed_acknowledgement(name, backend_config) do
      {:ok, %{protocol: "acp", command: command, permission_mode: permission_mode}}
    end
  end

  defp require_unsandboxed_acknowledgement(name, backend_config) do
    if backend_config["allow_unsandboxed"] == true do
      :ok
    else
      {:error, {:acp_unsandboxed_not_acknowledged, name}}
    end
  end

  defp merge_legacy_codex(backends, nil), do: {:ok, backends}

  defp merge_legacy_codex(backends, %{} = legacy) do
    with {:ok, codex} <- codex_backend_config(legacy, "codex", ~w(command approval_policy sandbox network_access)) do
      {:ok, Map.put(backends, "codex", codex)}
    end
  end

  defp merge_legacy_codex(_backends, _legacy), do: {:error, :invalid_codex_config}

  defp ensure_backend_present(backends, declared, legacy) do
    cond do
      map_size(backends) > 0 ->
        {:ok, backends}

      is_nil(declared) and is_nil(legacy) ->
        {:ok, %{"codex" => default_codex_backend()}}

      true ->
        {:error, :missing_backends}
    end
  end

  defp default_codex_backend do
    %{
      protocol: "app_server",
      command: "codex app-server",
      approval_policy: "never",
      thread_sandbox: "workspace-write",
      network_access: false
    }
  end

  defp codex_backend_config(config, context, allowed_keys) do
    with :ok <-
           reject_execution_limits(config, ~w(turn_timeout_ms read_timeout_ms stall_timeout_ms), context),
         :ok <- validate_known_keys(config, allowed_keys, context),
         {:ok, command} <- optional_string(config, "command", "codex app-server"),
         {:ok, sandbox} <- optional_string(config, "sandbox", "workspace-write"),
         {:ok, network_access} <- boolean(config, "network_access", false) do
      {:ok,
       %{
         protocol: "app_server",
         command: command,
         approval_policy: config["approval_policy"] || "never",
         thread_sandbox: sandbox,
         network_access: network_access
       }}
    end
  end

  defp parse_hooks(hooks) do
    keys = ~w(after_create before_run after_run before_remove)

    with :ok <- reject_execution_limits(hooks, ~w(timeout_ms), "hooks"),
         :ok <- validate_known_keys(hooks, keys, "hooks") do
      {:ok,
       %{
         after_create: blank_to_nil(hooks["after_create"]),
         before_run: blank_to_nil(hooks["before_run"]),
         after_run: blank_to_nil(hooks["after_run"]),
         before_remove: blank_to_nil(hooks["before_remove"])
       }}
    end
  end

  defp parse_jobs(nil), do: {:ok, %{}}

  defp parse_jobs(%{} = jobs) do
    jobs
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {id, config}, {:ok, acc} ->
      case parse_job(id, config) do
        {:ok, job} -> {:cont, {:ok, Map.put(acc, id, job)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_jobs(_jobs), do: {:error, :invalid_jobs}

  defp parse_job(id, %{} = config) do
    context = "jobs.#{id}"
    keys = ~w(executable arguments passthrough_arguments environment)

    with :ok <- valid_id(id, "job"),
         :ok <- reject_execution_limits(config, ~w(timeout_ms max_output_bytes), context),
         :ok <- validate_known_keys(config, keys, context),
         {:ok, executable} <- required_string(config, "executable", "#{context}.executable"),
         {:ok, arguments} <- job_arguments(config, id),
         {:ok, passthrough_arguments} <- passthrough_arguments(config, id),
         {:ok, environment} <- job_environment(config, id) do
      {:ok,
       %Job{
         id: id,
         executable: executable,
         arguments: arguments,
         passthrough_arguments: passthrough_arguments,
         environment: environment
       }}
    end
  end

  defp parse_job(id, _config), do: {:error, {:invalid_job, id}}

  defp parse_dispatch(nil), do: {:ok, %{preflight: nil}}

  defp parse_dispatch(%{} = dispatch) do
    with :ok <- validate_known_keys(dispatch, ~w(preflight), "dispatch"),
         {:ok, preflight} <- parse_preflight(Map.get(dispatch, "preflight")) do
      {:ok, %{preflight: preflight}}
    end
  end

  defp parse_dispatch(_dispatch), do: {:error, :invalid_dispatch}

  defp parse_preflight(nil), do: {:ok, nil}

  defp parse_preflight(%{} = preflight) do
    context = "dispatch.preflight"

    with :ok <- reject_execution_limits(preflight, ~w(timeout_ms max_output_bytes), context),
         :ok <- validate_known_keys(preflight, ~w(command retry_after_failure_ms), context),
         {:ok, command} <- required_string(preflight, "command", "#{context}.command"),
         {:ok, retry_after_failure_ms} <-
           required_positive_integer(preflight, "retry_after_failure_ms", "#{context}.retry_after_failure_ms") do
      {:ok, %{command: command, retry_after_failure_ms: retry_after_failure_ms}}
    end
  end

  defp parse_preflight(_preflight), do: {:error, :invalid_dispatch_preflight}

  defp parse_merge(nil), do: {:ok, nil}

  defp parse_merge(%{} = merge) do
    context = "merge"

    with :ok <- reject_execution_limits(merge, ~w(timeout_ms readiness_timeout_ms max_output_bytes), context),
         :ok <-
           validate_known_keys(
             merge,
             ~w(method readiness_command review_column conflict_column),
             context
           ),
         {:ok, "squash"} <- required_string(merge, "method", "#{context}.method"),
         {:ok, readiness_command} <-
           required_string(merge, "readiness_command", "#{context}.readiness_command"),
         {:ok, review_column} <- required_string(merge, "review_column", "#{context}.review_column"),
         {:ok, conflict_column} <- required_string(merge, "conflict_column", "#{context}.conflict_column") do
      {:ok,
       %{
         method: :squash,
         readiness_command: readiness_command,
         review_column: review_column,
         conflict_column: conflict_column
       }}
    else
      {:ok, method} -> {:error, {:unsupported_merge_method, method}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_merge(_merge), do: {:error, :invalid_merge}

  defp parse_prompts(%{} = prompts, workflow_path) do
    with :ok <- validate_known_keys(prompts, ~w(base context), "prompts"),
         {:ok, base_path} <- referenced_path(prompts, "base", workflow_path),
         {:ok, context_path} <- referenced_path(prompts, "context", workflow_path),
         {:ok, base} <- read_template(base_path),
         {:ok, context} <- read_template(context_path) do
      {:ok, %{base_path: base_path, base: base, context_path: context_path, context: context}}
    end
  end

  defp parse_prompts(_prompts, _workflow_path), do: {:error, :missing_prompts}

  defp parse_stages(%{} = stages, workflow_path, backends) when map_size(stages) > 0 do
    stages
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {id, config}, {:ok, acc} ->
      case parse_stage(id, config, workflow_path, backends) do
        {:ok, stage} -> {:cont, {:ok, Map.put(acc, id, stage)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_stages(_stages, _workflow_path, _backends), do: {:error, :missing_stages}

  defp parse_stage(id, %{} = config, workflow_path, backends) do
    with :ok <- valid_id(id, "stage"),
         :ok <- validate_known_keys(config, ~w(prompt workpad allowed_model_efforts allowed_models), "stages.#{id}"),
         {:ok, prompt_path} <- referenced_path(config, "prompt", workflow_path),
         {:ok, workpad_path} <- referenced_path(config, "workpad", workflow_path),
         {:ok, prompt} <- read_template(prompt_path),
         {:ok, workpad} <- read_template(workpad_path),
         {:ok, allowed} <- parse_stage_policy(config, id, backends) do
      {:ok,
       %AgentStage{
         id: id,
         prompt_path: prompt_path,
         prompt: prompt,
         workpad_template_path: workpad_path,
         workpad_template: workpad,
         allowed: allowed
       }}
    end
  end

  defp parse_stage(id, _config, _workflow_path, _backends), do: {:error, {:invalid_stage, id}}

  defp parse_stage_policy(config, stage_id, backends) do
    legacy = config["allowed_model_efforts"]
    structured = config["allowed_models"]

    cond do
      not is_nil(legacy) and not is_nil(structured) ->
        {:error, {:conflicting_model_policy_keys, stage_id}}

      not is_nil(structured) ->
        parse_allowed_models(structured, stage_id, backends)

      true ->
        parse_legacy_allowed_model_efforts(legacy, stage_id, backends)
    end
  end

  # Legacy flat `model => [efforts]` policy; always binds to the codex backend.
  defp parse_legacy_allowed_model_efforts(nil, stage_id, _backends), do: {:error, {:missing_model_policy, stage_id}}

  defp parse_legacy_allowed_model_efforts(allowed, stage_id, backends) do
    if Map.has_key?(backends, "codex") do
      case parse_allowed_model_efforts(allowed, stage_id) do
        {:ok, legacy_map} ->
          {:ok, for({model, efforts} <- legacy_map, effort <- efforts, do: {"codex", model, effort})}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, {:legacy_model_policy_requires_codex, stage_id}}
    end
  end

  defp parse_allowed_models(models, stage_id, backends) when is_list(models) and models != [] do
    models
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case parse_allowed_model_entry(entry, stage_id, backends) do
        {:ok, triples} -> {:cont, {:ok, acc ++ triples}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, triples} ->
        triples
        |> Enum.frequencies()
        |> Enum.find(fn {_triple, count} -> count > 1 end)
        |> case do
          nil -> {:ok, triples}
          {{backend, model, effort}, _count} -> {:error, {:duplicate_model_effort, stage_id, backend, model, effort}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_allowed_models(_models, stage_id, _backends), do: {:error, {:missing_model_policy, stage_id}}

  defp parse_allowed_model_entry(%{} = entry, stage_id, backends) do
    context = "stages.#{stage_id}.allowed_models"

    with :ok <- validate_known_keys(entry, ~w(backend model efforts), context),
         {:ok, backend} <- required_string(entry, "backend", "#{context}.backend"),
         :ok <- require_known_backend(backend, stage_id, backends),
         {:ok, model} <- required_string(entry, "model", "#{context}.model"),
         {:ok, efforts} <- allowed_entry_efforts(entry, stage_id, backend, model) do
      {:ok, Enum.map(efforts, &{backend, model, &1})}
    end
  end

  defp parse_allowed_model_entry(_entry, stage_id, _backends), do: {:error, {:invalid_model_policy_entry, stage_id}}

  defp require_known_backend(backend, stage_id, backends) do
    if Map.has_key?(backends, backend) do
      :ok
    else
      {:error, {:unknown_backend_in_stage_policy, stage_id, backend}}
    end
  end

  defp allowed_entry_efforts(entry, stage_id, backend, model) do
    case Map.get(entry, "efforts") do
      nil ->
        {:ok, [nil]}

      efforts when is_list(efforts) and efforts != [] ->
        if Enum.all?(efforts, &nonblank?/1) do
          {:ok, efforts}
        else
          {:error, {:invalid_efforts, stage_id, backend, model}}
        end

      _efforts ->
        {:error, {:invalid_efforts, stage_id, backend, model}}
    end
  end

  defp parse_allowed_model_efforts(%{} = allowed, stage_id) when map_size(allowed) > 0 do
    Enum.reduce_while(allowed, {:ok, %{}}, fn {model, efforts}, {:ok, acc} ->
      cond do
        not nonblank?(model) ->
          {:halt, {:error, {:invalid_model, stage_id, model}}}

        not is_list(efforts) or efforts == [] or Enum.any?(efforts, &(not nonblank?(&1))) ->
          {:halt, {:error, {:invalid_efforts, stage_id, model}}}

        length(efforts) != length(Enum.uniq(efforts)) ->
          {:halt, {:error, {:duplicate_efforts, stage_id, model}}}

        true ->
          {:cont, {:ok, Map.put(acc, model, efforts)}}
      end
    end)
  end

  defp parse_allowed_model_efforts(_allowed, stage_id), do: {:error, {:missing_model_policy, stage_id}}

  defp parse_columns(columns, stages) when is_list(columns) and columns != [] do
    columns
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {config, position}, {:ok, acc} ->
      case parse_column(config, position, stages) do
        {:ok, column} -> {:cont, {:ok, [column | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parsed} ->
        parsed = Enum.reverse(parsed)

        if Enum.uniq_by(parsed, & &1.id) == parsed do
          {:ok, parsed}
        else
          {:error, :duplicate_column_ids}
        end

      error ->
        error
    end
  end

  defp parse_columns(_columns, _stages), do: {:error, :missing_columns}

  defp parse_column(%{} = config, position, stages) do
    keys = ~w(id name role stage on_claim initial publish_workpad mark_pr_ready satisfies_dependencies successful)

    with :ok <- validate_known_keys(config, keys, "column"),
         {:ok, id} <- required_string(config, "id", "column.id"),
         :ok <- valid_id(id, "column"),
         {:ok, name} <- required_string(config, "name", "column.name"),
         {:ok, role} <- role(config["role"]),
         {:ok, stage_id} <- nullable_string(config, "stage"),
         :ok <- validate_stage_reference(role, stage_id, stages) do
      {:ok,
       %Column{
         id: id,
         name: name,
         role: role,
         position: position,
         stage_id: stage_id,
         on_claim: blank_to_nil(config["on_claim"]),
         initial: config["initial"] == true,
         publish_workpad: config["publish_workpad"] == true,
         mark_pr_ready: config["mark_pr_ready"] == true,
         satisfies_dependencies: config["satisfies_dependencies"] == true,
         successful: config["successful"] == true
       }}
    end
  end

  defp parse_column(_config, _position, _stages), do: {:error, :invalid_column}

  defp parse_transitions(%{} = transitions, columns) do
    with :ok <- validate_known_keys(transitions, ~w(human agent), "transitions"),
         {:ok, human} <- transition_map(transitions["human"] || %{}, columns, :human),
         {:ok, agent} <- transition_map(transitions["agent"] || %{}, columns, :agent) do
      {:ok, human, agent}
    end
  end

  defp parse_transitions(_transitions, _columns), do: {:error, :missing_transitions}

  defp transition_map(map, columns, actor) when is_map(map) do
    ids = MapSet.new(columns, & &1.id)

    Enum.reduce_while(map, {:ok, %{}}, fn {from, targets}, {:ok, acc} ->
      cond do
        not MapSet.member?(ids, from) ->
          {:halt, {:error, {:unknown_transition_source, actor, from}}}

        not is_list(targets) or Enum.any?(targets, &(not MapSet.member?(ids, &1))) ->
          {:halt, {:error, {:unknown_transition_target, actor, from}}}

        length(targets) != length(Enum.uniq(targets)) ->
          {:halt, {:error, {:duplicate_transition, actor, from}}}

        true ->
          {:cont, {:ok, Map.put(acc, from, targets)}}
      end
    end)
  end

  defp validate_column_semantics(columns, stages, merge, human_transitions, agent_transitions) do
    initial = Enum.filter(columns, & &1.initial)
    blocked = Enum.filter(columns, &(&1.role == :blocked))
    done = Enum.filter(columns, & &1.satisfies_dependencies)
    ready = Enum.filter(columns, & &1.mark_pr_ready)

    with :ok <- exactly_one(initial, :initial_column),
         :ok <- exactly_one(blocked, :blocked_column),
         :ok <- exactly_one(done, :dependency_satisfying_column),
         :ok <- at_most_one(ready, :mark_pr_ready_column),
         :ok <- validate_initial_column(List.first(initial)),
         :ok <- validate_done_column(List.first(done)),
         :ok <- validate_merge_columns(columns, merge),
         :ok <- validate_merge_transitions(columns, merge, human_transitions, agent_transitions) do
      validate_on_claim(columns, stages)
    end
  end

  defp validate_merge_columns(columns, nil) do
    case Enum.filter(columns, &(&1.role == :merge)) do
      [] -> :ok
      merge_columns -> {:error, {:merge_columns_require_configuration, Enum.map(merge_columns, & &1.id)}}
    end
  end

  defp validate_merge_columns(columns, merge) do
    merge_columns = Enum.filter(columns, &(&1.role == :merge))

    with :ok <- exactly_one(merge_columns, :merge_column),
         true <- merge.review_column != merge.conflict_column,
         :ok <- validate_merge_target(columns, merge.review_column, :review),
         :ok <- validate_merge_target(columns, merge.conflict_column, :conflict) do
      :ok
    else
      false -> {:error, :merge_review_and_conflict_columns_must_differ}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_merge_target(columns, id, kind) do
    case Enum.find(columns, &(&1.id == id)) do
      %Column{role: :dispatch} -> :ok
      nil -> {:error, {:unknown_merge_target, kind, id}}
      %Column{role: role} -> {:error, {:merge_target_not_dispatchable, kind, id, role}}
    end
  end

  defp validate_merge_transitions(_columns, nil, _human, _agent), do: :ok

  defp validate_merge_transitions(columns, merge, human, agent) do
    merge_column = Enum.find(columns, &(&1.role == :merge))
    review = Enum.find(columns, &(&1.id == merge.review_column))
    conflict = Enum.find(columns, &(&1.id == merge.conflict_column))
    blocked = Enum.find(columns, &(&1.role == :blocked))
    all_targets = Map.values(human) ++ Map.values(agent)
    conflict_targets = Map.get(agent, conflict.id, [])

    with true <- review.stage_id != conflict.stage_id,
         false <- Enum.any?(all_targets, &(merge_column.id in &1)),
         true <- Map.get(human, merge_column.id, []) == [],
         true <- Map.get(agent, merge_column.id, []) == [],
         true <- review.id in conflict_targets,
         true <- Enum.all?(conflict_targets, &(&1 in [review.id, blocked.id])) do
      :ok
    else
      _ -> {:error, :invalid_deterministic_merge_transitions}
    end
  end

  defp validate_initial_column(%Column{role: :pause}), do: :ok
  defp validate_initial_column(_column), do: {:error, :initial_column_must_pause}

  defp validate_done_column(%Column{role: :terminal, successful: true}), do: :ok
  defp validate_done_column(_column), do: {:error, :dependency_satisfying_column_must_be_successful_terminal}

  defp validate_on_claim(columns, stages) do
    Enum.reduce_while(columns, :ok, fn
      %Column{on_claim: nil}, :ok ->
        {:cont, :ok}

      %Column{role: :dispatch, stage_id: stage_id, on_claim: target_id}, :ok ->
        case validate_claim_target(columns, stages, stage_id, target_id) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      %Column{id: id}, :ok ->
        {:halt, {:error, {:on_claim_requires_dispatch, id}}}
    end)
  end

  defp validate_claim_target(columns, stages, stage_id, target_id) do
    case Enum.find(columns, &(&1.id == target_id)) do
      %Column{role: :dispatch, stage_id: ^stage_id} ->
        if Map.has_key?(stages, stage_id), do: :ok, else: {:error, :unknown_claim_stage}

      _ ->
        {:error, {:invalid_on_claim, target_id}}
    end
  end

  defp source_root(workflow_path) do
    directory = Path.dirname(workflow_path)

    case System.cmd("git", ["-C", directory, "rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {root, 0} -> {:ok, root |> String.trim() |> Path.expand()}
      {output, status} -> {:error, {:source_git_root_unavailable, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:source_git_root_unavailable, Exception.message(error)}}
  end

  defp default_branch(root, remote) do
    ref = "refs/remotes/#{remote}/HEAD"

    case System.cmd("git", ["-C", root, "symbolic-ref", "--short", ref], stderr_to_stdout: true) do
      {name, 0} ->
        case String.split(String.trim(name), "/", parts: 2) do
          [^remote, branch] when branch != "" -> {:ok, branch}
          _ -> {:error, {:invalid_remote_default_branch, remote}}
        end

      {_output, _status} ->
        fallback_default_branch(root, remote)
    end
  end

  defp fallback_default_branch(root, remote) do
    candidates = ["main", "master"]

    case Enum.find(candidates, fn branch ->
           match?(
             {_output, 0},
             System.cmd("git", ["-C", root, "show-ref", "--verify", "--quiet", "refs/remotes/#{remote}/#{branch}"], stderr_to_stdout: true)
           )
         end) do
      nil -> {:error, {:remote_default_branch_unavailable, remote}}
      branch -> {:ok, branch}
    end
  end

  defp referenced_path(config, key, workflow_path) do
    with {:ok, relative} <- required_string(config, key, key) do
      {:ok, Path.expand(relative, Path.dirname(workflow_path))}
    end
  end

  defp read_template(path) do
    with {:ok, content} <- File.read(path),
         :ok <- parse_solid(content, path) do
      {:ok, content}
    else
      {:error, reason} when is_atom(reason) -> {:error, {:template_read_failed, path, reason}}
      {:error, _reason} = error -> error
    end
  end

  defp parse_solid(content, path) do
    parsed = Solid.parse!(content)

    Enum.each(template_validation_assigns(), fn assigns ->
      _rendered = Solid.render!(parsed, assigns, strict_variables: true, strict_filters: true)
    end)

    :ok
  rescue
    error -> {:error, {:template_parse_error, path, Exception.message(error)}}
  end

  defp template_validation_assigns do
    criterion = %{
      "id" => "criterion-id",
      "text" => "criterion",
      "completed" => false,
      "evidence" => []
    }

    task = %{
      "id" => "task-id",
      "identifier" => "TASK-1",
      "title" => "Task title",
      "type" => "feature",
      "priority" => "normal",
      "brief" => "Task brief",
      "branch" => "feature/TASK-1",
      "column_id" => "in_progress",
      "revision" => 1
    }

    run = %{
      "id" => "run-id",
      "stage_id" => "implementation",
      "status" => "running",
      "backend" => "codex",
      "model" => "model",
      "effort" => "high",
      "claimed_at" => "2000-01-01T00:00:00Z",
      "started_at" => "2000-01-01T00:00:00Z",
      "updated_at" => "2000-01-01T00:00:00Z"
    }

    populated_task =
      Map.put(task, "block", %{
        "from_column_id" => "in_progress",
        "reason" => "Concrete blocker"
      })

    populated_run = Map.put(run, "worker_host", "worker.example")

    populated = %{
      "task" => populated_task,
      "run" => populated_run,
      "stage" => %{"id" => "implementation"},
      "source" => %{
        "head_sha" => String.duplicate("a", 40),
        "base_sha" => String.duplicate("b", 40),
        "clean" => true
      },
      "github" => %{
        "number" => 1,
        "url" => "https://github.example/pull/1",
        "state" => "open",
        "draft" => true,
        "head_sha" => String.duplicate("a", 40),
        "ready" => true,
        "merged" => false,
        "merge_sha" => String.duplicate("c", 40),
        "reachable" => false
      },
      "dependencies" => [
        %{
          "id" => "dependency-id",
          "identifier" => "TASK-0",
          "title" => "Dependency title",
          "column_id" => "done",
          "satisfied" => true
        }
      ],
      "criteria" => [criterion],
      "latest_workpad" => %{
        "run_id" => "prior",
        "stage_id" => "implementation",
        "status" => "completed",
        "finished_at" => "2000-01-01T00:00:00Z",
        "invocation" => 1,
        "updated_at" => "2000-01-01T00:00:00Z",
        "content" => "latest workpad"
      },
      "allowed_transitions" => [%{"id" => "review", "name" => "Review", "role" => "dispatch"}],
      "preflight" => %{
        "status" => "failed",
        "phase" => "completed",
        "fingerprint" => String.duplicate("d", 64),
        "reason" => "Preflight failed",
        "started_at" => "2000-01-01T00:00:00Z",
        "last_activity_at" => "2000-01-01T00:00:01Z",
        "completed_at" => "2000-01-01T00:00:02Z",
        "next_retry_at" => "2000-01-01T00:00:32Z"
      },
      "job" => %{
        "job_id" => "job-id",
        "job" => "targeted_validation",
        "status" => "running",
        "started_at" => "2000-01-01T00:00:00Z",
        "finished_at" => "2000-01-01T00:00:03Z",
        "elapsed_ms" => 3_000,
        "source_fingerprint" => String.duplicate("e", 64)
      },
      "workpad" => "workpad",
      "turn_number" => 1
    }

    first_run =
      populated
      |> Map.put("task", task)
      |> Map.put("run", run)
      |> Map.put("source", %{})
      |> Map.put("github", %{})
      |> Map.put("dependencies", [])
      |> Map.put("latest_workpad", nil)
      |> Map.delete("preflight")
      |> Map.delete("job")

    [first_run, populated]
  end

  defp bundle_hash(config, prompts, stages) do
    stage_templates =
      stages
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {id, stage} -> {id, stage.prompt, stage.workpad_template} end)

    :crypto.hash(:sha256, :erlang.term_to_binary({config, prompts, stage_templates}))
    |> Base.encode16(case: :lower)
  end

  defp validate_known_keys(map, allowed, context) do
    unknown = Map.keys(map) -- allowed
    if unknown == [], do: :ok, else: {:error, {:unknown_workflow_keys, context, Enum.sort(unknown)}}
  end

  defp required_string(map, key, context) do
    case map[key] do
      value when is_binary(value) ->
        if String.trim(value) == value and value != "", do: {:ok, value}, else: {:error, {:invalid_string, context}}

      _ ->
        {:error, {:missing_string, context}}
    end
  end

  defp optional_string(map, key, default) do
    case Map.get(map, key, default) do
      value when is_binary(value) ->
        if value != "" and String.trim(value) == value,
          do: {:ok, value},
          else: {:error, {:invalid_string, key}}

      _ ->
        {:error, {:invalid_string, key}}
    end
  end

  defp nullable_string(map, key) do
    case Map.get(map, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if value != "" and String.trim(value) == value,
          do: {:ok, value},
          else: {:error, {:invalid_string, key}}

      _ ->
        {:error, {:invalid_string, key}}
    end
  end

  defp string_list(map, key, default) do
    case Map.get(map, key, default) do
      values when is_list(values) ->
        if Enum.all?(values, &nonblank?/1), do: {:ok, Enum.uniq(values)}, else: {:error, {:invalid_string_list, key}}

      _ ->
        {:error, {:invalid_string_list, key}}
    end
  end

  defp job_arguments(map, id) do
    case Map.fetch(map, "arguments") do
      {:ok, arguments} when is_list(arguments) ->
        if Enum.all?(arguments, &is_binary/1) do
          validate_job_argument_tokens(arguments, id)
        else
          {:error, {:invalid_job_arguments, id}}
        end

      _ ->
        {:error, {:invalid_job_arguments, id}}
    end
  end

  defp validate_job_argument_tokens(arguments, id) do
    invalid =
      Enum.find(arguments, fn argument ->
        tokens = Regex.scan(~r/\$SYMPHONY_[A-Z0-9_]+/, argument) |> List.flatten()
        tokens != [] and not (argument == "$SYMPHONY_JOB_ID" and tokens == ["$SYMPHONY_JOB_ID"])
      end)

    if invalid,
      do: {:error, {:invalid_job_argument_token, id, invalid}},
      else: {:ok, arguments}
  end

  defp passthrough_arguments(map, id) do
    case map["passthrough_arguments"] do
      "required" -> {:ok, :required}
      "optional" -> {:ok, :optional}
      "forbidden" -> {:ok, :forbidden}
      _ -> {:error, {:invalid_job_passthrough_arguments, id}}
    end
  end

  defp job_environment(map, id) do
    case Map.fetch(map, "environment") do
      {:ok, %{} = environment} ->
        validate_job_environment(environment, id)

      _ ->
        {:error, {:invalid_job_environment, id}}
    end
  end

  defp validate_job_environment(environment, id) do
    if Enum.all?(environment, fn {key, value} -> valid_environment_key?(key) and is_binary(value) end) do
      {:ok, environment}
    else
      {:error, {:invalid_job_environment, id}}
    end
  end

  defp valid_environment_key?(key) when is_binary(key),
    do: Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, key)

  defp valid_environment_key?(_key), do: false

  defp positive_integer(map, key, default) do
    case Map.get(map, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:invalid_positive_integer, key}}
    end
  end

  defp required_positive_integer(map, key, context) do
    case Map.get(map, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:invalid_positive_integer, context}}
    end
  end

  defp nullable_positive_integer(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:invalid_positive_integer, key}}
    end
  end

  defp boolean(map, key, default) do
    case Map.get(map, key, default) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, {:invalid_boolean, key}}
    end
  end

  defp role(value) do
    case Map.fetch(@roles, value) do
      {:ok, role} -> {:ok, role}
      :error -> {:error, {:invalid_column_role, value}}
    end
  end

  defp validate_stage_reference(:dispatch, stage_id, stages) when is_binary(stage_id) do
    if Map.has_key?(stages, stage_id), do: :ok, else: {:error, {:unknown_stage, stage_id}}
  end

  defp validate_stage_reference(:dispatch, nil, _stages), do: {:error, :dispatch_column_requires_stage}
  defp validate_stage_reference(_role, nil, _stages), do: :ok
  defp validate_stage_reference(_role, stage_id, _stages), do: {:error, {:stage_on_non_dispatch_column, stage_id}}

  defp valid_id(id, context) do
    if is_binary(id) and Regex.match?(~r/\A[a-z][a-z0-9_-]*\z/, id) do
      :ok
    else
      {:error, {:invalid_id, context, id}}
    end
  end

  defp exactly_one([_], _name), do: :ok
  defp exactly_one(values, name), do: {:error, {:expected_exactly_one, name, length(values)}}

  defp at_most_one(values, _name) when length(values) <= 1, do: :ok
  defp at_most_one(values, name), do: {:error, {:expected_at_most_one, name, length(values)}}

  defp blank_to_nil(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp blank_to_nil(_value), do: nil

  defp reject_execution_limits(map, forbidden, context) do
    present = Map.keys(map) |> Enum.filter(&(&1 in forbidden)) |> Enum.sort()

    if present == [],
      do: :ok,
      else: {:error, {:execution_limits_forbidden, context, present}}
  end

  defp nonblank?(value), do: is_binary(value) and value != "" and String.trim(value) == value
end
