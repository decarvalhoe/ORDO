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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/bin" "$TEST_TMP/repos" "$TEST_TMP/logs"

for rel in \
  scripts/sixsigma_autoupgrade.sh \
  scripts/gh_actions_optimize.sh \
  lib/agent_inventory.sh \
  lib/audit_log.sh \
  lib/log_bounds.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/dry_run.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/sixsigma_autoupgrade.sh"

cat > "$SANITIZED_ROOT/scripts/ci_autofix.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'push=%s args=%s\n' "\${CI_AUTOFIX_AGENT_CAN_PUSH:-}" "\$*" >> "$TEST_TMP/logs/ci_autofix.log"
EOF
chmod +x "$SANITIZED_ROOT/scripts/ci_autofix.sh"

repo="$TEST_TMP/repos/agent-one"
git init -q "$repo"
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "Test Agent"
printf 'ok\n' > "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -q -m 'init'
git -C "$repo" branch -M main
git -C "$repo" remote add origin "$repo"
git -C "$repo" update-ref refs/remotes/origin/main HEAD
git -C "$repo" checkout -q -b feat/one
printf 'base drift\n' > "$repo/base.txt"
git -C "$repo" checkout -q main
git -C "$repo" add base.txt
git -C "$repo" commit -q -m 'base drift'
git -C "$repo" update-ref refs/remotes/origin/main HEAD
git -C "$repo" checkout -q feat/one

cat > "$TEST_TMP/config.sh" <<EOF
PROJECT="sixsigma-test"
DEFAULT_BRANCH="main"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENT_PANES=(
  "agent-one|agent-one:0.0|$repo"
)
EOF

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"* )
    printf '%s\n' '[
      {"number":101,"headRefName":"feat/one","isDraft":false,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE","name":"Frontend CI"}]},
      {"number":102,"headRefName":"feat/no-owner","isDraft":false,"mergeStateStatus":"UNKNOWN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE","name":"Backend CI"}]},
      {"number":103,"headRefName":"feat/draft","isDraft":true,"mergeStateStatus":"UNKNOWN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE","name":"CI"}]},
      {"number":104,"headRefName":"feat/pass","isDraft":false,"mergeStateStatus":"CLEAN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"CI"}]}
    ]'
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  SIXSIGMA_BASE_FETCH=0 \
  SIXSIGMA_RUN_POOL_SNAPSHOT=0 \
  bash "$SANITIZED_ROOT/scripts/sixsigma_autoupgrade.sh" "$TEST_TMP/config.sh" --dry-run 2>&1
)

[[ "$output" == *"SIXSIGMA autofix pr=101 branch=feat/one agent=agent-one"* ]] || fail "expected autofix audit: $output"
[[ "$output" == *"SIXSIGMA rebase-needed pr=101 branch=feat/one agent=agent-one state=BLOCKED reason=base-drift"* ]] || fail "expected rebase-needed audit: $output"
[[ "$output" == *"SIXSIGMA skip pr=102 branch=feat/no-owner reason=no-agent-owner"* ]] || fail "expected no-owner skip: $output"
[[ "$output" == *"SIXSIGMA skip pr=103 branch=feat/draft reason=draft"* ]] || fail "expected draft skip: $output"
[[ "$output" == *"SIXSIGMA observe pr=104 branch=feat/pass failed=0"* ]] || fail "expected pass observe: $output"
grep -q 'push=1 args=.* 101 agent-one --dry-run' "$TEST_TMP/logs/ci_autofix.log" || \
  fail "expected ci_autofix dry-run dispatch with push enabled"

printf 'ok - sixsigma_autoupgrade dispatches failed PRs to owning agents\n'
