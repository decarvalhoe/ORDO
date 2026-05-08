#!/usr/bin/env bash
# scripts/autonomous_pr_ops.sh — opt-in autonomous PR operations runner (#361).
#
# Usage:
#   autonomous_pr_ops.sh <project_short|config_path> evaluate <pr> [<pr>...]
#       Run the gate evaluator over each PR and print one JSON object
#       per PR. Always exits 0; an "eligible:false" verdict is the
#       refusal signal.
#
#   autonomous_pr_ops.sh <project_short|config_path> apply <pr>
#       Live mode: run the gate evaluator, refuse on any failed gate,
#       and otherwise invoke lib/pr_merge.sh with the configured
#       strategy. Requires AUTO_PR_OPS_ENABLED=1, AUTO_PR_OPS_MODE=live,
#       and the kill switch must be released. Without --apply (default),
#       the runner prints what it would do but does not mutate.
#
#   autonomous_pr_ops.sh <project_short|config_path> kill-switch \
#       (engage --reason "...") | release | status
#       Engage / release / inspect the kill switch. Engage refuses
#       every subsequent live action; release removes the marker.
#
#   autonomous_pr_ops.sh <project_short|config_path> render-evidence <pr>
#       Print the one-line audit summary line for the given PR.
#
# Universal:
#   - Reads policy from the project profile (lib/config_resolver.sh).
#   - No project / agent / model name is hardcoded.
#   - Tests can stub the gh payload via AUTO_PR_OPS_TEST_PR_PAYLOAD.

set -euo pipefail

TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=../lib/dry_run.sh
source "$TK/lib/dry_run.sh"
# shellcheck source=../lib/config_resolver.sh
source "$TK/lib/config_resolver.sh"
# shellcheck source=../lib/autonomous_pr_ops.sh
source "$TK/lib/autonomous_pr_ops.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

CFG_ARG="${1:?usage: autonomous_pr_ops.sh <project> <evaluate|apply|kill-switch|render-evidence> [args]}"
COMMAND="${2:?usage: autonomous_pr_ops.sh <project> <evaluate|apply|kill-switch|render-evidence> [args]}"
shift 2

load_project_config "$CFG_ARG"
: "${PROJECT:?}"
: "${GH_REPO:?GH_REPO must be set in project profile}"

# audit_log + state_persist are sourced after config is loaded so the
# state dir resolution honors the loaded PROJECT.
# shellcheck source=../lib/audit_log.sh
source "$TK/lib/audit_log.sh"
# shellcheck source=../lib/state_persist.sh
source "$TK/lib/state_persist.sh"


emit_audit() {
  local line="${1:?}"
  if declare -F audit >/dev/null 2>&1; then
    audit "$line"
  else
    printf 'AUDIT: %s\n' "$line" >&2
  fi
}


cmd_evaluate() {
  if [[ "$#" -eq 0 ]]; then
    printf 'autonomous_pr_ops evaluate: at least one PR number required\n' >&2
    exit 2
  fi
  local pr eval_json
  for pr in "$@"; do
    eval_json=$(auto_pr_ops_evaluate_pr "$GH_REPO" "$pr")
    printf '%s\n' "$eval_json"
    emit_audit "$(auto_pr_ops_render_evidence "$eval_json")"
  done
}


cmd_render_evidence() {
  local pr="${1:?usage: render-evidence <pr>}"
  local eval_json
  eval_json=$(auto_pr_ops_evaluate_pr "$GH_REPO" "$pr")
  auto_pr_ops_render_evidence "$eval_json"
}


