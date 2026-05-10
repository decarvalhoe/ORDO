#!/usr/bin/env bash
# scripts/post_merge_cleanup.sh - safely park an agent worktree after a PR merge.
#
# Usage:
#   post_merge_cleanup.sh <project_short|config_path> <pr-number> [--tsv|--json] [--no-fetch] [--dry-run]
#
# The cleanup is deliberately non-destructive: it only touches clean git
# worktrees. A matching merged branch is switched back to the configured default
# branch, fast-forwarded from origin/default, and its dispatch assignment is
# cleared. Dirty or ambiguous worktrees are reported as blockers instead.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/dry_run.sh"
source "$TK/lib/config_resolver.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

CFG_ARG=${1:?usage: post_merge_cleanup.sh <project> <pr-number> [--tsv|--json] [--no-fetch] [--dry-run]}
PR=${2:?missing pr number}
FORMAT="tsv"
FETCH=1
ASSUME_MERGED=0
MERGED_BRANCH_OVERRIDE=""
shift 2
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tsv) FORMAT="tsv" ;;
    --json) FORMAT="json" ;;
    --no-fetch) FETCH=0 ;;
    --assume-merged) ASSUME_MERGED=1 ;;
    --merged-branch)
      MERGED_BRANCH_OVERRIDE=${2:?missing value for --merged-branch}
      shift
      ;;
    --merged-branch=*) MERGED_BRANCH_OVERRIDE=${1#--merged-branch=} ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

load_project_config "$CFG_ARG"

source "$TK/lib/audit_log.sh"
source "$TK/lib/state_persist.sh"
source "$TK/lib/agent_inventory.sh"
source "$TK/lib/process_safety.sh"

: "${GH_REPO:?}" "${GH_CONFIG_DIR:?}" "${DEFAULT_BRANCH:=main}"
: "${ORCH_POST_MERGE_CLEANUP_TIMEOUT_SEC:=20}"

records=()

run_timeout() {
  orch_run_timeout "$ORCH_POST_MERGE_CLEANUP_TIMEOUT_SEC" "$@"
}

git_value() {
  local workdir=$1
  shift
  run_timeout git -C "$workdir" "$@" 2>/dev/null || true
}

git_quiet() {
  local workdir=$1
  shift
  run_timeout git -C "$workdir" "$@" >/dev/null 2>&1
}

is_git_worktree() {
  local workdir=${1:?usage: is_git_worktree <workdir>}
  git_quiet "$workdir" rev-parse --is-inside-work-tree
}

is_linked_worktree() {
  local workdir=${1:?usage: is_linked_worktree <workdir>}
  local git_dir common_dir

  if [ -f "$workdir/.git" ]; then
    return 0
  fi

  git_dir=$(git_value "$workdir" rev-parse --git-dir)
  common_dir=$(git_value "$workdir" rev-parse --git-common-dir)
  [ -n "$git_dir" ] && [ -n "$common_dir" ] && [ "$git_dir" != "$common_dir" ]
}

quote_cmd() {
  local arg
  for arg in "$@"; do
    printf '%q ' "$arg"
  done | sed 's/[[:space:]]$//'
}

dry_note() {
  dry_run_enabled || return 0
  printf 'DRY-RUN: %s\n' "$(quote_cmd "$@")" >&2
}

git_mutate() {
  local workdir=$1
  shift
  if dry_run_enabled; then
    dry_note git -C "$workdir" "$@"
    return 0
  fi
  run_timeout git -C "$workdir" "$@" >&2
}

add_record() {
  local agent=${1:-}
  local workdir=${2:-}
  local action=${3:-}
  local status=${4:-}
  local reason=${5:-}
  local detail=${6:-}
  records+=("$(jq -nc \
    --arg pr "$PR" \
    --arg agent "$agent" \
    --arg workdir "$workdir" \
    --arg action "$action" \
    --arg status "$status" \
    --arg reason "$reason" \
    --arg detail "$detail" \
    '{pr:($pr|tonumber),agent:$agent,workdir:$workdir,action:$action,status:$status,reason:$reason,detail:$detail}')")
}

emit_records() {
  if [ "$FORMAT" = "json" ]; then
    if [ "${#records[@]}" -eq 0 ]; then
      printf '[]\n'
    else
      printf '%s\n' "${records[@]}" | jq -s '.'
    fi
    return 0
  fi

  printf 'pr\tagent\tworkdir\taction\tstatus\treason\tdetail\n'
  if [ "${#records[@]}" -gt 0 ]; then
    printf '%s\n' "${records[@]}" \
      | jq -r '. | [.pr,.agent,.workdir,.action,.status,.reason,.detail] | @tsv'
  fi
}

assignment_has_label() {
  local agent=${1:?usage: assignment_has_label <agent>}
  state_get assignments | jq -e --arg agent "$agent" 'has($agent)' >/dev/null 2>&1
}

clear_assignment() {
  local agent=${1:?usage: clear_assignment <agent>}
  local target lock tmp
  target=$(state_file assignments.json)
  lock="${target}.lock"
  tmp="${target}.tmp.$$"

  if dry_run_enabled; then
    printf 'DRY-RUN: state_update assignments del(.%s)\n' "$agent" >&2
    return 0
  fi

  mkdir -p "$(dirname "$target")"
  (
    flock 9
    if [ -s "$target" ]; then
      jq --arg agent "$agent" 'del(.[$agent])' "$target" > "$tmp"
    else
      printf '{}\n' > "$tmp"
    fi
    mv "$tmp" "$target"
  ) 9>"$lock"
}

switch_to_default() {
  local workdir=${1:?usage: switch_to_default <workdir>}
  local current_branch=${2:?usage: switch_to_default <workdir> <current-branch>}

  if [ "$FETCH" -eq 1 ]; then
    git_mutate "$workdir" fetch origin "$DEFAULT_BRANCH" || return 1
  fi
  if ! git_quiet "$workdir" rev-parse --verify "origin/$DEFAULT_BRANCH"; then
    return 2
  fi

  if is_linked_worktree "$workdir"; then
    git_mutate "$workdir" switch --detach "origin/$DEFAULT_BRANCH" || return 1
    return 0
  fi

  if [ "$current_branch" != "$DEFAULT_BRANCH" ]; then
    if git_quiet "$workdir" show-ref --verify --quiet "refs/heads/$DEFAULT_BRANCH"; then
      git_mutate "$workdir" switch "$DEFAULT_BRANCH" || return 1
    else
      git_mutate "$workdir" switch -c "$DEFAULT_BRANCH" --track "origin/$DEFAULT_BRANCH" || return 1
    fi
  fi

  git_mutate "$workdir" pull --ff-only origin "$DEFAULT_BRANCH" || return 1
}

cleanup_candidate() {
  local agent=${1:?usage: cleanup_candidate <agent> <workdir> <source> <merged-branch>}
  local workdir=${2:?usage: cleanup_candidate <agent> <workdir> <source> <merged-branch>}
  local source=${3:?usage: cleanup_candidate <agent> <workdir> <source> <merged-branch>}
  local merged_branch=${4:?usage: cleanup_candidate <agent> <workdir> <source> <merged-branch>}
  local current_branch dirty cleanup_rc assignment_cleared=0 detail

  if ! is_git_worktree "$workdir"; then
    add_record "$agent" "$workdir" "skip" "blocked" "not_git_repo" "source=$source"
    return 0
  fi

  current_branch=$(git_value "$workdir" branch --show-current)
  if [ -z "$current_branch" ]; then
    add_record "$agent" "$workdir" "skip" "blocked" "detached_head" "source=$source"
    return 0
  fi

  dirty=$(git_value "$workdir" status --porcelain | wc -l | tr -d ' ')
  if [ "${dirty:-0}" != "0" ]; then
    add_record "$agent" "$workdir" "skip" "blocked" "dirty_worktree" \
      "source=$source current_branch=$current_branch dirty=$dirty"
    return 0
  fi

  if [ "$current_branch" != "$merged_branch" ] && [ "$current_branch" != "$DEFAULT_BRANCH" ]; then
    add_record "$agent" "$workdir" "skip" "blocked" "branch_mismatch" \
      "source=$source current_branch=$current_branch merged_branch=$merged_branch"
    return 0
  fi

  set +e
  switch_to_default "$workdir" "$current_branch"
  cleanup_rc=$?
  set -e
  case "$cleanup_rc" in
    0) ;;
    2)
      add_record "$agent" "$workdir" "skip" "blocked" "missing_origin_default" \
        "source=$source default_branch=$DEFAULT_BRANCH"
      return 0
      ;;
    *)
      add_record "$agent" "$workdir" "skip" "blocked" "switch_or_pull_failed" \
        "source=$source default_branch=$DEFAULT_BRANCH"
      return 0
      ;;
  esac

  if assignment_has_label "$agent"; then
    clear_assignment "$agent"
    assignment_cleared=1
  fi

  detail="source=$source from_branch=$current_branch default_branch=$DEFAULT_BRANCH assignment_cleared=$assignment_cleared"
  add_record "$agent" "$workdir" "cleanup" "ok" "" "$detail"
  audit "POST_MERGE_CLEANUP agent=${agent} pr=#${PR} branch=${merged_branch} workdir=${workdir} action=cleanup status=ok assignment_cleared=${assignment_cleared}"
}

