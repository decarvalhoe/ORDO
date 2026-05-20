# Issue #749 — RBOK GitHub Actions hygiene findings tracking

## Purpose

Issue #749 is a tracking record for GitHub Actions hygiene findings on the
downstream `RBOKproject/RBOK` repository that were surfaced through ORDO
log review on 2026-05-11 UTC (parent issue #636,
`ops(logtail): recent ORDO/Codex findings list from 2026-05-11 cleanup`).

ORDO itself owns the auditor (`scripts/gh_actions_optimize.sh`) and the
GHA_OPT audit event class; ORDO does not own the RBOK workflow files. This
runbook is the in-repo, append-only home for the findings, the auditor
contract that produced them, and the resumption path so the next ORDO log
or RBOK CI triage session can resume from durable evidence instead of
re-deriving the state from scrollback.

The findings themselves are durable in three places: the GitHub issue body
(#749), this runbook, and the RBOK-side companion tracking that owns the
fix work (workflow changes land in RBOK, not in ORDO).

## Scope boundary — ORDO tracks, RBOK fixes

The atomized child ticket (#749) leaves the placement explicit:

> If this is intentionally tracked in RBOK instead of ORDO, create/link
> the RBOK-side issue and close this checklist item with that reference.

Placement decision used by this runbook:

- ORDO retains the **audit/tracking** surface for these findings because
  the detector (`scripts/gh_actions_optimize.sh`) and the GHA_OPT audit
  event vocabulary live in ORDO and are the canonical signal source.
- The **remediation** surface (workflow edits, permissions, concurrency,
  branch routing) belongs to the downstream `RBOKproject/RBOK` repository
  because the workflow files themselves are not present in ORDO.
- A RBOK-side companion tracking issue, when opened, must be linked in
  the Tracking matrix below. Until that link is recorded, the findings
  remain owned by ORDO #749 as the single point of truth.

## Source signal — `scripts/gh_actions_optimize.sh`

The GHA hygiene findings reported against RBOK come from the ORDO audit
helper `scripts/gh_actions_optimize.sh --audit`. The script emits a
TAB-separated `severity \t code \t file \t message` line per finding and
also records each line as a `GHA_OPT` audit event via `lib/audit_log.sh`.

The audit-mode emit sites and their detection contract are:

- `gha-missing-permissions` (WARN) — workflow file does not declare a
  top-level or job-level `permissions:` block; least-privilege GITHUB_TOKEN
  scopes are not pinned.
- `gha-missing-concurrency` (WARN) — workflow file does not declare a
  `concurrency:` block; superseded runs cannot be collapsed and duplicate
  CI cost accumulates on PR pushes.
- `gha-pr-push-duplicate-risk` (WARN) — workflow runs on both
  `pull_request:` and `push:` events with `feat/**`, `fix/**`, or
  `feature/**` branch globs, which produces duplicate check runs on PR
  branches.
- `gha-full-tests-on-any-push` (WARN) — workflow keys full
  `pytest --cov` runs to `push` events without distinguishing the default
  branch from feature-branch pushes, so every feature-branch push pays
  the full coverage cost.

The same script also emits secondary INFO/ERROR codes
(`gha-actions-read-missing`, `gha-no-path-filter`, `gha-python-cache-missing`,
`gha-pytest-xdist-missing`, `gha-no-workflows`, `gha-scaffold-*`). They are
out of scope for #749 because the parent log review did not flag them
against RBOK; if a future audit surfaces them, add a new row to the
Findings table below.

## Findings (CAPA-shape)

### F1 — Missing workflow permissions across multiple RBOK workflows

- **Severity:** WARN (least-privilege drift)
- **Auditor code:** `gha-missing-permissions`
- **Evidence:** 2026-05-11 ORDO log tail review surfaced repeated
  `GHA_OPT severity=WARN code=gha-missing-permissions ...` lines for
  multiple files under the RBOK `.github/workflows/` tree.
- **Impact:** workflows run with the repository's default GITHUB_TOKEN
  scopes, which are broader than required. Any workflow that calls
  `gh api` or third-party actions without explicit `permissions:` widens
  the blast radius of a compromised step.
- **Required behavior:** each RBOK workflow file declares a least-privilege
  top-level `permissions:` block (or a per-job `permissions:` override).
  Workflows that call `gh api` for Actions endpoints must include
  `actions: read` per the `gha-actions-read-missing` ERROR rule.
- **Durable tracking:** ORDO #749 (this runbook); the workflow edit
  itself ships in `RBOKproject/RBOK`.

### F2 — Missing concurrency across multiple RBOK workflows

- **Severity:** WARN (duplicate CI load)
- **Auditor code:** `gha-missing-concurrency`
- **Evidence:** 2026-05-11 ORDO log tail review surfaced repeated
  `GHA_OPT severity=WARN code=gha-missing-concurrency ...` lines for
  multiple files under the RBOK `.github/workflows/` tree.
- **Impact:** rapid pushes to the same PR branch leave superseded runs
  executing in parallel with the latest run, burning Actions minutes and
  delaying merge-time CI rollup.
- **Required behavior:** each RBOK workflow declares a `concurrency:`
  block keyed on `${{ github.workflow }}-${{ github.ref }}` (or a more
  specific key) with `cancel-in-progress` enabled for non-default-branch
  refs. The ORDO baseline scaffold in `scripts/gh_actions_optimize.sh`
  (`scaffold_ci`) shows the expected shape.
- **Durable tracking:** ORDO #749 (this runbook); the workflow edit
  itself ships in `RBOKproject/RBOK`.

### F3 — `ci.yml` PR/push duplicate-run risk on feature branches

- **Severity:** WARN (duplicate check runs)
- **Auditor code:** `gha-pr-push-duplicate-risk`
- **Evidence:** 2026-05-11 ORDO log tail review surfaced
  `GHA_OPT severity=WARN code=gha-pr-push-duplicate-risk file=.github/workflows/ci.yml ...`
  against the RBOK CI workflow, indicating the workflow listens on both
  `pull_request:` and `push:` with feature/fix branch globs.
- **Impact:** every push to a PR branch produces two check runs (one for
  `push`, one for `pull_request.synchronize`). The duplicates inflate
  required-check rollups and delay the merge-time view.
- **Required behavior:** the RBOK `ci.yml` should either drop the
  feature/fix branch globs from the `push:` trigger or scope each event's
  job set so PR branches only emit the PR-event check run. The concurrency
  fix from F2 collapses the duplicates only when both runs share a key, so
  this finding is not subsumed by F2.
- **Durable tracking:** ORDO #749 (this runbook); the workflow edit
  itself ships in `RBOKproject/RBOK`.

### F4 — Full coverage tests keyed to any push in `ci.yml`

- **Severity:** WARN (cost / latency)
- **Auditor code:** `gha-full-tests-on-any-push`
- **Evidence:** 2026-05-11 ORDO log tail review surfaced
  `GHA_OPT severity=WARN code=gha-full-tests-on-any-push file=.github/workflows/ci.yml ...`
  against the RBOK CI workflow, indicating `pytest --cov` is keyed to
  `push` events without distinguishing the default branch from feature
  branches.
- **Impact:** every feature-branch push pays the full coverage cost,
  even when a fast PR-event check would suffice. CI minutes and merge
  latency are inflated.
- **Required behavior:** the RBOK `ci.yml` distinguishes default-branch
  pushes (full `pytest --cov`) from feature-branch pushes (fast
  `pytest -n auto --no-cov` or path-filtered subset), following the
  tiered pattern the ORDO scaffold emits in `scripts/gh_actions_optimize.sh`
  (`scaffold_ci`, see the `backend` and `frontend` jobs).
- **Durable tracking:** ORDO #749 (this runbook); the workflow edit
  itself ships in `RBOKproject/RBOK`.

## Tracking matrix

| Finding | Auditor code | Severity | ORDO tracking | RBOK companion |
| --- | --- | --- | --- | --- |
| F1 — missing workflow permissions | `gha-missing-permissions` | WARN | #749 (this runbook) | (record link when opened) |
| F2 — missing concurrency | `gha-missing-concurrency` | WARN | #749 (this runbook) | (record link when opened) |
| F3 — `ci.yml` PR/push duplicate risk | `gha-pr-push-duplicate-risk` | WARN | #749 (this runbook) | (record link when opened) |
| F4 — full tests on any push | `gha-full-tests-on-any-push` | WARN | #749 (this runbook) | (record link when opened) |

When a RBOK-side companion issue is opened, append its URL to the
"RBOK companion" cell of every finding it covers; do not delete the
ORDO tracking column.

## Re-audit recipe

A future ORDO operator can refresh these findings against a checked-out
RBOK working tree without leaving ORDO:

```bash
# From inside this ORDO checkout, against a sibling RBOK working tree.
scripts/gh_actions_optimize.sh <rbok-project-config> \
  --audit \
  --repo-root /path/to/RBOK-checkout
```

The TSV output and the `GHA_OPT` audit lines map directly to the F1–F4
rows above. If a new GHA_OPT code surfaces on the RBOK tree (for example
`gha-actions-read-missing` or `gha-no-path-filter`), open a new finding
row in the table; do not silently fold it into an existing row.

`scripts/gh_actions_optimize.sh --scaffold` is also available, but it is
ORDO-owned tooling and never rewrites a downstream workflow; the
`gha-scaffold-exists` ERROR refuses overwriting an existing `ci.yml`
unless `GHA_OPT_OVERWRITE=1` is set. Any actual workflow edit for RBOK
must be authored in `RBOKproject/RBOK` and reviewed there.

## Resumption checklist for the next session

When this tracking work is resumed (either after a fresh ORDO log review
or after the RBOK companion issue lands):

1. Read this runbook and the linked GitHub issues (#636 parent,
   #749 child, and any RBOK companion) before reasoning about the
   findings.
2. Re-run the audit recipe above against the current RBOK checkout and
   compare the auditor codes to the F1–F4 rows. Add new rows for any
   GHA_OPT code that is now emitted.
3. If a RBOK companion issue has been opened, record its URL in the
   Tracking matrix and reference it from the parent #636 close-out
   comment per the child instruction.
4. Treat the auditor as the source of truth for the ORDO-side findings:
   if a row's auditor code stops emitting against the current RBOK tree,
   mark the row Closed (with the auditor evidence and RBOK companion PR
   reference) rather than deleting it.

## Related rules and runbooks

- `scripts/gh_actions_optimize.sh` — the GHA_OPT auditor and baseline
  CI scaffold that produced the F1–F4 findings.
- `docs/architecture.md` — tiered CI strategy ORDO recommends to
  downstream projects; the F3/F4 remediations follow the same shape.
- `docs/runbooks/issue-387-fleet-outage-findings-handoff.md` — prior
  CAPA-shape findings runbook; this one follows the same structure.
- `docs/orchestrator-injected-rules.md` rule 9 — production CAPA and
  self-improvement capture (the umbrella requirement under which durable
  in-repo findings tracking lives).
