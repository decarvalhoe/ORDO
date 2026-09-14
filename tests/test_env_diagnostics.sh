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
  scripts/env_diagnostics.sh

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/clones-root/clean-clone" \
  "$TEST_TMP/clones-root/dirty-clone" "$TEST_TMP/clones-root/not-a-clone" \
  "$TEST_TMP/audit-base"

# --- Mock tmux: report 2 sessions, simulate live-target probe ---
cat > "$TEST_TMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list-sessions)
    printf '%s\n' \
      'rbok-copilot|1|attached' \
      'rbok-claude|1|detached'
    ;;
  display-message)
    target=""
    fmt=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target="$2"; shift 2 ;;
        -F) fmt="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    case "$fmt" in
      '#{pane_current_path}') printf '/root/rbokproject-fleet-20260508-clean/repos/ordo/%s\n' "${target%%:*}" ;;
      '#{pane_current_command}') printf 'claude\n' ;;
    esac
    ;;
  *) ;;
esac
EOF
chmod +x "$TEST_TMP/bin/tmux"

# --- Mock gh: report authenticated; produce open issue + PR lists ---
cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"auth status"* )
    printf '%s\n' "✓ Logged in to github.com account RBOKCLIcopilot"
    ;;
  *"repo view"* )
    # The provider adapter (#816) asks `repo view R --json ...` and reads
    # defaultBranchRef.name from the JSON payload.
    printf '%s\n' '{"name":"ORDO","nameWithOwner":"RBOKproject/ORDO","defaultBranchRef":{"name":"main"}}'
    ;;
  *"issue list"* )
    printf '%s\n' '[{"number":1},{"number":2},{"number":3}]'
    ;;
  *"pr list"* )
    printf '%s\n' '[{"number":10,"baseRefName":"main"},{"number":11,"baseRefName":"main"},{"number":12,"baseRefName":"release-2026-05"}]'
    ;;
  *) printf '%s\n' '[]' ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

export PATH="$TEST_TMP/bin:$PATH"

# Clean clone
git -C "$TEST_TMP/clones-root/clean-clone" init -q
git -C "$TEST_TMP/clones-root/clean-clone" config user.email t@t.local
git -C "$TEST_TMP/clones-root/clean-clone" config user.name "t"
printf 'one\n' > "$TEST_TMP/clones-root/clean-clone/file.txt"
git -C "$TEST_TMP/clones-root/clean-clone" add file.txt
git -C "$TEST_TMP/clones-root/clean-clone" commit -q -m "seed"

# Dirty clone
git -C "$TEST_TMP/clones-root/dirty-clone" init -q
git -C "$TEST_TMP/clones-root/dirty-clone" config user.email t@t.local
git -C "$TEST_TMP/clones-root/dirty-clone" config user.name "t"
printf 'one\n' > "$TEST_TMP/clones-root/dirty-clone/file.txt"
git -C "$TEST_TMP/clones-root/dirty-clone" add file.txt
git -C "$TEST_TMP/clones-root/dirty-clone" commit -q -m "seed"
printf 'two\n' >> "$TEST_TMP/clones-root/dirty-clone/file.txt"

run_diag() {
  bash "$SANITIZED_ROOT/scripts/env_diagnostics.sh" "$@"
}

# --- 1. tmux subcommand emits live-target probe per session ---
output=$(run_diag tmux)
[[ "$output" == *"tmux.status=ok"* ]] || fail "tmux.status should be ok: $output"
[[ "$output" == *"tmux.session.count=2"* ]] || fail "should report 2 sessions: $output"
[[ "$output" == *"tmux.session.1.live_target=rbok-copilot:0.0"* ]] || fail "should probe live session:0.0 target: $output"
[[ "$output" == *"tmux.session.1.pane_current_path="* ]] || fail "should probe pane_current_path: $output"

# --- 2. pane subcommand emits command + path ---
output=$(run_diag pane rbok-copilot:0.0)
[[ "$output" == *"pane.rbok-copilot:0.0.status=ok"* ]] || fail "pane status should be ok: $output"
[[ "$output" == *"pane.rbok-copilot:0.0.command=claude"* ]] || fail "pane command should be reported: $output"

# --- 3. memory + load + disk are read-only ---
output=$(run_diag memory)
[[ "$output" == *"memory.status=ok"* ]] || fail "memory.status should be ok: $output"
[[ "$output" == *"memory.total_mb="* ]] || fail "should emit memory.total_mb: $output"
output=$(run_diag load)
[[ "$output" == *"load.status="* ]] || fail "should emit load.status: $output"
output=$(run_diag disk /)
[[ "$output" == *"disk.status=ok"* ]] || fail "disk.status should be ok: $output"
[[ "$output" == *"disk.1.path=/"* ]] || fail "disk.1.path should be /: $output"

# --- 4. docker subcommand handles missing daemon gracefully (read-only) ---
output=$(run_diag docker)
[[ "$output" == *"docker.status="* ]] || fail "docker.status should be reported: $output"

