# CSV-09 Validation Plan and Protocol Strategy

## Purpose

This document defines the validation plan and protocol strategy for ORDO before
IQ, OQ, PQ, final traceability reconciliation, or final validation reporting
starts. It converts the intended use, boundary inventory, role model, supplier
assessment, data-integrity assessment, risk assessment, requirements, and
traceability model into a governed execution strategy.

CSV-09 is the control point that prevents unmanaged evidence generation. No IQ,
OQ, or PQ evidence should be accepted as formal validation evidence unless it
was produced under an approved protocol or accepted through a documented
deviation with impact assessment.

## Scope

The validation strategy covers ORDO as a product-neutral orchestration toolkit
for controlled software delivery workflows. It covers the configured ORDO
scripts, libraries, templates, validation documents, controlled configuration,
audit and state behavior, issue and pull-request workflow integration,
validation checks, dispatch controls, merge or release-support gates, cleanup
behavior, and evidence capture behavior identified by CSV-02.

The strategy does not validate any downstream product, target repository,
external service internals, credential lifecycle process, human quality system,
or final business release decision. Those remain outside the ORDO validation
boundary unless a deployment-specific assessment brings them into scope.

## Dependencies

CSV-09 depends on these approved or explicitly dispositioned inputs:

| Input | Required contribution to CSV-09 |
| --- | --- |
| CSV-01 Intended use and regulated impact | Defines the validation posture and non-intended uses. |
| CSV-02 System boundaries and configuration inventory | Defines the controlled baseline, external dependencies, and evidence locations. |
| CSV-03 Roles, training, and approval matrix | Defines authors, executors, reviewers, approvers, independence, and handoff rules. |
| CSV-04 Supplier and service provider assessment | Defines dependency classes, supplier evidence, local controls, and residual supplier risks. |
| CSV-05 Data integrity and electronic record assessment | Defines record criticality, auditability, retention, and electronic-record controls. |
| CSV-05A Agent evidence and attestation model | Defines required attribution and integrity controls for agent-produced evidence. |
| CSV-06 Quality risk assessment and criticality matrix | Defines risk-based test depth and priority. |
| CSV-07 User requirements and acceptance criteria | Defines verifiable requirements and acceptance criteria. |
| CSV-08 Traceability matrix template | Defines traceability fields and reconciliation structure. |

If a dependency is incomplete when CSV-09 is drafted, the validation owner must
mark the dependency as provisional and block formal protocol approval until the
dependency is completed or dispositioned.

## Validation Approach

ORDO validation uses a risk-based protocol suite:

- IQ verifies that the approved baseline is identifiable, installed or
  available, configured, versioned, and capable of producing controlled
  evidence.
- OQ verifies critical operating behavior under normal, boundary, refusal, and
  simulated-failure conditions.
- PQ verifies that the approved workflow performs acceptably under a
  production-like orchestration wave using controlled evidence and review.

The protocol suite combines:

- scripted checks for repeatable command behavior, syntax, regression behavior,
  and state or audit outputs;
- manual review checks for intended use, role coverage, supplier assessment,
  risk acceptance, requirements quality, traceability, and release rationale;
- dry-run checks for workflows that would otherwise mutate controlled systems;
- simulated failure checks for unsafe dispatch, missing prerequisites, failed
  checks, incomplete evidence, context mismatch, and cleanup refusal;
- production-like wave evidence for end-to-end PQ under realistic operating
  constraints.

Automated pass/fail output is evidence, not approval. Human or organizational
approval remains a separate accountable decision under CSV-03.

## Protocol Suite

| Protocol | Primary objective | Evidence style | Release decision |
| --- | --- | --- | --- |
| CSV-IQ-01 | Define the IQ checks for baseline identity, configuration, dependency availability, and evidence paths. | Approved protocol with command list, manual checks, expected evidence, and stop conditions. | Authorizes IQ execution. |
| CSV-IQ-02 | Execute IQ and capture baseline evidence. | Command transcripts, version records, configuration summaries, evidence path checks, attestation status, deviations. | Provides evidence for IQ report. |
| CSV-IQ-03 | Summarize IQ results and decide release to OQ. | IQ report, evidence index, deviations, residual risks, approval record. | Releases, blocks, or conditionally releases to OQ. |
| CSV-OQ-01 | Define OQ checks for critical operating semantics and failure behavior. | Approved protocol mapped to risks, requirements, and traceability rows. | Authorizes OQ execution. |
| CSV-OQ-02 | Execute OQ and manage deviations. | Scripted results, dry-run results, simulated-failure evidence, refusal logs, state/audit records, deviations. | Provides evidence for OQ report. |
| CSV-OQ-03 | Summarize OQ results and decide release to PQ. | OQ report, evidence index, deviation disposition, residual risks, approval record. | Releases, blocks, or conditionally releases to PQ. |
| CSV-PQ-01 | Define PQ checks for a production-like orchestration wave. | Approved protocol with scenario, acceptance criteria, data controls, rollback expectations, and evidence plan. | Authorizes PQ execution. |
| CSV-PQ-02 | Execute PQ and capture the production evidence pack. | Production-like run manifest, repository-platform references, CI provider results, evidence-store artifacts, state/audit records, deviations. | Provides evidence for PQ report. |
| CSV-PQ-03 | Summarize PQ results and decide production readiness. | PQ report, residual-risk statement, readiness decision, approval record. | Supports final validation reconciliation. |

