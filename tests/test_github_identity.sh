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
  scripts/dispatch_ticket.sh
chmod +x "$SANITIZED_ROOT/scripts/dispatch_ticket.sh"

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/logs" "$TEST_TMP/repos/writer" "$TEST_TMP/gh"

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GH_MOCK_LOG"

if [[ "${1:-}" == "api" && "${2:-}" == "user" ]]; then
  printf '%s\n' "${GH_MOCK_ACTIVE_LOGIN:-unknown-login}"
  exit 0
fi

if [[ "${1:-} ${2:-} ${3:-}" == "issue edit 501" ]]; then
  printf '%s\n' "issue-edit-write" >> "$GH_MOCK_WRITES"
  printf '%s\n' '{}'
  exit 0
fi

captured=""
declare -a captured_argv=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --body-file)
      captured="$2"
      shift 2
      ;;
    *)
      captured_argv+=("$1")
      shift
      ;;
  esac
done

if [[ -n "$captured" ]]; then
  printf '%s\n' "body-file-write" >> "$GH_MOCK_WRITES"
  cp "$captured" "$GH_MOCK_BODY"
  printf '%s\n' "${captured_argv[@]}" > "$GH_MOCK_ARGV"
  exit 0
fi

printf '%s\n' '{}'
EOF
chmod +x "$TEST_TMP/bin/gh"

cat > "$TEST_TMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  has-session|list-panes|send-keys)
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

export PATH="$TEST_TMP/bin:$PATH"
export GH_MOCK_LOG="$TEST_TMP/logs/gh.log"
export GH_MOCK_WRITES="$TEST_TMP/logs/gh-writes.log"
export GH_MOCK_BODY="$TEST_TMP/logs/body.md"
export GH_MOCK_ARGV="$TEST_TMP/logs/argv.txt"
export GH_CONFIG_DIR="$TEST_TMP/gh"
unset GH_TOKEN GITHUB_TOKEN

: > "$GH_MOCK_LOG"
: > "$GH_MOCK_WRITES"

# shellcheck source=../lib/config_resolver.sh
source "$ROOT/lib/config_resolver.sh"
# shellcheck source=../lib/github_identity.sh
source "$ROOT/lib/github_identity.sh"

# shellcheck disable=SC2034  # consumed by resolve_agent_github_login
AGENT_GH_LOGINS=("writer=writer-bot")
GH_MOCK_ACTIVE_LOGIN="writer-bot" orch_github_identity_guard_for_agent writer "unit-match" \
  || fail "matching active GitHub login should pass"

set +e
mismatch_output=$(
  GH_TOKEN="token-selects-other-account" GH_MOCK_ACTIVE_LOGIN="other-bot" \
  orch_github_identity_guard_for_agent writer "unit-mismatch" 2>&1
)
mismatch_status=$?
set -e
[[ "$mismatch_status" -eq 78 ]] \
  || fail "mismatched GitHub login should exit 78, got $mismatch_status: $mismatch_output"
[[ "$mismatch_output" == *"github_identity_mismatch"* \
  && "$mismatch_output" == *"expected=writer-bot"* \
  && "$mismatch_output" == *"active=other-bot"* \
  && "$mismatch_output" == *"token_override=GH_TOKEN"* ]] \
  || fail "mismatch output should include explicit signal, logins, and token override, got: $mismatch_output"

ORCH_EXPECTED_GH_LOGIN="writer-bot" \
  GH_MOCK_ACTIVE_LOGIN="writer-bot" \
  orch_github_identity_guard_for_command "unit-command" issue comment 41 \
  || fail "write command guard should pass when account matches"

ORCH_EXPECTED_GH_LOGIN="writer-bot" \
  GH_MOCK_ACTIVE_LOGIN="other-bot" \
  orch_github_identity_guard_for_command "unit-command-read" issue view 41 \
  || fail "read command guard should not require identity"

set +e
command_mismatch_output=$(
  ORCH_EXPECTED_GH_LOGIN="writer-bot" \
  GH_MOCK_ACTIVE_LOGIN="other-bot" \
  orch_github_identity_guard_for_command "unit-command-write" issue close 41 2>&1
)
command_mismatch_status=$?
set -e
[[ "$command_mismatch_status" -eq 78 ]] \
  || fail "write command guard should refuse mismatch with 78, got $command_mismatch_status: $command_mismatch_output"
