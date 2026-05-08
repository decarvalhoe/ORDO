# CSV-03 Roles, Training, and Approval Matrix

## Purpose

This document defines the role categories, responsibilities, training evidence,
approval gates, independence expectations, and operator handoff rules for an
ORDO validation package. It applies to any repository, provider, agent pool, or
deployment target that adopts ORDO as a controlled operations framework.

CSV-03 depends on the approved CSV-01 intended-use and regulated-impact
assessment. If CSV-01 classifies a use case as higher risk, this matrix must be
expanded before protocol execution starts.

## Role Categories

| Role category | Primary responsibility | May execute work | May review own work | Required evidence |
| --- | --- | --- | --- | --- |
| Validation owner | Owns the validation plan, scope, acceptance strategy, and release recommendation. | No, except for documented administrative tasks. | No | Appointment record, CSV training record, approved validation plan. |
| System owner | Owns intended use, configuration boundaries, operational readiness, and business acceptance. | Yes, for business configuration tasks when trained. | No | System ownership record, intended-use approval, configuration training. |
| Quality reviewer | Reviews CSV deliverables for compliance, independence, completeness, and deviation handling. | No | No | Quality role authorization, CSV review training, review checklist. |
| Technical reviewer | Reviews technical correctness of protocols, scripts, commands, logs, and evidence links. | No, unless independent review is reassigned. | No | Technical competency evidence, toolchain training, review notes. |
| Security or data-integrity reviewer | Reviews identity, access, audit trail, retention, signing, and data-integrity controls. | No | No | Control-domain training, access review evidence, integrity assessment. |
| Protocol author | Drafts VMP, URS, risk assessment, IQ, OQ, PQ, deviation, report, or release-package content. | No, unless separately assigned as executor. | No | Author assignment, template training, document history. |
| Protocol executor | Runs approved commands or manual steps and records contemporaneous evidence. | Yes | No | Execution authorization, command training, run log, evidence manifest. |
| Orchestration operator | Dispatches or supervises automated work within the approved scope and stops unsafe execution. | Yes, within approved runbooks. | No | Operator authorization, runbook training, handoff record. |
| Execution agent | Produces mechanical evidence, code changes, logs, reports, or observations under supervision. | Yes, within assigned scope. | No | Agent identity record, scope binding, mechanical attestation where required. |
| Release approver | Makes the accountable decision to accept validation results and authorize production use. | No | No | Approval authority record, final package approval, unresolved-risk acceptance. |
| Records custodian | Maintains controlled records, evidence retention, version history, and retrieval procedures. | No | No | Records procedure training, retention index, archive verification. |

One person may hold multiple human role categories only when the risk assessment
permits it and the approval matrix still preserves required independence. An
execution agent or automated service may attest authorship, execution, or
observation, but it must not be treated as a human approval authority.

## Deliverable Responsibility Matrix

| CSV deliverable | Owner | Author | Executor | Independent reviewer | Approver |
| --- | --- | --- | --- | --- | --- |
| Validation master plan | Validation owner | Protocol author | Not applicable | Quality reviewer | Validation owner and release approver |
| User requirements specification | System owner | Protocol author | Not applicable | Quality reviewer | System owner |
| Risk assessment | Validation owner | Protocol author | Not applicable | Quality reviewer and security or data-integrity reviewer when applicable | Validation owner |
| IQ protocol | Validation owner | Protocol author | Protocol executor or orchestration operator | Technical reviewer and quality reviewer | Validation owner |
| OQ protocol | Validation owner | Protocol author | Protocol executor or orchestration operator | Technical reviewer and quality reviewer | Validation owner |
| PQ protocol | System owner | Protocol author | Protocol executor or orchestration operator | Quality reviewer | System owner and validation owner |
| Deviation record | Validation owner | Protocol author | Protocol executor supplies evidence | Quality reviewer | Validation owner; release approver for critical deviations |
| IQ/OQ/PQ report | Validation owner | Protocol author | Not applicable | Technical reviewer and quality reviewer | Validation owner |
| Final validation report | Validation owner | Protocol author | Not applicable | Quality reviewer and system owner | Release approver |
| Production release package | Release approver | Protocol author | Not applicable | Quality reviewer and records custodian | Release approver |

## Training Evidence Expectations

Training must be complete before a person or automated actor performs an
assigned CSV activity. The training record must be testable by an independent
reviewer and retained with, or linked from, the validation package.

Minimum evidence:

- role assignment and effective date;
- training topic, version, trainer or source, completion date, and trainee;
- objective evidence that the trainee understood the procedure, such as a quiz,
  supervised run, checklist signoff, or documented competency review;
- repository, environment, command, or runbook scope covered by the training;
- refresher or retraining trigger, including procedure changes, failed
  execution, deviation recurrence, access changes, or role reassignment.

