#!/usr/bin/env bash
# scripts/auto_close_shipped_suspect.sh - queue resolver phase A (#762).
#
# Usage:
#   auto_close_shipped_suspect.sh <project_short|config_path>
#     [--apply|--dry-run] [--tsv|--json] [--plan-file <path>]
#
# Purpose
#   continuation_guard.sh emits "shipped-suspect-review-required" when the
#   ready queue is empty and the planner still carries `shipped_suspect`
#   rows. Those rows accumulate when a squash-merge "Closes #N" keyword
#   silently failed, or when the issue pre-dates the closure_acceptance
#   gate landed by #723. The supervisor cannot dispatch fresh work while
#   they sit on the backlog.
#
#   This script reads the full dispatch plan with
#   `--include-shipped-suspect --json`, picks every row tagged
#   `merged-pr:#N`, fetches the merging PR body + the source issue body
#   via gh, classifies the pair with closure_acceptance_classify, and:
#
#     * in --dry-run mode (default): emits one `AUTO_CLOSE_CANDIDATE`
#       audit row per shipped_suspect row, with the classifier outcome
#       and refusal reason. No GitHub mutation is attempted.
#     * in --apply mode: when closure_acceptance_should_close says yes,
#       closes the issue through `ordo_provider issue_edit --state closed`, so the
#       audit-only / issue_close authorisation gate (#268) still fires.
#       When the classifier refuses, only an audit row is emitted —
#       the row is surfaced for operator review and never closed
#       automatically.
#
# Mode source of truth
#   ORCH_AUTO_CLOSE_MODE=off|dry-run|apply (default: off). CLI flags
#   --apply and --dry-run override the env, allowing operator-scoped
#   one-shot runs without exporting state. While the rollout window is
#   open, the supervisor should pass --dry-run explicitly so the env
#   default does not silently flip behavior on hosts that pre-set
#   ORCH_AUTO_CLOSE_MODE=apply.
#
# Authorisation
#   the issue close runs through the provider adapter gate, which refuses
#   unless `issue_close` (or `all`) is in ORCH_EXTERNAL_PR_MUTATIONS.
#   That is intentional: --apply alone is not enough; the operator must
#   also authorize the mutation scope at dispatch time.
#
# Output
#   Same `pr / issue / outcome / action / reason / detail` shape as
#   post_merge_cleanup, in TSV (default) or JSON.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=../lib/config_resolver.sh
source "$TK/lib/config_resolver.sh"

CFG_ARG=${1:?usage: auto_close_shipped_suspect.sh <project> [--apply|--dry-run] [--tsv|--json] [--plan-file <path>]}
shift

MODE=""
FORMAT="tsv"
PLAN_FILE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) MODE="apply" ;;
    --dry-run) MODE="dry-run" ;;
    --off) MODE="off" ;;
    --tsv) FORMAT="tsv" ;;
    --json) FORMAT="json" ;;
    --plan-file)
      PLAN_FILE=${2:?missing value for --plan-file}
      shift
      ;;
    --plan-file=*) PLAN_FILE=${1#--plan-file=} ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

load_project_config "$CFG_ARG"

# shellcheck source=../lib/audit_log.sh
source "$TK/lib/audit_log.sh"
# shellcheck source=../lib/external_mutation_gate.sh
source "$TK/lib/external_mutation_gate.sh"
# Forge access goes through the provider adapter (#816): no direct gh call;
# the issue close mutation is gated and ledgered by the adapter itself.
# shellcheck source=../lib/ordo_provider_adapter.sh
source "$TK/lib/ordo_provider_adapter.sh"
# shellcheck source=../lib/closure_acceptance.sh
source "$TK/lib/closure_acceptance.sh"

: "${GH_REPO:?GH_REPO must be set by the project config}"
: "${GH_CONFIG_DIR:?GH_CONFIG_DIR must be set by the project config}"

# Effective mode: CLI flag wins over env, env default is `off` so the
# script never closes anything until an operator opts in explicitly.
if [ -z "$MODE" ]; then
  MODE=${ORCH_AUTO_CLOSE_MODE:-off}
fi
case "$MODE" in
  off|dry-run|apply) ;;
  *)
    printf 'unknown auto-close mode: %s (expected off|dry-run|apply)\n' "$MODE" >&2
    exit 2
    ;;
