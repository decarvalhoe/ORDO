#!/usr/bin/env bash
# scripts/portfolio_session_start.sh - start-of-session portfolio clone readiness audit.
#
# Usage:
#   portfolio_session_start.sh <portfolio-config> [--tsv|--json] [--apply] [--yolo-priority] [--dry-run]
#
# The default mode is diagnostic: it fetches origin/default to detect drift,
# reports missing or unsafe clones, and suggests remediations. --apply only runs
# remediations that are safe and deterministic: clone a missing workdir,
# fast-forward a clean default-branch clone that is behind origin/default, or
# set a missing per-agent local git identity (user.name + user.email) when the
# project config provides AGENT_GIT_IDENTITY_NAME_TEMPLATE +
# AGENT_GIT_IDENTITY_EMAIL_TEMPLATE (printf %s = label) or an explicit
# AGENT_GIT_IDENTITIES=("label|name|email") per-label override. Without those
# templates a missing identity is reported but never auto-applied.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/dry_run.sh"
source "$TK/lib/portfolio_config.sh"
# shellcheck source=../lib/api_rate_limiter.sh
source "$TK/lib/api_rate_limiter.sh"
# Forge access goes through the provider adapter (#816): the clone URL of a
# missing workdir comes from ordo_provider repo_get; the clone itself is git.
# shellcheck source=../lib/ordo_provider_adapter.sh
source "$TK/lib/ordo_provider_adapter.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

PORTFOLIO_ARG=${1:?usage: portfolio_session_start.sh <portfolio-config> [--tsv|--json] [--apply] [--yolo-priority] [--dry-run] [--ensure-fresh [--auto-refresh-if-stale]]}
FORMAT="tsv"
APPLY=0
FETCH=1
ENSURE_FRESH=0
AUTO_REFRESH_IF_STALE=0
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
    --ensure-fresh)
      ENSURE_FRESH=1
      shift
      ;;
    --auto-refresh-if-stale)
      AUTO_REFRESH_IF_STALE=1
      shift
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

load_portfolio_config "$PORTFOLIO_ARG"

# Wave-startup gate (#267): when --ensure-fresh is set, evaluate report-level
# freshness before running the full session-start flow.
#
# Without --auto-refresh-if-stale: report status and either exit 0 (fresh) or
# refuse with the canonical `portfolio_preflight_required: ... status=<...>`
# pattern that the per-agent guard in dispatch_ticket.sh emits, plus the
# explicit remediation command. No mutation, no fetches.
#
# With --auto-refresh-if-stale: a fresh report is a no-op (exit 0). A stale or
# missing report falls through to the regular session-start refresh below,
# preserving its safety semantics (--apply, --dry-run, etc remain operator
# controlled).
if (( ENSURE_FRESH == 1 )); then
  freshness_status=$(portfolio_preflight_report_freshness_status 2>/dev/null || true)
  freshness_age=$(portfolio_preflight_report_age_sec 2>/dev/null || true)
  freshness_report=$(portfolio_preflight_report_path)
  freshness_max_age=$(portfolio_preflight_max_age_sec)
  case "$freshness_status" in
    ok)
      printf 'portfolio_preflight_fresh: status=ok report=%s age_sec=%s max_age_sec=%s\n' \
        "$freshness_report" "${freshness_age:-0}" "$freshness_max_age"
      exit 0
      ;;
    missing|stale|jq_missing)
      if (( AUTO_REFRESH_IF_STALE != 1 )); then
        printf 'portfolio_preflight_required: status=%s report=%s age_sec=%s max_age_sec=%s; rerun scripts/portfolio_session_start.sh %s\n' \
          "$freshness_status" \
          "$freshness_report" \
          "${freshness_age:-unknown}" \
          "$freshness_max_age" \
          "$PORTFOLIO_ARG" >&2
        exit 4
      fi
      printf 'portfolio_preflight_refreshing: previous_status=%s report=%s age_sec=%s max_age_sec=%s\n' \
        "$freshness_status" \
        "$freshness_report" \
        "${freshness_age:-unknown}" \
        "$freshness_max_age" >&2
      ;;
    *)
      if (( AUTO_REFRESH_IF_STALE != 1 )); then
        printf 'portfolio_preflight_required: status=%s report=%s; rerun scripts/portfolio_session_start.sh %s\n' \
          "${freshness_status:-unknown}" \
          "$freshness_report" \
          "$PORTFOLIO_ARG" >&2
        exit 4
      fi
      ;;
  esac
