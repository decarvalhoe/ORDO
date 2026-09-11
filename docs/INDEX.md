# ORDO Documentation Index

This is the top-level navigation for ORDO documentation. It lists every
published document, grouped by audience and category, so a reader can find
the right material in one click.

The conceptual map that explains how the categories fit together — and which
docs must be updated when the toolkit changes — lives in
[docs/architecture/README.md](architecture/README.md).

## Start Here

| If you are a... | Start with | Then read |
| --- | --- | --- |
| New user | [README.md](../README.md) | [PRODUCT.md](../PRODUCT.md), [docs/universal-fleet-manual.md](universal-fleet-manual.md) |
| Operator | [docs/universal-fleet-manual.md](universal-fleet-manual.md) | [docs/dispatch-planning.md](dispatch-planning.md), [docs/host-health-runbook.md](host-health-runbook.md) |
| Integrator | [README.md → Project Profile Contract](../README.md#project-profile-contract) | [SECRETS.md](../SECRETS.md), [docs/multi-product-portfolio.md](multi-product-portfolio.md) |
| Local-agent author | [docs/issue-pack-handoff.md](issue-pack-handoff.md) | [`templates/issue-pack/`](../templates/issue-pack/) |
| Developer | [docs/architecture/README.md](architecture/README.md) | [docs/architecture.md](architecture.md), [docs/orchestrator-injected-rules.md](orchestrator-injected-rules.md) |
| Validation reviewer | [docs/validation/README.md](validation/README.md) | [docs/validation/document-index.md](validation/document-index.md) |

## By Documentation Category

The categories below match
[docs/architecture/README.md → Documentation Categories](architecture/README.md#documentation-categories).
Each document appears under every category that owns part of its content.

### Installation

- [README.md](../README.md) — quick start, prerequisites, current release
  state.
- [install.sh](../install.sh) — canonical installer; read its inline
  comments for what it changes on the host.
- [docs/install.md](install.md) — narrative installation guide for
  operator-led setups.
- [SECRETS.md](../SECRETS.md) — token file expectations and rotation.

### Integration

- [README.md → Project Profile Contract](../README.md#project-profile-contract)
- [docs/integration.md](integration.md) — integrating ORDO into an
  existing repository or CI pipeline.
- [docs/universal-fleet-manual.md](universal-fleet-manual.md) — fleet
  contract, minimal external profile, assignee mapping, supervisor binding.
- [docs/project-meta-context.md](project-meta-context.md) — cached project
  memory used for orchestrator handoffs.
- [docs/project-scaffold.md](project-scaffold.md) — neutral baseline for
  new downstream projects.
- [docs/multi-product-portfolio.md](multi-product-portfolio.md) — moving
  one fleet across multiple downstream products.
- [docs/onboarding-multi-project.md](onboarding-multi-project.md) —
  onboarding a multi-project portfolio against an existing fleet.
- [docs/external-agent-skills.md](external-agent-skills.md) — declaring
  external agent skills in a project profile.

### Usage

- [README.md → Common Commands](../README.md#common-commands)
- [docs/usage.md](usage.md) — daily-driver usage walk-through for
  operators.
- [docs/universal-fleet-manual.md → Daily Commands](universal-fleet-manual.md#daily-commands)
- [docs/agent-status-declarations.md](agent-status-declarations.md) —
  provider-neutral agent status declarations and low-overhead wake markers.
- [docs/dispatch-planning.md](dispatch-planning.md) — issue ranking and
  ready/blocked classification.
- [docs/dispatch.md](dispatch.md) — dispatch lifecycle reference,
  including the in-flight scope-claim ledger (`assignments_scope_claims.json`)
  consumed by `dispatch_plan --ready-only` and `brief_agents`.
- [docs/sixsigma-autoupgrade.md](sixsigma-autoupgrade.md) — CI autofix
  workflow.
- [docs/ci-autofix.md](ci-autofix.md) — CI autofix mechanics.
- [docs/pr-operations-governance.md](pr-operations-governance.md) —
  umbrella governance for the four PR operations modes (observe,
  centralized, delegated, autonomous).
- [docs/pr-ops-controller.md](pr-ops-controller.md) — deeper-dive on the
  centralized PR operations controller.
- [docs/visual-verification-lane.md](visual-verification-lane.md) —
  opt-in visual verification capability probe.

### Operator runbooks

- [docs/runbooks/README.md](runbooks/README.md) — index of the `docs/runbooks/`
  operator-runbook tree (fleet preparation, Windows SSH dispatch, connector
  permission prompts, API rate limiting, classifier outage, autonomous
  merge-policy and post-merge-cleanup remediation, fleet-outage handoff, and
  GxP / Six Sigma layer audits).
- [docs/operator-runbook.md](operator-runbook.md) — operator entry point
  when the supervisor stops making forward progress; covers the
  queue-starvation surface (`scripts/queue_starvation_surface.sh`) and
  the `QUEUE_STARVED_NO_RESOLUTION` escalation contract (#765).
- [docs/host-health-runbook.md](host-health-runbook.md)
- [docs/log-retention.md](log-retention.md) — ORDO / Codex log retention contract enforced by `scripts/log_retention.sh` and surfaced by `scripts/host_health_preflight.sh` (#747).
- [docs/preflight-connector-auth-drift.md](preflight-connector-auth-drift.md) —
  what the fleet preflight surfaces for Codex connector directory drift
  and MCP startup auth failures (#748).
- [docs/controlled-operations.md](controlled-operations.md)
- [docs/worktree-migration.md](worktree-migration.md)
- [docs/post-merge.md](post-merge.md) — post-merge cleanup, the
  closure-acceptance gate, and the PR-body proof patterns that let an
  auto-close proceed (acceptance block, operator override, scaffold-only
  retarget).
- [docs/closure-gate-operator-playbook.md](closure-gate-operator-playbook.md)
  — operator playbook for the closure-acceptance gate: decision matrix
  mapping PR archetypes to the three forms, when to use vs. NOT use the
  operator-authorized trailer, and audit guidance for the
  `POST_MERGE_CLEANUP CLOSURE_GATE` / `CLOSURE_REFUSED` rows.
- [docs/portfolio-poc-plan.md](portfolio-poc-plan.md)
- [docs/opportunity-registry.md](opportunity-registry.md)

### Local-agent handoff

- [docs/issue-pack-handoff.md](issue-pack-handoff.md) — local issue-pack
  handoff policy: plan locally, file a nuclear epic with atomized child
  issues, send the `NEW ISSUE PACK READY` notification, then stop. Local
  agents do not dispatch remote agents.
- [`templates/issue-pack/nuclear-epic.md`](../templates/issue-pack/nuclear-epic.md)
  — template for the parent epic that consolidates the locally-atomized
  scope.
- [`templates/issue-pack/child-issue.md`](../templates/issue-pack/child-issue.md)
  — template for each atomized child issue.
- [`templates/issue-pack/issue-pack-ready.md`](../templates/issue-pack/issue-pack-ready.md)
  — `NEW ISSUE PACK READY` notification template the local agent sends to
  the configured remote orchestrator.

### Developer docs

- [docs/architecture.md](architecture.md) — tiered CI strategy.
- [docs/architecture/README.md](architecture/README.md) — documentation
  architecture and information map.
- [docs/architecture/change-triggers.md](architecture/change-triggers.md) —
  which docs to update when the toolkit changes.
- [docs/architecture/contracts.md](architecture/contracts.md) — canonical
  execution contracts v1: kinds, state tables, error object / exit codes,
  redaction (#807); rules in [`contracts/README.md`](../contracts/README.md).
- [docs/architecture/cli.md](architecture/cli.md) — the unified `ordo`
  CLI (`scripts/ordo.sh`, `lib/ordo_cli.sh`): command registry, routing
  table, output modes, structured errors and exit codes.
- [docs/orchestrator-injected-rules.md](orchestrator-injected-rules.md)
- [docs/fleet-injected-rules.md](fleet-injected-rules.md)
- [docs/otel-export.md](otel-export.md)
- [docs/exit-codes.md](exit-codes.md) — canonical manifest of ORDO
  refusal exit codes (the 75–79 band, plus the policy-style 80–92
  block); drift-guarded by `tests/test_exit_codes_manifest.sh`.
- [docs/env-diagnostics.md](env-diagnostics.md) — environment readiness
  diagnostics surfaced by ORDO scripts.
- [docs/docs-generate.md](docs-generate.md) — reusable project doc
  generator module (#261).
- [docs/sixsigma/README.md](sixsigma/README.md) — Six Sigma architecture map
  (Level 1 standard, Level 2 opt-in DMAIC module).
- [docs/templates/multi-agent/README.md](templates/multi-agent/README.md) —
  provider-neutral documentation templates for the supported deployment modes.
- [docs/design/claude-json-isolation.md](design/claude-json-isolation.md) —
  `.claude.json` write-storm and per-agent isolation **investigation note**
  (findings and proposed direction; #412).
- [docs/superpowers/plans/2026-05-08-ordo-sixsigma-compliance.md](superpowers/plans/2026-05-08-ordo-sixsigma-compliance.md)
  — Six Sigma compliance implementation **plan** (historical plan record,
  2026-05-08).

### User docs

- [README.md](../README.md)
- [PRODUCT.md](../PRODUCT.md)

### API / CLI references

Until a top-level CLI wrapper exists, the authoritative reference for each
command is the script itself plus the matching feature doc:

- [README.md → Common Commands](../README.md#common-commands)
- [docs/universal-fleet-manual.md → Daily Commands](universal-fleet-manual.md#daily-commands)
- [docs/dispatch-planning.md](dispatch-planning.md)
- [docs/sixsigma-autoupgrade.md](sixsigma-autoupgrade.md)
- [docs/controlled-operations.md](controlled-operations.md)
- [docs/host-health-runbook.md](host-health-runbook.md)
- [docs/project-scaffold.md](project-scaffold.md)
- [docs/project-meta-context.md](project-meta-context.md)
- [docs/architecture/cli.md](architecture/cli.md) — `ordo <command>`: the
  unified entry point that routes to the scripts below (help, completion,
  `--json`, exit codes).
- [docs/cli/persistent-flags.md](cli/persistent-flags.md) — per-CLI flags ORDO
  treats as persistent across an agent's internal restarts, and the drift
  detector behind their regression coverage.
- `scripts/*.sh` usage banners.

### Generated downstream docs

- [docs/project-scaffold.md](project-scaffold.md) — baseline generator,
  preview-first behaviour, and the files it writes into a downstream project.
- [docs/project-meta-context.md](project-meta-context.md) — cached
  documentation index generated per project.
- [docs/architecture/README.md → Generated downstream docs](architecture/README.md#8-generated-downstream-docs)
  — provenance and optional-layer rules for everything ORDO emits into a
  downstream project.

### Validation evidence

- [docs/validation/README.md](validation/README.md) — Validation Master
  Plan and current disposition.
- [docs/validation/document-index.md](validation/document-index.md) —
  authoritative register.
- `docs/validation/csv-*.md` — CSV-01 through CSV-10 foundation, IQ/OQ/PQ
  protocols and reports, VAL-01/02 final traceability and report, OPS-01
  maintaining-state, and CSV development mode.
- `docs/validation/evidence/` — execution evidence packs (IQ-02, OQ-02,
  PQ-02).

### External assessment

- [docs/external-assessment/README.md](external-assessment/README.md) — neutral
  external-assessment pack: impartiality charter (available in EN / FR / DE).
- [docs/external-assessment/evidence-and-maturity.md](external-assessment/evidence-and-maturity.md)
  — what is built, tested, proven vs. not, and known gaps, with reproducible
  evidence and verification commands.
- [docs/external-assessment/valuation-inputs.md](external-assessment/valuation-inputs.md)
  — neutral accounting and market-category frameworks, with no value verdict.
- [docs/public-claim-boundary.md](public-claim-boundary.md) — what ORDO may and
  may not claim (the evidence rule and reserved status labels).

## By Document Type

| Type | Where to find it |
| --- | --- |
| Product docs | [README.md](../README.md), [PRODUCT.md](../PRODUCT.md) |
| Operator docs | [docs/universal-fleet-manual.md](universal-fleet-manual.md), [docs/host-health-runbook.md](host-health-runbook.md), [docs/controlled-operations.md](controlled-operations.md), [docs/worktree-migration.md](worktree-migration.md), [docs/portfolio-poc-plan.md](portfolio-poc-plan.md), [docs/multi-product-portfolio.md](multi-product-portfolio.md), [docs/dispatch-planning.md](dispatch-planning.md), [docs/sixsigma-autoupgrade.md](sixsigma-autoupgrade.md), [docs/ci-autofix.md](ci-autofix.md), [docs/issue-pack-handoff.md](issue-pack-handoff.md) |
| Templates | [`templates/issue-pack/nuclear-epic.md`](../templates/issue-pack/nuclear-epic.md), [`templates/issue-pack/child-issue.md`](../templates/issue-pack/child-issue.md), [`templates/issue-pack/issue-pack-ready.md`](../templates/issue-pack/issue-pack-ready.md), [`templates/dispatch-canonical.md.tpl`](../templates/dispatch-canonical.md.tpl), [`templates/orch_briefing.md`](../templates/orch_briefing.md), [`templates/agent_briefing.md`](../templates/agent_briefing.md) |
| Generated docs | Material produced by ORDO into a downstream project — described by [docs/project-scaffold.md](project-scaffold.md) and [docs/project-meta-context.md](project-meta-context.md), but not located in this repository. |
| Controlled / GxP evidence | Everything under [docs/validation/](validation/). Changes go through the deviation/CAPA path described in [docs/validation/README.md](validation/README.md). |

## Optional Layers

Two documentation layers are explicit, opt-in, and must not appear in a
normal-dev downstream project unless they are selected. See
[docs/architecture/README.md → Optional layers](architecture/README.md#optional-layers)
for the full contract.

- GxP-grade layer anchor: [docs/validation/](validation/).
- Six Sigma layer anchor: [docs/sixsigma-autoupgrade.md](sixsigma-autoupgrade.md).

## Discovery

Quick search recipes operators frequently use. They keep working as long as
this index, the README documentation map, and the validation register stay
in sync:

```bash
# Find every doc and template that talks about local-agent handoff.
grep -rn "NEW ISSUE PACK READY\|nuclear epic\|issue pack\|Do not dispatch\|rbok-orchestrator" docs README.md examples templates || true

# Find every doc that references the validation dossier.
grep -rn "csv-val-02\|FINAL VALIDATION\|NOT RELEASED" docs || true

# Find every doc that references the orchestrator dispatch rules.
grep -rn "dispatch_plan\|brief_agents\|dispatch_ticket" docs README.md || true
```

## When to update this page

Update this index whenever a document is added, removed, renamed, or moved.
The discoverability rule is enforced by
[docs/architecture/README.md → Discoverability rules](architecture/README.md#discoverability-rules):
every published document must be reachable from this index.
