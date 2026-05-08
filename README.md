# ORDO

ORDO is a shell-first control plane for coordinating multi-agent software
delivery.

It helps an operator observe a fleet, plan work from issue queues, dispatch
bounded tasks, monitor pull requests and checks, recover from blocked states,
and merge only when the configured gates say the work is ready.

ORDO is intentionally neutral:

- agent-neutral: labels can represent any terminal-driven agent or human
  operator;
- repo-neutral: live repository names and host paths belong in external project
  profiles;
- provider-adapter based: issue, pull request, review, and check signals come
  from configured adapters. The current shell workflows use `gh` where GitHub
  is the chosen provider;
- dry-run first: broad or mutating workflows expose preview modes and refuse
  unsafe states by default.

## Current Release State

This repository release publishes the ORDO toolkit and documentation state. It
does not claim that any deployment of ORDO is validated for regulated
production use.

Current validation dossier disposition:

- release status: `NOT RELEASED`;
- production-readiness status: `NOT PRODUCTION READY`;
- final validation status: release refused pending open OQ/PQ blockers;
- open validation deviations: `DEV-OQ-001` and `DEV-PQ-001`;
- OQ is not released to PQ;
- PQ stopped at `PQ-001`; `PQ-002` through `PQ-016` were not executed;
- CSV development mode scaffolds dossier templates only. It never validates,
  approves, waives, or releases a system automatically.

See [docs/validation/README.md](docs/validation/README.md) and
[docs/validation/csv-val-02-final-report.md](docs/validation/csv-val-02-final-report.md)
for the controlling validation disposition.

## What ORDO Does

ORDO turns hidden multi-agent delivery states into explicit signals:

- which agents are free, dirty, parked, blocked, behind, or already represented
  by a pull request;
- which issues are ready, assigned, blocked by dependencies, or too broad and
  need atomization;
- which PRs are merge-ready, waiting on checks, stale, conflicted, missing
  review, or carrying requested changes;
- which products in a portfolio can use idle capacity while another product is
  waiting on external gates;
- which operational findings should become immediate fixes or durable
  improvement records.

The result is a repeatable operator loop:

1. preflight the configured project or portfolio;
2. inspect fleet and backlog state;
3. dispatch one bounded task per available agent;
4. monitor work and PR blocker signals;
5. remediate or route failures with evidence;
6. merge only through the configured gated merge path.

## Quick Start

Use an existing checkout or clone the repository from the source location used
by your organization. Keep live topology out of this repository.

```bash
cd <ordo-checkout>

# Validate the toolkit locally.
bash scripts/run_shellcheck.sh
bash scripts/run_shell_tests.sh

# Use a generic project profile for read-only signals.
export ORDO_PROJECT_PROFILE=/absolute/path/to/project.config.sh
bash scripts/agent_pool_status.sh examples/ordo.config.sh --tsv
bash scripts/dispatch_plan.sh examples/ordo.config.sh --ready-only --json
bash scripts/pr_block_signals.sh examples/ordo.config.sh --tsv
```

`examples/ordo.config.sh` is a loader. It refuses to run until
`ORDO_PROJECT_PROFILE` points at an operator-owned project profile. That profile
is where real repository identifiers, provider credentials, tmux pane targets,
host paths, and agent labels belong.

For a step-by-step walkthrough see:

- [docs/install.md](docs/install.md) — prerequisites, installer, tokens, first
  verification command.
- [docs/integration.md](docs/integration.md) — adding ORDO to an existing or
  greenfield project, single-project and portfolio profiles, operator-owned
  config.
- [docs/usage.md](docs/usage.md) — daily operator loop with read-only versus
  mutating commands clearly marked.

## Project Profile Contract

The recommended fleet inventory is explicit and label based:

```bash
PROJECT="target-system"
DEFAULT_BRANCH="main"

# Provider adapter settings. For GitHub-backed projects this currently includes
# GH_REPO and GH_CONFIG_DIR because the shell adapter uses gh.
GH_REPO="owner/repository"
GH_CONFIG_DIR="/operator/credential/profile"

AGENT_PANES=(
  "planner|terminal-a:0.0|/workspace/target-planner"
  "builder|terminal-b:0.0|/workspace/target-builder"
  "reviewer|terminal-c:0.0|/workspace/target-reviewer"
)

AGENT_GH_LOGINS=(
  "planner=planner-bot"
  "builder=builder-bot"
  "reviewer=reviewer-bot"
)

SUPERVISOR_REPO="/workspace/target-supervisor"
AGENT_REPO_PREFIX="/workspace/target-"
export AGENT_WORKDIR_TEMPLATE="/workspace/target-%s"
```

