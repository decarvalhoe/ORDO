#!/usr/bin/env bash
# scripts/docs_generate.sh - reusable documentation pack generator for
# downstream projects. Produces developer, user, operator, integration,
# validation, and maintenance docs from project metadata, repo structure,
# existing docs signals, and operator-supplied context. Optional GxP-grade
# and Six Sigma layers are appended only when explicitly requested through
# flags or project profile metadata and never leak into normal-dev output.
set -euo pipefail

TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=../lib/config_resolver.sh
source "$TK/lib/config_resolver.sh"
# shellcheck source=../lib/dry_run.sh
source "$TK/lib/dry_run.sh"
# shellcheck source=../lib/docs_generate.sh
source "$TK/lib/docs_generate.sh"

usage() {
  cat <<'EOF' >&2
usage:
  docs_generate.sh <project|config> --target-dir <dir>
    [--intent <text>]
    [--operator-context-file <path>]
    [--output-dir <dir>]
    [--gxp-grade]
    [--sixsigma]
    [--apply]
    [--overwrite]
    [--dry-run]
    [--json|--tsv]

Generates a documentation pack for a downstream project. By default the
command previews what it would write. --apply writes files. --dry-run or
ORCH_DRY_RUN=1 keeps the command non-mutating even when --apply is supplied.

Defaults are safe for normal-dev work. The GxP-grade and Six Sigma layers
are emitted only when --gxp-grade, --sixsigma, or supported project validation
metadata explicitly selects them.
EOF
}

require_jq() {
  command -v jq >/dev/null 2>&1 || {
    printf 'docs_generate: jq is required\n' >&2
    exit 2
  }
}

docs_generate_enable_gxp_grade() {
  local source=${1:?usage: docs_generate_enable_gxp_grade <source>}
  local existing
  GXP_GRADE=1
  for existing in "${GXP_GRADE_SOURCES[@]}"; do
    [[ "$existing" == "$source" ]] && return 0
  done
  GXP_GRADE_SOURCES+=("$source")
}

docs_generate_normalize_validation_grade() {
  local raw=${1:-}
  local normalized
  normalized=${raw,,}
  normalized=${normalized//-/_}
  normalized=${normalized// /_}
  printf '%s\n' "$normalized"
}

docs_generate_apply_gxp_profile_metadata() {
  local key value normalized
  for key in PROJECT_VALIDATION_GRADE ORDO_ONBOARDING_VALIDATION_MODE; do
    value=${!key-}
    [[ -n "$value" ]] || continue
    normalized=$(docs_generate_normalize_validation_grade "$value")
    case "$normalized" in
      gxp|gxp_grade)
        docs_generate_enable_gxp_grade "$key=$value"
        ;;
    esac
  done
}

docs_generate_gxp_grade_sources_json() {
  if [[ "${#GXP_GRADE_SOURCES[@]}" -eq 0 ]]; then
    printf '[]\n'
    return 0
  fi
  printf '%s\n' "${GXP_GRADE_SOURCES[@]}" \
    | jq -R -s 'split("\n") | map(select(length > 0)) | unique'
}

add_line() {
  local file=$1 value=$2
  printf '%s\n' "$value" >> "$file"
}

CFG_ARG=${1:-}
[[ -n "$CFG_ARG" ]] || {
  usage
  exit 2
}
shift

ARGS=()
while [[ "$#" -gt 0 ]]; do
  ARGS+=("$1")
  shift
done

dry_run_parse_args "${ARGS[@]}"
set -- "${DRY_RUN_ARGS[@]}"

require_jq
load_project_config "$CFG_ARG"

FORMAT="json"
APPLY=0
OVERWRITE=0
GXP_GRADE=0
SIXSIGMA=0
GXP_GRADE_SOURCES=()
intent=${DOCS_GENERATE_INTENT:-}
operator_context_file=${DOCS_GENERATE_OPERATOR_CONTEXT_FILE:-}
target_dir=${DOCS_GENERATE_TARGET_DIR:-}
output_dir=${DOCS_GENERATE_OUTPUT_DIR:-}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --intent) intent=${2:?missing value for --intent}; shift 2 ;;
    --operator-context-file) operator_context_file=${2:?missing value for --operator-context-file}; shift 2 ;;
    --target-dir) target_dir=${2:?missing value for --target-dir}; shift 2 ;;
    --output-dir) output_dir=${2:?missing value for --output-dir}; shift 2 ;;
    --gxp-grade) docs_generate_enable_gxp_grade "cli:--gxp-grade"; shift ;;
    --sixsigma) SIXSIGMA=1; shift ;;
    --apply) APPLY=1; shift ;;
    --overwrite) OVERWRITE=1; shift ;;
    --json) FORMAT="json"; shift ;;
    --tsv) FORMAT="tsv"; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      printf 'docs_generate: unknown arg: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

