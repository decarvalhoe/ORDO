#!/usr/bin/env bash
# scripts/csv_dev_mode.sh - scaffold a neutral CSV validation dossier.
set -euo pipefail

TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/config_resolver.sh"
source "$TK/lib/dry_run.sh"

MARKER="<!-- generated-by: ordo-csv-dev-mode v1 -->"

usage() {
  cat <<'EOF' >&2
usage:
  csv_dev_mode.sh <project|config> [--target-dir <dir>]
    [--dossier-dir <validation|.ordo/validation>]
    [--json|--tsv]
    [--apply]
    [--dry-run]

Scaffolds a provider-neutral CSV/GAMP/CSA-style validation dossier plan by
default. Files are written only with --apply, and ORCH_DRY_RUN=1 or --dry-run
keeps the command non-mutating even when --apply is supplied.

The generator prepares templates, evidence ledgers, issue-tree drafts, and
traceability skeletons. It never validates, releases, approves, waives, or
accepts a system automatically.
EOF
}

require_jq() {
  command -v jq >/dev/null 2>&1 || {
    printf 'csv_dev_mode: jq is required\n' >&2
    exit 2
  }
}

add_line() {
  local file=$1 value=$2
  printf '%s\n' "$value" >> "$file"
}

json_string_array() {
  jq -nc '$ARGS.positional' --args "$@"
}

normalize_relative_path() {
  local path=${1:-}
  while [[ "$path" == ./* ]]; do
    path=${path#./}
  done
  while [[ "$path" == */ ]]; do
    path=${path%/}
  done
  printf '%s\n' "$path"
}

