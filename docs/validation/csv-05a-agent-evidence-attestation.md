# CSV-05A Agent Evidence and Attestation Model

## Purpose

This document defines the ORDO model for digitally signed or otherwise
cryptographically protected evidence produced by agent CLI actors, automation
services, and orchestration commands. It supports CSV-05 data-integrity
expectations by defining how mechanical evidence becomes attributable,
integrity-protected, reviewable, and traceable.

CSV-05A does not implement a signing mechanism and does not mandate a vendor,
product, or service. It defines the control outcome that later IQ, OQ, PQ,
traceability, and final validation evidence must satisfy.

## Scope

This model applies to agent-produced or automation-produced evidence used in an
ORDO validation package, including:

- command transcripts and exit status records;
- generated files, reports, summaries, manifests, or observations;
- repository-platform references, issue-tracker records, review records, and
  run identifiers when cited as validation evidence;
- CI provider results and retained job output;
- ORDO audit records, state snapshots, cleanup records, findings records, and
  controlled-operation records;
- evidence manifests used by IQ, OQ, PQ, final traceability reconciliation, and
  validated-state maintenance.

This model does not make agent output correct by itself. It proves origin,
context, and integrity at the level required by the record criticality. Human
or organizational review remains required wherever CSV-03, protocol approval,
deviation disposition, final report approval, or release readiness requires it.

## Core Distinction

Mechanical attestation and human approval are separate controls.

Mechanical attestation:

- proves that a defined actor identity or automation identity produced,
  observed, handled, or verified a specific evidence record;
- binds the evidence digest to metadata such as protocol step, source revision,
  execution context, timestamp, and actor identity;
- supports attribution, integrity, non-repudiation controls where applicable,
  and later verification;
- does not decide whether the evidence is acceptable.

Human or organizational approval:

- confirms accountable review of evidence, deviations, residual risk, and
  release readiness;
- follows the approval route defined by CSV-03 and the relevant protocol;
- may rely on verified mechanical attestation as supporting evidence;
- cannot be replaced by an agent signature unless a separate approved identity,
  records, and regulatory policy explicitly permits that interpretation.

## Design Principles

- Mechanism-neutral: the validation package may use detached signatures, signed
  envelopes, certificate-backed signatures, key-backed signatures, transparency
  records, or another approved standard.
- Criticality-based: required controls scale with CSV-06 risk and CSV-08
  traceability criticality.
- Metadata-bound: the signature or attestation must bind both artifact digest
  and essential context, not only the raw file bytes.
- Reviewable: verifiers must be able to reproduce the verification result with
  retained public material and documented commands.
- Fail-closed for critical evidence: missing, altered, expired, revoked, or
  unverifiable critical evidence becomes a deviation.
- No secret material in evidence: private keys, tokens, passwords, and secret
  values must never be stored in validation evidence.

## Evidence Criticality Classes

| Class | Use | Attestation requirement |
| --- | --- | --- |
| Critical validation evidence | Evidence used to pass IQ, OQ, PQ, final traceability, deviation closure, CAPA effectiveness, or release readiness. | Cryptographic attribution and integrity verification required. Missing or failed verification requires deviation disposition. |
| Supporting validation evidence | Evidence used to explain, corroborate, or review a decision, but not the sole basis for acceptance. | Digest or signature expected; reviewer may accept an equivalent control with rationale. |
| Transient operational evidence | Temporary output used for live triage and not cited in a validation decision. | Not retained as validation evidence unless promoted into an evidence record. |
| Human approval record | Accountable review, approval, or release decision. | Must follow the approved approval route. Mechanical attestation may support record integrity but is not the approval itself. |

## Actor Identity Registry

Each actor that produces or verifies retained mechanical evidence must have an
identity record before formal protocol execution.

Minimum registry fields:

| Field | Required content |
| --- | --- |
| Actor ID | Stable identifier unique within the validation package. |
| Actor class | Human executor, agent CLI, automation service, verification service, or repository platform. |
| Authorized scope | Approved protocol phases, command families, repository scope, evidence classes, and operating limits. |
| Supervising role | Human or organizational role accountable for the actor's use. |
| Public verification material | Public key, certificate, fingerprint, transparency reference, or approved verification descriptor. |
| Issuance record | Issued by, issued for, issue date, purpose, and approval reference. |
| Rotation status | Active, rotated, expired, revoked, suspended, or retired. |
| Non-reassignment rule | Actor identity must not be reused for a different actor without documented retirement and reissuance. |
| Review cadence | Periodic review owner and due date. |

