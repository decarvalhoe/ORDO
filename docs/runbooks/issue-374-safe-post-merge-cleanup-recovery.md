# Issue #374 — safe post-merge cleanup recovery before readiness escalation

## Problem

When the readiness recursion stalls and the orchestrator's only blocker is
that clean workdirs are still parked on already-merged feature branches,
escalating to operator intervention is wasteful: the post-merge cleanup
path was specifically designed to remediate exactly that state, and it
was not being attempted. Issue #374 mandates that the orchestrator MUST
attempt audited recovery via the safe cleanup path BEFORE escalating to
`operator_intervention_required`, and MUST distinguish in audit which of
the three states applies to each candidate:

- `safe_post_merge_cleanup_attempted` — gate evaluation began;
- `safe_post_merge_cleanup_applied` — gate held, live cleanup ran;
- `operator_intervention_required` — gate refused, escalate.

## Required normal behavior

For every agent → PR assignment in the portfolio's `assignments.json`,
the orchestrator must run the four-condition gate:

1. The target PR is in state `MERGED` (verified via
   `gh pr view --json state,mergedAt`).
2. The agent's workdir dirty count is zero
   (`git status --porcelain | wc -l == 0`).
3. No in-flight git operation markers exist in the workdir's `.git/`:
   - `MERGE_HEAD`
   - `REBASE_HEAD`
   - `CHERRY_PICK_HEAD`
   - `BISECT_LOG`
   - `rebase-merge/`
   - `rebase-apply/`
4. `scripts/post_merge_cleanup.sh <project-config> <pr> --json --dry-run`
   contains a record for this agent with `action=cleanup` and
   `status=ok`.

When all four conditions hold and `--apply` is set, the recovery script
runs the live `post_merge_cleanup.sh` for that PR. After all candidates
across all projects in the portfolio have been processed, if at least
one cleanup was applied and `--no-session-start` is not set, the script
runs `scripts/portfolio_session_start.sh <portfolio-config> --apply
--json` so deterministic safe remediations (default-branch
fast-forward, identity setup) land in the same audited window.

Any candidate where one of the four conditions fails is recorded as
`operator_intervention_required` with a structured `block_reason`
(`pr_not_merged`, `not_git_repo`, `dirty_worktree`,
`operation_marker_present`, `dry_run_blocked`, `live_cleanup_failed`).
Dirty worktrees and worktrees with operation markers are NEVER mutated;
business and out-of-scope projects are NEVER touched (the recovery
script ONLY iterates the portfolio config it was passed).

## Operating procedure

When the orchestrator's continuation guard reports
`waiting_on_post_merge_cleanup` or `clean_workdirs_on_merged_branches`,
run:

```sh
bash scripts/safe_post_merge_cleanup_recovery.sh \
  /etc/orch/portfolio.config.sh --json --dry-run
```

The dry-run prints the four-condition gate result for every agent. If
the report shows ANY candidate with `operator_intervention_required`,
investigate that candidate before applying.

If the dry-run is clean for every candidate the orchestrator wants to
recover, run the live apply:

```sh
bash scripts/safe_post_merge_cleanup_recovery.sh \
  /etc/orch/portfolio.config.sh --json --apply
```

Exit codes:

- `0` — every candidate either applied successfully OR was non-applicable
  (PR not merged, no assignment) AND no candidate required operator
  intervention. Includes the `decision=no_candidates` case.
- `10` — at least one candidate required `operator_intervention_required`.
  The orchestrator must surface those candidates and stop the recursion
  for them.

## Audit signal contract

Each candidate emits at least one of the following audit signal classes
(streamed via `lib/audit_log.sh`):

| Signal                                          | When                                              |
|-------------------------------------------------|---------------------------------------------------|
| `SAFE_POST_MERGE_CLEANUP_ATTEMPTED`             | Gate evaluation began for this candidate.          |
| `SAFE_POST_MERGE_CLEANUP_DRY_RUN_OK`            | Dry-run mode; gate held; live cleanup not run yet. |
| `SAFE_POST_MERGE_CLEANUP_APPLIED`               | Apply mode; gate held; live cleanup ran OK.        |
| `SAFE_POST_MERGE_CLEANUP_SESSION_START_APPLIED` | Apply mode; portfolio_session_start --apply ran OK.|
| `SAFE_POST_MERGE_CLEANUP_SKIP`                  | PR not merged; no further evaluation.              |
| `OPERATOR_INTERVENTION_REQUIRED`                | One of the four gate conditions refused.           |

The structured JSON emitted on stdout (`--json` mode) contains:

```json
{
  "decision": "safe_post_merge_cleanup_applied | operator_intervention_required | safe_post_merge_cleanup_attempted | no_candidates",
  "apply": true,
  "candidates": [
    {
      "project": "<alias>",
      "agent": "<agent>",
      "pr": 42,
      "workdir": "/abs/path",
      "action": "safe_post_merge_cleanup_applied | safe_post_merge_cleanup_attempted | operator_intervention_required | skip",
      "applied": true,
      "block_reason": "pr_not_merged | dirty_worktree | operation_marker_present | dry_run_blocked | live_cleanup_failed | not_git_repo | null",
      "detail": "<one-line>"
    }
  ],
  "counts": {
    "attempted": 3,
    "applied": 1,
    "operator_intervention_required": 1
  },
  "session_start": { "applied": true }
}
```

## Hard limits

- Dirty worktrees are NEVER mutated; they are reported under
  `operator_intervention_required` with `block_reason=dirty_worktree`.
- Worktrees with operation markers (`rebase-merge/`, `MERGE_HEAD`, …) are
  NEVER mutated; they are reported with
  `block_reason=operation_marker_present` because attempting cleanup
  there could destroy mid-flight work.
- Business and out-of-scope projects are NEVER touched; the recovery
  script ONLY iterates the portfolio config it was passed.
- The script never invokes `--force`, `--force-with-lease`, `git reset
  --hard`, or any destructive git operation directly. All mutation
  happens through `scripts/post_merge_cleanup.sh`, which itself respects
  the per-PR clean-workdir contract.

## Regression coverage

`tests/test_safe_post_merge_cleanup_recovery.sh` builds a tiny portfolio
with three agents — clean-merged, dirty-merged, open — and asserts:

1. Dry-run mode never invokes `portfolio_session_start --apply`.
2. The clean-merged agent's record shows
   `safe_post_merge_cleanup_attempted` (dry-run) → `safe_post_merge_cleanup_applied`
   (apply) and the workdir actually moved to the default branch with
   the remote's latest content present.
3. The dirty-merged agent's record stays
   `operator_intervention_required` with `block_reason=dirty_worktree`.
4. The open agent's record is `skip` with `block_reason=pr_not_merged`.
5. Empty assignments yield `decision=no_candidates`, exit 0, and no
   `portfolio_session_start --apply` invocation.

## Resolution

Closed: 2026-05-08 via PR #398 (fix(#374): standardize safe post-merge
cleanup recovery before readiness escalation). The four-condition gate
and the three-state audit (`safe_post_merge_cleanup_attempted` →
`safe_post_merge_cleanup_applied` → `operator_intervention_required`)
are wired into the readiness recursion. This runbook is retained as
durable evidence per `docs/orchestrator-injected-rules.md` rule 9.