pr_json=$(run_timeout env GH_CONFIG_DIR="$GH_CONFIG_DIR" gh pr view "$PR" \
  --repo "$GH_REPO" \
  --json number,state,headRefName,headRefOid,baseRefName,mergedAt 2>/dev/null || printf '{}')

pr_state=$(printf '%s' "$pr_json" | jq -r '.state // "UNKNOWN"')
merged_at=$(printf '%s' "$pr_json" | jq -r '.mergedAt // ""')
head_branch=$(printf '%s' "$pr_json" | jq -r '.headRefName // ""')
base_branch=$(printf '%s' "$pr_json" | jq -r '.baseRefName // ""')

if [ -n "$MERGED_BRANCH_OVERRIDE" ]; then
  head_branch="$MERGED_BRANCH_OVERRIDE"
fi

if [ "$ASSUME_MERGED" -ne 1 ] && [ "$pr_state" != "MERGED" ] && [ -z "$merged_at" ]; then
  add_record "" "" "skip" "not_applicable" "not_merged" "state=$pr_state"
  audit "POST_MERGE_CLEANUP pr=#${PR} action=skip reason=not_merged state=${pr_state}"
  emit_records
  exit 0
fi

if [ -n "$base_branch" ] && [ "$base_branch" != "$DEFAULT_BRANCH" ]; then
  add_record "" "" "skip" "not_applicable" "base_mismatch" "base=$base_branch default=$DEFAULT_BRANCH"
  audit "POST_MERGE_CLEANUP pr=#${PR} action=skip reason=base_mismatch base=${base_branch} default=${DEFAULT_BRANCH}"
  emit_records
  exit 0