fi

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

# resolve_clone_url <gh_repo> <gh_config_dir> <clone_url> — a configured
# GIT_REMOTE_URL / REPO_URL wins; the derived default (`https://github.com/
# <repo>.git`) is replaced by the forge's own answer (ordo_provider repo_get,
# #816: `clone_url` when the adapter provides one, else `<url>.git`), so a
# Forgejo/GitLab profile clones from its forge. Falls back to the derived
# default when the forge cannot be reached. One lookup per repository.
declare -A PORTFOLIO_CLONE_URL_CACHE=()
resolve_clone_url() {
  local gh_repo=$1 gh_config_dir=$2 clone_url=$3 resolved
  if [[ -z "$gh_repo" || "$clone_url" != "https://github.com/${gh_repo}.git" ]]; then
    printf '%s' "$clone_url"
    return 0
  fi
  if [[ -n "${PORTFOLIO_CLONE_URL_CACHE[$gh_repo]:-}" ]]; then
    printf '%s' "${PORTFOLIO_CLONE_URL_CACHE[$gh_repo]}"
    return 0
  fi
  if [[ -n "$gh_config_dir" ]]; then
    resolved=$(GH_CONFIG_DIR="$gh_config_dir" ordo_provider repo_get --repo "$gh_repo" 2>/dev/null \
      | jq -r 'if (.clone_url // "") != "" then .clone_url elif (.url // "") != "" then (.url + ".git") else empty end' 2>/dev/null || true)
  else
    resolved=$(ordo_provider repo_get --repo "$gh_repo" 2>/dev/null \
      | jq -r 'if (.clone_url // "") != "" then .clone_url elif (.url // "") != "" then (.url + ".git") else empty end' 2>/dev/null || true)
  fi
  [[ -n "$resolved" ]] || resolved=$clone_url
  PORTFOLIO_CLONE_URL_CACHE[$gh_repo]=$resolved
  printf '%s' "$resolved"
}

clone_command() {
  local gh_repo=$1 gh_config_dir=$2 clone_url=$3 workdir=$4
  local safe_url
  safe_url=$(redact_url "$(resolve_clone_url "$gh_repo" "$gh_config_dir" "$clone_url")")
  printf 'git clone %s %s' "$(shell_quote "$safe_url")" "$(shell_quote "$workdir")"
}

pull_command() {
  local workdir=$1 default_branch=$2
  printf 'git -C %s pull --ff-only origin %s' \
    "$(shell_quote "$workdir")" \
    "$(shell_quote "$default_branch")"
}

set_identity_command() {
  local workdir=$1 name=$2 email=$3
  printf 'git -C %s config user.name %s && git -C %s config user.email %s' \
    "$(shell_quote "$workdir")" \
    "$(shell_quote "$name")" \
    "$(shell_quote "$workdir")" \
    "$(shell_quote "$email")"
}

