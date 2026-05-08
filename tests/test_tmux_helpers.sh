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

# --- tmux_pane_values_batch escaped separator (issue #386) -------------------
# Some tmux installs emit the US separator as the literal 4-char escape
# `\037` instead of the raw 0x1f byte (observed live on rbok-tmux during
# the 2026-05-08 fleet recovery). The split must handle both forms or
# `agent_pool_status` reports `command=claude\037<path>` with empty
# `live_pane_cwd`, which is the exact live-cwd evidence gap #386 calls out.
batch_split() {
  # shellcheck disable=SC2317  # invoked indirectly by tmux_pane_values_batch
  tmux() {
    printf '%s\n' "$BATCH_RAW"
  }
  local cmd_out path_out
  tmux_pane_values_batch 'rbok-cursor:0' cmd_out path_out 1 \
    || fail "tmux_pane_values_batch returned non-zero on raw=$BATCH_RAW"
  printf '%s\037%s\n' "$cmd_out" "$path_out"
  unset -f tmux
}

# Raw 0x1f byte (the historical, fast-path case).
BATCH_RAW=$'claude\x1f/repos/target'
result=$(batch_split)
[[ "$result" == $'claude\x1f/repos/target' ]] \
  || fail "raw 0x1f split: expected claude<US>/repos/target, got $result"

# Literal escape `\037` (issue #386 regression).
BATCH_RAW='claude\037/repos/target'
result=$(batch_split)
[[ "$result" == $'claude\x1f/repos/target' ]] \
  || fail "literal \\037 split: expected claude<US>/repos/target, got $result"

# Literal escape with a path containing legitimate backslash sequences —
# only the FIRST `\037` separates command from path; downstream literal
# backslashes in the path must survive untouched.
BATCH_RAW='claude\037/repos/with\backslash'
result=$(batch_split)
[[ "$result" == $'claude\x1f/repos/with\\backslash' ]] \
  || fail "literal \\037 split with backslashed path: got $result"

unset BATCH_RAW result
unset -f batch_split

printf 'ok - tmux_pane_values_batch handles raw and escaped separator (issue #386)\n'

# --- agent_pane_ready (issue #123) -------------------------------------------
# Stub tmux to drive the readiness handshake deterministically. State lives
# on disk because the function under test invokes tmux from inside command
# substitution `$(...)`, which runs in a subshell — bash variable mutations
# inside subshells do not persist back to the parent, so we use files.
READY_STATE_DIR=$(mktemp -d)
trap 'rm -f "$custom_blacklist"; rm -rf "$READY_STATE_DIR"' EXIT

ready_state_path()      { printf '%s\n' "$READY_STATE_DIR/path"; }
ready_state_command()   { printf '%s\n' "$READY_STATE_DIR/command"; }
ready_state_path_rc()   { printf '%s\n' "$READY_STATE_DIR/path_rc"; }
ready_state_command_rc(){ printf '%s\n' "$READY_STATE_DIR/command_rc"; }
ready_state_fail_left() { printf '%s\n' "$READY_STATE_DIR/fail_first_n"; }
ready_state_attempts()  { printf '%s\n' "$READY_STATE_DIR/attempts"; }

reset_ready_stubs() {
  : > "$(ready_state_path)"
  : > "$(ready_state_command)"
  printf '0\n' > "$(ready_state_path_rc)"
  printf '0\n' > "$(ready_state_command_rc)"
  printf '0\n' > "$(ready_state_fail_left)"
  printf '0\n' > "$(ready_state_attempts)"
  AGENT_READY_REASON=""
  AGENT_READY_DETAIL=""
  AGENT_READY_LAST_PATH=""
  AGENT_READY_LAST_COMMAND=""
}

set_ready_path()       { printf '%s\n' "$1" > "$(ready_state_path)"; }
set_ready_command()    { printf '%s\n' "$1" > "$(ready_state_command)"; }
set_ready_fail_first() { printf '%s\n' "$1" > "$(ready_state_fail_left)"; }
get_ready_attempts()   { cat "$(ready_state_attempts)" 2>/dev/null || printf '0'; }

