defmodule SymphonyElixir.Board.Commands do
  @moduledoc "Typed commands accepted by the serialized board writer."

  defmodule CreateTask do
    @moduledoc "Create a task in the configured initial column."
    defstruct [:attrs]
    @type t :: %__MODULE__{attrs: map()}
  end

  defmodule UpdateTask do
    @moduledoc "Update mutable task contract fields."
    defstruct [:task_id, :attrs]
    @type t :: %__MODULE__{task_id: String.t(), attrs: map()}
  end

  defmodule MoveTask do
    @moduledoc "Transition a task to another workflow column."
    defstruct [:task_id, :column_id, :rank, :reason, force: false]

    @type t :: %__MODULE__{
            task_id: String.t(),
            column_id: String.t(),
            rank: integer() | nil,
            reason: String.t() | nil,
            force: boolean()
          }
  end

  defmodule ReorderTask do
    @moduledoc "Assign a task a sparse rank within its current column."
    defstruct [:task_id, :before_task_id, :after_task_id]

    @type t :: %__MODULE__{
            task_id: String.t(),
            before_task_id: String.t() | nil,
            after_task_id: String.t() | nil
          }
  end

  defmodule ArchiveTask do
    @moduledoc "Archive a terminal or cancelled task by tombstone."
    defstruct [:task_id]
    @type t :: %__MODULE__{task_id: String.t()}
  end

  defmodule CompleteAcceptance do
    @moduledoc "Complete one acceptance criterion, with agent evidence when required."
    defstruct [:task_id, :criterion_id, evidence: []]
    @type t :: %__MODULE__{task_id: String.t(), criterion_id: String.t(), evidence: [map()]}
  end

  defmodule ReopenAcceptance do
    @moduledoc "Reopen one acceptance criterion."
    defstruct [:task_id, :criterion_id, :reason]
    @type t :: %__MODULE__{task_id: String.t(), criterion_id: String.t(), reason: String.t() | nil}
  end

  defmodule BlockTask do
    @moduledoc "Move a task immediately to the unique Blocked column."
    defstruct [:task_id, :reason]
    @type t :: %__MODULE__{task_id: String.t(), reason: String.t()}
  end

  defmodule ResumeTask do
    @moduledoc "Resume a blocked task to its recorded prior column."
    defstruct [:task_id]
    @type t :: %__MODULE__{task_id: String.t()}
  end

  defmodule ClaimRun do
    @moduledoc "Atomically claim a dispatchable task and freeze its stage bundle."
    defstruct [:task_id, :worker_host]
    @type t :: %__MODULE__{task_id: String.t(), worker_host: String.t() | nil}
  end

  defmodule RunStarted do
    @moduledoc "Mark a claimed run as running."
    defstruct [:task_id, :run_id, :session_id, :workspace_path]

    @type t :: %__MODULE__{
            task_id: String.t(),
            run_id: String.t(),
            session_id: String.t(),
            workspace_path: Path.t()
          }
  end

  defmodule RunFinished do
    @moduledoc "Finish a run after a required workflow transition."
    defstruct [:task_id, :run_id, :outcome, :stats]

    @type t :: %__MODULE__{
            task_id: String.t(),
            run_id: String.t(),
            outcome: map(),
            stats: map() | nil
          }
  end

  defmodule RunFailed do
    @moduledoc "Fail a run and block its task without retry."
    defstruct [:task_id, :run_id, :reason, :stats]

    @type t :: %__MODULE__{
            task_id: String.t(),
            run_id: String.t(),
            reason: term(),
            stats: map() | nil
          }
  end

  defmodule RecordSourceHead do
    @moduledoc "Record a reconciled source worktree or remote head."
    defstruct [:task_id, :head_sha, :base_sha, :clean]

    @type t :: %__MODULE__{
            task_id: String.t(),
            head_sha: String.t(),
            base_sha: String.t() | nil,
            clean: boolean()
          }
  end

  defmodule LinkPullRequest do
    @moduledoc "Record canonical pull-request metadata."
    defstruct [:task_id, :run_id, :number, :url, :head_sha, :state, :draft, :created_by_run_id]

    @type t :: %__MODULE__{
            task_id: String.t(),
            run_id: String.t(),
            number: pos_integer(),
            url: String.t(),
            head_sha: String.t(),
            state: String.t(),
            draft: boolean(),
            created_by_run_id: String.t() | nil
          }
  end

  defmodule RecordGitHubOutcome do
    @moduledoc "Record readiness, publication, closure, or merge saga state."
    defstruct [:task_id, :kind, :attrs]
    @type t :: %__MODULE__{task_id: String.t(), kind: String.t(), attrs: map()}
  end

  defmodule RecordRunStatsPublication do
    @moduledoc "Record the successful GitHub publication of terminal run statistics."
    defstruct [:task_id, :run_id, :destination, :publication_id]

    @type t :: %__MODULE__{
            task_id: String.t(),
            run_id: String.t(),
            destination: String.t(),
            publication_id: String.t()
          }
  end

  @type t ::
          CreateTask.t()
          | UpdateTask.t()
          | MoveTask.t()
          | ReorderTask.t()
          | ArchiveTask.t()
          | CompleteAcceptance.t()
          | ReopenAcceptance.t()
          | BlockTask.t()
          | ResumeTask.t()
          | ClaimRun.t()
          | RunStarted.t()
          | RunFinished.t()
          | RunFailed.t()
          | RecordSourceHead.t()
          | LinkPullRequest.t()
          | RecordGitHubOutcome.t()
          | RecordRunStatsPublication.t()

  @spec type(t()) :: String.t()
  def type(%module{}) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end
end
