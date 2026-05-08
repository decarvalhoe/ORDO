# Validation Evidence Index — ${DG_PROJECT_NAME}

- generated_at: `${DG_GENERATED_AT}`
- gxp_grade_layer: `${DG_GXP_ENABLED}`
- six_sigma_layer: `${DG_SIXSIGMA_ENABLED}`

## Scope

This is a minimal validation evidence index for normal-dev work.

If `gxp_grade_layer` is `0` (the default), this pack is **not** validation
evidence and does not claim a regulated grade. The project's controlled
documents and validation evidence, if any, live elsewhere and are governed by
their own approval route.

If `gxp_grade_layer` is `1`, see the `../gxp/` folder for controlled-doc,
validation evidence, audit trail, deviation/CAPA, traceability, and approval
handoff sections.

## Normal-Dev Evidence Hooks

| Evidence | Location | Owner |
| --- | --- | --- |
| Test suite results | TODO confirm CI provider | engineering |
| Lint / format results | TODO confirm CI provider | engineering |
| Documentation pack manifest | `../generated.manifest.json` | documentation owner |
| Operator handoff notes | `../operator/operator-runbook.md` | operations owner |

## What This Index Does Not Claim

- It does not assert that the project is validated for regulated use.
- It does not assert that the project meets an external compliance standard.
- It does not substitute for a controlled validation dossier when one is
  required.

## Operator-Supplied Context

${DG_OPERATOR_CONTEXT}
