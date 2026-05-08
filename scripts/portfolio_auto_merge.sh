#!/usr/bin/env bash
# scripts/portfolio_auto_merge.sh — portfolio-level full-auto merge mode.
#
# Usage:
#   portfolio_auto_merge.sh <portfolio-config> [--apply|--live]
#                                              [--limit N]
#                                              [--no-admin-fallback]
#                                              [--yolo-priority]
#                                              [--tsv|--json]
#
# Behaviour (by acceptance #351):
#   - Default mode is **preview**: list every portfolio PR carrying the
#     `merge-ready` signal in priority order, and route each one through
#     `lib/pr_merge.sh --dry-run` so the existing CI gate decides whether the
#     live attempt would be safe. No external mutation. Reports merged /
#     skipped / failed counts.
#   - **Live mode** requires defense-in-depth — both:
#       1. an explicit command-line flag (`--apply` or its alias `--live`); and
#       2. an explicit profile/operator opt-in
#          (`PORTFOLIO_AUTO_MERGE_LIVE_OPT_IN=1` in the portfolio config or
#          exported in the environment).
#     Without the opt-in, the script refuses live mode and falls back to a
#     loud refusal (exit 70). Without the flag, preview is the answer even
#     when the opt-in is on.
#   - `--limit N` caps the number of PRs that will be merged in this wave
#     (default unlimited). Skipped-by-limit rows are reported.
#   - Every merge attempt delegates to `lib/pr_merge.sh` so the CI gate,
#     admin-fallback policy, conflict / draft / review-required / no-check
#     classification, and post-merge cleanup all stay in one place. This
#     command never invents merge eligibility.
#   - Honours portfolio priority order (`PORTFOLIO_PRIORITIES` or
#     `--yolo-priority`); priorities are required by default to prevent
#     silent ordering on unaudited portfolios.
#
# Exit codes:
#   0 — preview produced, OR live mode merged everything that was eligible
#   1 — at least one merge attempt failed
#   2 — config / args error
#   14 — portfolio priorities missing (matches portfolio_status.sh)
#   70 — live mode requested without profile opt-in (defense-in-depth refusal)
#
# Audit signatures:
#   AUTO_MERGE start portfolio=<name> mode=<preview|live> limit=<N|unlimited>
#   AUTO_MERGE candidate alias=<a> pr=#<n> branch=<br> priority=<p> action=<merge|skip|skip-limit>
#   AUTO_MERGE end portfolio=<name> mode=<preview|live> candidates=<n> merged=<n> skipped=<n> failed=<n>
#   AUTO_MERGE refused reason=<not_authorized|priorities_missing>
set -o pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/dry_run.sh"
source "$TK/lib/portfolio_config.sh"
source "$TK/lib/process_safety.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

PORTFOLIO_ARG=${1:?usage: portfolio_auto_merge.sh <portfolio-config> [--apply] [--limit N] [--no-admin-fallback] [--yolo-priority] [--tsv|--json]}
APPLY=0
LIMIT=""
ADMIN_ARGS=()
FORMAT="tsv"
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply|--live) APPLY=1 ;;
    --limit)
      LIMIT=${2:?missing value for --limit}
      shift
      ;;
    --no-admin-fallback) ADMIN_ARGS+=("$1") ;;
    --yolo-priority) PORTFOLIO_YOLO_PRIORITY=1 ;;
    --tsv) FORMAT="tsv" ;;
    --json) FORMAT="json" ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -n "$LIMIT" ] && ! [[ "$LIMIT" =~ ^[0-9]+$ ]]; then
  echo "--limit must be a non-negative integer (got: $LIMIT)" >&2
  exit 2
fi

load_portfolio_config "$PORTFOLIO_ARG"
portfolio_require_priorities || exit 14

: "${PORTFOLIO_AUTO_MERGE_CHILD_TIMEOUT_SEC:=30}"
: "${PORTFOLIO_AUTO_MERGE_INTER_PR_SLEEP_SEC:=10}"

portfolio_name="${PORTFOLIO_NAME:-portfolio}"

