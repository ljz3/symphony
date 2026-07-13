# Replace Linear with a Git-Backed Local Kanban

## Summary

Replace Linear entirely with an embedded Phoenix LiveView Kanban board. Symphony becomes the sole task authority, persists every domain action as a Git event, projects current state into SQLite, runs stage-specific Codex agents in persistent Git worktrees, and uses GitHub for pull requests and review discussion.

This is a clean breaking change:

- No Linear adapter, GraphQL client/tool, labels, credentials, import path, or `WORKFLOW.md` compatibility.
- No migration of existing Linear tasks.
- Existing unmanaged workspaces are left untouched for safety.
- `WORKFLOW.yml` and referenced Solid Markdown templates define each project’s workflow.
- An empty `board.remote` with no local event history creates a fresh embedded board and never triggers external-state discovery or migration.

## Architecture and Persistence

### Project storage

Use `$SYMPHONY_HOME`, defaulting to `~/.symphony`, with this layout:

```text
~/.symphony/<project.id>/
├── history.git/            # Bare canonical board-history repository
├── runtime/
│   ├── board.sqlite3       # Rebuildable projection plus local workpads
│   ├── lease/              # Single-instance ownership
│   └── logs/
└── worktrees/
    └── <TASK-ID>/          # Persistent source worktree per task
```

Allow machine-local overrides for Symphony home, worktree root, logs, and port through CLI/environment settings, never tracked workflow configuration.

### Canonical Git event history

- Add a serialized `Board.Writer` process that accepts validated commands with actor, task revision, and idempotency key.
- Store events on `refs/heads/main` in the bare history repository. Each commit adds one immutable JSON event under `events/<sequence>-<event-id>.json`.
- Event envelopes contain an internal format version, global sequence, event/command IDs, project/task/run IDs, task revision, actor type and identity, timestamp, event type, and typed payload.
- Use a temporary Git index, `commit-tree`, and compare-and-swap `update-ref`; never depend on a mutable history working tree.
- Commit Git first, then apply the event transactionally to SQLite and broadcast PubSub updates. A crash after Git but before SQLite is repaired by replay.
- Cover task creation/update/reorder/archive, criteria and dependencies, transitions/block/resume, run lifecycle, branch/PR linkage, source heads, GitHub publication/readiness/merge outcomes, and external-effect saga state.
- Retry optional board-remote pushes independently with backoff. Local commits remain authoritative and the UI shows ahead/behind/error state.
- Reject remote divergence and gate mutations/dispatch. Provide `symphony board reconcile --take-local|--take-remote`, preserving the losing head under a timestamped backup ref before reset or force-push.
- Checkpoint SQLite on every 100 events, clean shutdown, and verified handoff. Store verified snapshots on a separate `checkpoints` branch with the corresponding event OID/sequence.
- `symphony board handoff` requires no running agents, creates a checkpoint, pushes event/checkpoint refs, and verifies remote OIDs.

### SQLite projection

Add Ecto SQL with `ecto_sqlite3 ~> 0.24.1`, WAL mode, full durability, and internal migrations.

Project:

- Task state, criteria/evidence, dependencies, stage model selections, projected event history, runs, branch/PR metadata, sync state, and idempotency records.
- Keep run workpads in SQLite only. They are deliberately non-canonical and may rewind to the latest checkpoint after catastrophic recovery.
- Keep live run telemetry in an internally migrated SQLite table: the latest accepted cumulative token high-water mark and unique Codex turn IDs. On terminal finalization, copy the summary into the canonical run event and remove the transient row. Replay must reconstruct final stats without requiring telemetry.
- Restore from the newest compatible, integrity-checked checkpoint, then replay later events; fall back to full replay when necessary.
- Hold one process-level project lease. A second instance may expose diagnostics but cannot mutate or dispatch.

## Workflow and Task Contract

### `WORKFLOW.yml`

Replace front-matter Markdown parsing with one configuration-only YAML document; there is no user-visible schema-version field.

Keep only genuine project choices:

- Required immutable `project.id` and uppercase `project.key`.
- Optional source remote override, defaulting to `origin`; derive source Git root and remote default branch.
- Optional board-history remote.
- Codex command, project-wide sandbox/approval/network/timeouts.
- Agent concurrency, turns per run, shared base/context prompt paths.
- Named stages with prompt, workpad template, and stage-specific allowed model/effort map.
- Ordered columns and workflow-specific flags.
- Human/agent transition edges.
- Project-specific worktree hooks and timeout.

