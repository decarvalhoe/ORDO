# CSV-OPS-01 Maintaining Validated State: Change, Incident, CAPA, and Periodic Review

## Purpose

This procedure defines how the ORDO system under validation is maintained after
CSV-VAL-02 and how future controlled changes, incidents, deviations, CAPA, and
periodic reviews are governed.

Current validation state: `FINAL VALIDATION RELEASE REFUSED`.

Current production readiness: `NOT PRODUCTION READY`.

Current release status: `NOT RELEASED`.

CSV-VAL-02 records that `DEV-OQ-001` and `DEV-PQ-001` remain open. This
procedure therefore governs the current blocked and non-release validation state.
It does not convert the current dossier into a released or production-ready
baseline. Controls that refer to a future validated state apply only after a
later approved release package explicitly changes the release disposition.

## Scope

This procedure applies to controlled ORDO validation and operational records for:

- source code and scripts;
- configuration examples and deployment-specific configuration guidance;
- injected rules, rule sets, prompts, templates, and operating instructions;
- generated artifacts used as evidence or operator inputs;
- CI, workflow, validation, and verification definitions;
- issue-tracker records used for change control, incidents, deviations, CAPA,
  periodic review, and release readiness decisions.

Out of scope:

- validating a downstream product or deployment that uses ORDO;
- approving production use from the current blocked dossier;
- replacing accountable human review or approval;
- choosing a repository platform, issue tracker, CI provider, host topology,
  terminal multiplexer, account model, or agent vendor.

## Current Blocked-State Controls

Until a later approved release package supersedes CSV-VAL-02, the system under
validation must be operated and governed as a blocked, non-release package.

Required controls:

- retain CSV-VAL-01, CSV-VAL-02, `DEV-OQ-001`, and `DEV-PQ-001` as active
  controlled records;
- do not claim production readiness, final validation release, or released
  validated-state operation;
- do not use IQ completion, green CI checks, advisory summaries, or generated
  evidence alone as a release approval;
- do not close, waive, downgrade, or supersede `DEV-OQ-001` or `DEV-PQ-001`
  without retained responsible review evidence;
- route any attempt to bypass the blocked disposition through change control and
  deviation review before execution;
- require OQ remediation, OQ retest or execution, PQ entry retest, PQ execution,
  final traceability update, CSV-VAL-02 replacement, and accountable approval
  before any future release decision.

## Change-Control Rules

Every proposed change after the controlled baseline must have a change record in
the configured issue tracker before it is used as validation evidence or release
support. The record must identify the affected CSV IDs, controlled artifacts,
risk classification, required evidence, approval route, and rollback or
reversion plan.

### Controlled Change Classes

| Change class | Examples | Minimum control |
| --- | --- | --- |
| Source code | application logic, libraries, command behavior, safety checks, refusal paths | Impact assessment, focused tests, regression risk review, traceability update when requirements or risks are affected. |
| Scripts | validation helpers, dispatch, cleanup, verification, evidence generation, recovery or rollback helpers | Dry-run or preview evidence where available, bounded execution evidence, shell/static checks, and review of mutation boundaries. |
| Configuration examples | sample config files, environment placeholders, onboarding defaults, state/profile examples | Secret and live-identifier scan, deployment-neutral review, intended-use impact assessment. |
| Injected rules and rule sets | system prompts, operator rules, agent rules, policy snippets, handoff templates | Review for role boundaries, release authority limits, evidence retention, and unsafe automation implications. |
| Generated artifacts | profiles, state patches, traceability rows, verification inputs, reports, evidence manifests | Schema/version check, redaction check, source-reference integrity check, and reviewer disposition. |
| CI and workflow changes | check definitions, workflow triggers, validation runners, artifact retention, merge gates | Controlled workflow review, check coverage review, failure-mode review, and evidence-retention assessment. |
| Validation dossier changes | protocols, reports, deviations, CAPA records, indexes, approval records | CSV owner review, traceability update, approval-route confirmation, and retained rationale. |

### Change Classification

| Classification | Criteria | Required disposition |
| --- | --- | --- |
| Administrative | spelling, formatting, index link, or non-substantive wording with no control impact | Reviewer confirms no validation impact and records rationale. |
| No validation impact | change does not affect intended use, controlled behavior, evidence integrity, risk control, or release readiness | Impact assessment retained; focused check evidence as appropriate. |
| Minor validation impact | affects documentation, non-critical operator guidance, or non-critical generated artifacts without changing controlled behavior | Impact assessment, focused regression checks, updated traceability if affected. |
| Major validation impact | affects controlled behavior, safety/refusal paths, evidence generation, CI gates, configuration controls, or rule execution | Impact assessment, regression evidence, deviation/CAPA review if related to failure, and requalification assessment. |
| Revalidation required | affects intended use, regulated impact, critical controls, release readiness, approval boundaries, evidence integrity, or OQ/PQ acceptance criteria | Approved revalidation plan before use for release; update protocol/report strategy and traceability. |

