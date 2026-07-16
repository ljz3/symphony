defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Renders the four-layer run prompt and fresh stage workpads from frozen bundles.
  """

  alias SymphonyElixir.{Board, CurrentState, Task}

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

  @spec continuation_prompt(pos_integer()) :: String.t()
  def continuation_prompt(turn_number) when is_integer(turn_number) and turn_number > 1 do
    """
    Continue the current stage from the existing worktree and shared workpad.
    This is continuation turn #{turn_number} in the same run and Codex session.
    Do not restart completed investigation. Finish the remaining work and make a
    required task transition before this invocation ends.
    """
    |> String.trim()
  end

  @spec runner_contract() :: String.t()
  def runner_contract, do: String.trim(@runner_contract)

  defp assigns(task, run, opts) do
    bundle = run["frozen_bundle"]
    stage = %{"id" => get_in(bundle, ["stage", "id"])}

    task
    |> CurrentState.project(run, bundle)
    |> Map.merge(%{
      "stage" => stage,
      "latest_workpad" => Board.latest_workpad(task.id, run["id"]),
      "workpad" => Keyword.get(opts, :workpad, ""),
      "turn_number" => Keyword.get(opts, :turn_number, 1)
    })
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
