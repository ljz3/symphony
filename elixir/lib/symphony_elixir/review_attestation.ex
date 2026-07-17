defmodule SymphonyElixir.ReviewAttestation do
  @moduledoc "Canonical fingerprints for state bound to an exact review attestation."

  @doc "Hashes the exact acceptance-criterion multiset and each criterion's current evidence."
  @spec criteria_fingerprint([map()]) :: String.t()
  def criteria_fingerprint(criteria) when is_list(criteria) do
    canonical =
      criteria
      |> Enum.map(fn criterion ->
        %{
          "id" => value(criterion, "id"),
          "text" => value(criterion, "text"),
          "completed" => value(criterion, "completed"),
          "evidence" => canonical_value(value(criterion, "evidence"))
        }
      end)
      |> Enum.sort_by(&:erlang.term_to_binary(&1, [:deterministic]))

    :sha256
    |> :crypto.hash(:erlang.term_to_binary(canonical, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp canonical_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), canonical_value(nested)} end)
  end

  defp canonical_value(value) when is_list(value), do: Enum.map(value, &canonical_value/1)
  defp canonical_value(value), do: value

  defp value(map, key), do: Map.get(map, key, Map.get(map, atom_key(key)))

  defp atom_key("id"), do: :id
  defp atom_key("text"), do: :text
  defp atom_key("completed"), do: :completed
  defp atom_key("evidence"), do: :evidence
end