tmux() {
  case "$1" in
    display-message)
      local n_attempts
      n_attempts=$(cat "$(ready_state_attempts)" 2>/dev/null || printf '0')
      printf '%s\n' "$((n_attempts + 1))" > "$(ready_state_attempts)"
      local arg
      for arg in "$@"; do
        # Issue #322: agent_pane_ready now uses tmux_pane_values_batch
        # so a single display-message call returns command and path
        # joined by a US (\x1f) separator. Detect that combined format
        # explicitly so existing per-attempt path/command failure
        # injection still applies.
        case "$arg" in
          *'#{pane_current_command}'*'#{pane_current_path}'*)
            local fail_left
            fail_left=$(cat "$(ready_state_fail_left)" 2>/dev/null || printf '0')
            if [[ "$fail_left" -gt 0 ]]; then
              printf '%s\n' "$((fail_left - 1))" > "$(ready_state_fail_left)"
              return 1
            fi
            local path_rc cmd_rc
            path_rc=$(cat "$(ready_state_path_rc)" 2>/dev/null || printf '0')
            [[ "$path_rc" -ne 0 ]] && return "$path_rc"
            cmd_rc=$(cat "$(ready_state_command_rc)" 2>/dev/null || printf '0')
            [[ "$cmd_rc" -ne 0 ]] && return "$cmd_rc"
            local cmd_val path_val
            cmd_val=$(cat "$(ready_state_command)" 2>/dev/null || printf '')
            path_val=$(cat "$(ready_state_path)" 2>/dev/null || printf '')
            # \037 == ASCII US (0x1f); octal form is portable across
            # bash and /bin/sh printf implementations.
            printf '%s\037%s\n' "$cmd_val" "$path_val"
            return 0
            ;;
          '#{pane_current_path}')
            local fail_left
            fail_left=$(cat "$(ready_state_fail_left)" 2>/dev/null || printf '0')
            if [[ "$fail_left" -gt 0 ]]; then
              printf '%s\n' "$((fail_left - 1))" > "$(ready_state_fail_left)"
              return 1
            fi
            local rc
            rc=$(cat "$(ready_state_path_rc)" 2>/dev/null || printf '0')
            [[ "$rc" -ne 0 ]] && return "$rc"
            cat "$(ready_state_path)" 2>/dev/null
            return 0
            ;;
          '#{pane_current_command}')
            local rc
            rc=$(cat "$(ready_state_command_rc)" 2>/dev/null || printf '0')
            [[ "$rc" -ne 0 ]] && return "$rc"
            cat "$(ready_state_command)" 2>/dev/null
            return 0
            ;;
        esac
      done
      return 0
      ;;
  esac
  return 0
}

# Case: ready — workdir matches and command is in the allowlist.
reset_ready_stubs
set_ready_path '/repos/target'
set_ready_command 'claude'
agent_pane_ready 'rbok-cursor:0' '/repos/target' 3 0 \
  || fail "expected agent_pane_ready to succeed, reason=$AGENT_READY_REASON detail=$AGENT_READY_DETAIL"
[[ -z "$AGENT_READY_REASON" ]] || fail "expected empty reason on success, got=$AGENT_READY_REASON"
[[ "$AGENT_READY_LAST_PATH" == '/repos/target' ]] || fail "expected last_path to be captured, got=$AGENT_READY_LAST_PATH"
[[ "$AGENT_READY_LAST_COMMAND" == 'claude' ]] || fail "expected last_command claude, got=$AGENT_READY_LAST_COMMAND"

# Case: workdir mismatch — should refuse with workdir-mismatch reason.
reset_ready_stubs
set_ready_path '/wrong/path'
set_ready_command 'claude'
if agent_pane_ready 'rbok-cursor:0' '/repos/target' 2 0; then
  fail 'expected agent_pane_ready to fail on workdir mismatch'
