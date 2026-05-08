#!/usr/bin/env bash
# scripts/repository_bootstrap.sh - plan/apply greenfield repository bootstrap.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/config_resolver.sh"
source "$TK/lib/dry_run.sh"
source "$TK/lib/process_safety.sh"
source "$TK/lib/repository_platform.sh"

usage() {
  cat <<'EOF' >&2
usage:
  repository_bootstrap.sh <project|config> [--json|--tsv] [--apply] [--dry-run]

Plans repository bootstrap by default. Mutating steps such as repository create,
local git init, remote configuration, and baseline config writes require
--apply and are still disabled when --dry-run or ORCH_DRY_RUN=1 is set.
EOF
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    printf 'repository_bootstrap: jq is required\n' >&2
    exit 2
  fi
}

shell_quote() {
  printf '%q' "$1"
}

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON)
      return 0
      ;;
  esac
  return 1
}

valid_visibility() {
  case "${1:-}" in
    private|internal|public)
      return 0
      ;;
  esac
  return 1
}

valid_ref_name() {
  local ref=${1:-}
  [[ -n "$ref" ]] || return 1
  git check-ref-format --branch "$ref" >/dev/null 2>&1
}

dir_is_empty() {
  local dir=${1:?usage: dir_is_empty <dir>}
  [[ -z "$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]
}

git_current_branch() {
  local repo_dir=${1:?usage: git_current_branch <repo-dir>}
  git -C "$repo_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true
}

git_dirty() {
  local repo_dir=${1:?usage: git_dirty <repo-dir>}
  [[ -n "$(git -C "$repo_dir" status --porcelain 2>/dev/null)" ]]
}

git_remote_url() {
  local repo_dir=${1:?usage: git_remote_url <repo-dir> <remote-name>}
  local remote=${2:?usage: git_remote_url <repo-dir> <remote-name>}
  git -C "$repo_dir" remote get-url "$remote" 2>/dev/null || true
}

baseline_config_text() {
  printf 'PROJECT=%s\n' "$(shell_quote "${PROJECT:-repository-bootstrap}")"
  printf 'DEFAULT_BRANCH=%s\n' "$(shell_quote "$default_branch")"
  printf 'REPOSITORY_PLATFORM_REPOSITORY=%s\n' "$(shell_quote "$repo")"
  printf 'REPOSITORY_BOOTSTRAP_WORKDIR=%s\n' "$(shell_quote "$workdir")"
  printf 'PROJECT_REPO_ROOT=%s\n' "$(shell_quote "$workdir")"
  printf 'SUPERVISOR_REPO=%s\n' "$(shell_quote "$workdir")"
  printf 'REPOSITORY_BOOTSTRAP_REMOTE_NAME=%s\n' "$(shell_quote "$remote_name")"
  if [[ -n "$remote_url" ]]; then
    printf 'REPOSITORY_BOOTSTRAP_REMOTE_URL=%s\n' "$(shell_quote "$remote_url")"
  fi
}

CFG_ARG=${1:-}
[[ -n "$CFG_ARG" ]] || {
  usage
  exit 2
}
shift

FORMAT="json"
APPLY=0
ARGS=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --json)
      FORMAT="json"
      ARGS+=("$1")
      shift
      ;;
    --tsv)
      FORMAT="tsv"
      ARGS+=("$1")
      shift
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    --dry-run)
      ARGS+=("$1")
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'repository_bootstrap: unknown arg: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

dry_run_parse_args "${ARGS[@]}"
require_jq
load_project_config "$CFG_ARG"

: "${REPOSITORY_BOOTSTRAP_REFUSAL_EXIT_CODE:=78}"
: "${REPOSITORY_BOOTSTRAP_CREATE_REPOSITORY:=1}"
: "${REPOSITORY_BOOTSTRAP_VERIFY_READINESS:=1}"

