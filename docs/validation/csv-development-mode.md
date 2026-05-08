# CSV Development Mode and Validation Dossier Generator

Stable CSV ID: `FEAT-CSV-DEV-MODE`

Issue: #86

Status: Draft feature record.

## Purpose

CSV development mode provides a universal scaffold for preparing a
CSV/GAMP/CSA-style validation dossier for a target system. It creates a
reviewable set of templates, traceability keys, an evidence ledger, a local
issue-tree draft, and an IQ/OQ/PQ dependency graph from target configuration and
detected tooling.

The generator is an engineering aid only. It does not classify a deployment as
regulated, does not approve validation evidence, does not release a system, does
not waive deviations, and does not mark any target system validated.

## Current Dossier Boundary

The current manual ORDO dossier remains governed by CSV-VAL-02 and CSV-OPS-01:

- production readiness is `NOT PRODUCTION READY`;
- release status is `NOT RELEASED`;
- `DEV-OQ-001` and `DEV-PQ-001` remain active until responsible review
  dispositions them;
- generated templates from this feature cannot change that disposition.

## Command

```bash
bash scripts/csv_dev_mode.sh config/project.config.sh \
  --target-dir ./target-system \
  --dossier-dir .ordo/validation \
  --json
```

Dry-run is the default. File writes require `--apply`:

```bash
bash scripts/csv_dev_mode.sh config/project.config.sh \
  --target-dir ./target-system \
  --dossier-dir .ordo/validation \
  --apply \
  --json
```

`ORCH_DRY_RUN=1` or `--dry-run` keeps the command non-mutating even when
`--apply` is supplied.

## Configuration Inputs

The script reads the normal ORDO project config resolver and accepts these
optional variables:

| Variable | Purpose | Safe default |
| --- | --- | --- |
| `CSV_DEV_PROJECT_ID` | Display identifier for the target system. | `PROJECT`, then `target-system` |
| `CSV_DEV_TARGET_DIR` | Target directory when `--target-dir` is not passed. | None; required for a useful run |
| `CSV_DEV_DOSSIER_DIR` | Relative dossier directory under the target. | `validation` |
| `CSV_DEV_REQUIREMENTS` | Optional `ID|requirement|risk` rows. | Generic `URS-001` draft row |
| `CSV_DEV_RISKS` | Optional `ID|risk|control` rows. | Generic `RR-001` draft row |

The dossier directory must be a safe relative path such as `validation` or
`.ordo/validation`. Absolute paths and parent-directory traversal are refused.

## Generated Stable IDs

CSV development mode generates stable traceability IDs for:

- `VMP`, `IU`, `SA`, `DI`, `RR`, `URS`, and `TM`;
- `IQ-P`, `OQ-P`, `PQ-P`, `IQ-R`, `OQ-R`, and `PQ-R`;
- `EL`, `DEV`, `CAPA`, `FVR`, and `OPS`;
- `GRAPH`, `ISSUE-TREE`, `CSV-DEV-README`, and `CSV-DEV-INDEX`.

Each generated file includes an explicit status of draft template, not
validated, and not released.

## Safety Model

- Dry-run reports the planned relative file set and detected tooling classes
  without creating directories or files.
- Apply mode writes only inside the configured target directory and configured
  relative dossier directory.
- Existing files without the generator marker are refused instead of
  overwritten.
- Re-running apply is deterministic for generated files carrying the marker.
- Generated issue-tree output is a local draft only. External issue tracker
  mutation is intentionally outside this scaffold and must be implemented, when
  needed, through a separately configured generic workflow with its own dry-run
  preview and explicit apply gate.

## Evidence Integrity and Human Approval

Generated templates separate mechanical evidence attribution from accountable
human approval:

- the evidence ledger captures source, actor role, command or action, revision
  reference, digest, attestation reference, verification status, criticality,
  deviation reference, and human reviewer;
- verified mechanical evidence can support review, but cannot approve release
  or validated use by itself;
- missing or failed signature or attestation verification for critical evidence
  must route to deviation;
- non-critical supporting evidence may be retained only with documented
  rationale and responsible review.

This accounts for the digitally signed agent evidence dependency without
implementing the full attestation system.

## Dependency Graph

The script derives the IQ/OQ/PQ graph from the generated dossier dependencies
and detected target tooling classes such as language package manifests, build
files, script directories, test directories, configuration directories, and
documentation directories. Detection is intentionally generic and does not infer
a repository platform, CI provider, account, or deployment target.

## Limits

CSV development mode is not a validation authority. It prepares structure and
evidence placeholders for responsible review. Release, waiver, deviation
acceptance, production readiness, and validated-use decisions remain external
accountable actions.
