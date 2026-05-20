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

# ORDO Six Sigma Module

Entry-point documentation for the ORDO Six Sigma module. Tracks epic
#236 "ORDO Six Sigma
compliance and DMAIC project module".

The module has two layers:

- **Level 1 — ORDO standard.** A mandatory continuous-improvement loop
  that runs on every cycle. Treated as standard ORDO behavior, not an
  opt-in feature.
- **Level 2 — opt-in project DMAIC module.** Per-project Define / Measure
  / Analyze / Improve / Control dossier scaffold + helpers. Disabled by
  default; activated through project profile metadata.

Doctrine constraint (epic #236): generated artifacts must NEVER claim
human approval, release, waiver, validation, or phase-completion on
behalf of an operator. Generated evidence is auditable input to a human
decision; it is not the decision.

## Level 1 — ORDO standard cycle

The Six Sigma auto-upgrade loop is part of every standard ORDO cycle on
both the explicit and daemon paths (see
issue #245, closed):

| Path                 | Hook                                                                     | Behavior                                                                                |
| -------------------- | ------------------------------------------------------------------------ | --------------------------------------------------------------------------------------- |
| Explicit cycle       | `scripts/cycle.sh` step 1b — runs after `check_ci_health.sh` (default branch) | Forwards `--dry-run`. Failure emits `CYCLE <wave> SIXSIGMA WARN ...` and continues.    |
| Daemon loop          | `scripts/orch_loop.sh` per cycle — runs after the supervisor cycle, before the heartbeat | Honors `ORCH_DRY_RUN`. Failure emits `ORCH_LOOP SIXSIGMA WARN cycle=N ...` and continues. |

Operator commands:

```bash
# Inspect proposed self-improvement dispatches without mutating state.
bash scripts/sixsigma_autoupgrade.sh <project-config> --dry-run

# Run the loop directly (the cycle wrappers do this automatically).
bash scripts/sixsigma_autoupgrade.sh <project-config>
```

Opt-out for constrained hosts:

```bash
ORCH_SIXSIGMA_DISABLED=1 bash scripts/cycle.sh ...
ORCH_SIXSIGMA_DISABLED=1 bash scripts/orch_loop.sh ...
```

Audit lines emitted by the wrappers:

```text
CYCLE <wave> SIXSIGMA OK project=<project>
CYCLE <wave> SIXSIGMA WARN — sixsigma_autoupgrade.sh exited non-zero project=<project> (cycle continues)
ORCH_LOOP SIXSIGMA OK cycle=<n> project=<project>
ORCH_LOOP SIXSIGMA WARN cycle=<n> project=<project> (cycle continues)
```

Full operating contract for the loop itself: see
[`docs/sixsigma-autoupgrade.md`](../sixsigma-autoupgrade.md).

## Level 2 — opt-in project DMAIC module

The Level 2 module is the opt-in DMAIC project scaffold. It is being
built incrementally under epic #236; the children below are tracked and
will be linked here as they land:

| Topic                                  | Tracking issue                                              |
| -------------------------------------- | ----------------------------------------------------------- |
| Six Sigma architecture doc             | #237      |
| Six Sigma document index               | #238      |
| DMAIC base templates                   | #239      |
| Six Sigma config helper                | #240      |
| Six Sigma evidence ledger helper       | #241      |
| DMAIC gate helper                      | #242      |
| Project module scaffold CLI            | #243      |
| Auditable Six Sigma metric evidence    | #244      |
| Six Sigma by design brief injection    | #246      |
| Programming-run wrapper                | #247      |

Activation contract (planned):

- Per-project enable through profile metadata (default: disabled).
- Generated evidence is auditable input only; never claims approval,
  release, waiver, validation, or phase completion on behalf of an
  operator.
- Live identifiers (repo, org, account, host, user, provider, vendor,
  session, pane, path) MUST stay out of module files — see the
  [verification](#verification) section.

### Programming-run commands (placeholder)

The programming-run wrapper (#247) and its dependencies (#246, #244,
#241) are not yet implemented. When they land, the canonical operator
invocations will be:

```bash
# Scaffold the per-project DMAIC dossier (one-time, opt-in).
# Tracking: #243
bash scripts/sixsigma_project_scaffold.sh <project-config>

# Run a single Six Sigma programming-run cycle for a ticket
# (Define -> Measure -> Analyze -> Improve -> Control).
# Tracking: #247
bash scripts/sixsigma_programming_run.sh <project-config> <ticket>

# Append a measurement row to the project DMAIC evidence ledger.
# Tracking: #241, #244
bash scripts/sixsigma_evidence_append.sh <project-config> <metric> <value>
```

The placeholders are listed here so this README stays the canonical
entry-point as each sibling lands. The corresponding scripts will only
exist after their tracking issues close — `bash --help` is the
authoritative source for arguments at that point.

## Verification

The test surface for the Six Sigma module is wired into the standard
ORDO shell-test runner:

```bash
bash scripts/run_shell_tests.sh
```

Currently registered Six Sigma tests:

- `tests/test_sixsigma_autoupgrade.sh` — unit coverage for
  `sixsigma_autoupgrade.sh` plus the cycle.sh integration cases
  (success, failure-warn, opt-out) added under #245.

When a Level 2 sibling lands a new test, register it in the `TESTS`
array of `scripts/run_shell_tests.sh` in the same PR. The
`tests/test_exit_codes_manifest.sh` drift guard already enforces
that any new `ORCH_*_EXIT_CODE` is mirrored in
[`docs/exit-codes.md`](../exit-codes.md) — Six Sigma helpers MUST
follow the same convention.

### Final-checks live-identifier scan

Per epic constraint, ORDO module files must not carry generic
hardcoded live identifiers (repo, org, account, host, user, provider,
vendor, session, pane, path). Run the following scan before closing
any Six Sigma sibling PR:

```bash
# Scan the Six Sigma module surface for live identifiers. Patterns
# are repo-neutral fragments that should never appear in committed
# module files (sample sets only — extend per project as needed):
grep -nE \
  'RBOKproject|realisonsdotcom|rbok-orchestrator|RBOKCLI[a-z]+|/root/rbokproject-fleet|@example\.invalid' \
  scripts/sixsigma*.sh \
  lib/sixsigma*.sh 2>/dev/null \
  || echo 'live-identifier scan: clean'
```

Expected output for a clean module: `live-identifier scan: clean`.
Any match must be replaced with a configurable env var or a fixture
path under `$BATS_TEST_TMPDIR` / `$TEST_TMP` before the PR can land.

A second scan covers reusable artifact templates (which an operator
copies into their own project and which therefore must not bake in
live identifiers):

```bash
grep -nE \
  'RBOKproject|realisonsdotcom|rbok-orchestrator|RBOKCLI[a-z]+' \
  templates/sixsigma/* 2>/dev/null \
  || echo 'template live-identifier scan: clean'
```

The narrative documentation under `docs/sixsigma/` may legitimately
link to the upstream issue tracker (`github.com/RBOKproject/ORDO/...`);
those URLs are cross-references, not module identifiers, and are
expected. Both scans above are auditable evidence; capture the command
+ output in the PR body or as a comment when a Six Sigma sibling
closes.