repo=${REPOSITORY_BOOTSTRAP_REPOSITORY:-$(repository_platform_repo_identifier)}
workdir=${REPOSITORY_BOOTSTRAP_WORKDIR:-${PROJECT_REPO_ROOT:-${SUPERVISOR_REPO:-}}}
default_branch=${REPOSITORY_BOOTSTRAP_DEFAULT_BRANCH:-${DEFAULT_BRANCH:-main}}
visibility=${REPOSITORY_BOOTSTRAP_VISIBILITY:-private}
remote_name=${REPOSITORY_BOOTSTRAP_REMOTE_NAME:-origin}
remote_url=${REPOSITORY_BOOTSTRAP_REMOTE_URL:-${REPOSITORY_REMOTE_URL:-}}
baseline_output=${REPOSITORY_BOOTSTRAP_CONFIG_OUTPUT:-}

mode="plan"
if [[ "$APPLY" -eq 1 ]]; then
  if dry_run_enabled; then
    mode="dry-run"
  else
    mode="apply"
  fi
fi

actions_file=$(mktemp)
applied_file=$(mktemp)
blockers_file=$(mktemp)
metadata_file=$(mktemp)
readiness_file=$(mktemp)
# shellcheck disable=SC2317 # invoked by EXIT trap.
cleanup() {
  rm -f "$actions_file" "$applied_file" "$blockers_file" "$metadata_file" "$readiness_file"
}
trap cleanup EXIT

add_action() {
  local name=${1:?usage: add_action <name> <mutating> <detail>}
  local mutating=${2:?usage: add_action <name> <mutating> <detail>}
  local detail=${3:-}
  jq -nc --arg name "$name" --argjson mutating "$mutating" --arg detail "$detail" \
    '{name:$name,mutating:$mutating,detail:$detail}' >> "$actions_file"
}

add_applied() {
  local name=${1:?usage: add_applied <name> <status> <detail>}
  local applied_status=${2:?usage: add_applied <name> <status> <detail>}
  local detail=${3:-}
  jq -nc --arg name "$name" --arg status "$applied_status" --arg detail "$detail" \
    '{name:$name,status:$status,detail:$detail}' >> "$applied_file"
}

add_blocker() {
  local blocker=${1:?usage: add_blocker <blocker>}
  printf '%s\n' "$blocker" >> "$blockers_file"
}

emit_report() {
  local status=$1
  local baseline actions_json applied_json blockers_json readiness_json safe_to_apply
  local apply_requested_json dry_run_json
  baseline=$(baseline_config_text)
  actions_json=$(jq -s '.' "$actions_file")
  applied_json=$(jq -s '.' "$applied_file")
  blockers_json=$(jq -R -s 'split("\n") | map(select(length > 0)) | unique' "$blockers_file")
  readiness_json="null"
  if [[ -s "$readiness_file" ]]; then
    readiness_json=$(cat "$readiness_file")
  fi
  if [[ "$(jq -r 'length' <<< "$blockers_json")" -eq 0 ]]; then
    safe_to_apply=true
  else
    safe_to_apply=false
  fi
  if [[ "$APPLY" -eq 1 ]]; then
    apply_requested_json=true
  else
    apply_requested_json=false
  fi
  if dry_run_enabled; then
    dry_run_json=true
  else
    dry_run_json=false
  fi

  if [[ "$FORMAT" == "json" ]]; then
    jq -n \
      --arg status "$status" \
      --arg mode "$mode" \
      --arg repository_case "$repository_case" \
      --arg repository "$repo" \
      --arg workdir "$workdir" \
      --arg default_branch "$default_branch" \
      --arg visibility "$visibility" \
      --arg remote_name "$remote_name" \
      --arg remote_url "$remote_url" \
      --arg baseline_config "$baseline" \
      --argjson apply_requested "$apply_requested_json" \
      --argjson dry_run "$dry_run_json" \
      --argjson safe_to_apply "$safe_to_apply" \
      --argjson actions "$actions_json" \
      --argjson applied "$applied_json" \
      --argjson blockers "$blockers_json" \
      --argjson readiness "$readiness_json" \
      '{
        status:$status,
        mode:$mode,
        repository_case:$repository_case,
        repository:(if $repository == "" then null else $repository end),
        workdir:(if $workdir == "" then null else $workdir end),
        default_branch:$default_branch,
        visibility:$visibility,
        remote_name:$remote_name,
        remote_url:(if $remote_url == "" then null else $remote_url end),
        apply_requested:$apply_requested,
        dry_run:$dry_run,
        safe_to_apply:$safe_to_apply,
        actions:$actions,
        applied:$applied,
        blockers:$blockers,
        readiness:$readiness,
        baseline_config:$baseline_config
      }'
    return 0
  fi

  printf 'status\t%s\n' "$status"
  printf 'mode\t%s\n' "$mode"
  printf 'repository_case\t%s\n' "$repository_case"
  printf 'repository\t%s\n' "${repo:-missing}"
  printf 'workdir\t%s\n' "${workdir:-missing}"
  jq -r '.[] | "action\t\(.name)\t\(.mutating)\t\(.detail)"' <<< "$actions_json"
  jq -r '.[] | "applied\t\(.name)\t\(.status)\t\(.detail)"' <<< "$applied_json"
  jq -r '.[] | "blocker\t" + .' <<< "$blockers_json"
}

