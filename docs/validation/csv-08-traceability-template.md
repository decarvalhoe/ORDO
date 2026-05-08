# CSV-08 Traceability Matrix Template

## Purpose

This document defines the ORDO traceability matrix template for linking
intended use, risks, requirements, design or configuration references,
IQ/OQ/PQ verification, evidence artifacts, deviations, CAPA, and final
validation disposition.

The template is designed to be populated during protocol planning and execution
so CSV-VAL-01 can reconcile the final validation package directly from one
controlled traceability source.

## Scope and Inputs

CSV-08 depends on:

- CSV-01 intended use and regulated impact classification;
- CSV-02 system boundary and configuration item inventory;
- CSV-05 data integrity and electronic record assessment;
- CSV-05A agent evidence attestation model;
- CSV-06 quality risk assessment and criticality matrix;
- CSV-07 user requirements and acceptance criteria.

The matrix does not create requirements, risks, or acceptance criteria by
itself. It records how approved requirements and risks are verified, where
evidence is retained, and how final disposition is reached.

## Traceability Keys

Use stable, human-readable identifiers. Identifiers must not depend on live
repository names, user accounts, hostnames, sessions, panes, or environment
paths.

| Key family | Format | Example | Owner |
| --- | --- | --- | --- |
| Requirement | `URS-###` | `URS-001` | System owner |
| Risk | `RISK-###` | `RISK-014` | Validation owner |
| Control | `CTRL-###` | `CTRL-006` | Technical owner |
| Design or configuration reference | `CFG-###` or document section ID | `CFG-003` | Technical owner |
| IQ test | `IQ-###` | `IQ-004` | Validation owner |
| OQ test | `OQ-###` | `OQ-012` | Validation owner |
| PQ test | `PQ-###` | `PQ-003` | System owner |
| Evidence artifact | `EV-<phase>-###` | `EV-OQ-012` | Protocol executor |
| Deviation | `DEV-###` | `DEV-002` | Validation owner |
| CAPA | `CAPA-###` | `CAPA-001` | Quality reviewer |

## Matrix Columns

The controlled matrix should contain these columns. A deployment may add
columns, but it must not remove required columns after baseline approval without
change-control assessment.

| Column | Required content |
| --- | --- |
| Matrix row ID | Stable row identifier, such as `TM-001`. |
| Requirement ID | One or more `URS-###` IDs or `N/A` with rationale. |
| Requirement summary | Short statement of the requirement being verified. |
| Risk ID | One or more `RISK-###` IDs or `N/A` with rationale. |
| Criticality | Critical, high, medium, low, or not applicable. |
| Control ID | Preventive, detective, or corrective control reference. |
| Design/config reference | CSV-02 or CSV-10 configuration item, design section, or controlled baseline reference. |
| Verification phase | IQ, OQ, PQ, review-only, or not applicable. |
| IQ test ID | Planned or executed IQ test ID, or `N/A`. |
| OQ test ID | Planned or executed OQ test ID, or `N/A`. |
| PQ test ID | Planned or executed PQ test ID, or `N/A`. |
| Acceptance criterion | Objective pass/fail or review criterion. |
| Evidence artifact | Evidence ID, evidence path, immutable reference, checksum, or signed attestation reference. |
| Evidence producer | Human role, protocol executor, or agent CLI actor label. |
| Evidence attribution/integrity | Signature, checksum, attestation ID, or approved deviation reference. |
| Result | Planned, pass, fail, skipped, blocked, superseded, or not applicable. |
| Deviation/CAPA | Linked deviation and CAPA IDs, or `none`. |
| Final disposition | Accepted, accepted with limitation, rejected, superseded, or pending. |
| Reviewer | Role or review record reference. |
| Notes | Bounded rationale, limitations, or follow-up references. |

## Template

Use this table as the baseline matrix structure.

| Matrix row ID | Requirement ID | Requirement summary | Risk ID | Criticality | Control ID | Design/config reference | Verification phase | IQ test ID | OQ test ID | PQ test ID | Acceptance criterion | Evidence artifact | Evidence producer | Evidence attribution/integrity | Result | Deviation/CAPA | Final disposition | Reviewer | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| TM-001 | URS-001 |  | RISK-001 |  | CTRL-001 | CFG-001 | IQ/OQ/PQ | IQ-001 | OQ-001 | PQ-001 |  | EV- |  |  | Planned | none | Pending |  |  |

## Critical Requirement Rule

Every critical requirement must have at least one planned verification row before
protocol execution begins. The row must include:

- requirement ID and risk ID;
- criticality;
- design or configuration reference;
- verification phase;
- protocol test ID;
- objective acceptance criterion;
- expected evidence artifact location or naming pattern;
- evidence attribution and integrity expectation;
- deviation handling route.

A critical requirement may be marked `review-only` only when the validation
owner documents why scripted or operational verification is not feasible and the
quality reviewer accepts the rationale before execution.

## Protocol Naming Convention

