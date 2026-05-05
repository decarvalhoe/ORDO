# orchestrator-toolkit performance baseline

Date: 2026-05-05  
Repo: `RBOKproject/orchestrator-toolkit`  
Main SHA: `3543184`

## Purpose

This report closes the "baseline perf" deliverable from EPIC `#1`.

Important limitation: the toolkit was rebuilt and improved during the same
session on 2026-05-05, so a true pre-sprint historical baseline is not
recoverable from the repository alone. This document is therefore a
reconstructed operational baseline taken immediately after Phase 0-3 delivery.

It is still useful because it fixes:

- the first stable measurement point for future comparison
- the current GitHub and CI health of the toolkit itself
- which target metrics are already measurable and which still require runtime
  instrumentation

## Data sources

- GitHub merged PR history for `RBOKproject/orchestrator-toolkit`
- GitHub Actions runs on `main`
- current repository verification surface
- current open issue / open PR state

## Delivery snapshot

- Open PRs: `0`
- Open issues: `1`
- Remaining open issue: EPIC `#1`
- Merged improvement PRs in this campaign: `12`

Merged PR set included:

- Phase 0: `#6`, `#7`, `#8`, `#9`
- Phase 1-3: `#17` through `#24`

## Measured baseline

| Metric | Value on 2026-05-05 | Notes |
|---|---:|---|
| Merged improvement PRs | 12 | Full delivered campaign currently visible on GitHub |
| PR lead time median | 5.86 min | Based on merged PRs `#6-9`, `#17-24` |
| PR lead time min | 0.77 min | Fastest merged change in the observed set |
| PR lead time max | 36.27 min | Longest merged change in the observed set |
| CI success rate on `main` | 100% | 6/6 recent completed runs succeeded |
| Average CI duration on `main` | 0.88 min | Recent completed runs on `main` |
| Test files in repo | 22 | 6 bats, 15 shell regressions, 1 helper file |
| Open PR count | 0 | No queued repo work after Phase 3 |
| Open issue count | 1 | EPIC remains open for meta follow-up |

## Success-metric mapping

The EPIC tracks five outcome metrics. Current status:

| EPIC metric | Baseline status | Current value | Source |
|---|---|---:|---|
| Recover events / day | Not retroactively measurable | N/A | Future: `/var/log/orch/*.log` or OTEL `event_type=RECOVER` |
| CI green on default branch | Measurable | 100% recent success on toolkit `main` | GitHub Actions |
| Lead time PR (median) | Measurable | 5.86 min | GitHub merged PR timestamps |
| Idle ratio | Not retroactively measurable | N/A | Future: smart poll telemetry + assignment state |
| Inter-agent conflicts | Not historically measurable in repo | N/A | Future: worktree rollout + audit log / OTEL |

## Verification surface baseline

The toolkit now has a stable local and CI verification contract:

- `bash scripts/run_shellcheck.sh`
- `bash scripts/run_shell_tests.sh`
- `bash scripts/run_bats.sh`

Coverage surface at this checkpoint:

- shell runners and orchestration flows
- audit log and state persistence
- CI autofix loop
- prompt validation
- quota autodetect
- rollback recovery
- OTEL export
- worktree isolation helpers

This matters because future performance comparisons should only be made against
a toolkit revision that already has a stable safety net. `3543184` is the first
commit where that condition is clearly true.

## Interpretation

What this baseline says:

- the repo is currently clean from a delivery-flow standpoint
- the toolkit CI path is healthy and fast
- PR throughput for toolkit work itself is already short
- the observability needed for the remaining outcome metrics now exists or is
  partially in place

What it does not say:

- whether RBOK production orchestration already improved by the target
  percentages
- whether recover/day, idle ratio, or collision rate actually moved yet
- whether Phase 4 features have enough ROI to justify implementation

## Next measurement steps

To make the remaining EPIC metrics real instead of aspirational:

1. Enable OTEL export on one live orchestrator instance.
2. Keep `USE_WORKTREES=0` by default, then pilot `USE_WORKTREES=1` on one
   project.
3. Collect 3-7 days of runtime audit data for:
   - `RECOVER`
   - `DISPATCH`
   - `POLL`
   - `CLI_SWAP`
4. Produce `reports/perf-sprint-4-summary.md` with real runtime deltas.
5. Decide explicit go/no-go on Phase 4 after that runtime sample exists.

## Recommendation

Do not close EPIC `#1` yet.

Close condition should be:

- this baseline report committed
- one runtime follow-up report committed from live data
- explicit Phase 4 decision documented
