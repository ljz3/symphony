# Symphony Elixir

This directory contains the Elixir/OTP reference implementation of the Git-backed Symphony Kanban
service described in [`../SPEC.md`](../SPEC.md).

> [!WARNING]
> This is prototype software for trusted environments. It runs coding agents (Codex by default, or
> Kimi via ACP) unattended according to the checked-in project policy and is presented as-is.

## What it does

Symphony is the task authority for one project. It serves an editable loopback-only Kanban board,
commits every domain action to an append-only Git history, projects current state into SQLite, and
dispatches eligible cards to stage-specific agent runs. Agent backends are pluggable: Codex
(`codex app-server`) and Kimi (`kimi acp`, the Agent Client Protocol) are supported, each with
per-stage backend/model/effort selection. Each task keeps a persistent source
worktree and branch. A service-owned `gh` process manages pull-request effects and readiness checks.

The checked-in workflow provides:

```text
Backlog -> Todo -> In Progress -> Automated Review --passing attestation--> Merging -> Done
                                |       ^                                |
                                v       |                                v
                              Rework ---+                         Merge Conflict
                                |
                                +--------------------------------> Automated Review
```

Draft or otherwise non-ready pull requests leave Automated Review without a verdict and enter Human
Review, the publish-and-ready pause path. A human returns the ready PR to Automated Review for a
fresh structured review; only that explicit non-draft snapshot may pass to Merging, and no GitHub
aggregate approval is required. Human Review →
Rework requires feedback submitted through the board (the task page's review-feedback box);
feedback-less human transitions on that edge are rejected. The submission is recorded
canonically, rendered into the rework prompt, and stays pending until a rework run completes
successfully. The transition converts the PR to draft, so the same Human-ready/fresh-review cycle
repeats after rework.
Blocked records the previous column so a
human can resume it; Cancelled is an unsuccessful terminal state. Only Done satisfies dependencies.
Agent failures block immediately, and no retry queue exists.

## Prerequisites

- Elixir `1.19.x` and OTP 28, normally installed with [mise](https://mise.jdx.dev/)
- Git with a source remote whose default branch is discoverable
- [GitHub CLI](https://cli.github.com/) authenticated for that source remote
- Codex with app-server support and the models permitted by `WORKFLOW.yml`
- Optional: Kimi CLI (`kimi`) authenticated with `kimi login`, when an ACP backend is configured

Verify the tools and install dependencies:

```bash
mise trust
mise install
mise exec -- elixir --version
mise exec -- gh auth status
mise exec -- mix setup
mise exec -- mix build
```

The build embeds Exqlite's native SQLite library in `bin/symphony`. On escript startup, Symphony
extracts that library into a content-addressed directory under the current user's cache and adds
only its synthetic `ebin` directory to the front of the code path so `:code.priv_dir/1` resolves a
real filesystem location for NIF loading. `make all` rebuilds the package and runs a clean-cache
smoke test that starts the escript against a disposable home and reads board status through the
embedded NIF.

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

Startup failures name the failed supervision component, summarize the cause and next action, and
show the workflow and log paths. Port conflicts also report the listener PID and executable name
when `lsof` is available, including the explicit `kill -TERM <pid>` command for a graceful stop;
Symphony never stops an existing listener automatically.

Pass a workflow path as the final argument when the file lives elsewhere:

```bash
./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --port 4000 \
  /path/to/WORKFLOW.yml
```

`SYMPHONY_PORT` can replace `--port`.

## Connect Codex to the MCP endpoint

Symphony exposes exactly three external MCP tools on `/mcp`:

- `symphony_task_create` creates an execution-ready task in the workflow's initial Backlog column
  through the same serialized board writer used by the UI and internal tools.
- `symphony_task_get` returns one actionable task view by exact human identifier, including safe
  status, criteria/evidence, dependencies, PR projection, aggregate statistics, and bounded run/event history.
- `symphony_tasks_by_state` lists current, non-archived tasks in one exact workflow column using
  canonical priority/rank/number ordering.

All three tools require a `project_id` that exactly matches the caller's independently known active
workflow project. A mismatch is rejected before other arguments are processed, creates no event, and
does not disclose the active project ID. The read tools are read-only, idempotent, non-destructive,
and closed-world. The MCP surface never exposes workpads, raw task metadata, workspace paths, or
raw event/protocol payloads.

Register the listener globally in `~/.codex/config.toml` for a service running on port 4000:

```toml
[mcp_servers.symphony]
url = "http://127.0.0.1:4000/mcp"
enabled = true
required = false
enabled_tools = ["symphony_task_create", "symphony_task_get", "symphony_tasks_by_state"]
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
│   ├── board.sqlite3       # rebuildable board/workpad projection
│   ├── recovery/           # retained confirmed-corrupt database families
│   ├── lease/              # single-instance ownership
│   └── logs/
├── workpads/               # private authoritative local workpad history
│   ├── records/<run-id>/<invocation>.json
│   └── publications/<publication-id>.json
└── worktrees/
    └── <TASK-ID>/          # persistent source worktree
```

Use these machine-local overrides; they are intentionally unavailable in tracked workflow config:

- `--symphony-home` or `SYMPHONY_HOME`
- `--worktrees-root` or `SYMPHONY_WORKTREES_ROOT`
- `--logs-root` or `SYMPHONY_LOGS_ROOT`
- `--port` or `SYMPHONY_PORT`

The project lease permits a second process to show diagnostics, but only its owner may mutate the
board or dispatch agents. Lease owners include a hashed stable machine identifier so a dead local
owner can be reclaimed safely even when the operating system hostname changes.

Workpad records and publication manifests are versioned JSON with owner-only permissions. Symphony
writes, syncs, and atomically renames a record before updating SQLite. Existing sidecars win during
startup reconciliation; SQLite-only records are exported once, then the projection is rehydrated
from sidecars. Record v2 preserves the nullable initial rendered-template hash across edits, and
every non-null value is exactly 64 lowercase hexadecimal characters. V1 records remain readable and
count as meaningful, while publication manifests stay at v1. Publication state is true
only when a manifest's run/invocation/content hashes match
the current records. Startup stops on a malformed sidecar and reports its exact path rather than
discarding local history. These files remain private, local, and noncanonical; do not publish or
copy the directory into a source repository.

## Board and task contract

The LiveView routes are:

- `/` — ordered Kanban, task creation, drag/drop transitions, and health
- `/stats` — all-time project/task/model/stage/effort accounting, active sessions, service uptime, and per-worker rate limits
- `/tasks/:identifier` — task contract, criteria and evidence, dependencies, model selections,
  source/PR state, effective live/canonical run statistics, every ordered workpad invocation for
  completed, failed, and stopped runs, and event history
- `/archive` — archived task tombstones

A task requires a title, immutable Feature/Bug Fix/Chore type, Markdown brief, and at least one
acceptance criterion. Symphony allocates an irreversible `<PROJECT-KEY>-<number>` identifier and
derives `feature/ID`, `fix/ID`, or `chore/ID`. Priorities are Urgent, High, Normal, and Low. Optional
dependencies must be acyclic, and every reachable stage with multiple allowed backend/model/effort
combinations requires an explicit selection.

Task execution contracts cannot be edited while starting, running, or stopping. Agent-completed
criteria require evidence. Humans may reopen criteria, and editing criterion text preserves prior
evidence history.

There is no REST-style JSON API. Former `/api/v1/state`, `/api/v1/tasks/:identifier`, and
`/api/v1/refresh` paths (and every HTTP method on them) return the generic `404 not_found` response.
LiveView uses internal Elixir boundaries, while `/mcp` is the sole machine-facing protocol endpoint
and exposes only the three guarded task tools above. Workpad content and raw board/protocol data are
never exposed through MCP.

## `WORKFLOW.yml`

`WORKFLOW.yml` is a strict, configuration-only YAML document. Unknown keys are errors, and no
user-visible schema version is accepted. Referenced prompt and workpad files are loaded as one
bundle and parsed with strict Solid variables and filters before activation. Load-time rendering
exercises both realistic first-run assigns (empty GitHub, dependencies, and latest workpad) and
populated assigns so truthy empty maps cannot defer a strict-render failure until dispatch.

The document defines:

- immutable `project.id` and uppercase `project.key`
- source Git remote and optional board-history remote
- agent concurrency, optional SSH worker hosts/capacity, and an optional `local_worker` flag that
  adds a local worker pool alongside SSH hosts (with no SSH hosts, local execution is always
  enabled; without the flag, SSH hosts keep their remote-only behavior)
- named agent backends and the Codex command and approval/sandbox/network policy
- optional named blocking jobs with executable, fixed arguments, passthrough policy, and environment
- optional pre-claim dispatch preflight with a retry delay after explicit failure
- optional deterministic squash-merge policy and its review/conflict columns
- shared base/context prompts
- named stages with their prompt, workpad template, and allowed `(backend, model, effort?)` policy
- ordered `dispatch`, `merge`, `pause`, `blocked`, or `terminal` columns
- human and agent transition edges
- worktree lifecycle hooks

### Agent backends

The `backends:` section declares every agent CLI a stage may select. Two protocols exist:
`app_server` (the Codex app-server JSON-RPC protocol, reserved for the backend named `codex`) and
`acp` (the Agent Client Protocol, validated against Kimi CLI). The legacy top-level `codex:` section
remains a shorthand for `backends.codex`; defining both is an error, and the checked-in
[`WORKFLOW.yml`](WORKFLOW.yml) intentionally stays on that legacy form.

```yaml
backends:
  codex:
    protocol: app_server
    command: codex --config shell_environment_policy.inherit=all app-server
    approval_policy: never
    sandbox: workspace-write
    network_access: true
  kimi:
    protocol: acp
    command: kimi acp
    permission_mode: auto        # optional, default auto
    allow_unsandboxed: true      # required for ACP backends

stages:
  implementation:
    prompt: workflow/prompts/implementation.md
    workpad: workflow/workpads/implementation.md
    allowed_models:
      - {backend: codex, model: gpt-5.5, efforts: [xhigh]}
      - {backend: kimi, model: kimi-code/k3, efforts: [max]}
      - {backend: kimi, model: kimi-for-coding}   # no efforts: selection without a thinking level
```

Every stage policy entry expands to `(backend, model, effort?)` triples; the backend must exist.
The legacy flat `allowed_model_efforts` map always means the codex backend and is a migration error
when no codex backend is configured. `allow_unsandboxed: true` is a required acknowledgement — see
the security posture under [Agent execution and GitHub](#agent-execution-and-github). ACP backends
are local-only: they are never scheduled to SSH workers, and a task whose ACP backend has no local
worker moves to Blocked with a stable reason instead of queuing silently.

The checked-in [`WORKFLOW.yml`](WORKFLOW.yml) is the baseline workflow. Optional jobs, preflight, and
deterministic merge configuration use these strict shapes:

```yaml
jobs:
  targeted_validation:
    executable: ./elixir/scripts/symphony-targeted-validation.sh
    arguments: []
    passthrough_arguments: required
    environment: {}
  full_validation:
    executable: ./elixir/scripts/symphony-full-validation.sh
    arguments: []
    passthrough_arguments: forbidden
    environment: {}

dispatch:
  preflight:
    command: ./scripts/symphony-preflight.sh
    retry_after_failure_ms: 30000

merge:
  method: squash
  readiness_command: ./scripts/symphony-merge-readiness.sh
  review_column: automated_review
  conflict_column: merge_conflict
```

Job arguments are a literal argument vector. The exact `$SYMPHONY_JOB_ID` item is the only reserved
Symphony substitution. Job definitions require an environment map, which may be empty. A configured
merge policy requires exactly one `role: merge` column without a stage; its review and conflict
targets must be different dispatch columns. Template and executable paths are resolved relative to
the workflow/source worktree as specified by their consumers.

Managed agent turns (Codex or ACP), app-server responses, worktree hooks, jobs, preflight, and merge readiness do
not have elapsed-time, inactivity, or output-size limits. The workflow loader rejects former
`max_turns_per_run`, Codex timeout, hook timeout, job timeout/output-cap, preflight timeout, and merge
timeout/output-cap keys with an explicit migration error. Retry/reconciliation intervals and forced
termination after a human cancellation request remain scheduling and cancellation policy, not work
deadlines.

Invalid initial configuration leaves the board available in read-only diagnostic mode. An invalid
reload keeps the last valid bundle. Valid reloads wait until no agent is starting, running, or
stopping; active runs retain their frozen templates and model policy. A project ID cannot change,
and a column referenced by a live task cannot be removed. Workflow reloads never move tasks already
in Backlog, Todo, Blocked, Done, or Cancelled; only incompatible, non-running tasks outside those
protected columns may be routed to Blocked.

## Agent execution and GitHub

For each eligible dispatch task, Symphony first reserves global and selected-worker capacity. When
dispatch preflight is configured, it creates or reuses the managed worktree and runs the preflight
there while the task remains queued and no run exists. A successful command is usable only if a
fresh read confirms the same task revision, eligibility, workflow hash, and worker reservation;
otherwise Symphony discards it and probes current state again. Symphony then atomically records the
run, runs configured hooks, and validates the exact model against the backend's live catalog. Before
rendering an initial workpad or starting the agent session, Symphony refreshes the configured remote
default-branch ref for a reused local worktree and reconciles the actual branch HEAD, base SHA, and
cleanliness into canonical state. It then reloads the task and run, validates their scope, renders
the stage prompt/workpad from that current state, and starts the selected backend session in the
worktree. A
reconciliation failure starts no agent process and explicitly fails the claimed run. The prompt
order is fixed:

1. Symphony's runner safety contract
2. workflow base prompt
3. workflow context prompt
4. selected stage prompt

Preflight has no elapsed-time or inactivity deadline. A running probe consumes capacity. Explicit
failure releases that capacity, gates only the affected queued task until its retry time, and exposes
one replaceable current diagnostic rather than a history. Task notifications re-read current state:
non-revision events preserve an active probe or current failure, while revision, eligibility,
workflow-hash, or worker-reservation changes cancel stale work. A cancelled result is discarded and
never recorded as a project failure. Owner monitoring terminates an orphaned local or SSH command
when the orchestrator exits, so restart reruns the probe instead of accepting a pre-restart result.
Board health projects only current running or failed preflight state.

SSH worker health is also probed asynchronously under supervision. A silent probe can remain active
indefinitely without blocking Orchestrator messages; unknown and probing workers are not selected.
Explicit success records healthy state, while process exit or explicit failure records one current
unhealthy reason and schedules a later probe after completion. Workflow host removal and service
shutdown cancel the owned process tree. Direct dispatch without project preflight proceeds normally
once the selected worker has an explicit healthy result.

Synchronous SSH commands capture stderr with stdout. OpenSSH status `255` becomes a structured
transport error that retains the diagnostic; every other exit status remains a normal command
result. Deterministic merge treats that transport error as pending at readiness, target comparison,
reachability, and existing-worktree reconciliation boundaries. These commands have no added timeout.

Symphony applies the configured Codex sandbox mode to each Codex turn. In `workspace-write` mode, a local
run can write the managed task worktree and the source repository's shared Git metadata while the
source checkout's working tree remains read-only. This lets task worktrees stage and commit without
giving an agent write access to source files outside its managed worktree. `read-only` and
`danger-full-access` are passed through as their corresponding app-server turn policies.

### ACP (Kimi) sessions

An ACP session speaks the Agent Client Protocol over stdio. Symphony negotiates protocol version 1,
requires the agent's HTTP MCP capability, and authenticates with the documented `login` method when
the agent advertises it (run `kimi login` first). It then applies the selected model first, consumes
the complete returned session configuration state, validates and applies the thinking effort only
when the selected model supports it, and applies the configured permission mode. stdout carries only
JSON-RPC; stderr is captured in a per-run log file. A stopped run is cancelled with
`session/cancel` before its process is terminated. Permission prompts are answered deterministically
(first `allow_once`, else first `allow_always`, else cancelled); question elicitation is cancelled
rather than answered. ACP sessions are local-only, and there is no ACP resume in v1: a transport
failure fails the run and moves the task to Blocked, matching the no-retry-queue rule. ACP runs
record `stats.token_usage` as `null`.

**Security posture.** ACP backends have no sandbox concept and v1 adopts the trusted-local-process
model: `allow_unsandboxed: true` means the user accepts that the ACP agent runs with the same
OS-user authority as Symphony itself. The session working directory (the task worktree) is not
confinement, and the permission mode only auto-handles permission prompts. The run-scoped MCP token
and per-scope registration prevent accidental cross-run routing through the configured endpoint but
are not a security boundary against a malicious same-user process — such a process could potentially
reach the loopback `/mcp` endpoint or read runtime files. Running untrusted agents requires future
OS/container isolation plus protection of the global MCP endpoint and runtime secrets.

The agent can use only the task/run-scoped `symphony_*` tools advertised by the service — delivered
as app-server dynamic tools for Codex, and as a per-`{run_id, invocation}` isolated, token-authenticated
HTTP MCP scope (`/mcp/runs/:run_id/:invocation`) for ACP backends, with identical execution semantics
on both channels. It must
complete a permitted transition before the invocation ends. A transition into another dispatch
stage schedules a new run with that stage's frozen prompt and workpad. Mutating tool calls combine
the run ID with a namespaced call ID for idempotency, so call IDs may restart in a later run without
replaying a prior run's result. Successful mutations return only the event type, task revision/current
column, and run status when present rather than echoing identities, runtime state, or canonical task
and run payloads.

Runs with configured jobs additionally advertise `symphony_job_run`, with its `job` enum derived
only from that run's frozen bundle. The call remains pending until the command exits; there is no
agent-facing status, sleep, tail, or polling tool. Fixed and passthrough arguments remain a literal
argument vector, relative executables resolve in the managed worktree, and bare executables use the
configured `PATH`. Symphony injects managed task/run/job identity, writes stdout and stderr to
owner-only durable artifacts while the process runs, and returns complete stdout without a byte or
line cap. UTF-8 stdout is returned verbatim; arbitrary binary stdout is returned losslessly as
Base64, distinguished by `output_encoding`. Stderr remains an artifact instead of being injected
into model context. Source identity includes HEAD, complete staged and unstaged binary diffs, and
the paths and contents of untracked files.

The job store records identity before spawning. Delivery of the same run/call ID reattaches to or
replays that job, while identical active task/job/arguments/source requests single-flight. A dropped
app-server transport resumes the same thread and active turn; a re-delivered call replays the durable
result without a second OS process or model continuation. A service restart marks an unrecoverable
running record `interrupted`, never timed out. Explicit run cancellation terminates the job process
group, with bounded force escalation used only after that human cancellation request; local or
remote signal delivery never blocks cancellation progress.

Prompts and `symphony_task_context` share one explicit current-state projector. It includes only the
current task contract/column, active run, curated source/GitHub state, current criterion evidence,
shallow dependency status, allowed transitions, current preflight state, and the actual active
JobManager record reduced to job identity/status/timing/source fingerprint. Raw metadata, task
runtime/desired state, evidence history, frozen bundles, prior runs/invocations, provider payloads,
and job output/artifact/call internals are excluded. Templates receive only `stage.id`, never the
frozen prompt/template/path/model contract. `symphony_task_context` and `symphony_workpad_read`
require the literal empty object `{}` and reject null, scalar, and array inputs.
`symphony_workpad_read` returns the same one `latest_workpad` used by PromptBuilder, or `null`: the
current run's highest meaningful invocation, otherwise the newest completed, failed, or stopped
same-task run's highest meaningful invocation. Generated templates are stored as record-v2 hashes
and skipped until edited; legacy v1 records remain readable and meaningful. Publication manifests
remain v1, and cross-task or non-current active work is never selected.

### Structured review and deterministic merge

The configured review run receives `symphony_review_complete`. Its strict nested payload records a
`pass` or `rework` verdict, the exact reviewed head, plan-policy result, concrete validation
evidence, structured findings, route, and expected task revision. Symphony independently observes
the clean source worktree, current source and PR heads, PR state, aggregate GitHub review decision,
the strictly boolean draft state, every paginated review thread and comment, and every required
check. Draft state participates in the feedback fingerprint. Symphony stores system-derived
reviewer/run/time/PR fields, deterministic feedback/check fingerprints, and a canonical fingerprint
of the exact acceptance-criterion set and current evidence in the canonical task event; raw provider
payloads are not copied into prompt state.

A pass requires matching source/task/PR heads, completed criteria with evidence, a followed or
not-required plan, no blocker/high findings, aggregate `APPROVED`, no unresolved threads, and green
required checks, plus an explicitly non-draft provider snapshot. A missing or malformed draft field
invalidates the snapshot. Only that command may route to the system-owned `role: merge` column. Rework
requires findings and a configured non-review dispatch or Blocked route. Any later canonical source
or PR-head change, linked PR identity change, or acceptance-criterion/evidence change clears the pass
and sends merge-pending work back to review.

The orchestrator runs at most one deterministic merge worker separately from normal AgentRunner
capacity; no model or run is claimed for Merging. The worker revalidates the exact reviewed state,
fetches and compares the remote default branch, and then either:

- commits and pushes a normal target-branch merge, invalidates the attestation, and requires review
  of the new exact head; or
- verifies a real Git conflict, collects the complete sorted unmerged-path set, aborts the probe,
  and records the conflict before dispatching the Merge Conflict agent.

Only when the exact reviewed head already contains the fetched target does the worker run the
configured readiness command to natural exit without a deadline. After readiness exits it reloads
canonical task state, re-observes the clean local source and provider PR state (including
`draft: false`), fetches the target again, and compares it again. An advanced target uses the same
model-free update or verified-conflict path and returns to Automated Review; a changed target already
contained by the task branch still invalidates the attestation instead of reusing readiness evidence
for a different target. A still-current target proceeds to guarded
`gh pr merge --squash --match-head-commit <reviewed-head>`. The initial, post-readiness,
clean-update, and guarded-squash gates all require the PR to remain non-draft; a draft flip returns
the task to Automated Review without a push or squash.

External effects have canonical checkpoints before the clean-update push and guarded squash, so a
restart inspects local Git plus the actual remote PR head and resumes instead of repeating them; an
already-updated remote head invalidates review without another push. A first conflict
for one task-head/target-head pair enters Merge Conflict; recurrence of the same pair blocks. That
agent may resolve only the recorded paths by merging the recorded target without rebase/history
rewrite. The recorded task and target heads must be the ordered merge parents, and all follow-up
commits remain limited to the recorded paths. The agent commits a clean final source, runs the frozen
`full_validation` job through `symphony_job_run` to terminal success for that exact fingerprint, and
then pushes the same head. This commit-validate-push ordering means the push cannot change the source
fingerprint and avoids duplicating a successful validation. Symphony requires the local, remote, and
live linked-PR heads to match before atomically returning the task to Automated Review; a retry of the
same transition is idempotent. The agent never lands the PR. After squash, the system fetches the
target until the merge SHA is reachable, then atomically
records completion and moves to Done. Stale state returns to review, transient provider/process
failure remains merge-pending, and broken invariants or a missing/closed PR block.

After the first meaningful committed diff from the remote default branch, Symphony pushes the task
branch and creates a deterministic draft PR. Documentation, product-specification, configuration,
and tooling-only commits qualify; a zero-diff branch does not. Any agent transition into a
`publish_workpad` column synchronously publishes before Symphony accepts the move. The acknowledged
marker is written to an atomic local manifest before SQLite is marked published; stable task/content
hash IDs make retries idempotent, while changed content becomes unpublished. Entering Human Review
continues to publish, enforce acceptance evidence, review-thread and required-check readiness, and
then mark the PR ready and project canonical `draft: false`. A human must return that card to
Automated Review for a fresh review; the readiness action itself does not record or reuse a pass.
GitHub CLI's exact no-required-checks diagnostic is normalized to an empty
green set, while listed failed or pending checks and other CLI failures remain blocking. Rework
returns the PR to draft and projects canonical `draft: true`. Cancelled closes an open PR. Done is
accepted only after the merge commit is reachable from the remote default branch.

Periodic reconciliation never publishes an active run's workpad. A publication failure appears in
health/status under the affected task ID and gates only that task's dispatch while marker-idempotent
retries continue; unrelated eligible tasks remain dispatchable.

Terminal cleanup never changes the terminal board outcome. Symphony first removes its marked,
clean managed worktree, then deletes only the marker-proven local task branch. It never deletes the
remote branch in this path. If local branch deletion fails (for example because another worktree is
using it), the ownership marker remains and cleanup is retried; no source checkout is switched or
modified to force the deletion.

A GitHub outage gates new dispatch. An active run may reach a safe local commit and wait in the same
session while publication retries; it is not placed on an agent retry queue.

Every run finalized as completed, stopped, or failed records durable statistics in its canonical
Git event. `stats` contains elapsed milliseconds, the count of unique agent session turns, and the latest
authoritative cumulative input, cached-input, output, and total token counts. Runtime begins at
`started_at`, or at `claimed_at` when the agent never starts. If the backend never reports an authoritative
cumulative total (always the case for ACP backends in v1), `token_usage` is `null` rather than a synthetic zero.

While a run is live, SQLite retains only its token high-water mark and unique turn IDs so a runner
crash or orphan recovery does not lose accounting. Finalization copies that summary into the Git
event and removes the transient row. Symphony accepts
`thread/tokenUsage/updated.params.tokenUsage.total`, with the legacy nested
`total_token_usage` as a fallback; delta, generic `usage`, and turn-completion payloads are ignored.

The board, task detail, `/stats`, and read-only MCP task views merge that transient active-run snapshot
with canonical terminal `stats`. Task and project totals cover all runs, including archived tasks;
they sum input, cached-input, output, and reported total fields independently. Cached input remains
a subset of input and is not added again. Aggregates are marked `complete`, `partial`, or
`unavailable`: a partial UI total is prefixed with `≥`, unavailable usage is shown as `—`, and an
authoritative zero remains `0`.

The stats snapshot groups the same effective runs by backend and exact model and then by stage, combining effort
levels. Each model and stage aggregate reports distinct tasks, distinct all-time and active agent
session IDs, active and total runs, turns, agent time, and token usage. The `/stats` HTML view also
renders the same accounting separately for each observed effort beneath its stage row. Completed-task
counts represent distinct current or archived Done tasks with a run that has a canonical start time
or an effective session ID in the group. One completed task can therefore appear under several models,
stages, or efforts, while each model aggregate deduplicates that task across its own stages.

Agent time is the sum of run durations and can exceed service uptime or project age when agents run
concurrently. Project age runs from the earliest claim and continues while idle. Service uptime,
safe latest-activity labels, and rate limits keyed by local/SSH worker are operational values that
reset when the orchestrator process restarts; token, turn, and terminal-duration history does not.

Project-wide state and statistics remain internal to the LiveView/UI boundaries. `symphony_task_get`
exposes aggregate task `stats`, the three newest compact runs with effective statistics, and the ten
newest compact events with totals/truncation flags. It omits canonical run internals, workspaces,
workpads, source/GitHub maps, persistence metadata, and session IDs. Session IDs remain confined to
the loopback UI and are never published to GitHub.

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
and during handoff to a separate `checkpoints` branch.

Startup classifies an existing database as healthy, confirmed corrupt, or indeterminate. Healthy
database/WAL/SHM files are untouched. NIF, permission, open, and health-check execution failures are
indeterminate and abort startup without replacing or deleting that family. Only confirmed corruption
starts recovery: Symphony builds and validates a compatible checkpoint-derived replacement, or a
valid empty projection when no checkpoint exists, before moving the original family into a unique
`runtime/recovery/` quarantine. Installation failures roll the family back. Quarantines are never
deleted automatically; preserve them for operator diagnosis. Canonical Git replay and authoritative
workpad sidecars repopulate the installed projection.

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
executable. It exercises local task creation, draft Automated Review → Human readiness, Human Review
→ Rework draft conversion, a second ready cycle, a human return to fresh Automated Review, structured
pass, and system-owned deterministic Merging with no agent run. It also proves the guarded reviewed
head is exactly the landed tree, two marker-idempotent workpad publications, reachability, terminal
cleanup, verified handoff, projection loss, writer restart, and identical event replay without using
a production repository.

## Migration note

There is no compatibility or import path for the former `WORKFLOW.md`/Linear architecture. Existing
Linear tasks and old unmanaged workspace directories are not imported or deleted. Back up anything
you need, adopt `WORKFLOW.yml`, and create new task history through this board. An empty
`board.remote` with no existing local board history creates a fresh embedded board; it is not a
migration signal and does not discover or import Linear state.

## Project layout

- `lib/symphony_elixir/` — domain, event history, projection, orchestration, worktrees, agent backends (Codex, ACP/Kimi), GitHub
- `lib/symphony_elixir_web/` — loopback LiveView board, MCP dispatch, and generic HTTP fallback
- `workflow/prompts/` and `workflow/workpads/` — strict standard templates
- `test/` — unit, integration, UI/MCP, Git, fake-`gh`, and opt-in live coverage
- `WORKFLOW.yml` — standard project workflow contract
