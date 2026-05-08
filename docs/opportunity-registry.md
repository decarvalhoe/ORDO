# ORDO Opportunity Registry

The opportunity registry is a durable backlog for operational findings that
should become ORDO improvements. It complements live run ledgers: a ledger can
capture a finding at the moment of detection, while the registry stores the
curated opportunity record used for planning, validation, and later CAPA
assessment.

The registry is universal. Do not store live repository names, account names,
host names, provider names, terminal session names, pane identifiers, local
machine paths, or credential material as defaults. Environment-specific values
belong in controlled configuration or linked evidence records.

## Data Model

Each registry line is JSON with schema `ordo.opportunity.v1`.

Required fields:

- `id`: stable opportunity identifier.
- `created_at`: UTC creation timestamp.
- `project`: configured project key.
- `status`: default `proposed`.
- `priority`: planning priority.
- `severity`: impact severity.
- `finding`: observed problem or opportunity.
- `impact`: operational or validation impact.
- `detection_signal`: signal that exposed the finding.
- `remediation_candidate`: safe candidate fix or mitigation.
- `validation_plan`: planned proof for the remediation.
- `linked_evidence`: one or more artifact, issue, run, ledger, or report
  references.
- `source`: optional context label.
- `related_refs`: optional related opportunity, issue, PR, or CAPA references.

The registry intentionally does not inject CAPA operating rules. CAPA
classification and operating-rule injection are separate governance concerns.

## CLI

Preview the default registry path:

```bash
bash scripts/opportunity_registry.sh <project> path
```

Show the JSON schema summary:

```bash
bash scripts/opportunity_registry.sh <project> schema
```

Preview a new opportunity record. This is the default and does not write:

```bash
bash scripts/opportunity_registry.sh <project> add \
  --code OP-001 \
  --finding "Preflight missed an unsafe state" \
  --impact "Automation could continue without a visible blocker" \
  --detection-signal "synthetic preflight report with failed rows" \
  --remediation "add a conservative refusal check" \
  --validation-plan "add negative and positive fixtures" \
  --priority P1 \
  --severity high \
  --evidence "artifact:synthetic-preflight-report"
```

Persist the record only when the operator explicitly chooses to apply:

```bash
bash scripts/opportunity_registry.sh <project> add \
  --code OP-001 \
  --finding "Preflight missed an unsafe state" \
  --impact "Automation could continue without a visible blocker" \
  --detection-signal "synthetic preflight report with failed rows" \
  --remediation "add a conservative refusal check" \
  --validation-plan "add negative and positive fixtures" \
  --priority P1 \
  --severity high \
  --evidence "artifact:synthetic-preflight-report" \
  --apply
```

`ORCH_DRY_RUN=1` or `--dry-run` keeps the command non-mutating even when
`--apply` is supplied.

List registry entries:

```bash
bash scripts/opportunity_registry.sh <project> list
bash scripts/opportunity_registry.sh <project> list --json
```