# --- 5. api subcommand emits http_code (000 is acceptable when unreachable) ---
# Use a deliberately unreachable URL to keep this test offline-safe.
output=$(run_diag api http://127.0.0.1:1 1 2>&1 || true)
[[ "$output" == *"api.url=http://127.0.0.1:1"* ]] || fail "api.url should be reported: $output"
[[ "$output" == *"api.http_code="* ]] || fail "api.http_code should be reported: $output"

# --- 6. gh-auth + gh-repo use mock gh ---
output=$(run_diag gh-auth)
[[ "$output" == *"gh.status=authenticated"* ]] || fail "gh.status should be authenticated: $output"

output=$(run_diag gh-repo RBOKproject/ORDO)
[[ "$output" == *"gh.repo=RBOKproject/ORDO"* ]] || fail "gh.repo should be set: $output"
[[ "$output" == *"gh.issues_open=3"* ]] || fail "gh.issues_open should be 3: $output"
[[ "$output" == *"gh.prs_open_default_base=2"* ]] || fail "gh.prs_open_default_base should be 2: $output"
[[ "$output" == *"gh.prs_open_non_default_base=1"* ]] || fail "gh.prs_open_non_default_base should be 1: $output"

# --- 7. clones subcommand finds dirty clone, skips clean ---
output=$(run_diag clones "$TEST_TMP/clones-root")
[[ "$output" == *"dirty.status=ok"* ]] || fail "dirty.status should be ok: $output"
[[ "$output" == *"dirty.count=1"* ]] || fail "dirty.count should be 1 (only the dirty clone): $output"
[[ "$output" == *"dirty.1.workdir="*"dirty-clone"* ]] || fail "dirty workdir should be reported: $output"

# --- 8. audit-name resolves canonical paths for each kind ---
export ORCH_ENV_DIAG_AUDIT_BASE="$TEST_TMP/audit-base"
output=$(run_diag audit-name snapshot fleet-X)
[[ "$output" == "$TEST_TMP/audit-base/snapshots/fleet-X.tsv" ]] || fail "audit-name snapshot path wrong: $output"
output=$(run_diag audit-name ledger findings)
[[ "$output" == "$TEST_TMP/audit-base/ledgers/findings.jsonl" ]] || fail "audit-name ledger path wrong: $output"
output=$(run_diag audit-name matrix dispatch)
[[ "$output" == "$TEST_TMP/audit-base/matrices/dispatch.tsv" ]] || fail "audit-name matrix path wrong: $output"
output=$(run_diag audit-name monitor ci-watcher)
[[ "$output" == "$TEST_TMP/audit-base/monitors/ci-watcher.log" ]] || fail "audit-name monitor path wrong: $output"
unset ORCH_ENV_DIAG_AUDIT_BASE

# --- 9. audit-name rejects unknown kinds (read-only refusal) ---
set +e
output=$(run_diag audit-name unknown id 2>&1)
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "audit-name should refuse unknown kind"
[[ "$output" == *"unknown kind"* ]] || fail "audit-name should report unknown kind: $output"

# --- 10. preflight aggregates probes and stays read-only ---
output=$(run_diag preflight --repo RBOKproject/ORDO --clones-root "$TEST_TMP/clones-root")
for marker in \
  "preflight.started_at=" \
  "preflight.finished_at=" \
  "tmux.status=" \
  "load.status=" \
  "memory.status=" \
  "disk.status=" \
  "docker.status=" \
  "gh.status=" \
  "gh.repo=RBOKproject/ORDO" \
  "dirty.status=ok"
do
  [[ "$output" == *"$marker"* ]] || fail "preflight missing key: $marker"
done

# --- 11. preflight --json emits structured object when jq is available ---
if command -v jq >/dev/null 2>&1; then
  json=$(run_diag preflight --json --repo RBOKproject/ORDO --clones-root "$TEST_TMP/clones-root")
  jq -e '.["tmux.status"] != null' <<< "$json" >/dev/null \
    || fail "json should contain tmux.status: $json"
  jq -e '.["gh.issues_open"] == "3"' <<< "$json" >/dev/null \
    || fail "json should preserve gh.issues_open: $json"
fi

# --- 12. unknown subcommand exits non-zero (no implicit mutation) ---
set +e
run_diag mutate-everything >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "unknown subcommand should exit non-zero"

# --- 13. doc + script discoverability (matches issue #255 validation) ---
grep -Eq "preflight|diagnostics|tmux shape|dirty clones|non-default-base PR|read-only" \
  "$ROOT/docs/env-diagnostics.md" \
  || fail "docs/env-diagnostics.md should match issue #255 validation grep"
grep -Eq "preflight|diagnostics|read-only" "$ROOT/scripts/env_diagnostics.sh" \
  || fail "scripts/env_diagnostics.sh should match issue #255 validation grep"

printf 'ok - env_diagnostics aggregates tmux/load/memory/disk/docker/api/gh/issues/PRs/clones; read-only by default; canonical audit artifact naming\n'
