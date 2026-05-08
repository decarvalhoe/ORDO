# Metric Evidence Ledger — ${DG_PROJECT_NAME}

- generated_at: `${DG_GENERATED_AT}`
- six_sigma_layer: `${DG_SIXSIGMA_ENABLED}`

## Applicability

This document is generated only when the documentation pack was produced with
`--sixsigma`. The default pack does not include this file.

## Ledger Schema

| Field | Description |
| --- | --- |
| metric_id | Stable identifier for the metric. |
| ctq_ref | Reference to the CTQ entry the metric supports. |
| measurement_system | The instrument or query that produces the metric. |
| sample_window | Window over which the measurement is taken. |
| baseline_value | Baseline observation. |
| current_value | Most recent observation. |
| target | Target value. |
| specification_limits | Lower and upper specification limits. |
| evidence_reference | Link to the underlying record or dataset. |
| approved_by | Role that approved this metric for use. |

## Ledger Entries

| metric_id | ctq_ref | measurement_system | sample_window | baseline_value | current_value | target | specification_limits | evidence_reference | approved_by |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| TODO assign | TODO confirm | TODO confirm | TODO confirm | TODO confirm | TODO confirm | TODO confirm | TODO confirm | TODO confirm | TODO confirm |

## Ledger Maintenance

- Append-only by default; corrections create a new entry that supersedes the
  prior entry and links to it.
- Reviewed at the cadence defined in the control plan.

## Operator-Supplied Context

${DG_OPERATOR_CONTEXT}
