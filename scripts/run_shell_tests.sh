#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

mirror_file() {
  local rel=${1:?usage: mirror_file <repo-relative-path>}
  local dest="$SANITIZED_ROOT/$rel"
  mkdir -p "$(dirname "$dest")"
  tr -d '\r' < "$ROOT/$rel" > "$dest"
}

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
  tests/test_install.sh
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
  tests/test_project_meta_context.sh
  tests/test_run_bats.sh
  tests/test_run_shellcheck.sh
  tests/test_sixsigma_autoupgrade.sh
  tests/test_smart_poll_agents.sh
  tests/test_state_rollback.sh
  tests/test_tmux_helpers.sh
  tests/test_worktree_helpers.sh
)

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

for test_script in "${TESTS[@]}"; do
  bash "$test_script"
done
