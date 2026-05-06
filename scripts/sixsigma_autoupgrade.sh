#!/usr/bin/env bash
# scripts/sixsigma_autoupgrade.sh — self-improvement/autofix loop for any agent pool.
#
# Usage:
#   sixsigma_autoupgrade.sh <project_short|config_path> [--dry-run]
#
# Doctrine:
#   - Observe the whole pool without pane captures.
#   - Map each open PR branch to its owning agent workdir.
#   - Dispatch CI autofix only for failed checks, with retry caps inherited
#     from ci_autofix.sh.
#   - Never merge, never bypass CI, and never assume a specific model/vendor.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/dry_run.sh"
source "$TK/lib/config_resolver.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

CFG_ARG=${1:?usage: sixsigma_autoupgrade.sh <project> [--dry-run]}
shift
[ "$#" -eq 0 ] || { echo "unknown args: $*" >&2; exit 2; }

load_project_config "$CFG_ARG"

source "$TK/lib/audit_log.sh"
source "$TK/lib/agent_inventory.sh"

: "${GH_REPO:?}" "${GH_CONFIG_DIR:?}" "${DEFAULT_BRANCH:=main}"
: "${SIXSIGMA_MAX_AUTOFIX_DISPATCHES:=4}"
: "${SIXSIGMA_INCLUDE_DRAFTS:=0}"
: "${SIXSIGMA_AGENT_CAN_PUSH:=1}"
: "${SIXSIGMA_RUN_POOL_SNAPSHOT:=1}"
: "${SIXSIGMA_BASE_FETCH:=1}"
: "${SIXSIGMA_RUN_PR_SIGNALS:=1}"

branch_owner() {
  local branch=${1:?usage: branch_owner <branch>}
  local label pane workdir current
  while IFS='|' read -r label pane workdir; do
    [ -d "$workdir/.git" ] || continue
    current=$(timeout 5s git -C "$workdir" branch --show-current 2>/dev/null || true)
    if [ "$current" = "$branch" ]; then
      printf '%s\n' "$label"
      return 0
    fi
  done < <(agent_inventory_entries)
  return 1
}

branch_owner_workdir() {
  local branch=${1:?usage: branch_owner_workdir <branch>}
  local label pane workdir current
  while IFS='|' read -r label pane workdir; do
    [ -d "$workdir/.git" ] || continue
    current=$(timeout 5s git -C "$workdir" branch --show-current 2>/dev/null || true)
    if [ "$current" = "$branch" ]; then
      printf '%s|%s\n' "$label" "$workdir"
      return 0
    fi
  done < <(agent_inventory_entries)
  return 1
}

branch_needs_rebase() {
  local workdir=${1:?usage: branch_needs_rebase <workdir>}
  [ -d "$workdir/.git" ] || return 1
  if [ "$SIXSIGMA_BASE_FETCH" = "1" ]; then
    timeout 10s git -C "$workdir" fetch origin "$DEFAULT_BRANCH" >/dev/null 2>&1 || true
  fi
  timeout 5s git -C "$workdir" rev-parse --verify "origin/$DEFAULT_BRANCH" >/dev/null 2>&1 || return 1
  ! timeout 5s git -C "$workdir" merge-base --is-ancestor "origin/$DEFAULT_BRANCH" HEAD >/dev/null 2>&1
}

if [ "$SIXSIGMA_RUN_POOL_SNAPSHOT" = "1" ]; then
  if dry_run_enabled; then
    dry_run_note "agent_pool_status $CFG_ARG --tsv"
  else
    bash "$TK/scripts/agent_pool_status.sh" "$CFG_ARG" --tsv >/dev/null || \
      audit "SIXSIGMA pool snapshot failed project=$PROJECT"
  fi
fi

if [ "$SIXSIGMA_RUN_PR_SIGNALS" = "1" ]; then
  if dry_run_enabled; then
    dry_run_note "pr_block_signals $CFG_ARG --tsv"
  else
    while IFS= read -r signal_line; do
      [ -n "$signal_line" ] || continue
      audit "SIXSIGMA_PR_SIGNAL ${signal_line}"
    done < <(bash "$TK/scripts/pr_block_signals.sh" "$CFG_ARG" --tsv \
      | awk -F '\t' 'NR > 1 && $NF != "" { gsub(/\t/, " "); print }' || true)
  fi
fi

prs_json=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh pr list \
  --repo "$GH_REPO" \
  --base "$DEFAULT_BRANCH" \
  --state open \
  --limit 100 \
  --json number,headRefName,isDraft,mergeStateStatus,statusCheckRollup 2>/dev/null)

dispatches=0
while IFS='|' read -r pr branch is_draft merge_state failed_count pending_count; do
  [ -n "$pr" ] || continue

  if [ "$is_draft" = "true" ] && [ "$SIXSIGMA_INCLUDE_DRAFTS" != "1" ]; then
    audit "SIXSIGMA skip pr=$pr branch=$branch reason=draft"
    continue
  fi

  if [ "${failed_count:-0}" -eq 0 ] && [ "$merge_state" != "BEHIND" ]; then
    audit "SIXSIGMA observe pr=$pr branch=$branch failed=0 pending=${pending_count:-0} state=$merge_state"
    continue
  fi

  owner_entry=$(branch_owner_workdir "$branch" || true)
  agent=${owner_entry%%|*}
  workdir=${owner_entry#*|}
  if [ -z "$agent" ]; then
    audit "SIXSIGMA skip pr=$pr branch=$branch reason=no-agent-owner failed=$failed_count state=$merge_state"
    continue
  fi

  if [ "$merge_state" = "BEHIND" ] || branch_needs_rebase "$workdir"; then
    audit "SIXSIGMA rebase-needed pr=$pr branch=$branch agent=$agent state=$merge_state reason=base-drift default=$DEFAULT_BRANCH"
  fi

  if [ "${failed_count:-0}" -eq 0 ]; then
    continue
  fi

  if [ "$dispatches" -ge "$SIXSIGMA_MAX_AUTOFIX_DISPATCHES" ]; then
    audit "SIXSIGMA dispatch cap reached max=$SIXSIGMA_MAX_AUTOFIX_DISPATCHES"
    break
  fi

  audit "SIXSIGMA autofix pr=$pr branch=$branch agent=$agent failed=$failed_count pending=$pending_count"
  args=("$CFG_ARG" "$pr" "$agent")
  if dry_run_enabled; then
    args+=(--dry-run)
  fi
  CI_AUTOFIX_AGENT_CAN_PUSH="$SIXSIGMA_AGENT_CAN_PUSH" \
    bash "$TK/scripts/ci_autofix.sh" "${args[@]}"
  dispatches=$((dispatches + 1))
done < <(
  printf '%s' "$prs_json" | jq -r '
    .[]
    | [
        .number,
        .headRefName,
        (.isDraft // false),
        (.mergeStateStatus // ""),
        ([.statusCheckRollup[]? | select((.conclusion // "") as $c | ["FAILURE","TIMED_OUT","CANCELLED","ACTION_REQUIRED","STARTUP_FAILURE"] | index($c))] | length),
        ([.statusCheckRollup[]? | select((.status // "") as $s | ["QUEUED","IN_PROGRESS","REQUESTED","WAITING","PENDING"] | index($s))] | length)
      ]
    | @tsv
  ' | tr '\t' '|'
)

audit "SIXSIGMA end project=$PROJECT dispatches=$dispatches"
