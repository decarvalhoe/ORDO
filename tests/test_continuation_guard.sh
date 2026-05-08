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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/configs"

for rel in \
  scripts/continuation_guard.sh \
  lib/config_resolver.sh \
  lib/portfolio_config.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/continuation_guard.sh"

cat > "$SANITIZED_ROOT/scripts/portfolio_status.sh" <<'EOF'
#!/usr/bin/env bash
case "${SCENARIO:-ready}" in
  ready)
    cat <<JSON
[
  {
    "alias":"alpha","priority":100,"config":"$TEST_ALPHA_CFG","gate_state":"dispatchable",
    "counts":{"free":2,"parkable":0,"open_prs":0,"merge_ready":0,"ci_failed":0,"needs_rebase":0,"conflicts":0,"review_required":0},
    "agents":{"free":["alpha-free-1","alpha-free-2"],"parkable":[]}
  },
  {
    "alias":"beta","priority":50,"config":"$TEST_BETA_CFG","gate_state":"dispatchable",
    "counts":{"free":1,"parkable":0,"open_prs":0,"merge_ready":0,"ci_failed":0,"needs_rebase":0,"conflicts":0,"review_required":0},
    "agents":{"free":["beta-free-1"],"parkable":[]}
  }
]
JSON
    ;;
  parkable_ready)
    cat <<JSON
[
  {
    "alias":"alpha","priority":100,"config":"$TEST_ALPHA_CFG","gate_state":"external_wait",
    "counts":{"free":0,"parkable":1,"open_prs":1,"merge_ready":0,"ci_pending":1,"ci_failed":0,"needs_rebase":0,"conflicts":0,"review_required":0},
    "agents":{"free":[],"parkable":["alpha-parkable-1"]}
  }
]
JSON
    ;;
  external_wait_no_ready)
    cat <<JSON
[
  {
    "alias":"beta","priority":50,"config":"$TEST_BETA_CFG","gate_state":"external_wait",
    "counts":{"free":0,"parkable":1,"open_prs":1,"merge_ready":0,"ci_pending":1,"ci_failed":0,"needs_rebase":0,"conflicts":0,"review_required":0},
    "agents":{"free":[],"parkable":["beta-parkable-1"]}
  }
]
JSON
    ;;
  clean)
    cat <<JSON
[
  {
    "alias":"alpha","priority":100,"config":"$TEST_ALPHA_CFG","gate_state":"dispatchable",
    "counts":{"free":2,"parkable":0,"open_prs":0,"merge_ready":0,"ci_failed":0,"needs_rebase":0,"conflicts":0,"review_required":0},
    "agents":{"free":["alpha-free-1","alpha-free-2"],"parkable":[]}
  }
]
JSON
    ;;
  merge_ready)
    cat <<JSON
[
  {
    "alias":"alpha","priority":100,"config":"$TEST_ALPHA_CFG","gate_state":"merge_ready",
    "counts":{"free":0,"parkable":0,"open_prs":1,"merge_ready":1,"ci_failed":0,"needs_rebase":0,"conflicts":0,"review_required":0},
    "agents":{"free":[],"parkable":[]}
  }
]
JSON
    ;;
  atomize_only|shipped_suspect|blocked_only)
    cat <<JSON
[
  {
    "alias":"alpha","priority":100,"config":"$TEST_ALPHA_CFG","gate_state":"dispatchable",
    "counts":{"free":1,"parkable":0,"open_prs":0,"merge_ready":0,"ci_failed":0,"needs_rebase":0,"conflicts":0,"review_required":0},
    "agents":{"free":["alpha-free-1"],"parkable":[]}
  }
]
JSON
    ;;
  backlog_clean_unblocker)
    # Mirror the 2026-05-08 PRAXIS evidence: 28 drafts, 27 ci-failed, 1
    # clean unblocker. The orchestrator must merge the unblocker BEFORE
    # dispatching to the two free agents.
    cat <<JSON
[
  {
    "alias":"alpha","priority":100,"config":"$TEST_ALPHA_CFG","gate_state":"action_required",
    "backlog_signal":"clean_unblocker_available",
    "counts":{"free":2,"parkable":0,"open_prs":28,"merge_ready":0,"ci_failed":27,"needs_rebase":0,"conflicts":0,"review_required":0,"draft_prs":28,"failed_prs":27,"failed_draft_prs":27,"clean_unblocker_prs":1},
    "clean_unblocker_pr_numbers":["292"],
    "agents":{"free":["alpha-free-1","alpha-free-2"],"parkable":[]}
  }
]
JSON
    ;;
  backlog_drafts_blocked)
    # Drafts dominate (>=80%) but no CI failures and no clean unblocker:
    # the orchestrator must mark ready or close stale drafts before
    # further dispatch.
    cat <<JSON
