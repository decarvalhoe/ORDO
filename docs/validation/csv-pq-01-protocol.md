# CSV-PQ-01 PQ Protocol for Production-Like Multi-Agent Wave

## Purpose

This protocol defines Performance Qualification checks for a production-like
multi-agent orchestration wave. It is a future conditional protocol artifact
only. It does not authorize CSV-PQ-02 execution, does not start PQ, and does
not make a production-readiness decision.

CSV-PQ-02 cannot start until CSV-OQ-03 records release to PQ or an approved
deviation/waiver explicitly authorizes limited PQ execution. The current
CSV-OQ-03 disposition is `NOT RELEASED TO PQ`, and `DEV-OQ-001` remains open.
That condition blocks PQ execution.

CSV-PQ-03 owns the PQ report and production-readiness decision after executed
PQ evidence exists.

## Controlled Inputs

| Input | Controlled reference | Digest or retained reference | Use |
| --- | --- | --- | --- |
| OQ report and release-to-PQ disposition | CSV-OQ-03 | `88be736cf24d1123a9c50bc418bebd29a2b0dd24af2f8a89a48bf293201f3fe0` | Establishes current blocked entry condition and future release requirement. |
| Validation strategy | CSV-09 | `4187848eb32cddfe7e646648f0a5a2a8abd09a0eb0fd04897782e28b86368bd0` | Defines PQ role in the validation lifecycle. |
| User requirements | CSV-07 | `901bed510fbe35e9802f9fe0fc9ed3c851b43af44cd9a1f55670869ea672320e` | Provides PQ acceptance requirements. |
| Quality risk assessment | CSV-06 | `708c6ae29966366bf501b71479518e77418ed7ddbc77d067299797956d3dee11` | Provides risk-based coverage obligations. |
| Agent evidence and attestation model | CSV-05A | `dcd7e3eaaa2cf2f0e8dda4ed7f765c623ecec376b38a274591b53bae9273474f` | Defines attribution and integrity expectations for agent-produced evidence. |
| Protocol source baseline | Current controlled baseline | `d7e5b3e47feffd83eb4f7274bca82a1a31ceb810` | Baseline used to author this protocol. |

## Current Entry Guard

CSV-PQ-01 is allowed to exist before release to PQ so reviewers can inspect the
planned production-like evidence approach. However:

- CSV-PQ-02 must not be scheduled or executed while CSV-OQ-03 remains `NOT
  RELEASED TO PQ`;
- `DEV-OQ-001` must be closed, accepted with documented rationale, or linked to
  an approved waiver/deviation before PQ execution starts;
- a future CSV-PQ-02 package opened before those conditions are met must record
  an administrative blocker and stop without executing PQ protocol steps;
- this protocol does not close `DEV-OQ-001`, accept OQ residual risk, or
  authorize PQ entry.

## PQ Entry Criteria

CSV-PQ-02 execution may start only when all entry criteria are met.

| Entry criterion | Required status before execution |
| --- | --- |
| CSV-OQ-03 release disposition | Release to PQ is approved, or an approved waiver/deviation explicitly authorizes limited PQ execution. |
| OQ deviations | Critical and major OQ deviations are closed, accepted with documented rationale, or linked to approved CAPA with PQ impact assessed. |
| CSV-PQ-01 protocol approval | Protocol is reviewed and approved by the configured approval route. |
| Scenario package | Production-like wave scope, data classes, rollback boundaries, evidence plan, and stop conditions are approved. |
| Actor readiness | Human roles, agent CLI actors, and automation actors are authorized for the scenario and evidence classes. |
| Evidence controls | Critical evidence attribution, digest, attestation, retention, and verification procedures are available or preapproved deviations exist. |
| Configuration boundary | Controlled repository, issue tracker, check-status, evidence-store, and secret-store boundaries are identified through configuration without live names in generic evidence. |
| Data boundary | Synthetic records are available for destructive, negative, or unsafe conditions; production-like records are approved only for bounded observation or controlled dry-run. |
| Work-area readiness | Version-control state, active work, branch basis, and pending handoffs are clean or explicitly accepted for the scenario. |
| Review readiness | Reviewer roles and disposition placeholders are assigned before evidence generation starts. |

