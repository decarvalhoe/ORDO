# CSV-02 System Boundaries and Configuration Item Inventory

## Purpose

This document defines the qualified ORDO system boundary and the configuration
items that must be controlled, verified, or classified before CSV protocol
execution. It is intended to support installation qualification, operational
qualification, performance qualification, and final validation package assembly.

CSV-02 depends on the approved CSV-01 intended-use and regulated-impact
statement. If a deployment expands ORDO authority, changes the operating model,
or introduces additional regulated record handling, this inventory must be
updated before execution evidence is accepted.

## Boundary Statement

ORDO is bounded as a software orchestration control plane for controlled
engineering workflows. The qualified system includes the repository content,
configuration conventions, command-line scripts, libraries, templates,
validation documentation, example configuration patterns, audit and state
locations, and configured interfaces required to plan, dispatch, monitor,
validate, merge, clean up, and record controlled work.

The ORDO boundary includes behavior implemented and versioned in the ORDO
repository plus deployment-specific configuration that binds ORDO to a target
source-control system, issue or pull-request service, CI service, local shell
toolchain, agent workdirs, state directories, and evidence storage locations.

The ORDO boundary does not include the target product codebase, generated worker
changes, external service correctness, release approval authority, credential
management system, or regulated product behavior. Those systems remain external
and must be validated, qualified, or approved under their own procedures.

## Text Boundary Diagram

```text
Human or approved automation
  -> ORDO command entry points
    -> ORDO scripts, libraries, templates, docs, and examples
      -> controlled configuration
        -> source-control and issue or pull-request service
        -> CI or validation runner
        -> local shell toolchain and optional terminal multiplexer
        -> agent workdirs and ORDO state or audit locations
        -> optional connectors or model/tool adapters
      -> ORDO evidence outputs
        -> logs, audit events, validation outputs, PR/issue comments,
           generated dispatch briefs, findings records, cleanup records
```

## Controlled Baseline Identifiers

Each execution package must record these baseline identifiers before protocol
execution starts:

| Identifier | Required value | Verification method |
| --- | --- | --- |
| ORDO repository reference | Deployment-specific repository URL or repository identifier. | Compare configured repository origin or approved source archive to the protocol header. |
| Commit SHA | Exact commit under qualification. | Record `git rev-parse HEAD` or the equivalent immutable source digest. |
| Branch or release tag | Approved branch, tag, or release package identifier. | Compare to the approved validation plan. |
| Operating system family | OS family and version used for execution. | Record standard OS release output or equivalent platform evidence. |
| Shell | Shell executable and version used to run ORDO commands. | Record shell version command where available. |
| Version-control client | Client name and version used for source operations. | Record configured client version. |
| Issue/PR service client | CLI or API adapter name and version, if used. | Record configured client version and auth identity check result. |
| JSON processor | JSON processor name and version. | Record version output. |
| Terminal multiplexer | Multiplexer name and version, if used by the deployment. | Record version output or mark not used. |
| CI runner | CI service or local validation runner identifier. | Record workflow, job, runner, or local command baseline. |
| Optional connectors | Connector or adapter names, versions, scopes, and enabled status. | Compare configured connector inventory to approved scope. |
| Evidence signing control | Signing or digest mechanism for critical mechanical evidence. | Verify signature, digest, or approved deviation classification. |

Missing optional dependencies must be explicitly classified as "not used",
"not installed", "out of scope", or "deviation" before execution continues.

## Configuration Item Inventory

### Repository-Controlled Items

