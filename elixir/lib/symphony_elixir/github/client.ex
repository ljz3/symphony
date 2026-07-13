defmodule SymphonyElixir.GitHub.Client do
  @moduledoc "Service-owned GitHub CLI client used for all GitHub API operations."

  @spec run([String.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(args, opts \\ []) when is_list(args) do
    with {:ok, output, _status} <- run_with_status(args, opts) do
      {:ok, output}
    end
  end

  @spec run_with_status([String.t()], keyword()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, term()}
  def run_with_status(args, opts \\ []) when is_list(args) do
    case System.find_executable("gh") do
      nil -> {:error, :gh_not_found}
      executable -> run_executable(executable, args, opts)
    end
  rescue
    error -> {:error, {:gh_command_failed, args, Exception.message(error)}}
  end

  @spec json([String.t()], keyword()) :: {:ok, map() | list()} | {:error, term()}
  def json(args, opts \\ []) do
    with {:ok, output} <- run(args, opts),
         {:ok, decoded} <- Jason.decode(output) do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, {:gh_invalid_json, args, error}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put_cd(opts, nil), do: opts
  defp maybe_put_cd(opts, directory), do: Keyword.put(opts, :cd, directory)

  defp run_executable(executable, args, opts) do
    directory = Keyword.get(opts, :cd)
    accepted = Keyword.get(opts, :accepted_statuses, [0])
    command_opts = [stderr_to_stdout: true] |> maybe_put_cd(directory)

    {output, status} = System.cmd(executable, args, command_opts)

    if status in accepted,
      do: {:ok, output, status},
      else: {:error, {:gh_failed, args, status, String.trim(output)}}
  end
end