### Baseline Change Rules

- A change must not be merged into a controlled release baseline unless its
  change record has documented impact assessment and required reviewer
  disposition.
- A change that touches a critical control must identify the impacted
  requirement, risk, test, and evidence record.
- A change that alters rule sets or generated artifacts must demonstrate that
  release approval remains a human decision.
- A change that alters CI/workflows must define how failed, skipped, cancelled,
  or missing checks are interpreted.
- A change that alters evidence generation must address attribution, integrity,
  redaction, retention, and reproducibility.
- A change related to `DEV-OQ-001` or `DEV-PQ-001` must preserve the blocked
  state unless it explicitly supplies approved disposition and retest evidence.

## Impact Assessment Template

Use this checklist for each future change after baseline.

| Field | Required entry |
| --- | --- |
| Change record ID | Configured issue-tracker record or change-control identifier. |
| Change summary | Short description of what changes and why. |
| Affected artifact classes | Source, script, config example, injected rule, generated artifact, CI/workflow, validation dossier, or other controlled item. |
| Affected CSV IDs | CSV document, protocol step, requirement, risk, or evidence reference. |
| Current validation state | Blocked/non-release, released, superseded, revalidation required, or retired. |
| Production readiness impact | Confirm whether the change affects production readiness or release claims. |
| Intended-use impact | Confirm whether intended use or regulated-impact assumptions change. |
| Data/evidence integrity impact | Confirm whether records, signatures, hashes, retention, redaction, or attribution controls change. |
| Rule or automation impact | Confirm whether the change affects operator rules, agent behavior, generated decisions, or mutation boundaries. |
| CI/workflow impact | Confirm whether check semantics, workflow triggers, evidence artifacts, or retention change. |
| Security and secret impact | Confirm no secret, credential, private host, private path, or live identifier is added to controlled artifacts. |
| Deviation/CAPA link | Link related deviation or CAPA record if the change corrects a failure or systemic issue. |
| Required evidence | Tests, review records, dry-run outputs, verification reports, traceability updates, or protocol evidence. |
| Revalidation decision | No impact, focused regression, partial requalification, or full revalidation required. |
| Reviewer roles | Technical owner, validation owner, quality reviewer, system owner, operations owner, as applicable. |
| Approval outcome | Approved, rejected, deferred, blocked, or approved with limitations. |
| Rollback/reversion plan | How to return to the prior controlled state if the change fails. |

## Incident, Deviation, and CAPA Process

All incidents, deviations, and CAPA records must be tracked in the configured
issue tracker or controlled quality-record system. The procedure intentionally
does not require a specific platform.

### Incident Intake

Create an incident record when any of the following occurs:

- observed behavior differs from approved procedures, protocols, acceptance
  criteria, or release restrictions;
- a controlled script, rule, workflow, or generated artifact behaves
  unexpectedly;
- validation evidence is missing, corrupt, unverifiable, unauthenticated, or
  materially incomplete;
- CI/workflow behavior differs from the controlled interpretation;
- a user reports unsupported production use or a release-readiness claim not
  supported by the current dossier;
- an external dependency, issue tracker, CI service, evidence store, or secret
  store condition affects reviewability or retention.

### Incident Record Fields

| Field | Required entry |
| --- | --- |
| Record type | Incident, deviation, CAPA, or combined incident/deviation. |
| Discovery source | Operator, reviewer, automation, periodic review, external audit, or user report. |
| Date/time | Timestamp in a controlled, reviewable format. |
| Affected baseline | Source revision, document version, release package, or controlled state reference. |
| Affected CSV IDs | Requirements, risks, controls, tests, or evidence records impacted. |
| Severity | Critical, major, minor, or informational with rationale. |
| Current validation impact | No impact, possible impact, confirmed impact, release-blocking, or revalidation required. |
| Immediate containment | Stop use, retain evidence, revert, disable feature, update warning, or other containment. |
| Evidence references | Immutable artifact references, hashes, signed attestations, logs, reports, or review notes. |
| Deviation decision | Not a deviation, deviation opened, linked to existing deviation, or escalated to CAPA. |
| CAPA decision | Not required with rationale, required, linked, or pending quality review. |
| Closure criteria | Corrective action, preventive action, retest evidence, approval, or accepted residual risk. |

