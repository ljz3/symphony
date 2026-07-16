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
│   ├── board.sqlite3       # Rebuildable board and workpad projection
│   ├── recovery/           # Retained confirmed-corrupt database families
│   ├── lease/              # Single-instance ownership
│   └── logs/
├── workpads/               # Private authoritative local workpad history
│   ├── records/<run-id>/<invocation>.json
│   └── publications/<publication-id>.json
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
- Cover task creation/update/reorder/archive, criteria and dependencies, transitions/block/resume, run lifecycle, branch/PR linkage, source heads, canonical review attestations, GitHub publication/readiness/merge outcomes, and checkpointed external-effect saga state.
- Retry optional board-remote pushes independently with backoff. Local commits remain authoritative and the UI shows ahead/behind/error state.
- Reject remote divergence and gate mutations/dispatch. Provide `symphony board reconcile --take-local|--take-remote`, preserving the losing head under a timestamped backup ref before reset or force-push.
- Checkpoint SQLite on every 100 events, clean shutdown, and verified handoff. Store verified snapshots on a separate `checkpoints` branch with the corresponding event OID/sequence.
- `symphony board handoff` requires no running agents, creates a checkpoint, pushes event/checkpoint refs, and verifies remote OIDs.

### SQLite projection

Add Ecto SQL with `ecto_sqlite3 ~> 0.24.1`, WAL mode, full durability, and internal migrations.

Project:

- Task state, criteria/evidence, dependencies, stage model selections, projected event history, runs, branch/PR metadata, sync state, and idempotency records.
- Keep run workpads non-canonical and private, but make versioned JSON sidecars under `workpads/` authoritative over their SQLite projection. Record v2 stores a nullable initial-template SHA-256; every non-null value is exactly 64 lowercase hexadecimal characters. Ordinary writes preserve it, while legacy v1 records remain readable and conservatively meaningful. Publication manifests remain v1. Write each owner-only record with write-sync-rename before updating SQLite. After GitHub acknowledges a marker comment, atomically write an owner-only publication manifest before marking projection rows published. Publication identity is the task ID plus sorted run/invocation/content hashes and excludes timestamps.
- On startup, export legacy SQLite-only workpads, validate every existing sidecar without overwriting it, rehydrate SQLite from the sidecars, and derive publication state only from manifests whose stored hashes match current records. A malformed sidecar aborts startup and reports its exact path.
- Keep live run telemetry in an internally migrated SQLite table: the latest accepted cumulative token high-water mark and unique Codex turn IDs. On terminal finalization, copy the summary into the canonical run event and remove the transient row. Replay must reconstruct final stats without requiring telemetry.
- Classify database health as healthy, confirmed corrupt, or indeterminate. Leave healthy databases untouched. An open, permission, NIF, or health-check execution failure is indeterminate and aborts startup without changing the database, WAL, or SHM files. For confirmed corruption, build and validate a checkpoint-derived or empty replacement first, retain the original database family under `runtime/recovery/`, and roll back installation failures. Never delete quarantines automatically; replay canonical events after startup.
- Hold one process-level project lease. A second instance may expose diagnostics but cannot mutate or dispatch. Identify the owning machine independently of its mutable hostname so a dead local owner can be reclaimed without treating a remote owner as stale.

## Workflow and Task Contract

### `WORKFLOW.yml`

Replace front-matter Markdown parsing with one configuration-only YAML document; there is no user-visible schema-version field.

Keep only genuine project choices:

- Required immutable `project.id` and uppercase `project.key`.
- Optional source remote override, defaulting to `origin`; derive source Git root and remote default branch.
- Optional board-history remote.
- Codex command and project-wide sandbox/approval/network policy.
- Agent concurrency and shared base/context prompt paths.
- Optional named blocking jobs with an executable, literal fixed argument vector, required/optional/forbidden passthrough policy, and string environment map. `$SYMPHONY_JOB_ID` is the only reserved argument token.
- Optional pre-claim dispatch preflight command and retry delay after explicit failure.
- Optional deterministic squash-merge readiness command plus review and conflict dispatch-column IDs.
- Named stages with prompt, workpad template, and stage-specific allowed model/effort map.
- Ordered columns and workflow-specific flags.
- Human/agent transition edges.
- Project-specific worktree hooks.

