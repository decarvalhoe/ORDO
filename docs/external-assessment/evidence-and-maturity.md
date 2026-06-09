# Evidence and maturity dossier — input for external assessment

> Languages: **EN** · [FR](evidence-and-maturity.fr.md) · [DE](evidence-and-maturity.de.md)

> This document is a **neutral input** for an independent external assessment of
> the ORDO project's state. It asserts **no value** (monetary or strategic) and
> draws **no conclusion** about the project's worth. It presents verifiable
> facts: what is actually implemented and tested, what is not, and the known
> gaps. The analyst draws their own conclusions.
>
> The public claim contract is authoritative: see
> [public-claim-boundary.md](../public-claim-boundary.md). **Valuation inputs**
> (accounting frameworks and market context, with no verdict) are isolated in
> [valuation-inputs.md](valuation-inputs.md) for the analyst to apply
> independently.

## How to read this dossier

- Every statement maps to **evidence**: code, tests, CI configuration, a
  generated artifact, or a **named gap**.
- Quantitative metrics were measured on **2026-05-27** at commit `d80e60c`
  (the `origin/main` tip when this dossier was written). This pack is a
  docs-only change; it does not alter the engine or test counts below, though
  it adds Markdown files to the documentation count.
- Reproduction commands are provided (section "Verify it yourself"): nothing
  here asks to be taken on trust.
- Scope: this dossier describes the **observed** state. It does not present the
  roadmap as capability.

## 1. What ORDO is today

ORDO is a **shell-first control plane** for coordinating multi-agent software
delivery. It is a Bash codebase that drives external tools (`gh`, `git`, `jq`,
`tmux`) — there is no compiled binary and no long-running service. An operator
invokes individual scripts of the form `bash scripts/<name>.sh <project-config>
...` against an operator-owned project profile.

`examples/ordo.config.sh` is a loader that **refuses to run** until
`ORDO_PROJECT_PROFILE` points at an operator-owned profile; live repository
names, credentials, and tmux targets live outside this repository.

Command / workflow surface actually present on disk (all entry points below
were verified to exist):

| Workflow | Entry point(s) | Status |
|---|---|---|
| Fleet status | `agent_pool_status.sh`, `smart_poll_agents.sh` | implemented |
| Dispatch planning | `dispatch_plan.sh` | implemented |
| Dispatch execution | `dispatch_ticket.sh`, `brief_agents.sh` | implemented |
| PR blocker signals | `pr_block_signals.sh` | implemented |
| Gated merge | `lib/pr_merge.sh` | implemented |
| PR operations modes | `pr_ops_queue.sh`, `dispatch_pr_ops.sh` (observe / centralized / delegated), `pr_ops_controller.sh` | implemented; `autonomous` dispatcher mode reserved |
| Autonomous PR-ops runner | `autonomous_pr_ops.sh` | implemented; **opt-in, off by default** |
| Autonomous orchestrator loop | `orch_loop.sh` | implemented; **opt-in (requires explicit confirm), off by default** |
| CI autofix | `ci_autofix.sh`, `sixsigma_autoupgrade.sh` | implemented |
| Portfolio routing | `portfolio_session_start.sh`, `portfolio_status.sh` | implemented |
| Host health / safety gates | `host_health_preflight.sh`, `lib/host_load_gate.sh`, `lib/process_safety.sh` | implemented |
| CSV dossier scaffolding | `csv_dev_mode.sh` | implemented; **writes draft templates only** |
| Downstream docs generation | `docs_generate.sh` | implemented |

## 2. Implemented and tested

The engine is substantial and is covered by two test harnesses (Bats and a
custom `test_*.sh` shell harness), both wired into CI. The tests assert parsing
logic, refusal conditions, and state transitions — not only that a command
exits zero.

Metrics measured (commit `d80e60c`, 2026-05-27):

| Measure | Value |
|---|---:|
| Non-test shell lines (`lib/` + `scripts/`) | 51,862 |
| First-party scripts (`lib/` + `scripts/`) | 155 (74 + 81) |
| Bats test files / `@test` cases | 41 / 427 |
| Shell (`test_*.sh`) test files | 169 |
| Test lines (Bats + shell tests) | 48,177 |
| Tracked Markdown docs | 130 |
| CI workflows gating PRs to `main` | 2 |

Capabilities with implementation **and** behavioural tests (representative, not
exhaustive):

- **Gated merge** (`lib/pr_merge.sh`): enforces 11 distinct exit codes
  (`0` plus `2`–`11`) for CI-pending / failed / conflicted / dirty / review /
  reconcile refusal paths, with a final pre-merge head-SHA re-verification.
  Exercised by `tests/test_pr_merge.sh`.
- **Dispatch routing refusals** (`lib/dispatch_router.sh`): refuses dispatch
  before a brief is written when any routing surface (pane / filename / body
  token / cwd / git identity) disagrees. `tests/dispatch_router_route_mismatch.bats`
  (11 `@test` cases) models a recorded "Wave-23" routing incident.
- **Resilience refusals**: a tmux circuit breaker (`lib/process_safety.sh`),
  retry/recovery in `lib/tmux_helpers.sh`, a host-load gate that refuses
  dispatch on overload with exit code `75` (`lib/host_load_gate.sh`), and
  classifier-outage detection (`lib/classifier_outage.sh`).
- **Autonomous PR-ops runner gate set** (`scripts/autonomous_pr_ops.sh`):
  evaluated against a negative-test matrix in `tests/autonomous_pr_ops.bats`
  (23 `@test` cases).
