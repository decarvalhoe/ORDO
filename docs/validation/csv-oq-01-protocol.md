# CSV-OQ-01 OQ Protocol for Operational Gate Semantics

## Purpose

This protocol defines Operational Qualification checks for ORDO operational
gate semantics. It authorizes no execution by itself. CSV-OQ-02 owns execution
and evidence capture. CSV-OQ-03 owns the OQ report and any release-to-PQ
decision.

OQ proves that ORDO controls fail closed, preserve evidence, route deviations,
and refuse unsafe controlled actions under defined normal, boundary, and
negative conditions. The protocol uses universal ORDO contract terms only.
Deployment-specific repository names, actor names, environment names, service
names, terminal identifiers, machine identifiers, and local filesystem values
belong in controlled configuration records and must not be written into this
generic protocol.

## Dependencies and Entry Criteria

CSV-OQ-02 execution may start only when all entry criteria are met.

| Entry criterion | Required status before execution |
| --- | --- |
| CSV-IQ-03 | IQ report exists and includes a technical release-to-OQ recommendation. |
| Human approval condition from CSV-IQ-03 | Configured approval route has explicitly approved release to OQ, or a documented waiver/deviation authorizes limited OQ execution. |
| CSV-06 | Risk controls are available for OQ mapping. |
| CSV-07 | Requirements and acceptance criteria are available for OQ mapping. |
| CSV-08 | Traceability fields and evidence naming rules are available. |
| CSV-05A | Agent-produced evidence attribution and integrity expectations are available. |
| Test fixtures | Synthetic issue, change-request, repository-state, CI-status, evidence-store, and terminal-target fixtures are approved for non-production OQ execution. |
| Executor readiness | Protocol executor and reviewer roles are identified under CSV-03. |

If the CSV-IQ-03 human approval condition is not satisfied, CSV-OQ-02 must stop
before executing any OQ step and record a blocker or deviation according to the
configured approval route.

## Scope

This protocol covers:

- dispatch readiness and post-dispatch consumption checks;
- fail-closed refusal paths;
- evidence capture and evidence attribution placeholders;
- validator and check dispatch;
- merge or release-support gate behavior;
- retry, bounded recovery, and reconfiguration behavior;
- priority enforcement and ready-work planning;
- issue tracker traceability and atomization dry-run behavior;
- CI status classification, including stale result deduplication;
- dirty, rebase, branch divergence, and conflict detection;
- product or context switch guardrails;
- self-improvement finding capture;
- deviation, CAPA, retest, and stop-condition routing.

This protocol excludes:

- OQ execution;
- OQ report authoring or release-to-PQ decision;
- PQ production-like wave execution;
- live downstream product validation;
- provisioning of terminal multiplexers, credentials, actors, repositories, or
  execution environments;
- implementation of the CSV-05A signing mechanism.

## Evidence Capture Rules

CSV-OQ-02 must retain an evidence pack with:

- OQ step ID;
- evidence ID;
- controlled baseline reference;
- synthetic fixture identifier or approved controlled record reference;
- command or review action summary;
- actor role or agent CLI actor label;
- UTC timestamp;
- pass, fail, skipped, blocked, or deviated result;
- observed output summary;
- artifact digest or signed attestation reference;
- verification result for agent-produced evidence;
- deviation or CAPA reference when applicable;
- reviewer disposition.

Secret values, private credential material, live environment identifiers, and
unredacted service details must not be retained. Critical agent-produced
evidence must be attributable and integrity-protected or must create a
deviation unless a validation owner and quality reviewer classify the artifact
as non-critical supporting material.

## Global Stop Conditions

The executor must stop CSV-OQ-02 and open or link a deviation when:

- CSV-IQ-03 human approval for OQ entry is missing and no approved waiver is
  present;
- the execution baseline does not match the approved OQ baseline;
- the work area is dirty, ambiguous, rebasing, diverged, or in conflict outside
  the test fixture being evaluated;
- test fixtures are missing, unapproved, or contain live identifiers;
- evidence cannot be written, retrieved, hashed, or verified;
- a required refusal path does not fail closed;
- a command performs a real mutating action where this protocol requires
  dry-run, fixture-only, or simulated execution;
- critical evidence attribution or integrity verification is missing or fails;
- secret or credential material appears in retained output;
- an observed result contradicts an acceptance criterion.

