#!/usr/bin/env bash
# scripts/project_scaffold.sh - select a neutral project archetype and scaffold a minimum baseline.
set -euo pipefail

TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/config_resolver.sh"
source "$TK/lib/dry_run.sh"

usage() {
  cat <<'EOF' >&2
usage:
  project_scaffold.sh <project|config> --intent <text> --target-dir <dir>
    [--archetype <auto|generic|service|web-interface|worker|library|data-workflow|documentation>]
    [--repo-mode <existing|greenfield>]
    [--readiness-report <path>]
    [--json|--tsv]
    [--apply]
    [--overwrite]
    [--dry-run]

Plans a neutral minimum viable project scaffold by default. Files are written
only with --apply, and ORCH_DRY_RUN=1 or --dry-run keeps the command
non-mutating even when --apply is supplied.
EOF
}

require_jq() {
  command -v jq >/dev/null 2>&1 || {
    printf 'project_scaffold: jq is required\n' >&2
    exit 2
  }
}

shell_quote() {
  printf '%q' "$1"
}

json_string_array() {
  if [[ "$#" -eq 0 ]]; then
    printf '[]\n'
    return 0
  fi
  printf '%s\0' "$@" | jq -Rs 'split("\u0000")[:-1]'
}

valid_archetype() {
  case "${1:-}" in
    auto|generic|service|web-interface|worker|library|data-workflow|documentation)
      return 0
      ;;
  esac
  return 1
}

valid_repo_mode() {
  case "${1:-}" in
    existing|greenfield)
      return 0
      ;;
  esac
  return 1
}

contains_signal() {
  local text=$1 pattern=$2
  grep -Eiq "$pattern" <<< "$text"
}

select_archetype() {
  local requested=$1 intent_text=$2 lowered
  if [[ "$requested" != "auto" ]]; then
    printf '%s|explicit operator selection\n' "$requested"
    return 0
  fi

  lowered=$(tr '[:upper:]' '[:lower:]' <<< "$intent_text")
  if contains_signal "$lowered" '(^|[^a-z])(service|api|endpoint|request|response|integration|webhook)([^a-z]|$)'; then
    printf 'service|intent mentions service or integration boundary\n'
  elif contains_signal "$lowered" '(^|[^a-z])(user interface|interface|screen|dashboard|portal|form|web)([^a-z]|$)'; then
    printf 'web-interface|intent mentions user-facing interface\n'
  elif contains_signal "$lowered" '(^|[^a-z])(worker|job|queue|scheduled|background|automation|processor)([^a-z]|$)'; then
    printf 'worker|intent mentions asynchronous or background work\n'
  elif contains_signal "$lowered" '(^|[^a-z])(library|package|module|sdk|reusable|component)([^a-z]|$)'; then
    printf 'library|intent mentions reusable software component\n'
  elif contains_signal "$lowered" '(^|[^a-z])(data|pipeline|import|export|report|analytics|batch)([^a-z]|$)'; then
    printf 'data-workflow|intent mentions data movement or reporting\n'
  elif contains_signal "$lowered" '(^|[^a-z])(documentation|runbook|policy|knowledge|manual|procedure)([^a-z]|$)'; then
    printf 'documentation|intent mentions documentation or operating procedure\n'
  else
    printf 'generic|no dominant archetype signal in product intent\n'
  fi
}