### Deviation Routing

A deviation is required when:

- protocol execution differs from approved steps;
- required evidence is absent, unverifiable, altered, unsigned when required, or
  inconsistently attributed;
- a controlled change bypasses required impact assessment;
- a release restriction is contradicted or bypassed;
- a critical or major incident may affect validated-state conclusions;
- periodic review identifies overdue CAPA, stale evidence, or uncontrolled
  configuration drift.

Deviation severity:

- Critical: could invalidate evidence, bypass a critical control, affect release
  readiness, or compromise data/evidence integrity.
- Major: affects a requirement, risk control, repeatability, traceability, or
  reviewability but has a bounded correction or retest path.
- Minor: documentation or execution variance with no credible impact on a
  validation decision, supported by rationale.

### CAPA Routing

CAPA is required when a deviation or incident is:

- critical;
- recurring;
- systemic;
- caused by ineffective procedure, training, review, tooling, or automation;
- associated with repeated evidence-integrity failure;
- associated with a blocked release gate that cannot be resolved by a bounded
  correction and retest.

CAPA records must include root cause, correction, preventive action, owner role,
due date, verification of effectiveness, impacted CSV IDs, and closure approval.

Operational findings may be linked to the active CAPA or self-improvement
umbrella when one is configured, or to a dedicated CAPA record when the finding
requires independent tracking.

## Mechanical Evidence Attribution and Integrity

Agent-produced evidence must have mechanical attribution and integrity controls
before it is used for validation or release decisions. Human approval remains a
separate accountable decision and must not be replaced by mechanical signatures,
digests, generated summaries, or CI status.

For critical or release-supporting agent-produced evidence, retain:

- evidence artifact identifier and CSV reference;
- actor role or agent label without vendor-oriented defaults;
- source revision or controlled baseline reference;
- timestamp and command/action summary;
- artifact checksum or immutable reference;
- signature or attestation verification result when the evidence model requires
  signing;
- reviewer disposition and approval record.

Missing, failed, expired, revoked, or unverifiable signature or attestation
verification must be routed as a deviation unless responsible review classifies
the evidence as non-critical supporting material and records rationale.

The current CSV-VAL-02 package does not include executed critical OQ/PQ evidence
for final release use. Any future OQ/PQ evidence used to support release must
meet the applicable attribution and integrity controls before release review.

## Periodic Review

### Cadence

| Review type | Minimum cadence | Purpose |
| --- | --- | --- |
| Blocked-state review | Monthly while CSV-VAL-02 remains refused and open release blockers remain active | Confirm restrictions remain visible, deviations remain open or dispositioned, and no unsupported release claim exists. |
| Change backlog review | Monthly or before any controlled release decision | Confirm open changes have impact assessment and required evidence. |
| Incident/deviation/CAPA review | Monthly, and immediately for critical records | Confirm containment, ownership, due dates, retest evidence, and closure readiness. |
| Evidence integrity review | Quarterly, or before any phase/release decision | Confirm hashes, attestations, retention, redaction, and reviewability remain intact. |
| Full validated-state review | At least annually after any future approved release | Confirm intended use, baseline, dependencies, incidents, CAPA, training, evidence retention, and revalidation need. |

The blocked-state review cadence starts immediately because the current package
is refused and not released. The full validated-state review cadence starts only
after a future approved release package exists.

### Periodic Review Checklist

- Current release disposition is correctly stated and visible.
- `DEV-OQ-001` and `DEV-PQ-001` are still open, dispositioned, or superseded
  with retained approval evidence.
- No production-readiness or release claim exists without approved release
  evidence.
- Open changes have impact assessments and required evidence plans.
- Incidents, deviations, and CAPA records are triaged, owned, and within due
  dates.
- Evidence artifacts remain accessible, reviewable, checksum-verifiable, and
  redaction-safe.
- Agent-produced critical evidence has required attribution and integrity
  verification.
- CI/workflow definitions still match the controlled interpretation of pass,
  fail, skip, cancellation, timeout, and missing evidence.
- Injected rules and rule sets still preserve human approval boundaries and
  mutation safeguards.
- Configuration examples remain generic and free of secret values or live
  identifiers.
- Dependencies, external services, and issue-tracker/evidence-store access
  remain adequate for review and retention.
- Training or role assignments remain current for operators, reviewers, and
  approvers.
- Revalidation triggers have been evaluated and recorded.

### Periodic Review Output

Each review must record:

