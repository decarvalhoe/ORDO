#!/usr/bin/env bash
# scripts/portfolio_status.sh - summarize multi-product fleet capacity.
#
# Usage:
#   portfolio_status.sh <portfolio-config> [--tsv|--json]
#
# A project is "external_wait" when open PRs are blocked only by pending checks
# or merge gates. Clean agents on default branches are "free"; clean agents
# whose work is already represented by an open PR are "parkable".
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/portfolio_config.sh"

PORTFOLIO_ARG=${1:?usage: portfolio_status.sh <portfolio-config> [--tsv|--json]}
FORMAT="tsv"
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tsv) FORMAT="tsv" ;;
    --json) FORMAT="json" ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

load_portfolio_config "$PORTFOLIO_ARG"

project_meta_json() {
  local cfg=${1:?usage: project_meta_json <config>}
  bash -c '
    set -euo pipefail
    cfg=$1
    # shellcheck disable=SC1090
    source "$cfg"
    jq -nc \
      --arg project "${PROJECT:-}" \
      --arg repo "${GH_REPO:-}" \
      --arg default_branch "${DEFAULT_BRANCH:-main}" \
      --arg config "$cfg" \
      "{project:\$project,repo:\$repo,default_branch:\$default_branch,config:\$config}"
  ' _ "$cfg"
}

project_summary_json() {
  local alias=${1:?usage: project_summary_json <alias> <config>}
  local cfg=${2:?usage: project_summary_json <alias> <config>}
  local meta pool prs

  meta=$(project_meta_json "$cfg")
  pool=$(bash "$TK/scripts/agent_pool_status.sh" "$cfg" --json 2>/dev/null || printf '[]')
  prs=$(bash "$TK/scripts/pr_block_signals.sh" "$cfg" --json 2>/dev/null || printf '[]')

  jq -nc \
    --arg alias "$alias" \
    --argjson meta "$meta" \
    --argjson agents "$pool" \
    --argjson prs "$prs" '
      def has_signal($item; $signal):
        (($item.signals // []) | index($signal)) != null;
      def clean($agent):
        (($agent.dirty // "0") == "0");
      def on_default($agent):
        (($agent.branch // "") == ($meta.default_branch // "main"));
      def has_pr($agent):
        (($agent.pr // "") != "");
      def unsafe_agent($agent):
        (clean($agent) | not)
        or has_signal($agent; "conflict")
        or has_signal($agent; "needs-rebase")
        or has_signal($agent; "pr-behind")
        or has_signal($agent; "behind-upstream");
      def free_agent($agent):
        clean($agent) and (has_pr($agent) | not) and on_default($agent);
      def parkable_agent($agent):
        clean($agent) and has_pr($agent) and (unsafe_agent($agent) | not);
      def local_work_agent($agent):
        clean($agent)
        and (has_pr($agent) | not)
        and (($agent.branch // "") != "")
        and (on_default($agent) | not);
      def pr_signal_count($signal):
        [$prs[]? | select(has_signal(.; $signal))] | length;

      ($agents // []) as $a
      | ($prs // []) as $p
      | ([$a[]? | select(free_agent(.))]) as $free
      | ([$a[]? | select(parkable_agent(.))]) as $parkable
      | ([$a[]? | select(local_work_agent(.))]) as $local_work
      | ([$a[]? | select(unsafe_agent(.))]) as $blocked_agents
      | ([$a[]? | select(has_pr(.))]) as $submitted
      | ([$a[]? | select((.dirty // "0") != "0")]) as $dirty
      | (pr_signal_count("merge-ready")) as $merge_ready
      | (pr_signal_count("ci-pending")) as $ci_pending
      | (pr_signal_count("ci-failed")) as $ci_failed
      | (pr_signal_count("needs-rebase")) as $needs_rebase
      | (pr_signal_count("merge-conflict")) as $conflicts
      | (pr_signal_count("changes-requested")) as $changes_requested
      | (pr_signal_count("review-required")) as $review_required
      | ($p | length) as $open_prs
      | (
          if (($ci_failed + $needs_rebase + $conflicts + $changes_requested) > 0) then "action_required"
          elif ($merge_ready > 0) then "merge_ready"
          elif ($open_prs > 0 and $ci_pending > 0) then "external_wait"
          elif ($open_prs > 0 and $review_required > 0) then "review_wait"
          elif ($open_prs > 0) then "blocked_or_review"
          else "dispatchable"
          end
        ) as $gate_state
      | (
          if ($gate_state == "external_wait" and (($free | length) + ($parkable | length)) > 0) then "rebalance_recommended"
          elif (($free | length) > 0) then "dispatch_capacity_available"
          else ""
          end
        ) as $rebalance_signal
      | {
          alias: $alias,
          project: ($meta.project // $alias),
          repo: ($meta.repo // ""),
          default_branch: ($meta.default_branch // "main"),
          config: ($meta.config // ""),
          gate_state: $gate_state,
          rebalance_signal: $rebalance_signal,
          counts: {
            agents: ($a | length),
            free: ($free | length),
            parkable: ($parkable | length),
            submitted: ($submitted | length),
            dirty: ($dirty | length),
            local_work: ($local_work | length),
            blocked_agents: ($blocked_agents | length),
            open_prs: $open_prs,
            merge_ready: $merge_ready,
            ci_pending: $ci_pending,
            ci_failed: $ci_failed,
            needs_rebase: $needs_rebase,
            conflicts: $conflicts,
            review_required: $review_required
          },
          agents: {
            free: ($free | map(.label)),
            parkable: ($parkable | map(.label)),
            local_work: ($local_work | map(.label)),
            blocked: ($blocked_agents | map(.label))
          },
          prs: $p
        }
    '
}

json_items=()

if [ "$FORMAT" = "tsv" ]; then
  printf 'alias\tproject\trepo\tdefault_branch\tagents\tfree\tparkable\tsubmitted\tdirty\tlocal_work\topen_prs\tmerge_ready\tci_pending\tci_failed\tneeds_rebase\tconflicts\tgate_state\trebalance_signal\tfree_agents\tparkable_agents\n'
fi

while IFS='|' read -r alias cfg; do
  summary=$(project_summary_json "$alias" "$cfg")
  if [ "$FORMAT" = "json" ]; then
    json_items+=("$summary")
  else
    printf '%s\n' "$summary" | jq -r '
      [
        .alias,
        .project,
        .repo,
        .default_branch,
        .counts.agents,
        .counts.free,
        .counts.parkable,
        .counts.submitted,
        .counts.dirty,
        .counts.local_work,
        .counts.open_prs,
        .counts.merge_ready,
        .counts.ci_pending,
        .counts.ci_failed,
        .counts.needs_rebase,
        .counts.conflicts,
        .gate_state,
        .rebalance_signal,
        (.agents.free | join(",")),
        (.agents.parkable | join(","))
      ] | @tsv'
  fi
done < <(portfolio_project_entries)

if [ "$FORMAT" = "json" ]; then
  printf '%s\n' "${json_items[@]}" | jq -s '.'
fi
