# Controlled Document Policy — ${DG_PROJECT_NAME}

- generated_at: `${DG_GENERATED_AT}`
- gxp_grade_layer: `${DG_GXP_ENABLED}`

## Applicability

This document is generated only when the documentation pack was produced with
`--gxp-grade`. If the pack was generated without that option, this file does
not exist.

## Controlled-Document Expectations

- Each controlled document has a stable identifier, an owner role, an approval
  route, and an evidence location.
- Each controlled document records its current revision, the change request
  that produced it, and the approver of that revision.
- Controlled documents are not edited in place outside the approval route.
- Generated content from this pack must be reconciled with the controlled
  baseline before publication.

## Identifier Register

| Doc ID | Title | Owner | Approval route | Evidence location |
| --- | --- | --- | --- | --- |
| TODO assign | TODO confirm | TODO confirm | TODO confirm | TODO confirm |

## Revision Control

- Major revisions require an approved change request and a re-execution of
  any dependent validation steps.
- Minor revisions require approver acknowledgment and a recorded justification
  for skipping re-execution, when applicable.

## Tooling Boundary

This pack does not implement controlled-document workflow tooling. It records
the policy and the register so the project can wire it into an existing
controlled documentation system.

## Operator-Supplied Context

${DG_OPERATOR_CONTEXT}