Rules for profiles:

- use pane `0` when a fleet policy requires pane-zero-only operation;
- do not rely on agent labels matching provider names;
- do not store secrets in project profiles committed to ORDO;
- prefer the three-field `label|session:window.pane|workdir` form;
- keep live org, repo, user, host, and path names in external profiles or local
  fixtures, not in public product docs.

## Common Commands

| Workflow | Command |
| --- | --- |
| Fleet status | `bash scripts/agent_pool_status.sh <project-config> --tsv` |
| Portfolio preflight | `bash scripts/portfolio_session_start.sh <portfolio-config> --json` |
| Issue planning | `bash scripts/dispatch_plan.sh <project-config> --ready-only --json` |
| Dispatch | `bash scripts/dispatch_ticket.sh <project-config> <agent> <issue> <prompt.md>` |
| Smart poll | `bash scripts/smart_poll_agents.sh <project-config> <wave-id>` |
| Integrate wave | `bash scripts/integrate_wave.sh <project-config>` |
| PR blockers | `bash scripts/pr_block_signals.sh <project-config> --tsv` |
| CI autofix | `bash scripts/sixsigma_autoupgrade.sh <project-config> --dry-run` |
| Check workflow audit | `bash scripts/gh_actions_optimize.sh <project-config> --audit` |
| Controlled operation evidence | `bash scripts/controlled_operation.sh <project-config> plan --type emergency-admin --id emergency-001 --reason "temporary maintenance"` |
| Portfolio routing | `bash scripts/portfolio_status.sh <portfolio-config> --tsv` |
| Gated merge | `bash lib/pr_merge.sh <project-config> <pr-number>` |
| CSV dossier scaffold | `bash scripts/csv_dev_mode.sh <project-config> --target-dir <target-checkout> --dossier-dir .ordo/validation --json` |
| Downstream docs pack | `bash scripts/docs_generate.sh <project-config> --target-dir <target-checkout> --intent "..." --json` |

Prefer dry-runs before live dispatch, switching, merge, portfolio repair, or
dossier generation.

## Documentation Map

The two top-level entry points cover everything else:

- [docs/INDEX.md](docs/INDEX.md) — full navigation, grouped by audience and
  category (installation, integration, usage, operator runbooks, developer
  docs, user docs, API/CLI references, generated downstream docs, validation
  evidence).
- [docs/architecture/README.md](docs/architecture/README.md) — documentation
  architecture and information map: which docs are product docs, operator
  docs, generated docs, or controlled/GxP evidence; which optional layers are
  available; and which docs must be updated when features, CLIs, configs, or
  workflows change (matrix in
  [docs/architecture/change-triggers.md](docs/architecture/change-triggers.md)).

Frequently used direct links:

| Topic | Document |
| --- | --- |
| Documentation index | [docs/INDEX.md](docs/INDEX.md) |
| Product positioning | [PRODUCT.md](PRODUCT.md) |
| Installation | [docs/install.md](docs/install.md) |
| Integration (existing project, greenfield, profiles, portfolio) | [docs/integration.md](docs/integration.md) |
| Daily usage (audit, dispatch, monitor, merge, cleanup) | [docs/usage.md](docs/usage.md) |
| Universal fleet setup | [docs/universal-fleet-manual.md](docs/universal-fleet-manual.md) |
| Multi-project onboarding extension | [docs/onboarding-multi-project.md](docs/onboarding-multi-project.md) |
| Fleet preparation runbook | [docs/runbooks/fleet-preparation.md](docs/runbooks/fleet-preparation.md) |
| Operator runbooks index | [docs/runbooks/README.md](docs/runbooks/README.md) |
| Multi-product portfolios | [docs/multi-product-portfolio.md](docs/multi-product-portfolio.md) |
| Dispatch planning | [docs/dispatch-planning.md](docs/dispatch-planning.md) |
| Local issue-pack handoff (Do not dispatch from local) | [docs/issue-pack-handoff.md](docs/issue-pack-handoff.md) |
| Issue-pack templates (nuclear epic, child issue, NEW ISSUE PACK READY) | [templates/issue-pack/](templates/issue-pack/) |
| Project meta context | [docs/project-meta-context.md](docs/project-meta-context.md) |
| Documentation generator | [docs/docs-generate.md](docs/docs-generate.md) |
| Six Sigma module (entry-point: standard cycle + opt-in DMAIC) | [docs/sixsigma/README.md](docs/sixsigma/README.md) |
| CI autofix and autoupgrade | [docs/sixsigma-autoupgrade.md](docs/sixsigma-autoupgrade.md) |
| Controlled operations | [docs/controlled-operations.md](docs/controlled-operations.md) |
| Host health | [docs/host-health-runbook.md](docs/host-health-runbook.md) |
| OTEL export | [docs/otel-export.md](docs/otel-export.md) |
| Worktree isolation | [docs/worktree-migration.md](docs/worktree-migration.md) |
| Exit codes manifest | [docs/exit-codes.md](docs/exit-codes.md) |
| CSV validation dossier | [docs/validation/README.md](docs/validation/README.md) |
| CSV development mode | [docs/validation/csv-development-mode.md](docs/validation/csv-development-mode.md) |
| Secrets handling | [SECRETS.md](SECRETS.md) |

