#!/usr/bin/env bash
# scripts/portfolio_session_start.sh - start-of-session portfolio clone readiness audit.
#
# Usage:
#   portfolio_session_start.sh <portfolio-config> [--tsv|--json] [--apply] [--yolo-priority] [--dry-run]
#
# The default mode is diagnostic: it fetches origin/default to detect drift,
# reports missing or unsafe clones, and suggests remediations. --apply only runs
# remediations that are safe and deterministic: clone a missing workdir, or
# fast-forward a clean default-branch clone that is behind origin/default.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/dry_run.sh"
source "$TK/lib/portfolio_config.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

PORTFOLIO_ARG=${1:?usage: portfolio_session_start.sh <portfolio-config> [--tsv|--json] [--apply] [--yolo-priority] [--dry-run]}
FORMAT="tsv"
APPLY=0
FETCH=1
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tsv)
      FORMAT="tsv"
      shift
      ;;
    --json)
      FORMAT="json"
      shift
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    --yolo-priority)
      PORTFOLIO_YOLO_PRIORITY=1
      shift
      ;;
    --no-fetch)
      FETCH=0
      shift
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

load_portfolio_config "$PORTFOLIO_ARG"
portfolio_require_priorities || exit 14
priority_mode=$(portfolio_priority_mode)

: "${PORTFOLIO_SESSION_GIT_TIMEOUT_SEC:=20}"

