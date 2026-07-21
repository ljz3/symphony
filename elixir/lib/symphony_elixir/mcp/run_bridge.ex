defmodule SymphonyElixir.MCP.RunBridge do
  @moduledoc """
  Authentication and lifecycle for run-scoped MCP bridges.

  Each active agent run gets one isolated MCP scope `{run_id, invocation}`
  (see `SymphonyElixir.MCP.RunTransport`) behind an HMAC-signed bearer token.
  The token is derived from a secret that lives only on the local filesystem
  (mode 0600, under the project runtime root) and never enters the
  Git-committed board history.

  These tokens prevent accidental cross-run routing through the configured
  endpoint. They are not a security boundary against the agent process
  itself: the agent runs unsandboxed with the same OS-user authority as
  Symphony (trusted-local-process model).
  """

  alias SymphonyElixir.{Config, HttpServer, Paths}
  alias SymphonyElixir.MCP.RunTransport

  @secret_bytes 32
  @secret_file_mode 0o600
  @await_port_timeout_ms 2_000

  @doc """
  Register the run's MCP scope and return its URL and bearer token.

  Called by the agent backend before it hands the MCP server list to the
  agent, so the HTTP endpoint must already be bound.
  """
  @spec register(String.t(), pos_integer()) :: {:ok, %{url: String.t(), token: String.t()}} | {:error, term()}
  def register(run_id, invocation) when is_binary(run_id) and is_integer(invocation) and invocation >= 1 do
    with {:ok, _registered} <- RunTransport.register_scope(run_id, invocation),
         {:ok, port} <- HttpServer.await_bound_port(@await_port_timeout_ms),
         {:ok, token} <- token(run_id, invocation) do
      {:ok, %{url: url(port, run_id, invocation), token: token}}
    else
      {:error, :timeout} -> {:error, :http_server_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Tear the run's MCP scope down, closing every MCP transport/server process
  associated with it. Idempotent.
  """
  @spec unregister(String.t(), pos_integer()) :: :ok
  def unregister(run_id, invocation) when is_binary(run_id) and is_integer(invocation) and invocation >= 1 do
    RunTransport.unregister_scope(run_id, invocation)
  end

  @doc """
  Tear down every MCP scope belonging to a run, regardless of invocation.

  Called when the orchestrator finalizes a run (including orphan recovery), so
  scopes leak neither when a runner is force-killed nor across restarts.
  Idempotent.
  """
  @spec unregister_run(String.t()) :: :ok
  def unregister_run(run_id) when is_binary(run_id) do
    RunTransport.unregister_run(run_id)
  end

  @spec token(String.t(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def token(run_id, invocation) when is_binary(run_id) and is_integer(invocation) and invocation >= 1 do
    with {:ok, secret} <- secret() do
      {:ok,
       :crypto.mac(:hmac, :sha256, secret, "#{run_id}:#{invocation}")
       |> Base.url_encode64()}
    end
  end

  @doc """
  Verify the request's bearer token for the route's `{run_id, invocation}`
  and return the scope's Plug configuration. Both the token check (which
  binds the invocation into the signed material) and the scope lookup must
  succeed, so a session id minted under one scope is useless at another.
  """
  @spec authorize(Plug.Conn.t(), String.t(), String.t()) :: {:ok, term()} | :error
  def authorize(conn, run_id, invocation_param) do
    with {:ok, invocation} <- parse_invocation(invocation_param),
         :ok <- verify_bearer(conn, run_id, invocation),
         {:ok, config} <- RunTransport.fetch_config(run_id, invocation) do
      {:ok, config}
    else
      _error -> :error
    end
  end

  defp parse_invocation(param) when is_binary(param) do
    case Integer.parse(param) do
      {invocation, ""} when invocation >= 1 -> {:ok, invocation}
      _ -> :error
    end
  end

  defp verify_bearer(conn, run_id, invocation) do
    with [header] <- Plug.Conn.get_req_header(conn, "authorization"),
         ["Bearer", presented] <- String.split(header),
         {:ok, expected} <- token(run_id, invocation),
         true <- Plug.Crypto.secure_compare(presented, expected) do
      :ok
    else
      _ -> :error
    end
  end

  defp url(port, run_id, invocation) do
    "http://127.0.0.1:#{port}/mcp/runs/#{run_id}/#{invocation}"
  end

  defp secret do
    with {:ok, bundle} <- Config.bundle() do
      path = Path.join(Paths.runtime_root(bundle.project.id), "mcp_run_secret")

      case File.read(path) do
        {:ok, secret} when byte_size(secret) == @secret_bytes ->
          {:ok, secret}

        _ ->
          generate_secret(path)
      end
    end
  end

  defp generate_secret(path) do
    secret = :crypto.strong_rand_bytes(@secret_bytes)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, secret, [:raw]),
         :ok <- File.chmod(path, @secret_file_mode) do
      {:ok, secret}
    else
      {:error, reason} -> {:error, {:mcp_run_secret_unavailable, reason}}
    end
  end
end
