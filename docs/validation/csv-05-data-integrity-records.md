# CSV-05 Data Integrity and Electronic Record Assessment

## Purpose

This document assesses data integrity and electronic record controls for ORDO
evidence. It classifies evidence sources used by validation activities, maps
them to ALCOA+ expectations, defines retention and backup expectations, and
identifies residual risks that must feed CSV-06 risk assessment.

CSV-05 depends on the approved CSV-01 intended-use statement and CSV-02 system
boundary and configuration item inventory. It also anticipates CSV-05A, which
will define the digital or mechanical attestation model for agent-produced
evidence. CSV-05 does not implement cryptographic signing controls; it defines
the data integrity expectations those controls must satisfy.

## Scope

This assessment covers electronic records generated, consumed, or referenced by
ORDO when planning, dispatching, validating, merging, cleaning up, reporting, or
reconciling controlled work.

Covered records include:

- issues, pull requests, review comments, commit metadata, branch metadata, and
  merge evidence from a repository platform or issue tracker;
- CI provider workflow runs, job logs, status checks, artifacts, and run
  identifiers used as validation evidence;
- ORDO audit logs, dispatch prompts, assignment state, preflight state, queue
  state, cleanup records, and findings records;
- generated markdown reports, validation summaries, evidence manifests, and
  reconciliation records;
- command transcripts, local shell outputs, and operator notes when captured
  into an approved evidence location;
- electronic signatures, digest manifests, attestations, or verification
  results when the validation package requires them.

This assessment excludes the correctness of downstream product records,
external platform internal controls, credential lifecycle controls, and final
human approval authority. Those remain covered by the relevant quality,
supplier, security, records, or release procedures.

## Electronic Record Classification

| Record source | Examples | Baseline classification | Primary control expectation |
| --- | --- | --- | --- |
| Repository platform records | Commits, branches, pull requests, reviews, issue links, merge events. | Authoritative for source-control and review history when immutable identifiers are retained. | Capture immutable commit or run identifiers, actor identity, timestamp, and link or export. |
| Issue tracker records | Issues, labels, comments, assignees, blocker notes, acceptance decisions. | Authoritative for issue lifecycle when retained by the configured tracker. | Preserve relevant issue IDs, comment IDs, timestamps, actor identity, and status at time of use. |
| CI provider records | Workflow run, job status, logs, artifacts, checks, rerun metadata. | Authoritative for automated validation result when retained and traceable to commit. | Capture run ID, commit, job name, status, timestamp, and durable log or artifact reference. |
| ORDO audit logs | Dispatch, merge, cleanup, refusal, finding, and controlled-operation events. | Authoritative for ORDO control execution when written to approved evidence storage. | Persist log files, protect from silent overwrite, bind to actor, command, timestamp, and source revision. |
| ORDO state files | Assignment state, queue state, preflight state, cleanup state, portfolio state. | Supporting record unless designated as phase evidence. | Retain snapshots used in decisions; classify routine operational state as non-record or supporting evidence. |
| Dispatch prompts and handoffs | Rendered work instructions, scope boundaries, validation instructions, handoff summaries. | Supporting evidence for scope control and operator/agent instruction. | Retain final prompt version, issue reference, actor, timestamp, and receiving role or agent label. |
| Generated reports | Markdown summaries, validation reports, findings ledgers, evidence indexes. | Authoritative only after review or approval; otherwise supporting draft record. | Preserve source inputs, generation command or process, reviewer disposition, and final approved version. |
| Local command transcripts | Shell output, syntax checks, local test output, manual observations. | Transient until captured; supporting or authoritative after controlled retention. | Capture complete command, working context, timestamp, exit code, and output digest where required. |
| Agent-produced evidence | Code diffs, summaries, observations, generated files, command outputs. | Supporting until cryptographically attributed and reviewed; may become authoritative by procedure. | Require agent identity, scope binding, digest/signature or approved equivalent, and separate human approval. |
| External evidence references | External archive entries, tickets, release records, retained artifacts. | Supporting unless the external system is the authoritative record owner. | Store stable reference, retrieval procedure, owner, retention expectation, and verification result. |

