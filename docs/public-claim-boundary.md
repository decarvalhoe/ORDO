# Public claim boundary

This page states what ORDO may and may not claim in its public documentation,
and where each boundary is enforced. It exists so that every capability
statement in this repository maps to verifiable evidence rather than
aspiration. It is the contract behind the impartiality principle of the
[external assessment pack](external-assessment/README.md).

This page describes discipline that already exists in the repository (the
"evidence before claims" operating principle, the validation dossier, and the
evidence-gating code and CI). It does not introduce new governance.

## The rule: every claim maps to evidence

ORDO's operating principle is **evidence before claims** (see
[README.md → Operating Principles](../README.md#operating-principles)). A
statement that ORDO *does* something must be traceable to one of:

- a tracked script or library function, with a test that exercises it;
- a CI gate that runs on every pull request;
- a generated artifact or recorded run;
- or a named gap (a documented limitation, deviation, or roadmap item).

A statement that cannot be traced to one of these belongs on the roadmap and is
labelled as such, or it is removed.

## Reserved status labels

These labels are used precisely and consistently across the documentation. They
distinguish delivered scope from forward-looking scope.

| Label | Meaning |
| --- | --- |
| `NOT RELEASED` / `NOT PRODUCTION READY` | The CSV validation dossier has not been released for regulated production use. Controlling record: [docs/validation/csv-val-02-final-report.md](validation/csv-val-02-final-report.md). |
| `NOT VALIDATED` | A generated dossier artifact is a draft template, not an approved validation record. |
| opt-in / off by default | A capability exists and is tested, but stays disabled unless a project profile explicitly enables it (for example the autonomous PR-ops runner, the Six Sigma Level 2 module, and the autonomous orchestrator loop). |
| reserved / future | A code path is named but deliberately refused until a later iteration (for example the `autonomous` mode of the `dispatch_pr_ops.sh` dispatcher, distinct from the shipped `scripts/autonomous_pr_ops.sh` runner). |

## What ORDO does not claim

- **No validated or production-grade deployment.** A software release of this
  repository is not a validated release decision. The dossier explicitly
  refuses final validation while OQ/PQ evidence and approvals are incomplete
  (open deviations `DEV-OQ-001` and `DEV-PQ-001`).
- **No fully autonomous operation by default.** The autonomous orchestrator
  loop (`scripts/orch_loop.sh`) and the autonomous PR-ops runner
  (`scripts/autonomous_pr_ops.sh`) are opt-in and gated; the documented default
  is operator-driven.
- **No platform-scale guarantee.** The fleet is enumerated explicitly in a
  project profile; ORDO coordinates the agents an operator configures, not an
  auto-discovered or auto-scaled pool.
- **No self-assessment of value.** This repository states no monetary or
  strategic value. Neutral valuation inputs for an external analyst are isolated
  in [docs/external-assessment/valuation-inputs.md](external-assessment/valuation-inputs.md).

## Where the boundary is enforced

- The validation dossier ([docs/validation/](validation/)) holds the release
  disposition and the open deviations.
- Evidence-gating code refuses claims without proof at runtime — for example
  the gated merge (`lib/pr_merge.sh`), the closure-acceptance gate
  (`scripts/post_merge_cleanup.sh`), dispatch routing refusals
  (`lib/dispatch_router.sh`), and the documentation impact gate
  (`scripts/docs_impact_gate.sh`).
- CI runs `scripts/run_shellcheck.sh`, `scripts/run_shell_tests.sh`, and
  `scripts/run_bats.sh` on every pull request to `main`.