Load the YAML and every referenced template as one strict bundle. Parse all templates with strict Solid variables/filters before activation, and render validation fixtures for both realistic empty first-run values and populated values.

- Invalid bundles keep the board readable but gate new dispatch.
- Defer valid bundle activation until no agent is starting/running/stopping.
- Freeze the complete stage bundle for each run.
- Reject removal of column IDs still referenced by live tasks.
- Activate model-policy changes, but move incompatible paused tasks to Blocked for explicit reselection.
- Prompt/template edits apply only to future runs.

### Prompt composition

For every run render, in order:

1. A hard-coded runner contract enforcing worktree safety, scoped tools, non-interactive execution, and required stage transition.
2. Workflow base prompt.
3. Workflow context prompt.
4. Selected stage prompt.

Expose stable curated Solid maps for `task`, `run`, `stage`, `github`, dependencies, criteria/evidence, prior handoffs, and allowed transitions. Prior handoffs include run/stage/status metadata plus available workpad invocation metadata. Formatting and field inclusion remain controlled by the workflow context template.

Each named stage references its own workpad template. Render a fresh SQLite workpad per AgentRunner invocation; continuation turns in that invocation share it.

### Standard workflow

Ship:

```text
Backlog
→ Todo
→ In Progress
→ Automated Review
→ Human Review
→ Merging
→ Done
```

With Rework, Blocked, and Cancelled branches.

- `Backlog`: initial pause column.
- `Todo`: implementation dispatch; `on_claim` atomically moves to In Progress.
- `In Progress`: implementation stage.
- `Automated Review`: separately prompted review stage.
- `Human Review`: pause; entering publishes workpads and marks the draft PR ready.
- `Rework`: separately prompted rework stage, returning to Automated Review.
- `Merging`: merge/land stage.
- `Blocked`: unique special role; records prior column and resumes there.
- `Done`: successful terminal state and the only dependency-satisfying terminal.
- `Cancelled`: unsuccessful terminal state.

Support only `dispatch`, `pause`, `blocked`, and `terminal` roles. A dispatch column must reference a named stage. An optional `on_claim` target must be dispatchable and use the same stage.

Configure human/agent transitions in YAML. Hard-code system transitions for claim, any dispatch failure to Blocked, and terminal cleanup.

### Task model

Introduce a tracker-neutral `%SymphonyElixir.Task{}` and remove `%Linear.Issue{}`.

Task creation always starts in the configured initial column and requires:

- Internal UUID and irreversible `<PROJECT-KEY>-<number>` identifier.
- Title.
- Immutable type: Feature, Bug Fix, or Chore.
- Derived immutable branch: `feature/ID`, `fix/ID`, or `chore/ID`.
- Urgent, High, Normal, or Low priority; default Normal.
- Required Markdown brief.
- Nonempty ordered acceptance checklist.
- Optional acyclic dependencies.
- Model/effort choices for every reachable multi-pair agent stage.

For each named stage:

- Require a nonempty allowed model/effort map.
- Resolve a singleton pair automatically.
- Require task creation to select a pair when multiple combinations are allowed.
- Show live Codex catalog intersection when available; trust workflow policy when catalog loading fails during task editing.
- Revalidate the exact model through the complete hidden/paginated catalog at dispatch.
- Freeze the stage pair for the run.
- Move immediately to Blocked on any catalog/start/pair failure; never retry or substitute.

Other invariants:

- No labels.
- Never reuse task numbers.
- Archive by tombstone; never erase history.
- Dispatch by priority, then sparse board rank; renormalize ranks within one event when gaps are exhausted.
- Only Done satisfies dependencies. Waiting tasks remain visibly ranked in Todo.
- Reject dependency cycles.
- Freeze the task execution contract while starting/running/stopping.
- Agent-completed criteria require evidence; humans may reopen them. Editing criterion text reopens it while retaining prior evidence history.

## Runtime, GitHub, UI, and Interfaces

### Orchestrator lifecycle

Replace tracker polling with event-driven candidate dispatch plus periodic runtime reconciliation.

