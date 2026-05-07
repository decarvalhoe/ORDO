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

local_head_full=$(git -C "$repo" rev-parse HEAD)

# Scenario A: PR 77 has a fake (different) headRefOid -> remote-rebased-local-stale.
# Scenario B: PR 78 is green on a non-owned branch.
cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"* )
    printf '%s\n' '[{"number":77},{"number":78},{"number":79}]'
    ;;
  *"pr view 77"* )
    printf '%s\n' '{"number":77,"headRefName":"feat/blocked","headRefOid":"abcdef123456789012345678901234567890abcd","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","reviewDecision":"REVIEW_REQUIRED","autoMergeRequest":{"enabledAt":"2026-01-01T00:00:00Z"},"statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE","name":"ci"},{"status":"QUEUED","conclusion":"","name":"deploy"}]}'
    ;;
  *"pr view 78"* )
    printf '%s\n' '{"number":78,"headRefName":"feat/green","headRefOid":"987654321abcdef0987654321abcdef098765432","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","reviewDecision":"APPROVED","autoMergeRequest":null,"statusCheckRollup":[{"state":"SUCCESS","context":"ci"}]}'
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

# Append a 79 view that returns headRefOid matching local HEAD -> genuine needs-rebase.
cat >> "$TEST_TMP/bin/gh" <<EOF

# overwrite to inject scenario for PR 79
EOF

cat > "$TEST_TMP/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"pr list"* )
    printf '%s\n' '[{"number":77},{"number":78},{"number":79}]'
    ;;
  *"pr view 77"* )
    printf '%s\n' '{"number":77,"headRefName":"feat/blocked","headRefOid":"abcdef123456789012345678901234567890abcd","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","reviewDecision":"REVIEW_REQUIRED","autoMergeRequest":{"enabledAt":"2026-01-01T00:00:00Z"},"statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE","name":"ci"},{"status":"QUEUED","conclusion":"","name":"deploy"}]}'
    ;;
  *"pr view 78"* )
    printf '%s\n' '{"number":78,"headRefName":"feat/green","headRefOid":"987654321abcdef0987654321abcdef098765432","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","reviewDecision":"APPROVED","autoMergeRequest":null,"statusCheckRollup":[{"state":"SUCCESS","context":"ci"}]}'
    ;;
  *"pr view 79"* )
    printf '%s\n' '{"number":79,"headRefName":"feat/blocked","headRefOid":"$local_head_full","isDraft":false,"mergeStateStatus":"BEHIND","mergeable":"MERGEABLE","reviewDecision":"APPROVED","autoMergeRequest":null,"statusCheckRollup":[{"state":"SUCCESS","context":"ci"}]}'
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
[[ "$output" == *"remote-rebased-local-stale"* ]] || fail "missing remote-rebased-local-stale signal: $output"
[[ "$output" == *$'78\tfeat/green\t98765432\t\tCLEAN\tMERGEABLE\tAPPROVED\t0\t0\t\tci-pass,merge-ready'* ]] || \
  fail "missing green signal row: $output"

json_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  PR_SIGNAL_BASE_FETCH=0 \
  bash "$SANITIZED_ROOT/scripts/pr_block_signals.sh" "$TEST_TMP/config.sh" --json
)

printf '%s' "$json_output" | jq -e '
  (map(select(.pr == "77"))[0].signals | index("remote-rebased-local-stale") and index("auto-merge-armed")) and
  ((map(select(.pr == "77"))[0].signals | index("needs-rebase")) | not) and
  (map(select(.pr == "78"))[0].signals | index("ci-pass") and index("merge-ready")) and
  (map(select(.pr == "79"))[0].signals | index("needs-rebase")) and
  ((map(select(.pr == "79"))[0].signals | index("remote-rebased-local-stale")) | not)
' >/dev/null \
  || fail "unexpected JSON output: $json_output"

printf 'ok - pr_block_signals reports silent merge blockers and green PRs\n'
