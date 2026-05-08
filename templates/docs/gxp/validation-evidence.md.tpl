# Validation Evidence — ${DG_PROJECT_NAME}

- generated_at: `${DG_GENERATED_AT}`
- gxp_grade_layer: `${DG_GXP_ENABLED}`

## Applicability

This document is generated only when the documentation pack was produced with
`--gxp-grade`. The default pack does not include this file.

## Validation Evidence Categories

| Category | Description | Owner | Default location |
| --- | --- | --- | --- |
| Intended use | Approved statement of intended use and regulated impact | system owner | `docs/validation/intended-use.md` |
| Requirements | User and functional requirements with acceptance criteria | system owner | `docs/validation/requirements.md` |
| Design / configuration baseline | Controlled configuration of the validated system | technical owner | `docs/validation/baseline.md` |
| IQ evidence | Installation qualification protocol and executed report | validation owner | `docs/validation/iq-protocol.md` |
| OQ evidence | Operational qualification protocol and executed report | validation owner | `docs/validation/oq-protocol.md` |
| PQ evidence | Performance qualification protocol and executed report | validation owner | `docs/validation/pq-protocol.md` |
| Final report | Final validation report and release decision | validation owner | `docs/validation/final-report.md` |

## Evidence Acceptance

- Each evidence artifact must cite the requirement, risk, or control it
  satisfies.
- Each executed step must record the command or action summary, actor role,
  timestamp, repository revision, and evidence artifact reference.
- Each failed or skipped step must create or link a deviation record (see
  `deviation-capa.md`).

## Out of Scope For The Generator

The generator does not produce signed evidence or approve validation
artifacts. It only produces the structure into which controlled evidence is
recorded.

## Operator-Supplied Context

${DG_OPERATOR_CONTEXT}