# Portfolio-scoped audit. The project-level lib/audit_log.sh is scoped to
# PROJECT + AGENT_WORKDIR_TEMPLATE, neither of which exists at portfolio
# scope. Write durable audit lines under portfolio_state_dir/auto_merge.log
# so the run leaves evidence without forcing a project context.
audit() {
  local ts line state_dir log
  ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  line="AUDIT LOG: $ts $*"
  state_dir=$(portfolio_state_dir)
  mkdir -p "$state_dir" 2>/dev/null || true
  log="$state_dir/auto_merge.log"
  printf '%s\n' "$line" >> "$log" 2>/dev/null || true
  printf '%s\n' "$line" >&2
}

# Gate live mode: BOTH the command flag AND the profile opt-in must be
# present. The flag-only path (no opt-in) is the deliberate refusal that
# turned the manual draft→ready dance into auditable evidence (issue #351).
mode="preview"
if [[ "$APPLY" -eq 1 ]]; then
  if portfolio_auto_merge_live_opt_in_enabled; then
    mode="live"
  else
    audit "AUTO_MERGE refused reason=not_authorized portfolio=${portfolio_name} flag=apply opt_in=missing"
    cat >&2 <<'MSG'
portfolio_auto_merge: live mode refused — defense-in-depth requires BOTH a
command flag (--apply or --live) AND a profile opt-in
(PORTFOLIO_AUTO_MERGE_LIVE_OPT_IN=1 in the portfolio config, or exported in
the operator environment). Re-run with the opt-in set, or omit --apply to
get a non-mutating preview.
MSG
    exit 70
  fi
fi

limit_label="unlimited"
[ -n "$LIMIT" ] && limit_label="$LIMIT"

audit "AUTO_MERGE start portfolio=${portfolio_name} mode=${mode} limit=${limit_label}"