archetype_assumptions() {
  local selected=$1
  case "$selected" in
    service)
      json_string_array \
        "A service boundary is useful for the stated intent." \
        "Transport, runtime, data contracts, and deployment target remain undecided." \
        "The scaffold does not select a framework or hosting provider."
      ;;
    web-interface)
      json_string_array \
        "A user-facing interaction surface is useful for the stated intent." \
        "Client runtime, design system, accessibility targets, and deployment target remain undecided." \
        "The scaffold does not select a framework or hosting provider."
      ;;
    worker)
      json_string_array \
        "The intended behavior can be represented as asynchronous or scheduled work." \
        "Queueing, trigger source, retry policy, runtime, and deployment target remain undecided." \
        "The scaffold does not select a framework or hosting provider."
      ;;
    library)
      json_string_array \
        "The intended behavior can be packaged as a reusable component." \
        "Language, packaging format, public API, versioning, and distribution channel remain undecided." \
        "The scaffold does not select a framework or package registry."
      ;;
    data-workflow)
      json_string_array \
        "The intended behavior involves data movement, transformation, reporting, or batch work." \
        "Data sources, schemas, retention, execution cadence, and runtime remain undecided." \
        "The scaffold does not select a data platform or framework."
      ;;
    documentation)
      json_string_array \
        "The intended output is primarily controlled knowledge, procedure, or guidance." \
        "Review cadence, publication target, ownership, and approval model remain undecided." \
        "The scaffold does not select a documentation platform."
      ;;
    *)
      json_string_array \
        "The intent does not yet justify a specialized archetype." \
        "The baseline stays neutral until product and engineering decisions are made." \
        "The scaffold does not select a framework, provider, or runtime."
      ;;
  esac
}

required_decisions() {
  local selected=$1
  case "$selected" in
    service)
      json_string_array \
        "Confirm service interface contract and consumers." \
        "Choose runtime, framework, deployment target, and validation strategy." \
        "Define data model, error handling, security boundary, and observability requirements."
      ;;
    web-interface)
      json_string_array \
        "Confirm primary users, workflows, accessibility target, and content model." \
        "Choose client runtime, design system, deployment target, and validation strategy." \
        "Define authentication, authorization, data access, and analytics requirements."
      ;;
    worker)
      json_string_array \
        "Confirm trigger source, schedule or queue model, retry policy, and failure handling." \
        "Choose runtime, deployment target, persistence model, and validation strategy." \
        "Define idempotency, observability, data retention, and operational handoff rules."
      ;;
    library)
      json_string_array \
        "Confirm supported consumers, public API, compatibility policy, and versioning model." \
        "Choose implementation language, packaging format, distribution channel, and validation strategy." \
        "Define security review, dependency policy, and release process."
      ;;
    data-workflow)
      json_string_array \
        "Confirm source systems, target outputs, schema ownership, and data classification." \
        "Choose runtime, transformation approach, scheduling model, and validation strategy." \
        "Define reconciliation, retention, access control, and failure handling."
      ;;
    documentation)
      json_string_array \
        "Confirm audience, ownership, review cadence, and approval route." \
        "Choose publication target, versioning model, and validation strategy." \
        "Define change control, retention, and archival expectations."
      ;;
    *)
      json_string_array \
        "Confirm whether this should become a service, interface, worker, library, data workflow, documentation set, or another archetype." \
        "Choose runtime, framework if any, deployment target, validation strategy, and operating model." \
        "Define owner, users, core workflows, data handling, security, and release gates."
      ;;
  esac
}

scaffold_files_json() {
  jq -nc '[
    {path: ".gitignore", executable: false, purpose: "generic ignore policy"},
    {path: ".env.example", executable: false, purpose: "environment variable placeholders without secret values"},
    {path: "README.md", executable: false, purpose: "operator-facing project baseline"},
    {path: "docs/architecture.md", executable: false, purpose: "neutral architecture record"},
    {path: "docs/bootstrap-summary.md", executable: false, purpose: "bootstrap assumptions and remaining decisions"},
    {path: "docs/decisions/0001-project-archetype.md", executable: false, purpose: "archetype decision record"},
    {path: "docs/operator-runbook.md", executable: false, purpose: "minimum operator handoff and validation notes"},
    {path: "docs/requirements.md", executable: false, purpose: "initial product intent and acceptance questions"},
    {path: "config/project.config.example.sh", executable: false, purpose: "generic ORDO-ready configuration placeholders"},
    {path: "ci/validate.sh", executable: true, purpose: "provider-neutral validation stub"}
  ]'
}

repository_contract_command() {
  local mode=$1
  case "$mode" in
    existing)
      printf 'bash scripts/repository_platform_readiness.sh <project> --json\n'
      ;;
    greenfield)
      printf 'bash scripts/repository_bootstrap.sh <project> --apply --json\n'
      ;;
    *)
      printf 'select --repo-mode existing or --repo-mode greenfield\n'
      ;;
  esac
}