The registry must avoid embedding live account names, machine identifiers,
environment paths, or vendor-specific actor names in this generic document.
Deployment-specific values belong in controlled configuration and CSV-10
baseline evidence.

## Key and Credential Lifecycle

The signing or attestation mechanism must define:

- who can issue, approve, rotate, suspend, revoke, and retire verification
  material;
- where private signing material is stored and how access is restricted;
- how signing material is protected from export or uncontrolled copying;
- how lost, exposed, expired, or reassigned keys are handled;
- how revoked material is represented in old evidence and future verification;
- how verification material remains available for the evidence retention
  period;
- how emergency replacement is approved, recorded, and reconciled.

Private keys and secret values are never evidence content. Evidence may retain
only public verification material, fingerprints, certificate references,
revocation status, and verification results.

## Evidence Manifest Schema

Every retained attested evidence item must have a manifest or manifest row. A
deployment may store this as markdown, JSON, table rows, signed envelope
metadata, or another controlled format, but the required fields must remain
reviewable.

Required fields:

| Field | Required content |
| --- | --- |
| Evidence ID | Stable evidence identifier, normally aligned to CSV-08 naming. |
| CSV ID | Source document or phase, such as CSV-05A, CSV-IQ-02, CSV-OQ-02, or CSV-PQ-02. |
| Issue or work item | Controlled issue, requirement, deviation, or protocol reference. |
| Protocol step | Step ID, review step, or not applicable with rationale. |
| Artifact reference | Evidence-store path, retained artifact identifier, exported record identifier, or archive reference. |
| Artifact digest | Digest value and digest algorithm for the retained artifact or record export. |
| Source revision | Commit, release identifier, source digest, or approved baseline reference. |
| Branch or package reference | Approved branch, tag, package, or not applicable with rationale. |
| Command or action summary | Script, checker, review action, generation process, or platform event summary. |
| Actor ID | Registry ID of the producer, observer, handler, or verifier. |
| Actor class | Human executor, agent CLI, automation service, verification service, or platform record. |
| Supervising role | Role accountable for use of the actor or evidence. |
| Timestamp | UTC timestamp for creation, capture, export, or verification. |
| Attestation type | Authorship, execution, observation, export, verification, archive, or approval-support. |
| Signature or attestation reference | Detached signature, signed envelope ID, certificate fingerprint, transparency reference, or approved equivalent. |
| Verification result | Pass, fail, not required, superseded, or deviation opened. |
| Reviewer disposition | Accepted, rejected, accepted with limitation, superseded, or pending. |
| Related deviation/CAPA | Linked record or `none`. |

Secret values, private keys, access tokens, and credential material must not
appear in any manifest field.

## Signature Binding Requirements

A valid attestation must bind enough context to prevent copying a signature from
one evidence record to another.

Required binding:

- artifact digest;
- evidence ID;
- CSV ID and protocol step or review step;
- actor ID and actor class;
- source revision or approved baseline reference;
- command or action summary;
- timestamp;
- attestation type;
- verification material fingerprint or reference.

Recommended binding where available:

- controlled configuration baseline reference from CSV-10;
- issue, requirement, risk, traceability row, or deviation ID;
- CI provider run identifier or validation runner identifier;
- evidence-store archive batch, export identifier, or retention package ID.

If a mechanism can sign only a file digest, a separate manifest must be
digest-bound and retained so that contextual metadata is protected by the same
control outcome.

## Verification Procedure

Each protocol report that relies on attested evidence must include or link a
verification procedure.

The procedure must verify:

- artifact exists in the approved evidence store or retained archive;
- artifact digest matches the manifest;
- signature or attestation validates against retained public verification
  material;
- verification material was active and authorized at evidence creation time;
- actor ID was authorized for the protocol scope;
- source revision and controlled baseline match the protocol expectation;
- attestation type is appropriate for the evidence use;
- no required field is missing or inconsistent;
- revocation, expiration, replacement, and key rotation status were checked;
- failed or missing verification has a linked deviation or non-critical
  supporting-evidence rationale.

Verification output must itself be retained when used for IQ, OQ, PQ, final
traceability, or release readiness. The output must include command or process
summary, verification tool or service identifier, timestamp, verifier actor ID,
result, and reviewed evidence IDs.

## Failure and Deviation Rules

Open a deviation when critical evidence has:

- missing manifest;
- missing artifact;
- digest mismatch;
- invalid, missing, expired, revoked, or unverifiable signature or attestation;
- actor ID absent from the identity registry;
- actor scope mismatch;
- source revision or baseline mismatch;
- required metadata missing or inconsistent;
- evidence stored only in transient output;
- signature created after artifact modification without replacement record.

Deviation severity must follow CSV-06 and CSV-09. Critical evidence failures
normally start as major or critical deviations until impact assessment proves a
lower classification. A deviation may be closed by retest, replacement evidence,
documented true-copy recovery, accepted residual risk, or CAPA where the issue
is systemic.

Non-critical supporting evidence may be accepted without cryptographic
attestation only when the validation owner and quality reviewer document why it
does not affect acceptance, deviation disposition, or release readiness.

## Baseline and Configuration Relationship

CSV-10 will define the controlled baseline. CSV-05A requires that the baseline
capture the attestation-relevant configuration without codifying any live fleet.

CSV-10 should identify, at a class level:

- approved evidence-store type and retention expectation;
- approved signing or attestation mechanism class;
- actor identity registry location and owner;
- verification material retention path;
- digest algorithm policy;
- key rotation and revocation policy;
- validation runner or verification command family;
- evidence manifest format;
- expected artifact naming convention;
- required deviation route for failed verification.

Deployment-specific actor names, repository identifiers, host details, local
paths, terminal targets, service accounts, and secret names belong in controlled
configuration evidence, not in this generic CSV-05A model.

## Chain of Custody

Critical evidence must preserve chain of custody from creation through final
report reconciliation.

Minimum chain-of-custody events:

- evidence creation or export;
- digest calculation;
- signature or attestation creation;
- evidence-store write or archive action;
- verification before report approval;
- reviewer disposition;
- replacement or retirement, if applicable.

Each event must identify actor ID, timestamp, artifact reference, action
summary, and result. If an artifact is copied, exported, compressed, moved, or
converted, the true-copy process must record source reference, destination
reference, digest before and after, and reviewer disposition.

## Protocol Integration

IQ should verify:

- actor identity registry exists and required actors are active;
- verification material is retrievable;
- approved signing or attestation mechanism is available or explicitly out of
  scope for non-critical evidence;
- evidence-store location and manifest format are available;
- sample verification can pass and a deliberately altered sample can fail.

OQ should verify:

- valid critical evidence passes verification;
- altered artifact, altered metadata, wrong actor scope, revoked verification
  material, and missing manifest fail verification;
- failed verification creates or requires a deviation;
- human approval remains separate from mechanical attestation.

PQ should verify:

- production-like evidence is captured with required manifests;
- attested evidence can be retrieved and verified by a reviewer;
- evidence package review can distinguish critical evidence, supporting
  evidence, deviations, and approval records;
- residual attestation risks are documented for final validation.

No IQ, OQ, or PQ execution is performed by this document.

## Traceability and Final Report Use

CSV-08 traceability rows that rely on agent-produced evidence must cite:

- evidence ID;
- actor ID and actor class;
- artifact digest or signed attestation reference;
- verification result;
- reviewer disposition;
- deviation or CAPA reference when verification failed or was not required.

CSV-VAL-01 must reconcile whether every critical evidence artifact has valid
attribution and integrity evidence or a deviation disposition. CSV-VAL-02 must
state any residual risk from missing, incomplete, or limited attestation
controls.

## Maintaining Validated State

After release, CSV-OPS-01 must maintain the attestation model through:

- periodic review of actor registry entries;
- verification material rotation and revocation review;
- evidence-store retrieval checks;
- review of failed verification events and deviations;
- impact assessment for signing mechanism changes;
- impact assessment for validation runner, repository-platform, issue-tracker,
  CI provider, evidence-store, or secret-store changes that affect evidence
  attribution or integrity.

Changes that weaken evidence integrity, actor attribution, reviewability, or
retention require validation impact assessment before use as controlled
evidence.

## Acceptance Criteria

CSV-05A is complete when the validation package can show:

- agent-produced evidence has a defined identity, manifest, digest, and
  attestation model;
- mechanical attestation is clearly separate from human approval;
- critical evidence verification fails on altered artifacts or altered required
  metadata;
- missing or unverifiable critical evidence triggers deviation handling;
- the model is mechanism-neutral and does not require a specific vendor;
- CSV-08, CSV-09, IQ, OQ, PQ, final validation, and validated-state documents
  have enough information to reference the control consistently;
- CSV-10 can define the controlled baseline and configuration classes without
  hardcoding a live fleet.
