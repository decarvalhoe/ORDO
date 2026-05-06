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
    "counts":{"free":2,"parkable":0,"open_prs":0,"merge_ready":0,"ci_failed":0,"needs_rebase":0,"conflicts":0,"review_required":0}
  },
  {
    "alias":"beta","priority":50,"config":"$TEST_BETA_CFG","gate_state":"dispatchable",
    "counts":{"free":1,"parkable":0,"open_prs":0,"merge_ready":0,"ci_failed":0,"needs_rebase":0,"conflicts":0,"review_required":0}
  }
]
JSON
    ;;
  parkable_ready)
    cat <<JSON
[
  {
    "alias":"alpha","priority":100,"config":"$TEST_ALPHA_CFG","gate_state":"external_wait",
    "counts":{"free":0,"parkable":1,"open_prs":1,"merge_ready":0,"ci_pending":1,"ci_failed":0,"needs_rebase":0,"conflicts":0,"review_required":0}
  }
]
JSON
    ;;
  external_wait_no_ready)
    cat <<JSON
[
  {
    "alias":"beta","priority":50,"config":"$TEST_BETA_CFG","gate_state":"external_wait",
    "counts":{"free":0,"parkable":1,"open_prs":1,"merge_ready":0,"ci_pending":1,"ci_failed":0,"needs_rebase":0,"conflicts":0,"review_required":0}
  }
]
JSON
    ;;
  clean)
    cat <<JSON
[
  {
    "alias":"alpha","priority":100,"config":"$TEST_ALPHA_CFG","gate_state":"dispatchable",
    "counts":{"free":2,"parkable":0,"open_prs":0,"merge_ready":0,"ci_failed":0,"needs_rebase":0,"conflicts":0,"review_required":0}
  }
]
JSON
    ;;
  merge_ready)
    cat <<JSON
[
  {
    "alias":"alpha","priority":100,"config":"$TEST_ALPHA_CFG","gate_state":"merge_ready",
    "counts":{"free":0,"parkable":0,"open_prs":1,"merge_ready":1,"ci_failed":0,"needs_rebase":0,"conflicts":0,"review_required":0}
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
case "${SCENARIO:-ready}:$cfg" in
  ready:*alpha*|parkable_ready:*alpha* )
    cat <<'JSON'
[
  {"issue":101,"title":"Ready alpha task","status":"ready"}
]
JSON
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

set +e
rebalance_output=$(SCENARIO=parkable_ready bash "$SANITIZED_ROOT/scripts/continuation_guard.sh" "$TEST_TMP/configs/portfolio.config.sh" --json 2>&1)
rebalance_status=$?
set -e
[[ "$rebalance_status" -eq 10 ]] || fail "parkable ready work should require rebalance action, got $rebalance_status: $rebalance_output"
jq -e '.decision == "rebalance_required" and (.reasons[] | select(.alias == "alpha" and .reason == "rebalance-required"))' \
  <<< "$rebalance_output" >/dev/null || fail "missing rebalance-required reason: $rebalance_output"

clean_output=$(SCENARIO=clean bash "$SANITIZED_ROOT/scripts/continuation_guard.sh" "$TEST_TMP/configs/portfolio.config.sh" --json)
jq -e '.decision == "stop_ok" and (.reasons | length == 0)' <<< "$clean_output" >/dev/null \
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

printf 'ok - continuation_guard refuses premature stop when work remains\n'