If any entry criterion is not met, CSV-PQ-02 must not execute the PQ scenario.
The blocker must be retained as a deviation or administrative stop record.

## Production-Like Wave Scope

The PQ wave verifies that ORDO can coordinate realistic multi-agent work within
approved operating constraints. The scenario must include:

- a controlled backlog with ready, blocked, in-progress, completed, parked, and
  dependency-gated work items;
- multiple agent CLI actors with distinct authorized scopes;
- at least one dispatchable work item and at least one blocked work item;
- at least one rebalance or reassignment decision that preserves blockers;
- at least one atomization candidate with duplicate-prevention evidence;
- at least one validation or check-status observation;
- at least one merge-ready or release-support decision sample;
- evidence capture for dispatch, handoff, validation, blocker, deviation, and
  final wave summary records;
- sustained-operation observation across a configured wave duration or
  configured minimum work-item count;
- reviewer placeholders for quality, system, validation, and technical roles.

The scenario must reflect intended use, but it must not rely on hardcoded live
names, implicit actor identities, uncontrolled credentials, or transient
terminal output as the only record.

## Synthetic and Production-Like Boundaries

Use synthetic or non-production fixtures for:

- destructive cleanup attempts;
- unsafe merge or release-support decisions;
- missing approval, missing evidence, wrong context, or wrong actor cases;
- secret-like value redaction checks;
- failed or missing attestation checks;
- repeated or excessive retry conditions;
- any action that could mutate a controlled baseline outside the approved
  scenario.

Production-like observations may be used for:

- backlog state classification;
- dispatch planning;
- authorized bounded dispatch;
- check-status collection;
- evidence-store write and retrieval;
- handoff and continuation records;
- blocked-work reporting;
- merge-ready or release-support classification without forcing a mutating
  action.

Any real mutating action must already be approved by the scenario package and
must be represented in the evidence as a controlled action with stop
conditions, rollback or remediation expectations, and reviewer disposition.

## Evidence Capture Rules

CSV-PQ-02 must retain an evidence pack at the planned evidence location for
CSV-PQ-02. Each evidence item must include:

- PQ step ID;
- evidence ID;
- controlled baseline reference;
- scenario item or fixture identifier;
- action or command summary;
- actor role or agent CLI actor label;
- UTC timestamp;
- observed output summary;
- pass, fail, blocked, skipped, deviated, or stopped result;
- artifact digest or approved attestation reference;
- verification result for agent-produced evidence;
- related issue, change-request, requirement, risk, deviation, or CAPA
  reference when applicable;
- reviewer disposition placeholder.

Secret values, private credential material, live machine identifiers,
environment-specific endpoints, and unredacted private configuration must not
be retained.

Critical agent-produced evidence must have attribution and integrity
verification. Missing, failed, expired, revoked, or unverifiable critical
evidence creates a deviation unless the configured approval route classifies
the artifact as non-critical supporting material.

## Global Stop Conditions

The executor must stop CSV-PQ-02 and open or link a deviation when:

- CSV-OQ-03 release to PQ is absent and no approved waiver/deviation exists;
- `DEV-OQ-001` or any other release-blocking OQ deviation remains unresolved
  without approved PQ impact disposition;
- the scenario package is missing, unapproved, or contains live identifiers in
  generic evidence;
- actor authorization, role independence, or evidence-signing readiness is
  missing for critical steps;
- work-area state is dirty, ambiguous, stale, in conflict, or outside the
  approved scenario boundary;
- a blocked work item is classified as ready;
- a dispatch is sent to the wrong target or is not consumed but is classified as
  successful;
- a check-status, merge-ready, or release-support decision treats failed,
  pending, missing, stale, or ambiguous evidence as success;
- an unsafe cleanup, context switch, merge, release-support, retry, or
  reconfiguration proceeds without approval;