## IQ Strategy

IQ must prove that the qualified baseline is identifiable and ready for
controlled protocol execution.

Minimum IQ coverage:

- repository revision, branch or release identifier, and source digest;
- controlled scripts, libraries, templates, validation documents, and test
  assets present at the approved revision;
- operating system family, shell, version-control client, JSON processor, issue
  or pull-request client, CI or validation runner, optional terminal
  multiplexer, and optional connectors identified or marked not used;
- controlled configuration values available with secrets redacted;
- audit, state, and evidence locations writable by authorized executors and
  retrievable by reviewers;
- evidence attribution and cryptographic integrity controls available for
  critical mechanical evidence, or a preapproved deviation path;
- all optional dependencies classified as in scope, not used, or out of scope.

IQ entry criteria:

- CSV-09 and CSV-10 are approved.
- CSV-05A evidence controls are ready enough to classify critical evidence.
- The protocol executor has required role authorization and training or
  identity record.
- The execution baseline is clean, identifiable, and approved for IQ.

IQ exit criteria:

- all required baseline checks pass or have approved deviation disposition;
- every evidence artifact is listed in the IQ evidence index;
- any missing or failed attribution/integrity control is dispositioned;
- CSV-IQ-03 approves release to OQ.

## OQ Strategy

OQ must prove that ORDO controls operate as designed under defined conditions.
OQ focuses on high-risk workflow semantics rather than exhaustive coverage of
every informational output.

Minimum OQ coverage:

- readiness preflight and refusal behavior;
- project or repository binding checks;
- dispatch planning, dependency handling, ready/blocked classification, and
  atomization signals;
- dispatch execution boundaries, prompt integrity, assignment state, and audit
  records;
- validation result handling for pass, fail, pending, timeout, skipped, and
  delegated outcomes;
- pull-request blocker detection and merge or release-support refusal behavior;
- controlled-operation evidence requirements for temporary privileged work;
- post-merge or post-release cleanup refusal on dirty, ambiguous, or mismatched
  state;
- continuation or ready-queue behavior when work remains;
- findings capture into durable records instead of transient chat or terminal
  scrollback;
- evidence capture and attestation checks for agent-produced evidence.

OQ entry criteria:

- CSV-IQ-03 is approved.
- CSV-06 risk controls and CSV-07 acceptance criteria are mapped to OQ steps.
- CSV-08 traceability fields are available for OQ evidence.
- Test data, mock responses, dry-run setup, and simulated failure conditions are
  approved.

OQ exit criteria:

- all critical OQ steps pass or have approved deviation disposition;
- required refusal paths are demonstrated, not only happy paths;
- deviations are closed, accepted with rationale, or linked to CAPA;
- CSV-OQ-03 approves release to PQ.

## PQ Strategy

PQ must prove that ORDO performs acceptably in a production-like orchestration
wave within the approved intended use and operating constraints.

The PQ scenario should include:

- a controlled backlog or issue set with known ready, blocked, and completed
  states;
- at least one bounded dispatch path;
- evidence of validation status collection from the configured CI provider or
  approved local validation path;
- evidence of blocker reporting or merge/readiness decision support;
- evidence of cleanup, continuation, or validated-state handoff as applicable;
- review of generated evidence for completeness, attribution, integrity, and
  traceability.

PQ entry criteria:

- CSV-OQ-03 is approved.
- the production-like scenario, acceptance criteria, rollback plan, and evidence
  retention plan are approved;
- operators, executors, reviewers, and any agent CLI actors are authorized for
  the scenario;
- critical evidence attribution and integrity controls are available or
  deviations are preapproved.

PQ exit criteria:

- the production-like wave meets approved acceptance criteria;
- evidence is complete enough for final traceability reconciliation;
- open deviations and residual risks are documented and accepted by the
  configured approval route;
- CSV-PQ-03 records the production readiness decision.

## Protocol Authoring Requirements

Every IQ, OQ, and PQ protocol must include:

- CSV ID, issue number, protocol version, author, reviewer, approver, and
  approval date;
- intended baseline revision and configuration scope;
- prerequisite documents and entry criteria;
- execution roles and independence requirements;
- step ID, objective, risk or requirement reference, action, expected result,
  evidence artifact, and acceptance criterion;
- stop conditions for unsafe state, missing evidence, failed integrity checks,
  or unapproved scope changes;
- deviation initiation rules;
- retest rules and evidence replacement rules;
- exit criteria and report handoff requirements.

Protocol steps should be precise enough that a trained executor can reproduce
them, but not so environment-specific that the generic ORDO strategy hardcodes a
particular repository, provider, host, user, session, path, or agent name.

## Evidence Capture Plan

Evidence must be contemporaneous, attributable, reviewable, and retained in an
approved evidence store.

Expected evidence classes:

- command output and exit status for scripted checks;
- validation runner output, CI provider status, job identifier, and immutable
  run reference when external validation is used;
- repository platform issue, pull-request, commit, review, and branch
  references when they are used as validation evidence;
- audit log lines, state files, cleanup records, findings records, and
  controlled-operation records;
- dry-run transcripts for mutating paths that are not executed during protocol
  testing;
- simulated failure evidence showing the expected refusal or deviation path;
- screenshots only when a visual or UI state is required and cannot be captured
  more reliably as text or structured data;
- evidence manifests with artifact path, digest or signature reference,
  timestamp, actor role, protocol step, and reviewer disposition.

Secret values, tokens, private keys, and credential material must never be
stored as evidence. Evidence may reference a secret class or secret-store
identifier only when safe to disclose.

Agent-produced evidence must account for CSV-05A. Critical evidence produced by
an agent CLI must include cryptographic attribution and integrity verification,
or else it must be handled as a deviation unless the validation owner classifies
the artifact as non-critical supporting material.

## Deviation Strategy

A deviation is required when:

- execution differs from an approved protocol;
- a prerequisite, approval, role, or training requirement is missing;
- evidence is missing, incomplete, unverifiable, or stored in an uncontrolled
  location;
- a required command, check, dry-run, simulated failure, or production-like step
  fails;
- a critical evidence signature, digest, or attribution check fails or is
  unavailable;
- an external dependency behaves outside approved assumptions;
- a step is skipped, repeated, modified, or replaced without prior approval.

Deviation severity:

- Critical: may invalidate phase evidence, bypass a critical control, weaken
  data integrity, or affect release readiness.
- Major: affects a requirement, risk control, repeatability, or traceability but
  has a bounded retest or mitigation path.
- Minor: documentation or execution variance with no credible impact on the
  validation decision.

Deviation records must include issue or protocol reference, step ID, observed
condition, expected condition, severity, impact assessment, root-cause analysis
proportionate to severity, immediate correction, CAPA link when required, retest
decision, evidence impact, owner, approval route, and closure status.

## CAPA, Retest, and Acceptance Rules

CAPA is required for critical deviations, recurring major deviations, systemic
process gaps, failed corrective actions, or any issue that could recur without a
preventive control.

Retest is required when a failed or changed step is needed to support an
acceptance criterion. Retest evidence must identify the original failure,
correction, changed baseline if any, retest step, result, and whether prior
evidence was superseded or retained as failure evidence.

Acceptance with rationale is allowed only when:

- impact is bounded and documented;
- no critical requirement is left unverified;
- residual risk is accepted by the required approval route;
- final traceability clearly marks the accepted deviation.

Critical deviations cannot be silently waived. They must be closed, corrected
and retested, or explicitly accepted by the release approval route before final
validation release.

## Traceability Strategy

CSV-08 is the governing structure for traceability. CSV-09 requires each
protocol step and report conclusion to maintain links across:

- intended use and boundary statement;
- requirements and acceptance criteria;
- risk controls and supplier assumptions;
- protocol step and expected result;
- evidence artifact and integrity status;
- deviation or CAPA record when applicable;
- reviewer disposition and phase report decision.

Traceability must show both positive proof and refusal proof. For high-risk
controls, evidence that ORDO refuses unsafe operation is as important as
evidence that it completes safe operation.

## Approval Strategy

Approvals must follow CSV-03:

- validation owner approves protocol strategy and phase protocols;
- quality reviewer reviews compliance, independence, deviation handling, and
  record sufficiency;
- system owner approves operational readiness, PQ scenario, and residual-risk
  acceptance where required;
- technical owner or technical reviewer confirms command accuracy, feasibility,
  and evidence completeness where required;
- release approver accepts the final validation package, not individual command
  output alone.

Approvals must be explicit, attributable, and retained with the validation
package. Automated attestation may prove artifact origin and integrity, but it
does not replace accountable review or release approval.

## Change Control During Protocol Execution

After CSV-09 approval, the following changes require impact assessment before
formal protocol evidence is generated or accepted:

- controlled baseline revision, branch, release package, or source digest;
- protocol step, expected result, acceptance criterion, or evidence requirement;
- configuration item, external dependency, tool version, credential scope, or
  evidence store;
- validation runner, CI provider workflow, local checker, or script under test;
- evidence attribution or integrity mechanism;
- operator role, reviewer independence, or approval route.

The impact assessment must classify the change as no-impact, minor, major, or
revalidation-required and must state which CSV IDs, risks, requirements,
protocol steps, and evidence artifacts are affected.

## Final Validation Readiness

CSV-09 is complete when:

- IQ, OQ, and PQ strategy is approved before protocol execution;
- entry and exit criteria are defined for each phase;
- evidence capture, deviation, CAPA, retest, and approval rules are defined;
- #87 evidence attribution and cryptographic integrity expectations are
  accounted for without attempting to implement them in this document;
- protocols can be authored from this plan without adding deployment-specific
  hardcoded names or paths;
- final validation reconciliation in CSV-VAL-01 and CSV-VAL-02 has clear inputs.
