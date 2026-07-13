defmodule SymphonyElixir.Board.Event do
  @moduledoc """
  Versioned immutable event envelope stored as one JSON file per Git commit.
  """

  @format_version 1

  @derive Jason.Encoder
  @enforce_keys [
    :format_version,
    :sequence,
    :event_id,
    :command_id,
    :idempotency_key,
    :project_id,
    :task_revision,
    :actor,
    :timestamp,
    :type,
    :payload
  ]
  defstruct [
    :format_version,
    :sequence,
    :event_id,
    :command_id,
    :idempotency_key,
    :project_id,
    :task_id,
    :run_id,
    :task_revision,
    :actor,
    :timestamp,
    :type,
    :payload,
    :git_oid
  ]

  @type actor :: %{
          required(:type) => :human | :agent | :system,
          required(:identity) => String.t()
        }
  @type t :: %__MODULE__{
          format_version: pos_integer(),
          sequence: pos_integer(),
          event_id: String.t(),
          command_id: String.t(),
          idempotency_key: String.t(),
          project_id: String.t(),
          task_id: String.t() | nil,
          run_id: String.t() | nil,
          task_revision: non_neg_integer(),
          actor: actor(),
          timestamp: String.t(),
          type: String.t(),
          payload: map(),
          git_oid: String.t() | nil
        }

  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    struct!(__MODULE__,
      format_version: @format_version,
      sequence: Keyword.fetch!(attrs, :sequence),
      event_id: Keyword.get_lazy(attrs, :event_id, &Ecto.UUID.generate/0),
      command_id: Keyword.get_lazy(attrs, :command_id, &Ecto.UUID.generate/0),
      idempotency_key: Keyword.fetch!(attrs, :idempotency_key),
      project_id: Keyword.fetch!(attrs, :project_id),
      task_id: Keyword.get(attrs, :task_id),
      run_id: Keyword.get(attrs, :run_id),
      task_revision: Keyword.get(attrs, :task_revision, 0),
      actor: Keyword.fetch!(attrs, :actor),
      timestamp:
        Keyword.get_lazy(attrs, :timestamp, fn ->
          DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
        end),
      type: Keyword.fetch!(attrs, :type),
      payload: Keyword.fetch!(attrs, :payload),
      git_oid: Keyword.get(attrs, :git_oid)
    )
  end

  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = event), do: Jason.encode!(event, pretty: true)

  @spec decode(String.t()) :: {:ok, t()} | {:error, term()}
  def decode(json) when is_binary(json) do
    with {:ok, map} <- Jason.decode(json),
         :ok <- validate_version(map["format_version"]) do
      {:ok,
       %__MODULE__{
         format_version: map["format_version"],
         sequence: map["sequence"],
         event_id: map["event_id"],
         command_id: map["command_id"],
         idempotency_key: map["idempotency_key"],
         project_id: map["project_id"],
         task_id: map["task_id"],
         run_id: map["run_id"],
         task_revision: map["task_revision"],
         actor: decode_actor(map["actor"]),
         timestamp: map["timestamp"],
         type: map["type"],
         payload: map["payload"],
         git_oid: nil
       }}
    end
  end

  @spec format_version() :: pos_integer()
  def format_version, do: @format_version

  defp validate_version(@format_version), do: :ok
  defp validate_version(version), do: {:error, {:unsupported_event_format, version}}

  defp decode_actor(%{"type" => type, "identity" => identity}) do
    %{type: actor_type(type), identity: identity}
  end

  defp actor_type("human"), do: :human
  defp actor_type("agent"), do: :agent
  defp actor_type("system"), do: :system
  defp actor_type(type) when is_atom(type), do: type
end