- evidence cannot be written, retrieved, hashed, attested, or verified;
- secret or private credential material appears in retained evidence;
- sustained-operation observations show uncontrolled queue growth, repeated
  unresolved blocker loops, or missing handoff evidence;
- an observed result contradicts a protocol acceptance criterion.

## Deviation, Retest, and CAPA Rules

Create a deviation for any failed, blocked, skipped, altered, or unverifiable
step unless the protocol explicitly allows a not-applicable result with
rationale. Deviation severity follows CSV-06.

Retest is required when a failed or blocked step supports a PQ acceptance
criterion. Retest evidence must cite the original step, evidence ID, deviation
ID, corrective action, retest action, result, and whether prior evidence is
retained as failure evidence or superseded.

CAPA linkage is required when a deviation is critical, recurring, systemic, or
caused by an ineffective control. CAPA records remain separate from mechanical
evidence and require the configured approval route.

## PQ Protocol Steps

| Step ID | Objective | Requirement/risk links | Action for CSV-PQ-02 | Pass criteria | Fail/deviation trigger | Evidence ID |
| --- | --- | --- | --- | --- | --- | --- |
| PQ-001 | Confirm PQ entry release and scenario approval. | URS-014, URS-020, QR-006, QR-008 | Review CSV-OQ-03, OQ deviation status, scenario package, actor readiness, and evidence controls. | Release to PQ or approved waiver/deviation exists; scenario package is approved; no release-blocking deviation remains unresolved. | CSV-OQ-03 remains not released; `DEV-OQ-001` remains open without approved disposition; scenario or actor readiness missing. | EV-PQ-001-01 |
| PQ-002 | Verify production-like wave boundary and data controls. | URS-002, URS-016, QR-012, QR-013 | Review controlled scenario records for backlog class mix, data classes, synthetic boundary, and production-like observation boundary. | Scenario includes required work classes and excludes secret values and hardcoded live identifiers from generic evidence. | Scenario relies on uncontrolled live data, secret material, or unspecified boundaries. | EV-PQ-002-01 |
| PQ-003 | Verify actor, role, and attestation readiness. | URS-014, URS-015, QR-009, QR-011 | Review authorized human roles, agent CLI actor labels, automation actor labels, and verification procedure. | Actor scope, reviewer independence, evidence digest, and attestation or approved equivalent are ready for critical evidence. | Actor scope mismatch, missing verification route, or critical evidence lacks deviation path. | EV-PQ-003-01 |
| PQ-004 | Execute first-run wave preflight. | URS-001, URS-003, URS-004, QR-010 | Run approved preflight for configured backlog, repositories, work areas, dispatch targets, check-status source, and evidence store. | Preflight classifies ready and blocked conditions accurately and records blockers with remediation guidance. | Unsafe state is accepted as ready, or required readiness fields are missing. | EV-PQ-004-01 |
| PQ-005 | Verify safe cleanup proposal/apply split. | URS-003, URS-004, QR-004 | Run cleanup proposal and approved apply checks against scenario-controlled stale or temporary state. | Proposal is visible before apply; apply is bounded to approved scenario state; destructive or ambiguous cleanup is refused. | Apply mutates outside approved scope, skips proposal, or accepts destructive cleanup. | EV-PQ-005-01 |
| PQ-006 | Verify dispatchable work-item choice. | URS-002, URS-006, QR-007, QR-010 | Run production-like planning across ready, blocked, assigned, parked, completed, and dependency-gated items. | Output selects only ready work according to configured priority and records why other work is not selected. | Blocked, assigned, parked, completed, or dependency-gated work is selected as ready. | EV-PQ-006-01 |
| PQ-007 | Verify blocked-work rebalance decision. | URS-006, URS-008, URS-013, QR-007 | Run rebalance decision for a blocked work item and available alternative work. | Blocker is preserved; reassignment or rebalance keeps parent links, owner roles, remaining work, and evidence references. | Blocker is dropped, work is duplicated, or reassignment changes scope without approved evidence. | EV-PQ-007-01 |
| PQ-008 | Verify traceable atomization. | URS-005, URS-007, URS-020, QR-007 | Run atomization workflow for an oversized scenario item with duplicate-prevention marker. | Child work has parent reference, scope, constraints, acceptance criteria, dependency links, and duplicate-prevention evidence. | Child work lacks traceability, duplicates existing work, or expands scope. | EV-PQ-008-01 |
| PQ-009 | Verify controlled dispatch and consumption proof. | URS-001, URS-005, URS-011, QR-001, QR-002 | Dispatch one approved ready item to an authorized agent CLI actor and record post-dispatch context proof and consumption status. | Dispatch prompt, target proof, consumption proof, branch or work reference, and evidence link are retained. | Wrong target, stale context, prompt not consumed, or dispatch evidence missing. | EV-PQ-009-01 |
| PQ-010 | Observe sustained multi-agent operation. | URS-004, URS-008, URS-012, QR-003, QR-014 | Observe the configured wave duration or minimum work-item count across active, blocked, and handoff states. | No unsafe context switch, dirty-state continuation, missing handoff, or unresolved blocker loop occurs; observations are retained. | Queue health degrades without blocker evidence, handoff is missing, or unsafe switch proceeds. | EV-PQ-010-01 |
| PQ-011 | Verify validation/check observation and corrective-candidate handling. | URS-009, URS-010, URS-017, QR-005, QR-013 | Collect configured check-status evidence and any corrective-candidate observation without forcing unapproved changes. | Successful, failed, pending, missing, stale, and ambiguous states are classified conservatively; corrective candidates are advisory unless approved. | Unsafe status is treated as pass, or corrective action starts without approval. | EV-PQ-011-01 |
| PQ-012 | Verify merge-ready or release-support detection. | URS-005, URS-009, URS-010, QR-005, QR-006 | Review one merge-ready or release-support candidate and one blocked candidate under configured gates. | Ready decision cites required evidence; blocked decision records refusal category and next action; no unapproved mutating action occurs. | Missing review, failed check, stale state, conflict, or open deviation is classified as ready. | EV-PQ-012-01 |
| PQ-013 | Verify evidence capture and integrity across the wave. | URS-011, URS-015, URS-016, QR-008, QR-009, QR-012 | Review evidence manifest, artifact digests, attestation references, redaction checks, and retrieval proof for generated evidence. | Evidence is complete, retrievable, digest-bound, verified or deviation-routed, and free of secret values. | Missing artifact, digest mismatch, failed verification, or retained secret material. | EV-PQ-013-01 |
| PQ-014 | Verify continuation, cleanup, and handoff after wave activity. | URS-008, URS-012, URS-018, QR-003, QR-014 | Review parked work, remaining blockers, handoff records, cleanup status, and continuation queue. | Handoff records preserve scope, completed work, blockers, evidence links, and stop conditions; cleanup remains bounded. | Handoff fields missing, dirty work is ignored, or cleanup proceeds outside approved scenario. | EV-PQ-014-01 |
| PQ-015 | Verify deviation, retest, and CAPA routing. | URS-013, URS-014, QR-006, QR-008 | Review all failed, blocked, skipped, altered, or unverifiable results and route deviations, retests, and CAPA candidates. | Severity, owner role, root-cause expectation, impact, retest need, CAPA need, and reviewer placeholder are recorded. | Critical or recurring issue lacks deviation/CAPA route or is closed by mechanical evidence alone. | EV-PQ-015-01 |
| PQ-016 | Verify PQ evidence package completeness and report handoff. | URS-005, URS-011, URS-020, QR-008, QR-014 | Reconcile evidence IDs, traceability, deviations, retests, residual risks, and reviewer dispositions for CSV-PQ-03. | Package is complete enough for report preparation, or blockers are documented with explicit release impact. | Missing evidence ID, incomplete traceability, unresolved critical blocker, or absent release-impact statement. | EV-PQ-016-01 |

