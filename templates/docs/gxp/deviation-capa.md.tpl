# Deviation and CAPA Hooks — ${DG_PROJECT_NAME}

- generated_at: `${DG_GENERATED_AT}`
- gxp_grade_layer: `${DG_GXP_ENABLED}`

## Applicability

This document is generated only when the documentation pack was produced with
`--gxp-grade`. The default pack does not include this file.

## Deviation Lifecycle

1. Detect: any failed, skipped, or unexpected step during validation, change
   control, or operational use.
2. Record: open a deviation record with identifier, source step, affected
   requirement or control, severity, evidence reference, and reporter role.
3. Investigate: confirm root cause and downstream impact.
4. Disposition: approve, reject, or defer with justification and approver
   role.
5. Close: link the deviation to its CAPA and to any reissued evidence.

## CAPA Lifecycle

1. Identify the corrective and / or preventive action.
2. Assign the owner role.
3. Plan the action, the verification step, and the verification owner.
4. Execute and record evidence.
5. Verify and close.

## Register Skeleton

| Deviation ID | Source step | Severity | Disposition | Linked CAPA | Status |
| --- | --- | --- | --- | --- | --- |
| TODO assign | TODO confirm | TODO confirm | TODO confirm | TODO confirm | TODO confirm |

## Tooling Boundary

The generator does not own the deviation or CAPA tracker. It records the
expected lifecycle so the project can wire it into an existing quality
management system.

## Operator-Supplied Context

${DG_OPERATOR_CONTEXT}
