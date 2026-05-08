# ORDO Validation Document Index

This index is the working CSV document register for issues #64 through #87. It
uses stable CSV IDs as the primary traceability keys and keeps issue numbers as
live work links. Status values are initial planning states and should be updated
by the owning validation workflow as each artifact is drafted, reviewed,
approved, or retired.

Owner roles are generic:

- Validation owner: owns the VMP, protocols, reports, traceability, and release
  reconciliation.
- System owner: owns intended use, production readiness, and validated-state
  acceptance.
- Technical owner: owns configuration, execution evidence, baseline details, and
  technical verification.
- Quality reviewer: owns independent review, deviation disposition, CAPA, and
  approval checks.
- Operations owner: owns post-release change, incident, CAPA, periodic review,
  and revalidation triggers.

## Lifecycle Register

| Order | CSV ID | Issue | Document | Depends on | Primary owner | Status | Approval route | Planned evidence location |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 01 | CSV-01 | #64 | Intended use and regulated impact statement | #63 | System owner | Planned | System owner + quality reviewer | `docs/validation/csv-01-intended-use.md` |
| 02 | CSV-02 | #65 | System boundaries and configuration item inventory | CSV-01 | Technical owner | Planned | Technical owner + validation owner | `docs/validation/csv-02-boundaries-inventory.md` |
| 03 | CSV-03 | #66 | Roles, responsibilities, training, and approval matrix | CSV-01 | Validation owner | Planned | Validation owner + quality reviewer | `docs/validation/csv-03-roles-training-approval.md` |
| 04 | CSV-04 | #67 | Supplier and service provider assessment | CSV-02 | Quality reviewer | Planned | Quality reviewer + system owner | `docs/validation/csv-04-supplier-assessment.md` |
| 05 | CSV-05 | #68 | Data integrity and electronic record assessment | CSV-01, CSV-02 | Validation owner | Planned | Validation owner + quality reviewer | `docs/validation/csv-05-data-integrity-records.md` |
| 06 | CSV-05A | #87 | Digitally signed agent evidence and attestation model | CSV-03, CSV-05 | Validation owner | Planned | Validation owner + quality reviewer + technical owner | `docs/validation/csv-05a-agent-evidence-attestation.md` |
| 07 | CSV-06 | #69 | Quality risk assessment and criticality matrix | CSV-04, CSV-05, CSV-05A | Validation owner | Planned | Validation owner + quality reviewer | `docs/validation/csv-06-risk-criticality.md` |
| 08 | CSV-07 | #70 | User requirements and acceptance criteria | CSV-01, CSV-06 | System owner | Planned | System owner + validation owner | `docs/validation/csv-07-requirements-acceptance.md` |
| 09 | CSV-08 | #71 | Traceability matrix template | CSV-06, CSV-07 | Validation owner | Planned | Validation owner + quality reviewer | `docs/validation/csv-08-traceability-template.md` |
| 10 | CSV-09 | #72 | Validation plan and protocol strategy | CSV-01 through CSV-08, CSV-05A | Validation owner | Planned | Validation owner + quality reviewer + system owner | `docs/validation/csv-09-validation-strategy.md` |
| 11 | CSV-10 | #73 | Design/configuration specification and controlled baseline | CSV-02, CSV-07, CSV-09 | Technical owner | Planned | Technical owner + validation owner | `docs/validation/csv-10-controlled-baseline.md` |
| 12 | CSV-IQ-01 | #74 | IQ protocol | CSV-09, CSV-10 | Validation owner | Planned | Validation owner + quality reviewer | `docs/validation/csv-iq-01-protocol.md` |
| 13 | CSV-IQ-02 | #75 | Executed IQ evidence pack | CSV-IQ-01, CSV-05A | Technical owner | Planned | Technical owner + validation owner review | `docs/validation/evidence/csv-iq-02/` |
| 14 | CSV-IQ-03 | #76 | IQ report and release to OQ | CSV-IQ-02 | Validation owner | Planned | Validation owner + quality reviewer + system owner | `docs/validation/csv-iq-03-report.md` |
| 15 | CSV-OQ-01 | #77 | OQ protocol for operational gate semantics | CSV-IQ-03, CSV-06, CSV-07, CSV-08, CSV-05A | Validation owner | Planned | Validation owner + quality reviewer | `docs/validation/csv-oq-01-protocol.md` |
| 16 | CSV-OQ-02 | #78 | Executed OQ evidence and deviation log | CSV-OQ-01, CSV-05A | Technical owner | Planned | Technical owner + validation owner + quality reviewer | `docs/validation/evidence/csv-oq-02/` |
| 17 | CSV-OQ-03 | #79 | OQ report and release to PQ | CSV-OQ-02 | Validation owner | Planned | Validation owner + quality reviewer + system owner | `docs/validation/csv-oq-03-report.md` |
| 18 | CSV-PQ-01 | #80 | PQ protocol for production-like multi-agent wave | CSV-OQ-03, CSV-05A | Validation owner | Planned | Validation owner + system owner + quality reviewer | `docs/validation/csv-pq-01-protocol.md` |
| 19 | CSV-PQ-02 | #81 | Executed PQ production evidence pack | CSV-PQ-01, CSV-05A | Technical owner | Planned | Technical owner + validation owner review | `docs/validation/evidence/csv-pq-02/` |
| 20 | CSV-PQ-03 | #82 | PQ report and production readiness decision | CSV-PQ-02 | System owner | Planned | System owner + validation owner + quality reviewer | `docs/validation/csv-pq-03-report.md` |
| 21 | CSV-VAL-01 | #83 | Final traceability matrix and evidence reconciliation | CSV-IQ-03, CSV-OQ-03, CSV-PQ-03, CSV-05A | Validation owner | Planned | Validation owner + quality reviewer | `docs/validation/csv-val-01-final-traceability.md` |
| 22 | CSV-VAL-02 | #84 | Final validation report and release package | CSV-VAL-01 | Validation owner | Planned | System owner + validation owner + quality reviewer | `docs/validation/csv-val-02-final-report.md` |
| 23 | CSV-OPS-01 | #85 | Maintaining validated state: change, incident, CAPA, and periodic review | CSV-VAL-02 | Operations owner | Planned | Operations owner + system owner + quality reviewer | `docs/validation/csv-ops-01-maintaining-validated-state.md` |
| 24 | FEAT-CSV-DEV-MODE | #86 | CSV development mode and validation dossier generator | Manual CSV reference dossier | Technical owner | Backlog | Technical owner + validation owner + system owner | `docs/validation/csv-development-mode.md` |