Do not expose execution deadlines or output caps in project configuration. Reject former turn-count,
Codex read/turn/stall timeout, hook timeout, job timeout/output-cap, preflight timeout, and merge
timeout/output-cap keys with an explicit migration error rather than applying compatibility defaults.
Elapsed time and inactivity are observational only: managed work ends on completion, explicit
failure/process or protocol termination, invalidating task movement, service shutdown, or explicit
human cancellation. Retry/reconciliation cadence and cancellation escalation may remain bounded.

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

Use one current-state projector for prompts and `symphony_task_context`. Expose only the current task contract and column, active run summary, curated source and GitHub summaries, criteria with current evidence, shallow dependency status, allowed transitions, current preflight state, and the actual active JobManager record reduced to job identity/status/timing/source fingerprint. Omit raw metadata, task runtime/desired state, evidence history, frozen bundles, prior runs/invocations, raw provider readiness, job output/artifact/call internals, and nested dependency state. Workflow templates receive only `stage.id`; frozen stage prompts, templates, paths, and model matrices remain inaccessible as data. Prompt assigns include exactly one `latest_workpad`: the current run's highest meaningful invocation, otherwise the newest completed/failed/stopped same-task run ordered by finish time and run ID with its highest meaningful invocation. An untouched generated template is not meaningful; legacy records without a template hash are meaningful.

Each named stage references its own workpad template. Render a fresh durable private workpad per AgentRunner invocation; continuation turns in that invocation share it.

### Standard workflow

Ship:

```text
Backlog
→ Todo
→ In Progress
→ Automated Review
→ Merging
→ Done
```

With Human Review, Rework, Merge Conflict, Blocked, and Cancelled branches.

- `Backlog`: initial pause column.
- `Todo`: implementation dispatch; `on_claim` atomically moves to In Progress.
- `In Progress`: implementation stage.
- `Automated Review`: separately prompted review stage.
- `Human Review`: pause; entering publishes workpads and marks the draft PR ready.
- `Rework`: separately prompted rework stage, returning to Automated Review.
- `Merge Conflict`: separately prompted repair stage entered only after the system verifies and records
  a real Git conflict; it returns only to Automated Review or Blocked.
- `Merging`: system-owned deterministic merge column when a merge policy is configured.
- `Blocked`: unique special role; records prior column and resumes there.
- `Done`: successful terminal state and the only dependency-satisfying terminal.
- `Cancelled`: unsuccessful terminal state.

Support `dispatch`, `merge`, `pause`, `blocked`, and `terminal` roles. A dispatch column must reference a named stage. An optional `on_claim` target must be dispatchable and use the same stage. A `merge` column must not reference a stage, cannot be human- or agent-targeted, and cannot be agent-claimed. Merge configuration requires exactly one merge column and distinct review/conflict targets that are dispatch columns with distinct stages. The merge column has no configured human or agent exits. The conflict stage's only agent exits are the configured review column and Blocked.

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

1. Query SQLite for eligible queued dispatch tasks with satisfied dependencies and available slots.
2. Reserve global and selected-worker capacity for the candidate.
3. When dispatch preflight is configured, create/reuse the persistent task worktree and run the
   command there while the task remains queued and no run exists.
4. After preflight succeeds, re-read the task and active workflow and discard the result unless the
   task revision, eligibility, workflow hash, and worker reservation still match.
