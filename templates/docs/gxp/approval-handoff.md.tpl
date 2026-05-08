# Approval Handoff — ${DG_PROJECT_NAME}

- generated_at: `${DG_GENERATED_AT}`
- gxp_grade_layer: `${DG_GXP_ENABLED}`

## Applicability

This document is generated only when the documentation pack was produced with
`--gxp-grade`. The default pack does not include this file.

## Handoff Roles

| Role | Owns |
| --- | --- |
| System owner | intended use, production readiness, validated-state acceptance |
| Validation owner | validation plan, protocols, executed reports, traceability, release reconciliation |
| Technical owner | configuration, baseline, technical execution evidence |
| Quality reviewer | independent review, deviation disposition, CAPA, approval checks |
| Operations owner | change, incident, CAPA, periodic review, revalidation triggers |

Replace generic role names with the project's named roles before the pack is
treated as binding.

## Handoff Gates

| Gate | Inputs | Outputs | Approvers |
| --- | --- | --- | --- |
| Plan -> IQ | approved validation plan, baseline | IQ released to OQ | validation owner + quality reviewer |
| IQ -> OQ | IQ report | OQ released to PQ | validation owner + quality reviewer |
| OQ -> PQ | OQ report | PQ released | system owner + validation owner + quality reviewer |
| PQ -> Release | PQ report, dispositioned deviations | release decision | system owner + validation owner + quality reviewer |
| Release -> Operate | release decision, controlled procedures | validated-state operations | operations owner + system owner |

## Refusal Cases

- Required approver role is missing or has not signed.
- Linked evidence is missing, unsigned, or unreadable.
- Open deviation lacks disposition or CAPA link.
- Generated documentation pack is older than the configuration baseline.

## Operator-Supplied Context

${DG_OPERATOR_CONTEXT}
