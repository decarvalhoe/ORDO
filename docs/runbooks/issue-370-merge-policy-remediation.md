# Issue #370 — autonomous merge policy remediation

## Incident

On 2026-05-08, the autonomous unblock sweep merged ORDO PRs while their
`statusCheckRollup` reported `validate=FAILURE` on the current head. GitHub
branch protection accepted the merges; ORDO's internal policy did not
catch the gap because the merge audit signature did not pin its decision
to the head SHA, did not record the check evidence it evaluated, and had
no operator-pause control.

## Affected PRs

| PR    | Merged at (UTC)         | `validate` | `docs-impact-gate` |
|-------|-------------------------|------------|--------------------|
| #335  | 2026-05-08T14:49:46Z    | FAILURE    | SUCCESS            |
| #363  | 2026-05-08T14:49:59Z    | FAILURE    | SUCCESS            |
| #364  | 2026-05-08T14:50:03Z    | FAILURE    | SUCCESS            |
| #365  | 2026-05-08T14:50:07Z    | FAILURE    | SUCCESS            |
| #366  | 2026-05-08T14:50:11Z    | FAILURE    | SUCCESS            |
| #284  | (earlier)               | FAILURE    | SUCCESS            |
| #334  | (earlier)               | FAILURE    | SUCCESS            |

## Required validation per affected PR

For each PR above, the post-merge follow-up is:

1. Re-run the `validate` workflow on the merged commit (or the head it
   was based on) and capture the artefact reference in the issue
   tracker. If `validate` now passes on the same scope, the merge was
   correct in outcome but unsafe in process — note the discrepancy in
   the audit ledger.
2. If `validate` still fails on the merged head, open a follow-up PR
   with the test fix or revert. Tag both the original PR and #370 in
   the body so the audit trail links the cause to the remediation.
3. Record the validation result in `docs/audit/` (or the project's
   audit log of record) with timestamp, operator, and evidence URL.

## Policy fix landed in #370

`lib/pr_merge.sh` now refuses merges in the following situations, even
when `gh pr merge --squash` would accept them:

- `validate` (or any other rollup entry) is FAILURE / TIMED_OUT /
  CANCELLED / ACTION_REQUIRED / STARTUP_FAILURE → exit 2 with audit
  line `CI GATE FAILED ... reason=ci-fail`.
- The rollup is empty AND the `PR_MERGE_NO_CHECK_POLICY` opt-in does
  not apply to this PR's scope → exit 11 with audit line
  `POLICY GATE REFUSED ... reason=missing-evidence`.
- The poll loop saw a passing rollup but the final pre-merge re-verify
  sees a different state (a late-completing failed check, a fresh
  push) → exit 11 with audit line
  `POLICY GATE REFUSED ... reason=stale-poll-result` or
  `HEAD SHA CHANGED ...`.
- `PR_MERGE_HOLD=1` or the autonomous-pr-ops kill-switch state file is
  present → exit 10 with audit line `MERGE HELD ...`. Dispatch / fix /
  rebase callers do not consult this gate, so operators can pause
  merges without halting other work.

Every successful merge audit line now includes the head SHA (12-char
prefix) and the rollup evidence (check names + conclusions) so future
reviews can replay the gate from the audit record alone.

## Operator runbook

- **Engage hold**:
  ```
  PR_MERGE_HOLD=1 bash scripts/pr_merge_wave.sh ...
  # or, persistent across sessions:
  scripts/autonomous_pr_ops.sh <project> kill-switch engage --reason "<why>"
  ```
- **Release hold**:
  ```
  scripts/autonomous_pr_ops.sh <project> kill-switch release
  ```
- **Inspect refusal**: every refusal exits non-zero and emits one
  structured audit line; grep for `POLICY GATE REFUSED`,
  `CI GATE FAILED`, `HEAD SHA CHANGED`, or `MERGE HELD` in the
  orchestrator log to locate the head SHA and the evidence the gate
  evaluated.
