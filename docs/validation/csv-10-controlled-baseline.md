# CSV-10 Design/Configuration Specification and Controlled Baseline

## Purpose

This document defines the ORDO design/configuration specification and the
controlled baseline record that must exist before IQ, OQ, PQ, final validation,
or maintaining-validated-state records rely on ORDO evidence.

CSV-10 depends on CSV-02 system boundaries and configuration item inventory,
CSV-07 user requirements and acceptance criteria, and CSV-09 validation plan
and protocol strategy. It does not execute IQ, OQ, or PQ. It defines what must
be identified, approved, and controlled so later protocol evidence can cite a
stable baseline.

## Scope

CSV-10 covers the generic ORDO baseline for:

- source revision, controlled documents, scripts, templates, and validation
  assets;
- deployment configuration that binds ORDO to a repository platform, issue
  tracker, CI provider, evidence store, secret store, local toolchain, and
  optional terminal multiplexer;
- configured actor labels, agent CLI boundaries, identity checks, and handoff
  controls;
- audit, state, evidence, retention, and deviation-linkage configuration;
- cryptographic attribution and integrity expectations for agent-produced
  mechanical evidence;
- change-control rules for moving from one approved baseline to another.

This document excludes downstream product behavior, external service internal
control design, credential issuance, infrastructure provisioning, current fleet
layout, live account names, live repository names, and provider-specific
implementation choices.

## Baseline Principle

A controlled ORDO baseline is a versioned package, not a single file. The
baseline consists of:

- an immutable ORDO source reference or source archive digest;
- the approved validation document set and protocol strategy;
- the approved deployment configuration bundle with secrets redacted;
- the runtime dependency inventory and compatibility record;
- evidence locations, retention rules, and integrity controls;
- actor, reviewer, and approval role records;
- open deviation, limitation, and residual-risk references.

Deployment-specific values belong in a controlled baseline record for that
deployment. This generic CSV-10 document provides the structure and required
fields only; it must not encode live project, provider, host, account, terminal,
path, or fleet identifiers.

## Design Overview

```text
Human operator or approved automation
  -> ORDO command boundary
    -> configuration resolver
      -> preflight and clean-state guardrails
        -> issue or work-item planning
          -> dispatch, handoff, parking, or recovery controls
            -> validation status and refusal handling
              -> audit, state, evidence, and traceability records
                -> independent human review and approval decision
```

The design is fail-closed for controlled actions. When required configuration,
identity, evidence, approval, branch state, validation status, or integrity
checks are missing or inconclusive, ORDO must record the blocker and stop or
defer the controlled action according to the approved workflow.

Automated output, command results, and agent CLI summaries are evidence inputs.
They do not approve a baseline, close a deviation, authorize a phase gate, or
make a release decision unless a separate approved human accountability process
has explicitly accepted that use.

## Configuration Reference Catalogue

Use these `CFG-*` identifiers in CSV-08 traceability, IQ protocol steps, change
records, and final validation reconciliation.