## Evidence ID Register

| Evidence ID | PQ step | Required retained artifact |
| --- | --- | --- |
| EV-PQ-001-01 | PQ-001 | Entry release review, OQ disposition reference, scenario approval reference, and approval/waiver status. |
| EV-PQ-002-01 | PQ-002 | Wave boundary, data boundary, and scenario class review. |
| EV-PQ-003-01 | PQ-003 | Actor authorization, role independence, and evidence verification readiness review. |
| EV-PQ-004-01 | PQ-004 | First-run preflight output and readiness/blocker summary. |
| EV-PQ-005-01 | PQ-005 | Cleanup proposal/apply split evidence and refusal record when applicable. |
| EV-PQ-006-01 | PQ-006 | Dispatchable work-item choice and ready/blocked classification output. |
| EV-PQ-007-01 | PQ-007 | Blocked-work rebalance decision and preserved blocker traceability. |
| EV-PQ-008-01 | PQ-008 | Atomization output, parent/child traceability, and duplicate-prevention proof. |
| EV-PQ-009-01 | PQ-009 | Dispatch prompt, target/context proof, consumption proof, and evidence link. |
| EV-PQ-010-01 | PQ-010 | Sustained-operation observation summary and handoff/blocker observations. |
| EV-PQ-011-01 | PQ-011 | Validation/check status observation and corrective-candidate classification. |
| EV-PQ-012-01 | PQ-012 | Merge-ready or release-support decision and blocked-candidate refusal evidence. |
| EV-PQ-013-01 | PQ-013 | Evidence manifest, artifact digests, attestation verification, and redaction review. |
| EV-PQ-014-01 | PQ-014 | Continuation, cleanup, parked work, and handoff review. |
| EV-PQ-015-01 | PQ-015 | Deviation, retest, CAPA, and reviewer-disposition routing record. |
| EV-PQ-016-01 | PQ-016 | Evidence package completeness review and CSV-PQ-03 handoff statement. |

