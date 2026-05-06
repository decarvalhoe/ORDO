# 6sigma Autoupgrade Loop

The toolkit treats autofix/autoupgrade as an explicit operator feature, not an
ad-hoc habit.

## Goals

- Work with any orchestrator model and any agent pool shape.
- Avoid pane capture storms; use git and tmux metadata first.
- Redispatch failed CI to the owning agent, not to a hardcoded session.
- Keep retry caps, audit logs, and dry-run previews on every mutating path.
- Never merge while CI is red, pending, cancelled, or ambiguous.

## Main Command

```bash
bash scripts/sixsigma_autoupgrade.sh <project> [--dry-run]
```

The command:

1. Loads the project config.
2. Optionally snapshots the pool with `agent_pool_status.sh`.
3. Surfaces silent blockers with `pr_block_signals.sh`.
4. Reads open PRs against `DEFAULT_BRANCH`.
5. Counts failed and pending checks.
6. Maps `headRefName` to the agent whose workdir is currently on that branch.
7. Calls `ci_autofix.sh` for failed PRs until `SIXSIGMA_MAX_AUTOFIX_DISPATCHES`.

## Configuration

```bash
: "${SIXSIGMA_MAX_AUTOFIX_DISPATCHES:=4}"
: "${SIXSIGMA_INCLUDE_DRAFTS:=0}"
: "${SIXSIGMA_AGENT_CAN_PUSH:=1}"
: "${SIXSIGMA_RUN_POOL_SNAPSHOT:=1}"
: "${SIXSIGMA_RUN_PR_SIGNALS:=1}"
: "${CI_AUTOFIX_MAX_RETRIES:=3}"
```

Use `SIXSIGMA_AGENT_CAN_PUSH=0` when agents should commit locally and wait for
an orchestrator-controlled push. Use `1` when agents own their PR branch and
the workflow optimizes for freeing agents quickly.

## Merge Doctrine

Autoupgrade is intentionally separate from merge. A successful autofix only
creates another CI signal. Merge is still handled by `lib/pr_merge.sh`, which:

- waits for the full PR check rollup;
- refuses red or pending checks;
- disables any pre-existing auto-merge before refusing;
- uses immediate `gh pr merge --squash`, not deferred `--auto`;
- only uses admin fallback when the CI status is pass and the block is safe.

## Silent Blocker Signals

Run this independently whenever a PR appears stuck:

```bash
bash scripts/pr_block_signals.sh <project> --tsv
```

Signals include:

- `needs-rebase` when `origin/<DEFAULT_BRANCH>` is not an ancestor of the agent branch;
- `pr-behind` when GitHub reports `mergeStateStatus=BEHIND`;
- `merge-conflict` for dirty/conflicting mergeability;
- `review-required` and `changes-requested`;
- `ci-failed`, `ci-pending`, and `checks-missing`;
- `ci-pass` when all visible checks are complete and successful;
- `merge-ready` when GitHub reports a clean, mergeable, green PR with no blocker signal;
- `auto-merge-armed`;
- `merge-state-unknown` and `merge-state-unstable`.

## Operational Pattern

```bash
# 1. Snapshot the pool.
bash scripts/agent_pool_status.sh rbok --tsv

# 2. Preview self-improvement dispatches.
bash scripts/sixsigma_autoupgrade.sh rbok --dry-run

# 3. Run the loop.
bash scripts/sixsigma_autoupgrade.sh rbok

# 4. Poll PR checks, then merge only through gated merge tooling.
bash scripts/pr_merge_wave.sh rbok wave-label '^feat/issue-'
```
