# CSV-07 User Requirements and Acceptance Criteria

## Purpose

This document defines user requirements and acceptance criteria for validated
use of ORDO as a universal orchestration control framework. It translates the
intended use from CSV-01 and the risk priorities from CSV-06 into testable
requirements that can be imported into CSV-08 traceability and later verified
through IQ, OQ, PQ, and final validation evidence.

The requirements are intentionally environment-neutral. Live repository names,
client names, provider names, account names, host names, terminal identifiers,
environment URLs, credentials, and local filesystem paths belong in controlled
configuration records, not in this generic URS.

## Scope

These requirements cover controlled orchestration behavior for:

- operator preflight and readiness checks;
- repository and worktree preparation;
- issue tracker traceability;
- dispatch planning and atomization;
- parallel-work guardrails and product or context switching;
- CI provider status interpretation;
- pull request merge refusal and escalation;
- audit, evidence, and handoff records;
- self-improvement, deviation, and CAPA feedback loops.

## Requirement Attributes

| Attribute | Meaning |
| --- | --- |
| Requirement ID | Stable CSV-07 identifier used by CSV-08 traceability. |
| Priority | Must, Should, or Could. Must items are required for validated use. |
| Risk class | Critical, High, Medium, or Low based on workflow control and evidence impact. |
| Acceptance criteria | Observable condition that must be verified by protocol evidence. |
| Planned evidence | Placeholder for OQ, PQ, review, or rationale evidence. |

Critical and high-risk requirements require planned OQ or PQ evidence. Medium
and low-risk requirements may be verified by review, smoke evidence, or
documented rationale when CSV-06 justifies that approach.

## User Requirements

| ID | Requirement | Priority | Risk class | Acceptance criteria | Planned evidence |
| --- | --- | --- | --- | --- | --- |
| URS-001 | ORDO shall perform a session preflight before controlled dispatch or recovery work starts. | Must | Critical | Preflight detects missing required configuration, missing command dependencies, unsafe terminal targeting, unavailable repository state, and degraded validator conditions before work is dispatched. Refusal output states the blocking reason. | OQ: preflight pass and negative-path evidence. PQ: production-like wave readiness evidence. |
| URS-002 | ORDO shall represent portfolio or project priorities without hardcoding live project names or provider-specific labels into generic logic. | Must | High | Priority output can be produced from configuration or issue metadata, and the generic requirement remains valid when labels, repositories, or providers are replaced by synthetic equivalents. | OQ: synthetic priority fixture. Review: configuration boundary check. |
| URS-003 | ORDO shall prepare or remediate repository clones only through approved safe-clone procedures. | Must | High | Missing, stale, or misconfigured clone state is detected; remediation is bounded to the configured repository target; destructive cleanup is refused unless an approved controlled-operation path exists. | OQ: clone readiness and refusal fixture. PQ: production-like clone preflight evidence. |
| URS-004 | ORDO shall detect dirty worktrees, pending rebases, diverged branches, missing upstreams, and unrelated local changes before dispatch, merge, or context switching. | Must | Critical | The operator receives a blocked status and actionable reason when unsafe local state is present. Unrelated local work is not overwritten or reverted by default. | OQ: dirty, rebase, diverged, and clean-state fixtures. PQ: multi-agent wave state check. |
| URS-005 | ORDO shall preserve traceability between issue tracker work items, branches, commits, pull requests, validation checks, and evidence artifacts. | Must | Critical | Each controlled work item can be traced from issue ID to branch, commit, pull request, check result, evidence record, and final disposition without relying on chat history or terminal scrollback as the only record. | OQ: traceability record fixture. PQ: sampled production-like evidence chain. |
| URS-006 | ORDO shall produce conservative dispatch plans that distinguish ready work from blocked, assigned, atomized, parked, or dependency-gated work. | Must | Critical | Dispatch output exposes the status and blocker reason for each candidate item. Work with unresolved dependencies, explicit blocking language, or active assignment is not reported as ready. | OQ: dispatch planner fixtures. PQ: production-like planning sample. |
| URS-007 | ORDO shall support atomization of oversized work into traceable child work items without creating duplicate children for the same source task. | Must | High | Atomized children carry a stable parent reference, objective, inherited constraints, and duplicate-prevention marker. Re-running atomization does not create duplicate children for unchanged tasks. | OQ: atomization dry-run and duplicate fixture. |
| URS-008 | ORDO shall enforce product, repository, or context switching guardrails before an operator or agent CLI changes active work scope. | Must | Critical | Switching is refused when current work is dirty, unpushed, uncommitted, blocked by rebase, or missing a handoff record. Approved switches preserve or park current state before moving to the next target. | OQ: switch refusal and approved-switch fixture. PQ: multi-context handoff evidence. |
| URS-009 | ORDO shall interpret CI provider status semantics conservatively before merge or release-related actions. | Must | Critical | Pending, queued, in-progress, skipped, missing, failed, cancelled, timed-out, and successful checks are classified distinctly. Merge-ready output requires the configured required checks to pass or a documented no-check policy to apply. | OQ: CI status classification fixture. PQ: pull request check-rollup sample. |
| URS-010 | ORDO shall surface merge refusal reasons rather than silently retrying or treating refusal as success. | Must | Critical | Branch protection, missing review, failed checks, conflict, closed pull request, stale head, permission failure, and platform refusal messages are captured with a refusal category and next action. | OQ: merge refusal fixtures. PQ: sampled merge gate evidence. |
| URS-011 | ORDO shall produce durable audit and evidence outputs for controlled operations, dispatch, validation, merge, cleanup, handoff, and findings workflows. | Must | Critical | Evidence records include action, actor role, timestamp, target identifier, command or action summary, result, blocker or deviation when applicable, and artifact reference. Evidence excludes secret values. | OQ: audit schema and secret-redaction fixture. PQ: production-like evidence store sample. |
| URS-012 | ORDO shall maintain handoff rules for work moving between operators, agents, sessions, repositories, or environments. | Must | High | Handoff records identify source actor, receiving actor, scope, completed steps, remaining steps, blockers, evidence location, and stop conditions. Continuation is refused when required handoff fields are missing. | OQ: complete and incomplete handoff fixtures. PQ: multi-agent wave handoff sample. |
| URS-013 | ORDO shall maintain a self-improvement, deviation, and CAPA loop for recurring operational failures. | Must | High | Findings can be recorded, deduplicated, triaged, linked to work items or CAPA, and closed with verification evidence. Recurring critical failures require escalation instead of silent repetition. | OQ: findings ledger and recurrence fixture. PQ: sampled CAPA linkage. |
| URS-014 | ORDO shall preserve reviewer independence and approval boundaries for validated decisions. | Must | High | Automated evidence or agent CLI output can support review but cannot by itself approve deviations, validation reports, or production release unless a separately approved policy permits that interpretation. | Review: CSV-03 alignment. OQ: approval-boundary negative case. |
| URS-015 | ORDO shall account for cryptographic attribution and integrity of agent-produced evidence without embedding a provider-specific signing mechanism in this URS. | Must | High | Critical evidence records include a placeholder for actor identity, artifact digest, signature or attestation reference, verification status, and deviation handling when verification is missing or failed. | Review: CSV-05A alignment. OQ: missing-signature deviation placeholder. |
| URS-016 | ORDO shall protect credentials and sensitive configuration from being written into validation evidence. | Must | High | Evidence outputs may reference secret classes or secret-store identifiers but must not include secret values, private keys, tokens, passwords, or credential material. | OQ: prohibited-secret fixture. Review: evidence schema inspection. |
| URS-017 | ORDO shall support bounded local validation and CI-delegated validation without overloading shared execution hosts. | Should | Medium | Local checks are selected by changed-file risk and bounded by timeout or semaphore controls. Full validation can be delegated to CI provider checks when configured. | OQ: local-validator gating fixture. PQ: CI-delegated validation sample. |
| URS-018 | ORDO shall report residual blockers clearly when work cannot continue. | Must | High | Operator-facing output states whether the blocker is dependency, dirty state, missing approval, missing evidence, unavailable service, failed check, identity mismatch, or out-of-scope request. | OQ: blocker taxonomy fixture. PQ: sampled blocked-work report. |
| URS-019 | ORDO shall allow non-critical advisory summaries while keeping validated decisions tied to controlled evidence. | Should | Medium | Summaries and recommendations are marked advisory unless linked to evidence, review, and approval records required by the validation strategy. | Review: advisory-output rationale. OQ: summary classification fixture. |
| URS-020 | ORDO shall retain enough metadata to support final traceability reconciliation. | Must | High | Each requirement can be mapped to risks, controls, protocol steps, evidence artifacts, deviations, and approval outcomes in CSV-08 and final validation records. | Review: CSV-08 import check. OQ: traceability placeholder completeness. |

