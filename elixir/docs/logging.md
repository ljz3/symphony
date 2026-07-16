# Logging Best Practices

This guide defines stable, searchable logging conventions for the Git-backed Symphony runtime.

## Goals

- Correlate one project, task, run, Codex session, and worker without reconstructing state manually.
- Capture enough lifecycle and event-history context to diagnose failures after restart.
- Keep recurring messages stable enough for operational searches and alerts.
- Avoid leaking prompts, workpads, credentials, or large protocol payloads.

## Context fields

Include these fields whenever they apply:

- `project_id`: immutable workflow project ID.
- `task_id`: internal task UUID.
- `task_identifier`: human identifier such as `SYM-42`.
- `run_id`: durable stage-run UUID.
- `stage_id`: named workflow stage.
- `session_id`: Codex thread ID, or the established thread/turn correlation value.
- `mcp_request_key`: non-sensitive hash used to correlate one MCP JSON-RPC request; creation also
  uses its session/request hash for idempotent replay.
- `worker_host`: `local` or the selected SSH host.

For canonical board writes and recovery, also include:

- `event_sequence`: global event sequence.
- `event_id`: immutable event UUID.
- `event_oid`: Git commit OID when known.
- `task_revision`: optimistic-concurrency revision.

For external effects, include the durable saga/effect identifier and PR number when available.

## Message design

- Use explicit `key=value` pairs for high-signal fields.
- Use deterministic lifecycle wording and state the outcome: `completed`, `failed`, `blocked`,
  `waiting`, or `recovered`.
- Include one concise reason for failure or gating.
- Distinguish desired board state from observed runtime state while an agent is stopping.
- Describe optional board-remote and GitHub publication backoff as sync/publication retry, never as
  an agent retry.
- Never log GitHub tokens, Codex auth data, entire prompts, full workpads, or arbitrary tool payloads.

## Module guidance

- `Board.Writer` and `Board.History`: command acceptance, event commit/projection, CAS failure,
  replay, checkpoint, divergence, and reconciliation with event and revision context.
- `Orchestrator`: dispatch gates, preflight start/pass/failure/cancellation with task revision,
  workflow hash and worker context, claim, dependency/capacity decisions, stop requests, orphan
  recovery, external-effect progress, worker exit, and terminal cleanup with task/run context.
- `AgentRunner`: invocation start/completion/blocking with task/run/stage/worker context and
  `session_id` once known.
- `Codex.AppServer`: session/turn lifecycle and protocol errors with task/run/session context.
- `MCP.Handler`: guarded completion/failure for the three external task tools with MCP
  session/request correlation; never log tool arguments, task content, task briefs, workpads, or
  raw lookup/list results. Creation retains its hashed session/request idempotency key.
- `Worktree`: managed path, branch, source head, hook, cleanup, and safety rejection with task and
  worker context.
- `Board.Sync` and `GitHub`: remote/OID state, publication wait, readiness gates, and PR effects.

## Checklist

- Can this line be joined to `project_id`, `task_id`, and `task_identifier`?
- For execution, are `run_id`, `stage_id`, `session_id`, and `worker_host` present when known?
- For board durability, are sequence/event/OID/revision fields present when known?
- Is the reason concise and safe to log?
- Does the wording distinguish a blocked invocation from a remote publication wait?
- Is the format consistent with nearby lifecycle logs?
