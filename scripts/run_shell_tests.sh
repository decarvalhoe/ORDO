#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

: "${ORCH_SHELL_TEST_TIMEOUT_SEC:=120}"
if ! [[ "$ORCH_SHELL_TEST_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || [[ "$ORCH_SHELL_TEST_TIMEOUT_SEC" -le 0 ]]; then
  printf 'run_shell_tests: invalid ORCH_SHELL_TEST_TIMEOUT_SEC=%s\n' "$ORCH_SHELL_TEST_TIMEOUT_SEC" >&2
  exit 2
fi

# shellcheck source=../lib/host_load_gate.sh
source "$ROOT/lib/host_load_gate.sh"
orch_host_load_gate "local_validator:run_shell_tests" \
  "${ORCH_HOST_GATE_LOCAL_VALIDATORS_MODE:-${ORCH_HOST_GATE_MODE:-off}}"
orch_validator_fork_preflight "run_shell_tests"

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
  tests/test_agent_product_switch.sh
  tests/test_agent_pool_status.sh
  tests/test_ci_workflow.sh
  tests/test_ci_autofix.sh
  tests/test_check_ci_health.sh
  tests/test_cli_swap.sh
  tests/test_config_resolution.sh
  tests/test_continuation_guard.sh
  tests/test_brief_agents_shell_safe.sh
  tests/test_dispatch_ticket.sh
  tests/test_dispatch_plan.sh
  tests/test_prompt_integrity.sh
  tests/test_dry_run.sh
  tests/test_examples_config.sh
  tests/test_fleet_injected_rules.sh
  tests/test_gh_actions_optimize.sh
  tests/test_gh_body_helpers.sh
  tests/test_github_identity.sh
  tests/test_host_forensics_probe.sh
  tests/test_host_load_gate.sh
  tests/test_host_health_preflight.sh
  tests/test_install.sh
  tests/test_log_bounds.sh
  tests/test_orch_ctl.sh
  tests/test_orch_manual_session.sh
  tests/test_orchestrator_injected_rules.sh
  tests/test_preflight.sh
  tests/test_pr_merge.sh
  tests/test_pr_block_signals.sh
  tests/test_portfolio_poc.sh
  tests/test_portfolio_repo_bind_plan.sh
  tests/test_portfolio_status.sh
  tests/test_portfolio_session_start.sh
  tests/test_process_safety.sh
  tests/test_process_safety_preflight.sh
  tests/test_project_meta_context.sh
  tests/test_run_bats.sh
  tests/test_run_shellcheck.sh
  tests/test_run_shell_tests.sh
  tests/test_sixsigma_autoupgrade.sh
  tests/test_smart_poll_agents.sh
  tests/test_state_rollback.sh
  tests/test_test_sanitize.sh
  tests/test_tmux_helpers.sh
  tests/test_validator_fork_preflight.sh
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