adapter_available=0
if repository_platform_cli_bin >/dev/null 2>&1; then
  adapter_available=1
fi

repository_case="unverified"
metadata_error=""
metadata_permission=""
if [[ -n "$repo" && "$adapter_available" -eq 1 ]]; then
  if metadata=$(repository_platform_repo_metadata "$repo" 2>"$metadata_file"); then
    if [[ -n "$metadata" ]] && jq -e 'has("exists") and (.exists == false)' <<< "$metadata" >/dev/null 2>&1; then
      repository_case="new"
    else
      repository_case="existing"
      metadata_permission=$(jq -r '.permission // ""' <<< "$metadata" 2>/dev/null || true)
      metadata_remote=$(jq -r '.remote_url // .clone_url // .repository_url // ""' <<< "$metadata" 2>/dev/null || true)
      [[ -n "$remote_url" || -z "$metadata_remote" ]] || remote_url=$metadata_remote
      metadata_default_branch=$(jq -r '.default_branch // ""' <<< "$metadata" 2>/dev/null || true)
      [[ -n "${REPOSITORY_BOOTSTRAP_DEFAULT_BRANCH:-${DEFAULT_BRANCH:-}}" || -z "$metadata_default_branch" ]] || default_branch=$metadata_default_branch
    fi
  else
    metadata_error=$(tr '\n' ' ' < "$metadata_file" | cut -c1-160)
    repository_case="unverified"
  fi
fi

if [[ -z "$repo" ]]; then
  add_blocker "repository_identifier_missing"
fi
if [[ -z "$workdir" ]]; then
  add_blocker "workdir_missing"
fi
if [[ -z "$default_branch" ]] || ! valid_ref_name "$default_branch"; then
  add_blocker "default_branch_invalid"
fi
if ! valid_visibility "$visibility"; then
  add_blocker "visibility_invalid"
fi
if [[ "$adapter_available" -eq 0 && "${REPOSITORY_BOOTSTRAP_PLATFORM_REQUIRED:-1}" != "0" ]]; then
  add_blocker "repository_platform_adapter_missing"
fi
if [[ "$repository_case" == "unverified" && "$adapter_available" -eq 1 ]]; then
  add_blocker "repository_discovery_failed"
fi
if [[ "$repository_case" == "new" ]] && ! is_truthy "$REPOSITORY_BOOTSTRAP_CREATE_REPOSITORY"; then
  add_blocker "repository_missing_create_disabled"