5. Atomically commit a run claim and any `on_claim` transition.
6. Create/reuse the persistent task worktree and branch when preflight did not already do so.
7. Run hooks.
8. Resolve and validate the frozen stage model/effort.
9. Render prompt/workpad and start Codex app-server in the worktree.
10. Run continuation turns without a count or elapsed-time limit, reusing the same session and workpad.
11. Require an agent transition before the invocation ends.

Apply the configured Codex sandbox mode to every turn. For local `workspace-write` runs, grant write
access to both the managed task worktree and its shared Git common directory while keeping the
source checkout's working tree read-only. A task worktree must be able to stage and commit without
broad source-checkout write access.

Outcomes:

- An active preflight consumes global and worker-host capacity. Elapsed time and silence never end
  it. A task notification re-reads current state and terminates the probe only when its revision,
  eligibility/runtime, workflow hash, or worker reservation changed; non-revision events preserve
  the probe. Workflow activation, shutdown, or explicit semantic cancellation may terminate it.
  Results from a cancelled probe are discarded and never become a project preflight failure.
- Explicit preflight failure releases its reservation, keeps the task queued, and retains only the
  current diagnostic fingerprint, reason, completion time, and next retry time for that task.
  Identical failures replace current state instead of appending history, and unrelated tasks remain
  dispatchable. The retry delay schedules a new probe only after the prior probe exits.
- Orchestrator restart terminates an orphaned local or SSH probe through owner monitoring; the new
  orchestrator reruns the current probe and never trusts a pre-restart success.
- Board health exposes only current running and failed preflight projections.
- Transition to a different dispatch stage ends the current stage successfully and schedules a fresh run with the new stage prompt/workpad.
- Transition to pause/terminal finishes the run.
- Ending in the unchanged dispatch stage after an explicit invocation failure, requesting input, hook/process/protocol failure, or abnormal exit moves immediately to Blocked. Elapsed time, silence, and continuation count are not failures.
- There is no agent retry queue.
- On restart, any durable run without a live process is considered failed and moved to Blocked.
- Human movement of a running card initiates graceful stop, then forced termination if needed; show the desired column separately from observed `stopping` runtime state.
- Every completed, stopped, or failed run records `stats.duration_ms`, `stats.turn_count`, and `stats.token_usage`. Measure from `started_at` to `finished_at`, falling back to `claimed_at` when Codex never starts. Token usage contains cumulative input, cached-input, output, and total counts, or `null` when Codex supplied no authoritative total.
- Terminal cleanup is idempotent and never rolls back the task when cleanup fails. For a marker-proven managed worktree, remove the worktree first and then delete only its local task branch; retain the marker for retry when branch deletion fails. Terminal cleanup never deletes a remote source branch or switches/touches the source checkout to make deletion succeed.

Preserve SSH workers through a worktree backend:

- Local execution uses the source repository’s object store.
- Each SSH worker maintains a per-project bare source mirror and task worktrees, synchronized through the configured source remote.
- Probe SSH worker health asynchronously under supervision, without an elapsed-time or inactivity
  deadline. Unknown and probing workers are not selectable. Explicit success records current healthy
  state; exit or failure records current unhealthy state and schedules a later probe only after the
  failed probe terminates. Workflow host removal and shutdown cancel the supervised process tree.
- Retain host capacity scheduling; an unhealthy worker is excluded, direct dispatch resumes after
  explicit health, and dispatch is globally gated only when no eligible worker remains.

### Run-scoped Codex tools

Remove `linear_graphql`. Advertise strict, task-scoped dynamic tools:

- `symphony_task_context`
- `symphony_workpad_read`
- `symphony_workpad_write`
- `symphony_acceptance_complete`
- `symphony_review_complete` for the configured active review run
- `symphony_task_transition`
- `symphony_task_create`
- `symphony_job_run` when the active run's frozen bundle defines jobs