## ALCOA+ Assessment

| Attribute | ORDO expectation | Minimum control |
| --- | --- | --- |
| Attributable | Each critical evidence item identifies the actor, agent label, service identity, or system that produced it. | Capture authenticated actor where available; require signed or digest-bound attestation for critical agent-produced evidence once CSV-05A is approved. |
| Legible | Evidence must remain human-reviewable for the retention period. | Use text, structured JSON, markdown, or exported logs that reviewers can inspect without proprietary runtime state. |
| Contemporaneous | Evidence is captured at or near execution time. | Record timestamps, command order, run identifiers, and audit events during execution rather than reconstructing from memory. |
| Original or true copy | Evidence is the original platform record or a verified true copy. | Prefer immutable platform IDs and retained artifacts; when copied, record export time, source, and digest. |
| Accurate | Evidence accurately reflects the command, state, result, and decision used. | Include command line or action summary, exit status, target revision, branch or issue context, and reviewer checks. |
| Complete | Evidence contains enough context to reproduce the decision path. | Preserve inputs, outputs, status, actor, timestamp, commit, configuration baseline, deviations, and retest evidence. |
| Consistent | Similar evidence is captured with consistent naming, format, and retention rules. | Use stable evidence manifests, CSV IDs, protocol step IDs, and controlled record categories. |
| Enduring | Records remain available for the required retention period. | Store critical evidence in approved durable storage with backup or export controls, not only ephemeral terminal output. |
| Available | Authorized reviewers can retrieve records during review, audit, incident response, or periodic review. | Maintain an evidence index, access instructions, retention owner, and retrieval verification. |

## Data and Evidence Flow Assessment

| Flow | Integrity risk | Required control |
| --- | --- | --- |
| Issue or pull-request data enters dispatch planning. | Labels, comments, assignments, or body text may change after planning. | Capture relevant identifiers and planning output at decision time; cite timestamp and source revision. |
| Dispatch prompt is generated from issue scope. | Prompt may be edited, truncated, or sent to the wrong recipient. | Retain rendered prompt, target issue, receiving role or agent label, and dispatch audit event. |
| Agent or operator executes work. | Local output may be partial, ephemeral, or unattributed. | Capture command, exit code, output, actor identity, and digest or signature for critical evidence. |
| CI provider reports validation status. | Runs may be rerun, logs may expire, or status may not match the reviewed commit. | Bind run ID to commit, retain log or artifact reference, and record rerun or supersession status. |
| ORDO writes local state or audit files. | Files may be overwritten, deleted, or copied without integrity metadata. | Use controlled state roots, append or snapshot critical records, and retain digests for phase evidence. |
| Generated reports summarize evidence. | Summary may omit failed steps, deviations, or source context. | Require source evidence references, reviewer confirmation, and deviation reconciliation before approval. |
| Evidence moves to archive. | Links may break, access may be lost, or copy integrity may be unverified. | Archive manifest includes source, timestamp, owner, checksum or signature, and retrieval test. |

## Retention and Backup Expectations

Critical validation evidence must be retained for the period defined by the
applicable quality and records procedures. The retention package should include:

- approved CSV documents and protocol versions;
- executed command transcripts or CI run records used for acceptance decisions;
- issue, pull-request, commit, and review identifiers cited as evidence;
- ORDO audit logs, dispatch prompts, findings, deviations, and cleanup records
  relied on by IQ, OQ, PQ, or final validation reports;
- evidence manifests, digests, signatures, verification results, and archive
  retrieval checks;
- final approved reports and approval records.

Backup expectations:

- critical evidence must not rely solely on local terminal scrollback,
  disposable shell history, or unretained working directories;
- external platform evidence must be exported, mirrored, archived, or otherwise
  shown to remain retrievable for the retention period;
- evidence stores must have a documented backup or immutability control
  proportionate to record criticality;
- restore or retrieval checks must be performed before final report approval
  when the evidence store is new or materially changed.