readiness_report_status() {
  local report=${1:-}
  [[ -n "$report" && -f "$report" ]] || return 1
  jq -r '.status // ""' "$report" 2>/dev/null || return 1
}

target_has_unmanaged_content() {
  local dir=${1:?usage: target_has_unmanaged_content <dir>}
  [[ -d "$dir" ]] || return 1
  while IFS= read -r entry; do
    case "$(basename "$entry")" in
      .git)
        continue
        ;;
    esac
    return 0
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -print 2>/dev/null)
  return 1
}

add_line() {
  local file=$1 value=$2
  printf '%s\n' "$value" >> "$file"
}

emit_scaffold_file() {
  local rel=$1
  case "$rel" in
    .gitignore)
      cat <<'EOF'
# local environment
.env
.env.*
!.env.example

# generated caches
.cache/
tmp/
coverage/

# dependency and build outputs
dist/
build/

# operating system and editor files
.DS_Store
*.swp
EOF
      ;;
    .env.example)
      cat <<'EOF'
# Copy to an environment-specific file and fill through the approved secret store.
PROJECT_ENVIRONMENT=
EVIDENCE_STORE_REF=
SECRET_STORE_REF=
CI_PROVIDER_REF=
REPOSITORY_PLATFORM_REF=
EOF
      ;;
    README.md)
      cat <<EOF
# Project Baseline

## Product Intent

${intent}

## Selected Archetype

- Archetype: ${selected_archetype}
- Selection reason: ${selection_reason}

## Safe Defaults

- No framework, provider, runtime, hosting target, account, or repository name is selected by this scaffold.
- Repository readiness remains governed by the ORDO repository-platform readiness and bootstrap contracts.
- CI is represented by a provider-neutral validation stub until the engineering team chooses the real runner.

## Remaining Decisions

See [docs/bootstrap-summary.md](docs/bootstrap-summary.md) for assumptions and decisions still required.
EOF
      ;;
    docs/architecture.md)
      cat <<EOF
# Architecture Baseline

## Archetype

${selected_archetype}

## Intent

${intent}

## Initial Boundary

The baseline is intentionally neutral. It defines documentation, configuration
placeholders, validation stubs, and operator notes only. Product-specific
runtime, framework, persistence, interface, deployment, and repository-platform
choices require separate engineering approval.

## ORDO Compatibility

Before fleet provisioning, run the repository-platform readiness contract for
an existing repository or the repository bootstrap contract for a greenfield
repository. Store the resulting report as onboarding evidence.
EOF
      ;;
    docs/bootstrap-summary.md)
      cat <<EOF
# Bootstrap Summary

## Scaffolded Automatically

- Generic ignore file.
- Environment template without secret values.
- Provider-neutral validation stub.
- ORDO-ready configuration placeholder.
- Initial architecture, requirements, decision, and operator documents.

## Selected Archetype

- Archetype: ${selected_archetype}
- Selection reason: ${selection_reason}

## Assumptions

$(jq -r '.[] | "- " + .' <<< "$assumptions_json")

## Product and Engineering Decisions Still Required

$(jq -r '.[] | "- " + .' <<< "$decisions_json")

## Repository Readiness Contract

- Repository mode: ${repo_mode:-not selected}
- Required readiness command: ${contract_command}
- Readiness report supplied: ${readiness_report:-not supplied}
- Readiness status: ${readiness_status:-not verified}
EOF
      ;;
    docs/decisions/0001-project-archetype.md)
      cat <<EOF
# 0001 Project Archetype

## Status

Proposed

## Decision