Pass app-server call metadata to the executor and combine the active run ID with the call ID for mutation idempotency. This preserves retransmission safety within a run while allowing app-server call IDs to restart in later runs without replaying an earlier run's result. Mutations are scoped to the current task/run except execution-ready follow-up creation, which always creates a Backlog task. Return only the event type, task revision/current column, and run status when the command returns a run; never echo task/run identity, runtime state, active-run identity, or canonical payloads.

`symphony_review_complete` accepts a strict nested object containing the expected revision, exact
reviewed head, `pass` or `rework` verdict, route, plan-policy status and summary, nonempty validation
evidence, and structured findings. The service, not the model, reads the current clean worktree,
source head, PR head/state, aggregate review decision, every paginated review thread and comment,
and every required check context. It stores the reviewer/run identity, observation time, PR number,
and deterministic feedback/check fingerprints in a canonical review-attestation event. Current-state
projection exposes only the explicit nested attestation allowlist, never raw provider payloads.

A passing attestation requires the exact source/task/PR head, completed criteria with evidence, a
non-deviating plan policy, no blocker/high findings, aggregate GitHub `APPROVED`, no unresolved
threads, and green required checks, and routes only to the unique system merge column. A rework
attestation requires findings and routes only along a configured agent edge to a non-review dispatch
column or Blocked. Direct agent movement into the merge column is rejected. A later canonical source
or PR-head change clears a passing attestation and returns a merge-pending task to review.

Derive the `symphony_job_run` name enum solely from the claimed run's frozen job definitions. One
call starts or attaches to a supervised job and stays pending until a terminal result; do not expose
model-facing polling, sleep, status, or log-tail tools. Execute the fixed vector plus validated
literal passthrough arguments in the managed worktree. Substitute only the exact
`$SYMPHONY_JOB_ID` item, resolve relative executables in that worktree, and resolve bare names via
`PATH`. Inject managed task, run, branch, and job identity plus the job-executor marker.

Persist the job record before spawn and stream stdout/stderr to owner-only artifacts without output
caps. The terminal result returns complete stdout, the stderr artifact location, status/exit code,
timestamps, elapsed observational metadata, and the source fingerprint. Valid UTF-8 stdout is
returned verbatim with `output_encoding: utf8`; otherwise every byte is returned as Base64 with
`output_encoding: base64`. The source fingerprint covers HEAD, the complete staged and unstaged
binary diffs, and length-framed untracked paths, types, and contents. Namespace delivery
idempotency by run/call ID and single-flight identical active task/job/normalized-arguments/source
requests. If the app-server transport disconnects while a blocking call is pending, resume the same
thread and active turn and replay the same durable call result; do not start a second OS job or a new
model turn. Reattach while the service and run remain alive; after unrecoverable recovery mark a
running record `interrupted`, never timed out. Explicit run cancellation terminates the supervised
process group, with force escalation allowed only as cancellation policy; signal delivery must not
block the worker or delay terminal cancellation.

Agents cannot edit the running task contract or reopen criteria. `symphony_task_context` and `symphony_workpad_read` accept exactly an object and require it to be `{}`; JSON nulls, arrays, and scalars are rejected rather than normalized. `symphony_workpad_read` returns the single deterministic `latest_workpad` selection used by PromptBuilder, or `null`; arbitrary run/invocation selectors and workpad history are not exposed. The result contains only run/stage/status/finish/invocation/update metadata and content. Cross-task and non-current active work are never candidates. Human UI actions use the same command validator and event writer.

### External MCP task interface

Serve Streamable HTTP MCP at the exact `/mcp` path on the existing loopback UI listener. Expose exactly
three external tools: `symphony_task_create`, `symphony_task_get`, and `symphony_tasks_by_state`.
Do not expose MCP resources, prompts, board-wide state/statistics, refresh, or other external tools.