## Phase Gates

| Phase | Entry evidence | Exit evidence | Next phase |
| --- | --- | --- | --- |
| Foundation | CSV-01 scope decision and issue #63 VMP/index | CSV-01 through CSV-10 approved or justified as not applicable, with CSV-05A ready | IQ |
| IQ | Approved CSV-09 strategy, CSV-10 baseline, and CSV-05A evidence controls | CSV-IQ-03 approved IQ report and release decision | OQ |
| OQ | Approved IQ report and mapped risks/requirements | CSV-OQ-03 approved OQ report and release decision | PQ |
| PQ | Approved OQ report and production-like acceptance criteria | CSV-PQ-03 production readiness decision | Final validation |
| Final validation | Approved IQ/OQ/PQ reports and dispositioned deviations | CSV-VAL-02 final validation report and active CSV-OPS-01 | Maintaining validated state |
| Maintaining validated state | Released validated package | Periodic review, change, incident, CAPA, and revalidation records | Continued use or revalidation |

## Traceability Rules

- Every protocol step must cite at least one CSV requirement, risk, or control.
- Every test result must cite the protocol step, command or action summary,
  actor role, timestamp, repository revision, and evidence artifact reference.
- Every failed or skipped step must create or link a deviation record.
- Every deviation must be closed, accepted with rationale, or linked to CAPA
  before the next phase report is approved.
- Every phase report must state whether it releases the dossier to the next
  phase, blocks release, or releases with documented limitations.

## Approval States

Use these status values consistently when the index is maintained:

- Planned: issue exists but the artifact is not drafted.
- Drafted: artifact exists but has not been independently reviewed.
- In review: artifact is ready for quality or system-owner review.
- Approved: artifact is accepted and may be used as phase evidence.
- Superseded: artifact was replaced by a later approved revision.
- Not applicable: artifact is explicitly out of scope with documented
  rationale.

## Evidence Location Rules

- Planned document paths in this index are placeholders until the owning issue
  creates the artifact.
- Evidence directories must contain a manifest or report that explains what each
  artifact proves.
- Secret values, private credentials, and provider-specific private material
  must not be stored in the validation dossier.
- External evidence may be referenced by immutable URL, run ID, release ID,
  checksum, or signed attestation, but the reference must remain reviewable for
  the required retention period.
