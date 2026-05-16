# Dispatch (#721)

This page documents the three dispatch-side improvements landed under
issue [#721](https://github.com/RBOKproject/ORDO/issues/721): the
scope-claim ledger, the `--auto-recover` flag on `dispatch_ticket`, and
the `portfolio_dispatch.sh` cross-project planner.

The pre-existing defensive guards on `dispatch_ticket.sh` and
`dispatch_plan.sh` (pinned-base freshness, context-mismatch refusal,
scope-classification preflight, local-assignment exclusion, etc.) are
unchanged.

## Scope-claim ledger

`$(state_dir)/scope_claims.json` records the files an in-flight ticket
is allowed to mutate, keyed by ticket number:

```
{
  "<ticket>": {
    "agent":       "<label>",
    "scope_files": ["scripts/foo.sh", "lib/foo.sh", ...],
    "created_at":  "<iso8601>"
  }
}
```

**Lifecycle.**
- `scripts/dispatch_ticket.sh` writes the claim from the brief's
  `Fichiers autorises` block immediately after the assignment is
  promoted (`promote_dispatch_assignment` →
  `dispatch_capacity_scope_claims_record`). Empty / audit-only briefs
  record no claim.
- `scripts/post_merge_cleanup.sh` releases the claim when it clears the
  matching assignment row after a PR merge
  (`dispatch_capacity_scope_claims_release_by_ticket`).

**Consumers.**
- `scripts/dispatch_plan.sh` adds a `conflict-with:#<ticket>` signal
  (plus the umbrella `scope-claim-conflict` signal) and a
  `conflict_with: [<ticket>...]` JSON field to every open issue whose
  declared `scope_files` overlap an active claim. The JSON contract is
  additive — existing consumers see no behaviour change.
- `scripts/brief_agents.sh` pre-injects the active claim files
  (excluding the current ticket's own claim) into the brief's
  `forbidden_files` block. Set `ORCH_BRIEF_INJECT_SCOPE_CLAIMS=0` to
  opt out (mostly useful for fixtures that pin the rendered block).

The helpers live in `lib/dispatch_capacity.sh`
(`dispatch_capacity_scope_claims_*`).

## `dispatch_ticket --auto-recover`

Default-off flag that opportunistically recovers from two transient
failures without changing the canonical exit-code contract when the
flag is absent.

- **Exit 81 (`stale_base_refresh`).** When the brief's pinned base SHA
  is stale, the assigned worktree is clean, and `HEAD` is an ancestor
  of `origin/<default>`, the helper rewrites the pinned SHA in place
  (`accepted immutable base: ... at <new>`), emits
  `DISPATCH AUTO_RECOVER STALE_BASE old=<sha> new=<sha>`, and lets the
  dispatch continue with the refreshed brief. Dirty / committed
  worktrees still fall through to the canonical refusal (exit 82) so
  the operator reconciles by hand.
- **Exit 76 (`context_mismatch`).** When the post-dispatch context
  proof fails, the helper sends `cd <workdir>` Enter to the agent pane
  via tmux, audits `DISPATCH AUTO_RECOVER CONTEXT_MISMATCH`, and
  re-runs the context proof once. A success continues the dispatch
  (audit row: `DISPATCH AUTO_RECOVER CONTEXT_PROOF_OK`); a second
  failure falls through to the canonical exit 76 with a
  `CONTEXT_MISMATCH_RETRY_FAILED` audit row.

`ORCH_DISPATCH_AUTO_RECOVER_DEPTH` caps the retry budget at one tmux
`cd` per dispatch so the helper cannot loop. `--auto-recover` is
inheritable via `ORCH_DISPATCH_AUTO_RECOVER=1`.

## `portfolio_dispatch.sh`

```
scripts/portfolio_dispatch.sh <portfolio-config> <wave-id>
  [--apply] [--dry-run] [--limit N] [--matrix-out PATH] [--project P]
  [--json]
```

Walks every project in a portfolio config, asks each project's
`dispatch_plan` for ready candidates, drops rows that are
`local_assigned` or carry a `conflict_with` entry from the scope-claim
ledger, caps the per-project rows at `MAX_CONCURRENT_DISPATCHES` (per
project config, or `PORTFOLIO_MAX_CONCURRENT_DISPATCHES` override in
the portfolio config), and assembles a TSV matrix that
`scripts/dispatch_wave.sh` can consume under a single wave id.

By default the helper prints the plan and writes the matrix file
without dispatching; `--apply` hands the assembled matrix to
`dispatch_wave` so every project's dispatch shares one wave ledger.
See [docs/portfolio.md](./portfolio.md) for the portfolio-config
fields the planner consumes.
