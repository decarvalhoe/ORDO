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

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/dispatch_matrix.sh

mkdir -p "$TEST_TMP/gh" "$TEST_TMP/logs" "$TEST_TMP/state" "$TEST_TMP/work" "$TEST_TMP/bin"

config="$TEST_TMP/project.config.sh"
cat > "$config" <<EOF
PROJECT="dispatch-matrix-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_REPO_PREFIX="$TEST_TMP/work/"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/work/%s"
EOF

export ORCH_LOG_DIR="$TEST_TMP/logs"
export ORCH_STATE_BASE="$TEST_TMP/state"

# Mock gh: support `issue list --json ...` and `issue view <n> --json ...`.
cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"issue list"* )
    cat <<'JSON'
[
  {"number":1001,"title":"Ready emergency","labels":[{"name":"priority:P1"}],"assignees":[{"login":"copilot"}],"state":"OPEN","url":"https://example.test/1001"},
  {"number":1002,"title":"Closed already","labels":[{"name":"priority:P2"}],"assignees":[],"state":"CLOSED","url":"https://example.test/1002"}
]
JSON
    ;;
  *"issue view 1001"* )
    cat <<'JSON'
{"number":1001,"title":"Ready emergency","labels":[{"name":"priority:P1"}],"assignees":[{"login":"copilot"}],"state":"OPEN","url":"https://example.test/1001"}
JSON
    ;;
  *"issue view 1002"* )
    cat <<'JSON'
{"number":1002,"title":"Closed already","labels":[{"name":"priority:P2"}],"assignees":[],"state":"CLOSED","url":"https://example.test/1002"}
JSON
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"
export PATH="$TEST_TMP/bin:$PATH"

run_matrix() {
  bash "$SANITIZED_ROOT/scripts/dispatch_matrix.sh" "$config" "$@"
}

# --- 1. init creates a header-only matrix ---
matrix_path="$TEST_TMP/state/dispatch-matrix-test/matrix.tsv"
mkdir -p "$(dirname "$matrix_path")"
run_matrix init --matrix "$matrix_path" >/dev/null
[[ -f "$matrix_path" ]] || fail "init should create matrix file"
header=$(head -n 1 "$matrix_path")
for col in repo issue priority validation_mode target_agent tmux_target base_branch owned_paths forbidden_paths readiness blockers notes; do
  [[ "$header" == *"$col"* ]] || fail "init header missing column: $col (got: $header)"
done
[[ "$(wc -l < "$matrix_path")" -eq 1 ]] || fail "init should write only header"

# --- 2. build populates from gh issue list ---
run_matrix build --matrix "$matrix_path" >/dev/null
grep -q $'\t1001\t' "$matrix_path" || fail "build should add row for #1001"
grep -q $'\t1002\t' "$matrix_path" || fail "build should add row for #1002"
# Closed issues should land as blocked
awk -F'\t' '$2 == "1002" { exit ($10 == "blocked" ? 0 : 1) }' "$matrix_path" \
  || fail "build should mark closed issue as blocked"
# Open ready issue lands as ready
awk -F'\t' '$2 == "1001" { exit ($10 == "ready" ? 0 : 1) }' "$matrix_path" \
  || fail "build should mark open issue as ready"

# --- 3. add upserts a row with explicit kvargs ---
run_matrix add 1001 \
  target_agent=copilot \
  tmux_target=rbok-copilot:0.0 \
  base_branch=main \
  owned_paths=lib/dispatch_matrix.sh,scripts/dispatch_matrix.sh \
  forbidden_paths=scripts/install.sh \
  readiness=ready \
  notes='emergency authorized by operator-x' \
  --matrix "$matrix_path"
row_1001=$(awk -F'\t' '$2 == "1001"' "$matrix_path")
[[ "$row_1001" == *"copilot"* ]] || fail "add should set target_agent: $row_1001"
[[ "$row_1001" == *"rbok-copilot:0.0"* ]] || fail "add should set tmux_target: $row_1001"
[[ "$row_1001" == *"emergency authorized by operator-x"* ]] || fail "add should set notes: $row_1001"
# Should still be exactly one row for 1001
count=$(awk -F'\t' '$2 == "1001"' "$matrix_path" | wc -l)
[[ "$count" -eq 1 ]] || fail "add should upsert, not duplicate (got $count rows for #1001)"

# --- 4. gate refuses when row missing ---
set +e
output=$(run_matrix gate 9999 --matrix "$matrix_path" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 84 ]] || fail "gate should exit 84 when row missing (got $rc): $output"
[[ "$output" == *"missing"* ]] || fail "gate should report missing reason: $output"

# --- 5. gate refuses when matrix file missing ---
set +e
output=$(run_matrix gate 1001 --matrix "$TEST_TMP/does-not-exist.tsv" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 84 ]] || fail "gate should exit 84 when matrix file missing (got $rc): $output"

# --- 6. gate refuses blocked row ---
run_matrix add 2000 \
  target_agent=cursor \
  tmux_target=rbok-cursor:0.0 \
  base_branch=main \
  owned_paths=docs/example.md \
  readiness=blocked \
  blockers=needs-design-review \
  --matrix "$matrix_path"