fi
[[ "$AGENT_READY_REASON" == 'workdir-mismatch' ]] || fail "expected workdir-mismatch reason, got=$AGENT_READY_REASON"
[[ "$AGENT_READY_DETAIL" == *'/wrong/path'* ]] || fail "detail should mention current path, got=$AGENT_READY_DETAIL"
[[ "$AGENT_READY_DETAIL" == *'/repos/target'* ]] || fail "detail should mention expected path, got=$AGENT_READY_DETAIL"

# Case: cli not alive — pane runs an unrecognized command.
reset_ready_stubs
set_ready_path '/repos/target'
set_ready_command 'grep'
if agent_pane_ready 'rbok-cursor:0' '/repos/target' 2 0; then
  fail 'expected agent_pane_ready to fail when CLI is not alive'
fi
[[ "$AGENT_READY_REASON" == 'cli-not-alive' ]] || fail "expected cli-not-alive reason, got=$AGENT_READY_REASON"
[[ "$AGENT_READY_DETAIL" == *'command=grep'* ]] || fail "detail should mention command, got=$AGENT_READY_DETAIL"

# Case: introspection failure on first attempts then recovery — retry must
# converge to ready.
reset_ready_stubs
set_ready_path '/repos/target'
set_ready_command 'claude'
set_ready_fail_first 2
agent_pane_ready 'rbok-cursor:0' '/repos/target' 5 0 \
  || fail "expected retry to recover, reason=$AGENT_READY_REASON detail=$AGENT_READY_DETAIL"
[[ "$(get_ready_attempts)" -ge 3 ]] || fail "expected at least 3 attempts after transient failure, got=$(get_ready_attempts)"

# Case: persistent introspection failure — should give up after retries
# with the introspection reason recorded.
reset_ready_stubs
set_ready_path '/repos/target'
set_ready_command 'claude'
set_ready_fail_first 10
if agent_pane_ready 'rbok-cursor:0' '/repos/target' 3 0; then
  fail 'expected agent_pane_ready to fail on persistent introspection failure'
fi
[[ "$AGENT_READY_REASON" == 'pane-introspection-failed' ]] || \
  fail "expected pane-introspection-failed reason, got=$AGENT_READY_REASON"

# Case: custom command allowlist — orchestrator can lock down which CLIs
# count as alive (e.g. only `claude`).
reset_ready_stubs
set_ready_path '/repos/target'
set_ready_command 'bash'
AGENT_READY_COMMAND_PATTERN='^(claude)$'
if agent_pane_ready 'rbok-cursor:0' '/repos/target' 1 0; then
  fail 'expected custom allowlist to refuse bash'
fi
[[ "$AGENT_READY_REASON" == 'cli-not-alive' ]] || fail "expected cli-not-alive under custom allowlist, got=$AGENT_READY_REASON"
unset AGENT_READY_COMMAND_PATTERN

# Restore the conservative default tmux stub used by earlier tests so
# nothing downstream depends on the readiness stub state.
unset -f tmux

printf 'ok - tmux_helpers auto_unblock blacklist tests passed\n'

# pane_context_proof — issue #112, extended #286.

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

# Re-stub tmux for the live cwd check (#286). The stub returns a configurable
# pane_current_path so the proof can compare it against the expected workdir.
PANE_CTX_LIVE_PATH="$PROOF_REPO"
PANE_CTX_LIVE_RC=0
tmux() {
  if [[ "$1" == "display-message" ]]; then
    local arg
    for arg in "$@"; do
      if [[ "$arg" == '#{pane_current_path}' ]]; then
        if [[ "$PANE_CTX_LIVE_RC" -ne 0 ]]; then
          return "$PANE_CTX_LIVE_RC"
        fi
        printf '%s\n' "$PANE_CTX_LIVE_PATH"
        return 0
      fi
    done
  fi
  return 0
}

TMUX_CALLS=()
AUDIT_LINES=()

