#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/configs" "$TEST_TMP/calls"

for rel in \
  scripts/auto_rebalance.sh \
  lib/config_resolver.sh \
  lib/dry_run.sh \
  lib/portfolio_config.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/auto_rebalance.sh"

cat > "$SANITIZED_ROOT/scripts/portfolio_status.sh" <<'EOF'
#!/usr/bin/env bash
case "${SCENARIO:-ok}" in
  ok)
    cat <<JSON
[
  {
    "alias":"target-high","priority":90,"config":"$TEST_TARGET_HIGH_CFG","gate_state":"dispatchable",
    "counts":{"open_prs":0,"deploy_gate_wait":0,"ci_failed":0,"needs_rebase":0,"conflicts":0,"review_required":0,"merge_ready":0},
    "agents":{"free":["worker"],"parkable":[]},
    "prs":[]
  },
  {
    "alias":"source","priority":80,"config":"$TEST_SOURCE_CFG","gate_state":"external_wait",
    "counts":{"open_prs":1,"deploy_gate_wait":1,"ci_failed":0,"needs_rebase":0,"conflicts":0,"review_required":0,"merge_ready":0,"parkable":1},
    "agents":{"free":[],"parkable":["worker"]},
    "prs":[{"pr":"77","branch":"feat/source","agent":"worker","ci_fail":0,"ci_pending":1,"deploy_gate_pending":1,"base_current":"1","signals":["merge-blocked","ci-pending","deploy-gate-external-wait"]}]
  },
  {
    "alias":"target-low","priority":10,"config":"$TEST_TARGET_LOW_CFG","gate_state":"dispatchable",
    "counts":{"open_prs":0,"deploy_gate_wait":0,"ci_failed":0,"needs_rebase":0,"conflicts":0,"review_required":0,"merge_ready":0},
    "agents":{"free":["worker"],"parkable":[]},
    "prs":[]
  }
]
JSON
    ;;
  unsafe_pending)
    cat <<JSON
[
  {
    "alias":"source","priority":80,"config":"$TEST_SOURCE_CFG","gate_state":"external_wait",
    "counts":{"open_prs":1,"deploy_gate_wait":1,"ci_failed":0,"needs_rebase":0,"conflicts":0,"review_required":0,"merge_ready":0,"parkable":1},
    "agents":{"free":[],"parkable":["worker"]},
    "prs":[{"pr":"77","branch":"feat/source","agent":"worker","ci_fail":0,"ci_pending":2,"deploy_gate_pending":1,"base_current":"1","signals":["ci-pending","deploy-gate-external-wait"]}]
  },
  {
    "alias":"target-high","priority":90,"config":"$TEST_TARGET_HIGH_CFG","gate_state":"dispatchable",
    "counts":{"open_prs":0},"agents":{"free":["worker"],"parkable":[]},"prs":[]
  }
]
JSON
    ;;
esac
EOF
chmod +x "$SANITIZED_ROOT/scripts/portfolio_status.sh"

cat > "$SANITIZED_ROOT/scripts/dispatch_plan.sh" <<'EOF'
#!/usr/bin/env bash
cfg=$1
case "$cfg" in
  *target-high* )
    cat <<'JSON'
[{"issue":201,"title":"Highest priority ready work","status":"ready"}]
JSON
    ;;
  *target-low* )
    cat <<'JSON'
[{"issue":202,"title":"Lower priority ready work","status":"ready"}]
JSON
    ;;
  *)
    printf '[]\n'
    ;;
esac
EOF
chmod +x "$SANITIZED_ROOT/scripts/dispatch_plan.sh"

cat > "$SANITIZED_ROOT/scripts/agent_product_switch.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_CALLS/switch.argv"
printf 'switched\n'
EOF
chmod +x "$SANITIZED_ROOT/scripts/agent_product_switch.sh"

cat > "$SANITIZED_ROOT/scripts/brief_agents.sh" <<'EOF'
#!/usr/bin/env bash
printf 'brief for %s %s\n' "$2" "$3"
EOF
chmod +x "$SANITIZED_ROOT/scripts/brief_agents.sh"

cat > "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_CALLS/dispatch.argv"
printf 'dispatched\n'
EOF
chmod +x "$SANITIZED_ROOT/scripts/dispatch_ticket.sh"

cat > "$TEST_TMP/configs/source.config.sh" <<'EOF'
PROJECT="source"
DEFAULT_BRANCH="main"
EOF

cat > "$TEST_TMP/configs/target-high.config.sh" <<'EOF'
PROJECT="target-high"
DEFAULT_BRANCH="main"
EOF

cat > "$TEST_TMP/configs/target-low.config.sh" <<'EOF'
PROJECT="target-low"
DEFAULT_BRANCH="main"
EOF

cat > "$TEST_TMP/configs/portfolio.config.sh" <<EOF
PORTFOLIO_NAME="test"
PORTFOLIO_PROJECTS=(
  "source|$TEST_TMP/configs/source.config.sh"
  "target-high|$TEST_TMP/configs/target-high.config.sh"
  "target-low|$TEST_TMP/configs/target-low.config.sh"
)
PORTFOLIO_PRIORITIES=(
  "source=80"
  "target-high=90"
  "target-low=10"
)
EOF

export TEST_SOURCE_CFG="$TEST_TMP/configs/source.config.sh"
export TEST_TARGET_HIGH_CFG="$TEST_TMP/configs/target-high.config.sh"
export TEST_TARGET_LOW_CFG="$TEST_TMP/configs/target-low.config.sh"
export TEST_CALLS="$TEST_TMP/calls"