[
  {
    "alias":"alpha","priority":100,"config":"$TEST_ALPHA_CFG","gate_state":"action_required",
    "backlog_signal":"drafts_blocked",
    "counts":{"free":1,"parkable":0,"open_prs":10,"merge_ready":0,"ci_failed":0,"needs_rebase":0,"conflicts":0,"review_required":0,"draft_prs":10,"failed_prs":0,"failed_draft_prs":0,"clean_unblocker_prs":0},
    "clean_unblocker_pr_numbers":[],
    "agents":{"free":["alpha-free-1"],"parkable":[]}
  }
]
JSON
    ;;
  backlog_ci_blocked)
    # CI failures dominate (>=80%) on non-draft PRs; backlog is
    # ci_blocked but there is no unblocker, so the orchestrator must
    # rerun or fix CI before further dispatch.
    cat <<JSON
[
  {
    "alias":"alpha","priority":100,"config":"$TEST_ALPHA_CFG","gate_state":"action_required",
    "backlog_signal":"ci_blocked",
    "counts":{"free":1,"parkable":0,"open_prs":10,"merge_ready":0,"ci_failed":9,"needs_rebase":0,"conflicts":0,"review_required":0,"draft_prs":0,"failed_prs":9,"failed_draft_prs":0,"clean_unblocker_prs":0},
    "clean_unblocker_pr_numbers":[],
    "agents":{"free":["alpha-free-1"],"parkable":[]}
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
shift || true
ready_only=0
for arg in "$@"; do
  case "$arg" in
    --ready-only) ready_only=1 ;;
  esac
done
case "${SCENARIO:-ready}:$cfg" in
  ready:*alpha*|parkable_ready:*alpha* )
    cat <<'JSON'
[
  {"issue":101,"title":"Ready alpha task","status":"ready"},
  {"issue":102,"title":"Second ready alpha task","status":"ready"}
]
JSON
    ;;
  atomize_only:*alpha* )
    if [ "$ready_only" -eq 1 ]; then
      printf '[]\n'
    else
      cat <<'JSON'
[
  {"issue":201,"title":"Large parent task","status":"atomize"},
  {"issue":202,"title":"Stale parent follow-up","status":"stale_parent"}
]
JSON
    fi
    ;;
  shipped_suspect:*alpha* )
    if [ "$ready_only" -eq 1 ]; then
      printf '[]\n'
    else
      cat <<'JSON'
[
  {"issue":203,"title":"Verify shipped evidence","status":"shipped_suspect"}
]
JSON
    fi
    ;;
  blocked_only:*alpha* )
    if [ "$ready_only" -eq 1 ]; then
      printf '[]\n'
    else
      cat <<'JSON'
[
  {"issue":204,"title":"Blocked useful work","status":"blocked"}
]
JSON
    fi
    ;;
  *)
    printf '[]\n'
    ;;
esac
EOF
chmod +x "$SANITIZED_ROOT/scripts/dispatch_plan.sh"

cat > "$TEST_TMP/configs/alpha.config.sh" <<'EOF'
PROJECT="alpha"
GH_REPO="example/alpha"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/tmp/gh"
EOF

cat > "$TEST_TMP/configs/beta.config.sh" <<'EOF'
PROJECT="beta"
GH_REPO="example/beta"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/tmp/gh"
EOF

cat > "$TEST_TMP/configs/portfolio.config.sh" <<EOF
PORTFOLIO_PROJECTS=(
  "alpha|$TEST_TMP/configs/alpha.config.sh"
  "beta|$TEST_TMP/configs/beta.config.sh"
)
PORTFOLIO_PRIORITIES=(
  "alpha=100"
  "beta=50"
)
EOF

export TEST_ALPHA_CFG="$TEST_TMP/configs/alpha.config.sh"
export TEST_BETA_CFG="$TEST_TMP/configs/beta.config.sh"