## Acceptance Evidence Rules

Acceptance evidence must be objective enough for an independent reviewer to
repeat or inspect the result. For each executed test or review record, capture:

- CSV requirement ID and protocol step;
- actor role or agent identity label;
- UTC timestamp;
- repository revision or controlled baseline reference;
- command, script, or review action summary;
- input fixture, configuration class, or controlled environment reference;
- result, pass/fail status, and observed blocker or deviation;
- artifact path, immutable reference, checksum, or signed attestation reference;
- reviewer disposition and approval decision where applicable.

Agent-produced evidence must support cryptographic attribution and integrity as
defined by the CSV-05A evidence attestation model. Missing, expired, revoked, or
failed verification for critical evidence is a deviation unless the validation
owner classifies the artifact as non-critical supporting material.

## Non-Requirements and Exclusions

The following are excluded from CSV-07 validated requirements:

- validation of any downstream product solely because ORDO coordinated work on
  that product;
- autonomous final approval of deviations, validation reports, or production
  release without a separate approved policy;
- implementation of the CSV-05A signing mechanism;
- implementation of repository platform, issue tracker, CI provider, evidence
  store, or secret store internals;
- provisioning of terminal multiplexer sessions, panes, hosts, credentials, or
  accounts;
- guarantee that agent-generated code or text is correct without independent
  review and product-specific validation;
- storage of secret values or private credential material in the validation
  dossier;
- provider-specific behavior that cannot be represented through generic
  configuration, fixtures, or observable outputs.

## CSV-08 Import Expectations

CSV-08 must import each `URS-*` row with at least these fields:

- requirement ID;
- requirement text;
- priority;
- risk class;
- linked CSV-06 risk or control;
- planned IQ, OQ, PQ, review, or rationale evidence;
- actual protocol step and evidence reference after execution;
- deviation reference when the acceptance criterion is not met;
- approval disposition.

No requirement may be considered satisfied only by a green CI result. The
traceability matrix must link the green check to the relevant command,
artifact, actor attribution, controlled baseline, and reviewer disposition.

## Approval and Change Control

CSV-07 must be approved before CSV-08 traceability and CSV-09 protocol strategy
are finalized. Changes to a requirement ID, priority, risk class, acceptance
criterion, or planned evidence after approval require impact assessment against
CSV-06, CSV-08, CSV-09, affected protocols, and final validation reporting.
