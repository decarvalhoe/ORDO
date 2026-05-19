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
source "$TK/lib/external_mutation_gate.sh"
source "$TK/lib/state_persist.sh"
source "$TK/lib/agent_inventory.sh"
source "$TK/lib/process_safety.sh"
source "$TK/lib/tmux_helpers.sh"
# dispatch_capacity.sh exposes the in-flight scope-claim ledger helpers
# (#721 sub-A). The cleanup script releases the matching claim row when
# the dispatch's assignment is cleared. Sanitized test sandboxes may
# omit the lib; fall back to no-ops in that case.
if [[ -f "$TK/lib/dispatch_capacity.sh" ]]; then
  # shellcheck source=../lib/dispatch_capacity.sh
  source "$TK/lib/dispatch_capacity.sh"
fi
# closure_acceptance.sh exposes the closure_acceptance_gate classifier (#723).
# Guard the source so sanitized test sandboxes that don't copy the lib still
# parse; the gate is opt-in via ORCH_CLOSURE_GATE_MODE and its functions are
# only called when mode is set to warn or enforce.
if [[ -f "$TK/lib/closure_acceptance.sh" ]]; then
  # shellcheck source=../lib/closure_acceptance.sh
  source "$TK/lib/closure_acceptance.sh"
fi

: "${GH_REPO:?}" "${GH_CONFIG_DIR:?}" "${DEFAULT_BRANCH:=main}"
: "${ORCH_POST_MERGE_CLEANUP_TIMEOUT_SEC:=20}"
: "${POST_MERGE_ISSUE_RECONCILE:=auto}"

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

post_merge_issue_reconcile_enabled() {
  case "${POST_MERGE_ISSUE_RECONCILE:-auto}" in
    1|true|TRUE|yes|YES|on|ON|close|enabled) return 0 ;;
    0|false|FALSE|no|NO|off|OFF|disabled) return 1 ;;
    auto|"")
      [ "$GH_REPO" = "RBOKproject/realisons-wordpress" ]
      return
      ;;
    *)
      audit "POST_MERGE_CLEANUP issue_reconcile skipped invalid_policy=${POST_MERGE_ISSUE_RECONCILE}"
      return 1
      ;;
  esac
}

post_merge_repo_default_branch() {
  run_timeout env GH_CONFIG_DIR="$GH_CONFIG_DIR" gh repo view "$GH_REPO" --json defaultBranchRef 2>/dev/null \
    | jq -r '.defaultBranchRef.name // empty' 2>/dev/null
}

post_merge_issue_refs_from_pr_json() {
  local meta=${1:?usage: post_merge_issue_refs_from_pr_json <pr-json>}
  {
    printf '%s' "$meta" | jq -r '.closingIssuesReferences[]?.number // empty' 2>/dev/null || true
    printf '%s' "$meta" | jq -r '(.title // "") + "\n" + (.body // "")' 2>/dev/null \
      | grep -Ei '\b(close[sd]?|fix(e[sd])?|resolve[sd]?)\b' \
      | grep -Eo '#[0-9]+' \
      | tr -d '#' || true
  } | awk 'NF && !seen[$0]++'
}

post_merge_issue_close_comment() {
  local issue=${1:?usage: post_merge_issue_close_comment <issue> <pr-json> <repo-default>}
  local meta=${2:?usage: post_merge_issue_close_comment <issue> <pr-json> <repo-default>}
  local repo_default=${3:?usage: post_merge_issue_close_comment <issue> <pr-json> <repo-default>}
  local pr_number pr_url base_ref merged_at merge_commit title

  pr_number=$(printf '%s' "$meta" | jq -r '.number // "'"$PR"'"')
  pr_url=$(printf '%s' "$meta" | jq -r '.url // ""')
  base_ref=$(printf '%s' "$meta" | jq -r '.baseRefName // ""')
  merged_at=$(printf '%s' "$meta" | jq -r '.mergedAt // ""')
  merge_commit=$(printf '%s' "$meta" | jq -r '.mergeCommit.oid // ""')
  title=$(printf '%s' "$meta" | jq -r '.title // ""')

  cat <<EOF
Closed by PR #${pr_number} merged into ${base_ref}; repository default branch is ${repo_default}, so GitHub did not auto-close this closing keyword reference.

Evidence:
- PR: #${pr_number} ${pr_url}
- PR title: ${title}
- Linked issue: #${issue}
- Merged at: ${merged_at:-unknown}
- Merge commit: ${merge_commit:-unknown}
EOF
}