| Configuration item class | Included items | Qualification expectation |
| --- | --- | --- |
| Command scripts | Shell entry points under the controlled scripts directory. | Present at the approved commit; syntax and relevant regression checks pass. |
| Shared libraries | Reusable shell libraries under the controlled library directory. | Present at the approved commit; covered by dependent script checks. |
| Templates | Dispatch, briefing, prompt, and report templates. | Present at the approved commit; representative rendering or static verification where applicable. |
| Validation docs | CSV documents, architecture notes, runbooks, and controlled operating guidance. | Present at the approved commit; reviewed for consistency with intended use. |
| Examples | Example project, portfolio, or environment configuration files. | Treated as non-production examples unless adopted into deployment configuration. |
| CI workflows | Repository workflow definitions and validation job configuration. | Present at the approved commit; execution result retained as evidence when used. |
| Test suites | Shell, Bats, or other repository test assets. | Present at the approved commit; executed according to the validation plan. |
| Installation assets | Installer or bootstrap scripts and declared toolchain setup guidance. | Verified during IQ when included in deployment setup. |

### Deployment-Controlled Items

| Configuration item class | Included items | Qualification expectation |
| --- | --- | --- |
| Project configuration | Repository identifiers, default branches, workdir templates, state roots, log roots, limits, and feature flags. | Approved before execution; captured as configuration evidence with secrets redacted. |
| Agent inventory | Agent labels, scopes, assigned workdirs, allowed command boundaries, and identity records. | Bound to approved scope; no uncontrolled actor may execute validated steps. |
| Authentication configuration | CLI auth profiles, token scope summaries, service identities, and access review evidence. | Verified for least privilege; secrets are never stored in validation records. |
| State directories | Assignment state, preflight state, portfolio state, local queue state, and cleanup records. | Location and retention policy documented; contents retained when used as evidence. |
| Audit locations | Audit logs, command outputs, run manifests, findings ledgers, and validation transcripts. | Retained with timestamps and integrity controls proportionate to criticality. |
| Runtime limits | Timeout values, concurrency gates, validator semaphores, and dispatch safety settings. | Approved defaults or documented deviations; changes assessed before protocol execution. |
| Evidence signing | Signature keys, digest manifests, attestation policy, and verification commands. | Required for critical mechanical evidence when enabled; failures become deviations unless explicitly classified as non-critical. |

### External Dependencies

| Dependency class | Boundary status | Control expectation |
| --- | --- | --- |
| Source-control service | External dependency. | ORDO verifies configured repository and branch state; service correctness is not validated by ORDO. |
| Issue and pull-request service | External dependency. | ORDO records API or CLI responses as evidence; service availability and provider controls remain external. |
| CI or validation runner | External dependency. | ORDO may rely on configured pass/fail signals; runner configuration and logs must be retained when used as evidence. |
| Local operating system and shell | External dependency. | Version and platform are recorded; unsupported differences require impact assessment. |
| JSON, version-control, and service clients | External dependency. | Versions are recorded and compatibility is verified by IQ or smoke checks. |
| Terminal multiplexer | Optional external dependency. | Used only when the deployment requires pane or session orchestration; identifiers remain deployment-specific. |
| Optional connectors and adapters | Optional external dependency. | Enabled connectors must have scope, version, access, and failure-mode classification. |
| Model or assistant runtime | External dependency. | ORDO controls prompts, scope, and evidence expectations; generated content requires review under the applicable procedure. |
| Credential or secret store | External dependency. | ORDO references credentials through configured clients; it is not the authoritative secret manager. |
| Evidence storage or archive | External dependency. | Retention, immutability, and retrieval controls are verified by the records procedure, not by ORDO alone. |

## Data and Evidence Flows

ORDO processes operational metadata and evidence rather than target product data
as its baseline intended use. The expected flows are:

| Flow | Input | ORDO processing | Output evidence |
| --- | --- | --- | --- |
| Configuration resolution | Approved configuration file or environment binding. | Resolve project, repository, branch, workdir, state, and log settings. | Resolved configuration summary, refusal when required values are missing. |
| Dispatch planning | Open issues, labels, assignees, bodies, dependency signals, and configured priority rules. | Classify ready, blocked, assigned, atomize, stale, or shipped-suspect work. | Dispatch plan JSON or table, blocker rationale, atomization candidates. |
| Dispatch execution | Approved issue scope, agent label, workdir, and branch rules. | Render briefing, verify preflight, submit bounded work, and record handoff. | Dispatch prompt, audit log, assignment state, refusal evidence when unsafe. |
| Validation evidence | CI checks, local command output, syntax checks, shell checks, or protocol steps. | Record pass, fail, timeout, skipped, or delegated validation status. | Validation transcript, CI links or runner output, deviation trigger when missing. |
| Merge or release support | Pull-request metadata, reviews, checks, branch state, and issue links. | Surface blockers, reconcile evidence, and enforce configured merge guardrails. | Merge decision evidence, issue comments, audit entries, refusal reason. |
| Cleanup and rollback | Merged branch state, worktree cleanliness, state records, and parking rules. | Park or clean eligible workdirs and report ambiguous state. | Cleanup log, retained blockers, rollback or manual-action records. |
| Findings management | Operational defects, silent blockers, failed controls, or improvement signals. | Capture finding, impact, detection signal, remediation, validation plan, and priority. | Findings ledger entry or controlled issue reference. |

Critical evidence must have attributable origin, timestamp, command or event
context, and integrity protection appropriate to the validation plan. When
digital or mechanical evidence signing is required but unavailable or failed,
the executor must open a deviation unless the validation owner preclassifies the
artifact as non-critical supporting material.

## Excluded Systems and Rationale

| Excluded item | Rationale |
| --- | --- |
| Target product source code and product runtime | ORDO coordinates work but does not validate downstream product behavior. |
| Worker-generated implementation content | ORDO records evidence and scope; correctness requires product-specific review and testing. |
| External service internal controls | ORDO can record responses and statuses, but provider control design is outside this validation package. |
| Human final approval process | ORDO may present evidence; accountable approval remains a separate quality-system decision. |
| Credential issuance and rotation process | ORDO consumes configured credentials through approved clients; secret lifecycle control is external. |
| Network infrastructure | ORDO may require connectivity, but network design and availability controls are external. |
| General-purpose operating environment hardening | ORDO records platform assumptions; host hardening belongs to infrastructure procedures. |
| Optional connectors not enabled for the deployment | Not part of the qualified state unless explicitly enabled, scoped, and assessed. |
| Uncontrolled local scratch files | Not evidence unless captured into an approved record location with required metadata. |

## Controlled Configuration Categories

Changes in these categories require impact assessment before use in a validated
deployment:

- command scripts, libraries, templates, CI workflows, or validation tests;
- CSV documents, runbooks, intended-use statements, role matrices, or protocol
  content;
- project configuration, default branch rules, repository bindings, workdir
  templates, state roots, log roots, or evidence roots;
- dispatch readiness rules, blocker parsing, dependency inference, priority
  scoring, atomization behavior, or merge guardrails;
- authentication profiles, service identities, token scopes, connector scopes,
  or signing keys;
- external tool versions for shell, version control, JSON processing, issue or
  pull-request access, CI, terminal multiplexing, or connectors;
- timeout, concurrency, host-load, semaphore, cleanup, rollback, and retention
  policies;
- evidence signing, digest verification, archive, or retrieval mechanisms.

Minor editorial changes to non-executable documentation may be handled through
document change control when they do not alter intended use, role assignments,
validation acceptance criteria, operational controls, or evidence requirements.

## IQ Usage

An IQ protocol can use this inventory as its component checklist by verifying:

- every repository-controlled item class exists at the approved commit;
- every deployment-controlled item class has an approved value or an explicit
  "not used" classification;
- required external dependencies are installed, reachable, and versioned;
- optional dependencies are disabled, classified, or included in scope;
- evidence locations are writable by authorized executors and retrievable by
  reviewers;
- critical evidence signing or digest verification is available, or a deviation
  path is approved before execution;
- excluded systems are not silently treated as qualified by ORDO validation.

Any missing required item, unclassified optional dependency, unsupported tool
version, unauthorized actor, broken evidence path, or failed integrity check
must stop protocol execution until dispositioned by the configured validation
owner and quality review path.