- **Dispatch planning / atomization** (`scripts/dispatch_plan.sh`): ready /
  blocked / assigned classification and epic atomization, with multiple
  dedicated test files.

CI gates (`.github/workflows/`):

- `ci.yml` runs `scripts/run_shellcheck.sh`, `scripts/run_shell_tests.sh`, and
  `scripts/run_bats.sh` on every pull request to `main`. This is the merge gate.
- `docs-impact-gate.yml` runs `scripts/docs_impact_gate.sh check` and fails the
  PR when a change touches a user-visible surface without a documentation update
  or an explicit declaration trailer.

No formal code-coverage threshold is defined in CI.

## 3. Scaffold / not automated at this stage

To be clearly distinguished from the delivered scope:

| Item | Observed state | Evidence |
|---|---|---|
| CSV / GxP validation dossier | **Template scaffolding only.** `csv_dev_mode.sh` writes draft IQ/OQ/PQ templates (preview by default, `--apply` required) stamped `DRAFT TEMPLATE - NOT VALIDATED - NOT RELEASED`. It "never validates, releases, approves, waives" a system. | `scripts/csv_dev_mode.sh`; [docs/validation/](../validation/) |
| Autonomous orchestrator loop | Implemented but **gated off by default**: the daemon requires an explicit `ORCH_DAEMON_CONFIRM`; the documented default is the operator-driven `orch_manual_session.sh`. The loop delegates per-cycle decisions to an external agent CLI. | `scripts/orch_loop.sh` |
| `autonomous` dispatcher mode | **Reserved / refused** in `dispatch_pr_ops.sh`. Autonomous PR operations are provided instead by the separate opt-in `autonomous_pr_ops.sh` runner. | `scripts/dispatch_pr_ops.sh` |
| Six Sigma project-scaffold scripts | Documented as **planned / not yet implemented**. | [docs/sixsigma/README.md](../sixsigma/README.md) |
| Top-level CLI wrapper | **Not present**; entry points are individual scripts. | [PRODUCT.md → Product Roadmap](../../PRODUCT.md#product-roadmap) |

## 4. Proven vs. not proven

- **Proven (bounded to the tested scenarios).** The refusal and gating logic is
  asserted in CI: gated-merge exit codes, dispatch routing refusals (the
  Wave-23 model), the autonomous PR-ops gate set, and the tmux / host-load /
  classifier resilience refusals. These are **behavioural assertions in the
  test suites**, not field-scale guarantees.
- **Not proven (at operational / field scope).** Sustained autonomous
  multi-agent fleet operation over time; resilience to arbitrary SSH / host /
  network failure modes beyond the tmux, host-load, and classifier cases that
  are tested; correctness at fleet sizes beyond what an operator configures and
  has exercised; and any regulated **validated use** (the dossier refuses it).
- Capabilities labelled **opt-in / off by default** (the autonomous loop and the
  autonomous PR-ops runner) are implemented and tested but are not the documented
  default operating mode.

## 5. Known gaps

(Reflects the observed state and the stated roadmap at measurement time,
2026-05-27.)

- No top-level CLI wrapper; scripts are invoked individually
  ([PRODUCT.md roadmap](../../PRODUCT.md#product-roadmap)).
- A single provider adapter (GitHub CLI / `gh`); provider abstraction beyond it
  is documented as roadmap, not delivered.
- Some large scripts are thinly covered (1–2 test files each): e.g.
  `runtime_freshness`, `prompt_unblock_policy`, `smart_poll_agents`,
  `ensure_alive`, `project_scaffold`.
- No formal coverage threshold in CI.
- CSV OQ/PQ evidence incomplete; final validation **release refused**, with open
  deviations `DEV-OQ-001` and `DEV-PQ-001`
  ([docs/validation/csv-val-02-final-report.md](../validation/csv-val-02-final-report.md)).
- No generated static documentation site, packaged installer/upgrade path, or
  dashboard layer (all roadmap).

## 6. Verify it yourself

```bash
# Anchor
git rev-parse HEAD            # expect d80e60c… when measured

# Engine size (non-test shell)
git ls-files | grep -E '^(lib|scripts)/.*\.sh$' | xargs wc -l | tail -1
git ls-files | grep -E '^lib/.*\.sh$'     | wc -l   # 74
git ls-files | grep -E '^scripts/.*\.sh$' | wc -l   # 81

# Tests
git ls-files | grep -E '^tests/.*\.bats$' | wc -l                              # 41
git ls-files | grep -E '^tests/.*\.bats$' | xargs grep -hcE '^\s*@test' \
  | awk '{s+=$1} END{print s}'                                                 # 427
git ls-files | grep -E '^tests/.*\.sh$'   | wc -l                              # 169

# Gated-merge exit codes and routing-incident model
grep -oE 'exit [0-9]+' lib/pr_merge.sh | sort -u
grep -cE '^\s*@test' tests/dispatch_router_route_mismatch.bats                 # 11

# Opt-in / off-by-default gates
grep -n 'ORCH_DAEMON_CONFIRM' scripts/orch_loop.sh
grep -n 'NOT VALIDATED' scripts/csv_dev_mode.sh

# CI gates
ls .github/workflows/

# Run the suites locally (the same entrypoints CI uses)
bash scripts/run_shellcheck.sh
bash scripts/run_shell_tests.sh
bash scripts/run_bats.sh
```

---

> No valuation in this document. The accounting frameworks and market context
> (with no verdict) are in [valuation-inputs.md](valuation-inputs.md), for the
> analyst to apply.
