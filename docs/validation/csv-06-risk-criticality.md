# CSV-06 Quality Risk Assessment and Criticality Matrix

## Purpose

This document defines the quality risk assessment and criticality matrix for a
universal terminal-agent orchestration toolkit. It converts supplier, data
integrity, and evidence-attribution concerns into verification obligations so
IQ, OQ, and PQ scope can be justified by risk instead of broad ceremonial
testing.

CSV-06 depends on:

- CSV-04 supplier and service provider assessment;
- CSV-05 data integrity and electronic record assessment;
- CSV-05A digitally signed agent evidence and attestation model.

CSV-05A is treated as a required control input. Agent-produced evidence must be
cryptographically attributable and integrity-protected before it is relied on
as critical validation evidence. Human approval remains a separate accountable
decision. Missing or failed signature verification is a deviation unless the
artifact is explicitly classified as non-critical supporting material.

## Scoring Method

Each risk is scored for severity, likelihood, and detectability. Detectability
is scored higher when failure is harder to detect before it can affect a
controlled decision.

| Score | Severity | Likelihood | Detectability |
| --- | --- | --- | --- |
| 1 | No controlled-record impact; cosmetic or advisory only. | Rare under normal operation. | Automatically detected before use. |
| 2 | Minor workflow delay or documentation correction. | Unlikely but credible. | Usually detected by normal review. |
| 3 | Could require retest, rework, or deviation assessment. | Occasional under change or load. | Detectable with targeted checks. |
| 4 | Could compromise a required control, evidence chain, or release gate. | Plausible during normal operation. | May escape without independent evidence review. |
| 5 | Could cause uncontrolled change, invalid evidence, secret exposure, or incorrect release decision. | Expected without effective controls or during known stress conditions. | Hard to detect after the fact or not reconstructable. |

Risk priority number is `severity x likelihood x detectability`.

| Criticality | Rule | Verification obligation |
| --- | --- | --- |
| High | Score 40 or greater, or severity 5 with detectability 3 or greater. | OQ coverage required; PQ coverage required when the behavior is production-like or depends on external services, concurrent work, or human handoff. |
| Medium | Score 16 through 39. | OQ or PQ coverage required based on where the risk can occur; rationale required when protocol coverage is not needed. |
| Low | Score 15 or lower and no severity 5 condition. | Documented rationale and periodic review are sufficient unless the risk aggregates with another control failure. |

## Critical Function Matrix

| Function | Primary failure concern | Criticality | Required verification |
| --- | --- | --- | --- |
| Dispatch safety | Work is sent to the wrong terminal target, stale input is submitted, or the agent CLI does not consume the dispatch. | High | OQ negative-path tests for wrong target, not-consumed dispatch, and context proof; PQ confirmation under production-like dispatch volume. |
| Scope and product switch guardrails | Work continues in the wrong configured product, repository, or issue scope. | High | OQ tests for scope mismatch refusal and handoff refusal; PQ check during a multi-issue operating cycle. |
| Branch, rebase, and dirty-work detection | Existing work is overwritten, changes are based on stale default branch state, or unrelated edits are included. | High | OQ tests for dirty worktree refusal, stale branch handling, and explicit staged-file scope. |
| CI blocker detection | Red, pending, missing, or ambiguous CI status is treated as acceptable. | High | OQ tests for failed, pending, missing, and stale CI provider responses; PQ confirmation before merge-like decisions. |
| Merge refusal and release gate | A controlled merge or release decision proceeds despite unresolved blockers. | High | OQ tests for refusal on failed checks, unresolved deviations, unapproved risk, and missing evidence. |
| Issue atomization and rebalance | Work is split, assigned, or rebalanced in a way that changes approved scope or loses blockers. | Medium | OQ tests for atomization boundaries, blocker propagation, and handoff evidence. |
| Evidence persistence | Logs, decisions, findings, prompts, or validation artifacts are incomplete, mutable, unauthenticated, or not retained. | High | OQ tests for evidence write, checksum or signature verification, failed-attestation deviation, and retention references. |
| Portfolio or fleet preflight | A stale clone, missing configuration item, unavailable target, or wrong working directory is accepted. | High | OQ tests for preflight refusal and remediation instructions; PQ confirmation before production-like wave execution. |
| Credential and identity guardrails | A command-line integration writes with the wrong account, token, or privilege scope. | High | OQ tests for identity mismatch, token override refusal, least-privilege failure, and audit record creation. |
| Secret handling | Secret values are logged, stored in evidence, or sent to an unauthorized service. | High | OQ tests for secret redaction and prohibited evidence fields; PQ review of evidence packages. |
| Supplier or service dependency | Repository platform, issue tracker, CI provider, evidence store, secret store, or agent CLI dependency is unavailable or changes behavior. | Medium | OQ tests for degraded service handling; PQ confirmation of operational fallback and residual-risk review. |