docs_generate_apply_gxp_profile_metadata

blockers_file=$(mktemp)
apply_blockers_file=$(mktemp)
written_file=$(mktemp)
gaps_file=$(mktemp)
# shellcheck disable=SC2317
cleanup() {
  rm -f "$blockers_file" "$apply_blockers_file" "$written_file" "$gaps_file"
}
trap cleanup EXIT

if [[ -z "$target_dir" ]]; then
  add_line "$blockers_file" "target_dir_missing"
fi
if [[ -n "$target_dir" && -e "$target_dir" && ! -d "$target_dir" ]]; then
  add_line "$blockers_file" "target_not_directory"
fi
if [[ -n "$operator_context_file" && ! -f "$operator_context_file" ]]; then
  add_line "$blockers_file" "operator_context_file_not_found"
fi

resolved_output_dir=""
if [[ -n "$target_dir" ]]; then
  if [[ -n "$output_dir" ]]; then
    resolved_output_dir="$output_dir"
  else
    resolved_output_dir="$target_dir/docs/generated"
  fi
fi

if [[ -n "$resolved_output_dir" && -d "$resolved_output_dir" ]]; then
  if [[ "$OVERWRITE" -ne 1 ]] && find "$resolved_output_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -q .; then
    add_line "$apply_blockers_file" "output_dir_not_empty"
  fi
fi

operator_context_text=""
if [[ -n "$operator_context_file" && -f "$operator_context_file" ]]; then
  operator_context_text=$(cat "$operator_context_file")
fi

generated_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
repo_metadata_signature=""
if [[ -n "$target_dir" && -d "$target_dir" ]]; then
  repo_metadata_signature=$(docs_generate_repo_metadata_signature "$target_dir")
fi

layers_markdown=$(docs_generate_layers_markdown "$GXP_GRADE" "$SIXSIGMA")

# Compute follow-up gaps before deciding to apply so the report surfaces them.
docs_generate_follow_up_gaps "$intent" "$operator_context_file" "$target_dir" \
  > "$gaps_file"

files_json=$(docs_generate_files_json "$GXP_GRADE" "$SIXSIGMA")

if [[ "$(jq 'length' <<< "$files_json")" -eq 0 ]]; then
  add_line "$blockers_file" "no_templates_found"
fi

mode="plan"
if [[ "$APPLY" -eq 1 ]]; then
  if dry_run_enabled; then
    mode="dry-run"
  else
    mode="apply"
  fi
fi

emit_files_json_with_status() {
  local status_filter=$1
  jq --arg status "$status_filter" \
    'map(. + {status:$status})' <<< "$files_json"
}

