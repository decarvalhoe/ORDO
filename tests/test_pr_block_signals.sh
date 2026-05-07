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
  scripts/pr_block_signals.sh \
  lib/agent_inventory.sh \
  lib/config_resolver.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/pr_block_signals.sh"

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
git -C "$repo" checkout -q -b feat/blocked
git -C "$repo" checkout -q main
printf 'base drift\n' > "$repo/base.txt"
git -C "$repo" add base.txt
git -C "$repo" commit -q -m 'base drift'
git -C "$repo" update-ref refs/remotes/origin/main HEAD
git -C "$repo" checkout -q feat/blocked

cat > "$TEST_TMP/config.sh" <<EOF
PROJECT="signals-test"
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
    printf '%s\n' '[{"number":77},{"number":78},{"number":79}]'
    ;;
  *"pr view 77"* )
    printf '%s\n' '{"number":77,"headRefName":"feat/blocked","headRefOid":"abcdef123456","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","reviewDecision":"REVIEW_REQUIRED","autoMergeRequest":{"enabledAt":"2026-01-01T00:00:00Z"},"statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE","name":"ci"},{"status":"QUEUED","conclusion":"","name":"deploy"}]}'
    ;;
  *"pr view 78"* )
    printf '%s\n' '{"number":78,"headRefName":"feat/green","headRefOid":"987654321abc","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","reviewDecision":"APPROVED","autoMergeRequest":null,"statusCheckRollup":[{"state":"SUCCESS","context":"ci"}]}'
    ;;
  *"pr view 79"* )
    printf '%s\n' '{"number":79,"headRefName":"feat/deploy-wait","headRefOid":"deadbeefcafe","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","reviewDecision":"APPROVED","autoMergeRequest":null,"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"ci"},{"status":"IN_PROGRESS","conclusion":"","name":"Deploy gate / dev"}]}'
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  PR_SIGNAL_BASE_FETCH=0 \
  bash "$SANITIZED_ROOT/scripts/pr_block_signals.sh" "$TEST_TMP/config.sh" --tsv
)

[[ "$output" == *$'pr\tbranch\thead\tagent'* ]] || fail "missing header: $output"
[[ "$output" == *$'77\tfeat/blocked\tabcdef12\tagent-one\tBLOCKED\tMERGEABLE\tREVIEW_REQUIRED\t1\t1\t0\t'* ]] || fail "missing row: $output"
[[ "$output" == *"merge-blocked"* ]] || fail "missing merge-blocked signal: $output"
[[ "$output" == *"review-required"* ]] || fail "missing review-required signal: $output"
[[ "$output" == *"ci-failed"* ]] || fail "missing ci-failed signal: $output"
[[ "$output" == *"ci-pending"* ]] || fail "missing ci-pending signal: $output"
[[ "$output" == *"auto-merge-armed"* ]] || fail "missing auto-merge signal: $output"
[[ "$output" == *"needs-rebase"* ]] || fail "missing needs-rebase signal: $output"
[[ "$output" == *$'78\tfeat/green\t98765432\t\tCLEAN\tMERGEABLE\tAPPROVED\t0\t0\t\tci-pass,merge-ready'* ]] || \
  fail "missing green signal row: $output"
[[ "$output" == *"deploy-gate-external-wait"* ]] || fail "missing deploy-gate-external-wait signal: $output"

json_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  PR_SIGNAL_BASE_FETCH=0 \
  bash "$SANITIZED_ROOT/scripts/pr_block_signals.sh" "$TEST_TMP/config.sh" --json
)

printf '%s' "$json_output" | jq -e '
  (map(select(.pr == "77"))[0].signals | index("needs-rebase") and index("auto-merge-armed")) and
  (map(select(.pr == "78"))[0].signals | index("ci-pass") and index("merge-ready")) and
  (map(select(.pr == "79"))[0] as $p | $p.deploy_gate_pending == 1 and ($p.signals | index("deploy-gate-external-wait")) and ($p.signals | index("ci-failed") | not))
' >/dev/null \
  || fail "unexpected JSON output: $json_output"

printf 'ok - pr_block_signals reports silent merge blockers and green PRs\n'