## Risk Register

| Risk ID | Failure mode | Cause | Impact | S | L | D | Criticality | Current controls | Residual risk | Required verification |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| QR-001 | Dispatch reaches the wrong terminal target or wrong configured workspace. | Incorrect target resolution, stale inventory, or operator selection error. | Work may occur outside approved issue, repository, or product boundary. | 5 | 2 | 4 | High | Configured target inventory, context proof, scope prompt, operator review. | Medium until OQ proves refusal behavior and context evidence. | OQ dispatch mismatch refusal; PQ production-like dispatch sampling. |
| QR-002 | Dispatch text is pasted but not consumed by the agent CLI. | Idle prompt, stale terminal input, busy process, or failed submit event. | Assignment appears sent while no work starts; blockers can be missed. | 4 | 3 | 3 | Medium | Post-dispatch consumption check, retry, not-consumed blocker record. | Low if blocker is durable and visible to operators. | OQ idle and pasted-content not-consumed tests. |
| QR-003 | Scope switch guardrails allow work in the wrong configured product or repository. | Missing boundary check, stale configuration, or incomplete handoff. | Controlled evidence and code changes may be attributed to the wrong context. | 5 | 2 | 4 | High | CSV-02 inventory, explicit scope binding, handoff rules, context proof. | Medium until PQ confirms real operating handoff behavior. | OQ scope mismatch refusal; PQ multi-scope operating cycle. |
| QR-004 | Dirty worktree, stale base branch, or unrelated edits are not detected. | Incomplete version-control status review, failed synchronization, or broad staging command. | Others' work can be overwritten or unrelated edits can enter a change request. | 5 | 3 | 3 | High | Clean-worktree check, synchronization and rebase expectation, explicit file staging. | Medium where manual judgment remains involved. | OQ dirty/stale branch refusal; change-request evidence review in PQ. |
| QR-005 | CI blocker detection treats failed, pending, missing, or stale status as passing. | API ambiguity, timeout, provider outage, or unhandled check state. | Unverified changes may be merged or released. | 5 | 3 | 3 | High | CI status polling, fail-closed merge rule, audit of check decision. | Medium when external CI provider is degraded. | OQ CI state matrix; PQ release-gate confirmation. |
| QR-006 | Merge or release refusal does not stop on unresolved blockers. | Missing blocker lookup, race condition, override misuse, or incomplete deviation state. | Controlled baseline can change without required approval. | 5 | 2 | 4 | High | Refusal rules, issue tracker blockers, approval matrix, deviation escalation. | Medium until integrated gate tests are complete. | OQ merge refusal tests; final traceability review. |
| QR-007 | Issue atomization or rebalance changes approved scope. | Overbroad decomposition, missing dependency link, or lost blocker during handoff. | Agents may execute unapproved work or duplicate conflicting changes. | 4 | 3 | 3 | Medium | Atomization rules, assignment ledger, handoff evidence, blocker propagation. | Medium until handoff behavior is sampled in PQ. | OQ atomization and rebalance boundary tests; PQ multi-agent workflow. |
| QR-008 | Evidence is incomplete, mutable, unauthenticated, or not retained. | Failed write, reliance on terminal scrollback, missing checksum, or evidence store outage. | Validation package may be unreconstructable or not audit-ready. | 5 | 3 | 4 | High | Evidence store, audit log, retention rule, checksum or signature expectation. | Medium until CSV-05A controls are approved and verified. | OQ evidence persistence and failed-attestation deviation tests; PQ evidence package review. |
| QR-009 | Agent-produced evidence lacks cryptographic attribution or integrity. | CSV-05A not implemented, signing key unavailable, digest mismatch, or unsupported artifact class. | Evidence may not prove who or what produced it, or whether it changed. | 5 | 3 | 4 | High | CSV-05A dependency, deviation rule, human approval separation. | High until attestation controls exist; accepted only with documented limitation. | OQ signature success/failure tests after CSV-05A; deviation record for missing critical signature. |
| QR-010 | Portfolio or fleet preflight accepts stale or missing operational context. | Missing configuration item, stale clone, wrong branch, unavailable target, or incomplete readiness check. | Work may start in a non-representative or uncontrolled environment. | 5 | 2 | 4 | High | Preflight report, readiness checks, remediation instruction, context proof. | Medium until preflight refusal is verified. | OQ preflight refusal tests; PQ production-like wave readiness review. |
| QR-011 | Command-line integration writes with the wrong identity or elevated token. | Environment token override, misconfigured credential store, or stale login. | Issue tracker, repository platform, or evidence records may be mutated by the wrong actor. | 5 | 2 | 4 | High | Identity guard, token override refusal, least-privilege configuration, audit record. | Medium because credential state can drift. | OQ identity mismatch and token override tests; periodic access review. |
| QR-012 | Secret or restricted data appears in prompts, logs, artifacts, or evidence. | Overbroad capture, unredacted command output, debug logging, or unsafe supplier routing. | Confidentiality breach and invalid controlled record. | 5 | 2 | 4 | High | Secret exclusion rule, redaction review, data classification, secret store controls. | Medium until data-integrity controls are tested. | OQ prohibited-field and redaction tests; PQ evidence package inspection. |
| QR-013 | External service outage, quota, or behavior change causes partial operation. | Repository platform, issue tracker, CI provider, evidence store, secret store, or agent CLI dependency unavailable. | Work may be partially dispatched, evidence may be delayed, or gates may be inconclusive. | 4 | 3 | 3 | Medium | Supplier assessment, fail-closed checks, retry limits, durable blocker records. | Medium; accepted only with operational fallback and review cadence. | OQ degraded service tests; PQ fallback and recovery review. |
| QR-014 | Audit trail timestamps, actor labels, or artifact references are inconsistent. | Clock drift, missing metadata, manual edits, or cross-system reference mismatch. | Reviewers cannot reconstruct sequence, authorship, or decision basis. | 4 | 2 | 4 | Medium | UTC timestamp rule, actor role labels, artifact identifiers, evidence manifest. | Low after manifest reconciliation is verified. | OQ manifest validation; final traceability reconciliation. |

