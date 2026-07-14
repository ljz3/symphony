# Codex Token Accounting

This document explains how Codex reports token usage through the app-server protocol and how Symphony should account for it.

It is based on the current Codex source in `codex-rs`, especially:

- `app-server/README.md`
- `protocol/src/protocol.rs`
- `app-server/src/bespoke_event_handling.rs`
- `app-server-protocol/src/protocol/v2.rs`
- `exec/src/event_processor_with_jsonl_output.rs`
- `state/src/extract.rs`

## Short Version

- `last_token_usage` means "the latest increment".
- `total_token_usage` means "the cumulative total so far".
- `thread/tokenUsage/updated` is the live streaming notification for token usage.
- `turn/completed` carries final turn state, and turn-level usage is exposed separately from the live thread token stream.
- Generic `usage` fields are event-specific. Do not assume every `usage` payload is a cumulative thread total.

## Primary Source Semantics

Codex defines `TokenUsageInfo` like this:

```rust
pub struct TokenUsageInfo {
    pub total_token_usage: TokenUsage,
    pub last_token_usage: TokenUsage,
    pub model_context_window: Option<i64>,
}
```

The important behavior is in `append_last_usage`:

```rust
pub fn append_last_usage(&mut self, last: &TokenUsage) {
    self.total_token_usage.add_assign(last);
    self.last_token_usage = last.clone();
}
```

That gives the core semantics:

- `last_token_usage`: the newest chunk of usage that was just added
- `total_token_usage`: the accumulated total after adding that chunk

This is the most important accounting rule in the Codex source.

## Event Types

### `codex/event/token_count`

Codex core emits token count events containing `TokenUsageInfo`.

These events can carry:

- `info.total_token_usage`
- `info.last_token_usage`
- `info.model_context_window`

Symphony sees these events wrapped inside the app-server message stream.

Meaning:

- `total_token_usage` is an absolute cumulative snapshot
- `last_token_usage` is the delta that produced that snapshot

### `thread/tokenUsage/updated`

The app-server converts token count events into a dedicated thread-scoped notification:

```rust
let notification = ThreadTokenUsageUpdatedNotification {
    thread_id: conversation_id.to_string(),
    turn_id,
    token_usage,
};
```

`ThreadTokenUsage` is defined as:

```rust
pub struct ThreadTokenUsage {
    pub total: TokenUsageBreakdown,
    pub last: TokenUsageBreakdown,
    pub model_context_window: Option<i64>,
}
```

And it is populated directly from `TokenUsageInfo`:

```rust
impl From<CoreTokenUsageInfo> for ThreadTokenUsage {
    fn from(value: CoreTokenUsageInfo) -> Self {
        Self {
            total: value.total_token_usage.into(),
            last: value.last_token_usage.into(),
            model_context_window: value.model_context_window,
        }
    }
}
```

Meaning:

- `thread/tokenUsage/updated` is the canonical live notification for token usage
- `tokenUsage.total` is an absolute thread total
- `tokenUsage.last` is the latest increment that produced that total

The app-server README is explicit: token usage streams separately via `thread/tokenUsage/updated`.

### `turn/completed`

The app-server README says `turn/completed` carries final turn state and token usage.

There are two important details:

1. The app-server protocol `turn/completed` notification contains a final `turn` object.
2. The `exec` event processor also emits a turn-completed event that includes a `usage` struct.

In the `exec` event processor, the turn-completed usage is built from the most recent captured `total_token_usage`:

```rust
if let Some(info) = &ev.info {
    self.last_total_token_usage = Some(info.total_token_usage.clone());
}
```

Then on turn completion:

```rust
let usage = if let Some(u) = &self.last_total_token_usage {
    Usage {
        input_tokens: u.input_tokens,
        cached_input_tokens: u.cached_input_tokens,
        output_tokens: u.output_tokens,
    }
}
```

Important consequence:

