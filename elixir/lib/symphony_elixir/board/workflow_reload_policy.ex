defmodule SymphonyElixir.Board.WorkflowReloadPolicy do
  @moduledoc """
  Selects tasks that a workflow reload may move to Blocked.

  Reloads must preserve tasks in the user-facing protected columns, even when
  their saved stage selections no longer match the new workflow bundle.
  """

  alias SymphonyElixir.AgentStage
  alias SymphonyElixir.Task
  alias SymphonyElixir.Workflow.Bundle

  @protected_column_ids ~w(backlog todo blocked done cancelled)
  @active_runtime_states ~w(starting running stopping)

  @spec incompatible_tasks([Task.t()], Bundle.t()) :: [Task.t()]
  def incompatible_tasks(tasks, current) when is_list(tasks) do
    tasks
    |> Enum.reject(&runtime_active?/1)
    |> Enum.reject(fn task -> protected_column?(task, current) end)
    |> Enum.filter(fn task -> incompatible_selections?(task, current) end)
  end

  defp runtime_active?(%Task{runtime_state: state}), do: state in @active_runtime_states

  defp protected_column?(%Task{column_id: column_id}, current) do
    column_id in @protected_column_ids or
      case Bundle.column(current, column_id) do
        %{role: role} when role in [:blocked, :terminal] -> true
        _ -> false
      end
  end

  defp incompatible_selections?(task, current) do
    Enum.any?(task.stage_selections, fn {stage_id, selection} ->
      case current.stages[stage_id] do
        nil ->
          true

        stage ->
          not AgentStage.permits?(
            stage,
            selection["backend"] || "codex",
            selection["model"],
            selection["effort"]
          )
      end
    end)
  end
end
