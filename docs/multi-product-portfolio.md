# Multi-Product Portfolios

ORDO can coordinate one physical agent pool across several product repos. This
is useful when one project is waiting on external gates such as CI, deploy
health checks, reviews, or GitHub merge state, while clean agents could produce
useful work on another product.

The feature is product-neutral. RBOK, NOMOS, PRAXIS, LUMEN, WordPress, and ORDO
itself are just project configs in a portfolio.

## Portfolio Config

Create a config that references independent project configs:

```bash
PORTFOLIO_NAME="company-products"
PORTFOLIO_PROJECTS=(
  "rbok|/path/to/rbok.config.sh"
  "nomos|/path/to/nomos.config.sh"
  "praxis|/path/to/praxis.config.sh"
  "lumen|/path/to/lumen.config.sh"
  "wordpress|/path/to/realisons-wp.config.sh"
)
```

The right side can be any config accepted by ORDO: alias under `examples/`, a
relative path, or an absolute path.

## Capacity Status

```bash
bash scripts/portfolio_status.sh examples/portfolio.config.sh --tsv
bash scripts/portfolio_status.sh examples/portfolio.config.sh --json
```

For each product, ORDO reports:

- `dispatchable`: no PR gate is blocking the product;
- `external_wait`: open PRs are waiting on checks or external merge gates;
- `merge_ready`: at least one PR is green and mergeable;
- `action_required`: CI failure, rebase, conflict, or requested changes;
- free agents: clean, on default branch, no open PR;
- parkable agents: clean, non-default branch already represented by an open PR;
- unsafe agents: dirty, behind, conflict, or rebase-required state.

When a project is `external_wait` and has free or parkable agents,
`rebalance_signal` becomes `rebalance_recommended`.

## Product Switch

```bash
bash scripts/agent_product_switch.sh \
  examples/portfolio.config.sh \
  rbok RBOK-claude-2 nomos \
  --target-agent claude \
  --reason rbok-gate-wait \
  --dry-run
```

The switch is a physical-pane operation. The source and target project configs
must map the same tmux session pane, either with the same label or with
`--target-agent`.

ORDO refuses to switch by default when:

- the source worktree is dirty;
- the source branch is not the project default branch and has no open PR;
- the PR is behind or conflicting;
- source and target map to different physical panes;
- the target workdir is not a git repository.

Use `--force` only for an operator-reviewed exception.

## Context Coherence

A successful switch records a JSON entry under the portfolio state directory:

```json
{
  "pane": "claude:0.0",
  "source_project": "rbok",
  "source_branch": "develop",
  "source_head": "abc12345",
  "source_pr": null,
  "target_project": "nomos",
  "target_workdir": "/root/repos/Nomos-claude",
  "safe_state": "free",
  "reason": "rbok-gate-wait",
  "switched_at": "2026-05-06T11:16:46Z"
}
```

The pane receives a short context brief telling the agent which product and repo
it is now operating in, and which source project was parked.

## Operating Pattern

1. Run `portfolio_status.sh`.
2. Merge any `merge_ready` PRs through `pr_merge.sh`.
3. Fix any `action_required` blocker before moving agents.
4. If a product is `external_wait`, switch free or parkable agents to another
   configured product with ready work.
5. Switch them back when the original product has mergeable PRs or new ready
   issues.
