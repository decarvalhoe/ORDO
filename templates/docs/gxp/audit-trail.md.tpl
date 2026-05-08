# Audit Trail Expectations — ${DG_PROJECT_NAME}

- generated_at: `${DG_GENERATED_AT}`
- gxp_grade_layer: `${DG_GXP_ENABLED}`

## Applicability

This document is generated only when the documentation pack was produced with
`--gxp-grade`. The default pack does not include this file.

## Audit Trail Requirements

- Every change to a controlled artifact records actor identity, action,
  timestamp (UTC), affected artifact, prior revision, and new revision.
- Audit trail records are append-only and tamper-evident.
- Audit trail retention is at least the longer of the project retention
  policy and any regulatory retention requirement.
- Audit trail review is performed at the cadence required by the regulatory
  context.

## Surfaces That Generate Audit Records

| Surface | Records | Owner |
| --- | --- | --- |
| Source repository | commits, merges, force-push attempts | engineering |
| Build / CI | builds, test runs, deploy events | engineering |
| Documentation generator | regenerations, inputs used, files produced | documentation owner |
| Validation evidence store | evidence creation, approval, deviation, CAPA | validation owner |
| Production runtime | configuration changes, access events | operations owner |

## Operator-Supplied Context

${DG_OPERATOR_CONTEXT}
