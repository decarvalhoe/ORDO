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
