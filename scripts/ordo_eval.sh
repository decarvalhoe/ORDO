#!/usr/bin/env bash
# scripts/ordo_eval.sh — trajectory evaluation and failure-injection harness (#813, epic #806).
#
# Usage:
#   ordo_eval.sh <command> [args...] [--json]
#
# Commands:
#   run <scenario.json> [--out DIR] [--keep] [--work DIR]
#                             run one scenario in a fake world (fake runtime and
#                             provider adapters, pinned clock, isolated state dir),
#                             write the normalised trajectory to DIR (default: a
#                             temporary directory that is removed unless --keep)
#                             and score it against <name>.expected.json when that
#                             file exists next to the scenario
#   score <trajectory_dir> <expected.json>
#                             score an existing trajectory: completion, policy
#                             compliance, evidence completeness, cost, latency,
#                             duplicate-side-effect resistance (exit 1 when any fails)
#   baseline [--dir DIR] [--out FILE]
#                             run + score every scenario of DIR (default
#                             tests/fixtures/eval/demo) and write the baseline
#                             metrics file (default DIR/baseline.json)
#   check [--dir DIR] [--baseline FILE]
#                             run + score every scenario of DIR and compare with
#                             the baseline; exit 1 with a diff on any regression
#   demo                      run and score the demo workload with zero credentials
#                             (same as check, with a human summary per scenario)
#   list [--dir DIR]          list the scenarios of DIR (default: demo + failures)
#
# No project config is needed: every run lives in its own sandbox and never
# touches gh, tmux, curl or ssh (guard stubs refuse them and the run fails
# closed if one is invoked). Errors are ONE JSON line on stderr and the exit
# code follows the agentic-control-plane table (docs/exit-codes.md):
# 1 score or baseline failure / regression, 2 usage, 3 forbidden tool invoked,
# 4 not found, 5 invalid scenario or step divergence.
# Reference: docs/architecture/evaluation.md.
set -euo pipefail

TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export TK

# shellcheck source=lib/ordo_eval.sh
source "$TK/lib/ordo_eval.sh"

ORDO_EVAL_COMMANDS="run score baseline check demo list"
ORDO_EVAL_DEMO_DIR="$TK/tests/fixtures/eval/demo"
ORDO_EVAL_FAILURES_DIR="$TK/tests/fixtures/eval/failures"

usage() {
  sed -n '2,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

eval_error() {
  ordo_contracts_error eval "$@"
}

COMMAND=""
JSON=0
KEEP=0
ARGS=()
declare -A OPT=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --json) JSON=1; shift ;;
    --keep) KEEP=1; shift ;;
    --out|--work|--dir|--baseline)
      if [[ $# -lt 2 ]]; then
        ordo_contracts_error eval usage "option $1 requires a value" "$(printf '{"option":"%s"}' "$1")"
        exit $?
      fi
      OPT[${1#--}]=$2
      shift 2
      ;;
    --*)
      ordo_contracts_error eval usage "unknown option $1" "$(printf '{"option":"%s"}' "$1")"
      exit $?
      ;;
    *)
      if [[ -z "$COMMAND" ]]; then
        COMMAND=$1
      else
        ARGS+=("$1")
      fi
      shift
      ;;
  esac
done

if [[ -z "$COMMAND" ]]; then
  usage >&2
  eval_error usage "missing <command> (one of: ${ORDO_EVAL_COMMANDS})" "$(printf '{"known":"%s"}' "$ORDO_EVAL_COMMANDS")"
  exit $?
fi
case " $ORDO_EVAL_COMMANDS " in
  *" $COMMAND "*) ;;
  *)
    eval_error unknown_command "unknown command '${COMMAND}' (one of: ${ORDO_EVAL_COMMANDS})" "$(printf '{"command":"%s"}' "$COMMAND")"
    exit $?
    ;;
esac

# opt <name> [default] -> value of --<name>
opt() {
  if [[ -n "${OPT[$1]+set}" ]]; then printf '%s' "${OPT[$1]}"; else printf '%s' "${2-}"; fi
}

scenario_list() {
  # <dir...> -> scenario paths
  local d
  for d in "$@"; do
    ordo_eval_scenarios "$d"
  done
}

render_card() {
  # human line per dimension of one score card
  printf '%s' "$1" | jq -r '
    "scenario \(.scenario): \(if .pass then "PASS" else "FAIL" end)",
    (.dimensions | to_entries[] | "  \(.key): \(if .value.pass then "pass" else "FAIL" end)" + (if (.value.failures | length) > 0 then " — " + (.value.failures | join("; ")) else "" end)),
    "  metrics: mutations=\(.metrics.mutations_executed) unapproved=\(.metrics.mutations_unapproved) refused=\(.metrics.mutations_refused) repeated_keys=\(.metrics.repeated_keys) deliveries=\(.metrics.deliveries) events=\(.metrics.events_total) spans=\(.metrics.spans_total) elapsed=\(.metrics.elapsed_seconds)s tokens=\(.metrics.tokens_used) attempts=\(.metrics.attempts_used)"'
}

