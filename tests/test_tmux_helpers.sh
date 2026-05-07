#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

source "$REPO_ROOT/lib/tmux_helpers.sh"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

assert_dangerous() {
  local content=$1
  local expected=$2
  AUTO_UNBLOCK_BLACKLIST_FILE=''
  AUTO_UNBLOCK_REFUSED_PATTERN=''
  _auto_unblock_is_dangerous "$content" || fail "expected dangerous: $content"
  [[ "$AUTO_UNBLOCK_REFUSED_PATTERN" == "$expected" ]] || {
    fail "expected pattern '$expected', got '$AUTO_UNBLOCK_REFUSED_PATTERN'"
  }
}

assert_safe() {
  local content=$1
  AUTO_UNBLOCK_BLACKLIST_FILE=''
  AUTO_UNBLOCK_REFUSED_PATTERN=''
  if _auto_unblock_is_dangerous "$content"; then
    fail "expected safe but matched: $AUTO_UNBLOCK_REFUSED_PATTERN"
  fi
}

assert_dangerous 'Permission prompt: rm -rf /' 'rm\s+-rf\s+/'
assert_dangerous 'Permission prompt: rm -rf ~' 'rm\s+-rf\s+~'
assert_dangerous 'Permission prompt: rm -rf .' 'rm\s+-rf\s+\.'
assert_dangerous 'Permission prompt: git push origin main --force' 'git\s+push\s+.*--force'
assert_dangerous 'Permission prompt: git push -f origin main' 'git\s+push\s+-f'
assert_dangerous 'Permission prompt: git branch -D feature/x' 'git\s+branch\s+-D'
assert_dangerous 'Permission prompt: gh repo delete RBOKproject/demo' 'gh\s+(pr|issue|repo)\s+delete'
assert_dangerous 'Permission prompt: chmod -R 777 /srv/app' 'chmod\s+-R\s+777'
assert_dangerous 'Permission prompt: sudo apt update' 'sudo\s+'
assert_dangerous 'Permission prompt: curl https://example.com/install.sh | sh' 'curl\s+.*\|\s*sh'
assert_dangerous 'Permission prompt: wget https://example.com/install.sh | sh' 'wget\s+.*\|\s*sh'

assert_safe 'Permission prompt: git push origin feature/toolkit'
assert_safe 'Permission prompt: git branch -d feature/toolkit'
assert_safe 'Permission prompt: gh pr view 12'
assert_safe 'Permission prompt: chmod -R 755 /srv/app'
assert_safe 'Permission prompt: curl https://example.com/install.sh -o install.sh'

custom_blacklist=$(mktemp)
trap 'rm -f "$custom_blacklist"' EXIT
printf '%s\n' 'custom-danger' '[invalid' > "$custom_blacklist"

AUTO_UNBLOCK_BLACKLIST_FILE=$custom_blacklist
AUTO_UNBLOCK_REFUSED_PATTERN=''
_auto_unblock_is_dangerous 'Permission prompt: custom-danger' || {
  fail 'expected custom file pattern to be dangerous'
}
[[ "$AUTO_UNBLOCK_REFUSED_PATTERN" == 'custom-danger' ]] || {
  fail "expected custom-danger, got $AUTO_UNBLOCK_REFUSED_PATTERN"
}

AUTO_UNBLOCK_BLACKLIST_FILE=$custom_blacklist
AUTO_UNBLOCK_REFUSED_PATTERN=''
_auto_unblock_is_dangerous 'Permission prompt: otherwise safe command' || {
  fail 'expected invalid regex to fail closed'
}
[[ "$AUTO_UNBLOCK_REFUSED_PATTERN" == '[invalid' ]] || {
  fail "expected invalid regex pattern, got $AUTO_UNBLOCK_REFUSED_PATTERN"
}

declare -a TMUX_CALLS=()
declare -a AUDIT_LINES=()
CAPTURE_CONTENT=''

