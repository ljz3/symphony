---
name: debug
description:
  Investigate stuck or failed Symphony runs by tracing board, task, run, Codex,
  worktree, GitHub, and worker state with durable correlation identifiers.
---

# Debug

## Goals

- Explain why a task is blocked, stopping, waiting on GitHub, or failing.
- Correlate canonical board events, projected state, a durable run, and its Codex session.
- Distinguish recoverable remote publication waits from invocation failures that block immediately.

## Start with durable state

Use the same machine-local roots as the running service. The default project layout is
`~/.symphony/<project.id>/`:

- `history.git/`: canonical event commits
- `runtime/board.sqlite3`: rebuildable projection and local workpads
- `runtime/logs/symphony.log*`: current and rotated runtime logs
- `worktrees/<TASK-ID>/`: managed persistent task worktree

First query the service when it is available:

```bash
./elixir/bin/symphony board status \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --port <port> \
  ./elixir/WORKFLOW.yml
```

The UI health header and `GET /api/v1/state` expose workflow, lease, projection, board sync,
GitHub, Codex catalog, and worker gates.

## Correlation keys

- `project_id`: immutable project identity
- `task_identifier`: human key such as `SYM-42`
- `task_id`: internal task UUID
- `run_id`: durable stage invocation
- `stage_id`: frozen agent stage
- `session_id`: Codex thread/turn correlation
- `worker_host`: local or SSH worker
- `event_sequence`, `event_id`, `event_oid`, `task_revision`: canonical write/replay context

See `elixir/docs/logging.md` for the complete contract.

## Quick triage

1. Inspect task detail, latest run, desired column, observed runtime state, and health gates.
2. Search logs by `task_identifier`, then capture `task_id`, `run_id`, and `session_id`.
3. Trace the run through claim, worktree/hook setup, app-server, required transition, GitHub effects,
   and finish/block.
4. Inspect `history.git` if projection state disagrees with the event stream.
5. Classify the failure before changing anything: workflow/lease/divergence gate, worker/worktree,
   Codex protocol/model, missing transition, GitHub publication wait, or terminal cleanup.

## Useful commands

```bash
LOG_ROOT="${SYMPHONY_LOGS_ROOT:-$HOME/.symphony/<project-id>/runtime/logs}"

rg -n "task_identifier=SYM-42" "$LOG_ROOT"/symphony.log*
rg -n "task_id=<uuid>|run_id=<uuid>" "$LOG_ROOT"/symphony.log*
rg -n "session_id=<thread-or-turn>" "$LOG_ROOT"/symphony.log*
rg -n "dispatch_gate|Blocked|publication|divergen|orphan|cleanup|turn_" "$LOG_ROOT"/symphony.log*

git --git-dir "$HOME/.symphony/<project-id>/history.git" log \
  --oneline --decorate refs/heads/main
git --git-dir "$HOME/.symphony/<project-id>/history.git" show \
  --stat refs/heads/main
git -C "$HOME/.symphony/<project-id>/worktrees/SYM-42" status --short --branch
```

## Interpretation

- A durable run without a live process after restart is orphaned and should be failed to Blocked.
- A run that ends without a permitted transition is a failure and should be Blocked; it is not
  scheduled for retry.
- A GitHub outage may keep an active invocation waiting in the same run/session while new dispatch
  is globally gated.
- A requested human move may show a desired column while runtime remains `stopping` until graceful
  or forced termination completes.
- Event history is authoritative. A crash after Git commit and before SQLite projection should be
  repaired by replay.
- Diverged board history gates mutation and requires an explicit `board reconcile --take-local` or
  `--take-remote`; never choose an authority without preserving and inspecting the losing head.
- Dirty, unmanaged, colliding, or path-unsafe worktrees must not be removed to make a run pass.

## Evidence to report

Record the task/run/stage/session, relevant event sequence/OID, exact gate or failing lifecycle
step, source/worktree head, PR state when applicable, and the smallest safe next action. Include
timestamps, but do not copy credentials, prompts, full workpads, or unrelated logs.
