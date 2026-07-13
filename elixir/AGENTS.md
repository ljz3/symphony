# Symphony Elixir

This directory contains the Elixir service for the Git-backed local Kanban board, canonical Git
event history, SQLite projection, persistent task worktrees, and stage-specific Codex orchestration.

## Environment

- Elixir: `1.19.x` (OTP 28) via `mise`.
- Install deps: `mix setup`.
- Main quality gate: `make all` (format check, lint, coverage, dialyzer).

## Codebase-Specific Conventions

- Runtime config is loaded from strict `WORKFLOW.yml` plus referenced Solid templates through
  `SymphonyElixir.Workflow` and `SymphonyElixir.Config`.
- Keep the implementation aligned with [`../SPEC.md`](../SPEC.md) where practical.
  - The implementation may be a superset of the spec.
  - The implementation must not conflict with the spec.
  - If behavior changes materially, update the spec in the same change where practical.
- Prefer config access through `SymphonyElixir.Config`; machine-local roots belong in
  `SymphonyElixir.Paths`, CLI flags, or environment variables.
- Git event history is authoritative. Commit the event before projecting it to SQLite, and preserve
  CAS, replay, checkpoint, idempotency, divergence, and handoff semantics.
- Workspace safety is critical:
  - Never run a Codex turn in the source repository.
  - Managed worktrees must stay under the configured worktree root.
  - Do not delete unmanaged, branch-colliding, dirty, or path-unsafe directories.
- Orchestration is stateful and concurrency-sensitive. Preserve atomic claim/on-claim, dependency
  gating, graceful/forced stop, orphan recovery, external-effect saga, and cleanup behavior.
- An agent invocation failure moves its task to Blocked. Do not introduce an agent retry queue;
  GitHub publication retries remain inside the active run/session.
- Follow `docs/logging.md` for required project/task/run/session context.

## Tests and Validation

Run targeted tests while iterating, then the full gate before handoff:

```bash
make all
```

Public-function spec validation is also available directly:

```bash
mix specs.check
```

## Required Rules

- Public functions (`def`) in `lib/` must have an adjacent `@spec`.
- `defp` specs are optional.
- `@impl` callback implementations are exempt from the local `@spec` requirement.
- Keep changes narrowly scoped; avoid unrelated refactors.
- Follow existing module/style patterns in `lib/symphony_elixir/*`.

## PR Requirements

- PR body must follow `../.github/pull_request_template.md` exactly.
- Validate a prepared body locally when needed:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## Docs Update Policy

If behavior or config changes, update the relevant documentation in the same PR:

- `../README.md` for project concept and goals.
- `README.md` for Elixir operation and recovery.
- `WORKFLOW.yml` and referenced templates for workflow contract changes.
- `../SPEC.md` for intended architecture and invariants.
