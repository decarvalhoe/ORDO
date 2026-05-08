# CSV-IQ-01 Installation Qualification Protocol

## Purpose

This protocol defines the Installation Qualification (IQ) checks for the ORDO
controlled baseline. It is an authoring artifact only: it approves what must be
verified during CSV-IQ-02, but it does not execute IQ and does not create IQ
evidence by itself.

IQ proves that the approved ORDO source, controlled documents, configuration
classes, runtime dependencies, evidence locations, and mechanical attestation
controls are identifiable and ready for OQ protocol execution.

## Scope

This IQ protocol covers the ORDO baseline defined by CSV-10 and the IQ strategy
defined by CSV-09. It verifies installation and configuration readiness for:

- source baseline identity;
- controlled validation document set;
- controlled scripts, libraries, templates, and examples;
- runtime toolchain inventory;
- repository-platform and issue-tracker authentication readiness;
- CI provider or local validation runner availability;
- optional terminal multiplexer classification;
- configuration bundle presence and redaction status;
- state, audit, evidence-store, and retention locations;
- secret handling controls;
- CSV-05A mechanical attestation prerequisites;
- negative checks for missing required configuration or authentication.

This protocol does not verify OQ operating semantics, PQ production-like
performance, downstream product behavior, external service internals, live fleet
layout, or human release approval.

## Prerequisites

The validation owner must confirm these prerequisites before CSV-IQ-02
execution starts:

| Prerequisite | Expected status before execution |
| --- | --- |
| CSV-01 through CSV-10 | Approved, or explicitly dispositioned with rationale where the protocol allows. |
| CSV-05A | Approved enough to define critical mechanical evidence attribution and integrity expectations. |
| CSV-09 | Approved protocol strategy with IQ entry and exit criteria. |
| CSV-10 | Approved controlled baseline record and configuration specification. |
| CSV-08 | Traceability template available for IQ step mapping. |
| Actor registry | Protocol executor, reviewer, and verifier roles identified. |
| Evidence store | Approved evidence location and manifest format available. |
| Deviation process | Deviation owner, severity rules, and closure path available. |

If any prerequisite is missing, the executor must not begin IQ execution unless
the validation owner and quality reviewer approve a documented deviation or
limited execution scope.

## Roles and Approval Route

Protocol author: validation owner or delegated protocol author.

Protocol executor: trained protocol executor or orchestration operator acting
within the approved role matrix.

Technical reviewer: reviews command accuracy, baseline references, dependency
inventory, and evidence completeness.

Quality reviewer: reviews independence, data-integrity expectations, deviation
handling, and record sufficiency.

Approval before execution: validation owner and quality reviewer.

Release to OQ: CSV-IQ-03 report approval, not this protocol alone.

Mechanical attestation may prove that an artifact was produced, handled, or
verified by a defined actor. It does not replace accountable human review,
deviation acceptance, protocol approval, or release to OQ.

## Evidence Capture Rules

CSV-IQ-02 must capture evidence using the approved evidence-store and manifest
format. Each retained IQ evidence item must include:

- IQ step ID;
- evidence ID;
- artifact reference;
- timestamp in UTC;
- executor or actor ID;
- command or review action summary;
- source baseline reference;
- result and exit status where applicable;
- digest, signature, signed attestation, or approved equivalent for critical
  mechanical evidence;
- reviewer disposition;
- deviation reference when expected evidence is missing, altered, or
  unverifiable.

Planned evidence references in this protocol use CSV-08 naming, such as
`EV-IQ-001-01`. The executed CSV-IQ-02 evidence pack must map those IDs to real
records in the approved evidence store.

Secret values, private keys, passwords, tokens, and credential material must not
be captured. Evidence may reference only approved secret classes or secret-store
control records when needed.

## Stop Conditions

The executor must stop IQ execution and open or link a deviation when:

- the baseline source reference cannot be proven;
- the execution workspace is dirty, ambiguous, or not the approved baseline;
- a required command or dependency is unavailable;
- repository-platform or issue-tracker authentication cannot be verified where
  required;
- evidence-store write/read access fails;
- required actor identity or attestation controls are unavailable for critical
  mechanical evidence;
- a required configuration bundle is missing or contains unredacted secret
  material;
- a negative/exception check does not fail closed as expected;
- the protocol requires a result that cannot be captured in retained evidence.