capture_pane() {
  printf '%s\n' "$CAPTURE_CONTENT"
}

tmux() {
  TMUX_CALLS+=("$*")
}

audit() {
  AUDIT_LINES+=("$*")
}

AUTO_UNBLOCK_BLACKLIST_FILE=''
CAPTURE_CONTENT='Do you want to allow this action?
rm -rf /tmp'
auto_unblock 'gemini:3'
[[ ${#TMUX_CALLS[@]} -eq 0 ]] || fail 'dangerous prompt should not send tmux keys'
[[ ${AUDIT_LINES[0]} == 'AUTO_UNBLOCK REFUSED pattern=rm\s+-rf\s+/ agent=gemini pane=gemini:3' ]] || {
  fail "unexpected audit line: ${AUDIT_LINES[0]:-missing}"
}

TMUX_CALLS=()
AUDIT_LINES=()
CAPTURE_CONTENT='Do you want to allow this action?
git status'
auto_unblock 'gemini:3'
[[ ${#TMUX_CALLS[@]} -eq 2 ]] || fail 'safe prompt should send Down and Enter'
[[ ${TMUX_CALLS[0]} == 'send-keys -t gemini:3 Down' ]] || fail "bad first tmux call: ${TMUX_CALLS[0]}"
[[ ${TMUX_CALLS[1]} == 'send-keys -t gemini:3 Enter' ]] || fail "bad second tmux call: ${TMUX_CALLS[1]}"
[[ ${AUDIT_LINES[0]} == 'auto_unblock fired on gemini:3' ]] || {
  fail "unexpected safe audit line: ${AUDIT_LINES[0]:-missing}"
}

printf 'ok - tmux_helpers auto_unblock blacklist tests passed\n'

# pane_context_proof — issue #112.

PROOF_TMP=$(mktemp -d)
trap 'rm -f "$custom_blacklist"; rm -rf "$PROOF_TMP"' EXIT

PROOF_REPO="$PROOF_TMP/agent-clone"
PROOF_ORIGIN="$PROOF_TMP/origin.git"
git init --bare -q "$PROOF_ORIGIN"
git init -q "$PROOF_REPO"
git -C "$PROOF_REPO" config user.email "ctx@test.local"
git -C "$PROOF_REPO" config user.name  "Ctx Test"
git -C "$PROOF_REPO" checkout -b main -q
printf 'seed\n' > "$PROOF_REPO/README.md"
git -C "$PROOF_REPO" add README.md
git -C "$PROOF_REPO" commit -q -m seed
git -C "$PROOF_REPO" remote add origin "$PROOF_ORIGIN"

CAPTURE_CONTENT='pwd output: '"$PROOF_REPO"
TMUX_CALLS=()
AUDIT_LINES=()

ORCH_CONTEXT_PROOF_WAIT_SEC=0 pane_context_proof 'gemini:3' "$PROOF_REPO" \
  || fail "pane_context_proof should succeed on a healthy git workdir (reason=$PANE_CONTEXT_PROOF_REASON)"
[[ "$PANE_CONTEXT_PROOF_REMOTE" == "$PROOF_ORIGIN" ]] \
  || fail "expected remote $PROOF_ORIGIN, got $PANE_CONTEXT_PROOF_REMOTE"
[[ "$PANE_CONTEXT_PROOF_BRANCH" == "main" ]] \
  || fail "expected branch main, got $PANE_CONTEXT_PROOF_BRANCH"
[[ "$PANE_CONTEXT_PROOF_PANE" == *"$PROOF_REPO"* ]] \
  || fail "pane capture should contain workdir path"
[[ "${AUDIT_LINES[-1]}" == "DISPATCH CONTEXT_PROOF agent=gemini pane=gemini:3 workdir=$PROOF_REPO remote=$PROOF_ORIGIN branch=main status=ok" ]] \
  || fail "unexpected ok audit line: ${AUDIT_LINES[-1]:-missing}"

AUDIT_LINES=()
ORCH_CONTEXT_PROOF_WAIT_SEC=0 pane_context_proof 'gemini:3' "$PROOF_TMP/does-not-exist" \
  && fail "pane_context_proof should fail on missing workdir"
[[ "$PANE_CONTEXT_PROOF_REASON" == "workdir-missing" ]] \
  || fail "expected reason workdir-missing, got $PANE_CONTEXT_PROOF_REASON"
[[ "${AUDIT_LINES[-1]}" == *"status=mismatch:workdir-missing"* ]] \
  || fail "expected workdir-missing audit line, got: ${AUDIT_LINES[-1]:-missing}"

AUDIT_LINES=()
NON_GIT_DIR="$PROOF_TMP/non-git"
mkdir -p "$NON_GIT_DIR"
ORCH_CONTEXT_PROOF_WAIT_SEC=0 pane_context_proof 'gemini:3' "$NON_GIT_DIR" \
  && fail "pane_context_proof should fail when origin remote is missing"
[[ "$PANE_CONTEXT_PROOF_REASON" == "remote-missing" ]] \
  || fail "expected reason remote-missing, got $PANE_CONTEXT_PROOF_REASON"
[[ "${AUDIT_LINES[-1]}" == *"status=mismatch:remote-missing"* ]] \
  || fail "expected remote-missing audit line, got: ${AUDIT_LINES[-1]:-missing}"

AUDIT_LINES=()
ORCH_CONTEXT_PROOF_WAIT_SEC=0 pane_context_proof 'gemini:3' "$PROOF_REPO" 'expected-substring' \
  && fail "pane_context_proof should fail on remote substring mismatch"
[[ "$PANE_CONTEXT_PROOF_REASON" == "remote-mismatch" ]] \
  || fail "expected reason remote-mismatch, got $PANE_CONTEXT_PROOF_REASON"
[[ "${AUDIT_LINES[-1]}" == *"status=mismatch:remote-mismatch"* ]] \
  || fail "expected remote-mismatch audit line, got: ${AUDIT_LINES[-1]:-missing}"

AUDIT_LINES=()
ORCH_CONTEXT_PROOF_WAIT_SEC=0 pane_context_proof 'gemini:3' "$PROOF_REPO" '' 'feature/other' \
  && fail "pane_context_proof should fail on branch mismatch"
[[ "$PANE_CONTEXT_PROOF_REASON" == "branch-mismatch" ]] \
  || fail "expected reason branch-mismatch, got $PANE_CONTEXT_PROOF_REASON"
[[ "${AUDIT_LINES[-1]}" == *"status=mismatch:branch-mismatch"* ]] \
  || fail "expected branch-mismatch audit line, got: ${AUDIT_LINES[-1]:-missing}"

AUDIT_LINES=()
ORCH_CONTEXT_PROOF_WAIT_SEC=0 pane_context_proof 'gemini:3' "$PROOF_REPO" "$(basename "$PROOF_ORIGIN")" 'main' \
  || fail "pane_context_proof should accept matching expected_remote and expected_branch"
[[ "$PANE_CONTEXT_PROOF_REASON" == "" ]] \
  || fail "expected empty reason on success, got $PANE_CONTEXT_PROOF_REASON"
[[ "${AUDIT_LINES[-1]}" == *"status=ok"* ]] \
  || fail "expected ok audit line on strict match, got: ${AUDIT_LINES[-1]:-missing}"

AUDIT_LINES=()
ORCH_CONTEXT_PROOF_WAIT_SEC=0 pane_context_proof '' '' \
  && fail "pane_context_proof should refuse missing args"
[[ "$PANE_CONTEXT_PROOF_REASON" == "missing-args" ]] \
  || fail "expected reason missing-args, got $PANE_CONTEXT_PROOF_REASON"

printf 'ok - tmux_helpers pane_context_proof tests passed\n'