All three strict object schemas require `project_id` and reject additional properties. Compare the
value exactly with the active workflow project before validating or processing any other argument.
Missing or mismatched identity must return an `isError=true` tool result, create no event, and must
not disclose the active project ID. Creation retains its live serialized board-writer mutation and
per-MCP-session/request idempotency key, so retransmission of one JSON-RPC request creates at most
one canonical task event. The two read tools are read-only, non-destructive, idempotent, and
closed-world. Expected validation, lookup, project, and workflow failures are safe `isError=true`
text results; unexpected failures use a generic safe error.

`symphony_task_get` accepts an exact human identifier and returns a compact actionable task view with
status/column names, criteria evidence/history, stage selections, resolved `{id, identifier}`
dependencies, branch, a safe `{number, url, draft}` pull-request projection or `null`, active run
ID, timestamps, aggregate task statistics, the three newest compact runs, and the ten newest compact
events. Runs and events use `{items, total, truncated}` envelopes. Run activity is limited to the
existing safe activity summary; workpads, workspace paths, raw task metadata/source/GitHub maps, raw
event payloads, persistence/idempotency metadata, and protocol data remain private. Archived tasks
remain directly addressable; absent tasks return `task_not_found`.

`symphony_tasks_by_state` accepts an exact, case-sensitive workflow column ID. Tool discovery
advertises the active workflow's column IDs as the state enum. It searches current, non-archived
tasks only and preserves canonical priority/rank/number order. Each result contains only the lean
task fields, status, resolved dependency references, branch, and safe pull-request projection.

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
- Before accepting an agent transition into any `publish_workpad` column, synchronously publish every unpublished workpad and durably record its acknowledged marker; publication failure rejects the transition. Reconciliation skips tasks with active runs, retries marker-idempotently, gates only the affected task's dispatch, and reports per-task publication errors in health/status.
- Each publication posts one PR comment containing every unpublished run workpad since the last publication. Include the stable hidden publication ID marker so retries across comment/manifest/SQLite crash windows are idempotent; changed content has a new hash and becomes unpublished.
- After termination, append the creator run's compact status/model/effort/runtime/turn/token block to the PR body. Append every other run's block to the existing comment identified by its workpad publication marker, reconciling comments posted before final stats exist. Never create a stats-only comment, never copy a creator run into a workpad comment, and never expose Codex thread IDs or pricing estimates.
- Include a hidden per-run stats marker and record successful publication as an idempotent canonical run event with destination, publication ID, and timestamp. GitHub failures stay in external-effect reconciliation and never retry or alter the agent run.
- Entering the unique `mark_pr_ready` column requires a clean worktree, pushed matching PR head, completed/evidenced criteria, no requested-changes review, no unresolved review threads, and green required checks; the GitHub CLI's exact no-required-checks diagnostic is an empty green set, while listed failed/pending checks, malformed output, and genuine CLI failures remain blocking. Publish workpads, mark ready, then complete the board transition through a resumable saga.
- Human Review → Rework converts the PR back to draft.
- Cancelled closes any open PR with a reason.
- Reconcile at most one system merge worker at a time, separately from agent capacity and
  `AgentRunner`. Revalidate the exact reviewed source/PR head, feedback fingerprint, aggregate
  approval, all review threads/comments, all required checks, and acceptance evidence before any
  merge effect. A valid failed or pending check payload returns to review; provider transport,
  authentication, or process failure leaves the task merge-pending for reconciliation.
- Run the configured merge-readiness command to natural process exit without an elapsed-time,
  inactivity, or output deadline. Fetch the current remote default branch and compare it with the
  reviewed task head. If the task branch is behind, commit and push a normal merge of the target into
  the task branch, then invalidate the attestation and require exact-head review again. Never rebase
  or rewrite history.
- Before the external clean-update push and guarded squash merge, record a canonical checkpoint.
  Recovery observes current Git/PR state and resumes the same effect rather than repeating a
  completed one. Use literal Git/`gh` argument vectors locally and safely quoted arguments over SSH.
  Squash merge through `gh pr merge --squash --match-head-commit <reviewed-head>`.
