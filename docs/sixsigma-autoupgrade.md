# 6sigma Autoupgrade Loop

The toolkit treats autofix/autoupgrade as an explicit operator feature, not an
ad-hoc habit.

## Architecture Level

Six Sigma Auto Upgrade is **Level 1** of the ORDO Six Sigma architecture: it
is part of the ORDO standard and is mandatory cycle behavior. Every
operator-driven ORDO cycle is expected to dry-run or run this loop as
continuous-improvement evidence. There is no profile knob to disable Level 1
per project; profiles can only tune the existing knobs in the Configuration
section below.

Level 1 produces operational telemetry (autofix dispatches, optimizer findings,
silent blocker signals) and never produces an approval, release, waiver,
validation, or phase-completion claim. Approval-grade evidence belongs to the
controlled validation track in [docs/validation/](validation/), not to this
loop.

The opt-in **Level 2** project DMAIC module — auditable Define / Measure /
Analyze / Improve / Control records that a single project can choose to
maintain — is documented separately in
[docs/sixsigma/README.md](sixsigma/README.md). Level 2 is disabled by default
and is activated per project; it must never be confused with Level 1.

## Goals

- Work with any orchestrator model and any agent pool shape.
- Avoid pane capture storms; use git and tmux metadata first.
- Redispatch failed CI to the owning agent, not to a hardcoded session.
- Continuously audit configured check workflows for throughput and resilience
  regressions. The current shell adapter includes GitHub Actions support.
- Scaffold a safe baseline CI for nascent projects before agent scale begins.
- Detect when a product is only waiting on external gates so clean agents can
  be reassigned to another product instead of idling.
- Keep retry caps, audit logs, and dry-run previews on every mutating path.
- Never merge while CI is red, pending, cancelled, or ambiguous.
- Inject continuous-improvement discipline into orchestrators: every operational
  finding must either be fixed and validated immediately or captured as a
  durable ORDO opportunity with impact, detection signal, safe remediation,
  validation/POC plan, and priority.

See `docs/orchestrator-injected-rules.md` for the full orchestrator rule set.

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
8. Runs `gh_actions_optimize.sh --audit` to surface workflow bottlenecks such
   as duplicate PR/push runs, missing concurrency, missing permissions, and
   full backend suites on feature-branch pushes.

## Configuration

```bash
: "${SIXSIGMA_MAX_AUTOFIX_DISPATCHES:=4}"
: "${SIXSIGMA_INCLUDE_DRAFTS:=0}"
: "${SIXSIGMA_AGENT_CAN_PUSH:=1}"
: "${SIXSIGMA_RUN_POOL_SNAPSHOT:=1}"
: "${SIXSIGMA_RUN_PR_SIGNALS:=1}"
: "${SIXSIGMA_RUN_GHA_OPTIMIZER:=1}"
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

## GitHub Actions Continuous Optimization

`scripts/gh_actions_optimize.sh` is the 6sigma lens for GitHub Actions process
quality. It works in two modes:

```bash
# Existing project: report CI process smells without mutating files.
bash scripts/gh_actions_optimize.sh <project-config> --audit

# Nascent project: create a conservative baseline workflow.
bash scripts/gh_actions_optimize.sh <project-config> --scaffold
```

Audit mode emits TSV rows:

```text
severity  code  file  message
```

Current findings include:

- `gha-pr-push-duplicate-risk`: a workflow listens to both `pull_request` and
  feature/fix `push`, which can create duplicate checks for one PR branch.
- `gha-full-tests-on-any-push`: coverage/full pytest appears keyed to generic
  `push`; distinguish default-branch pushes from feature-branch pushes.
- `gha-actions-read-missing`: a workflow calls the Actions API through `gh api`
  without granting `GITHUB_TOKEN` `actions: read`.
- `gha-missing-concurrency` and `gha-missing-permissions`: workflow guardrails
  are absent or implicit.
- `gha-no-path-filter`, `gha-python-cache-missing`, and
  `gha-pytest-xdist-missing`: likely throughput improvements.

Scaffold mode creates `.github/workflows/ci.yml` only when no CI exists, unless
`GHA_OPT_OVERWRITE=1` is set. The generated baseline uses explicit
permissions, concurrency, path filters, dependency caches, parallel pytest, and
separate PR/default-branch behavior. It intentionally avoids feature-branch
`push` triggers so a PR does not get both a fast PR run and a full push run.

Reference anchors:

- GitHub Actions supports path filters, explicit permissions, concurrency, and
  reusable workflows in first-party workflow syntax.
- pytest supports targeted selection through node ids, `-k`, and markers.
- `pytest-xdist` distributes tests across CPUs with `pytest -n auto`.
- `pytest-testmon` demonstrates dependency-based impacted-test selection using
  Coverage.py data.

## Operational Pattern

```bash
# 1. Snapshot the pool.
bash scripts/agent_pool_status.sh <project-config> --tsv

# 2. Preview self-improvement dispatches.
bash scripts/sixsigma_autoupgrade.sh <project-config> --dry-run

# 3. Run the loop.
bash scripts/sixsigma_autoupgrade.sh <project-config>

# 4. Poll PR checks, then merge only through gated merge tooling.
bash scripts/pr_merge_wave.sh <project-config> wave-label '^feat/issue-'
```

## Portfolio Rebalancing

When the blocker is not code work but an external wait, use the portfolio layer:

```bash
bash scripts/portfolio_status.sh <portfolio-config> --tsv
bash scripts/agent_product_switch.sh <portfolio-config> product-a planner product-b --target-agent planner --dry-run
```

`portfolio_status.sh` emits `external_wait` plus `rebalance_recommended` when a
project has pending checks/gates and clean capacity. `agent_product_switch.sh`
then parks a free or PR-submitted branch and respawns the same physical pane in
the target product repo.