set +e
ready_output=$(SCENARIO=ready bash "$SANITIZED_ROOT/scripts/continuation_guard.sh" "$TEST_TMP/configs/portfolio.config.sh" --json 2>&1)
ready_status=$?
set -e
[[ "$ready_status" -eq 10 ]] || fail "ready work should require dispatch action, got $ready_status: $ready_output"
jq -e '.decision == "dispatch_required" and (.reasons[] | select(.alias == "alpha" and .reason == "dispatch-required"))' \
  <<< "$ready_output" >/dev/null || fail "missing dispatch-required reason: $ready_output"
jq -e '
  .decision == "dispatch_required"
  and ([.reasons[] | select(.alias == "alpha" and .reason == "dispatch-required")] | length == 2)
  and ([.reasons[].detail] | index("agent=alpha-free-1 issue=#101 Ready alpha task; available_capacity=2 ready_issues=2") != null)
  and ([.reasons[].detail] | index("agent=alpha-free-2 issue=#102 Second ready alpha task; available_capacity=2 ready_issues=2") != null)
  and (.warnings[] | select(.alias == "beta" and .reason == "idle-ready-agent-blocker" and (.detail | contains("agent=beta-free-1 blocker=no-ready-issue"))))
' <<< "$ready_output" >/dev/null \
  || fail "ready output should assign every available alpha agent and block idle beta agent: $ready_output"

set +e
rebalance_output=$(SCENARIO=parkable_ready bash "$SANITIZED_ROOT/scripts/continuation_guard.sh" "$TEST_TMP/configs/portfolio.config.sh" --json 2>&1)
rebalance_status=$?
set -e
[[ "$rebalance_status" -eq 10 ]] || fail "parkable ready work should require rebalance action, got $rebalance_status: $rebalance_output"
jq -e '.decision == "rebalance_required" and (.reasons[] | select(.alias == "alpha" and .reason == "rebalance-required" and (.detail | contains("agent=alpha-parkable-1 issue=#101 Ready alpha task"))))' \
  <<< "$rebalance_output" >/dev/null || fail "missing rebalance-required reason: $rebalance_output"

clean_output=$(SCENARIO=clean bash "$SANITIZED_ROOT/scripts/continuation_guard.sh" "$TEST_TMP/configs/portfolio.config.sh" --json)
jq -e '
  .decision == "stop_ok"
  and (.reasons | length == 0)
  and ([.warnings[] | select(.reason == "idle-ready-agent-blocker")] | length == 2)
' <<< "$clean_output" >/dev/null \
  || fail "clean portfolio should be stop_ok: $clean_output"

external_wait_output=$(SCENARIO=external_wait_no_ready bash "$SANITIZED_ROOT/scripts/continuation_guard.sh" "$TEST_TMP/configs/portfolio.config.sh" --json)
jq -e '.decision == "stop_ok" and (.reasons | length == 0) and (.warnings[] | select(.reason == "external-wait"))' \
  <<< "$external_wait_output" >/dev/null || fail "external wait without ready work should not require dispatch: $external_wait_output"

set +e
merge_output=$(SCENARIO=merge_ready bash "$SANITIZED_ROOT/scripts/continuation_guard.sh" "$TEST_TMP/configs/portfolio.config.sh" --json 2>&1)
merge_status=$?
set -e
[[ "$merge_status" -eq 10 ]] || fail "merge-ready should require continuation, got $merge_status: $merge_output"
jq -e '.decision == "continue_required" and (.reasons[] | select(.reason == "merge-ready"))' \
  <<< "$merge_output" >/dev/null || fail "missing merge-ready reason: $merge_output"

set +e
atomize_output=$(SCENARIO=atomize_only bash "$SANITIZED_ROOT/scripts/continuation_guard.sh" "$TEST_TMP/configs/portfolio.config.sh" --json 2>&1)
atomize_status=$?
set -e
[[ "$atomize_status" -eq 10 ]] || fail "atomize-only queue should require continuation, got $atomize_status: $atomize_output"
jq -e '
  .decision == "continue_required"
  and (.reasons[] | select(.alias == "alpha" and .reason == "atomize-required" and .count == 2 and (.detail | contains("dispatch_plan --atomize --dry-run"))))
  and (.warnings[] | select(.reason == "idle-ready-agent-blocker" and (.detail | contains("agent=alpha-free-1 blocker=no-ready-issue"))))
' <<< "$atomize_output" >/dev/null \
  || fail "atomize-only queue should recommend atomization and record idle blocker: $atomize_output"