esac

records=()

add_record() {
  local issue=${1:-0}
  local pr=${2:-0}
  local outcome=${3:-}
  local action=${4:-}
  local reason=${5:-}
  local detail=${6:-}
  records+=("$(jq -nc \
    --argjson issue "${issue:-0}" \
    --argjson pr "${pr:-0}" \
    --arg outcome "$outcome" \
    --arg action "$action" \
    --arg reason "$reason" \
    --arg detail "$detail" \
    --arg mode "$MODE" \
    --arg project "$PROJECT" \
    '{project:$project,issue:$issue,pr:$pr,outcome:$outcome,action:$action,reason:$reason,detail:$detail,mode:$mode}')")
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
  printf 'project\tissue\tpr\toutcome\taction\treason\tdetail\tmode\n'
  if [ "${#records[@]}" -gt 0 ]; then
    printf '%s\n' "${records[@]}" \
      | jq -r '. | [.project,.issue,.pr,.outcome,.action,.reason,.detail,.mode] | @tsv'
  fi
}

load_plan_json() {
  if [ -n "$PLAN_FILE" ]; then
    cat "$PLAN_FILE"
    return
  fi
  bash "$TK/scripts/dispatch_plan.sh" "$CFG_ARG" --include-shipped-suspect --json 2>/dev/null \
    || printf '[]'
}

merged_pr_from_signals() {
  local signals_json=$1
  jq -r '
    .[]?
    | select(test("^merged-pr:#[0-9]+$"))
    | sub("^merged-pr:#"; "")
  ' <<<"$signals_json" 2>/dev/null | head -n 1
}

fetch_pr_body() {
  local pr=${1:?usage: fetch_pr_body <pr>}
  GH_CONFIG_DIR="$GH_CONFIG_DIR" ordo_provider pr_get "$pr" --repo "$GH_REPO" 2>/dev/null \
    | jq -r '.body // empty' 2>/dev/null || true
}

fetch_issue_body() {
  local issue=${1:?usage: fetch_issue_body <issue>}
  GH_CONFIG_DIR="$GH_CONFIG_DIR" ordo_provider issue_get "$issue" --repo "$GH_REPO" 2>/dev/null \
    | jq -r '.body // empty' 2>/dev/null || true
}

