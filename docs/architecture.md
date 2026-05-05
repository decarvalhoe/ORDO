# Architecture

## Tiered CI strategy

The toolkit follows a two-tier CI model so agents get fast feedback on their
branches without letting slow merge-risk checks block every local iteration.

### Tier 1: fast checks on every push

Tier 1 belongs to the product repository, not to the orchestrator toolkit.
Typical examples are lint, type checks, and unit tests triggered by GitHub
Actions on every branch push.

Purpose:

- catch obvious breakage quickly
- keep agent feedback loops short
- avoid spending orchestrator time on branches that are already red

The toolkit does not run Tier 1 directly. It assumes the target repository
already exposes those checks through GitHub.

### Tier 2: merge-time orchestration checks

Tier 2 is where the toolkit operates. After agents finish local work, the
orchestrator integrates and merges sequentially instead of assuming that every
green branch is safe in aggregate.

Current flow:

1. `scripts/integrate_wave.sh` fetches the agent branches into the integration
   repo.
2. Each candidate branch is rebased onto the current default branch.
3. Optional project sanity gates run from the integration repo.
4. PRs are merged through `lib/pr_merge.sh`, which waits for CI and refuses to
   bypass a red or pending state.

Purpose:

- catch interactions between independently green branches
- reduce merge-order surprises on the default branch
- enforce the toolkit doctrine around CI gating and admin bypass

### ASCII flow

```text
agent branch push
    |
    v
Tier 1 checks on GitHub (fast)
    |
    +--> red  -> agent fixes branch
    |
    +--> green
            |
            v
      orchestrator wave
            |
            v
  integrate_wave.sh rebases branches
            |
            v
   project sanity command (optional)
            |
            v
     pr_merge.sh waits for CI
            |
     +------+------+
     |             |
     v             v
   fail          pass
     |             |
     v             v
 manual fix     merge to default branch
```

### Why this split matters

If Tier 1 and Tier 2 are collapsed into a single heavy pipeline, agents lose
iteration speed and the orchestrator becomes the bottleneck. If Tier 2 does not
exist, individually green branches can still collide when merged together.

This split keeps the inner loop fast while preserving a conservative merge gate
at orchestration time.