set +e
output=$(run_matrix gate 2000 --matrix "$matrix_path" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 80 ]] || fail "gate should exit 80 for blocked row (got $rc): $output"
[[ "$output" == *"blocked"* ]] || fail "gate should report blocked reason: $output"

# --- 7. gate refuses dirty workdir ---
# Create a git workdir for the agent and dirty it.
mkdir -p "$TEST_TMP/work/cursor"
git -C "$TEST_TMP/work/cursor" init -q
git -C "$TEST_TMP/work/cursor" config user.email test@test.local
git -C "$TEST_TMP/work/cursor" config user.name "test"
printf 'one\n' > "$TEST_TMP/work/cursor/file.txt"
git -C "$TEST_TMP/work/cursor" add file.txt
git -C "$TEST_TMP/work/cursor" commit -q -m "seed"
printf 'two\n' >> "$TEST_TMP/work/cursor/file.txt"  # uncommitted change
run_matrix add 2001 \
  target_agent=cursor \
  tmux_target=rbok-cursor:0.0 \
  base_branch=main \
  owned_paths=docs/cursor.md \
  readiness=ready \
  --matrix "$matrix_path"
set +e
output=$(run_matrix gate 2001 --matrix "$matrix_path" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 81 ]] || fail "gate should exit 81 for dirty workdir (got $rc): $output"
[[ "$output" == *"dirty"* ]] || fail "gate should report dirty reason: $output"

# Clean up the dirty change so subsequent agent rows don't re-trigger
git -C "$TEST_TMP/work/cursor" checkout -q -- file.txt

# --- 8. gate refuses hot-spot conflict between agents ---
# Add a second row owned by a different agent that overlaps row 1001.
run_matrix add 3000 \
  target_agent=claude \
  tmux_target=rbok-claude:0.0 \
  base_branch=main \
  owned_paths=lib/dispatch_matrix.sh \
  readiness=ready \
  --matrix "$matrix_path"
set +e
output=$(run_matrix gate 3000 --matrix "$matrix_path" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 82 ]] || fail "gate should exit 82 on hot-spot conflict (got $rc): $output"
[[ "$output" == *"conflict"* ]] || fail "gate should report conflict reason: $output"

# --- 9. gate refuses when agent already owns a different ticket ---
# Seed an assignments record that has copilot busy on a different issue.
state_dir="$TEST_TMP/state/dispatch-matrix-test"
mkdir -p "$state_dir"
cat > "$state_dir/assignments.json" <<'JSON'
{"copilot": {"ticket": "777", "issue": 777, "branch": "feat/777", "workdir": "/tmp/work", "repo_root": "/tmp/work", "prompt_file": "/tmp/x.md", "dispatched_at": "2026-05-08T08:00:00Z"}}
JSON
set +e
output=$(run_matrix gate 1001 --matrix "$matrix_path" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 83 ]] || fail "gate should exit 83 when agent already owns different ticket (got $rc): $output"
[[ "$output" == *"owned"* ]] || fail "gate should report owned reason: $output"

# --- 10. gate passes when row is ready, no conflict, no other ownership ---
# Reset assignments so copilot is on its declared ticket.
cat > "$state_dir/assignments.json" <<'JSON'
{"copilot": {"ticket": "1001", "issue": 1001, "branch": "feat/1001", "workdir": "/tmp/work", "repo_root": "/tmp/work", "prompt_file": "/tmp/x.md", "dispatched_at": "2026-05-08T08:00:00Z"}}
JSON
# Drop the conflicting row to clear hot-spot overlap.
awk -F'\t' '$2 != "3000"' "$matrix_path" > "$matrix_path.tmp"
mv "$matrix_path.tmp" "$matrix_path"
output=$(run_matrix gate 1001 --matrix "$matrix_path")
[[ "$output" == "ready" ]] || fail "gate should print 'ready' on PASS (got: $output)"

# --- 11. gate refuses malformed row missing required columns ---
# Append a row directly with empty target_agent.
{
  printf 'RBOKproject/ORDO\t4000\t\tci-delegated\t\t\tmain\t\t\tready\t\t\n'
} >> "$matrix_path"
set +e
output=$(run_matrix gate 4000 --matrix "$matrix_path" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 85 ]] || fail "gate should exit 85 on malformed row (got $rc): $output"
[[ "$output" == *"malformed"* ]] || fail "gate should report malformed reason: $output"

# --- 12. doc + script discoverability (matches issue #253 validation) ---
grep -Eq "dispatch matrix|direct dispatch" "$ROOT/docs/dispatch-planning.md" \
  || fail "docs/dispatch-planning.md should mention 'dispatch matrix' or 'direct dispatch'"
grep -Eq "owned_paths|forbidden_paths|readiness" "$ROOT/docs/dispatch-planning.md" \
  || fail "docs/dispatch-planning.md should mention owned_paths/forbidden_paths/readiness"
grep -Eq "owned_paths|forbidden_paths|readiness" "$ROOT/scripts/dispatch_matrix.sh" \
  || fail "scripts/dispatch_matrix.sh should mention the matrix columns"

printf 'ok - dispatch_matrix gate refuses blocked, dirty, conflict, owned, missing, and malformed rows; passes ready\n'