fi
if [[ "$repository_case" == "existing" && -n "$metadata_permission" ]] \
  && ! repository_platform_permission_allows_write "$metadata_permission"; then
  add_blocker "repository_write_permission_missing"
fi

workdir_exists=0
workdir_git=0
existing_remote_url=""
if [[ -n "$workdir" ]]; then
  if [[ -e "$workdir" && ! -d "$workdir" ]]; then
    add_blocker "workdir_not_directory"
  elif [[ -d "$workdir" ]]; then
    workdir_exists=1
    if [[ -d "$workdir/.git" ]] || git -C "$workdir" rev-parse --git-dir >/dev/null 2>&1; then
      workdir_git=1
      current_branch=$(git_current_branch "$workdir")
      if [[ -n "$current_branch" && "$current_branch" != "$default_branch" ]]; then
        add_blocker "default_branch_mismatch"
      fi
      if git_dirty "$workdir"; then
        add_blocker "workdir_dirty"
      fi
      existing_remote_url=$(git_remote_url "$workdir" "$remote_name")
      [[ -n "$remote_url" || -z "$existing_remote_url" ]] || remote_url=$existing_remote_url
      if [[ -n "$remote_url" && -n "$existing_remote_url" && "$existing_remote_url" != "$remote_url" ]]; then
        add_blocker "remote_url_mismatch"
      fi
    elif ! dir_is_empty "$workdir"; then
      add_blocker "workdir_not_empty"
    fi
  fi
fi

if [[ -n "$baseline_output" && -e "$baseline_output" && "${REPOSITORY_BOOTSTRAP_OVERWRITE_CONFIG:-0}" != "1" ]]; then
  add_blocker "baseline_config_exists"
fi
if [[ "$repository_case" == "existing" && -z "$remote_url" ]]; then
  add_blocker "remote_url_missing"
fi
if [[ "$repository_case" == "unverified" && "${REPOSITORY_BOOTSTRAP_PLATFORM_REQUIRED:-1}" == "0" && -z "$remote_url" ]]; then
  add_blocker "remote_url_missing"
fi

add_action "validate_inputs" "false" "repository bootstrap inputs and local workdir safety"
if [[ "$repository_case" == "new" ]]; then
  add_action "create_repository" "true" "create target repository through the configured repository-platform adapter"
elif [[ "$repository_case" == "unverified" && -n "$metadata_error" ]]; then
  add_action "discover_repository" "false" "repository metadata unavailable: $metadata_error"
else
  add_action "discover_repository" "false" "use existing repository metadata when available"
fi
if [[ "$workdir_exists" -eq 0 ]]; then
  add_action "create_workdir" "true" "create missing local workdir"
fi
if [[ "$workdir_git" -eq 0 ]]; then
  add_action "init_git" "true" "initialize local git repository on the default branch"
fi
add_action "configure_default_branch" "true" "align local and repository-platform default branch metadata"
add_action "configure_remote" "true" "attach the configured repository remote when available"
add_action "generate_baseline_config" "$([[ -n "$baseline_output" ]] && printf true || printf false)" "emit universal baseline repository config"
if is_truthy "$REPOSITORY_BOOTSTRAP_VERIFY_READINESS"; then
  add_action "verify_repository_readiness" "false" "run repository-platform readiness after apply"
fi

blocker_count=$(jq -R -s 'split("\n") | map(select(length > 0)) | unique | length' "$blockers_file")
if [[ "$mode" != "apply" ]]; then
  if [[ "$blocker_count" -eq 0 ]]; then
    emit_report "$mode"
  else
    emit_report "blocked"
  fi
  exit 0
fi

if [[ "$blocker_count" -gt 0 ]]; then
  emit_report "blocked"
  exit "$REPOSITORY_BOOTSTRAP_REFUSAL_EXIT_CODE"
fi