auto_close_comment() {
  local issue=$1
  local pr=$2
  local outcome=$3
  cat <<EOF
Auto-closed by ORDO queue resolver phase A (#762).

Evidence:
- Merged PR: #${pr}
- Source issue: #${issue}
- Closure acceptance outcome: ${outcome}
- Mode: ${MODE}

The PR body either carried an acceptance proof block whose artifact
markers covered the issue's DoD bullets, or an operator-authorized
close trailer. The closure_acceptance_gate (#723) validated the
relationship before this auto-close was attempted.
EOF
}

if [ "$MODE" = "off" ]; then
  audit "AUTO_CLOSE_SHIPPED_SUSPECT skip mode=off project=${PROJECT} repo=${GH_REPO}"
  emit_records
  exit 0
fi

audit "AUTO_CLOSE_SHIPPED_SUSPECT start mode=${MODE} project=${PROJECT} repo=${GH_REPO}"

plan_json=$(load_plan_json)
if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$plan_json"; then
  audit "AUTO_CLOSE_SHIPPED_SUSPECT abort reason=invalid-plan project=${PROJECT}"
  emit_records
  exit 0
fi

candidate_count=$(jq -r '[.[]? | select(.status == "shipped_suspect" or .status == "stale_parent")] | length' <<<"$plan_json")
audit "AUTO_CLOSE_SHIPPED_SUSPECT plan project=${PROJECT} repo=${GH_REPO} candidates=${candidate_count}"

if [ "${candidate_count:-0}" -eq 0 ]; then
  emit_records
  exit 0
fi

while IFS= read -r row_b64; do
  [ -n "$row_b64" ] || continue
  row=$(printf '%s' "$row_b64" | base64 -d)
  issue=$(jq -r '.issue' <<<"$row")
  signals=$(jq -c '.signals' <<<"$row")

  pr_number=$(merged_pr_from_signals "$signals")
  if [ -z "$pr_number" ]; then
    add_record "$issue" 0 "no-merged-pr" "skip" "no-merged-pr-signal" \
      "signals=$(jq -r '. | join(",")' <<<"$signals")"
    audit "AUTO_CLOSE_CANDIDATE issue=#${issue} pr=none outcome=no-merged-pr action=skip reason=no-merged-pr-signal mode=${MODE}"
    continue
  fi

  pr_body=$(fetch_pr_body "$pr_number")
  issue_body=$(fetch_issue_body "$issue")

  outcome=$(closure_acceptance_classify "$pr_body" "$issue_body" "$issue")
  reason=$(closure_acceptance_refusal_reason "$outcome")

  if ! closure_acceptance_should_close "$outcome"; then
    add_record "$issue" "$pr_number" "$outcome" "audit_only" "$reason" \
      "issue=#${issue} pr=#${pr_number} mode=${MODE}"
    audit "AUTO_CLOSE_CANDIDATE issue=#${issue} pr=#${pr_number} outcome=${outcome} action=audit_only reason=${reason} mode=${MODE}"
    continue
  fi

  if [ "$MODE" != "apply" ]; then
    add_record "$issue" "$pr_number" "$outcome" "would_close" "$reason" \
      "issue=#${issue} pr=#${pr_number} mode=${MODE}"
    audit "AUTO_CLOSE_CANDIDATE issue=#${issue} pr=#${pr_number} outcome=${outcome} action=would_close reason=${reason} mode=${MODE}"
    continue
  fi

  comment=$(auto_close_comment "$issue" "$pr_number" "$outcome")
  # ordo_provider issue_edit --state closed (#816) replaces the
  # external_pr_mutation_run pair: the adapter asserts the issue_close scope
  # (refused unless authorised via ORCH_EXTERNAL_PR_MUTATIONS) and records
  # the receipt under the idempotency key <issue, merged pr>.
  close_rc=0
  GH_CONFIG_DIR="$GH_CONFIG_DIR" ordo_provider issue_edit "$issue" --repo "$GH_REPO" \
    --state closed --reason completed --body "$comment" \
    --idempotency-key "auto_close_shipped_suspect:issue_close:${GH_REPO}#${issue}:pr${pr_number}" >/dev/null 2>&1 \
    || close_rc=$?

  if [ "$close_rc" -eq 0 ]; then
    add_record "$issue" "$pr_number" "$outcome" "closed" "$reason" \
      "issue=#${issue} pr=#${pr_number} mode=apply"
    audit "AUTO_CLOSE_CANDIDATE issue=#${issue} pr=#${pr_number} outcome=${outcome} action=closed reason=${reason} mode=apply"
  else
    add_record "$issue" "$pr_number" "$outcome" "close_failed" "issue_close_rc=${close_rc}" \
      "issue=#${issue} pr=#${pr_number} mode=apply"
    audit "AUTO_CLOSE_CANDIDATE issue=#${issue} pr=#${pr_number} outcome=${outcome} action=close_failed reason=issue_close_rc=${close_rc} mode=apply"
  fi
done < <(jq -r '
  [.[]? | select(.status == "shipped_suspect" or .status == "stale_parent")]
  | .[]
  | @base64
' <<<"$plan_json")

emit_records
