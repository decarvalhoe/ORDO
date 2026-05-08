# CSV-IQ-02 Executed IQ Evidence Pack

## Scope

This evidence pack records non-destructive execution of the CSV-IQ-01
Installation Qualification protocol for issue #75. It is evidence for IQ report
preparation only. It does not approve IQ results, release the baseline to OQ, or
replace accountable human review.

The retained evidence uses redacted fields, hashes, generic actor labels, and
controlled artifact references. Exact live repository locations, account names,
machine identifiers, local filesystem paths, credential locations, and private
service details are not retained in this dossier.

## Execution Summary

| Field | Value |
| --- | --- |
| CSV ID | CSV-IQ-02 |
| Source protocol | CSV-IQ-01 |
| Work item | #75 |
| Capture window start UTC | 2026-05-08T02:34:01Z |
| Evidence package close UTC | 2026-05-08T02:38:39Z |
| Executor actor ID | agent-cli-executor-01 |
| Executor actor class | agent CLI |
| Executor identity hash | 53175bcc0524f37b47062fafdda28e3f8eb91d519ca0a184ca71bbebe72f969a |
| Supervising role | technical owner |
| Source revision | 845a3e6e2ca841715b6c31755d832da56d00e748 |
| Source revision short | 845a3e6e2ca8 |
| Branch reference | docs/75-execute-iq-evidence |
| Source cleanliness before evidence authoring | clean |
| Source status hash before evidence authoring | e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 |
| Remote reference hash | c36042191cbd97258cec8967fe8673c8fbfc498b48fd9443a09e050a1d224d24 |
| Execution node hash | 7003548b821bcbe7ce22454c5c2a364216546852b0a3e6d51ea1746ee46b3270 |
| Operating environment hash | 62d3cfea4bd46d46749a50beea826ef6bcd1df2f48745e4bdbbd518eb479d18e |
| Repository-platform actor hash | 3211f6fb2c0daec9c79f3d1217e03aee6a324f9203f3fadfbc14ae67e62455e2 |
| Repository-platform config hash | f789d45b4cd59b1e4c7d8eaab104df02fc2663ca2b852d772905747e34857787 |
| Evidence digest algorithm | SHA-256 |
| Human approval status | pending CSV-IQ-03 review |

## Evidence Manifest

| Evidence ID | Protocol step or range | Artifact reference | Result | Integrity or retention reference |
| --- | --- | --- | --- | --- |
| EV-IQ-001-01 | IQ-001 | This manifest and command log | Pass | Prerequisite records reviewed from controlled validation docs |
| EV-IQ-002-01 | IQ-002 | `command-log.md` | Pass | Source revision and source status hash retained |
| EV-IQ-003-01 | IQ-003 | `command-log.md` | Pass | Source availability and remote reference hash retained |
| EV-IQ-004-01 | IQ-004 | `command-log.md` | Pass | Controlled validation document count retained |
| EV-IQ-005-01 | IQ-005 | `command-log.md` | Pass | Controlled script, library, template, and example counts retained |
| EV-IQ-006-01 | IQ-006 | `command-log.md` | Pass | Syntax and executable readiness review retained |
| EV-IQ-007-01 | IQ-007 | `command-log.md` | Pass | Runtime tool version hashes retained |
| EV-IQ-008-01 | IQ-008 | `command-log.md` | Pass | Terminal multiplexer classified as optional and available |
| EV-IQ-009-01 | IQ-009 | `command-log.md` | Pass | Repository-platform identity hash retained |
| EV-IQ-010-01 | IQ-010 | `command-log.md` | Pass | Issue-tracker controlled reference query passed |
| EV-IQ-011-01 | IQ-011 | `command-log.md` | Pass | Local validation runner commands executed successfully |
| EV-IQ-012-01 | IQ-012 | `command-log.md` | Pass | Example configuration class review passed |
| EV-IQ-013-01 | IQ-013 | `command-log.md` | Pass | Missing-configuration refusal failed closed |
| EV-IQ-014-01 | IQ-014 | `command-log.md` | Pass | Missing-authentication refusal failed closed |
| EV-IQ-015-01 | IQ-015 | `command-log.md` | Pass | Temporary state/audit write-read check passed |
| EV-IQ-016-01 | IQ-016 | `command-log.md` | Pass | Temporary evidence-store write-read check passed |
| EV-IQ-017-01 | IQ-017 | This manifest | Pass | Required CSV-05A fields represented in this evidence pack |
| EV-IQ-018-01 | IQ-018 | This manifest and command log | Pass | Digest-bound attribution and verification path retained |
| EV-IQ-019-01 | IQ-019 | `command-log.md` | Pass | Altered sample digest mismatch detected |
| EV-IQ-020-01 | IQ-020 | This manifest and command log | Pass | Secret values excluded; live identifiers retained only as hashes |
| EV-IQ-021-01 | IQ-021 | `command-log.md` | Pass | Bounded local validation command inventory retained |
| EV-IQ-022-01 | IQ-022 | This manifest | Pass | Dependency classification retained |
| EV-IQ-023-01 | IQ-023 | This manifest | Pass | IQ steps mapped to evidence IDs and deviation route |
| EV-IQ-024-01 | IQ-024 | `deviations.md` | Pass | Evidence pack complete for CSV-IQ-03 preparation |

## Dependency Classification

| Dependency class | IQ classification | Evidence |
| --- | --- | --- |
| Source repository platform | In scope, external service | Identity and controlled-reference query passed |
| Issue tracker | In scope, external service | Controlled-reference query passed |
| CI status source | External service; no release decision recorded here | PR checks are later validation evidence, not IQ approval |
| Local shell environment | In scope for IQ execution | Runtime version hash retained |
| Version-control client | In scope for source baseline | Runtime version hash retained |
| Repository-platform CLI | In scope for auth and issue query | Runtime version hash retained |
| JSON processor | In scope for local tooling | Runtime version hash retained |
| Terminal multiplexer | Optional supporting tool | Version hash retained; not silently required |
| Evidence store | In scope for retained artifacts | Non-secret write-read check passed |
| Secret store | Referenced as a controlled class only | No secret values retained |

## Mechanical Attestation Boundary

This pack uses a mechanism-neutral CSV-05A control outcome: each critical
evidence record is bound to a source revision, UTC capture time, actor label,
actor identity hash, command or review summary, result, and SHA-256 digest or
hash reference. A deliberately altered non-secret sample produced a different
digest and was not treated as acceptable evidence.

Mechanical attestation supports attribution and integrity review. It does not
constitute protocol approval, deviation acceptance, or release to OQ. Accountable
human approval remains pending for CSV-IQ-03.

## Reviewer Disposition

Reviewer disposition is pending independent CSV-IQ-03 review. No deviations were
opened during CSV-IQ-02 execution.
