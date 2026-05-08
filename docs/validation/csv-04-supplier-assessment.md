# CSV-04 Supplier and Service Provider Assessment

## Purpose

This document defines a universal assessment model for suppliers, service
providers, and dependency classes used by a terminal-agent orchestration
toolkit. It supports CSV evidence by identifying where supplier knowledge can
be relied on, where local controls are required, and where residual risk must
flow into the risk register for CSV-06.

This document is intentionally class-based. Live supplier names, repository
names, account names, session names, provider names, and environment paths must
be recorded in the system boundary and configuration item inventory from
CSV-02, not hardcoded here.

## Assessment Principles

- The implementing organization remains accountable for intended use, risk
  acceptance, data handling, and release decisions.
- Supplier evidence may support validation, but it does not replace local
  verification of configured use.
- Opaque or externally operated services must be treated as black-box
  dependencies unless contractual or technical evidence proves otherwise.
- Evidence produced by automation must preserve attribution and integrity.
  Failed or missing signature verification is a deviation unless the evidence
  is explicitly classified as non-critical supporting material.
- Each dependency class must have an owner, criticality rating, expected
  evidence, monitoring path, and residual risk disposition.

## Dependency Classes

| Class | Typical dependency | Criticality rationale | Baseline controls |
| --- | --- | --- | --- |
| Source control and review platform | Stores code, issues, pull requests, review history, and release decisions. | High when it is the source of truth for controlled changes and approval evidence. | Protected branches, reviewer requirements, audit log access, least-privilege accounts, signed or attributable changes where required. |
| Automation runner service | Executes CI, validation, packaging, or deployment jobs. | High when job output is used as release or validation evidence. | Pinned workflows, controlled secrets, immutable logs where available, runner provenance, failure visibility. |
| Command-line integration tooling | Provides API access for issue, pull request, artifact, and release operations. | Medium to high because it can mutate controlled records when authenticated. | Version capture, scoped credentials, identity guard, command audit, token override detection. |
| Terminal host and session runtime | Runs orchestration loops, terminal agents, shells, and pane interaction. | High when dispatch, recovery, or operational evidence depends on terminal state. | Host access control, time sync, pane targeting proof, command logging, recovery procedures, session health monitoring. |
| Shell, language, and package runtimes | Runs scripts, tests, validators, and local helper tools. | Medium to high depending on whether runtime output is validation evidence. | Version inventory, dependency pinning where practical, trusted installation source, vulnerability monitoring. |
| Agent model or automation provider | Generates analysis, code changes, review feedback, or evidence summaries. | High when outputs influence controlled changes; lower when outputs are only advisory. | Human approval gate, prompt and output retention, attribution, integrity checks, provider configuration record, data classification review. |
| Package, action, and binary distribution channels | Supplies third-party actions, packages, container images, or binaries. | Medium to high because upstream compromise can affect generated evidence or runtime behavior. | Pin versions or digests where practical, review update diffs, vulnerability scanning, trusted source policy. |
| Secret, token, and key management service | Stores credentials for source control, automation, signing, or external APIs. | High because compromise can invalidate auditability and controlled access. | Least privilege, rotation policy, no secret values in evidence, access review, revocation procedure. |
| Evidence storage and audit sink | Stores validation outputs, findings, logs, signatures, and approval records. | High when records are used for audit or release decisions. | Retention policy, write attribution, tamper-evidence, backup or export path, access control. |
| Network, time, and identity infrastructure | Provides connectivity, clock source, DNS, authentication, or authorization. | Medium to high because outages or drift can break evidence attribution. | Time sync monitoring, identity lifecycle review, access logging, outage handling. |
| Operator workstation and administrative environment | Human-operated environment used for controlled overrides or emergency actions. | High when manual actions can change controlled state. | Named accountability, approval evidence, local security baseline, controlled-operation record, cleanup proof. |

## Assessment Criteria

For each instantiated supplier or service provider from the CSV-02 inventory,
record the following:

| Criterion | Required decision |
| --- | --- |
| Intended use | What controlled function depends on the supplier or service. |
| Criticality | High, medium, or low based on impact to safety, quality, evidence integrity, availability, and controlled change. |
| Data classification | Whether prompts, logs, code, issues, secrets, regulated records, or personal data may be processed. |
| Control boundary | Which controls are local, which are supplier-provided, and which are unavailable. |
| Authentication and authorization | Account type, credential scope, rotation expectation, and approval path for privileged access. |
| Change control | How supplier changes, version updates, API changes, and deprecations are detected and assessed. |
| Evidence reliability | Whether evidence is attributable, complete, retained, and protected from tampering. |
| Availability dependency | Operational effect of outage, rate limit, quota exhaustion, or degraded service. |
| Exit or fallback path | How work continues if the supplier is unavailable or no longer acceptable. |
| Residual risk | Accepted, mitigated, transferred, avoided, or open for CSV-06 follow-up. |

## Evidence Expectations

Supplier assessment evidence should include references or records for:

- configuration item identifier from CSV-02
- supplier or service class
- live supplier name in the controlled inventory, not in this generic template
- intended use and criticality rationale
- version, plan, service tier, or runtime image where applicable
- available trust, security, status, retention, or compliance documentation
- local configuration that constrains use, such as protected branches, scoped
  credentials, pinned versions, or runner restrictions
- credential storage, rotation, and revocation expectation
- audit log or event record availability
- change notification or monitoring mechanism
- evidence signing or attribution mechanism for automation-generated records
- known limitations, missing supplier evidence, and compensating local controls
- owner, review cadence, last assessment date, and next review date

Evidence files must not include secret values, private keys, session tokens, or
credential material. Evidence may reference a secret identifier or credential
class only when that reference is safe to disclose.

## Change Monitoring

The operating team should monitor supplier and dependency changes through the
available channels for each class:

- release notes, changelogs, API deprecation notices, and migration guides
- security advisories, vulnerability databases, and package audit output
- service status pages, incident reports, and maintenance notifications
- workflow, action, package, image, and runtime version changes
- authentication policy changes, token scope changes, and key rotation events
- model, automation, or terminal-agent behavior changes that affect generated
  evidence, dispatch reliability, or review quality
- local configuration drift against the approved inventory

Each material supplier change must be triaged for validation impact. Changes
that affect intended use, evidence integrity, access control, or availability
must create a tracked assessment update before they are accepted for controlled
operation.

## Operational Service Assumptions

These assumptions apply unless stronger supplier evidence is recorded:

- External services can be temporarily unavailable, rate limited, throttled, or
  degraded without advance notice.
- External service internals are opaque. Local validation must focus on
  observable behavior, configuration, logs, and outputs.
- Automation-generated output is advisory until accepted by an accountable
  human or a defined automated gate.
- Terminal sessions and local panes are operational surfaces, not durable
  records, unless their relevant output is captured into controlled evidence.
- Hosted runners and remote execution environments may change underlying
  images, tools, or network behavior unless versions are pinned or captured.
- Supplier logs may be incomplete, delayed, unavailable, or retained for a
  shorter period than regulated evidence requires.
- Secrets and tokens are never evidence content. Only the control record for
  their existence, scope, rotation, and revocation is evidence.
- Missing cryptographic attribution for critical automation evidence is a
  deviation that requires documented disposition.

## Residual Risk Handling

Residual supplier risk must be handled through the validation risk process:

1. Assign an owner and criticality.
2. Identify unavailable supplier evidence or unsupported assumptions.
3. Define compensating controls, such as local replay, independent review,
   pinned versions, restricted credentials, additional logging, or manual
   approval.
4. Classify disposition as accepted, mitigated, transferred, avoided, or open.
5. Link open or accepted residual risk into CSV-06 with rationale and review
   date.
6. Reassess after material supplier changes, control failures, incidents, or
   failed evidence attribution.

## Assessment Record Template

Use this template when instantiating the class-based assessment for a specific
controlled environment:

| Field | Value |
| --- | --- |
| Configuration item ID |  |
| Supplier or service class |  |
| Live supplier or service name | Record in controlled inventory. |
| Intended use |  |
| Criticality |  |
| Data handled |  |
| Supplier evidence references |  |
| Local controls |  |
| Monitoring path |  |
| Outage or fallback handling |  |
| Evidence attribution and integrity control |  |
| Residual risk disposition |  |
| Owner |  |
| Last reviewed |  |
| Next review |  |