1. Query SQLite for eligible dispatch tasks with satisfied dependencies and available slots.
2. Atomically commit a run claim and any `on_claim` transition.
3. Create/reuse the persistent task worktree and branch.
4. Run hooks.
5. Resolve and validate the frozen stage model/effort.
6. Render prompt/workpad and start Codex app-server in the worktree.
7. Run up to `max_turns_per_run`, reusing the same session and workpad.
8. Require an agent transition before the invocation ends.

Apply the configured Codex sandbox mode to every turn. For local `workspace-write` runs, grant write
access to both the managed task worktree and its shared Git common directory while keeping the
source checkout's working tree read-only. A task worktree must be able to stage and commit without
broad source-checkout write access.

Outcomes:

- Transition to a different dispatch stage ends the current stage successfully and schedules a fresh run with the new stage prompt/workpad.
- Transition to pause/terminal finishes the run.
- Ending in the unchanged dispatch stage, exhausting turns, requesting input, hook/process/protocol failure, or abnormal exit moves immediately to Blocked.
- There is no agent retry queue.
- On restart, any durable run without a live process is considered failed and moved to Blocked.
- Human movement of a running card initiates graceful stop, then forced termination if needed; show the desired column separately from observed `stopping` runtime state.
- Every completed, stopped, or failed run records `stats.duration_ms`, `stats.turn_count`, and `stats.token_usage`. Measure from `started_at` to `finished_at`, falling back to `claimed_at` when Codex never starts. Token usage contains cumulative input, cached-input, output, and total counts, or `null` when Codex supplied no authoritative total.
- Terminal cleanup is idempotent and never rolls back the task when cleanup fails. For a marker-proven managed worktree, remove the worktree first and then delete only its local task branch; retain the marker for retry when branch deletion fails. Terminal cleanup never deletes a remote source branch or switches/touches the source checkout to make deletion succeed.

Preserve SSH workers through a worktree backend:

- Local execution uses the source repository’s object store.
- Each SSH worker maintains a per-project bare source mirror and task worktrees, synchronized through the configured source remote.
- Retain host capacity scheduling; an unhealthy worker is excluded, and dispatch is globally gated only when no eligible worker remains.

### Run-scoped Codex tools

Remove `linear_graphql`. Advertise strict, task-scoped dynamic tools:

- `symphony_task_context`
- `symphony_workpad_read`
- `symphony_workpad_write`
- `symphony_acceptance_complete`
- `symphony_task_transition`
- `symphony_task_create`

Pass app-server call metadata to the executor so the call ID becomes the idempotency key. Mutations are scoped to the current task/run except execution-ready follow-up creation, which always creates a Backlog task.

Agents cannot edit the running task contract or reopen criteria. `symphony_workpad_read` defaults to the current run/invocation and may select only completed prior runs with the same task ID; cross-task and other non-completed-run reads are rejected. Prior-run reads return run, stage, status, finish-time, and invocation metadata with the content. Human UI actions use the same command validator and event writer.

### External MCP task creation

Serve Streamable HTTP MCP at the exact `/mcp` path on the existing loopback UI listener. Expose only
`symphony_task_create`; do not expose MCP resources, prompts, or other board tools. The external
schema matches the run-scoped creation schema and additionally requires `project_id`.

Compare `project_id` exactly with the active workflow project before invoking the board. Missing or
mismatched identity must create no event and must not disclose the active project ID. Reject unknown
top-level arguments server-side. Valid calls use the live serialized board writer, an agent actor,
and a per-MCP-session/request idempotency key so retransmission of one JSON-RPC request creates at
most one canonical task event. A fresh tool invocation creates a new task.

The MCP route runs before general Phoenix body parsing, binds only through the UI's loopback server,
and accepts only localhost Host and Origin values. It has no independent port or listener lifecycle.

### Source Git and GitHub

Use a service-owned `gh` CLI client, not a Codex connector or new HTTP SDK.