emit_report() {
  local status=$1 gxp_sources_json
  local blockers_json apply_blockers_json gaps_json written_json safe_to_apply
  blockers_json=$(jq -R -s 'split("\n") | map(select(length > 0)) | unique' "$blockers_file")
  apply_blockers_json=$(jq -R -s 'split("\n") | map(select(length > 0)) | unique' "$apply_blockers_file")
  gaps_json=$(jq -R -s 'split("\n") | map(select(length > 0)) | unique' "$gaps_file")
  written_json=$(jq -R -s 'split("\n") | map(select(length > 0))' "$written_file")
  gxp_sources_json=$(docs_generate_gxp_grade_sources_json)
  if [[ "$(jq -r 'length' <<< "$blockers_json")" -eq 0 && "$(jq -r 'length' <<< "$apply_blockers_json")" -eq 0 ]]; then
    safe_to_apply=true
  else
    safe_to_apply=false
  fi

  local layers_array
  layers_array=$(docs_generate_resolve_layers "$GXP_GRADE" "$SIXSIGMA" \
    | jq -R -s 'split("\n") | map(select(length > 0))')

  local files_report
  files_report=$(jq 'map({path:.path,layer:.layer})' <<< "$files_json")

  if [[ "$FORMAT" == "json" ]]; then
    jq -n \
      --arg status "$status" \
      --arg mode "$mode" \
      --arg project_name "${PROJECT:-}" \
      --arg intent "$intent" \
      --arg target_dir "$target_dir" \
      --arg output_dir "$resolved_output_dir" \
      --arg operator_context_file "$operator_context_file" \
      --arg generated_at "$generated_at" \
      --arg repo_metadata_signature "$repo_metadata_signature" \
      --argjson gxp_grade "$GXP_GRADE" \
      --argjson sixsigma "$SIXSIGMA" \
      --argjson safe_to_apply "$safe_to_apply" \
      --argjson layers_selected "$layers_array" \
      --argjson gxp_grade_sources "$gxp_sources_json" \
      --argjson files "$files_report" \
      --argjson written_files "$written_json" \
      --argjson blockers "$blockers_json" \
      --argjson apply_blockers "$apply_blockers_json" \
      --argjson follow_up_gaps "$gaps_json" \
      '{
        status:$status,
        mode:$mode,
        project_name:(if $project_name == "" then null else $project_name end),
        product_intent:(if $intent == "" then null else $intent end),
        target_dir:(if $target_dir == "" then null else $target_dir end),
        output_dir:(if $output_dir == "" then null else $output_dir end),
        operator_context_file:(if $operator_context_file == "" then null else $operator_context_file end),
        generated_at:$generated_at,
        repo_metadata_signature:(if $repo_metadata_signature == "" then null else $repo_metadata_signature end),
        layers:{
          gxp_grade:($gxp_grade==1),
          sixsigma:($sixsigma==1),
          gxp_grade_sources:$gxp_grade_sources,
          selected:$layers_selected
        },
        defaults_safe:($gxp_grade==0 and $sixsigma==0),
        safe_to_apply:$safe_to_apply,
        files:$files,
        written_files:$written_files,
        blockers:$blockers,
        apply_blockers:$apply_blockers,
        follow_up_gaps:$follow_up_gaps
      }'
    return 0
  fi

  printf 'status\t%s\n' "$status"
  printf 'mode\t%s\n' "$mode"
  printf 'project_name\t%s\n' "${PROJECT:-}"
  printf 'product_intent\t%s\n' "${intent:-}"
  printf 'target_dir\t%s\n' "${target_dir:-missing}"
  printf 'output_dir\t%s\n' "${resolved_output_dir:-missing}"
  printf 'operator_context_file\t%s\n' "${operator_context_file:-not-supplied}"
  printf 'gxp_grade\t%s\n' "$GXP_GRADE"
  printf 'sixsigma\t%s\n' "$SIXSIGMA"
  printf 'safe_to_apply\t%s\n' "$safe_to_apply"
  jq -r '.[] | "gxp_grade_source\t" + .' <<< "$gxp_sources_json"
  jq -r '.[] | "layer\t" + .' <<< "$layers_array"
  jq -r '.[] | "file\t\(.layer)\t\(.path)"' <<< "$files_report"
  jq -r '.[] | "written\t" + .' <<< "$written_json"
  jq -r '.[] | "blocker\t" + .' <<< "$blockers_json"
  jq -r '.[] | "apply_blocker\t" + .' <<< "$apply_blockers_json"
  jq -r '.[] | "follow_up_gap\t" + .' <<< "$gaps_json"
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
  exit "${DOCS_GENERATE_REFUSAL_EXIT_CODE:-78}"