## Operating Principles

- **One agent, one bounded assignment.** Avoid double-assignment and file
  conflicts by inspecting agent state and open PRs before dispatch.
- **Configured topology only.** ORDO reads fleet identity from project profiles;
  it must not infer live names from product branding.
- **Evidence before claims.** Completion, validation, release, and merge claims
  require durable evidence, not terminal scrollback or chat memory alone.
- **Dry-run first.** Preview mutating operations and keep refusal output
  visible to the operator.
- **Fail closed.** Missing checks, ambiguous provider state, dirty worktrees,
  stale branches, and unresolved deviations stop the workflow until someone
  resolves them.
- **No automatic validated-use claim.** CSV automation can scaffold,
  reconcile, and report; accountable humans approve or refuse release.

## Running Tests

The repository ships its own runners so local verification and CI use the same
entrypoints:

```bash
bash scripts/run_shellcheck.sh
bash scripts/run_shell_tests.sh
bash scripts/run_bats.sh
```

`run_shellcheck.sh` excludes `SC1090` and `SC1091` because ORDO intentionally
loads runtime-selected project configs and helper libraries. The dynamic source
statements are covered by shell and Bats tests.

When the host reports validator pressure or process-budget degradation, prefer
CI validation instead of re-running full local suites in a loop.

## Safe Mutation Model

Many mutating scripts accept `--dry-run`, and `ORCH_DRY_RUN=1` enables global
preview mode where supported.

Dry-run mode validates inputs and performs read-only checks, but skips actions
such as:

- terminal dispatch;
- session or pane mutation;
- PR merge;
- state writes;
- local rebases or checkouts;
- generated CSV dossier writes.

Skipped actions are printed with `DRY-RUN:` so the caller can review what would
have happened.

## CSV Development Mode

`scripts/csv_dev_mode.sh` scaffolds a provider-neutral CSV/GAMP/CSA-style
validation dossier for another target checkout.

```bash
bash scripts/csv_dev_mode.sh <project-config> \
  --target-dir <target-checkout> \
  --dossier-dir .ordo/validation \
  --json

bash scripts/csv_dev_mode.sh <project-config> \
  --target-dir <target-checkout> \
  --dossier-dir .ordo/validation \
  --apply
```

Safety boundaries:

- preview is the default;
- `--apply` is required for writes;
- unmanaged existing files are refused;
- generated paths are relative to the target checkout;
- generated issue trees are local drafts only;
- generated reports state `NOT VALIDATED` and `NOT RELEASED` until accountable
  review changes that state in a controlled record.

## Security

Secret names, storage expectations, rotation steps, and leak response
procedures are documented in [SECRETS.md](SECRETS.md). Do not commit secret
values, credential directories, provider tokens, terminal screenshots with
secrets, or live operator profiles.

## Release and Validation Boundary

A software release of this repository is not the same thing as a validated
release decision for a regulated deployment.

To claim validated use, a deployment needs the full controlled package defined
by the validation dossier: approved foundation records, IQ, OQ, PQ,
traceability reconciliation, final validation report, deviation and CAPA
disposition, residual-risk acceptance, and maintaining-state controls.

The current ORDO dossier explicitly refuses final validation release because
OQ/PQ evidence and approvals remain incomplete.