## Protocol Steps

| Step ID | Objective | Action | Expected result | Evidence ID |
| --- | --- | --- | --- | --- |
| IQ-001 | Confirm protocol prerequisites. | Review prerequisite documents, approvals, actor registry, and evidence-store readiness. | Required prerequisites are approved or explicitly deviationed before execution. | EV-IQ-001-01 |
| IQ-002 | Confirm source baseline identity. | Record approved source reference, branch or package reference, source digest or commit, and clean source state. | Baseline matches CSV-10 CFG-001 and is clean or has an approved deviation. | EV-IQ-002-01 |
| IQ-003 | Confirm source availability. | Verify the source checkout, clone, or approved source archive is present and reviewable. | Source is available from an approved repository platform or retained source archive. | EV-IQ-003-01 |
| IQ-004 | Confirm controlled document set. | Compare validation documents against the document index and baseline record. | Required CSV documents through CSV-IQ-01 are present and match approved versions. | EV-IQ-004-01 |
| IQ-005 | Confirm scripts, libraries, templates, and examples. | Inventory controlled command scripts, shared libraries, templates, example configs, and test assets. | Required repository-controlled item classes from CSV-02 and CSV-10 are present. | EV-IQ-005-01 |
| IQ-006 | Confirm executable and syntax readiness. | Run approved non-mutating syntax or executable-bit checks for controlled shell entry points. | Required entry points are executable where expected and syntax checks pass. | EV-IQ-006-01 |
| IQ-007 | Confirm runtime toolchain. | Record shell, version-control client, JSON processor, repository-platform CLI, and validation runner versions or approved equivalents. | Required tools are available, versioned, and compatible with the baseline. | EV-IQ-007-01 |
| IQ-008 | Confirm optional terminal multiplexer classification. | Record terminal multiplexer version when used, or mark not used/out of scope. | Optional terminal multiplexer is classified and not silently required. | EV-IQ-008-01 |
| IQ-009 | Confirm repository-platform authentication readiness. | Verify configured repository-platform CLI or API authentication using a non-mutating identity/status check. | Authentication is present for required read or write scopes, with actor identity recorded. | EV-IQ-009-01 |
| IQ-010 | Confirm issue-tracker access readiness. | Verify the configured issue tracker can be queried for a controlled test reference or approved metadata endpoint. | Required issue-tracker read access is available and attributable. | EV-IQ-010-01 |
| IQ-011 | Confirm CI provider or validation runner readiness. | Verify configured CI provider status access or approved local validation runner availability. | Validation status can be queried or local runner can be invoked according to CSV-09. | EV-IQ-011-01 |
| IQ-012 | Confirm configuration bundle. | Locate approved deployment configuration bundle and confirm secrets are redacted or excluded. | Configuration exists, binds required classes, and contains no secret values. | EV-IQ-012-01 |
| IQ-013 | Confirm missing-configuration refusal. | Run or review an approved non-mutating negative check for missing required project configuration. | Missing required configuration fails closed and produces a clear refusal. | EV-IQ-013-01 |
| IQ-014 | Confirm missing-authentication refusal. | Run or review an approved non-mutating negative check for missing repository-platform authentication where authentication is required. | Missing authentication fails closed and produces a clear refusal or deviation trigger. | EV-IQ-014-01 |
| IQ-015 | Confirm state and audit locations. | Verify approved state and audit locations exist or can be created according to baseline permissions. | State and audit records can be written and retrieved by authorized actors. | EV-IQ-015-01 |
| IQ-016 | Confirm evidence-store access. | Verify evidence-store write/read or archive/retrieval path using a non-secret test artifact. | Evidence can be stored, retrieved, and indexed for review. | EV-IQ-016-01 |
| IQ-017 | Confirm evidence manifest format. | Review or generate a non-production sample manifest with required CSV-05A fields. | Manifest includes evidence ID, actor ID, artifact reference, digest, source reference, timestamp, and verification status. | EV-IQ-017-01 |
| IQ-018 | Confirm mechanical attestation readiness. | Verify signing, digest, or attestation mechanism class is configured, or deviation route is approved for critical evidence. | Critical mechanical evidence can be attributed and integrity-checked, or a preapproved deviation path exists. | EV-IQ-018-01 |
| IQ-019 | Confirm altered-artifact detection readiness. | Run or review an approved non-production sample showing a changed artifact or digest mismatch fails verification. | Altered sample fails verification and is not treated as acceptable evidence. | EV-IQ-019-01 |
| IQ-020 | Confirm secret handling controls. | Review prohibited evidence fields and redaction rules against configuration and evidence manifest examples. | Secret values and private credential material are excluded from retained evidence. | EV-IQ-020-01 |
| IQ-021 | Confirm local validation command inventory. | Record approved shell syntax, lint, and shell regression command set without executing broad validation beyond the protocol plan. | Local validation commands are identified, bounded, and mapped to later evidence. | EV-IQ-021-01 |
| IQ-022 | Confirm external dependency classification. | Review repository platform, issue tracker, CI provider, evidence store, secret store, local shell environment, and optional connectors. | Each dependency is classified as in scope, external, not used, or out of scope. | EV-IQ-022-01 |
| IQ-023 | Confirm traceability setup. | Create or review planned CSV-08 traceability rows for IQ checks and CFG references. | Each IQ step maps to required configuration references, evidence IDs, and deviation route. | EV-IQ-023-01 |
| IQ-024 | Confirm IQ package completeness. | Review all IQ evidence IDs, deviations, and reviewer dispositions before CSV-IQ-03 authoring. | IQ evidence pack is complete enough for IQ report preparation or has documented blockers. | EV-IQ-024-01 |