render_check() {
  printf '%s' "$1" | jq -r '
    "baseline check: \(if .pass then "PASS" else "FAIL" end) (\(.regressions) regression(s))",
    (.scenarios | to_entries[] | "  \(.key): \(.value.status)"
      + (if (.value.regressions // [] | length) > 0 then "\n" + ((.value.regressions // []) | map("    - " + .) | join("\n")) else "" end)
      + (if (.value.improvements // [] | length) > 0 then "\n" + ((.value.improvements // []) | map("    + " + .) | join("\n")) else "" end))'
}

rc=0
case "$COMMAND" in
  run)
    out=$(opt out "")
    work=$(opt work "")
    keep=$KEEP
    if [[ "${#ARGS[@]}" -ne 1 ]]; then
      eval_error usage "run needs exactly one <scenario.json>" "$(printf '{"args":%s}' "$(printf '%s\n' "${ARGS[@]+"${ARGS[@]}"}" | jq -R . | jq -sc 'map(select(. != ""))')")"
      exit $?
    fi
    scenario="${ARGS[0]}"
    kept=1
    [[ -n "$out" ]] || { out=$(mktemp -d "${TMPDIR:-/tmp}/ordo-eval-out.XXXXXX"); [[ "$keep" -eq 1 ]] || { kept=0; trap 'rm -rf "$out"' EXIT; }; }
    run_opts=(--out "$out")
    [[ -n "$work" ]] && run_opts+=(--work "$work")
    [[ "$keep" -eq 1 ]] && run_opts+=(--keep)
    summary=$(ordo_eval_run "$scenario" "${run_opts[@]}") || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      [[ -z "$summary" ]] || printf '%s\n' "$summary"
      exit "$rc"
    fi
    expected=$(ordo_eval_expected_for "$scenario")
    shown="$out"
    [[ "$kept" -eq 1 ]] || shown="(removed; pass --out DIR or --keep to keep it)"
    if [[ -f "$expected" ]]; then
      card=$(ordo_eval_score "$out" "$expected") || rc=$?
      if [[ "$JSON" == 1 ]]; then
        jq -cn --argjson s "$summary" --argjson c "$card" --arg out "$out" --argjson kept "$kept" \
          '{"summary": $s, "score": $c, "trajectory": (if $kept == 1 then $out else null end)}'
      else
        printf 'trajectory: %s (%s steps, clock %s -> %s)\n' "$shown" "$(jq -r .steps_executed <<<"$summary")" "$(jq -r .clock_start <<<"$summary")" "$(jq -r .clock_end <<<"$summary")"
        render_card "$card"
      fi
    elif [[ "$JSON" == 1 ]]; then
      jq -cn --argjson s "$summary" --arg out "$out" --argjson kept "$kept" \
        '{"summary": $s, "score": null, "trajectory": (if $kept == 1 then $out else null end)}'
    else
      printf 'trajectory: %s (%s steps, no expected file: not scored)\n' "$shown" "$(jq -r .steps_executed <<<"$summary")"
    fi
    ;;
  score)
    if [[ "${#ARGS[@]}" -ne 2 ]]; then
      eval_error usage "score needs <trajectory_dir> <expected.json>"
      exit $?
    fi
    card=$(ordo_eval_score "${ARGS[0]}" "${ARGS[1]}") || rc=$?
    [[ -n "$card" ]] || exit "$rc"
    if [[ "$JSON" == 1 ]]; then printf '%s\n' "$card"; else render_card "$card"; fi
    ;;
  baseline)
    dir=$(opt dir "$ORDO_EVAL_DEMO_DIR")
    out=$(opt out "$dir/baseline.json")
    mapfile -t scenarios < <(scenario_list "$dir")
    if [[ "${#scenarios[@]}" -eq 0 ]]; then
      eval_error not_found "no scenario found in ${dir}" "$(printf '{"dir":"%s"}' "$dir")"
      exit $?
    fi
    baseline=$(ordo_eval_baseline "${scenarios[@]}" --out "$out") || rc=$?
    if [[ "$JSON" == 1 ]]; then
      printf '%s\n' "$baseline"
    else
      printf 'baseline written: %s (%s scenario(s))\n' "$out" "$(jq -r '.scenarios | length' <<<"$baseline")"
      jq -r '.scenarios | to_entries[] | "  \(.key): \(if .value.pass then "pass" else "FAIL" end) mutations=\(.value.metrics.mutations_executed) events=\(.value.metrics.events_total) elapsed=\(.value.metrics.elapsed_seconds)s tokens=\(.value.metrics.tokens_used)"' <<<"$baseline"
    fi
    ;;
  check|demo)
    dir=$(opt dir "$ORDO_EVAL_DEMO_DIR")
    baseline=$(opt baseline "$dir/baseline.json")
    mapfile -t scenarios < <(scenario_list "$dir")
    if [[ "${#scenarios[@]}" -eq 0 ]]; then
      eval_error not_found "no scenario found in ${dir}" "$(printf '{"dir":"%s"}' "$dir")"
      exit $?
    fi
    report=$(ordo_eval_check "$baseline" "${scenarios[@]}") || rc=$?
    [[ -n "$report" ]] || exit "$rc"
    if [[ "$JSON" == 1 ]]; then printf '%s\n' "$report"; else render_check "$report"; fi
    ;;
  list)
    dir=$(opt dir "")
    if [[ -n "$dir" ]]; then scenario_list "$dir"; else scenario_list "$ORDO_EVAL_DEMO_DIR" "$ORDO_EVAL_FAILURES_DIR"; fi
    ;;
esac
exit "$rc"
