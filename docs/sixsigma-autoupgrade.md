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
3. Reads open PRs against `DEFAULT_BRANCH`.
4. Counts failed and pending checks.
5. Maps `headRefName` to the agent whose workdir is currently on that branch.
6. Calls `ci_autofix.sh` for failed PRs until `SIXSIGMA_MAX_AUTOFIX_DISPATCHES`.

## Configuration

```bash
: "${SIXSIGMA_MAX_AUTOFIX_DISPATCHES:=4}"
: "${SIXSIGMA_INCLUDE_DRAFTS:=0}"
: "${SIXSIGMA_AGENT_CAN_PUSH:=1}"
: "${SIXSIGMA_RUN_POOL_SNAPSHOT:=1}"
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