- review period;
- review participants by role;
- current validation state;
- open change, incident, deviation, and CAPA counts;
- evidence-integrity exceptions;
- revalidation decision;
- required actions, owners, and due dates;
- accountable review disposition.

## Regression, Requalification, and Revalidation Triggers

### Regression Triggers

Focused regression evidence is required when a change affects:

- controlled scripts or command behavior;
- validation helpers or evidence generation;
- generated profile, state, or report schemas;
- CI/workflow behavior or check interpretation;
- operator-facing rules, templates, or injected instructions;
- redaction, retention, checksum, or signature-verification behavior;
- dispatch, recovery, cleanup, merge-support, or release-support guardrails.

### Requalification Triggers

Partial requalification is required when:

- a controlled dependency changes in a way that may affect reviewability or
  repeatability;
- host or execution environment assumptions materially change;
- issue tracker, CI, evidence store, or secret store integration behavior
  changes;
- critical configuration item identity changes;
- an incident indicates a controlled process may no longer operate as specified;
- periodic review identifies uncontrolled drift from the approved baseline.

### Revalidation Triggers Before Future Release Decision

Before any future release decision can replace CSV-VAL-02 refusal, the following
must be true:

- `DEV-OQ-001` has approved disposition and OQ entry is retested;
- required OQ operating tests are executed or dispositioned under approved
  protocol strategy;
- CSV-OQ-03 is updated with a controlled release-to-PQ decision or approved
  limitation;
- `DEV-PQ-001` has approved disposition and PQ entry is retested;
- required PQ production-like tests are executed or dispositioned under approved
  protocol strategy;
- critical OQ/PQ agent-produced evidence has attribution and integrity
  verification, or deviations are opened and dispositioned;
- final traceability is updated to reflect executed evidence, deviations,
  CAPA, residual risks, and approval status;
- CSV-VAL-02 is replaced or superseded by a new final validation report;
- accountable human approval is recorded according to the approval matrix.

Full revalidation or a new validation cycle is required when:

- intended use changes;
- regulated-impact classification changes;
- critical risk controls change;
- final approval boundaries change;
- evidence integrity controls change materially;
- automation gains authority to approve, release, waive, or close controlled
  records without human approval;
- a critical incident or CAPA identifies systemic validation-control failure;
- the configured operating context is no longer represented by the approved
  baseline and protocols.

## Future Released-State Controls

If a future approved release package changes the current disposition, maintaining
validated state continues under this procedure with these additional controls:

- every controlled change must be impact-assessed before use in the released
  baseline;
- incidents must be assessed for validated-state impact within the configured
  severity timelines;
- CAPA effectiveness must be verified and retained;
- periodic review must confirm continued intended-use fit and evidence
  retention;
- regression or requalification must be completed before affected controls are
  relied upon;
- release limitations, residual risks, and approved operating constraints must
  remain visible to operators and reviewers.

These future controls do not apply as evidence of current production readiness.
They define the expected operating model only after a later approved release.

## Records and Retention

Retain the following records for the configured retention period:

- change records and impact assessments;
- incident, deviation, and CAPA records;
- periodic review reports;
- revalidation decisions and protocol updates;
- evidence manifests, checksums, signatures, and verification outcomes;
- human approval records;
- superseded baseline references and release restrictions.

Records must remain reviewable without relying on terminal scrollback, transient
chat history, unretained local files, or private credentials. References to
external systems must use stable, reviewable identifiers configured for the
deployment and must not expose secrets.

## Approval and Ownership

| Activity | Owner role | Required reviewers |
| --- | --- | --- |
| Change impact assessment | Technical owner or operations owner | Validation owner; quality reviewer when validation impact is possible. |
| Deviation disposition | Validation owner | Quality reviewer; system owner for release impact. |
| CAPA approval and closure | Quality reviewer | Operations owner and affected technical or system owner. |
| Periodic review | Operations owner | System owner and quality reviewer. |
| Revalidation decision | Validation owner | System owner, technical owner, and quality reviewer. |
| Future release readiness | System owner | Validation owner, quality reviewer, and required approver roles. |

No approval is granted by this procedure itself. Approval requires a controlled,
attributable, retained record by the accountable role.

## Blocked-State Disposition

CSV-OPS-01 is active for governing the current blocked validation state and for
defining future maintaining-state controls. It does not release ORDO, does not
approve production readiness, does not close `DEV-OQ-001` or `DEV-PQ-001`, and
does not supersede CSV-VAL-02.

The current disposition remains:

- `FINAL VALIDATION RELEASE REFUSED`;
- `NOT PRODUCTION READY`;
- `NOT RELEASED`.
