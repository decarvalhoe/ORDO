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
- [SECRETS.md](../SECRETS.md) — token file expectations and rotation.

### Integration

- [README.md → Project Profile Contract](../README.md#project-profile-contract)
- [docs/universal-fleet-manual.md](universal-fleet-manual.md) — fleet
  contract, minimal external profile, assignee mapping, supervisor binding.
- [docs/project-meta-context.md](project-meta-context.md) — cached project
  memory used for orchestrator handoffs.
- [docs/project-scaffold.md](project-scaffold.md) — neutral baseline for
  new downstream projects.
- [docs/multi-product-portfolio.md](multi-product-portfolio.md) — moving
  one fleet across multiple downstream products.

### Usage

- [README.md → Common Commands](../README.md#common-commands)
- [docs/universal-fleet-manual.md → Daily Commands](universal-fleet-manual.md#daily-commands)
- [docs/dispatch-planning.md](dispatch-planning.md) — issue ranking and
  ready/blocked classification.
- [docs/sixsigma-autoupgrade.md](sixsigma-autoupgrade.md) — CI autofix
  workflow.
- [docs/ci-autofix.md](ci-autofix.md) — CI autofix mechanics.

### Operator runbooks

- [docs/host-health-runbook.md](host-health-runbook.md)
- [docs/controlled-operations.md](controlled-operations.md)
- [docs/worktree-migration.md](worktree-migration.md)
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
- [docs/orchestrator-injected-rules.md](orchestrator-injected-rules.md)
- [docs/fleet-injected-rules.md](fleet-injected-rules.md)
- [docs/otel-export.md](otel-export.md)

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