## Deviation, Retest, and CAPA Rules

Create a deviation for any failed, skipped, altered, or unverifiable protocol
step unless the protocol explicitly allows a not-applicable result with
rationale. Deviation severity follows CSV-06 and CSV-09.

Retest is required when a failed step is needed to support an OQ acceptance
criterion. Retest evidence must cite the original step, original evidence ID,
deviation ID, correction, retest action, result, and whether prior evidence is
retained as failure evidence or superseded.

CAPA linkage is required when the deviation is critical, recurring, systemic,
or caused by an ineffective control. CAPA records must remain separate from
mechanical evidence and require the configured approval route.

## OQ Protocol Steps

| Step ID | Objective | Requirement/risk/config links | Action for CSV-OQ-02 | Pass criteria | Fail/deviation trigger | Evidence ID |
| --- | --- | --- | --- | --- | --- | --- |
| OQ-001 | Confirm OQ entry gate. | URS-014, URS-020, QR-008, CFG-020 | Review CSV-IQ-03, OQ approval record, baseline reference, actor readiness, and fixture approval. | Approval or approved waiver is present; no OQ step starts before entry gate is satisfied. | Missing approval or waiver; baseline mismatch; missing executor/reviewer record. | EV-OQ-001-01 |
| OQ-002 | Verify readiness preflight positive path. | URS-001, URS-006, QR-010, CFG-003, CFG-011 | Run approved preflight against a synthetic ready configuration and retained fixture state. | Ready status is produced with evidence of configuration, dependency, work-area, and target readiness. | Ready fixture is rejected without cause; output omits required readiness fields. | EV-OQ-002-01 |
| OQ-003 | Verify readiness preflight fail-closed paths. | URS-001, URS-018, QR-010, CFG-003 | Run negative preflight fixtures for missing configuration, unavailable dependency, stale work area, missing target, and degraded validator condition. | Each unsafe fixture is refused with blocker category and remediation guidance. | Any unsafe fixture is treated as ready or lacks a blocker reason. | EV-OQ-003-01 |
| OQ-004 | Verify priority enforcement. | URS-002, URS-006, QR-007, CFG-008 | Run planning fixture with high, medium, blocked, assigned, parked, and completed synthetic work items. | Output ranks ready work by configured priority without product-specific defaults and excludes blocked or assigned work. | Priority order ignores configured data; blocked, assigned, parked, or completed work appears ready. | EV-OQ-004-01 |
| OQ-005 | Verify issue tracker traceability. | URS-005, URS-006, QR-014, CFG-008 | Run fixture that maps work item, branch label, change request, validation status, and evidence reference. | Traceability record links the synthetic work item to branch, change request, check result, evidence ID, and final disposition placeholder. | Any required traceability field is missing or relies on chat/terminal scrollback alone. | EV-OQ-005-01 |
| OQ-006 | Verify atomization dry-run behavior. | URS-007, QR-007, CFG-008, CFG-012 | Run atomization dry-run fixture for oversized work with existing child marker and duplicate-risk marker. | Dry-run proposes bounded child work with parent reference and duplicate-prevention signal without creating live work items. | Dry-run mutates live tracker, omits parent linkage, or duplicates unchanged children. | EV-OQ-006-01 |
| OQ-007 | Verify dispatch readiness positive path. | URS-001, URS-006, QR-001, CFG-011 | Render a canonical dispatch prompt for a synthetic ready item and verify target, scope, base reference, validation instruction, and evidence expectations. | Prompt is complete, canonical, scoped, and ready for controlled dispatch. | Prompt is truncated, non-canonical, missing scope, or points outside approved fixture. | EV-OQ-007-01 |
| OQ-008 | Verify dispatch target and context refusal. | URS-008, URS-012, QR-001, QR-003, CFG-011 | Run wrong-target, wrong-context, stale-input, and not-consumed dispatch fixtures using synthetic terminal-target metadata. | Each unsafe condition fails closed and records a durable blocker with target/context evidence. | Dispatch is classified as consumed when prompt remains visible or target/context mismatch exists. | EV-OQ-008-01 |
| OQ-009 | Verify product or context switch guardrails. | URS-004, URS-008, URS-012, QR-003, CFG-005 | Run switch fixtures for clean parked work, dirty work, unpushed work, incomplete handoff, and mismatched source context. | Approved switch records parking/handoff evidence; unsafe switches are refused without mutation. | Dirty or incomplete work is switched without blocker; handoff evidence is missing. | EV-OQ-009-01 |
| OQ-010 | Verify dirty, rebase, divergence, and conflict detection. | URS-004, QR-004, CFG-005 | Run repository-state fixtures for clean, dirty, rebasing, diverged, missing upstream, and conflicted states. | Unsafe states block dispatch, validation, merge, and context switch with actionable reason. | Unsafe state proceeds or is remediated destructively without approved controlled operation. | EV-OQ-010-01 |
| OQ-011 | Verify safe remediation refusal/apply split. | URS-003, URS-004, QR-004, CFG-005, CFG-017 | Run dry-run and apply fixtures for safe remediation; include destructive cleanup and ambiguous target fixtures. | Dry-run reports proposed changes; apply performs only approved safe actions; destructive or ambiguous actions are refused. | Apply mutates outside approved fixture, skips dry-run where required, or accepts destructive cleanup. | EV-OQ-011-01 |
| OQ-012 | Verify validator and check dispatch policy. | URS-017, QR-005, QR-013, CFG-010, CFG-017 | Run fixtures for bounded local smoke, full local validator request without opt-in, CI-delegated validation, timeout, and semaphore/degraded condition. | Full local validators are refused without explicit opt-in; bounded checks run with limits; delegated checks are recorded as pending external evidence. | Unbounded validation starts without approval; timeout or degraded condition is treated as pass. | EV-OQ-012-01 |
| OQ-013 | Verify CI status classification. | URS-009, QR-005, CFG-010 | Run CI status fixtures for success, failure, pending, queued, running, skipped, cancelled, timed out, missing, and ambiguous states. | Only configured successful required checks produce merge-ready status; all other states produce distinct blocker or policy result. | Failed, pending, missing, or ambiguous status is treated as success. | EV-OQ-013-01 |
| OQ-014 | Verify stale CI result deduplication. | URS-009, QR-005, QR-013, CFG-010 | Run fixture with historical failed run, newer successful run, cancelled duplicate, and mismatched source revision. | Latest relevant status for the approved source revision is used; stale or duplicate status does not create false red or false green. | Historical failure overrides newer valid success; stale success hides current failure. | EV-OQ-014-01 |
| OQ-015 | Verify merge gate refusal. | URS-010, QR-006, CFG-009, CFG-010 | Run merge-gate fixtures for failed checks, pending checks, missing review, conflict, stale head, closed change request, permission refusal, and explicit no-check policy. | Gate refuses unsafe states with refusal category and next action; no-check policy requires documented rationale. | Unsafe state is classified as merge-ready or refusal lacks evidence. | EV-OQ-015-01 |
| OQ-016 | Verify merge or release-support evidence capture. | URS-005, URS-010, URS-011, QR-006, QR-014 | Run dry-run evidence fixture for a safe merge-support decision and a refused decision. | Evidence includes work item, change request, source revision, required-check status, decision, actor role, timestamp, and artifact digest. | Decision evidence lacks required fields or contains live identifiers or secret material. | EV-OQ-016-01 |
| OQ-017 | Verify evidence store, manifest, and attestation placeholders. | URS-011, URS-015, URS-020, QR-008, QR-009, CFG-014, CFG-015 | Generate non-secret OQ evidence manifest sample and altered-artifact sample. | Manifest includes required CSV-05A fields; changed artifact fails digest or attestation verification. | Critical evidence lacks digest/attestation field, verification status, or deviation route. | EV-OQ-017-01 |
| OQ-018 | Verify secret handling and redaction. | URS-016, QR-012, CFG-016 | Run prohibited-field fixture with secret-like values and allowed secret-class references. | Secret-like values are rejected or redacted; only approved secret-class references remain. | Secret value, private credential material, or live credential location is retained. | EV-OQ-018-01 |
| OQ-019 | Verify retry, bounded recovery, and reconfiguration behavior. | URS-018, QR-002, QR-013, CFG-012, CFG-017 | Run fixtures for transient failure, exhausted retry budget, reconfiguration-required condition, and recovery with preserved blocker. | Retry count is bounded; exhaustion records blocker; reconfiguration requires explicit approval; recovered state preserves evidence. | Infinite retry, silent success after exhaustion, or unapproved reconfiguration occurs. | EV-OQ-019-01 |
| OQ-020 | Verify self-improvement finding capture. | URS-013, QR-008, CFG-018 | Run fixture with operational finding, impact, detection signal, safe remediation candidate, validation/POC plan, priority, and linked evidence. | Durable finding or CAPA candidate contains all required fields and is not left only in chat or transient terminal output. | Required CAPA fields are missing or finding is not durable. | EV-OQ-020-01 |
| OQ-021 | Verify deviation and CAPA routing. | URS-013, URS-014, QR-006, QR-008, CFG-018 | Run fixtures for critical deviation, recurring major deviation, minor documentation deviation, and accepted limitation. | Routing assigns severity, owner role, approval route, retest decision, CAPA requirement, and final disposition placeholder. | Critical or recurring issue lacks deviation/CAPA route or is closed by mechanical evidence alone. | EV-OQ-021-01 |
| OQ-022 | Verify OQ evidence package completeness. | URS-020, QR-014, CFG-014, CFG-020 | Review all OQ evidence IDs, deviations, retests, CAPA links, and reviewer dispositions before CSV-OQ-03 authoring. | Evidence pack is complete enough for OQ report preparation or has documented blockers. | Missing evidence ID, unreviewed deviation, missing verification status, or incomplete traceability. | EV-OQ-022-01 |