| ID | Configuration reference | Required control | Primary verification |
| --- | --- | --- | --- |
| CFG-001 | Source baseline identity | Immutable source revision, approved branch, tag, release package, or archive digest. | IQ confirms exact source reference and clean source state. |
| CFG-002 | Controlled document set | Approved or dispositioned CSV foundation documents, protocols, reports, runbooks, and controlled operating guidance. | Review confirms document versions match the baseline record. |
| CFG-003 | Deployment boundary record | Generic repository, issue tracker, CI provider, evidence store, secret store, local toolchain, and optional connector scope. | IQ confirms each item is present, not used, or out of scope. |
| CFG-004 | Runtime toolchain inventory | Shell, version-control client, JSON processor, validation runner, and optional terminal multiplexer versions. | IQ records version evidence and compatibility disposition. |
| CFG-005 | Work area and clean-state gates | Workdir template class, branch rules, dirty-state refusal, rebase refusal, and unrelated-change protection. | OQ verifies clean, dirty, stale, and ambiguous states. |
| CFG-006 | Actor and agent inventory | Human roles, agent CLI labels, allowed scopes, work boundaries, and handoff obligations. | Review confirms role authorization and no uncontrolled actor. |
| CFG-007 | Authentication and identity guard | Repository platform, issue tracker, CI provider, evidence store, and signing identity checks. | OQ verifies mismatch refusal and audit evidence. |
| CFG-008 | Issue tracker adapter | Work item lookup, state classification, dependency markers, assignment status, and close-reference rules. | OQ verifies ready, blocked, assigned, parked, and closed states. |
| CFG-009 | Repository platform adapter | Branch, commit, review, pull-request, merge-readiness, and refusal evidence capture. | OQ verifies blocker classification and refusal behavior. |
| CFG-010 | CI provider adapter | Pending, queued, running, skipped, failed, cancelled, timed-out, missing, and successful status handling. | OQ verifies conservative status interpretation. |
| CFG-011 | Dispatch and handoff controls | Prompt rendering, scope proof, post-dispatch acknowledgement, handoff content, and stop conditions. | OQ verifies positive and negative dispatch paths. |
| CFG-012 | Parking and recovery controls | Criteria for parking blocked work, preserving evidence, resuming work, and refusing unsafe rebalance. | OQ verifies blocker preservation and traceable continuation. |
| CFG-013 | Audit and state locations | Assignment state, operational state, cleanup records, audit logs, and retention classification. | IQ verifies paths; OQ verifies durable records. |
| CFG-014 | Evidence store and retention | Evidence manifest location, artifact naming, retention period, retrieval method, and redaction rules. | IQ verifies write/read access; PQ samples retained evidence. |
| CFG-015 | Agent evidence attestation policy | Signature, digest, attestation, verification status, and deviation rule for mechanical evidence. | IQ confirms availability; OQ verifies success and failure handling. |
| CFG-016 | Secret handling controls | Secret classes, secret-store references, redaction expectations, and prohibited evidence fields. | OQ verifies secret values are not written into evidence. |
| CFG-017 | Timeout and concurrency limits | Bounded command execution, validator limits, queue limits, retry limits, and escalation thresholds. | OQ verifies bounded failure and degraded-condition reporting. |
| CFG-018 | Findings, deviation, and CAPA linkage | Durable findings path, deviation trigger rules, CAPA linkage, and recurrence handling. | OQ verifies records are durable and traceable. |
| CFG-019 | Rollback and release-support references | Rollback action class, release-support action class, limitation record, and residual-risk references. | Review confirms references before phase or release decisions. |
| CFG-020 | Baseline lifecycle control | Draft, proposed, approved, executed, superseded, retired, and revalidation-required states. | Review confirms change-control disposition. |

## Controlled Baseline Record

Each deployment that claims validated ORDO use must maintain a controlled
baseline record. The record may be stored in the evidence store, repository
platform, document-control system, or another approved records system, but it
must be reviewable for the required retention period.

| Field | Required content |
| --- | --- |
| Baseline ID | Stable identifier assigned by the deployment. |
| Baseline status | Draft, proposed, approved for IQ, approved for OQ, approved for PQ, released, superseded, retired, or revalidation required. |
| ORDO source reference | Commit, tag, release package, or source archive digest. |
| Source cleanliness statement | Confirmation that the baseline source was captured from a clean and approved source state, or a linked deviation. |
| Validation document versions | CSV document versions, protocol versions, and approval dispositions included in the baseline. |
| Configuration bundle reference | Redacted configuration artifact, checksum, and owner. |
| Runtime inventory reference | Toolchain, dependency, and optional connector inventory. |
| External dependency classification | Repository platform, issue tracker, CI provider, evidence store, secret store, local shell environment, and optional terminal multiplexer classified as in scope, external, not used, or out of scope. |
| Actor and identity record | Human role records, agent CLI labels, service identity summaries, and least-privilege review evidence. |
| Evidence-control record | Evidence store location, retention rule, manifest format, integrity mechanism, and redaction rule. |
| Agent evidence attestation record | Mechanical attestation method, signature or digest verification process, verification status field, and deviation route. |
| Secret handling record | Secret classes and approved secret-store references without secret values. |
| Known limitations | Open deviations, accepted limitations, unavailable optional controls, and residual risks. |
| Rollback or retirement action | Approved action for retiring, superseding, or rolling back the baseline when a change fails. |
| Approval record | Human approving roles, approval date, approval artifact, and independence check. |
| Next review trigger | Periodic review date, revalidation trigger, or change-control trigger. |

## Configuration Specification Template

Each controlled configuration bundle should include these sections. A
deployment may add fields, but removal after baseline approval requires
change-control assessment.

