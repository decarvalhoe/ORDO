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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/bin" "$TEST_TMP/repos"

for rel in \
  scripts/agent_pool_status.sh \
  lib/agent_inventory.sh \
  lib/config_resolver.sh \
  lib/process_safety.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/agent_pool_status.sh"

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
printf 'dirty\n' > "$repo/dirty.txt"

synced_repo="$TEST_TMP/repos/synced-agent"
git init -q "$synced_repo"
git -C "$synced_repo" config user.email synced@example.invalid
git -C "$synced_repo" config user.name "Synced Test Agent"
printf 'ok\n' > "$synced_repo/file.txt"
git -C "$synced_repo" add file.txt
git -C "$synced_repo" commit -q -m 'init'
git -C "$synced_repo" branch -M main
git -C "$synced_repo" remote add origin "$synced_repo"
git -C "$synced_repo" update-ref refs/remotes/origin/main HEAD
git -C "$synced_repo" checkout -q -b feat/synced
git -C "$synced_repo" update-ref refs/remotes/origin/feat/synced HEAD
git -C "$synced_repo" branch --set-upstream-to=origin/feat/synced feat/synced >/dev/null
printf 'staged after pr\n' > "$synced_repo/staged.txt"
git -C "$synced_repo" add staged.txt

cat > "$TEST_TMP/config.sh" <<EOF
PROJECT="pool-test"
DEFAULT_BRANCH="main"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
AGENT_PANES=(
  "agent-one|agent-one:0.0|$repo"
  "synced-agent|synced-agent:0.0|$synced_repo"
)
EOF

cat > "$TEST_TMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  has-session) exit 0 ;;
  display-message) printf 'node\n' ;;
esac
EOF
chmod +x "$TEST_TMP/bin/tmux"

local_head_full=$(git -C "$repo" rev-parse HEAD)

# Scenario A: PR head SHA differs from local HEAD -> remote-rebased-local-stale.
cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '[{"number":123,"headRefName":"feat/one","headRefOid":"abcdef123456789012345678901234567890abcd","mergeStateStatus":"BLOCKED","isDraft":false,"updatedAt":"2026-01-01T00:00:00Z","title":"test"}]'
EOF
chmod +x "$TEST_TMP/bin/gh"

output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_STATE_BASE="$TEST_TMP/state-tsv" \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" "$TEST_TMP/config.sh" --tsv
)

[[ "$output" == *$'label\tpane\talive\tcommand'* ]] || fail "missing TSV header: $output"
[[ "$output" == *$'agent-one\tagent-one:0.0\t1\tnode'* ]] || fail "missing agent row: $output"
[[ "$output" == *$'\tfeat/one\t'* ]] || fail "missing branch: $output"
[[ "$output" == *"remote-rebased-local-stale"* ]] || fail "missing remote-rebased-local-stale: $output"
[[ "$output" != *"needs-rebase"* ]] || fail "should not double-report needs-rebase when stale: $output"

json_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_STATE_BASE="$TEST_TMP/state-json" \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" "$TEST_TMP/config.sh" --json
)

printf '%s' "$json_output" | jq -e '.[0].label == "agent-one" and .[0].pr == "123" and .[0].alive == 1 and .[0].base_current == "0" and (.[0].signals | index("remote-rebased-local-stale")) and ((.[0].signals | index("needs-rebase")) | not)' >/dev/null \
  || fail "unexpected JSON output (stale): $json_output"

printf '%s' "$json_output" | jq -e '.[] | select(.label == "synced-agent" and .branch == "feat/synced" and .upstream == "origin/feat/synced" and .ahead == "0" and .behind == "0" and .dirty == "1" and (.signals | index("dirty_after_pr")))' >/dev/null \
  || fail "synced staged work should report dirty_after_pr: $json_output"

# Scenario B: PR head SHA matches local HEAD -> genuine needs-rebase.
cat > "$TEST_TMP/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' '[{"number":124,"headRefName":"feat/one","headRefOid":"$local_head_full","mergeStateStatus":"BLOCKED","isDraft":false,"updatedAt":"2026-01-01T00:00:00Z","title":"test"}]'
EOF
chmod +x "$TEST_TMP/bin/gh"

needs_rebase_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_STATE_BASE="$TEST_TMP/state-needs-rebase" \
  ORCH_PROCESS_BUDGET_WARN_PROCS=999999 \
  ORCH_PROCESS_BUDGET_MAX_PROCS=999999 \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" "$TEST_TMP/config.sh" --json
)

printf '%s' "$needs_rebase_output" | jq -e '.[0].pr == "124" and (.[0].signals | index("needs-rebase")) and ((.[0].signals | index("remote-rebased-local-stale")) | not)' >/dev/null \
  || fail "expected genuine needs-rebase when PR head matches local HEAD: $needs_rebase_output"

partial_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_STATE_BASE="$TEST_TMP/state-partial" \
  ORCH_PROCESS_BUDGET_WARN_PROCS=1 \
  ORCH_PROCESS_BUDGET_MAX_PROCS=1 \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" "$TEST_TMP/config.sh" --json
)

printf '%s' "$partial_output" | jq -e '.[0].label == "agent-one" and .[0].alive == 0 and (.[0].signals | index("process_budget_degraded")) and (.[0].signals | index("fork_risk"))' >/dev/null \
  || fail "expected partial process-budget status: $partial_output"

printf 'ok - agent_pool_status reports universal fleet state\n'
