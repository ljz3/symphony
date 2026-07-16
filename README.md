# Symphony

Symphony turns project work into isolated, autonomous implementation runs. The reference service
owns a local Kanban board, records every task action in Git, runs stage-specific Codex agents in
persistent source worktrees, and coordinates pull requests through GitHub.

> [!WARNING]
> Symphony is an engineering preview for trusted environments. It can run Codex unattended with
> the permissions configured for a project; inspect the workflow and source repository before
> starting it.

## Architecture

Symphony separates durable task authority from rebuildable runtime state:

- A bare Git repository is the canonical, append-only event history.
- SQLite is the replaceable local board/workpad projection; private versioned sidecars outside the
  runtime database are authoritative for non-canonical local workpad history and publication state.
- Phoenix LiveView serves the loopback-only Kanban board, task editor, and live project statistics.
- The same loopback listener exposes exactly three guarded MCP task tools for Codex: creation,
  exact task lookup, and current-task listing by workflow state.
- One persistent Git worktree and immutable branch belong to each task.
- A service-owned `gh` client creates draft pull requests, publishes workpads, checks review
  readiness, and verifies merges. Publish-only transitions are accepted only after their workpad
  marker and local publication manifest are durable.
- Completed, stopped, and failed Codex runs retain canonical runtime/turn/token statistics; the PR
  body or the run's published workpad comment exposes the same compact summary without extra comments.
- The board and statistics view combine those durable summaries with active SQLite telemetry to show
  all-time project/task usage, exact-model, stage, and effort breakdowns, live agent time, safe
  activity, and current per-worker rate limits.
- `WORKFLOW.yml` plus strict Solid Markdown templates define columns, transitions, stages, prompts,
  model policy, and hooks.

The standard flow is:

```text
Backlog -> Todo -> In Progress -> Automated Review -> Human Review -> Merging -> Done
                                \-> Rework ---------/
```

Blocked and Cancelled are explicit side paths. A failed agent invocation moves the task to Blocked;
there is no agent retry queue.

See [SPEC.md](SPEC.md) for the behavioral contract and [elixir/README.md](elixir/README.md) for setup,
operation, storage, and recovery instructions.

## Clean break from the previous service

This architecture does not import tasks or managed state from the former Linear-backed service.
Existing external tasks and unmanaged workspace directories are neither imported nor deleted. Start
with a new `WORKFLOW.yml` and create tasks on the embedded board. An empty `board.remote` and absent
local board history mean “start a fresh embedded board,” not “migrate external task state.”

## Reference implementation

The current implementation is under [`elixir/`](elixir/). It requires Elixir 1.19/OTP 28, Git, an
authenticated GitHub CLI, and Codex app-server.

To implement a compatible service in another language, use the root specification:

> Implement Symphony according to
> https://github.com/openai/symphony/blob/main/SPEC.md

## License

This project is licensed under the [Apache License 2.0](LICENSE).