run_timeout() {
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

git_value() {
  local repo=$1
  shift
  run_timeout "$PORTFOLIO_SESSION_GIT_TIMEOUT_SEC" git -C "$repo" "$@" 2>/dev/null || true
}

git_quiet() {
  local repo=$1
  shift
  run_timeout "$PORTFOLIO_SESSION_GIT_TIMEOUT_SEC" git -C "$repo" "$@" >/dev/null 2>&1
}

dry_note() {
  if dry_run_enabled; then
    printf 'DRY-RUN: %s\n' "$*" >&2
  fi
}

redact_url() {
  local url=${1:-}
  printf '%s' "$url" | sed -E 's#(https?://)[^/@]+@#\1***@#'
}

shell_quote() {
  printf '%q' "$1"
}

clone_command() {
  local gh_repo=$1 gh_config_dir=$2 clone_url=$3 workdir=$4
  local safe_url
  safe_url=$(redact_url "$clone_url")
  if [[ -n "$gh_repo" && "$clone_url" == https://github.com/* && -n "$(command -v gh 2>/dev/null || true)" ]]; then
    if [[ -n "$gh_config_dir" ]]; then
      printf 'GH_CONFIG_DIR=%s gh repo clone %s %s' \
        "$(shell_quote "$gh_config_dir")" \
        "$(shell_quote "$gh_repo")" \
        "$(shell_quote "$workdir")"
    else
      printf 'gh repo clone %s %s' "$(shell_quote "$gh_repo")" "$(shell_quote "$workdir")"
    fi
  else
    printf 'git clone %s %s' "$(shell_quote "$safe_url")" "$(shell_quote "$workdir")"
  fi
}

pull_command() {
  local workdir=$1 default_branch=$2
  printf 'git -C %s pull --ff-only origin %s' \
    "$(shell_quote "$workdir")" \
    "$(shell_quote "$default_branch")"
}

portfolio_fleet_spec() {
  if [[ -n "${PORTFOLIO_FLEET_AGENTS+x}" && "${#PORTFOLIO_FLEET_AGENTS[@]}" -gt 0 ]]; then
    printf '%s\n' "${PORTFOLIO_FLEET_AGENTS[@]}"
  fi
}

project_inventory_json() {
  local alias=${1:?usage: project_inventory_json <alias> <config> <priority>}
  local cfg=${2:?usage: project_inventory_json <alias> <config> <priority>}
  local priority=${3:?usage: project_inventory_json <alias> <config> <priority>}
  local matrix_spec=${4:-}
  local ensure_matrix=${5:-0}
  bash -c '
    set -euo pipefail
    alias=$1
    cfg=$2
    tk=$3
    priority=$4
    priority_mode=$5
    matrix_spec=$6
    ensure_matrix=$7
    # shellcheck disable=SC1090
    source "$cfg"
    # shellcheck source=lib/agent_inventory.sh
    source "$tk/lib/agent_inventory.sh"
    default_branch=${DEFAULT_BRANCH:-main}
    gh_repo=${GH_REPO:-}
    gh_config_dir=${GH_CONFIG_DIR:-}
    clone_url=${GIT_REMOTE_URL:-${REPO_URL:-}}
    if [[ -z "$clone_url" && -n "$gh_repo" ]]; then
      clone_url="https://github.com/${gh_repo}.git"
    fi

    emit_entry() {
      local label=$1 pane=$2 workdir=$3 entry_source=$4
      [[ -n "$label$pane$workdir" ]] || return 0
      jq -nc \
        --arg alias "$alias" \
        --arg project "${PROJECT:-$alias}" \
        --arg label "$label" \
        --arg pane "$pane" \
        --arg workdir "$workdir" \
        --arg source "$entry_source" \
        --arg priority "$priority" \
        --arg priority_mode "$priority_mode" \
        --arg default_branch "$default_branch" \
        --arg gh_repo "$gh_repo" \
        --arg gh_config_dir "$gh_config_dir" \
        --arg clone_url "$clone_url" \
        --arg config "$cfg" \
        "{
          alias:\$alias,
          project:\$project,
          label:\$label,
          pane:\$pane,
          workdir:\$workdir,
          source:\$source,
          priority:(\$priority | tonumber),
          priority_mode:\$priority_mode,
          default_branch:\$default_branch,
          gh_repo:\$gh_repo,
          gh_config_dir:\$gh_config_dir,
          clone_url:\$clone_url,
          config:\$config
        }"
    }

    declare -A seen_labels=()
    declare -A seen_panes=()
    while IFS="|" read -r label pane workdir; do
      [[ -n "$label$pane$workdir" ]] || continue
      seen_labels["$label"]=1
      [[ -n "$pane" ]] && seen_panes["$pane"]=1
      emit_entry "$label" "$pane" "$workdir" "configured"
    done < <(agent_inventory_entries || true)

    if [[ "$ensure_matrix" == "1" && -n "$matrix_spec" ]]; then
      while IFS="|" read -r matrix_label matrix_pane extra; do
        [[ -n "$matrix_label$matrix_pane$extra" ]] || continue
        if [[ -n "$extra" ]]; then
          printf "PORTFOLIO_FLEET_AGENTS entry malformed (need label or label|pane): %s|%s|%s\n" \
            "$matrix_label" "$matrix_pane" "$extra" >&2
          exit 2
        fi
        [[ -n "$matrix_label" ]] || continue
        if [[ -n "${seen_labels[$matrix_label]:-}" ]]; then
          continue
        fi
        if [[ -n "$matrix_pane" && -n "${seen_panes[$matrix_pane]:-}" ]]; then
          continue
        fi
        if [[ -n "${AGENT_WORKDIR_TEMPLATE:-}" ]]; then
          # shellcheck disable=SC2059
          matrix_workdir=$(printf "$AGENT_WORKDIR_TEMPLATE" "$matrix_label")
        elif [[ -n "${AGENT_REPO_PREFIX:-}" ]]; then
          matrix_workdir="${AGENT_REPO_PREFIX}${matrix_label}"
        else
          matrix_workdir=""
        fi
        emit_entry "$matrix_label" "$matrix_pane" "$matrix_workdir" "portfolio_matrix"
      done <<< "$matrix_spec"
    fi
  ' _ "$alias" "$cfg" "$TK" "$priority" "$priority_mode" "$matrix_spec" "$ensure_matrix"
}

clone_missing_workdir() {
  local gh_repo=$1 gh_config_dir=$2 clone_url=$3 workdir=$4
  mkdir -p "$(dirname "$workdir")"
  if dry_run_enabled; then
    dry_note "$(clone_command "$gh_repo" "$gh_config_dir" "$clone_url" "$workdir")"
    return 0
  fi
  if [[ -n "$gh_repo" && "$clone_url" == https://github.com/* && -n "$(command -v gh 2>/dev/null || true)" ]]; then
    GH_CONFIG_DIR="$gh_config_dir" gh repo clone "$gh_repo" "$workdir" >/dev/null
  else
    git clone --quiet "$clone_url" "$workdir"
  fi
}

pull_default_ff() {
  local workdir=$1 default_branch=$2
  if dry_run_enabled; then
    dry_note "git -C $workdir pull --ff-only origin $default_branch"
    return 0
  fi
  run_timeout "$PORTFOLIO_SESSION_GIT_TIMEOUT_SEC" \
    git -C "$workdir" pull --ff-only origin "$default_branch" >/dev/null 2>&1
}

inspect_entry() {
  local entry=$1
  local alias project label pane workdir entry_source default_branch gh_repo gh_config_dir clone_url clone_url_output
  local priority priority_mode_entry
  local exists=0 git_repo=0 branch="" head="" dirty="" fetch_status="" ahead="" behind=""
  local remote_default=0 base_current="" status="" remediation="" applied="" ready=0
  local remediation_action="" remediation_command="" safe_apply=0
  local counts

  alias=$(printf '%s' "$entry" | jq -r '.alias')
  project=$(printf '%s' "$entry" | jq -r '.project')
  label=$(printf '%s' "$entry" | jq -r '.label')
  pane=$(printf '%s' "$entry" | jq -r '.pane')
  workdir=$(printf '%s' "$entry" | jq -r '.workdir')
  entry_source=$(printf '%s' "$entry" | jq -r '.source // "configured"')
  priority=$(printf '%s' "$entry" | jq -r '.priority')
  priority_mode_entry=$(printf '%s' "$entry" | jq -r '.priority_mode')
  default_branch=$(printf '%s' "$entry" | jq -r '.default_branch')
  gh_repo=$(printf '%s' "$entry" | jq -r '.gh_repo')
  gh_config_dir=$(printf '%s' "$entry" | jq -r '.gh_config_dir')
  clone_url=$(printf '%s' "$entry" | jq -r '.clone_url')
  clone_url_output=$(redact_url "$clone_url")

  if [[ -z "$workdir" ]]; then
    status="missing_workdir_template"
    remediation="Define AGENT_WORKDIR_TEMPLATE or AGENT_REPO_PREFIX for this project so ORDO can derive per-agent clones."
    remediation_action="configure-workdir-template"
  elif [[ ! -e "$workdir" ]]; then
    status="missing_clone"
    remediation_action="clone"
    if [[ -n "$clone_url" ]]; then
      remediation="Clone the repository into the configured workdir."
      remediation_command=$(clone_command "$gh_repo" "$gh_config_dir" "$clone_url" "$workdir")
      safe_apply=1
    else
      status="missing_clone_no_remote"
      remediation="Add GH_REPO, REPO_URL, or GIT_REMOTE_URL to the project config so ORDO can clone this workdir."
      remediation_action="configure-remote"
    fi

    if [[ "$APPLY" -eq 1 && -n "$clone_url" ]]; then
      if clone_missing_workdir "$gh_repo" "$gh_config_dir" "$clone_url" "$workdir"; then
        applied="clone"
      else
        status="clone_failed"
        remediation="Retry clone manually and verify repository access."
      fi
    fi
  fi

  if [[ -n "$workdir" && -e "$workdir" ]]; then
    exists=1
  fi
  if [[ -n "$workdir" && -d "$workdir/.git" ]]; then
    git_repo=1
  elif [[ -z "$status" ]]; then
    status="not_git_repo"
    remediation="Move or clean the path, then clone the expected repository there."
  fi

  if [[ "$git_repo" -eq 1 ]]; then
    branch=$(git_value "$workdir" branch --show-current)
    head=$(git_value "$workdir" rev-parse --short HEAD)
    dirty=$(git_value "$workdir" status --porcelain | wc -l | tr -d ' ')

    if [[ "$FETCH" -eq 1 ]]; then
      if git_quiet "$workdir" fetch origin "$default_branch"; then
        fetch_status="ok"
      else
        fetch_status="failed"
      fi
    else
      fetch_status="skipped"
    fi

    if git_quiet "$workdir" rev-parse --verify "origin/$default_branch"; then
      remote_default=1
      counts=$(git_value "$workdir" rev-list --left-right --count "HEAD...origin/$default_branch")
      ahead=${counts%%[[:space:]]*}
      behind=${counts##*[[:space:]]}
    fi

    if [[ "${dirty:-0}" != "0" ]]; then
      status="dirty_worktree"
      remediation="Review, commit, stash, or clean local changes before assigning work."
    elif [[ -z "$branch" ]]; then
      status="detached_head"
      remediation="Checkout the default branch or a tracked work branch explicitly."
    elif [[ "$branch" != "$default_branch" ]]; then
      if [[ "$remote_default" -eq 1 ]]; then
        if git_quiet "$workdir" merge-base --is-ancestor "origin/$default_branch" HEAD; then
          base_current=1
          status="local_work_branch"
          remediation="Ensure the branch has a PR or park it before switching products."
        else
          base_current=0
          status="branch_needs_rebase"
          remediation="Rebase the branch on origin/$default_branch before parking or dispatching."
        fi
      else
        status="missing_origin_default"
        remediation="Fetch or configure origin/$default_branch before assessing this clone."
      fi
    elif [[ "$remote_default" -ne 1 ]]; then
      status="missing_origin_default"
      remediation="Fetch or configure origin/$default_branch before assigning work."
    elif [[ "${ahead:-0}" != "0" && "${behind:-0}" != "0" ]]; then
      status="diverged_default"
      remediation="Reconcile local default branch with origin/$default_branch manually."
    elif [[ "${ahead:-0}" != "0" ]]; then
      status="ahead_default"
      remediation="Push or inspect local default-branch commits; do not overwrite them automatically."
    elif [[ "${behind:-0}" != "0" ]]; then
      status="behind_default"
      remediation="Fast-forward the clean default branch from origin/$default_branch."
      remediation_action="pull-ff-only"
      remediation_command=$(pull_command "$workdir" "$default_branch")
      safe_apply=1
    else
      status="ready"
      remediation=""
      ready=1
    fi

    if [[ "$APPLY" -eq 1 && "$status" == "behind_default" ]]; then
      if pull_default_ff "$workdir" "$default_branch"; then
        applied="${applied:+$applied,}pull-ff-only"
        head=$(git_value "$workdir" rev-parse --short HEAD)
        ahead=0
        behind=0
        status="ready"
        remediation=""
        ready=1
      else
        status="pull_failed"
        remediation="Run git pull --ff-only manually and inspect the failure."
      fi
    fi
  fi

  jq -nc \
    --arg alias "$alias" \
    --arg project "$project" \
    --arg label "$label" \
    --arg pane "$pane" \
    --arg workdir "$workdir" \
    --arg source "$entry_source" \
    --arg priority "$priority" \
    --arg priority_mode "$priority_mode_entry" \
    --arg default_branch "$default_branch" \
    --arg gh_repo "$gh_repo" \
    --arg clone_url "$clone_url_output" \
    --arg branch "$branch" \
    --arg head "$head" \
    --arg fetch_status "$fetch_status" \
    --arg ahead "$ahead" \
    --arg behind "$behind" \
    --arg dirty "$dirty" \
    --arg base_current "$base_current" \
    --arg status "$status" \
    --arg remediation "$remediation" \
    --arg remediation_action "$remediation_action" \
    --arg remediation_command "$remediation_command" \
    --arg applied "$applied" \
    --argjson exists "$exists" \
    --argjson git_repo "$git_repo" \
    --argjson remote_default "$remote_default" \
    --argjson ready "$ready" \
    --argjson safe_apply "$safe_apply" \
    '{
      alias:$alias,
      project:$project,
      label:$label,
      pane:$pane,
      workdir:$workdir,
      source:$source,
      priority:($priority | tonumber),
      priority_mode:$priority_mode,
      default_branch:$default_branch,
      gh_repo:$gh_repo,
      clone_url:$clone_url,
      exists:$exists,
      git_repo:$git_repo,
      branch:$branch,
      head:$head,
      fetch:$fetch_status,
      remote_default:$remote_default,
      ahead:(if $ahead == "" then null else ($ahead | tonumber) end),
      behind:(if $behind == "" then null else ($behind | tonumber) end),
      dirty:(if $dirty == "" then null else ($dirty | tonumber) end),
      base_current:(if $base_current == "" then null else ($base_current | tonumber) end),
      status:$status,
      ready:$ready,
      safe_apply:$safe_apply,
      remediation_action:(if $remediation_action == "" then null else $remediation_action end),
      remediation_command:(if $remediation_command == "" then null else $remediation_command end),
      remediation:$remediation,
      applied:(if $applied == "" then null else $applied end)
    }'
}

json_items=()
matrix_spec=$(portfolio_fleet_spec)
ensure_matrix="${PORTFOLIO_ENSURE_AGENT_MATRIX:-}"
if [[ -z "$ensure_matrix" ]]; then
  if [[ -n "$matrix_spec" ]]; then
    ensure_matrix=1
  else
    ensure_matrix=0
  fi
fi
while IFS='|' read -r alias cfg; do
  priority=$(portfolio_project_priority "$alias")
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    json_items+=("$(inspect_entry "$entry")")
  done < <(project_inventory_json "$alias" "$cfg" "$priority" "$matrix_spec" "$ensure_matrix")
done < <(portfolio_project_entries)

json_report=$(printf '%s\n' "${json_items[@]}" | jq -s 'sort_by(-.priority, .alias, .label)')

if ! dry_run_enabled; then
  state_dir=$(portfolio_state_dir)
  mkdir -p "$state_dir"
  printf '%s\n' "$json_report" > "$state_dir/session_start.json"
fi

if [[ "$FORMAT" == "json" ]]; then
  printf '%s\n' "$json_report"
else
  printf 'alias\tpriority\tproject\tlabel\tsource\tworkdir\tstatus\tready\tsafe_apply\tbranch\tahead\tbehind\tdirty\tfetch\tapplied\taction\tcommand\tremediation\n'
  printf '%s\n' "$json_report" | jq -r '.[] | [
    .alias,
    .priority,
    .project,
    .label,
    .source,
    .workdir,
    .status,
    .ready,
    .safe_apply,
    .branch,
    (.ahead // ""),
    (.behind // ""),
    (.dirty // ""),
    .fetch,
    (.applied // ""),
    (.remediation_action // ""),
    (.remediation_command // ""),
    .remediation
  ] | @tsv'
fi
