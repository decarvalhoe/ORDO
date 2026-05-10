# Issue #426 - docs audience marker audit

## Purpose

Issue #426 audits the top-level `docs/*.md` files against the audience map in
`docs/INDEX.md`. The goal is to identify where the index implies an audience
but the document does not declare that audience inline near the top of the
file.

This is investigation-only. No audited document content was changed.

## Method

Scope:

- Included: every top-level `docs/*.md` file.
- Excluded: docs in subdirectories, README/Product files outside `docs/`, and
  generated templates.

Checks performed:

1. Read `docs/INDEX.md` and recorded each top-level `docs/*.md` reference.
2. Inferred the owning audience from the INDEX start-here table, document type
   table, and documentation category where each file appears.
3. Checked the first 30 lines of each top-level `docs/*.md` for either
   `Audience: ...` or `<!-- audience: ... -->`.
4. Compared the inferred audience with the declared audience marker.

Audience inference treats category names as follows:

| INDEX signal | Inferred audience |
| --- | --- |
| Start-here row named for an audience | That named audience |
| Installation | Operator, Integrator |
| Integration | Integrator |
| Usage | Operator |
| Operator runbooks | Operator |
| Local-agent handoff | Local-agent author |
| Developer docs | Developer |
| User docs | User |
| API / CLI references | Operator, Developer |
| Generated downstream docs | Integrator, Developer |
| Validation evidence | Validation reviewer |

## Audit matrix

| File | INDEX evidence | Inferred audience | Declared audience in first 30 lines | Gap status |
| --- | --- | --- | --- | --- |
| `docs/INDEX.md` | No self-entry in `docs/INDEX.md`; described by `docs/architecture/README.md` as a new-user entry point. | Unclassified by INDEX self-entry | None | Missing marker; INDEX self-classification gap |
| `docs/architecture.md` | Start Here: Developer; Developer docs | Developer | None | Missing marker |
| `docs/ci-autofix.md` | Usage; Operator docs | Operator | None | Missing marker |
| `docs/controlled-operations.md` | Operator runbooks; API / CLI references; Operator docs | Operator, Developer | None | Missing marker |
| `docs/dispatch-planning.md` | Start Here: Operator; Usage; API / CLI references; Operator docs | Operator, Developer | None | Missing marker |
| `docs/docs-generate.md` | Developer docs | Developer | None | Missing marker |
| `docs/env-diagnostics.md` | Developer docs | Developer | None | Missing marker |
| `docs/exit-codes.md` | Developer docs | Developer | None | Missing marker |
| `docs/external-agent-skills.md` | Integration | Integrator | None | Missing marker |
| `docs/fleet-injected-rules.md` | Developer docs | Developer | None | Missing marker |
| `docs/host-health-runbook.md` | Start Here: Operator; Operator runbooks; API / CLI references; Operator docs | Operator, Developer | None | Missing marker |
| `docs/install.md` | Installation | Operator, Integrator | None | Missing marker |
| `docs/integration.md` | Integration | Integrator | None | Missing marker |
| `docs/issue-pack-handoff.md` | Start Here: Local-agent author; Local-agent handoff; Operator docs | Local-agent author, Operator | None | Missing marker |
| `docs/multi-product-portfolio.md` | Start Here: Integrator; Integration; Operator docs | Integrator, Operator | None | Missing marker |
| `docs/onboarding-multi-project.md` | Integration | Integrator | None | Missing marker |
| `docs/opportunity-registry.md` | Operator runbooks | Operator | None | Missing marker |
| `docs/orchestrator-injected-rules.md` | Start Here: Developer; Developer docs | Developer | None | Missing marker |
| `docs/otel-export.md` | Developer docs | Developer | None | Missing marker |
| `docs/portfolio-poc-plan.md` | Operator runbooks; Operator docs | Operator | None | Missing marker |
| `docs/pr-operations-governance.md` | Usage | Operator | None | Missing marker |
| `docs/pr-ops-controller.md` | Usage | Operator | None | Missing marker |
| `docs/project-meta-context.md` | Integration; API / CLI references; Generated downstream docs | Integrator, Operator, Developer | None | Missing marker |
| `docs/project-scaffold.md` | Integration; API / CLI references; Generated downstream docs | Integrator, Operator, Developer | None | Missing marker |
| `docs/sixsigma-autoupgrade.md` | Usage; API / CLI references; Operator docs; Optional layers | Operator, Developer | None | Missing marker |
| `docs/universal-fleet-manual.md` | Start Here: New user and Operator; Integration; Usage; API / CLI references; Operator docs | User, Operator, Integrator, Developer | None | Missing marker |
| `docs/usage.md` | Usage | Operator | None | Missing marker |
| `docs/visual-verification-lane.md` | Usage | Operator | None | Missing marker |
| `docs/worktree-migration.md` | Operator runbooks; Operator docs | Operator | None | Missing marker |

## Summary

- Top-level `docs/*.md` files audited: 29.
- Files with a declared audience marker in the first 30 lines: 0.
- Files with no declared audience marker in the first 30 lines: 29.
- Inferred-vs-declared disagreements: 0 confirmed, because no file declares an
  audience to compare against.
- INDEX coverage ambiguity: `docs/INDEX.md` does not classify itself in
  `docs/INDEX.md`.

## Required follow-up

1. File one bug issue to add explicit audience markers to all top-level
   `docs/*.md` files. The issue should define the marker format first, then
   apply it consistently using the inferred audiences in this audit matrix.
2. File one bug issue to decide and encode `docs/INDEX.md` self-classification,
   either by adding an explicit inline audience marker only or by also adding a
   self-entry to the index.

## Evidence

- Base audited: `origin/main`
  `9def608e2afacf65d28de0507da9450ec164892c`.
- Issue source: GitHub issue #426 in `RBOKproject/ORDO`.
- Marker scan: first 30 lines of every top-level `docs/*.md` were searched for
  `Audience:` and `<!-- audience: -->`; no matches were found.