## Access Control and Mutation Controls

Access to ORDO evidence must follow least privilege and separation of duties.

Minimum controls:

- only authorized actors may create, modify, approve, archive, or delete
  validation evidence;
- automated actors may generate or attest evidence, but they must not provide
  final quality approval unless a separately approved policy authorizes that
  role;
- secret values must be redacted or excluded from retained evidence while
  preserving enough context to prove the control executed;
- critical evidence should be append-only, immutable, signed, checksum-bound, or
  otherwise protected from undetected mutation;
- any post-execution correction must retain the original record, correction
  reason, actor, timestamp, reviewer disposition, and impact assessment;
- failed access, missing evidence, failed signature verification, or suspected
  mutation must be handled as a deviation unless preclassified as non-critical
  supporting material.

## Agent-Produced Evidence and CSV-05A Dependency

Agent-produced evidence requires additional controls because the actor may be an
automated CLI, service identity, or tool adapter rather than a human executor.

CSV-05 requires the validation package to treat agent-produced critical evidence
as incomplete unless it has:

- a stable agent or service identity record;
- a bounded assignment or scope reference;
- the command, file, or artifact context that produced the evidence;
- timestamp and source revision binding;
- cryptographic attribution and integrity evidence, such as a signature,
  digest-bound attestation, or approved equivalent;
- independent human or organizational review where the evidence affects
  validated status, deviation disposition, or release readiness.

CSV-05A is expected to define the specific attestation format and verification
procedure. Until CSV-05A is approved, missing or failed cryptographic
verification for critical agent-produced evidence must be recorded as a
deviation or explicitly downgraded to non-critical supporting evidence by the
validation owner and quality reviewer.

## Known Limitations

| Limitation | Impact | Required disposition |
| --- | --- | --- |
| Local shell logs can be ephemeral unless persisted. | Passing commands may be unverifiable later. | Capture output into approved evidence storage when used for validation decisions. |
| External API data can change over time. | Later reads may not match the reviewed state. | Retain immutable IDs, timestamps, exports, or snapshots used for acceptance. |
| CI logs and artifacts may expire. | Long-term review may lose detailed execution evidence. | Archive critical logs or artifacts before expiry. |
| Local state files can be overwritten during continued operations. | Decision state may be lost or ambiguous. | Snapshot state files used as evidence and bind them to protocol steps. |
| Generated summaries may omit raw context. | Reviewers may over-rely on interpreted evidence. | Require source evidence references and reviewer trace-back checks. |
| Automated evidence lacks human accountability by itself. | Agent output may be mistaken for approval. | Separate mechanical attestation from human approval and record approval role explicitly. |
| Optional connectors may have inconsistent retention behavior. | Evidence availability may vary by connector. | Classify connector records before execution and retain true copies when needed. |

## Residual Risks for CSV-06

The following residual risks must feed CSV-06:

- critical evidence is not captured before an external platform mutates or
  expires the source record;
- agent-produced evidence lacks approved cryptographic attribution or integrity
  verification;
- generated reports are approved without tracing back to source evidence;
- local state is treated as authoritative without retention, digest, or
  reviewer controls;
- access controls allow unauthorized mutation or deletion of validation
  evidence;
- evidence store backup, archive, or retrieval controls are untested;
- secret redaction removes context needed to prove a control executed;
- transient evidence is used for an IQ, OQ, PQ, deviation, or final report
  decision without being promoted into a retained record.

## Acceptance Criteria for Validation Use

CSV evidence may be used in IQ, OQ, PQ, or final validation reports only when:

- the evidence source is classified as authoritative, supporting, or transient;
- transient evidence has been captured into an approved retained record before
  it is cited for acceptance;
- each critical record is attributable, timestamped, legible, complete, and
  bound to the relevant revision, issue, command, run, or protocol step;
- integrity controls, signatures, digests, or approved equivalent attestations
  are verified where required;
- deviations exist for missing, failed, altered, or unverifiable critical
  evidence;
- final human or organizational approval remains separate from automated or
  mechanical evidence generation.