## Load and Sustained-Operation Observations

CSV-PQ-02 must define wave-size and duration criteria in the approved scenario
package before execution. The criteria must be based on intended use and risk,
not hardcoded generic defaults.

At minimum, sustained-operation evidence must observe:

- number and class of candidate work items reviewed;
- number of agent CLI actors active, idle, blocked, or handed off;
- dispatch attempts, successful consumption proofs, and not-consumed blockers;
- blocked-work preservation and rebalance decisions;
- check-status observations and conservative classifications;
- evidence-write, retrieval, digest, and verification results;
- retry count, retry exhaustion, and reconfiguration decisions;
- queue health, unresolved blocker count, and continuation state at handoff;
- any deviation, retest, CAPA candidate, or stop condition.

The wave fails when sustained operation requires unsafe dispatch, unsafe merge,
unsafe context switch, uncontrolled cleanup, unbounded retry, missing handoff,
or incomplete critical evidence to proceed.

## Pass, Fail, and Report Handoff

CSV-PQ-02 passes only when every required PQ step passes or has an approved
deviation disposition, critical evidence is verified or deviation-routed, and
residual risks are ready for CSV-PQ-03 review.

CSV-PQ-02 is blocked or failed when any entry criterion is missing, any critical
control does not fail closed, critical evidence is missing or unverifiable, or
an open deviation prevents a responsible production-readiness decision.

CSV-PQ-02 must hand off to CSV-PQ-03:

- evidence manifest and artifact references;
- executed step results and observed outputs;
- traceability matrix updates;
- deviation, retest, and CAPA records;
- residual-risk statement;
- reviewer dispositions;
- explicit recommendation to release, block, or conditionally release for final
  readiness review.

CSV-PQ-02 must not itself approve production readiness. CSV-PQ-03 owns the
report and release decision.

## Approval

Approval of this protocol permits future CSV-PQ-02 execution only after all PQ
entry criteria are satisfied. It does not override the current blocked OQ
disposition, does not close `DEV-OQ-001`, does not start PQ, and does not
authorize production readiness.

Mechanical attestation supports evidence origin and integrity. It does not
replace responsible human approval for deviations, residual risk, PQ report
closure, or production-readiness decisions.