Protocol IDs should use the phase prefix and a three-digit sequence:

| Protocol type | Naming pattern | Example |
| --- | --- | --- |
| IQ protocol step | `IQ-###` | `IQ-001` |
| OQ protocol step | `OQ-###` | `OQ-001` |
| PQ protocol step | `PQ-###` | `PQ-001` |
| Review-only verification | `REV-###` | `REV-001` |

Protocol documents may group steps by feature, control, or risk family, but each
executable or reviewable step must retain its stable ID after approval.

If a protocol step is split, keep the original ID as retired or superseded and
create new IDs for the replacement steps. Do not reuse retired IDs.

## Evidence Naming Convention

Evidence IDs should bind to the phase and protocol step.

| Evidence type | Naming pattern | Example |
| --- | --- | --- |
| IQ evidence | `EV-IQ-<step>-<sequence>` | `EV-IQ-001-01` |
| OQ evidence | `EV-OQ-<step>-<sequence>` | `EV-OQ-001-01` |
| PQ evidence | `EV-PQ-<step>-<sequence>` | `EV-PQ-001-01` |
| Review evidence | `EV-REV-<step>-<sequence>` | `EV-REV-001-01` |
| Deviation evidence | `EV-DEV-<deviation>-<sequence>` | `EV-DEV-001-01` |

Evidence artifact references should be stable and reviewable. Acceptable
references include controlled evidence-store paths, immutable repository
artifacts, CI provider run identifiers, issue tracker records, repository
platform review records, signed attestations, checksums, or approved archive
references.

Evidence records must not contain secret values. References to a secret store
should identify only the approved secret class or control record, not the secret
material.

## Agent-Produced Evidence and #87 Dependency

Agent-produced evidence is mechanical evidence. It can support traceability only
when it is attributable and integrity-protected at a level appropriate to the
row criticality.

Until CSV-05A and issue #87 are implemented and approved, each row that relies
on agent-produced evidence must state one of these dispositions:

- signed or attested according to the approved evidence model;
- checksum captured and independently reviewed as interim supporting evidence;
- human reviewer reproduced or independently verified the evidence;
- deviation opened because required attribution or integrity verification is
  missing or failed;
- classified as non-critical supporting material with validation-owner rationale.

Human approval remains a separate accountable decision. A cryptographic
signature, checksum, or agent attestation can support artifact integrity and
origin, but it does not replace validation-owner, system-owner, or quality-review
approval where approval is required.

## Deviation and CAPA Linkage

Create or link a deviation when:

- a protocol step is not executed as approved;
- expected evidence is missing, incomplete, or not reviewable;
- a required command, action, signature, checksum, or attestation fails;
- observed behavior conflicts with an acceptance criterion;
- evidence is produced from an unapproved baseline or uncontrolled actor;
- a row cannot be reconciled to final disposition.

CAPA linkage is required when the deviation is critical, recurring, systemic,
or caused by an ineffective control. The matrix should show the latest
deviation or CAPA disposition, while the deviation record remains the detailed
source of impact assessment, correction, retest, and preventive action.

## Adding Future Requirements

New requirements must not overwrite or renumber approved rows. Add future
requirements by following this rule:

1. Create a new `URS-###` requirement ID in the controlled requirement source.
2. Assess or create linked `RISK-###` and `CTRL-###` entries.
3. Add new `TM-###` rows at the end of the matrix or in the next available
   controlled block.
4. Mark affected prior rows as superseded only when the new row replaces them.
5. Record the change-control or issue reference that authorized the addition.
6. Update protocol IDs only through protocol revision control.
7. Preserve historical results and evidence references for approved executions.

Editorial clarification may update a row note or summary when it does not alter
the requirement, risk, control, acceptance criterion, or evidence expectation.
Any substantive change after baseline approval requires impact assessment.

## Baseline and Version Control

Before protocol execution, the matrix baseline must record:

- matrix version or controlled document revision;
- repository revision or immutable source digest;
- approval date;
- approving roles;
- included requirement and risk source versions;
- included protocol versions;
- evidence store or archive location;
- known limitations or open deviations.

After baseline approval, changes to matrix structure, required columns,
criticality, acceptance criteria, verification phase, protocol IDs, or evidence
expectations require change-control assessment.

## CSV-VAL-01 Reconciliation Use

CSV-VAL-01 should use this matrix to confirm:

- every approved requirement has traceability to risk or documented rationale;
- every critical requirement has planned and executed verification;
- every executed protocol step maps to at least one requirement, risk, or
  control;
- every evidence artifact is present, reviewable, attributable, and integrity
  checked or deviationed;
- every failed, skipped, or blocked result has a deviation disposition;
- every open CAPA has release-impact rationale;
- every final disposition is supported by reviewer decision evidence;
- superseded rows preserve historical traceability.

The final validation report must not rely on a green CI result, successful
command, or agent summary alone. Release readiness is based on reconciled
requirements, risks, controls, protocols, evidence, deviations, CAPA, residual
risk, and accountable approval.
