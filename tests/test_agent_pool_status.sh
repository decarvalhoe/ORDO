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
  lib/config_resolver.sh
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

cat > "$TEST_TMP/config.sh" <<EOF
PROJECT="pool-test"
DEFAULT_BRANCH="main"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
AGENT_PANES=(
  "agent-one|agent-one:0.0|$repo"
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

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '[{"number":123,"headRefName":"feat/one","headRefOid":"abcdef123456","mergeStateStatus":"BLOCKED","isDraft":false,"updatedAt":"2026-01-01T00:00:00Z","title":"test"}]'
EOF
chmod +x "$TEST_TMP/bin/gh"

output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" "$TEST_TMP/config.sh" --tsv
)

[[ "$output" == *$'label\tpane\talive\tcommand'* ]] || fail "missing TSV header: $output"
[[ "$output" == *$'agent-one\tagent-one:0.0\t1\tnode'* ]] || fail "missing agent row: $output"
[[ "$output" == *$'\tfeat/one\t'* ]] || fail "missing branch: $output"
[[ "$output" == *$'\t1\t0\t123\tBLOCKED\tabcdef12\tdirty,needs-rebase'* ]] || fail "missing dirty/rebase/pr status: $output"

json_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" "$TEST_TMP/config.sh" --json
)

printf '%s' "$json_output" | jq -e '.[0].label == "agent-one" and .[0].pr == "123" and .[0].alive == 1 and .[0].base_current == "0" and (.[0].signals | index("needs-rebase"))' >/dev/null \
  || fail "unexpected JSON output: $json_output"

printf 'ok - agent_pool_status reports universal fleet state\n'