fi

if [ -z "$head_branch" ]; then
  add_record "" "" "skip" "blocked" "missing_head_branch" "state=$pr_state"
  audit "POST_MERGE_CLEANUP pr=#${PR} action=skip reason=missing_head_branch"
  emit_records
  exit 0
fi

audit "POST_MERGE_CLEANUP start pr=#${PR} branch=${head_branch} default=${DEFAULT_BRANCH}"

candidate_file=$(mktemp)
dedup_file=$(mktemp)
cleanup_tmp() {
  rm -f "$candidate_file" "$dedup_file"
}
trap cleanup_tmp EXIT

state_get assignments \
  | jq -r --arg branch "$head_branch" '
      to_entries[]
      | select((.value.branch // "") == $branch)
      | [.key, (.value.workdir // .value.repo_root // ""), "assignment"]
      | @tsv
    ' >> "$candidate_file"

while IFS='|' read -r label _pane workdir; do
  [ -n "$label$workdir" ] || continue
  is_git_worktree "$workdir" || continue
  branch=$(git_value "$workdir" branch --show-current)
  if [ "$branch" = "$head_branch" ]; then
    printf '%s\t%s\t%s\n' "$label" "$workdir" "inventory" >> "$candidate_file"
  fi
done < <(agent_inventory_entries || true)

awk -F '\t' 'NF >= 2 && $1 != "" && $2 != "" && !seen[$1 FS $2]++' \
  "$candidate_file" > "$dedup_file"

if [ ! -s "$dedup_file" ]; then
  add_record "" "" "skip" "not_applicable" "no_matching_worktree" "merged_branch=$head_branch"
  audit "POST_MERGE_CLEANUP pr=#${PR} branch=${head_branch} action=skip reason=no_matching_worktree"
  emit_records
  exit 0
fi

while IFS=$'\t' read -r agent workdir source; do
  cleanup_candidate "$agent" "$workdir" "$source" "$head_branch"
done < "$dedup_file"

emit_records
