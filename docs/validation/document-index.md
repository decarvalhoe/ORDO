# ORDO Validation Document Index

This index is the working CSV document register for the ORDO validation
dossier. Stable CSV IDs are the primary traceability keys; issue numbers remain
live work links.

## Current Dossier Disposition

| Field | Current value |
| --- | --- |
| Final validation decision | `FINAL VALIDATION RELEASE REFUSED` |
| Production readiness | `NOT PRODUCTION READY` |
| Release status | `NOT RELEASED` |
| OQ status | `NOT RELEASED TO PQ` |
| PQ status | Stopped at `PQ-001`; `PQ-002` through `PQ-016` not executed |
| Open deviations | `DEV-OQ-001`, `DEV-PQ-001` |
| Current operations procedure | CSV-OPS-01 governs blocked-state controls and future released-state controls |

The register therefore documents a reviewable, blocked dossier. It must not be
used as evidence that ORDO is production-ready or validated for regulated use.

Owner roles are generic:

- Validation owner: owns VMP, protocols, reports, traceability, and release
  reconciliation.
- System owner: owns intended use, production readiness, and validated-state
  acceptance.
- Technical owner: owns configuration, execution evidence, baseline details,
  and technical verification.
- Quality reviewer: owns independent review, deviation disposition, CAPA, and
  approval checks.
- Operations owner: owns change, incident, CAPA, periodic review, and
  revalidation triggers.

## Lifecycle Register

| Order | CSV ID | Issue | Document | Depends on | Primary owner | Current status | Approval route | Evidence location |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 01 | CSV-01 | #64 | Intended use and regulated impact statement | #63 | System owner | Drafted | System owner + quality reviewer | `docs/validation/csv-01-intended-use.md` |
| 02 | CSV-02 | #65 | System boundaries and configuration item inventory | CSV-01 | Technical owner | Drafted | Technical owner + validation owner | `docs/validation/csv-02-boundaries-inventory.md` |
| 03 | CSV-03 | #66 | Roles, responsibilities, training, and approval matrix | CSV-01 | Validation owner | Drafted | Validation owner + quality reviewer | `docs/validation/csv-03-roles-training-approval.md` |
| 04 | CSV-04 | #67 | Supplier and service provider assessment | CSV-02 | Quality reviewer | Drafted | Quality reviewer + system owner | `docs/validation/csv-04-supplier-assessment.md` |
| 05 | CSV-05 | #68 | Data integrity and electronic record assessment | CSV-01, CSV-02 | Validation owner | Drafted | Validation owner + quality reviewer | `docs/validation/csv-05-data-integrity-records.md` |
| 06 | CSV-05A | #87 | Digitally signed agent evidence and attestation model | CSV-03, CSV-05 | Validation owner | Drafted control model | Validation owner + quality reviewer + technical owner | `docs/validation/csv-05a-agent-evidence-attestation.md` |
| 07 | CSV-06 | #69 | Quality risk assessment and criticality matrix | CSV-04, CSV-05, CSV-05A | Validation owner | Drafted | Validation owner + quality reviewer | `docs/validation/csv-06-risk-criticality.md` |
| 08 | CSV-07 | #70 | User requirements and acceptance criteria | CSV-01, CSV-06 | System owner | Drafted | System owner + validation owner | `docs/validation/csv-07-requirements-acceptance.md` |
| 09 | CSV-08 | #71 | Traceability matrix template | CSV-06, CSV-07 | Validation owner | Drafted | Validation owner + quality reviewer | `docs/validation/csv-08-traceability-template.md` |
| 10 | CSV-09 | #72 | Validation plan and protocol strategy | CSV-01 through CSV-08, CSV-05A | Validation owner | Drafted | Validation owner + quality reviewer + system owner | `docs/validation/csv-09-validation-strategy.md` |
| 11 | CSV-10 | #73 | Design/configuration specification and controlled baseline | CSV-02, CSV-07, CSV-09 | Technical owner | Drafted | Technical owner + validation owner | `docs/validation/csv-10-controlled-baseline.md` |
| 12 | CSV-IQ-01 | #74 | IQ protocol | CSV-09, CSV-10 | Validation owner | Drafted | Validation owner + quality reviewer | `docs/validation/csv-iq-01-protocol.md` |
| 13 | CSV-IQ-02 | #75 | Executed IQ evidence pack | CSV-IQ-01, CSV-05A | Technical owner | Executed IQ evidence | Technical owner + validation owner review | `docs/validation/evidence/csv-iq-02/` |
| 14 | CSV-IQ-03 | #76 | IQ report and release to OQ | CSV-IQ-02 | Validation owner | IQ released to OQ | Validation owner + quality reviewer + system owner | `docs/validation/csv-iq-03-report.md` |
| 15 | CSV-OQ-01 | #77 | OQ protocol for operational gate semantics | CSV-IQ-03, CSV-06, CSV-07, CSV-08, CSV-05A | Validation owner | Drafted | Validation owner + quality reviewer | `docs/validation/csv-oq-01-protocol.md` |
| 16 | CSV-OQ-02 | #78 | Executed OQ evidence and deviation log | CSV-OQ-01, CSV-05A | Technical owner | Blocked at `OQ-001` | Technical owner + validation owner + quality reviewer | `docs/validation/evidence/csv-oq-02/` |
| 17 | CSV-OQ-03 | #79 | OQ report and release to PQ | CSV-OQ-02 | Validation owner | `NOT RELEASED TO PQ` | Validation owner + quality reviewer + system owner | `docs/validation/csv-oq-03-report.md` |
| 18 | CSV-PQ-01 | #80 | PQ protocol for production-like multi-agent wave | CSV-OQ-03, CSV-05A | Validation owner | Drafted protocol only | Validation owner + system owner + quality reviewer | `docs/validation/csv-pq-01-protocol.md` |
| 19 | CSV-PQ-02 | #81 | Executed PQ production evidence pack | CSV-PQ-01, CSV-05A | Technical owner | Blocked at `PQ-001` | Technical owner + validation owner review | `docs/validation/evidence/csv-pq-02/` |
| 20 | CSV-PQ-03 | #82 | PQ report and production readiness decision | CSV-PQ-02 | System owner | `NOT PRODUCTION READY`; `NOT RELEASED` | System owner + validation owner + quality reviewer | `docs/validation/csv-pq-03-report.md` |
| 21 | CSV-VAL-01 | #83 | Final traceability matrix and evidence reconciliation | CSV-IQ-03, CSV-OQ-03, CSV-PQ-03, CSV-05A | Validation owner | Blocked non-release reconciliation | Validation owner + quality reviewer | `docs/validation/csv-val-01-final-traceability.md` |
| 22 | CSV-VAL-02 | #84 | Final validation report and release package | CSV-VAL-01 | Validation owner | Final validation release refused | System owner + validation owner + quality reviewer | `docs/validation/csv-val-02-final-report.md` |
| 23 | CSV-OPS-01 | #85 | Maintaining validated state: change, incident, CAPA, and periodic review | CSV-VAL-02 | Operations owner | Active blocked-state procedure | Operations owner + system owner + quality reviewer | `docs/validation/csv-ops-01-maintaining-validated-state.md` |
| 24 | FEAT-CSV-DEV-MODE | #86 | CSV development mode and validation dossier generator | Manual CSV reference dossier | Technical owner | Implemented scaffold; not validation authority | Technical owner + validation owner + system owner | `docs/validation/csv-development-mode.md` |

