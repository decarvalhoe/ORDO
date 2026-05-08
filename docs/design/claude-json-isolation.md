# `.claude.json` write storm and per-agent isolation — investigation

Investigation issue: [#412](https://github.com/RBOKproject/ORDO/issues/412).
Status: investigation only — this note documents findings and proposes a
direction. The actual remediation is filed as a follow-up P1 fix issue
(see [§ Follow-up](#follow-up)). No runtime behavior is changed by this
PR.

## Summary

The Claude Code CLI persists per-process state to a single host-level
file at `${HOME}/.claude.json`. On a fleet host running 12 panes against
a shared `${HOME}`, every pane's CLI process flushes its own view of the
file on most state changes, producing the observed write storm
(~22 writes/s, ~1950 writes/min cumulative across panes). The storm
causes:

1. **Parse-error races** — concurrent reads of partially-written JSON
   (3 captured in 2026-05-08 debug logs).
2. **Last-writer-wins on pane-local fields** — a pane's `lastSessionId`,
   `lastCost`, `lastModelUsage`, etc. are clobbered by any other pane's
   subsequent flush, so per-pane telemetry is unreliable.
3. **Disk I/O pressure** — a 187 KB JSON file rewritten ~30×/s on
   fan-out events generates measurable I/O on the tmux host.

The dominant per-pane write source is the `projects.<repo-path>` map.
Each project entry carries 21 `last*` fields (`lastSessionId`,
`lastSessionModified`, `lastCost`, `lastDuration`, `lastAPIDuration`,
`lastTotalInputTokens`, `lastTotalOutputTokens`, `lastModelUsage`,
`lastFpsAverage`, `lastFpsLow1Pct`, `lastLinesAdded`, `lastLinesRemoved`,
`lastToolDuration`, `lastTotalCacheCreationInputTokens`,
`lastTotalCacheReadInputTokens`, `lastTotalWebSearchRequests`,
`lastSessionFirstPrompt`, `lastSessionMetrics`, `lastGracefulShutdown`,
`lastHintSessionId`, `lastAPIDurationWithoutRetries`) which are written
on most API responses, tool invocations, and session lifecycle events.

## Field inventory

The CLI persists three classes of state in the same file. Field counts
and byte sizes below are sampled from a real `~/.claude.json` on a
fleet host (187 800 bytes, 67 project entries).

### Class A — truly global (must remain shared)

These are host-level identity, auth, billing, and feature-flag fields.
They change on coarse cadence (login, daily cron, version bump). Sharing
across panes is correct.

| Field | Bytes | Cadence |
| --- | ---: | --- |
| `oauthAccount` | 650 | login / token refresh |
| `userID` / `anonymousId` | ~110 | install |
| `cachedGrowthBookFeatures` | 16 803 | periodic refresh |
| `cachedExperimentFeatures` | 307 | periodic refresh |
| `passesEligibilityCache` | 471 | daily |
| `overageCreditGrantCache` | 339 | per billing event |
| `installMethod`, `migrationVersion`, `firstStartTime`, `numStartups` | <60 each | install / version migration |
| `theme`, `autoUpdates`, `hasCompletedOnboarding`, `tipsHistory` | <800 each | UX preferences |
| `lastReleaseNotesSeen`, `opus*MigrationComplete`, `sonnet*MigrationComplete` | <50 each | version migration |

Total Class A: ~22 KB. **Recommendation:** keep in `.claude.json`.

### Class B — project-shared (one writer at a time per project, multiple readers)

Per-project preferences and trust state. These are written occasionally
(first dispatch of a project, MCP enable/disable, trust-prompt accept),
but read by every pane that touches that repo.

| Field | Cadence |
| --- | --- |
| `projects.<repo>.allowedTools` | tool grant / revoke |
| `projects.<repo>.hasTrustDialogAccepted` | first project visit |
| `projects.<repo>.mcpServers` | MCP add/remove |
| `projects.<repo>.enabledMcpjsonServers` / `disabledMcpjsonServers` | MCP toggle |
| `projects.<repo>.exampleFiles` / `exampleFilesGeneratedAt` | one-time per project |
| `projects.<repo>.hasClaudeMdExternalIncludesApproved` | one-time per project |
| `projects.<repo>.projectOnboardingSeenCount` | bounded |

Total Class B: a few KB per project. **Recommendation:** keep in
`.claude.json` under `projects.<repo>.config`, but write via atomic
rename + advisory lock so concurrent panes do not race.

### Class C — pane-local (the write-storm source)

Per-session telemetry that changes on every API response and most tool
calls. There is no semantic reason for these to live in a host-shared
file: a different pane's metrics never inform another pane's decision.

| Field family (per project) | Cadence |
| --- | --- |
| `lastSessionId`, `lastSessionFirstPrompt`, `lastSessionModified`, `lastHintSessionId`, `lastGracefulShutdown` | once per session start / shutdown |
| `lastCost`, `lastDuration`, `lastAPIDuration`, `lastAPIDurationWithoutRetries`, `lastToolDuration` | every API turn |
| `lastTotalInputTokens`, `lastTotalOutputTokens`, `lastTotalCacheCreationInputTokens`, `lastTotalCacheReadInputTokens`, `lastTotalWebSearchRequests` | every API turn |
| `lastModelUsage`, `lastSessionMetrics` | every API turn |
| `lastLinesAdded`, `lastLinesRemoved` | every Edit / Write |
| `lastFpsAverage`, `lastFpsLow1Pct` | UI render tick |

Total Class C: ~1–2 KB per pane × number of recently-active projects.
This is where ~95 % of the write traffic comes from. **Recommendation:**
relocate to a per-pane file, e.g.
`${HOME}/.claude/sessions/<pane-id>/metrics.json`, written by exactly
one process and read by nobody else.

There is also a global Class C tail (`skillUsage`, `toolUsage`,
`promptQueueUseCount`, `numStartups`, etc., totalling <2 KB). These are
aggregates that benefit from being process-local **and** eventually
merged; the simplest model is "each pane appends to its own log; a
periodic merger folds into `.claude.json`".

## Write-storm diagnosis

Concrete causes, ranked by traffic volume:

1. **Class C fields flushed on every event** — the CLI writes the whole
   file on every state change rather than batching. Multiple changes
   per second per pane × 12 panes = the observed cadence.
2. **No advisory lock** — two panes flushing inside the same kernel
   tick can interleave. Even though writes appear atomic at the
   `write(2)` boundary, the CLI does not appear to use `flock` or
   `O_EXCL` rename, so a reader during a multi-write update can
   observe a truncated or partially-rewritten file → the captured
   `Unexpected end of JSON input` errors.
3. **No atomic-rename** — if the writer renamed a temp file over
   `.claude.json` (the standard `tmp + rename` pattern), readers
   would always see a complete file. The current code path appears to
   open the destination directly.
4. **No debounce** — there is no "coalesce writes within N ms" buffer,
   so a burst of API events produces a burst of full-file rewrites.
5. **Single file for unrelated state classes** — Class A and Class B
   are dragged along on every Class C flush, so a 1 KB metric update
   rewrites a 187 KB file.

The race in (2) is the parse-error driver. The pressure in (1)/(4)/(5)
is the throughput driver.

## Open-question answers

> Is `.claude.json` intended to be shared across CLI processes, or
> should each agent have its own?

The file *as currently structured* is a host-shared file by design for
Class A and Class B fields (auth, feature flags, project trust). But
Class C fields (per-session telemetry) are pane-local in semantics and
should live in a per-pane file. The fix is split, not full per-agent
duplication.

> Which fields are pane-local vs truly global?

See the Class A/B/C tables above.

> Can writes be batched/debounced (e.g., flush at most every 500ms)?

Yes, and this is the cheapest mitigation. A 500 ms debounce on Class C
writes alone would cut the observed 22 writes/s to ≤2 writes/s per pane
without changing the file format. This is an upstream-only change.

> Is there a file-locking story (`flock` / atomic-rename) we can adopt
> to eliminate the parse-error race?

Yes, and this is independent of the storm. Adopting `tmp + rename` for
writes (so readers always see a complete file) and an `flock`-guarded
read-modify-write loop is the standard recipe and would eliminate the
parse-error race even if write frequency stayed the same. This is an
upstream-only change too.

> Would moving to SQLite remove the storm entirely?

Probably yes for Class C — SQLite's WAL mode is built for this access
pattern. But it adds a runtime dependency and complicates downstream
tooling that currently treats `.claude.json` as a plain JSON file. A
simpler path that achieves the same goal:

- **Move Class C out** to per-pane JSON files (no SQLite needed).
- **Keep Class A / B in `.claude.json`** behind atomic-rename + lock.

This split removes the high-frequency writes from the shared file, so
the shared file's contention goes from ~30/s to <1/s and SQLite's
WAL-mode benefit is no longer load-bearing. The decision tree is in
[§ Recommendation](#recommendation).

## Recommendation

Two-phase remediation, ordered by effort × impact:

### Phase 1 — eliminate parse-error race (low effort, full payoff)

- Switch the writer to `tmp + rename` so readers always see a complete
  file.
- Wrap the read-modify-write cycle in `flock` (advisory exclusive on
  the destination path).

This is independent of any field-split and eliminates the parse-error
race even at the current write rate. **This is a Claude Code CLI
upstream change**, not an ORDO change. ORDO can file a focused bug
report against the CLI with the captured evidence.

### Phase 2 — reduce write rate (medium effort, big payoff)

- Move Class C fields to per-pane files (one writer, no contention).
- Debounce Class C writes to ≤2/s per pane.
- Keep Class A / B in `.claude.json` with the Phase-1 lock + rename.

This is also a CLI upstream change. ORDO's role is to:

- Specify the field split (Class A/B/C tables above).
- Provide a migration plan that preserves existing telemetry.

### What ORDO can ship without waiting on upstream

While the upstream fix is in flight, ORDO can:

1. **Detect the storm in fleet diagnostics**: `lib/host_forensics.sh`
   already probes host load; add a `.claude.json` write-rate signal so
   operators know when the storm is active. Counter source:
   `stat -c %Y` polled at 1 Hz; alarm when delta > N writes per N
   seconds.
2. **Surface parse errors in dispatch**: when a dispatch attempt
   observes a JSON parse failure on `.claude.json`, retry once with
   100 ms backoff (the CLI already does this internally; ORDO should
   too on its own consumers) and audit the event so the rate is
   visible.
3. **Pin per-pane HOME (long-shot, requires CLI cooperation)**: if the
   CLI honours an env var like `CLAUDE_HOME`, ORDO can give each pane
   a distinct path. As of 2026-05-08, the CLI does not document such
   an override; the dispatcher will track upstream support and adopt
   it once available.

None of (1)–(3) require upstream cooperation; they are pure
observability + retry safeguards. (3) is gated on the upstream
exposing an override.

## Follow-up

A P1 fix issue should be filed with the following body. ORDO does not
own the fix surface (the CLI does), but the issue keeps the
remediation tracked alongside the investigation.

```
## Title
fix: split per-pane telemetry out of .claude.json + atomic-rename writes

## Background
Per investigation #412, ~95% of .claude.json write traffic is per-pane
telemetry (Class C in docs/design/claude-json-isolation.md) that has no
business living in a host-shared JSON file. The remaining classes
(global identity/auth, project-shared trust + MCP config) are
correctly shared but currently subject to a parse-error race because
writes are not atomic.

## Required behavior
- Writer flushes via tmp + rename (atomic from a reader's POV).
- Writer holds advisory exclusive flock on the destination across the
  read-modify-write cycle.
- Class C fields (`projects.*.last*`) move to per-pane files at
  `${HOME}/.claude/sessions/<pane-id>/metrics.json`; .claude.json no
  longer carries them.
- Class C writes debounced to ≤2/s per pane.
- Migration: on first startup after upgrade, copy existing
  `projects.*.last*` into the per-pane file for the active session and
  drop them from .claude.json.

## Acceptance criteria
- Concurrent reads during writes never observe partial JSON
  (regression: open 12 readers + 12 writers for 60s; zero parse
  errors).
- Per-pane metrics survive other panes' writes (regression: pane A
  writes M_A; pane B writes M_B; both files retain their own values).
- Aggregate write rate to .claude.json drops below 2/s on a 12-pane
  fleet host.

## Owner
Claude Code CLI (upstream).
```

ORDO observability work (the items in [§ What ORDO can ship without
waiting on upstream](#what-ordo-can-ship-without-waiting-on-upstream))
is filed separately so that PR can land without dependency on the
upstream fix.

## Related

- #327 — orchestrator stall investigation (partially attributable to
  parse-error retries).
- #339 — dispatch fan-out timing (write storm peaks coincide with
  fan-out windows).
- Captured 2026-05-08 audit excerpts: `~/.claude/debug/` parse-error
  log lines from `rbok-codex` and `rbok-cursor`.
