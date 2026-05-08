# Multi-Product Portfolios

ORDO can coordinate one physical agent pool across several product repositories.
This is useful when one product is waiting on external gates such as CI,
deployment health, reviews, or merge state while clean agents can work
elsewhere.

The feature is product-neutral. Product names, repository identifiers, host
paths, and agent labels in this document are placeholders.

## Portfolio Config

Create a portfolio config that references independent project configs:

```bash
PORTFOLIO_NAME="product-suite"
PORTFOLIO_PROJECTS=(
  "product-a|/profiles/product-a.config.sh"
  "product-b|/profiles/product-b.config.sh"
  "product-c|/profiles/product-c.config.sh"
)

PORTFOLIO_PRIORITIES=(
  "product-a=100"
  "product-b=80"
  "product-c=60"
)

# Optional: verify every physical agent has a clone for every product.
PORTFOLIO_ENSURE_AGENT_MATRIX=1
PORTFOLIO_FLEET_AGENTS=(
  "planner|terminal-a:0.0"
  "builder|terminal-b:0.0"
  "reviewer|terminal-c:0.0"
)
```

The right side of each `PORTFOLIO_PROJECTS` entry can be any config accepted by
ORDO: a path, a local alias, or an external profile loader.

Priorities are explicit by default. ORDO refuses portfolio status and readiness
commands when `PORTFOLIO_PRIORITIES` is missing or incomplete because silent
ordering can waste agent capacity on the wrong product. If the operator wants
ORDO to derive priority from portfolio order, pass `--yolo-priority`.

## Repository Binding

When repository names or clone paths are custom, bind them explicitly before
preflight:

```bash
PORTFOLIO_REPO_CANDIDATES=(
  "product-c|owner/custom-product-c|main|/workspace/product-c-%s"
)
```

If the repo list is not known, ORDO can produce a non-mutating bind plan for a
configured provider owner:

```bash
bash scripts/portfolio_repo_bind_plan.sh <portfolio-config> \
  --discover-owner owner \
  --json
```

The bind plan never edits configs, creates clones, moves panes, or dispatches
work. Candidate rows require operator confirmation before
`portfolio_session_start.sh --apply` can create anything.

## Capacity Status

```bash
bash scripts/portfolio_status.sh <portfolio-config> --tsv
bash scripts/portfolio_status.sh <portfolio-config> --json
bash scripts/portfolio_status.sh <portfolio-config> --yolo-priority --tsv
```

For each product, ORDO reports:

- `dispatchable`: no PR gate is blocking the product;
- `external_wait`: open PRs are waiting on checks or external merge gates;
- `merge_ready`: at least one PR is green and mergeable;
- `action_required`: CI failure, rebase, conflict, or requested changes;
- free agents: clean, on default branch, no open PR;
- parkable agents: clean, non-default branch already represented by an open PR;
- unsafe agents: dirty, behind, conflicted, or rebase-required.

When a product is `external_wait` and has free or parkable agents,
`rebalance_signal` becomes `rebalance_recommended`.

## Session Start Readiness

At the beginning of an orchestration session:

```bash
bash scripts/portfolio_session_start.sh <portfolio-config> --tsv
bash scripts/portfolio_session_start.sh <portfolio-config> --json
```

The audit verifies clone existence, git repository shape, default branch, dirty
state, remote default availability, and ahead/behind drift. It fetches
`origin/<default>` by default so drift detection is current; use `--no-fetch`
for local-only reads.

When `PORTFOLIO_FLEET_AGENTS` is defined, the audit expands the full
agent/product matrix. Missing clones are reported with remediation metadata
only when the project config exposes a confirmed remote binding through
`REPO_URL`, `GIT_REMOTE_URL`, or the provider-specific `GH_REPO`.

With `--apply`, session start performs only deterministic safe actions:

- clone a missing workdir when a confirmed remote binding exists;
- fast-forward a clean default-branch clone that is behind `origin/<default>`.