- Require a GitHub source remote and working `gh` authentication before new dispatch.
- Create the task branch/worktree from the latest remote default branch on first dispatch.
- Reconcile worktree HEAD during runs and after turns/tool calls.
- After the first meaningful committed diff from the remote default branch, push the branch and create a draft PR with a deterministic task-derived draft body. Documentation, product-specification, configuration, and tooling-only committed diffs qualify; a zero-diff branch does not.
- Put a hidden creator-run marker in each newly created PR and retain that association on the run. An existing PR without the marker is pre-existing and has no creator run.
- Store branch, base/head SHAs, PR number/URL, and merge SHA as canonical board events.
- A mid-run GitHub outage globally gates new dispatch; let the active invocation reach a safe local commit and wait in the same run/session while push/PR operations retry.
- Entering a `publish_workpad` column posts one new PR comment containing every unpublished run workpad since the last publication. Include a hidden publication ID marker so retries are idempotent.
- After termination, append the creator run's compact status/model/effort/runtime/turn/token block to the PR body. Append every other run's block to the existing comment identified by its workpad publication marker, reconciling comments posted before final stats exist. Never create a stats-only comment, never copy a creator run into a workpad comment, and never expose Codex thread IDs or pricing estimates.
- Include a hidden per-run stats marker and record successful publication as an idempotent canonical run event with destination, publication ID, and timestamp. GitHub failures stay in external-effect reconciliation and never retry or alter the agent run.
- Entering the unique `mark_pr_ready` column requires a clean worktree, pushed matching PR head, completed/evidenced criteria, no requested-changes review, no unresolved review threads, and green required checks; the GitHub CLI's exact no-required-checks diagnostic is an empty green set, while listed failed/pending checks, malformed output, and genuine CLI failures remain blocking. Publish workpads, mark ready, then complete the board transition through a resumable saga.
- Human Review → Rework converts the PR back to draft.
- Cancelled closes any open PR with a reason.
- Done is accepted only after GitHub reports the PR merged and the merge SHA is reachable from the remote default branch.
- Retain the existing land skill and squash-merge flow; task history is preserved in the separate board repository.

### Board UI and public interfaces

Replace the read-only dashboard with a loopback-only LiveView application:

- `/`: ordered Kanban with drag/drop, priority-aware ordering, dependency/runtime/blocked badges, PR links, and project health.
- `/stats`: durable all-history project/task accounting, active sessions, service uptime, safe activity, and current rate limits grouped by worker.
- `/tasks/:identifier`: editable task detail, criteria/evidence, dependencies, stage selections, branch/PR, effective live/canonical run statistics, workpads, event history, and Blocked resume/archive actions.
- `/archive`: archived tasks.
- Creation/edit forms enforce the complete task contract and only show selectors for stages with multiple allowed pairs.
- Human moves are limited to configured transition edges; stopping/cancelling active work requires confirmation.
- Header health covers workflow validity/pending activation, lease, board projection/history, remote sync, GitHub, Codex catalog, and workers.
- Kanban cards show per-task token, agent-time, and turn summaries. Project and task totals include archived history and overlay active telemetry without changing canonical events.
- Sum reported input, cached-input, output, and total fields independently. Mark aggregates complete, partial, or unavailable; cached input is a subset of input, partial totals are lower bounds, and authoritative zero remains distinct from missing usage.
- Agent time sums run durations and may exceed project age or current service uptime under concurrency. Project age begins at the earliest claim; uptime, safe latest activity, and per-worker rate limits reset with the orchestrator.
- `/mcp`: Streamable HTTP MCP sharing the configured UI port and exposing only guarded Backlog task creation.

Keep JSON APIs read-only and loopback-only:

- `GET /api/v1/state`
- `GET /api/v1/tasks/:identifier`
- `POST /api/v1/refresh`

`GET /api/v1/state` includes a `stats` snapshot with counts, project/runtime summaries, active runs,
and per-task totals. `GET /api/v1/tasks/:identifier` includes aggregate `stats` and adds
`effective_stats` plus optional safe `activity` to each run without replacing canonical run `stats`.

LiveView calls the board context directly, and there is no general-purpose mutation REST API. The
loopback MCP route is the only external model-facing write interface and is constrained by its exact
project-ID guard and one-tool allowlist.

Expose a public Elixir boundary with adjacent specs:

- `Board.execute(command, actor:, expected_revision:, idempotency_key:)`
- Board/task/run query functions, including `Board.metrics/0` and `Board.task_metrics/1`.
- `%Task{}`, `%AgentStage{}`, `%Workflow.Bundle{}`, typed command/event structs.
- PubSub notifications for task, run, health, workflow, and sync changes.

Update CLI behavior:

- Default workflow path becomes `WORKFLOW.yml`.
- Require the existing guardrail acknowledgement.
- Require `--port` or `SYMPHONY_PORT`; bind only to loopback.
- Add `--symphony-home`, `--worktrees-root`, and existing log overrides.
- Add `board status`, `board checkpoint`, `board handoff`, and guarded divergence-reconciliation commands.

## Migration, Documentation, and Testing

### Clean removal

- Delete Linear client/adapter/issue modules, tracker adapters, `linear_graphql`, Linear-specific tests/live fixtures, API-key/project config, and the repository Linear skill.
- Rename issue terminology to task throughout runtime state, logs, APIs, UI, and templates.
- Remove tracker polling and retry queues.
- Replace the checked-in workflow with `WORKFLOW.yml`, shared policy/context prompts, stage prompts, and stage workpad templates.
- Update the root specification, root README, Elixir README, AGENTS instructions, logging documentation, token accounting, and PR/live-test instructions in the same change.
- Document that old Linear workspaces and tasks are not imported or deleted.

### Tests

Add targeted coverage for:

- YAML bundle loading, strict template validation, dependency graph checks, deferred hot reload, and incompatible live-task policy changes.
- Stage-specific model resolution: singleton auto-selection, required multi-pair choices, catalog fallback during editing, exact dispatch validation, and Blocked failures.
- Git event append/CAS/idempotency, replay, projection failure recovery, checkpoint restore/integrity fallback, push lag, divergence, handoff, and backup refs.
- SQLite migrations, task invariants, evidence, dependency cycles, rank compaction, archive, Blocked resume, and workpad loss/recovery semantics.
- Actor-aware transitions and all external-effect saga crash windows.
- Local and SSH worktree creation/reuse/removal, path/symlink safety, branch collisions, dirty worktrees, source fetch failures, and terminal cleanup.
- Run-scoped dynamic-tool schemas, current/prior invocation selection, completed same-task prior-workpad reads, cross-task isolation, expected revisions, call-id idempotency, transition requirements, and follow-up creation.
- Shared-listener MCP handshake/tool discovery, exact-path dispatch, project-ID fail-closed behavior, Host/Origin rejection, canonical task creation, and per-request idempotency.
- Orchestrator claim/on-claim behavior, stage handoffs, no-retry blocking, orphan recovery, human stop, GitHub-wait exception, capacity, and dependency gating.
- Cumulative-only token extraction, camel/snake-case token fields, cached tokens, high-water behavior, unique turns, telemetry migration/recovery/cleanup, terminal stats for completion/stop/failure, and `null` unavailable usage.
- Fake-`gh` GitHub zero/green/failed/pending/malformed/failure check handling, meaningful-diff draft PR creation including documentation-only and zero-diff cases, publication markers, readiness prerequisites, rework-to-draft, cancellation, and merge validation.
- Creator-run PR-body routing, existing workpad-comment routing before or after finalization, unpublished failed-run locality, retry-after-GitHub-failure, and crash-after-publication idempotency.
- LiveView creation/editing, model selectors, drag/reorder, invalid transitions, active-stop confirmation, Blocked resume, archive, and health states.
- Read-only API response compatibility and method rejection.

Replace the Linear live E2E with:

1. Temporary source and board remotes.
2. Local task creation through the board.
3. Fake or real Codex implementation run in a task worktree.
4. First-commit draft PR creation.
5. Automated Review → Human Review workpad publication.
6. Rework cycle with a second workpad comment.
7. Merge → Done validation and cleanup.
8. Service restart followed by event replay and identical board state.

Run targeted tests during implementation, then `mix specs.check` and the full `make all` gate.

## Assumptions

- One active Symphony instance owns one project.
- The source repository is GitHub-hosted; Git, `gh`, and Codex are installed and authenticated where needed.
- Board remotes are optional; local-only operation is fully supported.
- Board UI/API/MCP bind only to loopback and require no authentication in v1.
- Workpads are intentionally less durable than task/event history.
- There is no historical token backfill; only runs finalized after this behavior is deployed have complete stats. Cached-input tokens are shown separately and remain a subset of input tokens.
- User-facing workflow configuration has no schema-version field; internal SQLite migrations and event-format compatibility remain implementation details.
- The checked-in standard workflow includes Automated Review followed by optional Human Review.
