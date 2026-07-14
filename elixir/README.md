# Symphony Elixir

This directory contains the Elixir/OTP reference implementation of the Git-backed Symphony Kanban
service described in [`../SPEC.md`](../SPEC.md).

> [!WARNING]
> This is prototype software for trusted environments. It runs Codex unattended according to the
> checked-in project policy and is presented as-is.

## What it does

Symphony is the task authority for one project. It serves an editable loopback-only Kanban board,
commits every domain action to an append-only Git history, projects current state into SQLite, and
dispatches eligible cards to stage-specific Codex runs. Each task keeps a persistent source
worktree and branch. A service-owned `gh` process manages pull-request effects and readiness checks.

The checked-in workflow provides:

```text
Backlog -> Todo -> In Progress -> Automated Review -> Human Review -> Merging -> Done
                                \-> Rework ---------/
```

Blocked records the previous column so a human can resume it; Cancelled is an unsuccessful terminal
state. Only Done satisfies dependencies. Agent failures block immediately, and no retry queue exists.

## Prerequisites

- Elixir `1.19.x` and OTP 28, normally installed with [mise](https://mise.jdx.dev/)
- Git with a source remote whose default branch is discoverable
- [GitHub CLI](https://cli.github.com/) authenticated for that source remote
- Codex with app-server support and the models permitted by `WORKFLOW.yml`

Verify the tools and install dependencies:

```bash
mise trust
mise install
mise exec -- elixir --version
mise exec -- gh auth status
mise exec -- mix setup
mise exec -- mix build
```

## Start the service

The CLI requires both the preview acknowledgement and a loopback port. It defaults to
`./WORKFLOW.yml`:

```bash
mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --port 4000
```

Open `http://127.0.0.1:4000/`. The HTTP server always binds to loopback.
The same listener serves Symphony's MCP endpoint at `http://127.0.0.1:4000/mcp`.

Pass a workflow path as the final argument when the file lives elsewhere:

```bash
./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --port 4000 \
  /path/to/WORKFLOW.yml
```

`SYMPHONY_PORT` can replace `--port`.

## Connect Codex to the MCP endpoint

Symphony exposes exactly one external MCP tool, `symphony_task_create`, on `/mcp`. The tool creates
an execution-ready task in the workflow's initial Backlog column through the same serialized board
writer used by the UI and internal tools. Its required `project_id` must exactly match the active
workflow project before any mutation occurs; a mismatch creates nothing and does not disclose the
active project ID.

Register the listener globally in `~/.codex/config.toml` for a service running on port 4000:

```toml
[mcp_servers.symphony]
url = "http://127.0.0.1:4000/mcp"
enabled = true
required = false
enabled_tools = ["symphony_task_create"]
default_tools_approval_mode = "writes"
```

Verify the saved entry with `codex mcp get symphony` and `codex mcp list`. Codex stores a concrete
URL, so update or re-add the entry explicitly whenever the UI port changes. Symphony never rewrites
personal Codex configuration during startup.

## Storage

Machine-local data defaults to `$SYMPHONY_HOME`, or `~/.symphony` when unset:

```text
~/.symphony/<project.id>/
├── history.git/            # canonical bare board-history repository
├── runtime/
│   ├── board.sqlite3       # rebuildable projection and local workpads
│   ├── lease/              # single-instance ownership
│   └── logs/
└── worktrees/
    └── <TASK-ID>/          # persistent source worktree
```

Use these machine-local overrides; they are intentionally unavailable in tracked workflow config:

- `--symphony-home` or `SYMPHONY_HOME`
- `--worktrees-root` or `SYMPHONY_WORKTREES_ROOT`
- `--logs-root` or `SYMPHONY_LOGS_ROOT`
- `--port` or `SYMPHONY_PORT`

The project lease permits a second process to show diagnostics, but only its owner may mutate the
board or dispatch agents.

## Board and task contract

The LiveView routes are:

- `/` — ordered Kanban, task creation, drag/drop transitions, and health
- `/stats` — all-time project/task/model/stage accounting, active sessions, service uptime, and per-worker rate limits
- `/tasks/:identifier` — task contract, criteria and evidence, dependencies, model selections,
  source/PR state, effective live/canonical run statistics, workpads, and event history
- `/archive` — archived task tombstones

A task requires a title, immutable Feature/Bug Fix/Chore type, Markdown brief, and at least one
acceptance criterion. Symphony allocates an irreversible `<PROJECT-KEY>-<number>` identifier and
derives `feature/ID`, `fix/ID`, or `chore/ID`. Priorities are Urgent, High, Normal, and Low. Optional
dependencies must be acyclic, and every reachable stage with multiple allowed model/effort pairs
requires an explicit selection.

Task execution contracts cannot be edited while starting, running, or stopping. Agent-completed
criteria require evidence. Humans may reopen criteria, and editing criterion text preserves prior
evidence history.

The REST-style JSON interface is diagnostic and intentionally read-only:

- `GET /api/v1/state`
- `GET /api/v1/tasks/:identifier`
- `POST /api/v1/refresh`

All other REST mutation methods are rejected. LiveView and MCP mutations call the same validated
board command boundary used by internal tools; `/mcp` is a separate Streamable HTTP protocol route,
not a general-purpose task API.

## `WORKFLOW.yml`

`WORKFLOW.yml` is a strict, configuration-only YAML document. Unknown keys are errors, and no
user-visible schema version is accepted. Referenced prompt and workpad files are loaded as one
bundle and parsed with strict Solid variables and filters before activation. Load-time rendering
exercises both realistic first-run assigns (empty GitHub, dependencies, and prior handoffs) and
populated assigns so truthy empty maps cannot defer a strict-render failure until dispatch.

The document defines:

- immutable `project.id` and uppercase `project.key`
- source Git remote and optional board-history remote
- agent concurrency, turns per run, and optional SSH worker hosts/capacity
- Codex command, approval/sandbox/network policy, and timeouts
- shared base/context prompts
- named stages with their prompt, workpad template, and allowed model/effort map
- ordered `dispatch`, `pause`, `blocked`, or `terminal` columns
- human and agent transition edges
- worktree lifecycle hooks

The checked-in [`WORKFLOW.yml`](WORKFLOW.yml) is the complete reference. Template paths are resolved
relative to that file, while the source repository is derived from its containing Git worktree.

Invalid initial configuration leaves the board available in read-only diagnostic mode. An invalid
reload keeps the last valid bundle. Valid reloads wait until no agent is starting, running, or
stopping; active runs retain their frozen templates and model policy. A project ID cannot change,
and a column referenced by a live task cannot be removed.

## Agent execution and GitHub

For each claimed dispatch task, Symphony atomically records the run, creates or reuses its managed
worktree, runs configured hooks, validates the exact model against Codex's complete catalog, renders
the stage prompt/workpad, and starts app-server in that worktree. The prompt order is fixed:

1. Symphony's runner safety contract
2. workflow base prompt
3. workflow context prompt
4. selected stage prompt

Symphony applies the configured Codex sandbox mode to each turn. In `workspace-write` mode, a local
run can write the managed task worktree and the source repository's shared Git metadata while the
source checkout's working tree remains read-only. This lets task worktrees stage and commit without
giving an agent write access to source files outside its managed worktree. `read-only` and
`danger-full-access` are passed through as their corresponding app-server turn policies.

The agent can use only the task/run-scoped `symphony_*` tools advertised by the service. It must
complete a permitted transition before the invocation ends. A transition into another dispatch
stage schedules a new run with that stage's frozen prompt and workpad.

`symphony_workpad_read` defaults to the active run and selected invocation. It may also select an
explicit completed prior run of the same task; prompt handoffs expose each run's stage and available
workpad invocations. Cross-task reads and reads from other non-completed runs are rejected. This
lets Automated Review hand findings directly to Rework without waiting for Human Review publication.

After the first meaningful committed diff from the remote default branch, Symphony pushes the task
branch and creates a deterministic draft PR. Documentation, product-specification, configuration,
and tooling-only commits qualify; a zero-diff branch does not. Entering Human Review publishes
unpublished workpads, enforces acceptance evidence, review-thread and required-check readiness, then
marks the PR ready. GitHub CLI's exact no-required-checks diagnostic is normalized to an empty green
set, while listed failed or pending checks and other CLI failures remain blocking. Rework returns the
PR to draft. Cancelled closes an open PR. Done is accepted only after the merge commit is reachable
from the remote default branch.

Terminal cleanup never changes the terminal board outcome. Symphony first removes its marked,
clean managed worktree, then deletes only the marker-proven local task branch. It never deletes the
remote branch in this path. If local branch deletion fails (for example because another worktree is
using it), the ownership marker remains and cleanup is retried; no source checkout is switched or
modified to force the deletion.

A GitHub outage gates new dispatch. An active run may reach a safe local commit and wait in the same
session while publication retries; it is not placed on an agent retry queue.

Every run finalized as completed, stopped, or failed records durable statistics in its canonical
Git event. `stats` contains elapsed milliseconds, the count of unique Codex turns, and the latest
authoritative cumulative input, cached-input, output, and total token counts. Runtime begins at
`started_at`, or at `claimed_at` when Codex never starts. If Codex never reports an authoritative
cumulative total, `token_usage` is `null` rather than a synthetic zero.

While a run is live, SQLite retains only its token high-water mark and unique turn IDs so a runner
crash or orphan recovery does not lose accounting. Finalization copies that summary into the Git
event and removes the transient row. Symphony accepts
`thread/tokenUsage/updated.params.tokenUsage.total`, with the legacy nested
`total_token_usage` as a fallback; delta, generic `usage`, and turn-completion payloads are ignored.

The board, task detail, `/stats`, and read-only JSON API merge that transient active-run snapshot
with canonical terminal `stats`. Task and project totals cover all runs, including archived tasks;
they sum input, cached-input, output, and reported total fields independently. Cached input remains
a subset of input and is not added again. Aggregates are marked `complete`, `partial`, or
`unavailable`: a partial UI total is prefixed with `≥`, unavailable usage is shown as `—`, and an
authoritative zero remains `0`.

The stats snapshot also groups the same effective runs by exact model and then by stage, combining
effort levels. Each group reports distinct tasks, distinct all-time and active Codex thread IDs,
active and total runs, turns, agent time, and token usage. Completed-task counts represent distinct
current or archived Done tasks with a run that has a canonical start time or an effective session ID
in the group. One completed task can therefore appear under several models or stages, while each
model aggregate deduplicates that task across its own stages.

Agent time is the sum of run durations and can exceed service uptime or project age when agents run
concurrently. Project age runs from the earliest claim and continues while idle. Service uptime,
safe latest-activity labels, and rate limits keyed by local/SSH worker are operational values that
reset when the orchestrator process restarts; token, turn, and terminal-duration history does not.

`GET /api/v1/state` exposes the same snapshot under `stats`, including `models` with nested `stages`,
per-group `session_count` and `active_session_count`, and project `session_count` and
`completed_task_count` values. Task responses expose aggregate
`stats`, preserve each run's canonical `stats`, and add `effective_stats` plus safe active
`activity`. Session IDs remain confined to the loopback UI/API and are never published to GitHub.

GitHub receives one compact, marker-managed stats block after the run terminates. The run that
created a Symphony-managed PR is appended to the PR body. Other runs are appended to the existing
comment that published their workpad, including when that comment was created before the run
finished. A run without a published workpad remains local and creates no extra GitHub comment.
Hidden per-run markers make retries and crash recovery idempotent, and successful publication is
itself recorded as a canonical run event.

## Board history, recovery, and handoff

The canonical board branch is `refs/heads/main` in `history.git`. Every commit adds exactly one JSON
event. Git is committed before SQLite is updated, so startup replay repairs a crash in that window.
SQLite uses WAL and full durability. Checkpoints are written every 100 events, at clean shutdown,
and during handoff to a separate `checkpoints` branch; incompatible or corrupt snapshots fall back
to full event replay.

Maintenance commands require the same acknowledgement and port as normal startup:

```bash
./bin/symphony board status [options] [WORKFLOW.yml]
./bin/symphony board checkpoint [options] [WORKFLOW.yml]
./bin/symphony board handoff [options] [WORKFLOW.yml]
./bin/symphony board reconcile --take-local [options] [WORKFLOW.yml]
./bin/symphony board reconcile --take-remote [options] [WORKFLOW.yml]
```

`board handoff` requires no running agents, checkpoints state, pushes configured event/checkpoint
refs, and verifies their remote OIDs. Divergence gates mutations and dispatch. Reconciliation keeps
the losing head under a timestamped backup ref before reset or force-push, so choose the authority
deliberately.

## Testing

Run targeted tests while iterating, then the full quality gate:

```bash
mix specs.check
make all
```

The normal suite uses temporary Git repositories and deterministic boundaries for failure/recovery
coverage. The protocol-level end-to-end gate is excluded by default:

```bash
make e2e
```

That target creates disposable source and board remotes, a fake app-server process, and a fake `gh`
executable. It exercises local task creation, the implementation/review/rework/merge stages, two
workpad publications, terminal cleanup, verified handoff, projection loss, writer restart, and
identical event replay without using a production repository.

## Migration note

There is no compatibility or import path for the former `WORKFLOW.md`/Linear architecture. Existing
Linear tasks and old unmanaged workspace directories are not imported or deleted. Back up anything
you need, adopt `WORKFLOW.yml`, and create new task history through this board. An empty
`board.remote` with no existing local board history creates a fresh embedded board; it is not a
migration signal and does not discover or import Linear state.

## Project layout

- `lib/symphony_elixir/` — domain, event history, projection, orchestration, worktrees, Codex, GitHub
- `lib/symphony_elixir_web/` — loopback LiveView board and read-only API
- `workflow/prompts/` and `workflow/workpads/` — strict standard templates
- `test/` — unit, integration, UI/API, Git, fake-`gh`, and opt-in live coverage
- `WORKFLOW.yml` — standard project workflow contract
