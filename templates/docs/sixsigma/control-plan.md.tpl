# Control Plan — ${DG_PROJECT_NAME}

- generated_at: `${DG_GENERATED_AT}`
- six_sigma_layer: `${DG_SIXSIGMA_ENABLED}`

## Applicability

This document is generated only when the documentation pack was produced with
`--sixsigma`. The default pack does not include this file.

## Control Entries

| Control ID | CTQ ref | Metric ref | Trigger | Action | Owner | Cadence |
| --- | --- | --- | --- | --- | --- | --- |
| TODO assign | TODO confirm | TODO confirm | TODO confirm | TODO confirm | TODO confirm | TODO confirm |

## Drift Response

- Drift outside specification limits opens a drift event linked to the
  improvement backlog (`improvement-backlog.md`).
- Drift inside specification but outside the control band records an early
  warning entry without opening backlog work.

## Reviews

- Routine review at the cadence above.
- Triggered review on every release decision.
- Triggered review on every change to the underlying measurement system.

## Operator-Supplied Context

${DG_OPERATOR_CONTEXT}
