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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$SANITIZED_ROOT/examples" "$TEST_TMP/configs"

for rel in \
  scripts/portfolio_status.sh \
  lib/config_resolver.sh \
  lib/portfolio_config.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/portfolio_status.sh"

cat > "$SANITIZED_ROOT/scripts/agent_pool_status.sh" <<'EOF'
#!/usr/bin/env bash
cfg=$1
case "$cfg" in
  *alpha* )
    cat <<'JSON'
[
  {"label":"free-a","pane":"a:0.0","workdir":"/tmp/a","branch":"main","dirty":"0","pr":"","signals":[]},
  {"label":"park-a","pane":"p:0.0","workdir":"/tmp/p","branch":"feat/a","dirty":"0","pr":"12","signals":[]}
]
JSON
    ;;
  *beta* )
    cat <<'JSON'
[
  {"label":"busy-b","pane":"b:0.0","workdir":"/tmp/b","branch":"feat/b","dirty":"2","pr":"","signals":["dirty"]}
]
JSON
    ;;
esac
EOF
chmod +x "$SANITIZED_ROOT/scripts/agent_pool_status.sh"

cat > "$SANITIZED_ROOT/scripts/pr_block_signals.sh" <<'EOF'
#!/usr/bin/env bash
cfg=$1
case "$cfg" in
  *alpha* )
    cat <<'JSON'
[
  {"pr":"12","branch":"feat/a","agent":"park-a","merge_state":"BLOCKED","mergeable":"MERGEABLE","ci_fail":0,"ci_pending":1,"deploy_gate_pending":1,"base_current":"1","signals":["merge-blocked","ci-pending","deploy-gate-external-wait"]}
]
JSON
    ;;
  *beta* )
    printf '[]\n'
    ;;
esac
EOF
chmod +x "$SANITIZED_ROOT/scripts/pr_block_signals.sh"

cat > "$TEST_TMP/configs/alpha.config.sh" <<'EOF'
PROJECT="alpha"
GH_REPO="example/alpha"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/tmp/gh"
AGENT_REPO_PREFIX="/tmp/alpha-"
export AGENT_WORKDIR_TEMPLATE="/tmp/alpha-%s"
EOF

cat > "$TEST_TMP/configs/beta.config.sh" <<'EOF'
PROJECT="beta"
GH_REPO="example/beta"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/tmp/gh"
AGENT_REPO_PREFIX="/tmp/beta-"
export AGENT_WORKDIR_TEMPLATE="/tmp/beta-%s"
EOF

cat > "$TEST_TMP/configs/portfolio.config.sh" <<EOF
PORTFOLIO_NAME="test"
PORTFOLIO_PROJECTS=(
  "alpha|$TEST_TMP/configs/alpha.config.sh"
  "beta|$TEST_TMP/configs/beta.config.sh"
)
PORTFOLIO_PRIORITIES=(
  "alpha=20"
  "beta=10"
)
EOF

output=$(bash "$SANITIZED_ROOT/scripts/portfolio_status.sh" "$TEST_TMP/configs/portfolio.config.sh" --json)

jq -e '
  (map(select(.alias == "alpha" and .priority == 20 and .gate_state == "external_wait" and .rebalance_signal == "rebalance_recommended" and .counts.free == 1 and .counts.parkable == 1 and .counts.deploy_gate_wait == 1)) | length == 1)
  and
  (map(select(.alias == "beta" and .priority == 10 and .counts.dirty == 1 and .gate_state == "dispatchable" and .counts.deploy_gate_wait == 0)) | length == 1)
' <<< "$output" >/dev/null || fail "unexpected portfolio JSON: $output"

tsv=$(bash "$SANITIZED_ROOT/scripts/portfolio_status.sh" "$TEST_TMP/configs/portfolio.config.sh" --tsv)
[[ "$tsv" == *$'alpha\t20\talpha\texample/alpha\tmain\t2\t1\t1'* ]] || fail "missing alpha TSV row: $tsv"

cat > "$TEST_TMP/configs/no-priority.config.sh" <<EOF
PORTFOLIO_NAME="missing-priority"
PORTFOLIO_PROJECTS=(
  "alpha|$TEST_TMP/configs/alpha.config.sh"
  "beta|$TEST_TMP/configs/beta.config.sh"
)
EOF

set +e
missing_output=$(bash "$SANITIZED_ROOT/scripts/portfolio_status.sh" "$TEST_TMP/configs/no-priority.config.sh" --json 2>&1)
missing_status=$?
set -e
[[ "$missing_status" -eq 14 ]] || fail "missing priorities should exit 14, got $missing_status: $missing_output"
[[ "$missing_output" == *'portfolio priorities are required'* ]] || fail "missing priority prompt not explicit: $missing_output"

yolo_output=$(bash "$SANITIZED_ROOT/scripts/portfolio_status.sh" "$TEST_TMP/configs/no-priority.config.sh" --json --yolo-priority)
jq -e '
  (map(select(.alias == "alpha" and .priority_mode == "yolo" and .priority == 20)) | length == 1)
  and
  (map(select(.alias == "beta" and .priority_mode == "yolo" and .priority == 10)) | length == 1)
' <<< "$yolo_output" >/dev/null || fail "unexpected yolo priorities: $yolo_output"

printf 'ok - portfolio_status detects gate-bound projects and rebalancing capacity\n'