- Treat provider-reported conflict as a hint only. Reproduce it with Git, collect the complete sorted
  unmerged-path set, and successfully abort the probe before recording a canonical conflict. The
  first conflict for one task-head/target-head pair routes to the configured conflict stage and
  clears the attestation; the same pair recurring later routes to Blocked. The conflict agent may
  resolve only those recorded paths by merging the recorded target without rebase/history rewrite,
  validate only through managed jobs, commit/push, and return to review; it never lands the PR.
- After guarded squash, fetch the target until the merge SHA is reachable. Atomically record the
  reachable merge outcome and move to Done. Done cannot be reached by an agent and is accepted only
  through this system completion event. Stale reviewed state returns to review, transient external
  failure remains merge-pending, and missing/closed PRs or broken invariants route to Blocked.

### Board UI and public interfaces

Replace the read-only dashboard with a loopback-only LiveView application:

- `/`: ordered Kanban with drag/drop, priority-aware ordering, dependency/runtime/blocked badges, PR links, and project health.
- `/stats`: durable all-history project/task accounting with exact-model aggregates, nested stage breakdowns, and effort rows beneath each stage, plus active sessions, service uptime, safe activity, and current rate limits grouped by worker.
- `/tasks/:identifier`: editable task detail, criteria/evidence, dependencies, stage selections, branch/PR, effective live/canonical run statistics, every ordered workpad invocation for every run outcome, event history, and Blocked resume/archive actions.
- `/archive`: archived tasks.
- Creation/edit forms enforce the complete task contract and only show selectors for stages with multiple allowed pairs.
- Human moves are limited to configured transition edges; stopping/cancelling active work requires confirmation.
- Header health covers workflow validity/pending activation, lease, board projection/history, remote sync, GitHub, per-task workpad publication failures, Codex catalog, and workers.
- Kanban cards show per-task token, agent-time, and turn summaries. Project and task totals include archived history and overlay active telemetry without changing canonical events.
- Model and model-stage summaries reuse the same effective runs, combine effort levels, count distinct all-time and active thread IDs, and preserve missing dimensions as Unknown. The `/stats` HTML view additionally renders effort-level summaries beneath each model-stage row, while the internal stats snapshot remains model/stage-shaped. Completed-task participation counts distinct current or archived Done tasks per group only for runs with a canonical start time or an effective session ID, deduplicates within each model aggregate, and is intentionally non-additive across models and stages.
- Sum reported input, cached-input, output, and total fields independently. Mark aggregates complete, partial, or unavailable; cached input is a subset of input, partial totals are lower bounds, and authoritative zero remains distinct from missing usage.
- Agent time sums run durations and may exceed project age or current service uptime under concurrency. Project age begins at the earliest claim; uptime, safe latest activity, and per-worker rate limits reset with the orchestrator.
- `/mcp`: Streamable HTTP MCP sharing the configured UI port and exposing only the three guarded task tools.

There is no REST JSON API. Former `/api/v1/state`, `/api/v1/tasks/:identifier`, and
`/api/v1/refresh` paths fall through to the generic `404 not_found` response for every HTTP method.
LiveView calls the board context directly, and the loopback MCP route is the only machine-facing
protocol endpoint, constrained by its exact project-ID guard and three-tool allowlist.

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
- Package Exqlite's native library in the escript and extract a content-addressed copy into the
  current user's cache before OTP application startup so the standard launcher can load SQLite.

## Migration, Documentation, and Testing

### Clean removal

- Delete Linear client/adapter/issue modules, tracker adapters, `linear_graphql`, Linear-specific tests/live fixtures, API-key/project config, and the repository Linear skill.
- Rename issue terminology to task throughout runtime state, logs, interfaces, UI, and templates.
- Remove tracker polling and retry queues.
- Replace the checked-in workflow with `WORKFLOW.yml`, shared policy/context prompts, stage prompts, and stage workpad templates.
- Update the root specification, root README, Elixir README, AGENTS instructions, logging documentation, token accounting, and PR/live-test instructions in the same change.
- Document that old Linear workspaces and tasks are not imported or deleted.