## Risk Acceptance Criteria

- High risks must have an approved control, an OQ verification obligation, and
  documented residual-risk disposition before release to PQ.
- High risks that occur only under production-like concurrency, supplier
  dependency, or human handoff must also have PQ coverage.
- Medium risks must have either OQ or PQ coverage, or a documented rationale
  explaining why existing controls and review are sufficient.
- Low risks may be accepted with documented rationale and periodic review.
- Any open high risk, failed critical control, missing critical evidence,
  unresolved signature failure, or uncontrolled write requires deviation
  escalation before the next phase gate.
- Residual risk may be accepted only by the configured human approval route.
  Mechanical attestation can support the record but cannot replace the
  accountable approval decision.

## Deviation Escalation Rules

Create a critical deviation when any of the following occurs:

- uncontrolled write, merge, release, or scope change;
- failed refusal for dirty work, wrong context, missing blocker, or failed CI;
- missing, altered, unverifiable, or unsigned critical evidence;
- failed cryptographic verification for agent-produced critical evidence;
- secret exposure or prohibited credential material in evidence;
- supplier outage or behavior change that invalidates required evidence.

Create a major deviation when a required control works only after retry,
manual recovery, retest, or compensating review. Create a minor deviation for
documentation variance with no credible impact on evidence integrity,
controlled change, or release readiness.

Critical deviations require impact assessment, root-cause review, corrective
action, retest or documented rationale, and human approval before release.
Recurring major deviations must be converted into CAPA or tracked issues.

## Protocol Coverage Rules

- IQ confirms the configured inventory, tool versions, evidence locations,
  identity stores, and attestation prerequisites are identifiable.
- OQ confirms controls fail closed, record durable blockers, preserve evidence,
  and escalate deviations for all high risks and applicable medium risks.
- PQ confirms that production-like orchestration can complete with acceptable
  residual risk, including concurrent work, human handoff, supplier dependency,
  evidence retention, and final review.
- CSV-08 traceability must link each high and medium risk to at least one
  requirement, protocol step, expected result, evidence artifact, and final
  disposition.

## Residual Risk Review

Residual risks are reviewed at phase gates and during validated-state
maintenance. Review must confirm:

- current criticality and score remain accurate;
- controls are still implemented and effective;
- supplier assumptions from CSV-04 remain valid;
- data integrity and record assumptions from CSV-05 remain valid;
- CSV-05A attribution and integrity controls are available for critical
  agent-produced evidence;
- open deviations, CAPA, incidents, or supplier changes do not require
  revalidation.
