# Mode: Portfolio / Multi-Project ORDO Deployment

> Template — copy into the documentation tree of `{{portfolio_name}}` and
> replace every `{{placeholder}}` before publishing.

This template documents an ORDO deployment that coordinates one physical
agent pool across two or more product repositories. It builds on
[`single-project.md`](single-project.md) and adds the portfolio mechanics
documented in `docs/multi-product-portfolio.md`.

## Installation

- toolkit version: `{{ordo_release_tag}}` (or `main` at SHA `{{base_sha}}`)
- toolkit checkout: `{{absolute_path_to_ordo_checkout}}`
- portfolio config: `{{absolute_path_to_portfolio_config}}`
- per-project profiles: list each `{{project_label}}` →
  `{{absolute_path_to_project_profile}}`
- credentials: provider tokens for each project, loaded from
  `{{operator_credential_source}}` per `SECRETS.md`
- prerequisites: `gh`, `jq`, `git`, `bash`, terminal multiplexer

```bash
export ORDO_PROJECT_PROFILE={{absolute_path_to_active_project_profile}}
bash {{absolute_path_to_ordo_checkout}}/scripts/portfolio_session_start.sh \
  {{portfolio_config}} --json
```

## Integration

- portfolio name: `{{portfolio_name}}`
- portfolio members (each with `project_label | repo | default_branch`):
  - `{{project_label_a}}` | `{{owner_a}}/{{repo_a}}` | `{{default_branch_a}}`
  - `{{project_label_b}}` | `{{owner_b}}/{{repo_b}}` | `{{default_branch_b}}`
- portfolio priorities: declare `PORTFOLIO_PRIORITIES` explicitly per
  `docs/multi-product-portfolio.md`
- shared agent pool (one physical agent that may switch between products):
  - `{{label_a}}` / `{{role_a}}` / `{{runtime_a}}` / `{{provider_account_a}}`
  - `{{label_b}}` / `{{role_b}}` / `{{runtime_b}}` / `{{provider_account_b}}`
- repo binding: declare `PORTFOLIO_REPO_CANDIDATES` if any project repo is
  custom, else rely on `portfolio_repo_bind_plan.sh`

The portfolio config refuses status and readiness commands when priorities
are missing. Use `--yolo-priority` only with explicit operator review.

## Usage

| Step | Command |
| --- | --- |
| Session start | `bash scripts/portfolio_session_start.sh <portfolio-config> --json` |
| Apply safe remediations | `bash scripts/portfolio_session_start.sh <portfolio-config> --apply --dry-run` then `--apply` |
| Capacity status | `bash scripts/portfolio_status.sh <portfolio-config> --tsv` |
| Soft route | `bash scripts/agent_product_switch.sh <portfolio-config> <src> <agent> <dst> --soft --dry-run` |
| Hard route | `bash scripts/agent_product_switch.sh <portfolio-config> <src> <agent> <dst> --dry-run` |
| Auto rebalance | `bash scripts/auto_rebalance.sh <portfolio-config>` |
| Per-product dispatch | follow [`single-project.md`](single-project.md) for the active product |

The portfolio operator alternates between portfolio-level commands and the
single-project loop for each product.

## Troubleshooting

| Symptom | Diagnosis | Safe remediation |
| --- | --- | --- |
| Portfolio status reports `external_wait` for every product | every product has open PRs blocked on external review or CI | use the rebalance signal to keep parkable agents productive on another product; do not force-merge |
| `portfolio_session_start.sh --apply` refuses to clean a workdir | workdir is dirty or on a non-default branch with no open PR | leave it alone and ask the agent to push the WIP, then re-run |
| `agent_product_switch` refuses with `context-mismatch` | source workdir is not clean, or hard mode targets the wrong physical pane | resolve dirty state on the source side or use soft mode with a different target agent |
| Portfolio routing keeps choosing the same product | priority weights overshadow capacity signals | tune `PORTFOLIO_PRIORITIES` in the portfolio config; do not bypass with `--force` |

## Audit Evidence

- portfolio state base: `{{orch_state_base}}/{{portfolio_name}}`
- portfolio reports: `_portfolio/session_start.json`,
  `_portfolio/clean_plan.json`, `_portfolio/PREFLIGHT_CLEAN_PLAN.md`,
  `_portfolio/unblock_tasks.json`, `_portfolio/ORCH_TASKS.md`
- per-product audit logs: each `{{project_label}}` profile sets
  `AUDIT_LOG_FILE`
- product-switch records: portfolio state directory, JSON entry per switch
- findings ledger: `{{findings_ledger_path}}` per
  `docs/orchestrator-injected-rules.md`

## Known Limitations

- portfolio mode does not change the validation grade; combine with
  [`gxp-grade.md`](gxp-grade.md) when any product is regulated;
- soft routing requires the target workdir to be declared in the target
  project config or resolved through the portfolio matrix;
- the dispatch matrix gate (issue #253) applies per product; the portfolio
  itself is not a substitute for per-product matrices;
- portfolio routing does not validate a regulated deployment and does not
  change a CSV release disposition by itself.

## Update Policy

- whenever a member project is added or removed, re-render the portfolio
  config, rerun `portfolio_session_start.sh`, and update this docs pack;
- whenever a project changes default branch, repo URL, or priority, update
  the portfolio config and re-run the audit;
- on toolkit upgrades, re-run portfolio preflight before any dispatch.

## Docs Impact

Refresh this docs pack whenever any of the following changes ship. Use the
checklist in [`docs-impact.md`](docs-impact.md):

- portfolio membership change (project added, removed, renamed);
- portfolio priority change;
- agent pool roster change (label, runtime, identity, audit root);
- toolkit version pin change affecting portfolio scripts;
- a member product flips between normal-dev and GxP-grade;
- a member product enables or disables the Six Sigma option.