fi

mkdir -p "$resolved_output_dir"
layers_list_md=$layers_markdown

while IFS= read -r row; do
  rel=$(jq -r '.path' <<< "$row")
  src=$(jq -r '.source' <<< "$row")
  layer=$(jq -r '.layer' <<< "$row")
  dest="$resolved_output_dir/$rel"
  if [[ -e "$dest" && "$OVERWRITE" -ne 1 ]]; then
    add_line "$apply_blockers_file" "generated_file_exists:$rel"
    emit_report "blocked"
    exit "${DOCS_GENERATE_REFUSAL_EXIT_CODE:-78}"
  fi
  mkdir -p "$(dirname "$dest")"
  DG_PROJECT_NAME=${PROJECT:-} \
  DG_PROJECT_INTENT=${intent:-} \
  DG_TARGET_DIR=${target_dir:-} \
  DG_GENERATED_AT="$generated_at" \
  DG_OUTPUT_DIR="$resolved_output_dir" \
  DG_LAYERS_LIST="$layers_list_md" \
  DG_GXP_ENABLED="$GXP_GRADE" \
  DG_SIXSIGMA_ENABLED="$SIXSIGMA" \
  DG_OPERATOR_CONTEXT="$operator_context_text" \
  DG_REPO_METADATA_SIGNATURE="$repo_metadata_signature" \
    docs_generate_render_template "$src" "$dest"
  add_line "$written_file" "$rel"
  unused=$layer
  : "$unused"
done < <(jq -c '.[]' <<< "$files_json")

manifest_path="$resolved_output_dir/generated.manifest.json"
manifest_files=$(jq 'map({path:.path, layer:.layer})' <<< "$files_json")
manifest_layers=$(docs_generate_resolve_layers "$GXP_GRADE" "$SIXSIGMA" \
  | jq -R -s 'split("\n") | map(select(length > 0))')
manifest_gaps=$(jq -R -s 'split("\n") | map(select(length > 0)) | unique' "$gaps_file")
manifest_gxp_sources=$(docs_generate_gxp_grade_sources_json)
jq -n \
  --arg generated_at "$generated_at" \
  --arg project_name "${PROJECT:-}" \
  --arg intent "$intent" \
  --arg target_dir "$target_dir" \
  --arg output_dir "$resolved_output_dir" \
  --arg operator_context_file "$operator_context_file" \
  --arg repo_metadata_signature "$repo_metadata_signature" \
  --argjson gxp_grade "$GXP_GRADE" \
  --argjson sixsigma "$SIXSIGMA" \
  --argjson layers "$manifest_layers" \
  --argjson gxp_grade_sources "$manifest_gxp_sources" \
  --argjson files "$manifest_files" \
  --argjson follow_up_gaps "$manifest_gaps" \
  '{
    generated_at:$generated_at,
    inputs:{
      project_name:(if $project_name == "" then null else $project_name end),
      product_intent:(if $intent == "" then null else $intent end),
      target_dir:$target_dir,
      output_dir:$output_dir,
      operator_context_file:(if $operator_context_file == "" then null else $operator_context_file end),
      repo_metadata_signature:$repo_metadata_signature
    },
    layers:{
      gxp_grade:($gxp_grade==1),
      sixsigma:($sixsigma==1),
      gxp_grade_sources:$gxp_grade_sources,
      selected:$layers
    },
    files:$files,
    follow_up_gaps:$follow_up_gaps,
    defaults_safe:($gxp_grade==0 and $sixsigma==0)
  }' > "$manifest_path"
add_line "$written_file" "generated.manifest.json"

emit_report "ready"