# Strict mode + matching live cwd → success, audit includes live_workdir and route=hard.
PANE_CTX_LIVE_PATH="$PROOF_REPO"
PANE_CTX_LIVE_RC=0
ORCH_CONTEXT_PROOF_WAIT_SEC=0 pane_context_proof 'gemini:3' "$PROOF_REPO" \
  || fail "pane_context_proof should succeed on matching live cwd (reason=$PANE_CONTEXT_PROOF_REASON)"
[[ "$PANE_CONTEXT_PROOF_LIVE_PATH" == "$PROOF_REPO" ]] \
  || fail "expected live path captured, got $PANE_CONTEXT_PROOF_LIVE_PATH"
[[ "$PANE_CONTEXT_PROOF_ROUTE" == "hard" ]] \
  || fail "expected route=hard on matching cwd, got $PANE_CONTEXT_PROOF_ROUTE"
[[ "$PANE_CONTEXT_PROOF_REMOTE" == "$PROOF_ORIGIN" ]] \
  || fail "expected remote $PROOF_ORIGIN, got $PANE_CONTEXT_PROOF_REMOTE"
[[ "$PANE_CONTEXT_PROOF_BRANCH" == "main" ]] \
  || fail "expected branch main, got $PANE_CONTEXT_PROOF_BRANCH"
[[ "$PANE_CONTEXT_PROOF_PANE" == *"$PROOF_REPO"* ]] \
  || fail "pane capture should contain workdir path"
[[ "${AUDIT_LINES[-1]}" == "DISPATCH CONTEXT_PROOF agent=gemini pane=gemini:3 workdir=$PROOF_REPO live_workdir=$PROOF_REPO remote=$PROOF_ORIGIN branch=main route=hard status=ok" ]] \
  || fail "unexpected ok audit line: ${AUDIT_LINES[-1]:-missing}"

# Strict mode + mismatched live cwd → fail with live-cwd-mismatch (#286 root cause).
AUDIT_LINES=()
PANE_CTX_LIVE_PATH="/some/other/product"
PANE_CTX_LIVE_RC=0
ORCH_CONTEXT_PROOF_WAIT_SEC=0 pane_context_proof 'gemini:3' "$PROOF_REPO" \
  && fail "pane_context_proof must refuse a live cwd mismatch in strict mode"
[[ "$PANE_CONTEXT_PROOF_REASON" == "live-cwd-mismatch" ]] \
  || fail "expected live-cwd-mismatch, got $PANE_CONTEXT_PROOF_REASON"
[[ "$PANE_CONTEXT_PROOF_LIVE_PATH" == "/some/other/product" ]] \
  || fail "expected live path /some/other/product, got $PANE_CONTEXT_PROOF_LIVE_PATH"
[[ "${AUDIT_LINES[-1]}" == *"workdir=$PROOF_REPO"* ]] \
  || fail "expected expected-workdir in mismatch audit, got: ${AUDIT_LINES[-1]:-missing}"
[[ "${AUDIT_LINES[-1]}" == *"live_workdir=/some/other/product"* ]] \
  || fail "expected live_workdir in mismatch audit, got: ${AUDIT_LINES[-1]:-missing}"
[[ "${AUDIT_LINES[-1]}" == *"status=mismatch:live-cwd-mismatch"* ]] \
  || fail "expected mismatch:live-cwd-mismatch, got: ${AUDIT_LINES[-1]:-missing}"

# Soft-routing accepted + mismatched live cwd → success, audit records soft route.
AUDIT_LINES=()
PANE_CTX_LIVE_PATH="/some/other/product"
PANE_CTX_LIVE_RC=0
ORCH_CONTEXT_PROOF_WAIT_SEC=0 pane_context_proof 'gemini:3' "$PROOF_REPO" '' '' 'accept-soft-routed' \
  || fail "accept-soft-routed mode should pass on mismatched live cwd (reason=$PANE_CONTEXT_PROOF_REASON)"
