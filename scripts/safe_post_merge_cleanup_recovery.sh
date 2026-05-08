#!/usr/bin/env bash
# scripts/safe_post_merge_cleanup_recovery.sh — non-destructive recovery
# for ORDO bootstrap recursion (#374).
#
# When the orchestrator's readiness recursion stalls because clean
# workdirs are still parked on already-merged branches, ORDO must
# attempt this audited recovery path BEFORE escalating to operator
# intervention. The script encodes the four-condition gate from
# the issue's "required normal behavior":
#
#   1. target PR is already merged,
#   2. workdir dirty count is zero,
#   3. no rebase / merge / cherry-pick operation markers exist,
#   4. `post_merge_cleanup --dry-run` reports cleanup would be safe.
#
# When all four hold, the script runs the live cleanup. Otherwise
# it records `operator_intervention_required` with a structured
# block_reason. After every project's candidates are processed, the
# script (when --apply) runs `portfolio_session_start --apply` so
# the deterministic safe remediations (default-branch fast-forward,
# identity setup) land in the same audited window.
#
# Usage:
#   safe_post_merge_cleanup_recovery.sh <portfolio-config>
#       [--tsv|--json]                 (default: tsv)
#       [--dry-run]                    (no live cleanup, no session_start
#                                       --apply; just report the gate)
#       [--apply]                      (run live cleanup AND
#                                       portfolio_session_start --apply;
#                                       this is the explicit opt-in)
#       [--no-session-start]           (skip the session_start step even
#                                       when --apply is set)
#
# Exit codes:
#   0  — every candidate either applied cleanup successfully OR was
#        non-applicable (PR not merged, no assignment) and no candidate
#        required operator intervention. Including the "no candidates"
#        case (decision=no_candidates).
#   10 — at least one candidate was attempted but blocked, requiring
#        operator intervention (decision=operator_intervention_required).
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/portfolio_config.sh"

PORTFOLIO_ARG=${1:?usage: safe_post_merge_cleanup_recovery.sh <portfolio-config> [--tsv|--json] [--dry-run|--apply] [--no-session-start]}
FORMAT="tsv"
APPLY_MODE=0
SKIP_SESSION_START=0
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tsv) FORMAT="tsv" ;;
    --json) FORMAT="json" ;;
    --dry-run) APPLY_MODE=0 ;;
    --apply) APPLY_MODE=1 ;;
    --no-session-start) SKIP_SESSION_START=1 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

load_portfolio_config "$PORTFOLIO_ARG"

# audit() needs PROJECT to be set; we override it per project below.
PROJECT="_safe_pmc_recovery"
ORCH_LOG_DIR="${ORCH_LOG_DIR:-/var/log/orch}"
: "${AGENT_WORKDIR_TEMPLATE:=__safe_pmc_recovery__}"
export AGENT_WORKDIR_TEMPLATE
# shellcheck source=lib/audit_log.sh
source "$TK/lib/audit_log.sh"

# Records collected across every project; emitted at the end as JSON
# or TSV.
candidates_json=()
operator_intervention_count=0
applied_count=0
attempted_count=0

