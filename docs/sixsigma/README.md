# ORDO Six Sigma Module

Entry-point documentation for the ORDO Six Sigma module. Tracks epic
[#236](https://github.com/RBOKproject/ORDO/issues/236) "ORDO Six Sigma
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
[issue #245](https://github.com/RBOKproject/ORDO/issues/245), closed):

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
| Six Sigma architecture doc             | [#237](https://github.com/RBOKproject/ORDO/issues/237)      |
| Six Sigma document index               | [#238](https://github.com/RBOKproject/ORDO/issues/238)      |
| DMAIC base templates                   | [#239](https://github.com/RBOKproject/ORDO/issues/239)      |
| Six Sigma config helper                | [#240](https://github.com/RBOKproject/ORDO/issues/240)      |
| Six Sigma evidence ledger helper       | [#241](https://github.com/RBOKproject/ORDO/issues/241)      |
| DMAIC gate helper                      | [#242](https://github.com/RBOKproject/ORDO/issues/242)      |
| Project module scaffold CLI            | [#243](https://github.com/RBOKproject/ORDO/issues/243)      |
| Auditable Six Sigma metric evidence    | [#244](https://github.com/RBOKproject/ORDO/issues/244)      |
| Six Sigma by design brief injection    | [#246](https://github.com/RBOKproject/ORDO/issues/246)      |
| Programming-run wrapper                | [#247](https://github.com/RBOKproject/ORDO/issues/247)      |

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