if [[ "$repository_case" == "new" ]]; then
  create_output=$(repository_platform_create_repository "$repo" "$visibility" "$default_branch") || {
    add_applied "create_repository" "failed" "repository-platform create refused"
    add_blocker "create_repository_failed"
    emit_report "blocked"
    exit "$REPOSITORY_BOOTSTRAP_REFUSAL_EXIT_CODE"
  }
  add_applied "create_repository" "applied" "repository-platform create completed"
  created_remote=$(jq -r '.remote_url // .clone_url // .repository_url // ""' <<< "$create_output" 2>/dev/null || true)
  [[ -n "$remote_url" || -z "$created_remote" ]] || remote_url=$created_remote
fi

if [[ "$workdir_exists" -eq 0 ]]; then
  mkdir -p "$workdir"
  add_applied "create_workdir" "applied" "created local workdir"
fi

if [[ "$workdir_git" -eq 0 ]]; then
  git init -q "$workdir"
  git -C "$workdir" symbolic-ref HEAD "refs/heads/$default_branch"
  add_applied "init_git" "applied" "initialized local git repository"
fi

if [[ "$adapter_available" -eq 1 ]]; then
  repository_platform_configure_default_branch "$repo" "$default_branch" >/dev/null || {
    add_applied "configure_default_branch" "failed" "repository-platform default branch update refused"
    add_blocker "default_branch_config_failed"
    emit_report "blocked"
    exit "$REPOSITORY_BOOTSTRAP_REFUSAL_EXIT_CODE"
  }
  add_applied "configure_default_branch" "applied" "repository-platform default branch configured"
else
  add_applied "configure_default_branch" "skipped" "repository-platform adapter not configured"
fi

if [[ -z "$remote_url" ]]; then
  add_applied "configure_remote" "failed" "remote URL unavailable"
  add_blocker "remote_url_missing"
  emit_report "blocked"
  exit "$REPOSITORY_BOOTSTRAP_REFUSAL_EXIT_CODE"
fi

current_remote_url=$(git_remote_url "$workdir" "$remote_name")
if [[ -z "$current_remote_url" ]]; then
  git -C "$workdir" remote add "$remote_name" "$remote_url"
  add_applied "configure_remote" "applied" "added local git remote"
elif [[ "$current_remote_url" == "$remote_url" ]]; then
  add_applied "configure_remote" "already_ready" "local git remote already matched"
else
  add_applied "configure_remote" "failed" "local git remote mismatch"
  add_blocker "remote_url_mismatch"
  emit_report "blocked"
  exit "$REPOSITORY_BOOTSTRAP_REFUSAL_EXIT_CODE"
fi

if [[ -n "$baseline_output" ]]; then
  mkdir -p "$(dirname "$baseline_output")"
  baseline_config_text > "$baseline_output"
  add_applied "generate_baseline_config" "applied" "wrote baseline config"
else
  add_applied "generate_baseline_config" "preview" "baseline config included in report"
fi

if is_truthy "$REPOSITORY_BOOTSTRAP_VERIFY_READINESS" && [[ "$adapter_available" -eq 1 ]]; then
  if readiness_output=$(bash "$TK/scripts/repository_platform_readiness.sh" "$CFG_ARG" --json 2>&1); then
    printf '%s\n' "$readiness_output" > "$readiness_file"
    add_applied "verify_repository_readiness" "passed" "repository-platform readiness passed"
  else
    jq -nc --arg output "$readiness_output" '{status:"blocked",raw:$output}' > "$readiness_file"
    add_applied "verify_repository_readiness" "failed" "repository-platform readiness refused"
    add_blocker "repository_platform_readiness_failed"
    emit_report "blocked"
    exit "$REPOSITORY_BOOTSTRAP_REFUSAL_EXIT_CODE"
  fi
elif is_truthy "$REPOSITORY_BOOTSTRAP_VERIFY_READINESS"; then
  add_applied "verify_repository_readiness" "skipped" "repository-platform adapter not configured"
fi

emit_report "ready"