Protocol executors and orchestration operators must have documented training on:

- approved command boundaries and stop conditions;
- evidence capture, timestamp expectations, and log retention;
- deviation initiation when a command, check, signature, or evidence step fails;
- handoff requirements when work moves between people, agents, sessions, or
  environments;
- confidentiality rules for credentials, secrets, customer data, and regulated
  records.

Execution agents require an identity and authorization record rather than a
human training record. The record must identify the agent label, authorized
scope, supervising role, allowed tools or commands, and evidence-signing status.

## Approval Matrix

| Gate | Required approval before proceeding | Required evidence | Refusal or hold condition |
| --- | --- | --- | --- |
| Validation plan approval | Validation owner and quality reviewer | Approved scope, acceptance criteria, deliverable list, role assignments. | Missing CSV-01 decision, missing role coverage, unresolved independence conflict. |
| Protocol approval | Validation owner plus required technical or quality reviewer | Approved protocol version, traceability to requirements and risks, executor readiness. | Untrained executor, ambiguous acceptance criteria, missing test data or environment control. |
| Execution start | Protocol executor or orchestration operator confirms readiness; validation owner authorizes start. | Training evidence, approved protocol, environment identifier, command or runbook version. | Dirty scope, missing approvals, unauthorized tool access, incomplete handoff. |
| Deviation acceptance | Validation owner and quality reviewer; release approver for critical impact. | Deviation record, impact assessment, corrective action, retest decision. | Unbounded impact, unverifiable evidence, missing root-cause assessment. |
| Report approval | Validation owner, quality reviewer, and required technical reviewer. | Executed protocol, evidence index, deviations, pass/fail summary, reviewer comments. | Missing evidence, unresolved deviations, failed acceptance criteria. |
| Final validation release | Release approver with validation owner recommendation. | Final validation report, production readiness statement, residual-risk acceptance. | Open critical deviation, missing independent review, missing or failed evidence verification. |
| Record archive | Records custodian confirms retention readiness. | Final package index, immutable or controlled storage location, retrieval check. | Broken links, missing signatures where required, uncontrolled record location. |

Approvals must be explicit and attributable. A mechanical signature or automated
attestation can prove that an artifact was produced or observed by a defined
actor, but final review, deviation acceptance, and production release require
the configured human or organizational approval path.

## Independence and Review Expectations

Review independence is required when a deliverable can affect validated status,
release readiness, patient or customer impact, data integrity, security,
financial reporting, or regulated evidence. Independence means the reviewer did
not author, execute, or approve the same work item.

Minimum expectations:

- the author and executor cannot be the sole reviewer of their own evidence;
- protocol approval must occur before execution starts;
- report approval must occur after evidence is complete and deviations are
  dispositioned;
- any independence exception must be documented as a risk-based justification
  and approved before relying on the affected evidence;
- reviewers must record the evidence inspected, the decision, and any required
  correction or retest.

If reviewer independence cannot be met because of team size, the validation
owner must document the compensating control, such as second-pass review,
enhanced audit trail inspection, or release-approver review of the specific
record.

## Operator Handoff Rules

Handoff is required whenever control of an active validation activity moves
between people, agents, sessions, machines, repositories, environments, or
approval stages.

Each handoff record must include:

- source actor and receiving actor;
- date and time in UTC;
- issue, protocol, command, branch, commit, run, or artifact identifiers;
- current state, completed steps, remaining steps, known blockers, and open
  deviations;
- evidence location and integrity status;
- explicit stop conditions and escalation path;
- confirmation that the receiving actor has the required authorization and
  training or identity record.

The receiving actor must refuse continuation when the handoff is incomplete,
evidence cannot be located, signature or digest verification fails where
required, the branch or environment is not the one approved for execution, or an
open deviation changes the approved scope.

## Evidence Signing and Approval Boundary

CSV-03 depends on the evidence-signing controls defined by the CSV-05A evidence
attestation model. Until those controls are implemented and approved, missing or
failed signature verification for critical evidence must be handled as a
deviation unless the validation owner documents that the artifact is
non-critical supporting material.

Required separation:

- mechanical attestation proves artifact identity, command context, actor
  identity, timestamp, and digest binding;
- human or organizational approval accepts responsibility for review,
  deviation disposition, release readiness, and residual risk;
- an automated actor may not approve a deviation, final validation report, or
  production release unless a separate approved policy explicitly authorizes
  that interpretation.

## CSV-09 and Final Report Inputs

CSV-09 planning and the final validation report must reference this matrix and
confirm:

- every deliverable had an owner, author, executor when applicable, independent
  reviewer, and approver;
- training and identity records were complete before execution;
- approval gates occurred in the required order;
- deviations from role independence, handoff, or signing expectations were
  assessed and dispositioned;
- the release package includes or links the final role assignment, training,
  approval, and handoff evidence.