## Negative and Exception Checks

The IQ executor must include negative or exception evidence for:

- missing required configuration;
- missing repository-platform authentication where authentication is required;
- unavailable evidence-store write/read path;
- missing actor identity for critical mechanical evidence;
- altered artifact, digest mismatch, or failed attestation verification;
- configuration or manifest sample containing prohibited secret material.

Each negative check must prove fail-closed behavior. If an exception condition
passes silently, the executor must open a deviation before continuing.

## Expected Evidence Pack

CSV-IQ-02 should produce an IQ evidence pack containing:

- protocol approval record;
- source baseline record and source cleanliness statement;
- controlled document inventory;
- repository-controlled item inventory;
- runtime toolchain inventory;
- optional dependency classifications;
- authentication readiness evidence;
- configuration bundle redaction review;
- state, audit, and evidence-store access evidence;
- mechanical attestation readiness and altered-artifact failure evidence;
- negative/exception check evidence;
- traceability rows or traceability export for IQ steps;
- deviation log or statement that no deviations were opened;
- reviewer disposition summary.

The evidence pack must remain separate from accountable approval. Reviewer and
phase-gate approvals are recorded under CSV-IQ-03 and the configured approval
route.

## Entry Criteria for Execution

CSV-IQ-02 execution may start only when:

- this protocol is approved;
- CSV-10 baseline status is approved for IQ;
- actor registry and training or identity records are complete;
- evidence-store and manifest format are available;
- deviation process is available;
- mechanical attestation controls or approved deviation route are ready for
  critical evidence.

## Exit Criteria for IQ Report Preparation

CSV-IQ-03 may be authored when:

- all required IQ steps are executed, marked not applicable with rationale, or
  linked to deviations;
- every expected evidence ID is present in the evidence pack or deviationed;
- critical mechanical evidence has valid attribution and integrity verification
  or approved deviation disposition;
- negative checks demonstrate fail-closed behavior or deviations are opened;
- reviewers can retrieve evidence from the approved evidence store;
- open deviations have documented impact on release to OQ.

## Deviation and Retest Rules

Retest is required when a failed IQ step is necessary to prove a prerequisite
for OQ. Retest evidence must cite the original evidence ID, deviation ID,
correction, retest action, result, and whether prior evidence is retained as
failure evidence or replaced by a verified true copy.

Acceptance with rationale is allowed only when the missing or failed item does
not affect baseline identity, evidence integrity, actor attribution, OQ
readiness, or required approval. Critical evidence failures require the approval
route defined by CSV-05A, CSV-06, CSV-09, and CSV-03.

## Approval

Approving this protocol authorizes CSV-IQ-02 execution only. It does not approve
IQ results and does not release the baseline to OQ.

Release to OQ requires CSV-IQ-03 report approval after evidence review,
deviation disposition, and accountable human approval. Mechanical attestation is
supporting evidence for artifact origin and integrity; it is not the human
approval decision.