suggest_output=$(
  ORCH_STATE_BASE="$TEST_TMP/state-suggest" \
  bash "$SANITIZED_ROOT/scripts/auto_rebalance.sh" "$TEST_TMP/configs/portfolio.config.sh"
)
[[ "$suggest_output" == *'AUTO_REBALANCE suggested'* ]] || fail "missing suggested signal: $suggest_output"
[[ "$suggest_output" == *'source_pr=#77'* ]] || fail "missing source PR: $suggest_output"
[[ "$suggest_output" == *'target_project=target-high'* ]] || fail "should select highest-priority ready target: $suggest_output"
[[ "$suggest_output" == *'target_issue=#201'* ]] || fail "missing target issue: $suggest_output"
[[ "$suggest_output" == *'rollback_release_action='* ]] || fail "missing rollback/release action: $suggest_output"

jq -e '
  .history[0].status == "suggested"
  and .history[0].source_project == "source"
  and .history[0].source_agent == "worker"
  and .history[0].source_pr == "77"
  and .history[0].target_project == "target-high"
  and .history[0].target_issue == "201"
  and (.history[0].rollback_release_action | contains("release source/worker"))
' "$TEST_TMP/state-suggest/_portfolio/auto_rebalance.json" >/dev/null \
  || fail "suggested state record missing expected fields"
grep -q 'AUTO_REBALANCE suggested' "$TEST_TMP/state-suggest/_portfolio/ORCH_TASKS.md" \
  || fail "suggested action should be user-visible in task list"

dry_apply_output=$(
  ORCH_STATE_BASE="$TEST_TMP/state-dry" \
  bash "$SANITIZED_ROOT/scripts/auto_rebalance.sh" "$TEST_TMP/configs/portfolio.config.sh" --apply --dry-run
)
[[ "$dry_apply_output" == *'DRY-RUN: bash scripts/agent_product_switch.sh'* ]] \
  || fail "dry-run apply should preview switch command: $dry_apply_output"
[[ "$dry_apply_output" == *'DRY-RUN: bash scripts/dispatch_ticket.sh'* ]] \
  || fail "dry-run apply should preview dispatch command: $dry_apply_output"
[[ ! -e "$TEST_TMP/state-dry/_portfolio/auto_rebalance.json" ]] \
  || fail "dry-run must not persist auto rebalance records"

set +e
no_ready_output=$(
  AGENT_SWITCH_VERIFY_READY=0 \
  ORCH_STATE_BASE="$TEST_TMP/state-no-ready" \
  bash "$SANITIZED_ROOT/scripts/auto_rebalance.sh" "$TEST_TMP/configs/portfolio.config.sh" --apply 2>&1
)
no_ready_status=$?
set -e
[[ "$no_ready_status" -eq 2 ]] || fail "apply should refuse disabled readiness, got $no_ready_status: $no_ready_output"
[[ "$no_ready_output" == *'AGENT_SWITCH_VERIFY_READY disabled'* ]] \
  || fail "disabled readiness refusal should be explicit: $no_ready_output"

apply_output=$(
  ORCH_STATE_BASE="$TEST_TMP/state-apply" \
  bash "$SANITIZED_ROOT/scripts/auto_rebalance.sh" "$TEST_TMP/configs/portfolio.config.sh" --apply
)
[[ "$apply_output" == *'AUTO_REBALANCE suggested'* && "$apply_output" == *'AUTO_REBALANCE applied'* ]] \
  || fail "apply should emit suggested and applied signals: $apply_output"
grep -qxF 'source' "$TEST_TMP/calls/switch.argv" || fail "switch missing source project"
grep -qxF 'worker' "$TEST_TMP/calls/switch.argv" || fail "switch missing source agent"
grep -qxF 'target-high' "$TEST_TMP/calls/switch.argv" || fail "switch missing target project"
grep -qxF -- '--hard' "$TEST_TMP/calls/switch.argv" || fail "switch should default to hard mode"
grep -qxF "$TEST_TMP/configs/target-high.config.sh" "$TEST_TMP/calls/dispatch.argv" \
  || fail "dispatch missing target config"
grep -qxF '201' "$TEST_TMP/calls/dispatch.argv" || fail "dispatch missing target issue"
grep -qxF -- '--portfolio-project' "$TEST_TMP/calls/dispatch.argv" || fail "dispatch should carry portfolio project"
jq -e '
  ([.history[] | select(.status == "suggested")] | length == 1)
  and ([.history[] | select(.status == "applied")] | length == 1)
' "$TEST_TMP/state-apply/_portfolio/auto_rebalance.json" >/dev/null \
  || fail "apply should record suggested and applied history"

unsafe_output=$(
  SCENARIO=unsafe_pending \
  ORCH_STATE_BASE="$TEST_TMP/state-unsafe" \
  bash "$SANITIZED_ROOT/scripts/auto_rebalance.sh" "$TEST_TMP/configs/portfolio.config.sh"
)
[[ "$unsafe_output" == 'AUTO_REBALANCE none reason=no-conservative-external-wait-candidate' ]] \
  || fail "unsafe pending checks must not rebalance: $unsafe_output"
[[ ! -e "$TEST_TMP/state-unsafe/_portfolio/auto_rebalance.json" ]] \
  || fail "unsafe scenario must not persist records"

printf 'ok - auto_rebalance parks conservative external waits and dispatches ready work\n'
