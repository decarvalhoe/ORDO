#!/usr/bin/env bash
# Regression for issue #307: ci_autofix must sanitize captured failed-run
# logs before they are embedded in the dispatch prompt, so nonfatal
# shell-error lines (e.g. `rg: command not found` from a test that still
# reports ok) cannot trip prompt_integrity's ORCH_PROMPT_FORBID_RE and
# block autofix dispatch on the wrong signal.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"
PROMPT_FILE="/tmp/dispatch-claude-autofix-pr-307.md"

cleanup() {
  rm -rf "$TEST_TMP"
  rm -f "$PROMPT_FILE"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/bin" "$TEST_TMP/logs"

for rel in \
  scripts/ci_autofix.sh \
  lib/audit_log.sh \
  lib/log_bounds.sh \
  lib/ci_external_blockers.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/dry_run.sh \
  lib/prompt_integrity.sh \
  lib/state_persist.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done

chmod +x "$SANITIZED_ROOT/scripts/ci_autofix.sh"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="ci-autofix-307"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worktrees/%s"
EOF

# Fake `gh` reproducing the exact pattern from the audit: a captured
# failed log that contains a nonfatal `command not found` line from
# test_csv_dev_mode.sh (which still reports ok) followed by the actual
# failing assertion in test_github_identity.sh.
cat > "$TEST_TMP/bin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\$*" in
  *"pr view 307"* )
    printf '%s\n' '{"title":"#307 fixture PR","headRefName":"feat/sanitize-fixture","baseRefName":"main","changedFiles":1,"files":[{"path":"scripts/ci_autofix.sh"}],"url":"https://github.com/RBOKproject/ORDO/pull/307"}'
    ;;
  *"pr checks 307"* )
    printf '%s\n' '[{"name":"unit","state":"FAILURE","bucket":"fail","link":"https://github.com/RBOKproject/ORDO/actions/runs/9999/job/1","workflow":"CI"}]'
    ;;
  *"run view 9999 --log-failed"* )
    cat <<'LOG'
running tests/test_csv_dev_mode.sh
tests/test_csv_dev_mode.sh: line 131: rg: command not found
ok - csv_dev_mode handles missing rg
running tests/test_github_identity.sh
tests/test_github_identity.sh: line 42: assertion failed: expected RBOKCLIcursor, got RBOKCLIgemini
not ok - github identity guard refuses mismatched login
helper.sh: line 17: syntax error near unexpected token \`fi'
helper.sh: line 8: VAR_X: unbound variable
artifacts: cannot open /tmp/missing-fixture.json
release-config.yaml: No such file or directory
LOG
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

cat > "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod +x "$SANITIZED_ROOT/scripts/dispatch_ticket.sh"

set +e
PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/ci_autofix.sh" "$TEST_TMP/test.config.sh" 307 claude --dry-run >/dev/null 2>&1
status=$?
set -e

[[ "$status" -eq 0 ]] || fail "ci_autofix dry-run exited $status"
[[ -f "$PROMPT_FILE" ]] || fail "ci_autofix should produce a prompt file"

# Acceptance criterion 1: the generated prompt MUST pass prompt_integrity
# even though the captured log contained nonfatal shell-error noise.
source "$ROOT/lib/prompt_integrity.sh"
if ! validate_prompt_integrity "$PROMPT_FILE" 2>"$TEST_TMP/integrity.err"; then
  printf 'integrity stderr:\n' >&2
  cat "$TEST_TMP/integrity.err" >&2
  fail "prompt_integrity must accept the sanitized prompt (#307)"
fi

# Acceptance criterion 2: the prompt MUST still reference the actual
# failing test path so the agent can act on the right signal.
grep -q 'tests/test_github_identity.sh' "$PROMPT_FILE" \
  || fail "sanitized prompt must still mention the actual failing test"
grep -q 'github identity guard refuses mismatched login' "$PROMPT_FILE" \
  || fail "sanitized prompt must still mention the failing assertion"

# Acceptance criterion 3: each known shell-error trigger MUST have been
# rewritten to its parenthesized, regex-non-matching form. Use
# fixed-string grep so the assertion does not itself trip the regex.
grep -F -q 'command (not found)' "$PROMPT_FILE" \
  || fail "expected sanitized 'command (not found)' in prompt"
grep -F -q 'syntax error near (unexpected token)' "$PROMPT_FILE" \
  || fail "expected sanitized 'syntax error near (unexpected token)' in prompt"
grep -F -q 'unbound (variable)' "$PROMPT_FILE" \
  || fail "expected sanitized 'unbound (variable)' in prompt"
grep -F -q ': (cannot open)' "$PROMPT_FILE" \
  || fail "expected sanitized ': (cannot open)' in prompt"
grep -F -q 'No such file or directory.' "$PROMPT_FILE" \
  || fail "expected line-end anchor broken with trailing period"

# Negative assertions: the raw trigger substrings MUST NOT appear in the
# embedded log. (The forbid regex itself is allowed to mention the
# patterns once it is documented in tests/test_prompt_integrity.sh, but
# this prompt is the autofix dispatch brief and must be clean.)
! grep -F -q 'command not found' "$PROMPT_FILE" \
  || fail "raw 'command not found' must be sanitized out of the prompt"
! grep -F -q 'syntax error near unexpected token' "$PROMPT_FILE" \
  || fail "raw 'syntax error near unexpected token' must be sanitized out"
! grep -F -q 'unbound variable' "$PROMPT_FILE" \
  || fail "raw 'unbound variable' must be sanitized out"

# Sanitization marker MUST be present so a reviewer knows the embedded
# log was rewritten and can audit against the run id.
grep -q 'sanitized for prompt integrity per #307' "$PROMPT_FILE" \
  || fail "expected sanitization-provenance marker in embedded log header"

printf 'ok - ci_autofix sanitizes nonfatal shell-error log lines (issue #307)\n'