apply_git_identity() {
  local workdir=$1 name=$2 email=$3
  if dry_run_enabled; then
    dry_note "$(set_identity_command "$workdir" "$name" "$email")"
    return 0
  fi
  run_timeout "$PORTFOLIO_SESSION_GIT_TIMEOUT_SEC" \
    git -C "$workdir" config user.name "$name" >/dev/null 2>&1 || return 1
  run_timeout "$PORTFOLIO_SESSION_GIT_TIMEOUT_SEC" \
    git -C "$workdir" config user.email "$email" >/dev/null 2>&1 || return 1
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
    identity_name_template=${AGENT_GIT_IDENTITY_NAME_TEMPLATE:-}
    identity_email_template=${AGENT_GIT_IDENTITY_EMAIL_TEMPLATE:-}

    resolve_identity() {
      local entry_label=$1 out_name out_email entry override_label override_name override_email override_extra
      out_name=""
      out_email=""
      if [[ -n "${AGENT_GIT_IDENTITIES+x}" && "${#AGENT_GIT_IDENTITIES[@]}" -gt 0 ]]; then
        for entry in "${AGENT_GIT_IDENTITIES[@]}"; do
          IFS="|" read -r override_label override_name override_email override_extra <<< "$entry"
          if [[ -n "$override_extra" ]]; then
            printf "AGENT_GIT_IDENTITIES entry malformed (need label|name|email): %s\n" "$entry" >&2
            return 2
          fi
          if [[ "$override_label" == "$entry_label" ]]; then
            out_name="$override_name"
            out_email="$override_email"
            break
          fi
        done
      fi
      if [[ -z "$out_name" && -n "$identity_name_template" ]]; then
        # shellcheck disable=SC2059
        out_name=$(printf "$identity_name_template" "$entry_label")
      fi
      if [[ -z "$out_email" && -n "$identity_email_template" ]]; then
        # shellcheck disable=SC2059
        out_email=$(printf "$identity_email_template" "$entry_label")
      fi
      printf "%s\n%s\n" "$out_name" "$out_email"
    }

    emit_entry() {
      local label=$1 pane=$2 workdir=$3 entry_source=$4
      [[ -n "$label$pane$workdir" ]] || return 0
      local target_identity_name target_identity_email
      local identity_arr=()
      mapfile -t identity_arr < <(resolve_identity "$label")
      target_identity_name=${identity_arr[0]-}
      target_identity_email=${identity_arr[1]-}
      jq -nc \
        --arg alias "$alias" \
        --arg project "${PROJECT:-$alias}" \
        --arg agent_label "$label" \
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
        --arg target_identity_name "$target_identity_name" \
        --arg target_identity_email "$target_identity_email" \
        "{
          alias:\$alias,
          project:\$project,
          label:\$agent_label,
          pane:\$pane,
          workdir:\$workdir,
          source:\$source,
          priority:(\$priority | tonumber),
          priority_mode:\$priority_mode,
          default_branch:\$default_branch,
          gh_repo:\$gh_repo,
          gh_config_dir:\$gh_config_dir,
          clone_url:\$clone_url,
          config:\$config,
          target_identity_name:\$target_identity_name,
          target_identity_email:\$target_identity_email
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
  git clone --quiet "$(resolve_clone_url "$gh_repo" "$gh_config_dir" "$clone_url")" "$workdir"
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
  local upstream="" upstream_ahead="" upstream_behind=""
  local remote_default=0 base_current="" status="" remediation="" applied="" ready=0
  local remediation_action="" remediation_command="" safe_apply=0
  local counts
  local identity_name="" identity_email="" identity_complete=0
  local target_identity_name target_identity_email

  alias=$(printf '%s' "$entry" | jq -r '.alias')
  project=$(printf '%s' "$entry" | jq -r '.project')
  label=$(printf '%s' "$entry" | jq -r '.label')
  pane=$(printf '%s' "$entry" | jq -r '.pane')
  workdir=$(printf '%s' "$entry" | jq -r '.workdir')

  # Per-pane fan-out jitter (#409). When --apply iterates over all
  # twelve panes, the per-agent clone/pull/identity-set work fans out
  # in tight succession; without staggering, the agent CLIs that resume
  # right after on those panes hit Anthropic /v1/messages in lockstep
  # and trigger 429 storms. A 50–250 ms randomised sleep before each
  # entry's mutations is read-only otherwise (jitter only fires on the
  # APPLY path) so diagnostic --tsv/--json runs stay fast.
  if [[ "$APPLY" -eq 1 ]] && ! dry_run_enabled; then
    api_rate_limiter_jitter
  fi
  entry_source=$(printf '%s' "$entry" | jq -r '.source // "configured"')
  priority=$(printf '%s' "$entry" | jq -r '.priority')
  priority_mode_entry=$(printf '%s' "$entry" | jq -r '.priority_mode')
  default_branch=$(printf '%s' "$entry" | jq -r '.default_branch')
  gh_repo=$(printf '%s' "$entry" | jq -r '.gh_repo')
  gh_config_dir=$(printf '%s' "$entry" | jq -r '.gh_config_dir')
  clone_url=$(printf '%s' "$entry" | jq -r '.clone_url')
  clone_url_output=$(redact_url "$clone_url")
  target_identity_name=$(printf '%s' "$entry" | jq -r '.target_identity_name // ""')
  target_identity_email=$(printf '%s' "$entry" | jq -r '.target_identity_email // ""')

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
    upstream=$(git_value "$workdir" rev-parse --abbrev-ref --symbolic-full-name '@{u}')
    identity_name=$(git_value "$workdir" config --local user.name)
    identity_email=$(git_value "$workdir" config --local user.email)
    if [[ -n "$identity_name" && -n "$identity_email" ]]; then
      identity_complete=1
    fi

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
    if [[ -n "$upstream" ]]; then
      counts=$(git_value "$workdir" rev-list --left-right --count "$upstream...HEAD")
      upstream_behind=${counts%%[[:space:]]*}
      upstream_ahead=${counts##*[[:space:]]}
    fi

    if [[ "${dirty:-0}" != "0" ]]; then
      if [[ -n "$branch" \
        && "$branch" != "$default_branch" \
        && -n "$upstream" \
        && "${upstream_ahead:-}" == "0" \
        && "${upstream_behind:-}" == "0" ]]; then
        status="dirty_after_pr"
        remediation="Commit and push the staged or unstaged work, intentionally discard it, or attach it to follow-up work before assigning this clone."
      else
        status="dirty_worktree"
        remediation="Review, commit, stash, or clean local changes before assigning work."
      fi
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

    if [[ "$identity_complete" -ne 1 && ( "$status" == "ready" || -z "$status" ) ]]; then
      ready=0
      if [[ -n "$target_identity_name" && -n "$target_identity_email" ]]; then
        status="missing_git_identity"
        remediation="Set per-agent local git identity (user.name + user.email) on this clone."
        remediation_action="set-git-identity"
        remediation_command=$(set_identity_command "$workdir" "$target_identity_name" "$target_identity_email")
        safe_apply=1
      else
        status="missing_git_identity_no_template"
        remediation="Configure AGENT_GIT_IDENTITY_NAME_TEMPLATE and AGENT_GIT_IDENTITY_EMAIL_TEMPLATE (or AGENT_GIT_IDENTITIES per-label) so ORDO can set per-agent identity."
        remediation_action="configure-identity-template"
        remediation_command=""
        safe_apply=0
      fi
    fi

    if [[ "$APPLY" -eq 1 && "$status" == "missing_git_identity" ]]; then
      if apply_git_identity "$workdir" "$target_identity_name" "$target_identity_email"; then
        applied="${applied:+$applied,}set-git-identity"
        identity_name="$target_identity_name"
        identity_email="$target_identity_email"
        identity_complete=1
        status="ready"
        remediation=""
        ready=1
      else
        status="set_identity_failed"
        remediation="Run git config user.name and user.email manually for this clone."
      fi
    fi
  fi

  if [[ "$ready" -eq 1 ]]; then
    safe_apply=0
    remediation_action=""
    remediation_command=""
  fi

  jq -nc \
    --arg alias "$alias" \
    --arg project "$project" \
    --arg agent_label "$label" \
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
    --arg upstream "$upstream" \
    --arg upstream_ahead "$upstream_ahead" \
    --arg upstream_behind "$upstream_behind" \
    --arg ahead "$ahead" \
    --arg behind "$behind" \
    --arg dirty "$dirty" \
    --arg base_current "$base_current" \
    --arg status "$status" \
    --arg remediation "$remediation" \
    --arg remediation_action "$remediation_action" \
    --arg remediation_command "$remediation_command" \
    --arg applied "$applied" \
    --arg identity_name "$identity_name" \
    --arg identity_email "$identity_email" \
    --arg target_identity_name "$target_identity_name" \
    --arg target_identity_email "$target_identity_email" \
    --argjson exists "$exists" \
    --argjson git_repo "$git_repo" \
    --argjson remote_default "$remote_default" \
    --argjson ready "$ready" \
    --argjson safe_apply "$safe_apply" \
    --argjson identity_complete "$identity_complete" \
    '{
      alias:$alias,
      project:$project,
      label:$agent_label,
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
      upstream:(if $upstream == "" then null else $upstream end),
      upstream_ahead:(if $upstream_ahead == "" then null else ($upstream_ahead | tonumber) end),
      upstream_behind:(if $upstream_behind == "" then null else ($upstream_behind | tonumber) end),
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
      applied:(if $applied == "" then null else $applied end),
      identity_complete:$identity_complete,
      identity_name:$identity_name,
      identity_email:$identity_email,
      target_identity_name:(if $target_identity_name == "" then null else $target_identity_name end),
      target_identity_email:(if $target_identity_email == "" then null else $target_identity_email end)
    }'
}

preflight_clean_plan_json() {
  local report=$1
  printf '%s\n' "$report" | jq '
    def clean_action:
      if .safe_apply == 1 and (.remediation_command // "") != "" then
        .remediation_command
      elif .status == "dirty_after_pr" then
        "Commit and push the staged/unstaged work, intentionally discard it, or attach it to follow-up work before dispatch."
      elif .status == "dirty_worktree" then
        "Review local changes, then commit, stash, or clean the worktree before dispatch."
      elif .status == "branch_needs_rebase" then
        "Rebase the branch on origin/" + .default_branch + " or hand it to an agent as an explicit unblock task."
      elif .status == "local_work_branch" then
        "Create or link a PR for this branch, then park it or return the clone to the default branch."
      elif .status == "missing_clone_no_remote" then
        "Confirm the project repo binding, add GH_REPO/REPO_URL/GIT_REMOTE_URL, then rerun preflight."
      elif .status == "missing_workdir_template" then
        "Define AGENT_WORKDIR_TEMPLATE or AGENT_REPO_PREFIX for this project."
      elif .status == "not_git_repo" then
        "Move or clean the existing path, then clone the expected repository."
      elif .status == "detached_head" then
        "Checkout the default branch or a named work branch explicitly."
      elif .status == "missing_origin_default" then
        "Fetch or configure origin/" + .default_branch + " before dispatch."
      elif .status == "diverged_default" then
        "Reconcile the local default branch with origin/" + .default_branch + " manually."
      elif .status == "ahead_default" then
        "Inspect, push, or move local default-branch commits before dispatch."
      elif .status == "clone_failed" then
        "Retry clone manually and verify repository access."
      elif .status == "pull_failed" then
        "Run git pull --ff-only manually and inspect the failure."
      elif .status == "missing_git_identity" then
        "Set per-agent local git identity: " + (.remediation_command // ("git -C " + .workdir + " config user.name <name> && git -C " + .workdir + " config user.email <email>"))
      elif .status == "missing_git_identity_no_template" then
        "Configure AGENT_GIT_IDENTITY_NAME_TEMPLATE and AGENT_GIT_IDENTITY_EMAIL_TEMPLATE (or AGENT_GIT_IDENTITIES per-label) for project " + .alias + ", then rerun preflight."
      elif .status == "set_identity_failed" then
        "Set git config user.name and user.email manually for " + .workdir + "."
      else
        (.remediation // "Review this preflight blocker before dispatch.")
      end;
    [
      .[]
      | select(.ready != 1)
      | . + {
          unblock_code: ("preflight-" + .status),
          recommended_action: clean_action
        }
    ]'
}

persist_preflight_clean_plan() {
  local report=$1 state_dir=$2
  local clean_plan unblock_file task_file clean_file md_file
  local new_open new_history existing_open tmp created_at

  clean_file="$state_dir/clean_plan.json"
  md_file="$state_dir/PREFLIGHT_CLEAN_PLAN.md"
  unblock_file="$state_dir/unblock_tasks.json"
  task_file="$state_dir/ORCH_TASKS.md"
  created_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

  clean_plan=$(preflight_clean_plan_json "$report")
  printf '%s\n' "$clean_plan" > "$clean_file"

  {
    printf '# ORDO Portfolio Preflight Clean Plan\n\n'
    printf -- "- generated_at: \`%s\`\n" "$created_at"
    printf -- "- blockers: \`%s\`\n\n" "$(printf '%s\n' "$clean_plan" | jq 'length')"
    if [[ "$(printf '%s\n' "$clean_plan" | jq 'length')" -eq 0 ]]; then
      printf 'No preflight blockers remain.\n'
    else
      printf '%s\n' "$clean_plan" | jq -r '
        .[]
        | "- [ ] "
          + "code=" + .unblock_code
          + " project=" + .alias
          + " agent=" + .label
          + " status=" + .status
          + " workdir=" + .workdir
          + " action=" + .recommended_action'
    fi
  } > "$md_file"

  new_open=$(mktemp)
  new_history=$(mktemp)
  printf '{}\n' > "$new_open"
  printf '[]\n' > "$new_history"

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    local alias project label pane workdir branch default_branch status code action detail id record tmp_record
    alias=$(printf '%s' "$item" | jq -r '.alias')
    project=$(printf '%s' "$item" | jq -r '.project')
    label=$(printf '%s' "$item" | jq -r '.label')
    pane=$(printf '%s' "$item" | jq -r '.pane')
    workdir=$(printf '%s' "$item" | jq -r '.workdir')
    branch=$(printf '%s' "$item" | jq -r '.branch // ""')
    default_branch=$(printf '%s' "$item" | jq -r '.default_branch')
    status=$(printf '%s' "$item" | jq -r '.status')
    code=$(printf '%s' "$item" | jq -r '.unblock_code')
    action=$(printf '%s' "$item" | jq -r '.recommended_action')
    detail=$(printf '%s' "$item" | jq -c '{
      source:.source,
      status:.status,
      remediation:.remediation,
      remediation_action:.remediation_action,
      remediation_command:.remediation_command,
      upstream:.upstream,
      upstream_ahead:.upstream_ahead,
      upstream_behind:.upstream_behind,
      ahead:.ahead,
      behind:.behind,
      dirty:.dirty,
      fetch:.fetch
    }')
    id=$(printf '%s' "${alias}|${label}|${workdir}|${branch}|${status}|${action}" \
      | sha256sum | awk '{print substr($1,1,16)}')
    record=$(jq -nc \
      --arg id "$id" \
      --arg created_at "$created_at" \
      --arg status_open "open" \
      --arg code "$code" \
      --arg action "$action" \
      --arg detail "$detail" \
      --arg mode "preflight" \
      --arg reason "portfolio_session_start" \
      --arg source_project "$alias" \
      --arg project "$project" \
      --arg source_agent "$label" \
      --arg source_pane "$pane" \
      --arg source_workdir "$workdir" \
      --arg source_branch "$branch" \
      --arg source_default "$default_branch" \
      --arg target_project "$alias" \
      --arg target_agent "$label" \
      --arg target_pane "$pane" \
      --arg target_workdir "$workdir" \
      --arg target_branch "$branch" \
      --arg target_default "$default_branch" \
      '{
        id:$id,
        created_at:$created_at,
        status:$status_open,
        code:$code,
        exit_code:0,
        recommended_action:$action,
        detail:($detail | fromjson),
        mode:$mode,
        reason:$reason,
        project:$project,
        source_project:$source_project,
        source_agent:$source_agent,
        source_pane:$source_pane,
        source_workdir:$source_workdir,
        source_branch:$source_branch,
        source_default:$source_default,
        source_pr:null,
        source_pr_state:"",
        target_project:$target_project,
        target_agent:$target_agent,
        target_pane:$target_pane,
        target_workdir:$target_workdir,
        target_branch:$target_branch,
        target_default:$target_default
      }')
    tmp_record=$(mktemp)
    jq --arg id "$id" --argjson record "$record" '. + {($id):$record}' "$new_open" > "$tmp_record"
    mv "$tmp_record" "$new_open"
    tmp_record=$(mktemp)
    jq --argjson record "$record" '. + [$record]' "$new_history" > "$tmp_record"
    mv "$tmp_record" "$new_history"
  done < <(printf '%s\n' "$clean_plan" | jq -c '.[]')

  existing_open="{}"
  if [[ -s "$unblock_file" ]]; then
    existing_open=$(jq -c '.open // {}' "$unblock_file")
  fi

  tmp="${unblock_file}.tmp.$$"
  if [[ -s "$unblock_file" ]]; then
    jq \
      --argjson preflight "$(cat "$new_open")" \
      --argjson new_history "$(cat "$new_history")" \
      --argjson existing_open "$existing_open" \
      '
        . as $old
        | ($old.open // {} | with_entries(select((.value.code | startswith("preflight-")) | not))) as $kept
        | ($new_history | map(select(($existing_open[.id] // null) == null))) as $fresh_history
        | {
            open: ($kept + $preflight),
            history: (($old.history // []) + $fresh_history)
          }
      ' "$unblock_file" > "$tmp"
  else
    jq -nc \
      --argjson preflight "$(cat "$new_open")" \
      --argjson new_history "$(cat "$new_history")" \
      '{open:$preflight, history:$new_history}' > "$tmp"
  fi
  mv "$tmp" "$unblock_file"
  rm -f "$new_open" "$new_history"

  {
    printf '# ORDO Portfolio Unblock Tasks\n\n'
    jq -r '
      (.open // {})
      | to_entries
      | sort_by(.value.created_at, .value.code, .value.source_project, .value.source_agent)
      | .[]
      | "- [ ] "
        + .value.created_at
        + " id=" + .key
        + " code=" + .value.code
        + " source=" + .value.source_project + "/" + (.value.source_agent // "unknown")
        + " target=" + .value.target_project + "/" + (.value.target_agent // "unknown")
        + " action=" + .value.recommended_action
    ' "$unblock_file"
  } > "$task_file"
}

stale_assignment_entry_json() {
  local raw=$1
  jq -nc --argjson raw "$raw" '
    {
      alias: $raw.alias,
      project: $raw.project,
      label: $raw.label,
      pane: "",
      workdir: ($raw.workdir // ""),
      source: "stale_matrix_assignment",
      priority: $raw.priority,
      priority_mode: "explicit",
      default_branch: "",
      gh_repo: "",
      clone_url: "",
      exists: 0,
      git_repo: 0,
      branch: ($raw.branch // ""),
      head: "",
      fetch: "skipped",
      remote_default: 0,
      ahead: null,
      behind: null,
      dirty: null,
      base_current: null,
      status: "stale_matrix_assignment",
      ready: 0,
      safe_apply: 0,
      remediation_action: "review-stale-assignment",
      remediation_command: null,
      remediation: ("Stale dispatch assignment for label \($raw.label) (ticket=\($raw.ticket)) — agent is no longer in the configured fleet or portfolio matrix; reconcile state/" + $raw.project + "/assignments.json before dispatch."),
      applied: null,
      ticket: ($raw.ticket // ""),
      dispatched_at: ($raw.dispatched_at // "")
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

while IFS= read -r stale_raw; do
  [[ -n "$stale_raw" ]] || continue
  json_items+=("$(stale_assignment_entry_json "$stale_raw")")
done < <(portfolio_stale_matrix_assignments_json "$matrix_spec" "$ensure_matrix")

json_report=$(printf '%s\n' "${json_items[@]}" | jq -s 'sort_by(-.priority, .alias, .label)')

if ! dry_run_enabled; then
  state_dir=$(portfolio_state_dir)
  mkdir -p "$state_dir"
  printf '%s\n' "$json_report" > "$state_dir/session_start.json"
  persist_preflight_clean_plan "$json_report" "$state_dir"
fi

if [[ "$FORMAT" == "json" ]]; then
  printf '%s\n' "$json_report"
else
  printf 'alias\tpriority\tproject\tlabel\tsource\tworkdir\tstatus\tready\tsafe_apply\tbranch\tahead\tbehind\tdirty\tfetch\tidentity_complete\tidentity_name\tidentity_email\tapplied\taction\tcommand\tremediation\n'
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
    .identity_complete,
    (.identity_name // ""),
    (.identity_email // ""),
    (.applied // ""),
    (.remediation_action // ""),
    (.remediation_command // ""),
    .remediation
  ] | @tsv'
fi