### Tests

Add targeted coverage for:

- YAML bundle loading, strict template validation, dependency graph checks, deferred hot reload, and incompatible live-task policy changes.
- Stage-specific model resolution: singleton auto-selection, required multi-pair choices, catalog fallback during editing, exact dispatch validation, and Blocked failures.
- Git event append/CAS/idempotency, replay, projection failure recovery, checkpoint restore/integrity fallback, push lag, divergence, handoff, and backup refs.
- SQLite migrations, task invariants, evidence, dependency cycles, rank compaction, archive, Blocked resume, tri-state database recovery/quarantine/rollback, and sidecar-authoritative workpad loss/recovery semantics.
- Actor-aware transitions; canonical structured review-attestation pass/rework/replay/invalidation;
  and all deterministic merge checkpoint crash windows.
- Local and SSH worktree creation/reuse/removal, path/symlink safety, branch collisions, dirty worktrees, source fetch failures, and terminal cleanup.
- Run-scoped dynamic-tool schemas, exact current-state allowlists, deterministic single-workpad selection across current/completed/failed/stopped runs, untouched-template skipping, legacy record recovery, active/cross-task isolation, compact mutation results, expected revisions, call-id idempotency, transition requirements, and follow-up creation.
- Shared-listener MCP handshake/tool discovery for exactly three tools, strict schemas and read
  annotations, dynamic state enum discovery, exact-path dispatch, project-ID fail-closed behavior,
  safe task/run/event projections, Host/Origin rejection, canonical task creation, and per-request
  idempotency.
- Orchestrator pre-claim reservation, no-run-before-success, stale-success rejection, current-only
  failure projection, unchanged-event preservation, delayed retry, semantic cancellation/restart
  cleanup, asynchronous deadline-free SSH health probing, direct dispatch after explicit health,
  claim/on-claim behavior, stage handoffs, no-retry blocking, orphan recovery, human stop,
  GitHub-wait exception, capacity, and dependency gating.
- Cumulative-only token extraction, camel/snake-case token fields, cached tokens, high-water behavior, unique turns, telemetry migration/recovery/cleanup, terminal stats for completion/stop/failure, and `null` unavailable usage.
- Fake-`gh` GitHub zero/green/failed/pending/malformed/failure check handling, aggregate approval,
  complete thread/comment pagination beyond 100 comments, meaningful-diff draft PR creation including
  documentation-only and zero-diff cases, publication markers, readiness prerequisites,
  rework-to-draft, cancellation, and guarded merge validation.
- System merge/AgentRunner isolation, exact-head/feedback/check routing, delayed deadline-free
  readiness, literal command arguments, real Git conflict path collection and abort, first/repeated
  conflict routing, clean-update and guarded-squash recovery, and merge-SHA reachability.
- Creator-run PR-body routing, existing workpad-comment routing before or after finalization, unpublished failed-run locality, retry-after-GitHub-failure, and crash-after-publication idempotency.
- LiveView creation/editing, model selectors, drag/reorder, invalid transitions, active-stop confirmation, Blocked resume, archive, and health states.
- Former REST paths returning generic 404s for every method, LiveView routing, and the complete MCP
  contract including bounded history and raw-data exclusion.

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
- Board UI/MCP bind only to loopback and require no authentication in v1.
- Workpads are intentionally less durable than task/event history.
- There is no historical token backfill; only runs finalized after this behavior is deployed have complete stats. Cached-input tokens are shown separately and remain a subset of input tokens.
- User-facing workflow configuration has no schema-version field; internal SQLite migrations and event-format compatibility remain implementation details.
- The checked-in standard workflow includes Automated Review followed by optional Human Review.