post_merge_fetch_issue_body() {
  local issue=${1:?usage: post_merge_fetch_issue_body <issue>}
  run_timeout env GH_CONFIG_DIR="$GH_CONFIG_DIR" gh issue view "$issue" \
    --repo "$GH_REPO" --json body 2>/dev/null \
    | jq -r '.body // empty' 2>/dev/null || true
}

post_merge_reconcile_issues() {
  local meta=${1:?usage: post_merge_reconcile_issues <pr-json>}
  post_merge_issue_reconcile_enabled || return 0

  local repo_default base_ref issues issue comment close_rc close_action
  local pr_body issue_body gate_outcome gate_reason
  base_ref=$(printf '%s' "$meta" | jq -r '.baseRefName // empty')
  pr_body=$(printf '%s' "$meta" | jq -r '.body // empty')
  repo_default=$(post_merge_repo_default_branch || true)
  repo_default=${repo_default:-$DEFAULT_BRANCH}

  if [ -z "$base_ref" ] || [ "$base_ref" = "$repo_default" ]; then
    audit "POST_MERGE_CLEANUP issue_reconcile skipped base=${base_ref:-unknown} repo_default=${repo_default} reason=default-branch-merge"
    return 0
  fi

  issues=$(post_merge_issue_refs_from_pr_json "$meta")
  if [ -z "$issues" ]; then
    audit "POST_MERGE_CLEANUP issue_reconcile none base=${base_ref} repo_default=${repo_default}"
    return 0
  fi

  while IFS= read -r issue; do
    [ -n "$issue" ] || continue

    # #723 closure_acceptance_gate: refuse to propagate close when the source
    # issue carries UAT-style DoD bullets and the PR body lacks an acceptance
    # proof block, an operator-authorized trailer, or a scaffold-declared
    # retarget to a follow-up. Surface CLOSURE_REFUSED for operator review.
    issue_body=$(post_merge_fetch_issue_body "$issue")
    gate_outcome=$(closure_acceptance_classify "$pr_body" "$issue_body" "$issue")
    if ! closure_acceptance_should_close "$gate_outcome"; then
      gate_reason=$(closure_acceptance_refusal_reason "$gate_outcome")
      add_record "" "" "issue_reconcile" "blocked" "closure_refused" \
        "issue=#${issue} base=${base_ref} repo_default=${repo_default} outcome=${gate_outcome} reason=${gate_reason}"
      audit "POST_MERGE_CLEANUP CLOSURE_REFUSED issue=#${issue} pr=#${PR} outcome=${gate_outcome} reason=${gate_reason} base=${base_ref} repo_default=${repo_default}"
      continue
    fi
    audit "POST_MERGE_CLEANUP CLOSURE_GATE pass issue=#${issue} pr=#${PR} outcome=${gate_outcome} base=${base_ref} repo_default=${repo_default}"

    comment=$(post_merge_issue_close_comment "$issue" "$meta" "$repo_default")
    if dry_run_enabled; then
      close_action=close
      dry_note gh issue "$close_action" "$issue" --repo "$GH_REPO" --reason completed --comment "$comment"
      add_record "" "" "issue_reconcile" "dry_run" "would_close" \
        "issue=#${issue} base=${base_ref} repo_default=${repo_default}"
      audit "POST_MERGE_CLEANUP issue_reconcile dry_run issue=#${issue} base=${base_ref} repo_default=${repo_default}"
      continue
    fi

    close_rc=0
    (
      export GH_CONFIG_DIR
      external_pr_mutation_run "post_merge_cleanup:issue_close:#${issue}" -- \
        issue close "$issue" --repo "$GH_REPO" --reason completed --comment "$comment" >/dev/null
    ) || close_rc=$?

    if [ "$close_rc" -eq 0 ]; then
      add_record "" "" "issue_reconcile" "ok" "closed" \
        "issue=#${issue} base=${base_ref} repo_default=${repo_default}"
      audit "POST_MERGE_CLEANUP issue_reconcile closed issue=#${issue} base=${base_ref} repo_default=${repo_default}"
    else
      add_record "" "" "issue_reconcile" "blocked" "issue_close_failed" \
        "issue=#${issue} base=${base_ref} repo_default=${repo_default} rc=${close_rc}"
      audit "POST_MERGE_CLEANUP issue_reconcile close_failed issue=#${issue} base=${base_ref} repo_default=${repo_default} rc=${close_rc}"
    fi
  done <<< "$issues"
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

# #501: Supervisor mirror detection.
#
# Integration/supervisor work repos can hold a foreign agent's branch after
# an integration mirror. Inventory-based cleanup must NOT treat such a mirror
# as the assignment owner: only the dispatched owner (via the assignments
# registry) is responsible for the PR branch, unless an explicit mirror
# mapping is declared (assignment.workdir resolving to the mirror path).
#
# Configuration (project profile):
#   SUPERVISOR_REPO          single supervisor/integration workdir path
#   SUPERVISOR_MIRROR_REPOS  optional bash array of additional mirror paths
post_merge_supervisor_mirror_paths() {
  local entry resolved
  if [[ -n "${SUPERVISOR_REPO:-}" ]]; then
    resolved=$(cd "$SUPERVISOR_REPO" 2>/dev/null && pwd -P || printf '%s' "$SUPERVISOR_REPO")
    [[ -n "$resolved" ]] && printf '%s\n' "${resolved%/}"
  fi
  if declare -p SUPERVISOR_MIRROR_REPOS >/dev/null 2>&1; then
    for entry in "${SUPERVISOR_MIRROR_REPOS[@]}"; do
      [[ -n "$entry" ]] || continue
      resolved=$(cd "$entry" 2>/dev/null && pwd -P || printf '%s' "$entry")
      [[ -n "$resolved" ]] && printf '%s\n' "${resolved%/}"
    done
  fi
}

post_merge_workdir_is_supervisor_mirror() {
  local workdir=${1:-}
  local mirror workdir_real
  [[ -n "$workdir" ]] || return 1
  workdir_real=$(cd "$workdir" 2>/dev/null && pwd -P || printf '%s' "$workdir")
  workdir_real="${workdir_real%/}"
  while IFS= read -r mirror; do
    [[ -n "$mirror" ]] || continue
    [[ "$workdir_real" == "$mirror" ]] && return 0
  done < <(post_merge_supervisor_mirror_paths)
  return 1
}

post_merge_assignment_owns_workdir() {
  local agent=${1:?usage: post_merge_assignment_owns_workdir <agent> <branch> <workdir>}
  local branch=${2:?usage: post_merge_assignment_owns_workdir <agent> <branch> <workdir>}
  local workdir=${3:?usage: post_merge_assignment_owns_workdir <agent> <branch> <workdir>}
  local assigned assigned_real workdir_real
  assigned=$(state_get assignments | jq -r \
    --arg agent "$agent" --arg branch "$branch" '
      .[$agent]
      | select((.branch // "") == $branch)
      | (.workdir // .repo_root // "")
    ' 2>/dev/null || true)
  [[ -n "$assigned" ]] || return 1
  assigned_real=$(cd "$assigned" 2>/dev/null && pwd -P || printf '%s' "$assigned")
  workdir_real=$(cd "$workdir" 2>/dev/null && pwd -P || printf '%s' "$workdir")
  [[ "${assigned_real%/}" == "${workdir_real%/}" ]]
}

clear_assignment() {
  local agent=${1:?usage: clear_assignment <agent>}
  local target lock tmp
  target=$(state_file assignments.json)
  lock="${target}.lock"
  tmp="${target}.tmp.$$"

  if dry_run_enabled; then
    printf 'DRY-RUN: state_update assignments del(.%s)\n' "$agent" >&2
    printf 'DRY-RUN: dispatch_capacity_release_scope_claim %s\n' "$agent" >&2
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

  # Release the matching scope claim (#721 sub-A) so subsequent
  # dispatch_plan / brief_agents calls can reuse the freed files. No-op
  # when the helper is absent or the agent has no recorded claim.
  if declare -F dispatch_capacity_release_scope_claim >/dev/null 2>&1; then
    dispatch_capacity_release_scope_claim "$agent" || true
    audit "POST_MERGE_CLEANUP scope_claim_released agent=${agent} pr=#${PR}"
  fi
}

default_branch_holder() {
  local workdir=${1:?usage: default_branch_holder <workdir>}
  local current_abs record_worktree="" record_branch="" holder_abs line

  current_abs=$(cd "$workdir" 2>/dev/null && pwd -P || printf '%s\n' "$workdir")
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$line" ]; then
      if [ "$record_branch" = "refs/heads/$DEFAULT_BRANCH" ] && [ -n "$record_worktree" ]; then
        holder_abs=$(cd "$record_worktree" 2>/dev/null && pwd -P || printf '%s\n' "$record_worktree")
        if [ "$holder_abs" != "$current_abs" ]; then
          printf '%s\n' "$record_worktree"
          return 0
        fi
      fi
      record_worktree=""
      record_branch=""
      continue
    fi

    case "$line" in
      worktree\ *) record_worktree=${line#worktree } ;;
      branch\ *) record_branch=${line#branch } ;;
    esac
  done < <({ run_timeout git -C "$workdir" worktree list --porcelain 2>/dev/null || true; printf '\n'; })

  return 1
}

finish_cleanup() {
  local agent=${1:?usage: finish_cleanup <agent> <workdir> <source> <merged-branch> <current-branch> [extra-detail]}
  local workdir=${2:?usage: finish_cleanup <agent> <workdir> <source> <merged-branch> <current-branch> [extra-detail]}
  local source=${3:?usage: finish_cleanup <agent> <workdir> <source> <merged-branch> <current-branch> [extra-detail]}
  local merged_branch=${4:?usage: finish_cleanup <agent> <workdir> <source> <merged-branch> <current-branch> [extra-detail]}
  local current_branch=${5:?usage: finish_cleanup <agent> <workdir> <source> <merged-branch> <current-branch> [extra-detail]}
  local extra_detail=${6:-}
  local assignment_cleared=0 detail

  if assignment_has_label "$agent"; then
    clear_assignment "$agent"
    assignment_cleared=1
  fi

  detail="source=$source from_branch=$current_branch default_branch=$DEFAULT_BRANCH assignment_cleared=$assignment_cleared"
  if [ -n "$extra_detail" ]; then
    detail="$detail $extra_detail"
  fi
  add_record "$agent" "$workdir" "cleanup" "ok" "" "$detail"
  audit "POST_MERGE_CLEANUP agent=${agent} pr=#${PR} branch=${merged_branch} workdir=${workdir} action=cleanup status=ok assignment_cleared=${assignment_cleared}"
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
  local current_branch dirty cleanup_rc holder holder_branch holder_dirty

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

  holder=""
  if [ "$current_branch" != "$DEFAULT_BRANCH" ] && ! is_linked_worktree "$workdir"; then
    holder=$(default_branch_holder "$workdir" || true)
    if [ -n "$holder" ]; then
      holder_branch=$(git_value "$holder" branch --show-current)
      holder_dirty=$(git_value "$holder" status --porcelain | wc -l | tr -d ' ')
      if [ "${holder_dirty:-0}" != "0" ]; then
        add_record "$agent" "$workdir" "skip" "blocked" "stale_dirty_default_branch_holder" \
          "source=$source current_branch=$current_branch default_branch=$DEFAULT_BRANCH holder=$holder holder_branch=$holder_branch holder_dirty=$holder_dirty recovery=preserve_archive_or_recover proof=recovery_context_capture"
        return 0
      fi

      if [ "$FETCH" -eq 1 ]; then
        if ! git_mutate "$workdir" fetch origin "$DEFAULT_BRANCH"; then
          add_record "$agent" "$workdir" "skip" "blocked" "switch_or_pull_failed" \
            "source=$source default_branch=$DEFAULT_BRANCH"
          return 0
        fi
      fi
      if ! git_quiet "$workdir" rev-parse --verify "origin/$DEFAULT_BRANCH"; then
        add_record "$agent" "$workdir" "skip" "blocked" "missing_origin_default" \
          "source=$source default_branch=$DEFAULT_BRANCH"
        return 0
      fi

      add_record "$agent" "$workdir" "warning" "ok" "stale_main_holder" \
        "source=$source default_branch=$DEFAULT_BRANCH holder=$holder"
      finish_cleanup "$agent" "$workdir" "$source" "$merged_branch" "$current_branch" \
        "default_checkout=skipped_default_branch_in_use holder=$holder"
      return 0
    fi
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

  finish_cleanup "$agent" "$workdir" "$source" "$merged_branch" "$current_branch"
}

pr_json=$(run_timeout env GH_CONFIG_DIR="$GH_CONFIG_DIR" gh pr view "$PR" \
  --repo "$GH_REPO" \
  --json number,title,body,url,state,headRefName,headRefOid,baseRefName,mergedAt,mergeCommit,closingIssuesReferences 2>/dev/null || printf '{}')

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

post_merge_reconcile_issues "$pr_json"

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
    # #501: Skip supervisor/integration mirrors that happen to hold the
    # merged branch checked out. Cleanup must only touch the assignment
    # owner. If the agent has an explicit assignment for this branch that
    # points to the mirror, the earlier assignment-driven loop has already
    # queued the candidate, so we still skip here without losing coverage.
    if post_merge_workdir_is_supervisor_mirror "$workdir" \
      && ! post_merge_assignment_owns_workdir "$label" "$head_branch" "$workdir"; then
      add_record "$label" "$workdir" "skip" "not_applicable" "supervisor_mirror" \
        "source=inventory branch=$head_branch"
      audit "POST_MERGE_CLEANUP supervisor_mirror_skip agent=${label} pr=#${PR} branch=${head_branch} workdir=${workdir}"
      continue
    fi
    printf '%s\t%s\t%s\n' "$label" "$workdir" "inventory" >> "$candidate_file"
  fi
done < <(agent_inventory_entries || true)

# Issue #643: live tmux pane cwd as a third candidate source. In profiles
# where `agent_inventory_entries` resolves every workdir to an orchestrator
# parent path (not the per-agent worktree), the inventory branch check never
# matches the merged head_branch and cleanup emits `no_matching_worktree`
# even when `agent_pool_status.sh` shows the pane parked on that branch.
# `tmux_pane_current_path` is the same #{pane_current_path} read used by
# `agent_pool_status.sh` to derive `live_pane_cwd`. Existing safety gates
# (clean-worktree, branch match, holder checks) still apply via
# cleanup_candidate, so this only expands discovery, not destructive scope.
while IFS='|' read -r label pane workdir; do
  if [ -z "$label" ] || [ -z "$pane" ]; then
    continue
  fi
  live_path=$(tmux_pane_current_path "$pane" 2>/dev/null || true)
  [ -n "$live_path" ] || continue
  [ "$live_path" != "$workdir" ] || continue
  is_git_worktree "$live_path" || continue
  branch=$(git_value "$live_path" branch --show-current)
  if [ "$branch" = "$head_branch" ]; then
    printf '%s\t%s\t%s\n' "$label" "$live_path" "live_pane" >> "$candidate_file"
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