It does not stash, reset, checkout over local work, rebase feature branches, or
push. Unsafe states become explicit unblock tasks.

```bash
bash scripts/portfolio_session_start.sh <portfolio-config> --apply --dry-run
bash scripts/portfolio_session_start.sh <portfolio-config> --apply --json
```

Live reports and unblock tasks are written under the ORDO state directory:

```text
_portfolio/session_start.json
_portfolio/clean_plan.json
_portfolio/PREFLIGHT_CLEAN_PLAN.md
_portfolio/unblock_tasks.json
_portfolio/ORCH_TASKS.md
```

## Product Switch Modes

`hard` mode respawns the physical pane in the target workdir:

```bash
bash scripts/agent_product_switch.sh \
  <portfolio-config> \
  product-a planner product-b \
  --target-agent planner \
  --reason external-wait \
  --dry-run
```

`soft` mode keeps the pane and current process stable, then sends a workspace
contract instructing the agent to work from a target repo:

```bash
bash scripts/agent_product_switch.sh \
  <portfolio-config> \
  product-a planner product-b \
  --target-agent planner \
  --soft \
  --reason external-wait \
  --dry-run
```

Hard mode is a physical-pane operation. Source and target configs must map the
same tmux session pane unless the operator explicitly overrides the target
agent. Soft mode can target a different configured workdir without respawning
the pane.

Direct ticket dispatch can use the same portfolio matrix fallback:

```bash
bash scripts/dispatch_ticket.sh \
  <target-project-config> planner 93 /tmp/dispatch-planner-93.md \
  --portfolio <portfolio-config> \
  --dry-run
```

ORDO refuses to switch by default when:

- the source worktree is dirty;
- the source branch is not the default branch and has no open PR;
- the PR is behind or conflicting;
- hard mode maps source and target to different physical panes;
- the target workdir is not a git repository.

Use `--force` only for an operator-reviewed exception.

## Soft Workspace Guardrails

Soft routing has stricter context controls. By default, it refuses when:

- the target workdir is dirty;
- the target workdir is on a non-default branch;
- the target workdir is not declared in the target project config or resolved
  from the portfolio matrix.

The brief sent to the pane includes a workspace contract path and requires the
agent to verify:

```bash
pwd
git -C <target-workdir> status --short --branch
```

If the active repo does not match the contract, the agent must stop and report
`context-mismatch`.

Override options are explicit:

- `--allow-target-branch`: allow a clean target workdir already on a non-default
  branch;
- `--no-strict-context`: disable target branch and dirty checks;
- `--force`: bypass safety refusals after operator review.

## Context Record

A successful switch records a JSON entry under the portfolio state directory:

```json
{
  "pane": "terminal-a:0.0",
  "mode": "soft",
  "brief_pane": "terminal-a:0.0",
  "source_project": "product-a",
  "source_branch": "main",
  "source_head": "abc12345",
  "source_pr": null,
  "target_project": "product-b",
  "target_workdir": "/workspace/product-b-planner",
  "target_branch": "main",
  "target_head": "def67890",
  "target_dirty": 0,
  "safe_state": "free",
  "reason": "external-wait",
  "strict_context": true,
  "switched_at": "2026-05-06T11:16:46Z"
}
```

The pane receives a short context brief naming the target product and workdir
and the source project that was parked.

## Operating Pattern

1. Run `portfolio_session_start.sh`.
2. Run `portfolio_status.sh`.
3. Merge any `merge_ready` PRs through `pr_merge.sh`.
4. Fix `action_required` blockers before moving agents.
5. If a product is `external_wait`, run `auto_rebalance.sh` or a dry-run switch
   to route parkable capacity to another configured product.
6. Switch agents back when the original product has mergeable PRs or ready
   work.

Portfolio routing does not validate a regulated deployment and does not change
the CSV release disposition by itself.