Use the \`${selected_archetype}\` archetype as the initial scaffold shape.

## Rationale

${selection_reason}

## Consequences

- The scaffold stays framework-neutral until the engineering team chooses a runtime.
- ORDO readiness is delegated to the repository-platform readiness or bootstrap contract.
- Product and engineering decisions listed in the bootstrap summary must be resolved before delivery planning.
EOF
      ;;
    docs/operator-runbook.md)
      cat <<'EOF'
# Operator Runbook

## Before Agent Orchestration

1. Confirm the product intent and selected archetype are still accurate.
2. Resolve the decisions listed in the bootstrap summary.
3. Run the repository-platform readiness contract for an existing repository or
   the repository bootstrap contract for a greenfield repository.
4. Record the readiness report as onboarding evidence.
5. Replace the provider-neutral validation stub with the approved project checks.

## Stop Conditions

- Repository readiness report is missing or blocked.
- Product intent is ambiguous.
- A required decision is unresolved but needed for implementation.
- A secret value would be written into source control or evidence.
- The selected archetype no longer matches the intended product.
EOF
      ;;
    docs/requirements.md)
      cat <<EOF
# Initial Requirements

## Product Intent

${intent}

## Minimum Acceptance Questions

- Who are the intended users or consumers?
- What outcome must the first usable baseline prove?
- What data or records are created, changed, retained, or deleted?
- What security, privacy, audit, or validation obligations apply?
- What checks must pass before work can be handed to agents?

## Initial Acceptance Criteria

- Repository readiness evidence is available.
- Product and engineering decisions required by the bootstrap summary are reviewed.
- The validation stub is replaced or explicitly accepted as a placeholder.
- The first implementation issue references this baseline.
EOF
      ;;
    config/project.config.example.sh)
      cat <<'EOF'
#!/usr/bin/env bash
# Generic ORDO project configuration placeholder.
# Fill values in a deployment-specific config file; do not store secrets here.

PROJECT=
DEFAULT_BRANCH=main

# Repository/platform readiness contract inputs.
REPOSITORY_PLATFORM_REPOSITORY=
REPOSITORY_PLATFORM_CLI_BIN=
ORCH_EXPECTED_REPOSITORY_PLATFORM_IDENTITY=

# Greenfield bootstrap contract inputs.
REPOSITORY_BOOTSTRAP_WORKDIR=
REPOSITORY_BOOTSTRAP_REMOTE_URL=
REPOSITORY_BOOTSTRAP_CONFIG_OUTPUT=

# Later fleet provisioning can add agent inventory, workdir templates, and
# identity bindings after repository readiness passes.
EOF
      ;;
    ci/validate.sh)
      cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

missing=0
for required in README.md docs/architecture.md docs/bootstrap-summary.md config/project.config.example.sh; do
  if [[ ! -s "$required" ]]; then
    printf 'missing required scaffold file: %s\n' "$required" >&2
    missing=1
  fi
done

if [[ "$missing" -ne 0 ]]; then
  exit 1
fi

printf 'baseline scaffold validation passed; replace this stub with approved project checks\n'
EOF
      ;;
    *)
      printf 'project_scaffold: unknown scaffold file: %s\n' "$rel" >&2
      exit 2
      ;;
  esac
}

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

FORMAT="json"
APPLY=0
OVERWRITE=0
intent=${PROJECT_SCAFFOLD_INTENT:-}
requested_archetype=${PROJECT_SCAFFOLD_ARCHETYPE:-auto}
target_dir=${PROJECT_SCAFFOLD_TARGET_DIR:-}
repo_mode=${PROJECT_SCAFFOLD_REPO_MODE:-}
readiness_report=${PROJECT_SCAFFOLD_READINESS_REPORT:-}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --intent) intent=${2:?missing value for --intent}; shift 2 ;;
    --archetype) requested_archetype=${2:?missing value for --archetype}; shift 2 ;;
    --target-dir) target_dir=${2:?missing value for --target-dir}; shift 2 ;;
    --repo-mode) repo_mode=${2:?missing value for --repo-mode}; shift 2 ;;
    --readiness-report) readiness_report=${2:?missing value for --readiness-report}; shift 2 ;;
    --json) FORMAT="json"; shift ;;
    --tsv) FORMAT="tsv"; shift ;;
    --apply) APPLY=1; shift ;;
    --overwrite) OVERWRITE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      printf 'project_scaffold: unknown arg: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

require_jq
load_project_config "$CFG_ARG"

blockers_file=$(mktemp)
apply_blockers_file=$(mktemp)
files_file=$(mktemp)
written_file=$(mktemp)
# shellcheck disable=SC2317 # invoked by EXIT trap.
cleanup() {
  rm -f "$blockers_file" "$apply_blockers_file" "$files_file" "$written_file"
}
trap cleanup EXIT

if [[ -z "$intent" ]]; then
  add_line "$blockers_file" "intent_missing"
fi
if ! valid_archetype "$requested_archetype"; then
  add_line "$blockers_file" "archetype_invalid"
  requested_archetype="auto"
fi
if [[ -z "$target_dir" ]]; then
  add_line "$blockers_file" "target_dir_missing"
fi
if [[ -n "$repo_mode" ]] && ! valid_repo_mode "$repo_mode"; then
  add_line "$blockers_file" "repo_mode_invalid"
fi
if [[ -z "$repo_mode" ]]; then
  add_line "$apply_blockers_file" "repo_mode_required_for_apply"
fi

selection=$(select_archetype "$requested_archetype" "$intent")
selected_archetype=${selection%%|*}
selection_reason=${selection#*|}
assumptions_json=$(archetype_assumptions "$selected_archetype")
decisions_json=$(required_decisions "$selected_archetype")
contract_command=$(repository_contract_command "$repo_mode")
readiness_status=""

if [[ -n "$readiness_report" ]]; then
  if [[ ! -f "$readiness_report" ]]; then
    add_line "$apply_blockers_file" "readiness_report_not_found"
  elif ! readiness_status=$(readiness_report_status "$readiness_report"); then
    readiness_status=""
    add_line "$apply_blockers_file" "readiness_report_unreadable"
  elif [[ "$readiness_status" != "ready" ]]; then
    add_line "$apply_blockers_file" "readiness_report_not_ready"
  fi
else
  add_line "$apply_blockers_file" "readiness_report_required_for_apply"
fi

if [[ -n "$target_dir" ]]; then
  if [[ -e "$target_dir" && ! -d "$target_dir" ]]; then
    add_line "$blockers_file" "target_not_directory"
  elif [[ -d "$target_dir" ]] && target_has_unmanaged_content "$target_dir"; then
    add_line "$apply_blockers_file" "target_dir_not_empty"
  fi
fi

while IFS= read -r file_row; do
  rel=$(jq -r '.path' <<< "$file_row")
  executable=$(jq -r '.executable' <<< "$file_row")
  purpose=$(jq -r '.purpose' <<< "$file_row")
  exists=false
  if [[ -n "$target_dir" && -e "$target_dir/$rel" ]]; then
    exists=true
    if [[ "$OVERWRITE" -ne 1 ]]; then
      add_line "$apply_blockers_file" "scaffold_file_exists:$rel"
    fi
  fi
  jq -nc --arg path "$rel" --argjson executable "$executable" \
    --arg purpose "$purpose" --argjson exists "$exists" \
    '{path:$path,executable:$executable,purpose:$purpose,exists:$exists,action:(if $exists then "would-overwrite-or-refuse" else "create" end)}' \
    >> "$files_file"
done < <(jq -c '.[]' <<< "$(scaffold_files_json)")

mode="plan"
if [[ "$APPLY" -eq 1 ]]; then
  if dry_run_enabled; then
    mode="dry-run"
  else
    mode="apply"
  fi
fi

emit_report() {
  local status=$1
  local blockers_json apply_blockers_json files_json written_json safe_to_apply
  blockers_json=$(jq -R -s 'split("\n") | map(select(length > 0)) | unique' "$blockers_file")
  apply_blockers_json=$(jq -R -s 'split("\n") | map(select(length > 0)) | unique' "$apply_blockers_file")
  files_json=$(jq -s '.' "$files_file")
  written_json=$(jq -R -s 'split("\n") | map(select(length > 0))' "$written_file")
  if [[ "$(jq -r 'length' <<< "$blockers_json")" -eq 0 && "$(jq -r 'length' <<< "$apply_blockers_json")" -eq 0 ]]; then
    safe_to_apply=true
  else
    safe_to_apply=false
  fi

  if [[ "$FORMAT" == "json" ]]; then
    jq -n \
      --arg status "$status" \
      --arg mode "$mode" \
      --arg intent "$intent" \
      --arg requested_archetype "$requested_archetype" \
      --arg selected_archetype "$selected_archetype" \
      --arg selection_reason "$selection_reason" \
      --arg target_dir "$target_dir" \
      --arg repo_mode "$repo_mode" \
      --arg readiness_report "$readiness_report" \
      --arg readiness_status "$readiness_status" \
      --arg contract_command "$contract_command" \
      --argjson safe_to_apply "$safe_to_apply" \
      --argjson assumptions "$assumptions_json" \
      --argjson decisions_required "$decisions_json" \
      --argjson blockers "$blockers_json" \
      --argjson apply_blockers "$apply_blockers_json" \
      --argjson files "$files_json" \
      --argjson written_files "$written_json" \
      '{
        status:$status,
        mode:$mode,
        product_intent:$intent,
        requested_archetype:$requested_archetype,
        selected_archetype:$selected_archetype,
        selection_reason:$selection_reason,
        target_dir:(if $target_dir == "" then null else $target_dir end),
        repository_contract:{
          mode:(if $repo_mode == "" then null else $repo_mode end),
          required_command:$contract_command,
          readiness_report:(if $readiness_report == "" then null else $readiness_report end),
          readiness_status:(if $readiness_status == "" then null else $readiness_status end)
        },
        safe_to_apply:$safe_to_apply,
        assumptions:$assumptions,
        decisions_required:$decisions_required,
        blockers:$blockers,
        apply_blockers:$apply_blockers,
        files:$files,
        written_files:$written_files
      }'
    return 0
  fi

  printf 'status\t%s\n' "$status"
  printf 'mode\t%s\n' "$mode"
  printf 'selected_archetype\t%s\n' "$selected_archetype"
  printf 'selection_reason\t%s\n' "$selection_reason"
  printf 'target_dir\t%s\n' "${target_dir:-missing}"
  printf 'repository_contract\t%s\t%s\n' "${repo_mode:-missing}" "$contract_command"
  jq -r '.[] | "assumption\t" + .' <<< "$assumptions_json"
  jq -r '.[] | "decision_required\t" + .' <<< "$decisions_json"
  jq -r '.[] | "blocker\t" + .' <<< "$blockers_json"
  jq -r '.[] | "apply_blocker\t" + .' <<< "$apply_blockers_json"
  jq -r '.[] | "file\t\(.path)\t\(.action)\t\(.purpose)"' <<< "$files_json"
  jq -r '.[] | "written\t" + .' <<< "$written_json"
}

hard_blocker_count=$(jq -R -s 'split("\n") | map(select(length > 0)) | unique | length' "$blockers_file")
apply_blocker_count=$(jq -R -s 'split("\n") | map(select(length > 0)) | unique | length' "$apply_blockers_file")

if [[ "$mode" != "apply" ]]; then
  if [[ "$hard_blocker_count" -gt 0 ]]; then
    emit_report "blocked"
  else
    emit_report "$mode"
  fi
  exit 0
fi

if [[ "$hard_blocker_count" -gt 0 || "$apply_blocker_count" -gt 0 ]]; then
  emit_report "blocked"
  exit "${PROJECT_SCAFFOLD_REFUSAL_EXIT_CODE:-78}"
fi

mkdir -p "$target_dir"
while IFS= read -r file_row; do
  rel=$(jq -r '.path' <<< "$file_row")
  executable=$(jq -r '.executable' <<< "$file_row")
  dest="$target_dir/$rel"
  if [[ -e "$dest" && "$OVERWRITE" -ne 1 ]]; then
    add_line "$apply_blockers_file" "scaffold_file_exists:$rel"
    emit_report "blocked"
    exit "${PROJECT_SCAFFOLD_REFUSAL_EXIT_CODE:-78}"
  fi
  mkdir -p "$(dirname "$dest")"
  emit_scaffold_file "$rel" > "$dest"
  if [[ "$executable" == "true" ]]; then
    chmod +x "$dest"
  fi
  add_line "$written_file" "$rel"
done < "$files_file"

emit_report "ready"
