#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/host_load_gate.sh
source "$ROOT/lib/host_load_gate.sh"
orch_host_load_gate "local_validator:run_shell_tests" \
  "${ORCH_HOST_GATE_LOCAL_VALIDATORS_MODE:-${ORCH_HOST_GATE_MODE:-off}}"
orch_validator_fork_preflight "run_shell_tests"

if [[ "${ORCH_VALIDATOR_SEMAPHORE_HELD:-0}" != "1" ]]; then
  export ORCH_VALIDATOR_SEMAPHORE_HELD=1
  orch_validator_run_with_semaphore "run_shell_tests" bash "$0" "$@"
  exit $?
fi

TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

: "${ORCH_SHELL_TEST_TIMEOUT_SEC:=120}"
if ! [[ "$ORCH_SHELL_TEST_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || [[ "$ORCH_SHELL_TEST_TIMEOUT_SEC" -le 0 ]]; then
  printf 'run_shell_tests: invalid ORCH_SHELL_TEST_TIMEOUT_SEC=%s\n' "$ORCH_SHELL_TEST_TIMEOUT_SEC" >&2
  exit 2
fi

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

mirror_file() {
  local rel=${1:?usage: mirror_file <repo-relative-path>}
  local dest="$SANITIZED_ROOT/$rel"
  mkdir -p "$(dirname "$dest")"
  tr -d '\r' < "$ROOT/$rel" > "$dest"
  # tr-redirect drops the source's mode bits; bring them back so tests
  # that depend on +x scripts (and anything keyed off `[[ -x ... ]]`)
  # see the same shape as the real repo (#148 / #154 follow-up).
  chmod --reference="$ROOT/$rel" "$dest" 2>/dev/null || \
    { [[ -x "$ROOT/$rel" ]] && chmod +x "$dest"; }
}

if [[ -n "${ORCH_SHELL_TESTS:-}" ]]; then
  # shellcheck disable=SC2206
  TESTS=($ORCH_SHELL_TESTS)
else
  TESTS=(
  tests/test_agent_inventory.sh
  tests/test_agent_github_assignees.sh
  tests/test_agent_product_switch.sh
  tests/test_api_rate_limiter.sh
  tests/test_agent_pool_status.sh
  tests/test_auto_rebalance.sh
  tests/test_ci_workflow.sh
  tests/test_ci_autofix.sh
  tests/test_ci_autofix_log_sanitization.sh
  tests/test_check_ci_health.sh
  tests/test_cli_swap.sh
  tests/test_config_resolution.sh
  tests/test_audit_ready_backlog.sh
  tests/test_continuation_guard.sh
  tests/test_controlled_operation.sh
  tests/test_csv_dev_mode.sh
  tests/test_brief_agents_shell_safe.sh
  tests/test_dispatch_ticket.sh
  tests/test_dispatch_matrix_overlap_refusal.sh
  tests/test_dispatch_plan.sh
  tests/test_dispatch_plan_acceptance.sh
  tests/test_dispatch_plan_blockers.sh
  tests/test_dispatch_plan_headers.sh
  tests/test_dispatch_capacity.sh
  tests/test_dispatch_pr_ops.sh
  tests/test_capacity_busy_claim_gate.sh
  tests/test_classifier_outage.sh
  tests/test_docs_impact_gate.sh
  tests/test_docs_index_drift.sh
  tests/test_universal_fleet_manual_path_drift.sh
  tests/test_exit_codes_manifest.sh
  tests/test_file_hotspots.sh
  tests/test_prompt_integrity.sh
  tests/test_project_scaffold.sh
  tests/test_dry_run.sh
  tests/test_examples_config.sh
  tests/test_fleet_injected_rules.sh
  tests/test_fleet_provisioning.sh
  tests/test_fleet_sizing.sh
  tests/test_guided_onboarding.sh
  tests/test_multi_project_onboarding.sh
  tests/test_findings_ledger.sh
  tests/test_opportunity_registry.sh
  tests/test_onboarding_verification.sh
  tests/test_gh_actions_optimize.sh
  tests/test_gh_body_helpers.sh
  tests/test_github_identity.sh
  tests/test_host_forensics_probe.sh
  tests/test_host_assessment.sh
  tests/test_host_load_gate.sh
  tests/test_host_health_preflight.sh
  tests/test_install.sh
  tests/test_log_bounds.sh
  tests/test_orch_bootstrap_paths.sh
  tests/test_orch_ctl.sh
  tests/test_orch_manual_session.sh
  tests/test_orchestrator_injected_rules.sh
  tests/test_preflight.sh
  tests/test_post_merge_cleanup.sh
  tests/test_safe_post_merge_cleanup_recovery.sh
  tests/test_pr_merge.sh
  tests/test_pr_block_signals.sh
  tests/test_portfolio_config.sh
  tests/test_portfolio_remote_identity.sh
  tests/test_portfolio_poc.sh
  tests/test_portfolio_onboarding_upgrade_path.sh
  tests/test_portfolio_repo_bind_plan.sh
  tests/test_portfolio_status.sh
  tests/test_portfolio_session_start.sh
  tests/test_portfolio_preflight_refresh.sh
  tests/test_process_safety.sh
  tests/test_process_safety_preflight.sh
  tests/test_project_meta_context.sh
  tests/test_repository_bootstrap.sh
  tests/test_repository_platform_readiness.sh
  tests/test_runbook_freshness.sh
  tests/test_run_bats.sh
  tests/test_run_shellcheck.sh
  tests/test_run_shell_tests.sh
  tests/test_sixsigma_autoupgrade.sh
  tests/test_sixsigma_autoupgrade_in_standard_cycle.sh
  tests/test_dmaic_default_off.sh
  tests/test_sixsigma_project_module.sh
  tests/test_smart_poll_agents.sh
  tests/test_state_rollback.sh
  tests/test_test_sanitize.sh
  tests/test_terminal_dispatch_submission.sh
  tests/test_ticket_scope_validator.sh
  tests/test_tmux_helpers.sh
  tests/test_validator_fork_preflight.sh
  tests/test_validator_semaphore.sh
  tests/test_worktree_helpers.sh
)
fi

mkdir -p "$SANITIZED_ROOT"

while IFS= read -r abs_path; do
  rel_path=${abs_path#"$ROOT"/}
  mirror_file "$rel_path"
done < <(
  find \
    "$ROOT/.github" \
    "$ROOT/config" \
    "$ROOT/docs" \
    "$ROOT/examples" \
    "$ROOT/lib" \
    "$ROOT/scripts" \
    "$ROOT/templates" \
    "$ROOT/tests" \
    -type f \
    \( -name '*.sh' -o -name '*.bash' -o -name '*.bats' -o -name '*.config.sh' -o -name '*.md' -o -name '*.tpl' -o -name '*.txt' -o -name '*.yml' \) \
    | sort
)

mirror_file "install.sh"

cd "$SANITIZED_ROOT"

run_one_test() {
  local test_script=${1:?usage: run_one_test <test-script>}
  local status

  printf 'run_shell_tests: %s\n' "$test_script"
  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout "$ORCH_SHELL_TEST_TIMEOUT_SEC" bash "$test_script"
  else
    bash "$test_script"
  fi
  status=$?
  set -e

  case "$status" in
    0)
      return 0
      ;;
    124|137)
      printf 'run_shell_tests: timed out after %ss: %s\n' \
        "$ORCH_SHELL_TEST_TIMEOUT_SEC" "$test_script" >&2
      ;;
    *)
      printf 'run_shell_tests: failed exit=%s: %s\n' "$status" "$test_script" >&2
      ;;
  esac
  return "$status"
}

for test_script in "${TESTS[@]}"; do
  run_one_test "$test_script"
done