[[ "$command_mismatch_output" == *"github_identity_mismatch"* ]] \
  || fail "write command guard should report github_identity_mismatch, got: $command_mismatch_output"

set +e
token_mismatch_output=$(
  GH_TOKEN="token-one" GITHUB_TOKEN="token-two" \
  ORCH_EXPECTED_GH_LOGIN="writer-bot" \
  GH_MOCK_ACTIVE_LOGIN="other-bot" \
  orch_github_identity_guard_for_command "unit-token-write" issue close 42 2>&1
)
token_mismatch_status=$?
set -e
[[ "$token_mismatch_status" -eq 78 ]] \
  || fail "write command guard should refuse token override mismatch with 78, got $token_mismatch_status: $token_mismatch_output"
[[ "$token_mismatch_output" == *"token_override=GH_TOKEN,GITHUB_TOKEN"* ]] \
  || fail "token override mismatch should name both token variables, got: $token_mismatch_output"

# shellcheck source=../lib/gh_body_helpers.sh
source "$ROOT/lib/gh_body_helpers.sh"

body='safe body'
printf '%s' "$body" | \
  GH_MOCK_ACTIVE_LOGIN="writer-bot" ORCH_EXPECTED_GH_LOGIN="writer-bot" \
  gh_issue_comment_body_file 41 --repo example/repo \
  || fail "body-file write should pass with matching account"
grep -q '^body-file-write$' "$GH_MOCK_WRITES" \
  || fail "expected matching body-file helper to invoke gh write"

: > "$GH_MOCK_WRITES"
set +e
body_mismatch_output=$(
  printf '%s' "$body" | \
    GH_MOCK_ACTIVE_LOGIN="other-bot" ORCH_EXPECTED_GH_LOGIN="writer-bot" \
    gh_issue_comment_body_file 42 --repo example/repo 2>&1
)
body_mismatch_status=$?
set -e
[[ "$body_mismatch_status" -eq 78 ]] \
  || fail "body-file helper should refuse mismatch with 78, got $body_mismatch_status: $body_mismatch_output"
[[ "$body_mismatch_output" == *"github_identity_mismatch"* ]] \
  || fail "body-file mismatch should report github_identity_mismatch, got: $body_mismatch_output"
[[ ! -s "$GH_MOCK_WRITES" ]] \
  || fail "body-file helper must refuse before write on mismatch"

cat > "$TEST_TMP/config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="identity-test"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_WINDOW_INDEX=0
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENT_GH_LOGINS=("writer=writer-bot")
EOF

prompt="$TEST_TMP/prompt.md"
cat > "$prompt" <<'EOF'
## Objectif
Test dispatch identity guard.

## Format de sortie attendu
Report status.

## Tools / sources autorises
Use mocked tools only.

## Boundaries / interdictions
Stay in test scope.

## Definition of Done verifiable
Guard was exercised.

## Preuves attendues
Focused mocked output.

This prompt includes enough filler for prompt integrity validation. It is a
generic local fixture and does not represent a live project, host, account, or
provider. The remaining text exists only to exceed the minimum byte threshold
used by dispatch prompt integrity checks in tests.
EOF

: > "$GH_MOCK_WRITES"
set +e
dispatch_output=$(
  GH_MOCK_ACTIVE_LOGIN="other-bot" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_CONTEXT_PROOF=0 \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" \
    "$TEST_TMP/config.sh" writer 501 "$prompt" --assign 2>&1
)
dispatch_status=$?
set -e
[[ "$dispatch_status" -eq 78 ]] \
  || fail "dispatch --assign should refuse mismatch with 78, got $dispatch_status: $dispatch_output"
[[ "$dispatch_output" == *"github_identity_mismatch"* ]] \
  || fail "dispatch mismatch should report github_identity_mismatch, got: $dispatch_output"
[[ ! -s "$GH_MOCK_WRITES" ]] \
  || fail "dispatch --assign must refuse before gh issue edit write"

printf 'ok - github identity guard refuses drift before GitHub writes\n'