## Phase Gates

| Phase | Entry evidence | Current exit evidence | Current state | Next phase |
| --- | --- | --- | --- | --- |
| Foundation | CSV-01 scope decision and VMP/index | Draft foundation package exists | Supports protocol planning only | IQ |
| IQ | CSV-09 strategy, CSV-10 baseline, CSV-05A evidence controls | CSV-IQ-03 accepts IQ as completed input | Released to OQ | OQ |
| OQ | IQ report and mapped risks/requirements | CSV-OQ-03 records `NOT RELEASED TO PQ` | Blocked by `DEV-OQ-001` | No PQ release |
| PQ | Approved OQ report or approved waiver/deviation route | CSV-PQ-03 records `NOT PRODUCTION READY` and `NOT RELEASED` | Blocked by `DEV-PQ-001`; stopped at `PQ-001` | No final release |
| Final validation | Approved IQ/OQ/PQ reports and dispositioned deviations | CSV-VAL-02 refuses final validation release | Blocked non-release package | CSV-OPS-01 blocked-state governance |
| Maintaining state | Current blocked disposition or future approved release | CSV-OPS-01 procedure | Active for blocked state; future released-state controls are conditional | Continued blocked-state review or future revalidation |

## Traceability Rules

- Every protocol step must cite at least one CSV requirement, risk, or control.
- Every test result must cite the protocol step, command or action summary,
  actor role, timestamp, repository revision, and evidence artifact reference.
- Every failed or skipped step must create or link a deviation record.
- Every deviation must be closed, accepted with rationale, or linked to CAPA
  before the next phase report can approve phase release.
- Every phase report must state whether it releases to the next phase, blocks
  release, or releases with documented limitations.
- No document may invent human approval, waiver, or release based on generated
  text, green checks, or mechanical attestation alone.

## Status Values

Use these status values consistently when the index is maintained:

- Planned: issue exists but the artifact is not drafted.
- Drafted: artifact exists but has not been independently reviewed.
- Drafted control model: control model exists but does not prove executed
  downstream evidence.
- Executed IQ evidence: IQ execution evidence exists and is accepted as IQ
  input only.
- IQ released to OQ: IQ report permits OQ entry, without implying OQ/PQ success.
- Blocked: execution or release cannot continue until deviation or entry-gate
  evidence is dispositioned.
- Blocked non-release reconciliation: traceability exists only for a blocked
  package.
- Final validation release refused: final validation package is not released.
- Active blocked-state procedure: procedure governs the current non-release
  state and future released-state controls.
- Implemented scaffold; not validation authority: feature exists but cannot
  approve, waive, validate, or release.
- Approved: artifact is accepted and may be used as phase evidence.
- Superseded: artifact was replaced by a later approved revision.
- Not applicable: artifact is explicitly out of scope with documented
  rationale.

## Evidence Location Rules

- Evidence directories must contain a manifest or report explaining what each
  artifact proves.
- Secret values, private credentials, live host paths, account names, provider
  tokens, and deployment-specific private material must not be stored in the
  validation dossier.
- External evidence may be referenced by immutable URL, run ID, release ID,
  checksum, or signed attestation, but the reference must remain reviewable for
  the required retention period.
- Critical missing or unverifiable evidence remains deviation-routed unless
  responsible review records a non-critical classification with rationale.