| Section | Required content | Control expectation |
| --- | --- | --- |
| Scope binding | Repository class, default branch rule, work-item source, validation runner class, and evidence store class. | Values are generic in the dossier and concrete only in the deployment record. |
| Work area model | Workdir pattern, clone or source-preparation rule, branch naming rule, and cleanup rule. | Unsafe or ambiguous local state fails closed. |
| Actor model | Human roles, agent CLI labels, allowed scopes, reviewer independence, and handoff fields. | No actor may perform controlled steps outside approved scope. |
| Identity checks | Command-line identity checks, service identity summaries, token-scope summaries, and mismatch behavior. | Write operations require identity verification and mismatch refusal. |
| Dispatch settings | Candidate selection, dependency signals, assignment signals, atomization limits, and handoff requirements. | Blockers and assignments are preserved when work is parked or rebalanced. |
| Validation settings | Local check selection, CI provider status mapping, timeout policy, retry policy, and required-check rule. | Pending, missing, failed, skipped, and ambiguous status cannot be treated as success by default. |
| Evidence settings | Manifest fields, artifact naming, checksums or signatures, attestation reference, timestamps, and retention. | Critical evidence is attributable and integrity protected or deviationed. |
| Secret settings | Secret classes, approved references, redaction policy, and prohibited capture fields. | Secret values and private credential material are excluded from evidence. |
| Findings settings | Findings ledger class, controlled issue conversion path, deviation trigger, CAPA trigger, and close criteria. | Findings that affect validated state become traceable records. |
| Change settings | Change categories, approval route, rollback action, supersession rule, and revalidation trigger. | Baseline changes are assessed before use as validation evidence. |

## Baseline Lifecycle

| State | Meaning | Permitted next state |
| --- | --- | --- |
| Draft | Baseline record is being assembled and may not support protocol execution. | Proposed or retired. |
| Proposed | Baseline is complete enough for review but not approved for execution. | Approved for IQ, returned to draft, or retired. |
| Approved for IQ | Baseline may be used to execute IQ only. | IQ executed, superseded, or retired. |
| IQ executed | IQ evidence exists and is awaiting report disposition. | Approved for OQ, superseded, or revalidation required. |
| Approved for OQ | Baseline may be used to execute OQ according to approved protocols. | OQ executed, superseded, or revalidation required. |
| Approved for PQ | Baseline may be used to execute PQ according to approved protocols. | PQ executed, released, superseded, or revalidation required. |
| Released | Baseline is accepted for the defined intended use and limitations. | Superseded, retired, or revalidation required. |
| Superseded | A later approved baseline replaces this baseline. | Retired or retained for historical evidence. |
| Retired | Baseline is no longer used for controlled execution. | Historical only. |
| Revalidation required | A change or event invalidated prior assumptions enough to require revalidation assessment. | Draft, proposed, retired, or an approved deviation path. |

Moving a baseline between execution states requires the approval route defined
by the applicable CSV document and protocol report. Mechanical evidence can
support the move, but human approval remains the accountable decision.

## Mechanical Evidence and Human Approval

Agent CLI output, generated manifests, command transcripts, automated check
results, and signed artifacts are mechanical evidence. They may prove that an
artifact was produced by a configured actor or process and that the artifact was
not altered after capture.

Mechanical attestation does not prove that the result is acceptable for
regulated or controlled use. Approval of a baseline, protocol, deviation, CAPA,
phase gate, or release decision remains a human or organizational
accountability activity under the approved role matrix.

For critical agent-produced evidence, the baseline must define:

- artifact class and criticality;
- actor label or execution role;
- digest, signature, attestation, or immutable-reference requirement;
- verification command or review action;
- verification status field in the evidence manifest;
- deviation route for missing, expired, revoked, mismatched, or failed
  verification;
- rationale path for classifying an artifact as non-critical supporting
  material.

No mandatory signing vendor, repository platform, CI provider, evidence store,
secret store, or agent CLI vendor is required by this CSV-10 baseline. The
deployment must choose controls that meet the approved risk classification and
record their behavior in the controlled baseline record.

## Change Control

After CSV-10 approval, these changes require impact assessment before the
changed baseline is used as formal validation evidence:

- source scripts, libraries, templates, tests, or validation workflow logic;
- CSV documents, protocol content, acceptance criteria, risk controls, or
  traceability structure;
- repository platform, issue tracker, CI provider, evidence store, secret
  store, or command-line identity configuration;
