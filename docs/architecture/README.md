# ORDO Documentation Architecture

This page is the durable map of ORDO documentation. It tells users, operators,
integrators, developers, and validation reviewers where each kind of material
lives, who owns it, and when it must be updated.

It is the architecture page referenced by the parent epic
(["EPIC: build ORDO documentation system and automated downstream docs
generation"](https://github.com/RBOKproject/ORDO/issues/257)). It extends the
existing README, PRODUCT, and `docs/` layout. It does not replace any of those
files and does not introduce a parallel documentation track.

For the navigable list of every published document, see
[docs/INDEX.md](../INDEX.md).

## Audiences

Documentation in this repository is written for five primary audiences. Every
document should be reachable from the audience that owns its outcome.

| Audience | Primary question | Entry point |
| --- | --- | --- |
| User | "How do I run an ORDO operator loop on my fleet?" | [README.md](../../README.md) |
| Operator | "How do I dispatch, recover, integrate, and merge safely?" | [docs/universal-fleet-manual.md](../universal-fleet-manual.md) |
| Integrator | "How do I install ORDO and connect it to my provider, repo, and panes?" | [README.md](../../README.md) and [SECRETS.md](../../SECRETS.md) |
| Developer | "How do the scripts, libs, and tests fit together?" | [docs/architecture.md](../architecture.md) and `scripts/`, `lib/`, `tests/` |
| Validation reviewer | "Where is the controlled-document evidence and what is its current disposition?" | [docs/validation/README.md](../validation/README.md) |

A document that does not have a clearly identified audience is a candidate for
consolidation, not a new doc.

## Documentation Categories

ORDO documentation is organised into nine explicit categories. Every published
document belongs to at least one category. Categories are stable; individual
documents can move as the toolkit evolves.

### 1. Installation

Bootstraps ORDO on a host or operator workstation. Covers prerequisites,
installer behaviour, log/state directories, token files, and first-run checks.

- [README.md](../../README.md) — quick start and prerequisites.
- [install.sh](../../install.sh) — the canonical installer (read its inline
  comments for what it changes on the host).
- [SECRETS.md](../../SECRETS.md) — token file expectations and rotation.

### 2. Integration

Connects ORDO to a project's provider, repository, fleet, terminal panes, and
credentials through external project profiles. Integration material never
embeds live topology in this repository.

- [README.md → Project Profile Contract](../../README.md#project-profile-contract)
- [docs/universal-fleet-manual.md](../universal-fleet-manual.md) — fleet
  contract, profile rules, assignee mapping, supervisor CLI binding.
- [docs/project-meta-context.md](../project-meta-context.md) — cached project
  memory used for orchestrator handoffs.
- [docs/project-scaffold.md](../project-scaffold.md) — neutral baseline for new
  downstream projects, including the `--readiness-report` contract.
- [docs/multi-product-portfolio.md](../multi-product-portfolio.md) — moving one
  fleet across multiple downstream products.
- [examples/](../../examples) — neutral loader configs, never live topology.
- [docs/architecture/providers.md](providers.md) — connecting ORDO to a
  Forgejo/Gitea or GitLab instance (`ORDO_PROVIDER_ADAPTER`, `ORDO_FORGE_*`,
  token file rules) (#815).

### 3. Usage

Day-to-day operator workflow: snapshot, plan, dispatch, monitor, integrate,
merge. The canonical command tables are kept in the manual and the README.

- [README.md → Common Commands](../../README.md#common-commands)
- [docs/universal-fleet-manual.md → Daily Commands](../universal-fleet-manual.md#daily-commands)
- [docs/dispatch-planning.md](../dispatch-planning.md) — issue ranking and
  ready/blocked classification.
- [docs/sixsigma-autoupgrade.md](../sixsigma-autoupgrade.md) — CI autofix
  workflow.

### 4. Operator runbooks

Recovery, host health, controlled operations, and other "what do I do when X is
on fire" material. Runbooks document procedure, evidence, and safety rails;
they do not replace `--dry-run`.

- [docs/host-health-runbook.md](../host-health-runbook.md)
- [docs/controlled-operations.md](../controlled-operations.md)
- [docs/ci-autofix.md](../ci-autofix.md)
- [docs/worktree-migration.md](../worktree-migration.md)
- [docs/portfolio-poc-plan.md](../portfolio-poc-plan.md) — staged proof-of-concept
  plan for portfolio mode.
- [docs/opportunity-registry.md](../opportunity-registry.md) — durable
  improvement record.

### 5. Developer docs

How the toolkit is built, how its tiers split work, and the rules that shape
agent behaviour. Developer material is for people changing scripts, libs, or
dispatch contracts.

- [docs/architecture.md](../architecture.md) — tiered CI strategy and the
  toolkit's place in it.
- [docs/dispatch-planning.md](../dispatch-planning.md)
- [docs/orchestrator-injected-rules.md](../orchestrator-injected-rules.md) —
  rules the orchestrator must inject into every dispatch.
- [docs/fleet-injected-rules.md](../fleet-injected-rules.md) — rules every
  agent in the fleet must respect.
- [docs/otel-export.md](../otel-export.md) — telemetry export hooks.
- [docs/architecture/contracts.md](contracts.md) — canonical execution
  contracts v1 (run, task, attempt, agent, lease, event, approval, artifact,
  policy_decision, blocker), state tables, error object and exit codes (#807).
- [docs/architecture/adapters.md](adapters.md) — runtime adapters
  (tmux, ssh, fake) and the forge-neutral provider adapter (github, forgejo,
  gitlab, fake): op tables, normalised JSON shapes, selection knobs,
  mutation policy and idempotency ledger, conformance suite (#811).
- [docs/architecture/journal.md](journal.md) — SQLite event journal
  (`lib/ordo_journal.sh`): gapless per-run sequence, projections, compat
  export of legacy state files, lease/approval CRUD, recovery (#808).
- [docs/architecture/providers.md](providers.md) — forge providers:
  Forgejo/Gitea (REST v1) and GitLab (REST v4) adapters next to GitHub:
  per-forge configuration and token file, endpoint mapping, capability
  matrix (native / emulated / unsupported), error classification, known
  differences (#815).
- [docs/architecture/approvals.md](approvals.md) — approval-safe actions
  (`lib/ordo_approval.sh`, `scripts/ordo_approve.sh`): typed approvals,
  re-authorization checklist, idempotent execution, actor rules (#812).
- [docs/architecture/tracing.md](tracing.md) — OpenTelemetry-compatible
  spans (`lib/ordo_trace.sh`): span model, files, OTLP export, redaction (#812).
- [docs/architecture/scheduler.md](scheduler.md) — durable scheduler
  (`lib/ordo_scheduler.sh`): run state machine, leases and heartbeats, retry
  policy with backoff, timeouts, cancellation, crash recovery, budgets,
  fail-closed readiness, opt-in loop hook (#810).

### 6. User docs

Material consumed directly by the human running ORDO. The README is the
canonical user-facing entry; PRODUCT.md is the positioning document.

- [README.md](../../README.md)
- [PRODUCT.md](../../PRODUCT.md)

These two files plus [docs/INDEX.md](../INDEX.md) are the only entry points a
new user should need to find any other document.

### 7. API / CLI references

ORDO's surface is shell scripts plus their flags. Until the planned top-level
CLI wrapper exists (see [PRODUCT.md → Product Roadmap](../../PRODUCT.md#product-roadmap)),
the authoritative reference for each command is the script itself plus the
matching feature doc.

- [README.md → Common Commands](../../README.md#common-commands) — short reference.
- [docs/universal-fleet-manual.md → Daily Commands](../universal-fleet-manual.md#daily-commands)
- Per-feature pages: dispatch planning, sixsigma autoupgrade, controlled
  operations, host health, project scaffold, project meta context.
- `scripts/*.sh` — every script accepts `--help` or refuses with a usage banner;
  treat the banner as the contract.
- [docs/architecture/cli.md](cli.md) — the unified `ordo` CLI
  (`scripts/ordo.sh`): command and routing tables, output modes, error
  objects and exit codes, and the route-incrementally migration plan.

### 8. Generated downstream docs

Documentation that ORDO produces for a downstream project, not for itself.
Generated docs live in the target checkout, not in this repository, and they
must carry their own provenance markers.

- [docs/project-scaffold.md](../project-scaffold.md) — describes the baseline
  generator, its preview-by-default behaviour, and the files it writes.
- [docs/project-meta-context.md](../project-meta-context.md) — describes the
  cached documentation index that is generated per project.
- The reusable docs generator module and templates planned by epic #257
  (issues #261 and #262) will publish their generated artefacts under the
  target project's own `docs/` tree.

ORDO's commitment for generated docs:

- preview-first: the generator does not write without explicit `--apply`;
- provenance: every generated file is labelled as generated and refuses silent
  overwrites of unmanaged content;
- optional layers: GxP-grade and Six Sigma documentation layers are produced
  only when the downstream project is launched with those options selected,
  and never leak into normal-dev projects (see "Optional layers" below).

### 9. Validation evidence

Controlled-document evidence and its current disposition. This category is
governed by the CSV dossier and is the source of any validated-use claim.

- [docs/validation/README.md](../validation/README.md) — Validation Master Plan.
- [docs/validation/document-index.md](../validation/document-index.md) —
  authoritative register of CSV documents.
- `docs/validation/csv-*.md` — CSV-01 through CSV-10 foundation, IQ/OQ/PQ
  protocols and reports, VAL-01/02 final traceability and report, OPS-01
  maintaining-state.
- `docs/validation/evidence/` — execution evidence packs (IQ-02, OQ-02, PQ-02).

Controlled-document material must not be edited as ordinary documentation.
Changes go through the deviation/CAPA path described in
[docs/validation/README.md](../validation/README.md#deviation-capa-and-change-control).

## Document Type Taxonomy

Every document belongs to one of four ownership types. The type tells a reader
how the document is updated and what gates protect it.

| Type | What it is | Where to find it | Update path |
| --- | --- | --- | --- |
| Product docs | Public positioning, capabilities, roadmap, naming | [README.md](../../README.md), [PRODUCT.md](../../PRODUCT.md) | Normal PR; respect the change-trigger matrix below. |
| Operator docs | How an operator runs, recovers, and integrates ORDO | [docs/universal-fleet-manual.md](../universal-fleet-manual.md), [docs/host-health-runbook.md](../host-health-runbook.md), runbooks, integration pages | Normal PR; verify the documented commands still match scripts. |
| Generated docs | Material produced by ORDO for a downstream project | Inside the downstream checkout, never in this repo | Re-generated with preview-first; owned by the downstream project. |
| Controlled / GxP evidence | CSV dossier and execution evidence | [docs/validation/](../validation/) | Deviation/CAPA path; signed off by accountable reviewers. |

A document that mixes types (for example, an operator runbook that quietly
embeds validation conclusions) is a defect. Split it before merging.

## Optional layers

Two documentation layers are explicitly optional and gated on a downstream
project's selected options. They must be discoverable and testable from this
architecture page, but they must not leak into a normal-dev project that did
not select them.

### GxP-grade documentation layer

Required content when a downstream project is launched with GxP-grade options:

- controlled-document expectations and document index;
- validation/evidence sections and traceability matrix;
- audit-trail expectations and electronic-record/signature scope;
- deviation and CAPA hooks;
- traceability and update controls (who approves a change, against which CSV
  IDs).

For ORDO itself, this layer lives under [docs/validation/](../validation/) and
is the authoritative example of how a GxP-grade layer is structured. The
reusable generator (epic #257) reuses that structure for downstream projects
and only when GxP options are explicitly selected.

### Six Sigma documentation layer

Required content when a downstream project is launched with Six Sigma options:

- DMAIC chapters (Define, Measure, Analyze, Improve, Control);
- CTQ definitions and measurement plan;
- evidence ledger expectations;
- hooks for future Six Sigma modules.

ORDO's anchor for Six Sigma material is
[docs/sixsigma-autoupgrade.md](../sixsigma-autoupgrade.md). Six Sigma artefacts
must not appear in a normal-dev downstream project.

## Change-trigger matrix

When something changes in ORDO, the matrix below tells the contributor which
documentation must be updated in the same change. The matrix is intentionally
short. The detailed list lives in
[docs/architecture/change-triggers.md](change-triggers.md).

| Change | Always update | Update if affected |
| --- | --- | --- |
| New or removed user-facing feature | [README.md](../../README.md), [PRODUCT.md](../../PRODUCT.md), [docs/INDEX.md](../INDEX.md) | matching feature doc under `docs/` |
| New or changed CLI script or flag | [README.md → Common Commands](../../README.md#common-commands), [docs/universal-fleet-manual.md → Daily Commands](../universal-fleet-manual.md#daily-commands) | per-feature doc, examples, tests |
| New or changed config key in a project profile | [docs/universal-fleet-manual.md](../universal-fleet-manual.md) | [README.md → Project Profile Contract](../../README.md#project-profile-contract), examples |
| New or changed orchestrator workflow | [docs/architecture.md](../architecture.md), [docs/orchestrator-injected-rules.md](../orchestrator-injected-rules.md) | runbooks, dispatch-planning |
| New or changed validation grade or evidence flow | [docs/validation/README.md](../validation/README.md) | CSV-09, CSV-10, CSV-VAL-01 traceability |
| New or changed GxP or Six Sigma optional layer | this page, [docs/INDEX.md](../INDEX.md) | downstream generator templates and tests |
| New generated downstream artefact | [docs/project-scaffold.md](../project-scaffold.md) or generator-module doc | this page (Generated downstream docs section) |

The matrix is the contract for the documentation impact gate planned in epic
#257 (issue #260). When the gate ships, it will read this matrix to decide
whether a PR's docs touch is sufficient.

## Discoverability rules

- Every document must be reachable from [docs/INDEX.md](../INDEX.md).
- Every document must list its audience and its category at the top, or be
  reachable from a parent page that does.
- New documents added to `docs/` must be linked from this architecture page or
  from the validation index, otherwise they are orphan and must be removed.
- File renames must keep the old path resolvable for at least one minor release
  through redirects in [docs/INDEX.md](../INDEX.md).

## Change history

This page is a living map. When a document is added, removed, or moved, update
the relevant category section here and the change-trigger matrix entry, then
update [docs/INDEX.md](../INDEX.md) so the navigation reflects reality.

Issues that govern documentation architecture changes:

- Parent epic: [#257](https://github.com/RBOKproject/ORDO/issues/257) — build
  ORDO documentation system and automated downstream docs generation.
- This page: [#258](https://github.com/RBOKproject/ORDO/issues/258) — define
  ORDO documentation architecture and information map.
- Sibling work: #259 (install/integration/usage), #260 (docs impact gate),
  #261 (reusable generator), #262 (templates and examples), #263 (verification).
