# Operator Runbook — ${DG_PROJECT_NAME}

- generated_at: `${DG_GENERATED_AT}`

## Audience

Operators running the project in any environment. For engineers, see
`../developer/overview.md`. For users, see `../user/user-guide.md`.

## Prerequisites Before Operating

1. Confirm the deployment target and ownership.
2. Confirm secrets are managed in the approved secret store; do not store
   secrets alongside this documentation.
3. Confirm observability (logs, metrics, alerts) is wired to the operator
   pager or shared channel.
4. Confirm that documentation reflects the deployed code revision.

## Standard Operations

| Operation | Trigger | Action | Verification |
| --- | --- | --- | --- |
| Health check | per shift / on alert | TODO confirm | TODO confirm |
| Deploy | release event | TODO confirm | TODO confirm |
| Rollback | failed deploy | TODO confirm | TODO confirm |

## Stop Conditions

- Validation grade is unclear (normal-dev vs gxp-grade) and the change is
  user-visible.
- Secrets would be written into source control, evidence, or this pack.
- Integration contract change is not reflected in `../integration/integration-notes.md`.
- Documentation pack is older than the deployed code revision.

## Escalation

Replace this section with the project's actual escalation path. The generator
does not assume an oncall topology.

## Operator-Supplied Context

${DG_OPERATOR_CONTEXT}