## Evidence ID Register

| Evidence ID | OQ step | Required retained artifact |
| --- | --- | --- |
| EV-OQ-001-01 | OQ-001 | Entry gate review record and approval/waiver reference. |
| EV-OQ-002-01 | OQ-002 | Positive preflight fixture output and readiness evidence. |
| EV-OQ-003-01 | OQ-003 | Negative preflight fixture outputs and blocker taxonomy. |
| EV-OQ-004-01 | OQ-004 | Priority planning fixture output. |
| EV-OQ-005-01 | OQ-005 | Traceability record fixture. |
| EV-OQ-006-01 | OQ-006 | Atomization dry-run output and duplicate-prevention evidence. |
| EV-OQ-007-01 | OQ-007 | Rendered dispatch prompt integrity evidence. |
| EV-OQ-008-01 | OQ-008 | Dispatch refusal and not-consumed blocker evidence. |
| EV-OQ-009-01 | OQ-009 | Context switch and handoff fixture evidence. |
| EV-OQ-010-01 | OQ-010 | Repository-state refusal matrix. |
| EV-OQ-011-01 | OQ-011 | Safe remediation dry-run/apply split evidence. |
| EV-OQ-012-01 | OQ-012 | Validator/check dispatch policy evidence. |
| EV-OQ-013-01 | OQ-013 | CI status classification matrix. |
| EV-OQ-014-01 | OQ-014 | Stale status deduplication evidence. |
| EV-OQ-015-01 | OQ-015 | Merge gate refusal matrix. |
| EV-OQ-016-01 | OQ-016 | Merge or release-support decision evidence sample. |
| EV-OQ-017-01 | OQ-017 | Evidence manifest and altered-artifact verification sample. |
| EV-OQ-018-01 | OQ-018 | Secret redaction and prohibited-field evidence. |
| EV-OQ-019-01 | OQ-019 | Retry, recovery, and reconfiguration evidence. |
| EV-OQ-020-01 | OQ-020 | Self-improvement finding capture evidence. |
| EV-OQ-021-01 | OQ-021 | Deviation/CAPA routing evidence. |
| EV-OQ-022-01 | OQ-022 | OQ evidence completeness review. |

## Pass, Fail, and Report Handoff

CSV-OQ-02 passes when every OQ step passes or has an approved deviation
disposition and every required evidence ID is retained with integrity status.
CSV-OQ-02 fails or is blocked when any critical refusal path does not fail
closed, any required evidence is missing or unverifiable, or any critical
agent-produced evidence lacks attribution/integrity verification without an
approved deviation.

CSV-OQ-02 must not conclude release to PQ. It hands the executed evidence pack,
deviation log, retest records, CAPA links, and residual blockers to CSV-OQ-03.

## Approval

Approval of this protocol authorizes CSV-OQ-02 execution only after entry
criteria are satisfied. It does not approve OQ results, close deviations, start
PQ, or release the validated package. Mechanical attestation supports evidence
origin and integrity but does not replace accountable human approval.
