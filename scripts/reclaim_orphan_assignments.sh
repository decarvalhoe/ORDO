#!/usr/bin/env bash
# scripts/reclaim_orphan_assignments.sh — queue-resolver phase C.
#
# dispatch_plan marks an issue as `status="assigned"` whenever it carries a
# non-empty GitHub assignees list. When the assignee login does not map to
# any active fleet slot (AGENT_GH_LOGINS for the project profile), the row
# is excluded from --ready-only AND never gets reclaimed — it becomes
# invisible to dispatch forever. See issue #764.
#
# Usage:
#   reclaim_orphan_assignments.sh <project> [--dry-run|--apply]
#                                 [--threshold-hours N]
#                                 [--json|--tsv]
#
# Defaults: --dry-run, --tsv, threshold 24h (override via
# ORCH_RECLAIM_RECENT_THRESHOLD_HOURS env or --threshold-hours flag).
#
# Behavior:
#   - Reads `dispatch_plan.sh <project> --json` to find rows with
#     status=="assigned" and a non-empty assignees array.
#   - For every assignee login NOT present (case-insensitive) in the
#     active project's AGENT_GH_LOGINS, checks the issue's `updatedAt`
#     via `gh issue view`. If the issue has been touched in the last
#     `threshold_hours`, the orphan is reported but NOT reclaimed (the
#     assignee may be working in a parallel channel).
#   - In --apply mode, idle orphans are unassigned with
#     `gh issue edit --remove-assignee`. Each removal records:
#       RECLAIM_ORPHAN_ASSIGNMENT issue=#N removed_assignee=LOGIN reason=not_in_active_logins
#     A dry-run records the symmetric RECLAIM_ORPHAN_ASSIGNMENT_DRYRUN row
#     so an operator post-mortem can correlate the reclaim plan with the
#     subsequent apply.
#
# Exit codes:
#   0 — completed (no orphans reclaimed OR all reclaim attempts succeeded
#       OR --dry-run finished). The audit ledger holds the per-row detail.
#   2 — argument / usage error.
#   3 — gh CLI errors prevented at least one apply attempt; partial work
#       may have happened. Inspect the JSON/TSV output for `status=error`
#       rows.
set -euo pipefail
TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# shellcheck disable=SC1091
source "$TK/lib/config_resolver.sh"
# shellcheck disable=SC1091
source "$TK/lib/process_safety.sh"
source "$TK/lib/external_mutation_gate.sh"

usage() {
  cat >&2 <<'USAGE'
usage: reclaim_orphan_assignments.sh <project> [--dry-run|--apply]
                                     [--threshold-hours N]
                                     [--json|--tsv]
USAGE
  exit 2
}

PROJECT_ARG=${1:-}
[[ -n "$PROJECT_ARG" ]] || usage
shift

MODE="dry-run"
FORMAT="tsv"
THRESHOLD_HOURS_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    --apply)   MODE="apply"; shift ;;
    --json)    FORMAT="json"; shift ;;
    --tsv)     FORMAT="tsv"; shift ;;
    --threshold-hours)
      THRESHOLD_HOURS_OVERRIDE=${2:?--threshold-hours requires a value}
      shift 2
      ;;
    -h|--help) usage ;;
    *)
      printf 'unknown arg: %s\n' "$1" >&2
      usage
      ;;
  esac
done

load_project_config "$PROJECT_ARG"

# shellcheck disable=SC1091
source "$TK/lib/audit_log.sh"

threshold_hours=${THRESHOLD_HOURS_OVERRIDE:-${ORCH_RECLAIM_RECENT_THRESHOLD_HOURS:-24}}
if ! [[ "$threshold_hours" =~ ^[0-9]+$ ]]; then
  printf 'reclaim_orphan_assignments: invalid threshold value %q, falling back to 24\n' \
    "$threshold_hours" >&2
  threshold_hours=24
fi
threshold_seconds=$((threshold_hours * 3600))

# Active fleet logins for this project. Treated case-insensitively to match
# GitHub's login normalization. An empty set means every assignee is an
# orphan (the operator profile has not declared who the agents are).
declare -A active_logins=()
if [[ -n "${AGENT_GH_LOGINS+x}" && "${#AGENT_GH_LOGINS[@]}" -gt 0 ]]; then
  for entry in "${AGENT_GH_LOGINS[@]}"; do
    case "$entry" in
      *=*)    login_val=${entry#*=} ;;
      *'|'*)  login_val=${entry#*|} ;;
      *)      login_val=$entry ;;
    esac
    [[ -n "$login_val" ]] || continue
    active_logins["${login_val,,}"]=1
  done
fi

gh_timeout_sec=${ORCH_RECLAIM_GH_TIMEOUT_SEC:-30}

run_gh() {
  if [[ -n "${GH_CONFIG_DIR:-}" ]]; then
    orch_run_timeout "$gh_timeout_sec" env GH_CONFIG_DIR="$GH_CONFIG_DIR" gh "$@"
  else
    orch_run_timeout "$gh_timeout_sec" gh "$@"
  fi
}

dispatch_timeout_sec=${ORCH_RECLAIM_DISPATCH_TIMEOUT_SEC:-${ORDO_READY_QUEUE_TIMEOUT_SEC:-60}}
plan_json=$(orch_run_timeout "$dispatch_timeout_sec" \
  bash "$TK/scripts/dispatch_plan.sh" "$ORCH_CONFIG_PATH" --json 2>/dev/null || printf '[]')
if ! jq -e 'type == "array"' <<< "$plan_json" >/dev/null 2>&1; then
  plan_json='[]'
fi

mapfile -t assigned_rows < <(jq -c '.[]? | select(.status == "assigned" and ((.assignees // []) | length > 0))' <<< "$plan_json")