relative_path_safe() {
  local path=${1:-} part
  [[ -n "$path" && "$path" != /* ]] || return 1
  IFS='/' read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    [[ -n "$part" && "$part" != "." && "$part" != ".." ]] || return 1
  done
  return 0
}

array_is_declared() {
  declare -p "$1" >/dev/null 2>&1
}

config_rows() {
  local array_name=$1 default_row=$2
  local -n rows_ref=$array_name
  if array_is_declared "$array_name" && [[ "${#rows_ref[@]}" -gt 0 ]]; then
    printf '%s\n' "${rows_ref[@]}"
  else
    printf '%s\n' "$default_row"
  fi
}

parse_row_field() {
  local row=$1 field=$2 rest
  case "$field" in
    1)
      printf '%s\n' "${row%%|*}"
      ;;
    2)
      rest=${row#*|}
      if [[ "$rest" == "$row" ]]; then
        printf '\n'
      else
        printf '%s\n' "${rest%%|*}"
      fi
      ;;
    *)
      case "$row" in
        *'|'*'|'*)
          rest=${row#*|}
          printf '%s\n' "${rest#*|}"
          ;;
        *)
          printf '\n'
          ;;
      esac
      ;;
  esac
}

append_tooling_class() {
  local value=$1 existing
  for existing in "${tooling_classes[@]}"; do
    [[ "$existing" == "$value" ]] && return 0
  done
  tooling_classes+=("$value")
}

detect_tooling_classes() {
  local dir=$1
  tooling_classes=()

  [[ -d "$dir" ]] || {
    append_tooling_class "target-directory-not-present"
    return 0
  }

  [[ -f "$dir/package.json" ]] && append_tooling_class "javascript-package"
  [[ -f "$dir/pyproject.toml" ]] && append_tooling_class "python-project"
  [[ -f "$dir/requirements.txt" ]] && append_tooling_class "python-requirements"
  [[ -f "$dir/go.mod" ]] && append_tooling_class "go-module"
  [[ -f "$dir/Cargo.toml" ]] && append_tooling_class "rust-package"
  [[ -f "$dir/Makefile" ]] && append_tooling_class "make-targets"
  [[ -f "$dir/Dockerfile" ]] && append_tooling_class "container-build-file"
  [[ -f "$dir/compose.yaml" || -f "$dir/compose.yml" ]] && append_tooling_class "container-composition-file"
  [[ -d "$dir/scripts" ]] && append_tooling_class "script-directory"
  [[ -d "$dir/tests" || -d "$dir/test" ]] && append_tooling_class "test-directory"
  [[ -d "$dir/config" ]] && append_tooling_class "configuration-directory"
  [[ -d "$dir/docs" ]] && append_tooling_class "documentation-directory"

  if [[ "${#tooling_classes[@]}" -eq 0 ]]; then
    append_tooling_class "no-tooling-detected"
  fi
}

deliverables_json() {
  jq -nc '[
    {id:"CSV-DEV-README", path:"README.md", title:"Dossier README", purpose:"operator overview and safety model"},
    {id:"CSV-DEV-INDEX", path:"document-index.md", title:"Validation Document Index", purpose:"stable deliverable register"},
    {id:"VMP", path:"validation-plan.md", title:"Validation Master Plan", purpose:"risk-based validation strategy and lifecycle plan"},
    {id:"IU", path:"intended-use.md", title:"Intended Use and Regulatory Scope", purpose:"intended use, regulated impact, and scope assumptions"},
    {id:"SA", path:"supplier-assessment.md", title:"Supplier and Service Assessment", purpose:"external dependency and service leverage assessment"},
    {id:"DI", path:"data-integrity.md", title:"Data Integrity and Electronic Records", purpose:"record integrity, attribution, retention, and reviewability"},
    {id:"RR", path:"risk-register.md", title:"Risk Register", purpose:"quality risk and criticality matrix"},
    {id:"URS", path:"user-requirements.md", title:"User Requirements and Acceptance Criteria", purpose:"requirements linked to risks and tests"},
    {id:"TM", path:"traceability-matrix.md", title:"Traceability Matrix", purpose:"requirements, risks, protocol steps, evidence, and disposition"},
    {id:"IQ-P", path:"iq-protocol.md", title:"IQ Protocol", purpose:"installation and baseline identification protocol"},
    {id:"OQ-P", path:"oq-protocol.md", title:"OQ Protocol", purpose:"operational control and failure-handling protocol"},
    {id:"PQ-P", path:"pq-protocol.md", title:"PQ Protocol", purpose:"production-like workflow protocol"},
    {id:"IQ-R", path:"iq-report.md", title:"IQ Report", purpose:"executed IQ result and release-to-OQ recommendation template"},
    {id:"OQ-R", path:"oq-report.md", title:"OQ Report", purpose:"executed OQ result and release-to-PQ recommendation template"},
    {id:"PQ-R", path:"pq-report.md", title:"PQ Report", purpose:"executed PQ result and production-readiness recommendation template"},
    {id:"EL", path:"evidence-ledger.md", title:"Evidence Ledger", purpose:"mechanical evidence attribution and integrity ledger"},
    {id:"DEV", path:"deviation-log.md", title:"Deviation Log", purpose:"deviation capture, disposition, and retest linkage"},
    {id:"CAPA", path:"capa-log.md", title:"CAPA Log", purpose:"corrective and preventive action tracker"},
    {id:"FVR", path:"final-validation-report.md", title:"Final Validation Report", purpose:"human accountable final package template"},
    {id:"OPS", path:"maintaining-state.md", title:"Maintaining State Procedure", purpose:"change, incident, periodic review, and revalidation controls"},
    {id:"GRAPH", path:"iq-oq-pq-dependency-graph.md", title:"IQ OQ PQ Dependency Graph", purpose:"configured dependency graph from tooling and dossier dependencies"},
    {id:"ISSUE-TREE", path:"issue-tree.md", title:"Issue Tree Draft", purpose:"local issue-tree plan with stable deliverable dependencies"}
  ]'
}

generated_path() {
  local dossier=$1 rel=$2
  printf '%s/%s\n' "$dossier" "$rel"
}

tooling_markdown() {
  local class
  for class in "${tooling_classes[@]}"; do
    printf -- "- \`%s\`\n" "$class"
  done
}

requirements_markdown() {
  local row id text risk
  while IFS= read -r row; do
    id=$(parse_row_field "$row" 1)
    text=$(parse_row_field "$row" 2)
    risk=$(parse_row_field "$row" 3)
    printf "| \`%s\` | %s | %s | Draft |\n" "$id" "${text:-TBD}" "${risk:-TBD}"
  done < <(config_rows CSV_DEV_REQUIREMENTS "URS-001|Define intended use and controlled workflow acceptance criteria.|RR-001")
}

risks_markdown() {
  local row id text control
  while IFS= read -r row; do
    id=$(parse_row_field "$row" 1)
    text=$(parse_row_field "$row" 2)
    control=$(parse_row_field "$row" 3)
    printf "| \`%s\` | %s | %s | Open |\n" "$id" "${text:-TBD}" "${control:-TBD}"
  done < <(config_rows CSV_DEV_RISKS "RR-001|Evidence is incomplete, unauthenticated, or not reviewable.|EL, DEV")
}

phase_steps_markdown() {
  local phase=$1 prefix=$2 target=$3
  cat <<EOF
| Step | Objective | Expected evidence | Acceptance |
| --- | --- | --- | --- |
| \`${prefix}-001\` | Confirm dossier entry gate for ${phase}. | Approved prerequisite records and open-deviation review. | Entry is accepted by accountable reviewer or stopped with deviation. |
| \`${prefix}-002\` | Execute configured checks for ${target}. | Command/action log, revision reference, digest, and verification result. | Checks pass or deviations are opened with retest path. |
| \`${prefix}-003\` | Reconcile evidence integrity. | Evidence ledger entries with attribution and integrity status. | Critical missing or failed verification is deviation-routed. |
| \`${prefix}-004\` | Record ${phase} disposition. | Report draft with reviewer signoff fields. | Human approver records pass, blocked, not applicable, or limited rationale. |
EOF
}

dependency_edges_markdown() {
  cat <<'EOF'
| From | To | Reason |
| --- | --- | --- |
| `IU` | `VMP` | Intended use determines validation scope. |
| `SA`, `DI` | `RR` | Dependency and record controls feed risk criticality. |
| `RR` | `URS` | Requirements should reflect critical risks. |
| `URS`, `RR` | `TM` | Traceability maps requirements and risks to evidence. |
| `TM`, `VMP` | `IQ-P`, `OQ-P`, `PQ-P` | Protocols must cite controlled requirements and risks. |
| `IQ-P` | `IQ-R` | IQ report reconciles executed IQ evidence. |
| `IQ-R` | `OQ-P` | OQ entry depends on accepted IQ disposition or approved limitation. |
| `OQ-P` | `OQ-R` | OQ report reconciles executed OQ evidence. |
| `OQ-R` | `PQ-P` | PQ entry depends on accepted OQ disposition or approved limitation. |
| `PQ-P` | `PQ-R` | PQ report reconciles production-like evidence. |
| `EL`, `DEV`, `CAPA` | `IQ-R`, `OQ-R`, `PQ-R`, `FVR` | Reports consume evidence, deviations, and corrective actions. |
| `FVR` | `OPS` | Maintaining-state controls start only after accountable release decision or blocked-state governance decision. |
EOF
}

issue_tree_markdown() {
  local row id path title
  printf '| Stable ID | Local draft item | Depends on | External action |\n'
  printf '| --- | --- | --- | --- |\n'
  while IFS= read -r row; do
    id=$(jq -r '.id' <<< "$row")
    path=$(generated_path "$dossier_dir" "$(jq -r '.path' <<< "$row")")
    title=$(jq -r '.title' <<< "$row")
    case "$id" in
      CSV-DEV-README|CSV-DEV-INDEX|VMP|IU)
        printf "| \`%s\` | %s (\`%s\`) | Dossier initialization | Local draft only |\n" "$id" "$title" "$path"
        ;;
      IQ-P|OQ-P|PQ-P|IQ-R|OQ-R|PQ-R|FVR|OPS)
        printf "| \`%s\` | %s (\`%s\`) | \`TM\`, \`EL\`, \`DEV\` | Local draft only |\n" "$id" "$title" "$path"
        ;;
      *)
        printf "| \`%s\` | %s (\`%s\`) | \`VMP\`, \`IU\` | Local draft only |\n" "$id" "$title" "$path"
        ;;
    esac
  done < <(jq -c '.[]' <<< "$deliverables")
}

document_index_markdown() {
  local row id path title purpose
  printf '| Stable ID | Document | Path | Purpose | Status |\n'
  printf '| --- | --- | --- | --- | --- |\n'
  while IFS= read -r row; do
    id=$(jq -r '.id' <<< "$row")
    path=$(generated_path "$dossier_dir" "$(jq -r '.path' <<< "$row")")
    title=$(jq -r '.title' <<< "$row")
    purpose=$(jq -r '.purpose' <<< "$row")
    printf "| \`%s\` | %s | \`%s\` | %s | Draft template |\n" "$id" "$title" "$path" "$purpose"
  done < <(jq -c '.[]' <<< "$deliverables")
}

common_header() {
  local id=$1 title=$2
  cat <<EOF
$MARKER

# ${title}

Stable ID: \`${id}\`

Target system: \`${project_id}\`

Status: DRAFT TEMPLATE - NOT VALIDATED - NOT RELEASED.

This file was scaffolded by CSV development mode. It prepares a reviewable
record template only. Human review, approval, release, waiver, and validated-use
decisions remain external accountable actions.
EOF
}

common_evidence_boundary() {
  cat <<'EOF'
## Evidence and Approval Boundary

- Mechanical evidence attribution and integrity fields identify who or what
  produced an artifact, the revision or command source, digest, attestation
  reference, and verification status.
- Human approval is separate. A verified artifact can support review, but it is
  not an approval, release, waiver, or acceptance by itself.
- Missing or failed signature or attestation verification for critical evidence
  must be routed to the deviation log unless the evidence is explicitly
  classified as non-critical support with documented rationale.
EOF
}

emit_generated_file() {
  local id=$1 title=$2
  common_header "$id" "$title"
  printf '\n'

  case "$id" in
    CSV-DEV-README)
      cat <<EOF
## Purpose

This dossier scaffold helps a project prepare CSV/GAMP/CSA-style planning,
evidence, traceability, and report templates. It does not decide whether the
target system is regulated, validated, released, production-ready, or approved.

## Generated Contents

$(document_index_markdown)

## Detected Tooling Classes

$(tooling_markdown)

## Safe Use

- Run without \`--apply\` to preview the dossier plan.
- Run with \`--apply\` only after the plan is accepted and the target directory
  is confirmed.
- Generated files use stable IDs for traceability and include explicit human
  approval fields.
- Issue-tree output is local draft content only. External issue tracker changes
  require a separate configured workflow with its own dry-run and apply gate.

$(common_evidence_boundary)
EOF
      ;;
    CSV-DEV-INDEX)
      cat <<EOF
## Document Register

$(document_index_markdown)

## Control Rules

- Stable IDs are the primary traceability keys.
- File paths are relative to the target directory.
- Draft templates require responsible review before use as controlled records.
- The generator may update only files carrying its generator marker.
EOF
      ;;
    VMP)
      cat <<EOF
## Validation Strategy Template

Record intended use, regulated impact, scope, lifecycle model, approval route,
roles, review cadence, and proportional assurance strategy.

## Lifecycle Gates

| Gate | Entry evidence | Exit evidence | Human decision required |
| --- | --- | --- | --- |
| Foundation | Intended use, boundary, data integrity, risk, and requirements drafts. | Approved or justified foundation records. | Yes |
| IQ | Approved strategy and baseline inventory. | IQ report and deviations disposition. | Yes |
| OQ | Accepted IQ disposition. | OQ report and deviations disposition. | Yes |
| PQ | Accepted OQ disposition. | PQ report and production-like evidence reconciliation. | Yes |
| Final validation | Reconciled IQ/OQ/PQ evidence. | Final report and release decision. | Yes |

$(common_evidence_boundary)
EOF
      ;;
    IU)
      cat <<'EOF'
## Intended Use Assessment

| Field | Draft response |
| --- | --- |
| Intended users | TBD |
| Business or quality process supported | TBD |
| Regulated impact | TBD |
| Electronic records in scope | TBD |
| Electronic signatures in scope | TBD |
| Exclusions | TBD |
| Approval route | TBD |

## Decision Rules

- If regulated impact is uncertain, mark the dossier blocked pending
  responsible classification.
- If the target system creates, changes, transmits, stores, or displays
  regulated records, data-integrity assessment is required before release
  planning.
EOF
      ;;
    SA)
      cat <<'EOF'
## External Dependency Assessment

| Dependency class | Intended use | Assurance evidence | Residual risk | Owner |
| --- | --- | --- | --- | --- |
| Repository platform | TBD | Access, permission, review, issue, and status visibility readiness. | TBD | Technical owner |
| CI provider | TBD | Check visibility, retention, and failure-routing evidence. | TBD | Technical owner |
| Evidence store | TBD | Retention, integrity, redaction, and restore review. | TBD | Validation owner |
| Secret store | TBD | Access policy, rotation, and exclusion from evidence. | TBD | Technical owner |

## Supplier Leverage

Document what external assurance evidence is used, what remains verified by the
target project, and how changes or outages are reviewed.
EOF
      ;;
    DI)
      cat <<EOF
## Data Integrity and Electronic Records

| Record class | Attribution | Integrity | Retention | Reviewability | Criticality |
| --- | --- | --- | --- | --- | --- |
| Configuration baseline | Actor and revision reference | Digest or signed attestation | TBD | Reviewable by role | TBD |
| Command/action evidence | Actor, command/action, timestamp, revision | Digest and verification status | TBD | Reviewable by role | TBD |
| Protocol report | Human author and reviewer | Controlled revision and approval record | TBD | Reviewable by role | TBD |
| External reference | Immutable reference or retained copy | Digest or attestation where available | TBD | Reviewable by role | TBD |

$(common_evidence_boundary)
EOF
      ;;
    RR)
      cat <<EOF
## Risk Register

| Risk ID | Risk statement | Control or evidence | Status |
| --- | --- | --- | --- |
$(risks_markdown)

## Risk Disposition

Risks remain open until linked requirements, protocol evidence, deviations, and
human review disposition are complete.
EOF
      ;;
    URS)
      cat <<EOF
## Requirements

| Requirement ID | Requirement | Linked risk | Status |
| --- | --- | --- | --- |
$(requirements_markdown)

## Acceptance Criteria

Each requirement must map to one or more IQ, OQ, or PQ steps in the traceability
matrix before phase execution.
EOF
      ;;
    TM)
      cat <<EOF
## Traceability Matrix

| Trace ID | Requirement | Risk | Protocol step | Evidence | Disposition |
| --- | --- | --- | --- | --- | --- |
| \`TM-001\` | \`URS-001\` | \`RR-001\` | \`IQ-002\`, \`OQ-002\`, \`PQ-002\` | \`EL-TBD\` | Draft |

## Required Reconciliation

- Every critical requirement must cite executed evidence or a deviation.
- Every failed, skipped, or missing critical step must cite the deviation log.
- No row can be used for release until accountable review accepts the
  disposition.
EOF
      ;;
    IQ-P)
      printf '## IQ Protocol Steps\n\n'
      phase_steps_markdown "IQ" "IQ" "installation and baseline"
      ;;
    OQ-P)
      printf '## OQ Protocol Steps\n\n'
      phase_steps_markdown "OQ" "OQ" "operational controls"
      ;;
    PQ-P)
      printf '## PQ Protocol Steps\n\n'
      phase_steps_markdown "PQ" "PQ" "production-like workflow"
      ;;
    IQ-R|OQ-R|PQ-R)
      local phase=${id%-R}
      cat <<EOF
## ${phase} Report Template

| Field | Value |
| --- | --- |
| Protocol reference | \`${phase}-P\` |
| Execution status | Not executed |
| Open deviations | TBD |
| Evidence ledger references | TBD |
| Human review disposition | Pending |
| Release recommendation | Not made by generator |

## Required Disposition

The responsible reviewer must state passed, blocked, not applicable, or limited
with rationale. This template alone does not release any later phase.
EOF
      ;;
    EL)
      cat <<EOF
## Evidence Ledger

| Evidence ID | Source | Actor role | Command/action | Revision/reference | Digest | Attestation reference | Verification status | Criticality | Deviation | Human reviewer |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| \`EL-001\` | TBD | TBD | TBD | TBD | TBD | TBD | Not verified | TBD | TBD | Pending |

$(common_evidence_boundary)
EOF
      ;;
    DEV)
      cat <<'EOF'
## Deviation Log

| Deviation ID | Trigger | Criticality | Impact | Immediate action | Retest or rationale | Status | Approver |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `DEV-001` | Missing or failed critical signature or attestation verification | TBD | TBD | Stop release use of affected evidence | Retest or approved non-critical rationale | Open | Pending |

## Routing Rules

- Protocol variance, missing evidence, failed verification, or unsupported
  release claim must be logged.
- Critical deviations require responsible review before phase continuation.
EOF
      ;;
    CAPA)
      cat <<'EOF'
## CAPA Log

| CAPA ID | Linked deviation | Root cause | Correction | Preventive action | Owner | Due date | Effectiveness check | Status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `CAPA-001` | TBD | TBD | TBD | TBD | TBD | TBD | TBD | Draft |

CAPA is required when a deviation is critical, recurring, systemic, or caused by
an ineffective process.
EOF
      ;;
    FVR)
      cat <<EOF
## Final Validation Report Template

Release status: NOT RELEASED.

Production readiness: NOT APPROVED.

Validation decision: not made by generator.

| Input | Status | Evidence | Open blockers |
| --- | --- | --- | --- |
| IQ report | Not executed | TBD | TBD |
| OQ report | Not executed | TBD | TBD |
| PQ report | Not executed | TBD | TBD |
| Traceability matrix | Draft | TBD | TBD |
| Evidence ledger | Draft | TBD | TBD |
| Human approval record | Missing | TBD | Required |

## Human Approval Boundary

Only accountable reviewers can approve release, waiver, deviation acceptance,
or validated use. This generated template must remain blocked until executed
evidence, deviations, CAPA, residual risks, and approval records are complete.
EOF
      ;;
    OPS)
      cat <<'EOF'
## Maintaining State Procedure Template

| Trigger | Required control | Evidence |
| --- | --- | --- |
| Controlled change | Impact assessment and regression or revalidation decision | Change record and approval |
| Incident | Impact assessment, deviation if validation may be affected | Incident record and disposition |
| Periodic review | Confirm intended use, dependencies, records, evidence, and open risks | Review report |
| Evidence integrity concern | Verification review and deviation routing | Evidence ledger and deviation record |

Maintaining-state controls start from the current approved or blocked
disposition. This procedure does not create a release decision.
EOF
      ;;
    GRAPH)
      cat <<EOF
## Detected Tooling Classes

$(tooling_markdown)

## Dependency Edges

$(dependency_edges_markdown)

## IQ/OQ/PQ Use of Detected Tooling

| Tooling class | IQ use | OQ use | PQ use |
| --- | --- | --- | --- |
$(for class in "${tooling_classes[@]}"; do printf "| \`%s\` | Identify baseline and configuration. | Exercise configured controls where applicable. | Use in production-like workflow only after OQ disposition. |\n" "$class"; done)
EOF
      ;;
    ISSUE-TREE)
      cat <<EOF
## Issue Tree Draft

This is a local planning artifact. It does not create or update external issue
tracker records. Any external tracker workflow must be configured separately and
must use its own dry-run preview and explicit apply gate.

$(issue_tree_markdown)
EOF
      ;;
    *)
      printf 'csv_dev_mode: unknown generated id: %s\n' "$id" >&2
      exit 2
      ;;
  esac
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

CFG_ARG=${1:-}
[[ -n "$CFG_ARG" ]] || {
  usage
  exit 2
}
shift

ARGS=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run)
      ARGS+=("$1")
      shift
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

dry_run_parse_args "${ARGS[@]}"
set -- "${DRY_RUN_ARGS[@]}"

require_jq
load_project_config "$CFG_ARG"

FORMAT="json"
APPLY=0
project_id=${CSV_DEV_PROJECT_ID:-${PROJECT:-target-system}}
target_dir=${CSV_DEV_TARGET_DIR:-}
dossier_dir=${CSV_DEV_DOSSIER_DIR:-validation}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --target-dir) target_dir=${2:?missing value for --target-dir}; shift 2 ;;
    --dossier-dir) dossier_dir=${2:?missing value for --dossier-dir}; shift 2 ;;
    --json) FORMAT="json"; shift ;;
    --tsv) FORMAT="tsv"; shift ;;
    --apply) APPLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      printf 'csv_dev_mode: unknown arg: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

dossier_dir=$(normalize_relative_path "$dossier_dir")
mode="dry-run"
if [[ "$APPLY" -eq 1 && "${ORCH_DRY_RUN:-0}" != "1" ]]; then
  mode="apply"
fi

blockers_file=$(mktemp)
apply_blockers_file=$(mktemp)
files_file=$(mktemp)
written_file=$(mktemp)
# shellcheck disable=SC2317 # invoked by EXIT trap.
cleanup() {
  rm -f "$blockers_file" "$apply_blockers_file" "$files_file" "$written_file"
}
trap cleanup EXIT

deliverables=$(deliverables_json)

if [[ -z "$target_dir" ]]; then
  add_line "$blockers_file" "target_dir_missing"
elif [[ -e "$target_dir" && ! -d "$target_dir" ]]; then
  add_line "$blockers_file" "target_not_directory"
elif [[ ! -d "$target_dir" ]]; then
  add_line "$apply_blockers_file" "target_dir_not_found"
fi

if ! relative_path_safe "$dossier_dir"; then
  add_line "$blockers_file" "dossier_dir_must_be_relative_safe_path"
fi

if [[ -n "$target_dir" && -e "$target_dir/$dossier_dir" && ! -d "$target_dir/$dossier_dir" ]]; then
  add_line "$blockers_file" "dossier_path_not_directory"
fi

detect_tooling_classes "$target_dir"
tooling_json=$(json_string_array "${tooling_classes[@]}")

while IFS= read -r row; do
  rel=$(jq -r '.path' <<< "$row")
  id=$(jq -r '.id' <<< "$row")
  title=$(jq -r '.title' <<< "$row")
  purpose=$(jq -r '.purpose' <<< "$row")
  path=$(generated_path "$dossier_dir" "$rel")
  exists=false
  managed=false
  action="create"

  if [[ -n "$target_dir" && -e "$target_dir/$path" ]]; then
    exists=true
    if grep -Fq "$MARKER" "$target_dir/$path" 2>/dev/null; then
      managed=true
      action="update"
    else
      action="refuse-existing-unmanaged"
      add_line "$apply_blockers_file" "generated_file_exists_unmanaged:$path"
    fi
  fi

  jq -nc \
    --arg id "$id" \
    --arg path "$path" \
    --arg title "$title" \
    --arg purpose "$purpose" \
    --arg action "$action" \
    --argjson exists "$exists" \
    --argjson managed "$managed" \
    '{id:$id,path:$path,title:$title,purpose:$purpose,exists:$exists,managed:$managed,action:$action}' \
    >> "$files_file"
done < <(jq -c '.[]' <<< "$deliverables")

emit_report() {
  local status=$1
  local blockers_json apply_blockers_json files_json written_json safe_to_apply
  local target_configured
  blockers_json=$(jq -R -s 'split("\n") | map(select(length > 0)) | unique' "$blockers_file")
  apply_blockers_json=$(jq -R -s 'split("\n") | map(select(length > 0)) | unique' "$apply_blockers_file")
  files_json=$(jq -s '.' "$files_file")
  written_json=$(jq -R -s 'split("\n") | map(select(length > 0))' "$written_file")
  if [[ -n "$target_dir" ]]; then
    target_configured=true
  else
    target_configured=false
  fi
  if [[ "$(jq -r 'length' <<< "$blockers_json")" -eq 0 && "$(jq -r 'length' <<< "$apply_blockers_json")" -eq 0 ]]; then
    safe_to_apply=true
  else
    safe_to_apply=false
  fi

  if [[ "$FORMAT" == "json" ]]; then
    jq -n \
      --arg status "$status" \
      --arg mode "$mode" \
      --arg project_id "$project_id" \
      --arg dossier_dir "$dossier_dir" \
      --argjson target_dir_configured "$target_configured" \
      --argjson safe_to_apply "$safe_to_apply" \
      --argjson tooling_classes "$tooling_json" \
      --argjson blockers "$blockers_json" \
      --argjson apply_blockers "$apply_blockers_json" \
      --argjson files "$files_json" \
      --argjson written_files "$written_json" \
      '{
        status:$status,
        mode:$mode,
        project_id:$project_id,
        target_dir_configured:$target_dir_configured,
        dossier_dir:$dossier_dir,
        safe_to_apply:$safe_to_apply,
        generator_limits:{
          validates_system:false,
          releases_system:false,
          approves_human_decisions:false,
          mutates_only_with_apply:($mode == "apply")
        },
        tooling_classes:$tooling_classes,
        blockers:$blockers,
        apply_blockers:$apply_blockers,
        files:$files,
        written_files:$written_files
      }'
    return 0
  fi

  printf 'status\t%s\n' "$status"
  printf 'mode\t%s\n' "$mode"
  printf 'project_id\t%s\n' "$project_id"
  printf 'dossier_dir\t%s\n' "$dossier_dir"
  jq -r '.[] | "tooling\t" + .' <<< "$tooling_json"
  jq -r '.[] | "blocker\t" + .' <<< "$blockers_json"
  jq -r '.[] | "apply_blocker\t" + .' <<< "$apply_blockers_json"
  jq -r '.[] | "file\t\(.id)\t\(.path)\t\(.action)"' <<< "$files_json"
  jq -r '.[] | "written\t" + .' <<< "$written_json"
}

hard_blocker_count=$(jq -R -s 'split("\n") | map(select(length > 0)) | unique | length' "$blockers_file")
apply_blocker_count=$(jq -R -s 'split("\n") | map(select(length > 0)) | unique | length' "$apply_blockers_file")

if [[ "$mode" != "apply" ]]; then
  if [[ "$hard_blocker_count" -gt 0 ]]; then
    emit_report "blocked"
  else
    emit_report "dry-run"
  fi
  exit 0
fi

if [[ "$hard_blocker_count" -gt 0 || "$apply_blocker_count" -gt 0 ]]; then
  emit_report "blocked"
  exit "${CSV_DEV_MODE_REFUSAL_EXIT_CODE:-78}"
fi

mkdir -p "$target_dir/$dossier_dir"
while IFS= read -r row; do
  rel=$(jq -r '.path' <<< "$row")
  id=$(jq -r '.id' <<< "$row")
  title=$(jq -r '.title' <<< "$row")
  path=$(generated_path "$dossier_dir" "$rel")
  dest="$target_dir/$path"
  if [[ -e "$dest" ]] && ! grep -Fq "$MARKER" "$dest" 2>/dev/null; then
    add_line "$apply_blockers_file" "generated_file_exists_unmanaged:$path"
    emit_report "blocked"
    exit "${CSV_DEV_MODE_REFUSAL_EXIT_CODE:-78}"
  fi
  mkdir -p "$(dirname "$dest")"
  emit_generated_file "$id" "$title" > "$dest"
  add_line "$written_file" "$path"
done < <(jq -c '.[]' <<< "$deliverables")

emit_report "ready"
