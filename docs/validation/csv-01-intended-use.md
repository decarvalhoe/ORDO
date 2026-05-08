# CSV-01 Intended Use and Regulated Impact Statement

## Purpose

This document defines the intended use, regulated impact posture, validation
boundaries, non-intended use, user classes, and risk rationale for ORDO before
URS, risk assessment, IQ, OQ, or PQ evidence is finalized.

This statement is the controlling baseline for proportionate validation. Any
deployment that changes the intended use, user population, automation authority,
regulated process context, or release authority must create a deployment-specific
delta assessment before relying on this baseline.

## Intended Use

ORDO is intended to operate as a multi-agent software orchestration control
plane for engineering work. It coordinates human operators and automated worker
agents across source control, issue tracking, pull request review, continuous
integration status, worktree state, dispatch prompts, and audit records.

Within that intended use, ORDO may:

- identify ready, blocked, parked, or merge-ready work;
- dispatch bounded work items to configured worker agents;
- enforce preflight checks before dispatch or product switching;
- surface dirty worktrees, stale branches, conflicting work, or missing evidence;
- record audit events, task handoffs, findings, and release or rollback actions;
- recommend or apply conservative operational actions when configured guardrails
  pass;
- provide evidence that orchestration controls were executed as designed.

ORDO is intended to support controlled software delivery workflows. It is not
intended to replace accountable human approval where that approval is required
by a quality system, release policy, or regulated procedure.

## Regulated Impact Classification

The baseline classification for ORDO is:

```text
Indirect support tool for regulated software delivery when deployed in a
regulated lifecycle context; non-regulated engineering productivity tool when
used outside a regulated lifecycle context.
```

ORDO is not classified as a direct regulated product system under this baseline.
It does not create, modify, diagnose, treat, monitor, or directly control a
regulated end product or regulated operational process.

ORDO can indirectly affect regulated software delivery because it may influence
which work is dispatched, when a branch is considered ready, whether evidence is
present before merge, and whether operational findings are captured. For that
reason, deployments that use ORDO in a regulated lifecycle should validate the
configured orchestration controls, evidence capture, and release guardrails at a
rigor level proportionate to their impact on product quality records.

If ORDO is configured to make final release decisions, execute irreversible
production changes, approve regulated records, or act as the sole quality gate
without independent review, this baseline classification no longer applies. That
use must be assessed as a higher-impact deployment before operation.

## Validation Boundaries

The validation package for this intended use may assert that ORDO:

- resolves configured projects, agents, repositories, and workdirs according to
  controlled configuration;
- refuses unsafe dispatch when required preconditions fail;
- records auditable evidence for dispatch, merge, cleanup, findings, and
  controlled operations;
- preserves worktree isolation between configured targets;
- reports blockers instead of silently treating blocked work as complete;
- delegates full repository validation to configured CI or an explicitly
  approved local validation path;
- produces reproducible command-line behavior for the covered scripts and
  control flows.

The validation package does not assert that:

- any target product is validated or compliant solely because ORDO coordinated
  work on it;
- worker-agent generated code is correct without product-specific review and
  testing;
- external systems used by the workflow are validated by ORDO evidence alone;
- generated prompts, comments, summaries, or recommendations are complete
  regulated records without review under the applicable quality procedure;
- ORDO is suitable for autonomous release approval unless that use is separately
  assessed and validated.

## Non-Intended Use

ORDO is not intended to be used as:

- a medical, clinical, manufacturing, laboratory, or safety-control system;
- an autonomous final approver for regulated release or quality records;
- a substitute for required human review, quality approval, or change control;
- a source of product requirements or acceptance criteria without accountable
  review;
- an uncontrolled agent runtime where any worker may mutate any repository or
  workdir;
- a secret store, credential broker, or privileged access manager;
- a guarantee that downstream product behavior is safe, effective, secure, or
  compliant.

## Intended Users and Operational Context

ORDO is intended for use by trained personnel or controlled automation acting
within defined operating procedures.

User classes include:

- orchestrator operators who start, monitor, and adjudicate orchestration waves;
- worker agents that receive bounded tasks and report evidence;
- repository owners who define branch, review, CI, and merge policies;
- quality or release reviewers who inspect evidence, blockers, and audit trails;
- validation owners who approve intended use, risk controls, and protocol scope;
- system maintainers who configure credentials, state directories, logs, and
  integration endpoints.

The expected operational context is a controlled software engineering
environment with version control, issue tracking, pull request review, CI, audit
logging, and documented release procedures. ORDO should be operated with least
privilege, explicit configuration, and traceable changes.

## Risk Rationale

ORDO's primary risk is not direct product harm; it is workflow control failure.
Examples include dispatching work to the wrong target, accepting incomplete
evidence, masking blocked work, switching context unsafely, losing audit
findings, or treating a pending external gate as completed work.

These risks justify applying CSV, GAMP, and CSA principles proportionately:

- intended use is documented before protocol authoring;
- requirements focus on critical orchestration controls and evidence integrity;
- tests prioritize high-risk workflows such as dispatch, context isolation,
  merge gating, cleanup, and audit capture;
- lower-risk informational outputs are verified through review, sampling, or
  smoke tests rather than exhaustive scripted proof;
- configuration and operating procedures remain part of the validated state;
- changes that expand ORDO's authority require impact assessment before use.

Under this rationale, ORDO validation should emphasize critical thinking,
traceability, automated regression checks for core controls, and evidence that
known operational failure modes are prevented or surfaced. The validation effort
should scale upward when ORDO is placed closer to regulated release authority
and scale downward when ORDO is used only for non-regulated productivity
coordination.

## Approval and Change Control

This intended-use statement must be approved before dependent URS, risk, and
protocol artifacts are finalized. Approval establishes the baseline validation
posture for the current ORDO operating model.

Reopen this assessment, or create a linked delta assessment, when:

- ORDO is deployed into a new regulated lifecycle context;
- ORDO gains authority to approve, merge, release, or roll back without
  independent review;
- user classes or operating procedures materially change;
- integrations become part of regulated record creation or retention;
- risk controls are weakened, removed, or bypassed;
- a post-release finding shows this intended-use statement no longer describes
  actual operation.