[[ "$PANE_CONTEXT_PROOF_ROUTE" == "soft-routed" ]] \
  || fail "expected route=soft-routed, got $PANE_CONTEXT_PROOF_ROUTE"
[[ "${AUDIT_LINES[-1]}" == *"route=soft-routed"* ]] \
  || fail "expected route=soft-routed in audit, got: ${AUDIT_LINES[-1]:-missing}"
[[ "${AUDIT_LINES[-1]}" == *"status=ok"* ]] \
  || fail "expected status=ok on soft-routed accept, got: ${AUDIT_LINES[-1]:-missing}"

# Strict mode + unreadable live cwd (tmux failure) + REQUIRE_LIVE_CWD=1 → fail.
AUDIT_LINES=()
PANE_CTX_LIVE_PATH=""
PANE_CTX_LIVE_RC=1
ORCH_CONTEXT_PROOF_REQUIRE_LIVE_CWD=1 \
  ORCH_CONTEXT_PROOF_WAIT_SEC=0 pane_context_proof 'gemini:3' "$PROOF_REPO" \
  && fail "strict mode must refuse unreadable live cwd when REQUIRE_LIVE_CWD=1"
[[ "$PANE_CONTEXT_PROOF_REASON" == "live-cwd-unreadable" ]] \
  || fail "expected live-cwd-unreadable, got $PANE_CONTEXT_PROOF_REASON"

# Strict mode + unreadable live cwd + REQUIRE_LIVE_CWD=0 → fall back to legacy
# behavior so degraded tmux servers do not regress.
AUDIT_LINES=()
PANE_CTX_LIVE_PATH=""
PANE_CTX_LIVE_RC=1
ORCH_CONTEXT_PROOF_REQUIRE_LIVE_CWD=0 \
  ORCH_CONTEXT_PROOF_WAIT_SEC=0 pane_context_proof 'gemini:3' "$PROOF_REPO" \
  || fail "REQUIRE_LIVE_CWD=0 should preserve legacy behavior (reason=$PANE_CONTEXT_PROOF_REASON)"
[[ "$PANE_CONTEXT_PROOF_ROUTE" == "cwd-unreadable" ]] \
  || fail "expected route=cwd-unreadable on degraded tmux, got $PANE_CONTEXT_PROOF_ROUTE"
unset ORCH_CONTEXT_PROOF_REQUIRE_LIVE_CWD

# Restore matching live cwd for the remaining legacy assertions.
PANE_CTX_LIVE_PATH="$PROOF_REPO"
PANE_CTX_LIVE_RC=0

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
PANE_CTX_LIVE_PATH="$NON_GIT_DIR"
ORCH_CONTEXT_PROOF_WAIT_SEC=0 pane_context_proof 'gemini:3' "$NON_GIT_DIR" \
  && fail "pane_context_proof should fail when origin remote is missing"
[[ "$PANE_CONTEXT_PROOF_REASON" == "remote-missing" ]] \
  || fail "expected reason remote-missing, got $PANE_CONTEXT_PROOF_REASON"
[[ "${AUDIT_LINES[-1]}" == *"status=mismatch:remote-missing"* ]] \
  || fail "expected remote-missing audit line, got: ${AUDIT_LINES[-1]:-missing}"

AUDIT_LINES=()
PANE_CTX_LIVE_PATH="$PROOF_REPO"
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

# Invalid soft-routing mode → refuse early.
AUDIT_LINES=()
ORCH_CONTEXT_PROOF_WAIT_SEC=0 pane_context_proof 'gemini:3' "$PROOF_REPO" '' '' 'unknown-mode' \
  && fail "pane_context_proof should refuse an unknown soft_routing mode"
[[ "$PANE_CONTEXT_PROOF_REASON" == "invalid-soft-routing-mode" ]] \
  || fail "expected invalid-soft-routing-mode, got $PANE_CONTEXT_PROOF_REASON"

printf 'ok - tmux_helpers pane_context_proof tests passed\n'