# 1. Walk every project, ask pr_block_signals.sh for the per-PR signal
#    bundle, keep only PRs whose signals contain `merge-ready`. We rely on
#    the existing classifier instead of re-implementing it.
candidates_jq='
  .[]?
  | select((.signals // []) | index("merge-ready"))
  | {pr:.pr, branch:.branch, agent:(.agent // "")}
'

candidate_lines=()
while IFS='|' read -r alias cfg; do
  [[ -n "$alias" && -n "$cfg" ]] || continue
  priority=$(portfolio_project_priority "$alias")
  if ! prs=$(orch_run_timeout "$PORTFOLIO_AUTO_MERGE_CHILD_TIMEOUT_SEC" \
    bash "$TK/scripts/pr_block_signals.sh" "$cfg" --json 2>/dev/null); then
    audit "AUTO_MERGE candidate-scan project=${alias} status=skipped reason=child_timeout"
    continue
  fi
  if ! printf '%s' "$prs" | jq -e 'type == "array"' >/dev/null 2>&1; then
    audit "AUTO_MERGE candidate-scan project=${alias} status=skipped reason=invalid_json"
    continue
  fi

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    pr=$(printf '%s' "$entry" | jq -r '.pr')
    branch=$(printf '%s' "$entry" | jq -r '.branch')
    agent=$(printf '%s' "$entry" | jq -r '.agent')
    [[ "$pr" =~ ^[0-9]+$ ]] || continue
    candidate_lines+=("$priority|$alias|$cfg|$pr|$branch|$agent")
  done < <(printf '%s' "$prs" | jq -c "$candidates_jq")
done < <(portfolio_project_entries)

# 2. Sort: highest portfolio priority first, then ascending PR number for
#    stable alembic-aware ordering inside a project.
sorted_candidates=()
if [ "${#candidate_lines[@]}" -gt 0 ]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    sorted_candidates+=("$line")
  done < <(printf '%s\n' "${candidate_lines[@]}" | sort -t'|' -k1,1nr -k4,4n)
fi
candidate_count=${#sorted_candidates[@]}

# 3. Plan / execute.
plan_items=()
merged=0
skipped=0
failed=0
limit_reached=0

if [[ -n "$LIMIT" && "$LIMIT" -eq 0 ]]; then
  limit_reached=1
fi

for line in "${sorted_candidates[@]}"; do
  IFS='|' read -r priority alias cfg pr branch agent <<<"$line"
  action="merge"
  rc_label="0"
  reason=""

  if [[ "$limit_reached" -eq 1 ]]; then
    action="skip-limit"
    skipped=$((skipped + 1))
    audit "AUTO_MERGE candidate alias=${alias} pr=#${pr} branch=${branch} priority=${priority} action=${action}"
  else
    audit "AUTO_MERGE candidate alias=${alias} pr=#${pr} branch=${branch} priority=${priority} action=${action} mode=${mode}"

    child_args=("$cfg" "$pr" "${ADMIN_ARGS[@]}")
    if [[ "$mode" == "preview" ]]; then
      child_args+=(--dry-run)
    fi
    if dry_run_enabled; then
      # Operator opted into both --apply --dry-run; respect dry_run library.
      dry_run_note "bash $TK/lib/pr_merge.sh ${child_args[*]}"
      action="merge-dry"
      merged=$((merged + 1))
    elif bash "$TK/lib/pr_merge.sh" "${child_args[@]}"; then
      action="merge-ok"
      merged=$((merged + 1))
    else
      rc_label=$?
      action="fail"
      reason="pr_merge_rc=${rc_label}"
      failed=$((failed + 1))
    fi

    if [[ -n "$LIMIT" && "$merged" -ge "$LIMIT" ]]; then
      limit_reached=1
    fi

    if [[ "$mode" == "live" && "$action" == "merge-ok" ]]; then
      sleep "$PORTFOLIO_AUTO_MERGE_INTER_PR_SLEEP_SEC" 2>/dev/null || true
    fi
  fi

  plan_items+=("$(jq -nc \
    --arg alias "$alias" \
    --arg pr "$pr" \
    --arg branch "$branch" \
    --arg agent "$agent" \
    --arg priority "$priority" \
    --arg mode "$mode" \
    --arg action "$action" \
    --arg rc "$rc_label" \
    --arg reason "$reason" \
    '{alias:$alias, pr:($pr|tonumber? // $pr), branch:$branch, agent:$agent, priority:($priority|tonumber? // 0), mode:$mode, action:$action, rc:($rc|tonumber? // 0), reason:$reason}')")
done

audit "AUTO_MERGE end portfolio=${portfolio_name} mode=${mode} candidates=${candidate_count} merged=${merged} skipped=${skipped} failed=${failed}"

# 4. Emit report.
if [[ "$FORMAT" == "json" ]]; then
  jq -nc \
    --arg portfolio "$portfolio_name" \
    --arg mode "$mode" \
    --arg limit "$limit_label" \
    --argjson candidates "$candidate_count" \
    --argjson merged "$merged" \
    --argjson skipped "$skipped" \
    --argjson failed "$failed" \
    --argjson plan "$(printf '%s\n' "${plan_items[@]}" | jq -s '.')" \
    '{portfolio:$portfolio, mode:$mode, limit:$limit, candidates:$candidates, merged:$merged, skipped:$skipped, failed:$failed, plan:$plan}'
else
  printf 'portfolio\tmode\tlimit\tcandidates\tmerged\tskipped\tfailed\n'
  printf '%s\t%s\t%s\t%d\t%d\t%d\t%d\n' \
    "$portfolio_name" "$mode" "$limit_label" "$candidate_count" "$merged" "$skipped" "$failed"
  if [ "${#plan_items[@]}" -gt 0 ]; then
    printf '\nalias\tpriority\tpr\tbranch\tagent\taction\trc\treason\n'
    printf '%s\n' "${plan_items[@]}" | jq -r '
      [.alias, (.priority|tostring), (.pr|tostring), .branch, .agent, .action, (.rc|tostring), .reason] | @tsv
    '
  fi
fi

[ "$failed" -eq 0 ] || exit 1
exit 0