set +e
shipped_output=$(SCENARIO=shipped_suspect bash "$SANITIZED_ROOT/scripts/continuation_guard.sh" "$TEST_TMP/configs/portfolio.config.sh" --json 2>&1)
shipped_status=$?
set -e
[[ "$shipped_status" -eq 10 ]] || fail "shipped-suspect queue should require continuation, got $shipped_status: $shipped_output"
jq -e '.decision == "continue_required" and (.reasons[] | select(.reason == "shipped-suspect-review-required" and .count == 1))' \
  <<< "$shipped_output" >/dev/null || fail "missing shipped-suspect continuation reason: $shipped_output"

set +e
blocked_output=$(SCENARIO=blocked_only bash "$SANITIZED_ROOT/scripts/continuation_guard.sh" "$TEST_TMP/configs/portfolio.config.sh" --json 2>&1)
blocked_status=$?
set -e
[[ "$blocked_status" -eq 10 ]] || fail "blocked-only queue should require continuation, got $blocked_status: $blocked_output"
jq -e '.decision == "continue_required" and (.reasons[] | select(.reason == "unblock-required" and .count == 1))' \
  <<< "$blocked_output" >/dev/null || fail "missing unblock continuation reason: $blocked_output"

# --- Backlog escalation (#353) --------------------------------------------

# Clean unblocker present: decision MUST be merge_required even though
# free agents exist with ready work. Mark-ready -> merge -> rerun is the
# canonical sequence the orchestrator must follow before more dispatch.
set +e
unblocker_output=$(SCENARIO=backlog_clean_unblocker bash "$SANITIZED_ROOT/scripts/continuation_guard.sh" "$TEST_TMP/configs/portfolio.config.sh" --json 2>&1)
unblocker_status=$?
set -e
[[ "$unblocker_status" -eq 10 ]] || fail "clean unblocker should require merge action, got $unblocker_status: $unblocker_output"
jq -e '
  .decision == "merge_required"
  and (.reasons[] | select(.alias == "alpha"
    and .reason == "backlog-clean-unblocker-ready"
    and .count == 1
    and (.detail | contains("clean draft PR(s)=292"))
    and (.detail | contains("total=28 drafts=28 failed=27"))
    and (.detail | contains("mark ready -> merge through gated path -> rerun dependent failed PRs"))
  ))
' <<< "$unblocker_output" >/dev/null \
  || fail "merge_required decision and unblocker reason expected: $unblocker_output"
# Even though dispatch capacity exists, the canonical decision must be
# merge_required, not dispatch_required.
jq -e '.decision != "dispatch_required"' <<< "$unblocker_output" >/dev/null \
  || fail "decision must NOT be dispatch_required while a clean unblocker is pending: $unblocker_output"

# Drafts blocked (no clean unblocker): decision is continue_required,
# reason is backlog-drafts-blocked, no merge_required.
set +e
drafts_output=$(SCENARIO=backlog_drafts_blocked bash "$SANITIZED_ROOT/scripts/continuation_guard.sh" "$TEST_TMP/configs/portfolio.config.sh" --json 2>&1)
drafts_status=$?
set -e
[[ "$drafts_status" -eq 10 ]] || fail "drafts-blocked backlog should require continuation, got $drafts_status: $drafts_output"
jq -e '
  .decision == "continue_required"
  and (.reasons[] | select(.alias == "alpha"
    and .reason == "backlog-drafts-blocked"
    and .count == 10
    and (.detail | contains("total=10 drafts=10"))
    and (.detail | contains("mark ready or close stale drafts"))
  ))
' <<< "$drafts_output" >/dev/null \
  || fail "drafts-blocked reason expected: $drafts_output"

# CI blocked (non-draft majority): decision is continue_required,
# reason is backlog-ci-blocked.
set +e
ciblocked_output=$(SCENARIO=backlog_ci_blocked bash "$SANITIZED_ROOT/scripts/continuation_guard.sh" "$TEST_TMP/configs/portfolio.config.sh" --json 2>&1)
ciblocked_status=$?
set -e
[[ "$ciblocked_status" -eq 10 ]] || fail "ci-blocked backlog should require continuation, got $ciblocked_status: $ciblocked_output"
jq -e '
  .decision == "continue_required"
  and (.reasons[] | select(.alias == "alpha"
    and .reason == "backlog-ci-blocked"
    and .count == 9
    and (.detail | contains("total=10 failed=9"))
    and (.detail | contains("rerun or fix failed CI"))
  ))
' <<< "$ciblocked_output" >/dev/null \
  || fail "ci-blocked reason expected: $ciblocked_output"

printf 'ok - continuation_guard refuses premature stop when work remains\n'
