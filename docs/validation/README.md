# ORDO Validation Master Plan

This Validation Master Plan defines the CSV dossier structure for ORDO and is
the controlling validation index for the current document set.

The dossier uses stable CSV IDs as traceability keys. Issue numbers are work
items and may change independently of this document.

## Current Disposition

Current final validation disposition:

- final validation decision: `FINAL VALIDATION RELEASE REFUSED`;
- production readiness: `NOT PRODUCTION READY`;
- release status: `NOT RELEASED`;
- OQ status: `NOT RELEASED TO PQ`;
- PQ status: stopped at `PQ-001`;
- open deviations: `DEV-OQ-001` and `DEV-PQ-001`;
- unexecuted downstream evidence: `OQ-002` through `OQ-022` and `PQ-002`
  through `PQ-016`;
- final accountable approval: absent.

This VMP therefore governs a blocked, non-release validation package. It must
not be read as production approval, validated-use approval, waiver, deviation
closure, or release authorization.

## Positioning

ORDO is a product-neutral orchestration toolkit. This VMP does not claim that
ORDO is a regulated GxP product by itself. CSV-01 classifies intended use and
regulated impact for a deployment before any validation claim can be made.

Validation effort is proportional to risk, intended use, and record impact. The
dossier favors objective evidence, documented rationale, repeatable checks, and
accountable review over ceremonial paperwork.

A software release of ORDO is separate from a validated-use release decision.
Publishing toolkit code or documentation does not change the current CSV
disposition.

## Guidance Anchors

Use current applicable guidance and regulation for the deployment context. The
baseline anchors for this dossier are:

- [ISPE GAMP 5 Guide, 2nd Edition](https://ispe.org/publications/guidance-documents/gamp-5-guide-2nd-edition),
  for risk-based computerized-system lifecycle thinking and supplier/service
  provider leverage.
- [FDA Computer Software Assurance for Production and Quality System Software](https://www.fda.gov/regulatory-information/search-fda-guidance-documents/computer-software-assurance-production-and-quality-system-software),
  September 2025 final guidance, for risk-based assurance and critical
  thinking.
- [21 CFR Part 11](https://www.ecfr.gov/current/title-21/chapter-I/subchapter-A/part-11)
  and [FDA Part 11 Scope and Application guidance](https://www.fda.gov/regulatory-information/search-fda-guidance-documents/part-11-electronic-records-electronic-signatures-scope-and-application),
  when electronic records or electronic signatures are in scope for a
  deployment.
- [EudraLex Volume 4](https://health.ec.europa.eu/medicinal-products/eudralex/eudralex-volume-4_en)
  Annex 11 and Annex 15, when EU GMP computerized-system or qualification and
  validation expectations are in scope.

## Dossier Documents

The authoritative register is
[document-index.md](document-index.md). Dossier families:

- CSV-01 through CSV-10: foundation, boundaries, responsibilities, risk,
  requirements, traceability, validation strategy, and controlled baseline.
- CSV-IQ-01 through CSV-IQ-03: installation qualification protocol, execution
  evidence, and release to OQ.
- CSV-OQ-01 through CSV-OQ-03: operational qualification protocol, execution
  evidence, deviation handling, and release-to-PQ decision.
- CSV-PQ-01 through CSV-PQ-03: performance qualification protocol, production
  evidence pack, and production readiness decision.
- CSV-VAL-01 and CSV-VAL-02: final traceability reconciliation and final
  validation report.
- CSV-OPS-01: blocked-state governance now, and future maintaining-state
  controls after any later approved release.
- FEAT-CSV-DEV-MODE: neutral dossier scaffold generator. It creates draft
  templates only and cannot validate, waive, approve, or release a system.

## Lifecycle Order

1. CSV-01 establishes intended use and regulated impact.
2. CSV-02 through CSV-05 define boundaries, roles, dependencies, and
   data-integrity or electronic-record impact.
3. CSV-05A defines mechanically attributable, reviewable agent evidence.
4. CSV-06 turns the assessments into risk and criticality controls.
5. CSV-07 and CSV-08 define requirements, acceptance criteria, and
   traceability.
6. CSV-09 and CSV-10 define the validation strategy and controlled baseline.
7. IQ proves the configured system and evidence controls are installed and
   identifiable.
8. OQ proves controlled operating gates and failure handling under defined
   conditions.
9. PQ proves the workflow under production-like use.
10. Final validation reconciles evidence, deviations, approvals, residual risk,
    and release rationale.
11. Maintaining-state procedures govern the current blocked state and, after a
    later approved release, post-release change, incident, CAPA, periodic
    review, and revalidation triggers.

Current lifecycle status: the dossier is blocked after IQ. OQ did not release
to PQ, and PQ did not execute beyond entry.

## Gate Criteria

### Foundation Gate

Exit requires CSV-01 through CSV-10 to be approved or explicitly not applicable
with rationale, and CSV-05A evidence attribution controls to be ready before
protocol execution evidence is relied upon.

### IQ Gate

IQ may release to OQ only when installation/baseline evidence is complete,
deviations are closed or accepted with retained rationale, and the IQ report
records accountable disposition.

Current state: IQ is accepted as completed input for later reconciliation.

### OQ Gate

OQ entry requires an approved IQ report, mapped risks and requirements, defined
test data, and provider-neutral negative paths.

OQ exit requires executed OQ evidence, dispositioned deviations, linked CAPA
where required, and an approved release-to-PQ decision.

Current state: OQ is `NOT RELEASED TO PQ`; `DEV-OQ-001` remains open.

### PQ Gate

PQ entry requires an approved OQ report or approved waiver/deviation route,
defined production-like workflow scope, acceptance criteria, rollback
expectations, evidence retention, and reviewer responsibilities.

PQ exit requires executed production-like evidence, residual-risk disposition,
and an accountable production-readiness decision.

Current state: PQ stopped at `PQ-001`; `PQ-002` through `PQ-016` were not
executed; `DEV-PQ-001` remains open.

### Final Validation Gate

Final validation entry requires approved IQ, OQ, and PQ reports; dispositioned
deviations and CAPA; reconciled traceability; retained approval evidence; and
residual-risk rationale.

Current state: CSV-VAL-01 reconciles a blocked non-release package, and
CSV-VAL-02 refuses final validation release.

## Deviation, CAPA, and Change Control

Protocol deviations must be logged when execution differs from an approved
protocol, expected evidence is missing, observed behavior contradicts an
acceptance criterion, or release restrictions are bypassed.

Deviation severity:

- Critical: could invalidate evidence, bypass a required control, affect a
  regulated record/signature decision, or undermine release readiness.
- Major: affects a requirement, risk control, repeatability, or reviewability
  with a bounded workaround or retest path.
- Minor: documentation or execution variance with no credible validation
  impact and retained rationale.

CAPA is required when a deviation is critical, recurring, systemic, or caused
by an ineffective process. CAPA records must state root cause, correction,
preventive action, owner role, due date, impacted CSV IDs, and effectiveness
verification.

Changes to controlled configuration, validation scripts, evidence controls,
acceptance criteria, rule sets, generated artifacts, or operating gates require
impact assessment. A change related to `DEV-OQ-001` or `DEV-PQ-001` must
preserve the blocked state unless it supplies approved disposition and retest
evidence.

## Evidence and Approval Rules

Every evidence item used for validation decisions should capture:

- CSV ID, issue or change record, protocol step, and acceptance criterion;
- actor role or agent label without vendor-oriented defaults;
- UTC timestamp, source revision, command or action summary, and result;
- artifact path, checksum or immutable reference, and reviewer disposition;
- redaction notation for secrets or unavailable external evidence;
- attestation or signature verification status when required by evidence
  criticality.

Evidence must not rely on terminal scrollback or chat history as the only
record. Mechanical evidence can support review, but human approval remains a
separate accountable decision. Missing, failed, expired, revoked, or
unverifiable critical evidence remains deviation-routed unless responsible
review classifies it as non-critical supporting material with retained
rationale.

## Release Rule

The validated release decision cannot be made from green checks alone. The
minimum release package is:

- approved CSV-01 through CSV-10 foundation documents;
- approved IQ, OQ, and PQ reports;
- reconciled CSV-VAL-01 traceability matrix;
- approved CSV-VAL-02 final validation report;
- active CSV-OPS-01 process appropriate to the approved state;
- dispositioned deviations and CAPA;
- documented residual risks and approval rationale.

That package does not currently exist. The current package is explicitly
blocked and not released.
