# ORDO Validation Master Plan

This Validation Master Plan (VMP) defines the CSV dossier structure for ORDO.
It is the controlling index for issues #64 through #87 and establishes the
lifecycle order, evidence expectations, and release gates for IQ, OQ, PQ, final
validation, and maintaining the validated state.

Stable CSV IDs are the primary traceability keys. GitHub issue numbers are live
work items and may change state independently of this document.

## Positioning

ORDO is a product-neutral orchestration toolkit. This VMP does not claim that
ORDO is a regulated GxP product by itself. CSV-01 must classify the intended use
and regulated impact for each deployment before any validation claim is made.

Validation effort must be proportional to risk, intended use, and record impact.
The dossier should prefer objective evidence, documented rationale, and
repeatable checks over ceremonial documentation.

## Guidance Anchors

Use current applicable guidance and regulation for the deployment context. The
baseline anchors for this dossier are:

- [ISPE GAMP 5 Guide, 2nd Edition](https://ispe.org/publications/guidance-documents/gamp-5-guide-2nd-edition),
  for risk-based computerized-system lifecycle thinking and supplier/service
  provider leverage.
- [FDA Computer Software Assurance for Production and Quality System Software](https://www.fda.gov/regulatory-information/search-fda-guidance-documents/computer-software-assurance-production-and-quality-system-software),
  September 2025 final guidance, for risk-based assurance and critical thinking.
- [21 CFR Part 11](https://www.ecfr.gov/current/title-21/chapter-I/subchapter-A/part-11)
  and [FDA Part 11 Scope and Application guidance](https://www.fda.gov/regulatory-information/search-fda-guidance-documents/part-11-electronic-records-electronic-signatures-scope-and-application),
  when electronic records or electronic signatures are in scope for a deployment.
- [EudraLex Volume 4](https://health.ec.europa.eu/medicinal-products/eudralex/eudralex-volume-4_en)
  Annex 11 and Annex 15, when EU GMP computerized-system or qualification and
  validation expectations are in scope.

## Dossier Documents

The authoritative index is [document-index.md](document-index.md). The planned
dossier families are:

- CSV-01 through CSV-10: foundation, boundaries, responsibilities, risk,
  requirements, traceability, validation strategy, and controlled baseline.
- CSV-IQ-01 through CSV-IQ-03: installation qualification protocol, execution
  evidence, and release to OQ.
- CSV-OQ-01 through CSV-OQ-03: operational qualification protocol, execution
  evidence, deviation handling, and release to PQ.
- CSV-PQ-01 through CSV-PQ-03: performance qualification protocol, production
  evidence pack, and production readiness decision.
- CSV-VAL-01 through CSV-VAL-02: final traceability reconciliation and final
  validation report.
- CSV-OPS-01: maintaining validated state.
- CSV-05A and FEAT CSV development mode: evidence attestation controls and a
  later automation path after the manual dossier is proven.

## Lifecycle Order

1. CSV-01 establishes intended use and whether a deployment has regulated
   impact.
2. CSV-02 through CSV-05 define boundaries, roles, supplier dependencies, and
   data-integrity or electronic-record impact.
3. CSV-05A defines how agent-produced evidence is mechanically attributable and
   reviewable.
4. CSV-06 turns the preceding assessments into a risk and criticality matrix.
5. CSV-07 and CSV-08 define user requirements, acceptance criteria, and
   traceability.
6. CSV-09 and CSV-10 define the validation strategy and controlled baseline.
7. IQ proves the configured system and evidence controls are installed and
   identifiable.
8. OQ proves controlled operating gates and failure handling under defined
   conditions.
9. PQ proves the workflow under production-like use.
10. Final validation reconciles evidence, deviations, approvals, and release
    rationale.
11. Maintaining validated state governs post-release changes, incidents, CAPA,
    periodic review, and revalidation triggers.
12. CSV development mode automation is considered only after the manual
    reference implementation is complete enough to encode safely.

## Foundation Entry and Exit Criteria

Foundation entry:

- Issue #63 is accepted as the active VMP/index task.
- CSV issues #64 through #87 exist as traceable work items.
- The team agrees to use CSV IDs as stable dossier keys.

Foundation exit:

- CSV-01 through CSV-10 are approved or explicitly not applicable with rationale.
- CSV-05A evidence attribution controls are approved before protocol execution
  evidence is relied upon.
- Risks, requirements, and traceability are reconciled before IQ starts.

## IQ Gate

IQ entry:

- CSV-09 validation strategy and CSV-10 controlled baseline are approved.
- Required configuration items, scripts, docs, workflows, and state locations
  are uniquely identified.
- The CSV-05A attestation model is ready for protocol evidence capture.

IQ exit:

- CSV-IQ-02 evidence proves the baseline was installed or identified as
  specified.
- Any IQ deviations are closed, corrected, or accepted with documented risk
  rationale.
- CSV-IQ-03 approves release to OQ.

## OQ Gate

OQ entry:

- IQ report is approved.
- Critical requirements and risks are mapped to OQ tests.
- Test data, mock services, and negative paths are defined without relying on a
  live product-specific repository or provider.

OQ exit:

- CSV-OQ-02 evidence proves required operating gates, refusals, failure handling,
  and auditability.
- Deviations are dispositioned and any CAPA actions are linked.
- CSV-OQ-03 approves release to PQ.

## PQ Gate

PQ entry:

- OQ report is approved.
- Production-like workflow scope, acceptance criteria, and rollback expectations
  are defined.
- Evidence storage, retention, and reviewer responsibilities are confirmed.

PQ exit:

- CSV-PQ-02 evidence shows the workflow performs acceptably under production-like
  conditions.
- Operational residual risks are documented and accepted.
- CSV-PQ-03 records the production readiness decision.

## Final Validation Gate

Final validation entry:

- IQ, OQ, and PQ reports are approved.
- All open deviations, CAPA items, and change-control records have documented
  disposition.
- Traceability covers intended use, risks, requirements, tests, evidence, and
  approvals.

Final validation exit:

- CSV-VAL-01 reconciles the traceability matrix and evidence pack.
- CSV-VAL-02 records the final release package, limitations, residual risks, and
  approval decision.
- CSV-OPS-01 is active for maintaining validated state after release.

## Deviation, CAPA, and Change Control

Protocol deviations must be logged when execution differs from an approved
protocol, expected evidence is missing, or observed behavior contradicts an
acceptance criterion.

Deviation severity:

- Critical: could invalidate evidence, bypass a required control, or affect a
  regulated record/signature decision.
- Major: affects a requirement, risk control, or repeatability but has a
  bounded workaround or retest path.
- Minor: documentation or execution variance with no credible impact on the
  validated decision.

CAPA is required when a deviation is critical, recurring, systemic, or caused by
an ineffective process. CAPA records must state root cause, correction,
preventive action, owner, due date, and verification of effectiveness.

After CSV-10 is approved, changes to controlled configuration, validation
scripts, evidence controls, acceptance criteria, or operating gates require
change-control assessment. Each change is classified as no-impact, minor,
major, or revalidation-required. The classification must cite affected CSV IDs
and update traceability where needed.

## Maintaining Validated State

CSV-OPS-01 governs validated-state operations after CSV-VAL-02:

- periodic review of intended use, configuration, dependencies, open defects,
  incidents, and evidence retention;
- incident triage with documented impact on validated state;
- change-control review before controlled baseline changes are used as release
  evidence;
- CAPA follow-through for systemic issues;
- revalidation triggers for changed intended use, changed regulated impact,
  changed critical controls, significant dependency changes, or failed periodic
  review.

## Agent Evidence Controls

CSV-05A defines the final mechanism, but the VMP requires every agent-produced
evidence item to be attributable, reviewable, and tamper-evident enough for the
deployment risk. At minimum, evidence should capture:

- CSV ID, issue number, protocol step, and acceptance criterion;
- actor label or execution role, without depending on a provider-specific name;
- UTC timestamp, repository revision, command or action summary, and result;
- artifact path, checksum or immutable reference, and reviewer disposition;
- explicit notation for redacted secrets or unavailable external evidence.

Evidence must not rely on terminal scrollback or chat history as the only
record. Reviewer approval must be captured in a durable artifact or issue/PR
system appropriate to the deployment.

## Release Rule

The validated release decision cannot be made from green checks alone. The
minimum release package is:

- approved CSV-01 through CSV-10 foundation documents;
- approved IQ, OQ, and PQ reports;
- reconciled CSV-VAL-01 traceability matrix;
- approved CSV-VAL-02 final validation report;
- active CSV-OPS-01 validated-state process;
- documented residual risks and approval rationale.