add_candidate_record() {
  local project=$1 agent=$2 pr=$3 workdir=$4 action=$5 \
    applied=$6 block_reason=$7 detail=$8
  candidates_json+=("$(jq -nc \
    --arg project "$project" \
    --arg agent "$agent" \
    --arg pr "$pr" \
    --arg workdir "$workdir" \
    --arg action "$action" \
    --arg applied "$applied" \
    --arg block_reason "$block_reason" \
    --arg detail "$detail" \
    '{
      project: $project,
      agent: $agent,
      pr: ($pr | tonumber? // null),
      workdir: $workdir,
      action: $action,
      applied: ($applied == "true"),
      block_reason: (if $block_reason == "" then null else $block_reason end),
      detail: $detail
    }')")
}

# Detect rebase / merge / cherry-pick / bisect operation markers in a
# git workdir. Each of these implies a partially-completed git
# operation; cleanup MUST refuse such workdirs even when they look
# clean otherwise (the working tree is technically clean but
# the .git/ state is mid-flight).
operation_marker_present() {
  local workdir=$1
  local marker
  for marker in MERGE_HEAD REBASE_HEAD CHERRY_PICK_HEAD BISECT_LOG; do
    if [ -e "$workdir/.git/$marker" ]; then
      printf '%s' "$marker"
      return 0
    fi
  done
  for dir in rebase-merge rebase-apply; do
    if [ -d "$workdir/.git/$dir" ]; then
      printf '%s' "$dir"
      return 0
    fi
  done
  printf ''
  return 1
}

# Probe the PR's current state via gh. Echoes one of:
#   merged | not_merged | unknown
gh_pr_state() {
  local pr=$1
  local repo=$2
  local payload
  payload=$(GH_CONFIG_DIR="${GH_CONFIG_DIR:-}" gh pr view "$pr" \
    --repo "$repo" \
    --json state,mergedAt 2>/dev/null || printf '{}')
  local state merged_at
  state=$(printf '%s' "$payload" | jq -r '.state // "UNKNOWN"')
  merged_at=$(printf '%s' "$payload" | jq -r '.mergedAt // ""')
  if [ "$state" = "MERGED" ] || [ -n "$merged_at" ]; then
    printf 'merged'
    return 0
  fi
  if [ "$state" = "OPEN" ] || [ "$state" = "CLOSED" ]; then
    printf 'not_merged'
    return 0
  fi
  printf 'unknown'
}

# Run post_merge_cleanup --dry-run for one project + PR; return its
# JSON output. Empty array on failure.
post_merge_cleanup_dry_run() {
  local cfg=$1 pr=$2
  local out
  out=$(bash "$TK/scripts/post_merge_cleanup.sh" "$cfg" "$pr" --json --dry-run 2>/dev/null || printf '[]')
  if printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf '%s' "$out"
  else
    printf '[]'
  fi
}

# All records in a dry-run output must have action=cleanup AND
# status=ok for the live cleanup to be safe. A "skip status=blocked"
# record means at least one candidate is dirty / on a wrong branch /
# missing origin; we do not run live cleanup in that case.
dry_run_is_all_ok() {
  local payload=$1
  local agent=$2
  local matched_count
  matched_count=$(jq --arg agent "$agent" \
    '[.[]? | select(.agent == $agent and .action == "cleanup" and .status == "ok")] | length' \
    <<< "$payload")
  [ "${matched_count:-0}" -ge 1 ]
}

# Main loop. For each project in the portfolio, scan its
# assignments.json for agents whose ticket is a numeric PR number.
process_project() {
  local alias=$1 cfg=$2
  local project_name assignments_path assignments_json agent_count

  # Resolve the project's PROJECT name + GH_REPO via a sub-shell so we
  # do not pollute the global env with a project's GH_REPO etc.
  project_name=$(bash -c '
    set -euo pipefail
    cfg=$1
    # shellcheck disable=SC1090
    source "$cfg"
    printf "%s" "${PROJECT:-}"
  ' _ "$cfg")

  if [ -z "$project_name" ]; then
    return 0
  fi

  assignments_path="${ORCH_STATE_BASE:-${XDG_DATA_HOME:-$HOME/.local/share}/orch-state}/$project_name/assignments.json"
  if [ ! -s "$assignments_path" ]; then
    return 0
  fi
  assignments_json=$(cat "$assignments_path" 2>/dev/null || printf '{}')

  agent_count=$(printf '%s' "$assignments_json" | jq -r 'keys | length' 2>/dev/null || printf 0)
  if [ "${agent_count:-0}" -eq 0 ]; then
    return 0
  fi

  # Read GH_REPO + GH_CONFIG_DIR from the project's config.
  local repo gh_config_dir
  repo=$(bash -c '
    set -euo pipefail
    cfg=$1
    # shellcheck disable=SC1090
    source "$cfg"
    printf "%s" "${GH_REPO:-}"
  ' _ "$cfg")
  gh_config_dir=$(bash -c '
    set -euo pipefail
    cfg=$1
    # shellcheck disable=SC1090
    source "$cfg"
    printf "%s" "${GH_CONFIG_DIR:-}"
  ' _ "$cfg")
  GH_CONFIG_DIR="$gh_config_dir"

  while IFS=$'\t' read -r agent pr workdir; do
    [ -n "$agent" ] || continue
    [[ "$pr" =~ ^[0-9]+$ ]] || continue
    [ -n "$workdir" ] || continue

    PROJECT="$project_name"
    audit "SAFE_POST_MERGE_CLEANUP_ATTEMPTED project=${alias} agent=${agent} pr=#${pr} workdir=${workdir}"
    attempted_count=$((attempted_count + 1))

    # Gate condition 1: PR merged.
    local state
    state=$(gh_pr_state "$pr" "$repo")
    if [ "$state" != "merged" ]; then
      add_candidate_record "$alias" "$agent" "$pr" "$workdir" \
        "skip" "false" "pr_not_merged" "state=${state}"
      audit "SAFE_POST_MERGE_CLEANUP_SKIP project=${alias} agent=${agent} pr=#${pr} reason=pr_not_merged state=${state}"
      continue
    fi

    # Gate condition 2: workdir clean (we re-check here even though
    # post_merge_cleanup --dry-run also does, so the audit line names
    # the precise blocker close to the gate).
    if [ ! -d "$workdir/.git" ]; then
      add_candidate_record "$alias" "$agent" "$pr" "$workdir" \
        "operator_intervention_required" "false" "not_git_repo" \
        "workdir is not a git checkout"
      operator_intervention_count=$((operator_intervention_count + 1))
      audit "OPERATOR_INTERVENTION_REQUIRED project=${alias} agent=${agent} pr=#${pr} reason=not_git_repo"
      continue
    fi
    local dirty
    dirty=$(git -C "$workdir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [ "${dirty:-0}" != "0" ]; then
      add_candidate_record "$alias" "$agent" "$pr" "$workdir" \
        "operator_intervention_required" "false" "dirty_worktree" \
        "dirty=${dirty}"
      operator_intervention_count=$((operator_intervention_count + 1))
      audit "OPERATOR_INTERVENTION_REQUIRED project=${alias} agent=${agent} pr=#${pr} reason=dirty_worktree dirty=${dirty}"
      continue
    fi

    # Gate condition 3: no in-flight git operation markers.
    local marker
    marker=$(operation_marker_present "$workdir" || true)
    if [ -n "$marker" ]; then
      add_candidate_record "$alias" "$agent" "$pr" "$workdir" \
        "operator_intervention_required" "false" "operation_marker_present" \
        "marker=${marker}"
      operator_intervention_count=$((operator_intervention_count + 1))
      audit "OPERATOR_INTERVENTION_REQUIRED project=${alias} agent=${agent} pr=#${pr} reason=operation_marker_present marker=${marker}"
      continue
    fi

    # Gate condition 4: post_merge_cleanup --dry-run reports cleanup
    # would be safe for this agent.
    local dry_run_payload
    dry_run_payload=$(post_merge_cleanup_dry_run "$cfg" "$pr")
    if ! dry_run_is_all_ok "$dry_run_payload" "$agent"; then
      local dry_run_reason
      dry_run_reason=$(jq -r --arg agent "$agent" \
        '[.[]? | select(.agent == $agent)][0].reason // "dry_run_no_match"' \
        <<< "$dry_run_payload")
      add_candidate_record "$alias" "$agent" "$pr" "$workdir" \
        "operator_intervention_required" "false" "dry_run_blocked" \
        "dry_run_reason=${dry_run_reason}"
      operator_intervention_count=$((operator_intervention_count + 1))
      audit "OPERATOR_INTERVENTION_REQUIRED project=${alias} agent=${agent} pr=#${pr} reason=dry_run_blocked dry_run_reason=${dry_run_reason}"
      continue
    fi

    # All four gate conditions hold. Apply live cleanup if requested.
    if [ "$APPLY_MODE" -eq 1 ]; then
      if bash "$TK/scripts/post_merge_cleanup.sh" "$cfg" "$pr" --json >/dev/null 2>&1; then
        add_candidate_record "$alias" "$agent" "$pr" "$workdir" \
          "safe_post_merge_cleanup_applied" "true" "" \
          "all gate conditions held; live cleanup ran"
        applied_count=$((applied_count + 1))
        audit "SAFE_POST_MERGE_CLEANUP_APPLIED project=${alias} agent=${agent} pr=#${pr} workdir=${workdir}"
      else
        add_candidate_record "$alias" "$agent" "$pr" "$workdir" \
          "operator_intervention_required" "false" "live_cleanup_failed" \
          "live cleanup returned non-zero despite dry-run-ok"
        operator_intervention_count=$((operator_intervention_count + 1))
        audit "OPERATOR_INTERVENTION_REQUIRED project=${alias} agent=${agent} pr=#${pr} reason=live_cleanup_failed"
      fi
    else
      add_candidate_record "$alias" "$agent" "$pr" "$workdir" \
        "safe_post_merge_cleanup_attempted" "false" "" \
        "dry-run mode; all gate conditions held; live cleanup NOT executed"
      audit "SAFE_POST_MERGE_CLEANUP_DRY_RUN_OK project=${alias} agent=${agent} pr=#${pr} workdir=${workdir}"
    fi
  done < <(printf '%s' "$assignments_json" | jq -r '
    to_entries[]
    | select(.value.issue != null or .value.ticket != null)
    | [.key, ((.value.ticket // .value.issue) | tostring), (.value.workdir // "")]
    | @tsv
  ')
}

while IFS='|' read -r alias cfg; do
  [ -n "$alias" ] || continue
  process_project "$alias" "$cfg"
done < <(portfolio_project_entries)

# Optional portfolio_session_start --apply phase.
session_start_block='{}'
if [ "$APPLY_MODE" -eq 1 ] && [ "$SKIP_SESSION_START" -ne 1 ] && [ "$applied_count" -gt 0 ]; then
  if ss_out=$(bash "$TK/scripts/portfolio_session_start.sh" "$ORCH_PORTFOLIO_CONFIG_PATH" --apply --json 2>/dev/null); then
    if printf '%s' "$ss_out" | jq -e '.' >/dev/null 2>&1; then
      session_start_block="$ss_out"
    fi
    audit "SAFE_POST_MERGE_CLEANUP_SESSION_START_APPLIED applied=${applied_count}"
  else
    session_start_block='{"error":"session_start_failed"}'
    audit "SAFE_POST_MERGE_CLEANUP_SESSION_START_FAILED applied=${applied_count}"
  fi
fi

# Compute decision.
decision="no_candidates"
if [ "$attempted_count" -gt 0 ]; then
  if [ "$operator_intervention_count" -gt 0 ]; then
    decision="operator_intervention_required"
  elif [ "$APPLY_MODE" -eq 1 ] && [ "$applied_count" -gt 0 ]; then
    decision="safe_post_merge_cleanup_applied"
  else
    decision="safe_post_merge_cleanup_attempted"
  fi
fi

candidates_array='[]'
if [ "${#candidates_json[@]}" -gt 0 ]; then
  candidates_array=$(printf '%s\n' "${candidates_json[@]}" | jq -s '.')
fi

if [ "$FORMAT" = "json" ]; then
  jq -nc \
    --arg decision "$decision" \
    --arg apply "$([ "$APPLY_MODE" -eq 1 ] && printf 'true' || printf 'false')" \
    --argjson candidates "$candidates_array" \
    --argjson session_start "$session_start_block" \
    --arg attempted "$attempted_count" \
    --arg applied "$applied_count" \
    --arg intervention "$operator_intervention_count" \
    '{
      decision: $decision,
      apply: ($apply == "true"),
      candidates: $candidates,
      counts: {
        attempted: ($attempted | tonumber),
        applied: ($applied | tonumber),
        operator_intervention_required: ($intervention | tonumber)
      },
      session_start: $session_start
    }'
else
  printf 'decision\t%s\n' "$decision"
  printf 'apply\t%s\n' "$([ "$APPLY_MODE" -eq 1 ] && printf 'true' || printf 'false')"
  printf 'attempted\t%s\n' "$attempted_count"
  printf 'applied\t%s\n' "$applied_count"
  printf 'operator_intervention_required\t%s\n' "$operator_intervention_count"
  printf 'project\tagent\tpr\taction\tapplied\tblock_reason\tworkdir\tdetail\n'
  if [ "${#candidates_json[@]}" -gt 0 ]; then
    printf '%s\n' "${candidates_json[@]}" \
      | jq -r '. | [.project,.agent,.pr,.action,.applied,(.block_reason // ""),.workdir,.detail] | @tsv'
  fi
fi

if [ "$decision" = "operator_intervention_required" ]; then
  exit 10
fi
exit 0
