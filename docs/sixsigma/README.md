# ORDO Six Sigma Architecture

This page is the durable architecture map for ORDO Six Sigma material. It
defines the two levels of the architecture, the boundary between them, and the
boundary between any Six Sigma evidence ORDO produces and the human approval
that turns evidence into a release or validation decision.

The two levels are intentionally separated so Level 1 can be relied on as
standard ORDO cycle behavior without a project also opting into Level 2, and so
Level 2 can be activated per project without redefining what ORDO standard
cycles already provide.

## Level 1 — ORDO standard (mandatory)

Level 1 is **Six Sigma Auto Upgrade**: the continuous-improvement loop that
every ORDO operator cycle dry-runs or runs.

- Source-of-truth doc: [../sixsigma-autoupgrade.md](../sixsigma-autoupgrade.md).
- Entry point: `bash scripts/sixsigma_autoupgrade.sh <project-config>`.
- Companion entry points: `bash scripts/pr_block_signals.sh <project-config>`
  for silent-blocker signals and `bash scripts/gh_actions_optimize.sh
  <project-config> --audit` for the GitHub Actions process audit.
- Status: part of the ORDO standard — not optional, not project-scoped, not
  configurable to "off".
- Signals it produces: autofix dispatches against red PR checks, silent-blocker
  rows for stuck PRs, GitHub Actions optimizer findings, dry-run previews of
  every mutating action.
- What it intentionally does **not** do: it does not approve, release,
  waive, validate, or mark a phase complete. It does not authorize a merge
  by itself; merge remains the responsibility of the gated merge tooling
  documented in [../sixsigma-autoupgrade.md#merge-doctrine](../sixsigma-autoupgrade.md#merge-doctrine).

Project profiles can tune the documented `SIXSIGMA_*` knobs (max autofix
dispatches per cycle, whether agents push their own branches, optimizer
toggle). They cannot disable Level 1 itself; turning every knob off would
still leave the operator-driven cycle obligation in place.

## Level 2 — Opt-in project DMAIC module

Level 2 is the **opt-in project DMAIC module**: an auditable Define / Measure
/ Analyze / Improve / Control dossier a single project can choose to
maintain. It is disabled by default and is activated per project through a
project-profile opt-in.

- Status: opt-in per project. Default state is disabled. ORDO cycles do not
  generate Level 2 records unless the owning project profile has explicitly
  activated the module.
- Scope: scaffold and maintain DMAIC records — for example, a Define charter,
  Measure baselines, Analyze findings, Improve experiments, Control plans —
  alongside the ORDO repository's existing controlled-validation dossier.
- Boundary with Level 1: Level 2 consumes Level 1 telemetry as one of its
  inputs (autofix dispatch counts, optimizer findings, silent-blocker rows
  per cycle). Level 2 never replaces Level 1 and never re-defines what Level
  1 already records.
- Boundary with the controlled validation track: Level 2 is a project
  improvement record, not a regulated-validation record. The controlled
  validation track lives under [../validation/](../validation/) and is
  governed by IQ/OQ/PQ protocols, deviations, and accountable human approval.
  Level 2 records can reference the controlled track but cannot stand in for
  it.

The companion ORDO subissues (sibling subscope under the parent epic, kept
out of this issue per its atomic-scope constraint) are the implementation
surfaces for Level 2: the DMAIC base templates, the project module scaffold
CLI, the config helper, the evidence ledger helper, the DMAIC gate helper,
the metric evidence collector, the by-design brief injection, the programming
run wrapper, and the verification/release-evidence harness. This README is
the architecture page they all reference; their CLIs and behaviors are
documented in their own files when each subissue lands.

## Approval boundary

The single load-bearing rule for both levels:

> ORDO Six Sigma material — Level 1 telemetry **and** Level 2 DMAIC records
> alike — is mechanical evidence. It never authors an approval, release,
> waiver, validation, or phase-completion claim on behalf of a human.

Concretely, that means:

- Generated Level 1 reports (autofix logs, optimizer findings, silent-blocker
  signals) are evidence inputs only.
- Generated Level 2 dossiers (DMAIC templates, evidence ledger rows, metric
  rollups) state, on every page where a status is rendered, that approval is
  separate, that release status is `NOT RELEASED` until a controlled human
  decision changes that state, and that validation decisions are `not made
  by generator`.
- The keywords `RELEASED`, `APPROVED`, `WAIVED`, `VALIDATED`, `PHASE COMPLETE` must never appear as the active status of a generated Six Sigma page. They may appear only when the same line also negates them (for example `NOT RELEASED`, `NOT APPROVED`) or when quoting an external controlled record authored by an accountable human.
- Tests guard this boundary by reading the published Six Sigma docs and
  refusing language patterns that would erase it; see
  [`tests/test_sixsigma_project_module.sh`](../../tests/test_sixsigma_project_module.sh).

## Neutrality constraints

Both levels follow the same ORDO neutrality rules: no live repository, org,
account, host, user, provider, vendor, session, pane, or path identifiers
appear in this docs tree. Concrete examples in any future Level 2 templates
must use placeholders (for example, `<project-config>`, `<agent-pane>`,
`<workdir>`) and link out to the project profile contract documented in the
top-level [README](../../README.md#project-profile-contract).

## Cross-references

- Architecture entry point in the documentation map:
  [docs/architecture/README.md](../architecture/README.md).
- Documentation index entry:
  [docs/INDEX.md](../INDEX.md).
- Controlled validation entry point: [docs/validation/README.md](../validation/README.md).
- Related runbooks: [docs/runbooks/README.md](../runbooks/README.md).
