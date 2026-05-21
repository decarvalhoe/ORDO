# Dispatch reference

Operator-facing reference for the dispatch lifecycle and the
data files it produces. See
[`dispatch-planning.md`](dispatch-planning.md) for the candidate-ranking
walkthrough and [`multi-product-portfolio.md`](multi-product-portfolio.md)
for cross-project posture.

## In-flight scope-claim ledger

`scripts/dispatch_ticket.sh` writes a per-agent claim row to
`<state_dir>/assignments_scope_claims.json` when the dispatch's
assignment is promoted (audit signature
`DISPATCH SCOPE_CLAIM_WRITTEN`). The row is keyed by agent and
captures the resolved scope parsed out of the rendered brief.

```json
{
  "agent-001": {
    "agent": "agent-001",
    "ticket": "721",
    "branch": "feat/issue-721",
    "scope_files": [
      "scripts/dispatch_ticket.sh",
      "scripts/dispatch_plan.sh"
    ],
    "forbidden_files": [
      "scripts/portfolio_dispatch.sh"
    ],
    "claimed_at": "2026-05-20T12:00:00Z"
  }
}
```

The row is released by `scripts/post_merge_cleanup.sh` after the
matching PR merges (audit signature
`POST_MERGE_CLEANUP scope_claim_released`). Stale rows therefore
mean either an in-flight PR or a cleanup that has not run yet.

### Downstream consumers

- **`scripts/dispatch_plan.sh --ready-only`** emits a
  `conflict_with` field per JSON candidate listing the in-flight
  ticket numbers whose claimed scope intersects the candidate's
  expected scope. The heuristic extracts path-like tokens
  (`<dir>/<file>.<ext>`) from the candidate's title and body and
  intersects them with the union of in-flight `scope_files`.
  `["unknown"]` indicates the heuristic abstained because no path
  token could be derived from the candidate; `[]` means either
  the ledger was empty or no overlap was found.
- **`scripts/brief_agents.sh`** consults the ledger before
  rendering and prepends any intersecting in-flight `scope_files`
  to the rendered brief's `Fichiers interdits` block (audit
  signature `BRIEF SCOPE_CLAIM_FORBIDDEN_INJECTED`). Pass
  `--ignore-scope-claims` (or `ORCH_BRIEF_IGNORE_SCOPE_CLAIMS=1`)
  to opt a single brief out; the override is recorded as
  `BRIEF SCOPE_CLAIM_IGNORED`.

### Manual inspection

```bash
PROJECT=ordo jq . "$(state_dir)/assignments_scope_claims.json"
```

`state_dir` resolves to `${XDG_DATA_HOME:-/root/.local/share}/orch-state/$PROJECT`.

### Failure-soft contract

The ledger helpers live in `lib/dispatch_capacity.sh`. Sanitized
test sandboxes that copy a subset of `lib/` may omit the file; in
that case every wired script falls back to its pre-#721
behavior (`promote_dispatch_assignment` still records the
assignment, the planner emits no `conflict_with` field, the brief
renderer leaves `forbidden_files` untouched). The fail-soft path
keeps legacy fixtures and emergency-mode bypasses bisect-safe.

## Parked decisions ledger (rbok#725)

### Behavioral contract

The orchestrator MUST NOT pause its cycle when an arbitration item is
surfaced. The authoritative source for this rule is the durable feedback
memory `feedback_pending_arbitration_no_block.md` (filed 2026-05-16),
captured after fleet-000 stopped cycling on PR #722 instead of moving on
to the next priority. The codified rule:

- A `needs-user-auth` or `operator_intervention_required` outcome is a
  fire-and-forget signal, not a session-stop signal.
- The orchestrator surfaces the item once (with options), records it in
  the parked-decisions ledger, and continues cycling on the next ready
  priority.
- The cycle wakeup loop pauses only when the genuine queue is exhausted,
  never because an item is parked.

### Storage

`<state_dir>/parked_decisions.json` is a JSON array of objects, atomically
rewritten under `flock`. `state_dir` resolves to
`${XDG_DATA_HOME:-/root/.local/share}/orch-state/$PROJECT`.

```json
[
  {
    "id":         "needs-user-auth:dispatch:agent-001:#722:external-pr-mutations",
    "kind":       "needs_user_auth",
    "source":     "dispatch_ticket",
    "agent":      "agent-001",
    "target":     "#722",
    "summary":    "external-pr-mutations unauthorized (unmet=issue_assignees)",
    "options":    "pass --external-pr-mutations=issue_assignees, ...",
    "created_at": "2026-05-21T12:00:00Z",
    "updated_at": "2026-05-21T12:00:00Z"
  }
]
```

Idempotency key is `id`: re-adding the same id refreshes `summary`,
`options`, and `updated_at`, but preserves `created_at`. That preserves
the original "first observed" timestamp and lets `ORCH_PARKED_REMINDER_TTL`
suppress re-reminders within a quiet window.

### Producers

- **`scripts/dispatch_ticket.sh`** appends an entry whenever the
  `external-pr-mutations` declaration on a brief is not authorized by
  `--external-pr-mutations` / `ORCH_EXTERNAL_PR_MUTATIONS`. The existing
  refusal exit code (`ORCH_EXTERNAL_PR_MUTATION_REFUSED_EXIT_CODE`,
  default 80) and the `DISPATCH REFUSED reason=external_pr_mutations_unauthorized`
  audit line are unchanged; a paired `DISPATCH NEEDS_USER_AUTH` audit
  line is emitted alongside the ledger write.
- **`scripts/post_merge_cleanup.sh`** appends an entry every time
  `add_record` records a `status=blocked` candidate (dirty worktree,
  switch/pull failure, closure refused, etc.) — these are the
  operator-intervention-required classifications. Re-reminding is gated
  by `ORCH_PARKED_REMINDER_TTL` (default `0` = immediate; non-zero =
  suppress within that many seconds of the original `created_at`).

Producers fail soft when `lib/parked_decisions.sh` is not present
(sanitized test sandboxes that copy a subset of `lib/`).

### Operator clear/resolve path

`scripts/parked_decisions.sh` is the operator CLI:

```bash
# Inspect what is currently parked (TSV).
scripts/parked_decisions.sh list

# Trail a status report with Markdown bullets.
scripts/parked_decisions.sh reminders

# Resolve a single parked item.
scripts/parked_decisions.sh clear --id "needs-user-auth:dispatch:agent-001:#722:external-pr-mutations"

# Manually park an arbitration (operator helper).
scripts/parked_decisions.sh add \
  --id "<stable-id>" --kind needs_user_auth --source operator \
  --agent agent-001 --target "#722" --summary "..." --options "..."
```

The CLI is a thin wrapper around `lib/parked_decisions.sh`; both share
the `PARKED_DECISIONS_FILE` env override, which test sandboxes use to
redirect the ledger to a tmp path.

### Integration with status reports

A compact cycle status report ends with a "Parked decisions" section
populated by `scripts/parked_decisions.sh reminders`. Empty output means
no parked items — the section is omitted. Non-empty output means the
operator has open arbitrations to resolve, but the cycle continues
regardless.