now_epoch=$(date -u +%s)
records=()
exit_code=0

emit_record() {
  records+=("$1")
}

for row in "${assigned_rows[@]}"; do
  issue=$(jq -r '.issue' <<< "$row")
  [[ -n "$issue" && "$issue" != "null" ]] || continue
  mapfile -t row_assignees < <(jq -r '.assignees[]?' <<< "$row")
  for assignee in "${row_assignees[@]}"; do
    [[ -n "$assignee" ]] || continue
    if [[ -n "${active_logins[${assignee,,}]:-}" ]]; then
      continue
    fi

    # Orphan candidate. Check recent activity via the issue's updatedAt
    # (rolled forward by every comment, label change, edit, etc.). When
    # gh refuses or returns an unparseable timestamp, we DO NOT reclaim:
    # the safe failure mode is to leave the assignment alone.
    updated_at=$(run_gh issue view "$issue" --repo "$GH_REPO" \
        --json updatedAt -q '.updatedAt' 2>/dev/null || printf '')
    if [[ -z "$updated_at" ]]; then
      emit_record "$(jq -nc \
        --arg issue "$issue" --arg login "$assignee" \
        '{issue:$issue,assignee:$login,status:"skipped",reason:"activity-lookup-failed"}')"
      continue
    fi
    updated_epoch=$(date -u -d "$updated_at" +%s 2>/dev/null || printf '')
    if [[ -z "$updated_epoch" ]]; then
      emit_record "$(jq -nc \
        --arg issue "$issue" --arg login "$assignee" \
        --arg updated "$updated_at" \
        '{issue:$issue,assignee:$login,status:"skipped",reason:"activity-parse-failed",updatedAt:$updated}')"
      continue
    fi
    age_seconds=$((now_epoch - updated_epoch))
    if (( age_seconds < threshold_seconds )); then
      emit_record "$(jq -nc \
        --arg issue "$issue" --arg login "$assignee" \
        --argjson age "$age_seconds" --argjson threshold "$threshold_seconds" \
        '{issue:$issue,assignee:$login,status:"skipped",reason:"recent-activity",age_seconds:$age,threshold_seconds:$threshold}')"
      continue
    fi

    if [[ "$MODE" == "apply" ]]; then
      # Required Rule 12 / authorization parity with dispatch_ticket: gate
      # the assignee mutation before calling gh. Audit-only by default;
      # operators authorize via ORCH_EXTERNAL_PR_MUTATIONS.
      gate_rc=0
      external_pr_mutation_assert issue_assignees \
        "reclaim_orphan_assignments:unassign:#${issue}" || gate_rc=$?
      if (( gate_rc != 0 )); then
        audit_action RECLAIM_ORPHAN_ASSIGNMENT_REFUSED \
          "issue=#${issue}" \
          "expected_remove_assignee=${assignee}" \
          "reason=external-pr-mutation-gate" \
          "gate_exit=${gate_rc}"
        emit_record "$(jq -nc \
          --arg issue "$issue" --arg login "$assignee" \
          --argjson age "$age_seconds" --argjson gate "$gate_rc" \
          '{issue:$issue,assignee:$login,status:"refused",reason:"external-pr-mutation-gate",age_seconds:$age,gate_exit:$gate}')"
        continue
      fi
      if run_gh issue edit "$issue" --repo "$GH_REPO" \
            --remove-assignee "$assignee" >/dev/null 2>&1; then
        audit_action RECLAIM_ORPHAN_ASSIGNMENT \
          "issue=#${issue}" \
          "removed_assignee=${assignee}" \
          "reason=not_in_active_logins"
        emit_record "$(jq -nc \
          --arg issue "$issue" --arg login "$assignee" \
          --argjson age "$age_seconds" \
          '{issue:$issue,assignee:$login,status:"reclaimed",reason:"not_in_active_logins",age_seconds:$age}')"
      else
        exit_code=3
        emit_record "$(jq -nc \
          --arg issue "$issue" --arg login "$assignee" \
          --argjson age "$age_seconds" \
          '{issue:$issue,assignee:$login,status:"error",reason:"gh-edit-failed",age_seconds:$age}')"
      fi
    else
      audit_action RECLAIM_ORPHAN_ASSIGNMENT_DRYRUN \
        "issue=#${issue}" \
        "would_remove_assignee=${assignee}" \
        "reason=not_in_active_logins"
      emit_record "$(jq -nc \
        --arg issue "$issue" --arg login "$assignee" \
        --argjson age "$age_seconds" \
        '{issue:$issue,assignee:$login,status:"dry-run-orphan",reason:"not_in_active_logins",age_seconds:$age}')"
    fi
  done
done

if [[ "$FORMAT" == "json" ]]; then
  if [[ "${#records[@]}" -eq 0 ]]; then
    printf '%s\n' '{"mode":"'"$MODE"'","threshold_hours":'"$threshold_hours"',"records":[]}'
  else
    jq -nc \
      --arg mode "$MODE" \
      --argjson threshold "$threshold_hours" \
      --argjson records "$(printf '%s\n' "${records[@]}" | jq -s '.')" \
      '{mode:$mode,threshold_hours:$threshold,records:$records}'
  fi
else
  printf 'mode\t%s\n' "$MODE"
  printf 'threshold_hours\t%s\n' "$threshold_hours"
  for record in "${records[@]}"; do
    issue=$(jq -r '.issue' <<< "$record")
    login=$(jq -r '.assignee' <<< "$record")
    status=$(jq -r '.status' <<< "$record")
    reason=$(jq -r '.reason' <<< "$record")
    printf '%s\t#%s\t%s\t%s\n' "$status" "$issue" "$login" "$reason"
  done
fi

exit "$exit_code"
