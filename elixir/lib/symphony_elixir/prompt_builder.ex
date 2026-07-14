defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Renders the four-layer run prompt and fresh stage workpads from frozen bundles.
  """

  alias SymphonyElixir.Board
  alias SymphonyElixir.Task

  @render_opts [strict_variables: true, strict_filters: true]
  @runner_contract """
  # Symphony runner contract

  - Work only in the task worktree supplied as the current working directory.
  - Never read from, write to, or run a Codex turn in the source repository checkout.
  - Use only the run-scoped Symphony tools advertised for this task and run.
  - This execution is non-interactive; do not request human input.
  - Keep the stage workpad current with decisions, validation, and handoff evidence.
  - Before the invocation ends, call `symphony_task_transition` to a permitted different column.
  - If work cannot continue, transition to `blocked` and include a precise reason.
  """

  @spec build_prompt(Task.t(), map(), keyword()) :: String.t()
  def build_prompt(%Task{} = task, run, opts \\ []) when is_map(run) do
    frozen = Map.fetch!(run, "frozen_bundle")
    assigns = assigns(task, run, opts)

    [
      String.trim(@runner_contract),
      render!(frozen["base_prompt"], assigns, "base prompt"),
      render!(frozen["context_prompt"], assigns, "context prompt"),
      render!(frozen["stage"]["prompt"], assigns, "stage prompt")
    ]
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @spec render_workpad(Task.t(), map(), keyword()) :: String.t()
  def render_workpad(%Task{} = task, run, opts \\ []) when is_map(run) do
    run
    |> get_in(["frozen_bundle", "stage", "workpad_template"])
    |> render!(assigns(task, run, opts), "workpad template")
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  @spec continuation_prompt(pos_integer(), pos_integer()) :: String.t()
  def continuation_prompt(turn_number, max_turns)
      when is_integer(turn_number) and turn_number > 1 and is_integer(max_turns) and max_turns >= turn_number do
    """
    Continue the current stage from the existing worktree and shared workpad.
    This is turn #{turn_number} of #{max_turns} in the same run and Codex session.
    Do not restart completed investigation. Finish the remaining work and make a
    required task transition before this invocation ends.
    """
    |> String.trim()
  end

  @spec runner_contract() :: String.t()
  def runner_contract, do: String.trim(@runner_contract)

  defp assigns(task, run, opts) do
    bundle = run["frozen_bundle"]
    stage = bundle["stage"]
    dependencies = dependency_maps(task.dependencies)
    transitions = allowed_transition_maps(task.column_id, bundle["agent_transitions"], bundle["columns"])

    %{
      "task" => Task.to_map(task),
      "run" => run,
      "stage" => stage,
      "github" => task.github,
      "dependencies" => dependencies,
      "criteria" => task.acceptance_criteria,
      "prior_handoffs" => prior_handoffs(task.id),
      "allowed_transitions" => transitions,
      "workpad" => Keyword.get(opts, :workpad, ""),
      "turn_number" => Keyword.get(opts, :turn_number, 1)
    }
  end

  defp dependency_maps(ids) do
    Enum.flat_map(ids, fn id ->
      case Board.task(id) do
        {:ok, task} -> [Task.to_map(task)]
        {:error, _reason} -> []
      end
    end)
  end

  defp allowed_transition_maps(column_id, transitions, columns) do
    allowed = Map.get(transitions, column_id, [])
    Enum.filter(columns, &(&1["id"] in allowed))
  end

  defp prior_handoffs(task_id) do
    task_id
    |> Board.runs()
    |> Enum.reject(&(&1["status"] in ["starting", "running", "stopping"]))
    |> Enum.map(fn run ->
      %{
        "run_id" => run["id"],
        "stage_id" => run["stage_id"],
        "status" => run["status"],
        "outcome" => run["outcome"],
        "finished_at" => run["finished_at"],
        "workpads" =>
          if(run["status"] in ["completed", "failed", "stopped"],
            do: Board.workpad_metadata(run["id"]),
            else: []
          )
      }
    end)
  end

  defp render!(template, assigns, label) when is_binary(template) do
    template
    |> Solid.parse!()
    |> Solid.render!(assigns, @render_opts)
    |> IO.iodata_to_binary()
  rescue
    error ->
      reraise RuntimeError,
              [message: "#{label} render failed: #{Exception.message(error)}"],
              __STACKTRACE__
  end
end