- workdir model, branch rules, dispatch rules, parking rules, handoff rules,
  cleanup rules, or release-support rules;
- actor inventory, agent CLI scope, service identity, permission summary, or
  reviewer independence model;
- evidence manifest schema, retention policy, redaction rule, signature,
  digest, attestation, or verification mechanism;
- external tool versions outside the approved compatibility range;
- timeout, concurrency, retry, queue, or validator-load settings;
- open deviation disposition, CAPA linkage, accepted limitation, rollback
  action, or release-support action.

Change classifications:

| Classification | Meaning | Minimum action |
| --- | --- | --- |
| No-impact | Editorial or administrative update with no effect on requirements, risks, controls, evidence, or execution. | Record rationale and reviewer disposition. |
| Minor | Bounded update with no critical-control impact and no protocol evidence impact. | Update baseline record and affected traceability rows. |
| Major | Update affects requirement coverage, risk controls, evidence capture, actor scope, or operational behavior. | Change-control approval, protocol impact assessment, and targeted retest plan. |
| Revalidation required | Update changes intended use, regulated impact, critical controls, evidence integrity, or release readiness assumptions. | Revalidation assessment and approved protocol strategy before use. |

## IQ Input Checklist

CSV-IQ-01 may use this checklist to define IQ steps. This checklist is not an
execution record by itself.

| Check | Expected evidence |
| --- | --- |
| CFG-001 source baseline identity is recorded. | Source reference or archive digest with reviewer confirmation. |
| CFG-002 controlled document set is listed. | Document index or baseline record with versions and dispositions. |
| CFG-003 deployment boundary is classified. | Boundary record with in-scope, external, not-used, and out-of-scope classifications. |
| CFG-004 runtime inventory is captured. | Tool version outputs or equivalent dependency evidence. |
| CFG-006 actor and agent inventory is approved. | Role and scope record without live account secrets. |
| CFG-007 identity guard is available. | Identity-check command evidence or approved deviation path. |
| CFG-013 audit and state locations are available. | Write/read path evidence or controlled-system record. |
| CFG-014 evidence store and retention are defined. | Evidence manifest location, retention class, and retrieval proof. |
| CFG-015 agent evidence attestation policy is ready. | Verification method, status field, and deviation route. |
| CFG-016 secret handling controls are defined. | Secret-class references and redaction rule review. |
| CFG-020 lifecycle control is active. | Baseline status, approval record, and change-control trigger. |

## Traceability Expectations

CSV-08 rows should reference CSV-10 when verification depends on design or
configuration controls.

| Configuration reference | Primary requirements | Primary risk links |
| --- | --- | --- |
| CFG-001 | URS-004, URS-005, URS-020 | QR-004, QR-008, QR-014 |
| CFG-005 | URS-003, URS-004, URS-008 | QR-003, QR-004, QR-010 |
| CFG-007 | URS-011, URS-016, URS-018 | QR-011, QR-012, QR-014 |
| CFG-008 | URS-005, URS-006, URS-007 | QR-007, QR-013, QR-014 |
| CFG-010 | URS-009, URS-010, URS-017 | QR-005, QR-006, QR-013 |
| CFG-011 | URS-001, URS-006, URS-012 | QR-001, QR-002, QR-003 |
| CFG-012 | URS-006, URS-008, URS-013 | QR-007, QR-008, QR-010 |
| CFG-014 | URS-005, URS-011, URS-020 | QR-008, QR-014 |
| CFG-015 | URS-015, URS-020 | QR-008, QR-009, QR-014 |
| CFG-018 | URS-013, URS-018, URS-019 | QR-006, QR-008, QR-014 |

Rows may cite additional `CFG-*`, `URS-*`, and `QR-*` identifiers when the
protocol step covers a combined behavior. A critical or high-risk row must not
be satisfied only by a successful command or green status. It must link the
result to baseline identity, evidence integrity, deviation disposition when
applicable, and human reviewer decision evidence.

## Approval and Maintenance

CSV-10 must be approved before IQ execution relies on ORDO baseline evidence.
The technical owner maintains the configuration specification. The validation
owner confirms that the baseline supports planned protocols and traceability.
The quality reviewer or system owner participates when the change affects
regulated impact, release readiness, data integrity, or approval boundaries.

After release, CSV-OPS-01 governs periodic review, incident impact assessment,
CAPA follow-through, retirement, supersession, and revalidation triggers for
the controlled ORDO baseline.