- a turn-completed `usage` payload is not the same schema as `ThreadTokenUsage`
- it should be interpreted in the context of the specific event that emitted it
- it must not be blindly mixed with `thread/tokenUsage/updated` accounting

### Generic `usage`

Codex uses the word `usage` in multiple places.

That does not mean all `usage` maps have the same semantics.

Examples:

- `thread/tokenUsage/updated.tokenUsage.total`: absolute cumulative thread total
- `thread/tokenUsage/updated.tokenUsage.last`: latest delta
- turn-completed `usage`: event-specific completion usage payload

Rule:

- never classify a `usage` map by name alone
- classify it by event type and payload path

## What The Metrics Mean

### Absolute totals

These are safe high-water-mark style counters:

- `info.total_token_usage`
- `tokenUsage.total` on `thread/tokenUsage/updated`

Use these when you want:

- live board totals
- stable per-thread accumulation
- recovery after missed intermediate events

### Deltas

These are incremental additions:

- `info.last_token_usage`
- `tokenUsage.last` on `thread/tokenUsage/updated`

Use these only when:

- no absolute total is available
- you are explicitly handling additive updates

### Context window

`model_context_window` is not spend. It is the model's context limit.

Codex also has logic that can "fill to context window", which sets:

- `total_token_usage.total_tokens = context_window`
- `last_token_usage.total_tokens = delta`

So `total_tokens` can reflect context-window normalization behavior, not just a raw upstream token report.

For Symphony, `model_context_window` should be displayed or logged separately from spend.

## Recommended Accounting Strategy For Symphony

Track usage per active Codex thread.

For each thread, keep:

- `absolute_total`: latest accepted absolute total snapshot
- `accumulated_total`: the total you expose in UI/API
- `last_seen_turn_id`

### Preferred source order

When a token-related event arrives, use this precedence:

1. `thread/tokenUsage/updated.tokenUsage.total`
2. `TokenCountEvent.info.total_token_usage`

Ignore these for accounting:

- `thread/tokenUsage/updated.tokenUsage.last`
- `TokenCountEvent.info.last_token_usage`
- generic `usage` maps
- turn-completed `usage`

Do not treat generic `params.usage` as equivalent to a cumulative thread total unless the event type makes that meaning explicit.

### Algorithm

#### If an absolute total is present

- Treat it as a thread-level snapshot.
- If it is greater than or equal to the stored `absolute_total`, replace the stored absolute total.
- Set exposed totals from that absolute snapshot.
- Do not add the corresponding delta again.

#### If no absolute total is present

- Ignore the event for accounting.
- Keep the last accepted absolute high-water mark unchanged.

### Why this matters

If you misclassify a per-turn `usage` payload as an absolute thread total, later turns can appear to stall because a smaller per-turn number is compared against a larger cumulative baseline.

## What Symphony Should And Should Not Do

### Do

- Prefer `thread/tokenUsage/updated` for live reporting.
- Treat `tokenUsage.total` as authoritative for thread totals.
- Key accounting by `thread_id`, not just task ID.
- Expect one thread to span multiple turns when Symphony reuses a live Codex thread.

### Do not

- Do not treat every `usage` map as absolute.
- Do not count `tokenUsage.last` or `last_token_usage` into board totals.
- Do not add turn-completed `usage` on top of already-counted live thread totals unless you can prove it represents missing spend.
- Do not reset accounting just because a new turn starts on the same thread.

## Practical Interpretation For Symphony Logs

When reading raw app-server events:

- `codex/event/token_count`
  - useful if you are inspecting nested `info.total_token_usage`
- `thread/tokenUsage/updated`
  - best source for live board and API totals
- `turn/completed`
  - best used as end-of-turn state, not as an unconditional additive token event

## Why `total_token_usage` Is The Durable Choice

Codex itself consistently prefers cumulative totals when it needs durable state:

- the state extractor stores `info.total_token_usage.total_tokens`
- the exec event processor caches the last `total_token_usage` and uses that on turn completion

That is a strong signal for Symphony:

- use absolute totals as the main accounting surface
- ignore last/delta values for totals

## Symphony Persistence And Publication Contract

Symphony implements the following accounting contract:

- Accept only `thread/tokenUsage/updated.params.tokenUsage.total` as the primary live snapshot, with
  nested `info.total_token_usage` as the compatibility fallback.
- Normalize camel- and snake-case input, cached-input, output, and total token fields.
- Replace the stored snapshot only when its cumulative total is greater than or equal to the current
  high-water mark. Never add a delta to it.
- Ignore generic `usage`, `tokenUsage.last`, `last_token_usage`, and turn-completion usage.
- Count unique turn IDs while allowing one Codex thread to span multiple turns.
- Persist the live high-water mark and turn IDs in SQLite so runner crashes and orphan recovery retain
  them. Finalization copies the summary into the Git-backed `RunFinished` or `RunFailed` event and
  removes the transient telemetry row.
- Store `token_usage: null` when no authoritative cumulative total was observed. Zero is reserved for
  an explicit zero reported by Codex.

## Project Aggregation And Live Presentation

The board builds effective run statistics without adding a second durable accounting source:

- Terminal runs use canonical `run.stats`; active runs use the SQLite high-water mark and elapsed
  time since `started_at`, falling back to `claimed_at`.
- Task and project totals include every run, including archived tasks. Sum the authoritative input,
  cached-input, output, and total fields independently; cached input is informational and is never
  added to total again.
- Group project runs by exact model and then by stage, combining effort levels and applying the same
  live/canonical token completeness rules independently to every public group. The HTML stats view
  further groups each model/stage pair by effort without changing the public JSON shape. Preserve
  missing model, stage, or effort values in an Unknown bucket rather than dropping their accounting.
- Count Codex sessions as distinct nonempty thread IDs and active sessions as distinct nonempty
  thread IDs on active runs. Count completed tasks in a model or stage as distinct current or
  archived Done tasks with a run in that group that has a canonical start time or an effective
  session ID. These participation counts are intentionally non-additive across models and stages;
  model totals deduplicate across their nested stages, and the project total counts each Done task
  once.
- An aggregate with usage for every included run is `complete`. Some known and some missing runs is
  `partial`; no authoritative usage from any included run is `unavailable`. A collection with no
  runs is an exact zero. The UI renders partial totals as a lower bound (`≥`) and unavailable totals
  as `—`.
- Agent time is additive across runs and can exceed project age or service uptime when work overlaps.
  Project age begins at the earliest run claim. Service uptime, safe latest activity, and rate-limit
  snapshots are operational and reset when the orchestrator restarts.
- Rate limits are retained per local/SSH worker. Activity summaries expose bounded lifecycle labels,
  never raw prompts, reasoning, command output, workpads, or arbitrary protocol payloads.

`GET /api/v1/state` exposes project/runtime/task summaries under `stats`, plus model summaries with
nested stage summaries and project session/completion counts. Effort summaries are private to the
HTML stats view. Task responses retain canonical run
`stats` and add `effective_stats` plus optional safe `activity` for live display.

Completed, stopped, and failed runs expose duration, turn count, and cumulative usage through the
board/API. After termination, the run that created the PR is appended once to the managed PR body;
other runs are appended once to the existing GitHub comment identified by their workpad publication
marker. Runs without a published workpad remain local. Hidden per-run markers make GitHub retries
idempotent, and a successful destination/publication ID/timestamp is recorded canonically. Symphony
does not publish Codex thread IDs or pricing estimates.

## Implementation Checklist

- Prefer `thread/tokenUsage/updated.tokenUsage.total`
- Fallback to `info.total_token_usage`
- Ignore `last` for totals
- Key totals by `thread_id`
- Do not classify generic `usage` by field name alone
- Do not double-count turn-completed usage after live updates
- Persist terminal usage as `null` when no authoritative snapshot arrived
- Route creator stats to the PR body and other stats only to an existing published-workpad comment