cmd_apply() {
  local pr=""
  local apply=0
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --apply) apply=1; shift ;;
      --pr|-p) pr="${2:?missing value for --pr}"; shift 2 ;;
      -*) printf 'autonomous_pr_ops apply: unknown arg: %s\n' "$1" >&2; exit 2 ;;
      *) pr="$1"; shift ;;
    esac
  done
  [[ -n "$pr" ]] || { printf 'autonomous_pr_ops apply: pr number required\n' >&2; exit 2; }

  local mode
  mode=$(auto_pr_ops_mode)

  if [[ "$mode" != "live" ]]; then
    printf 'autonomous_pr_ops apply: AUTO_PR_OPS_MODE != live (current=%s); refusing\n' "$mode" >&2
    emit_audit "AUTONOMOUS_PR_OPS apply refused pr=#${pr} reason=mode-not-live mode=${mode}"
    exit 1
  fi

  local eval_json
  eval_json=$(auto_pr_ops_evaluate_pr "$GH_REPO" "$pr")
  printf '%s\n' "$eval_json"
  emit_audit "$(auto_pr_ops_render_evidence "$eval_json")"

  local eligible
  eligible=$(printf '%s' "$eval_json" | jq -r '.eligible')
  if [[ "$eligible" != "true" ]]; then
    printf 'autonomous_pr_ops apply: PR #%s ineligible — refused\n' "$pr" >&2
    emit_audit "AUTONOMOUS_PR_OPS apply refused pr=#${pr} reason=gate-refused"
    exit 1
  fi

  if [[ "$apply" -ne 1 ]] && ! dry_run_enabled; then
    printf 'autonomous_pr_ops apply: dry-run by default. Pass --apply to perform the live merge.\n' >&2
    emit_audit "AUTONOMOUS_PR_OPS apply dry-run pr=#${pr} reason=apply-flag-missing"
    return 0
  fi

  local strategy
  strategy=$(auto_pr_ops_strategy)
  if dry_run_enabled; then
    dry_run_note "bash $TK/lib/pr_merge.sh $CFG_ARG $pr --strategy $strategy"
    emit_audit "AUTONOMOUS_PR_OPS apply dry-run pr=#${pr} strategy=${strategy}"
    return 0
  fi

  emit_audit "AUTONOMOUS_PR_OPS apply pre pr=#${pr} strategy=${strategy}"
  local merge_status=0
  bash "$TK/lib/pr_merge.sh" "$CFG_ARG" "$pr" || merge_status=$?
  if [[ "$merge_status" -eq 0 ]]; then
    emit_audit "AUTONOMOUS_PR_OPS apply post pr=#${pr} result=success"
  else
    emit_audit "AUTONOMOUS_PR_OPS apply post pr=#${pr} result=failed exit=${merge_status}"
  fi
  return "$merge_status"
}


cmd_kill_switch() {
  local subcommand="${1:?usage: kill-switch (engage|release|status)}"
  shift
  case "$subcommand" in
    engage)
      local reason="engaged"
      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          --reason) reason="${2:?missing value for --reason}"; shift 2 ;;
          *) printf 'kill-switch engage: unknown arg: %s\n' "$1" >&2; exit 2 ;;
        esac
      done
      auto_pr_ops_kill_switch_engage "$reason"
      printf 'kill switch engaged at %s (reason: %s)\n' \
        "$(auto_pr_ops_kill_switch_path)" "$reason"
      emit_audit "AUTONOMOUS_PR_OPS kill-switch engage reason=${reason}"
      ;;
    release)
      auto_pr_ops_kill_switch_release
      printf 'kill switch released at %s\n' "$(auto_pr_ops_kill_switch_path)"
      emit_audit "AUTONOMOUS_PR_OPS kill-switch release"
      ;;
    status)
      if auto_pr_ops_kill_switch_active; then
        printf 'kill switch ACTIVE at %s\n' "$(auto_pr_ops_kill_switch_path)"
        cat "$(auto_pr_ops_kill_switch_path)"
        return 0
      fi
      printf 'kill switch inactive at %s\n' "$(auto_pr_ops_kill_switch_path)"
      ;;
    *)
      printf 'kill-switch: unknown subcommand: %s\n' "$subcommand" >&2
      exit 2
      ;;
  esac
}


case "$COMMAND" in
  evaluate) cmd_evaluate "$@" ;;
  apply) cmd_apply "$@" ;;
  kill-switch) cmd_kill_switch "$@" ;;
  render-evidence) cmd_render_evidence "$@" ;;
  *)
    printf 'autonomous_pr_ops: unknown command: %s\n' "$COMMAND" >&2
    exit 2
    ;;
esac
