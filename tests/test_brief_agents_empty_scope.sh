#!/usr/bin/env bash
# test_brief_agents_empty_scope.sh — proves brief_agents.sh refuses to
# render implementation briefs whose `Fichiers autorises` allowlist is
# empty, and that `--audit-only` is a clean opt-out for legitimate
# audit/diagnostic dispatches.
#
# Source: issue #538. The 2026-05 dispatch of #518 rendered a brief
# with no scope_files; the worker correctly stopped before mutation
# but the pane stayed marked occupied, burning fleet capacity until
# an operator re-rendered the brief. This pins the refusal so that
# regression never reaches a pane.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

mkdir -p "$TEST_TMP/logs" "$TEST_TMP/repos" "$TEST_TMP/gh" "$TEST_TMP/bin"

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/brief_agents.sh \
  templates/dispatch-canonical.md.tpl

chmod +x "$SANITIZED_ROOT/scripts/brief_agents.sh"

# Fast `gh` stub so the source-substance fetch returns immediately —
# brief_agents wraps the real `gh issue view` in a 15 s timeout and
# falls back to the local source body on failure, but eating the full
# wall-clock penalty per invocation makes this test brittle on busy
# hosts. The stub also keeps the assertion deterministic.
cat > "$TEST_TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
exit 0
GH
chmod +x "$TEST_TMP/bin/gh"
export PATH="$TEST_TMP/bin:$PATH"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="brief-empty-scope"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
SUPERVISOR_REPO="origin"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
EOF

# --- Case 1: implementation brief with empty scope_files is refused ------

empty_out="$TEST_TMP/empty.md"
empty_err="$TEST_TMP/empty.err"

set +e
ORCH_LOG_DIR="$TEST_TMP/logs" \
ORCH_SOURCE_FETCH_TIMEOUT_SEC=2 \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/test.config.sh" \
  claude 538 \
  branch_slug="fix/538-refuse-empty-scope" \
  summary="refuse empty allowed-files scope" \
  > "$empty_out" 2> "$empty_err"
empty_status=$?
set -e

[[ "$empty_status" -eq 87 ]] \
  || fail "empty scope_files should exit 87 (got: $empty_status, stderr: $(cat "$empty_err"))"
[[ ! -s "$empty_out" ]] \
  || fail "no brief should be rendered when scope_files is empty (stdout: $(cat "$empty_out"))"
grep -q "EMPTY_SCOPE_REFUSED" "$empty_err" \
  || fail "empty scope refusal should surface EMPTY_SCOPE_REFUSED on stderr, got: $(cat "$empty_err")"
grep -q "reason=empty_allowed_files_scope" "$empty_err" \
  || fail "empty scope refusal should carry actionable reason on stderr, got: $(cat "$empty_err")"
grep -q -- "--audit-only" "$empty_err" \
  || fail "empty scope refusal should advertise --audit-only opt-out, got: $(cat "$empty_err")"

empty_log="$TEST_TMP/logs/brief-empty-scope.log"
[[ -s "$empty_log" ]] \
  || fail "empty scope refusal should write a project audit log line"
grep -q "BRIEF EMPTY_SCOPE_REFUSED" "$empty_log" \
  || fail "audit log should classify the refusal as BRIEF EMPTY_SCOPE_REFUSED, got: $(cat "$empty_log")"
grep -q "project=brief-empty-scope" "$empty_log" \
  || fail "audit log should expose project= identifier"
grep -q "agent=claude" "$empty_log" \
  || fail "audit log should expose agent= identifier"
grep -q "ticket=#538" "$empty_log" \
  || fail "audit log should expose ticket=#<n> identifier"
grep -q "reason=empty_allowed_files_scope" "$empty_log" \
  || fail "audit log should expose the structured reason"

# --- Case 2: whitespace-only scope_files counts as empty -----------------

ws_out="$TEST_TMP/whitespace.md"
ws_err="$TEST_TMP/whitespace.err"

set +e
ORCH_LOG_DIR="$TEST_TMP/logs-ws" \
ORCH_SOURCE_FETCH_TIMEOUT_SEC=2 \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/test.config.sh" \
  claude 538 \
  branch_slug="fix/538-refuse-empty-scope" \
  summary="refuse empty allowed-files scope" \
  scope_files=$'  \n\t  \n' \
  > "$ws_out" 2> "$ws_err"
ws_status=$?
set -e

[[ "$ws_status" -eq 87 ]] \
  || fail "whitespace-only scope_files should still be refused (got: $ws_status, stderr: $(cat "$ws_err"))"
grep -q "EMPTY_SCOPE_REFUSED" "$ws_err" \
  || fail "whitespace-only scope_files should still report EMPTY_SCOPE_REFUSED"
[[ ! -s "$ws_out" ]] \
  || fail "no brief should be rendered when scope_files is whitespace-only"

# --- Case 3: --audit-only allows empty scope_files -----------------------

audit_out="$TEST_TMP/audit.md"
audit_err="$TEST_TMP/audit.err"

set +e
ORCH_LOG_DIR="$TEST_TMP/logs-audit" \
ORCH_SOURCE_FETCH_TIMEOUT_SEC=2 \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/test.config.sh" \
  claude 538 \
  --audit-only \
  branch_slug="fix/538-refuse-empty-scope" \
  summary="refuse empty allowed-files scope" \
  > "$audit_out" 2> "$audit_err"
audit_status=$?
set -e

[[ "$audit_status" -eq 0 ]] \
  || fail "--audit-only should let the brief render (got: $audit_status, stderr: $(cat "$audit_err"))"
[[ -s "$audit_out" ]] \
  || fail "--audit-only brief should be rendered to stdout"
grep -q "Ticket: #538" "$audit_out" \
  || fail "audit-only brief should still carry the ticket header"

audit_log="$TEST_TMP/logs-audit/brief-empty-scope.log"
[[ -s "$audit_log" ]] \
  || fail "--audit-only path should leave an audit log entry"
grep -q "BRIEF AUDIT_ONLY_AUTHORIZED" "$audit_log" \
  || fail "audit-only authorization should be classified BRIEF AUDIT_ONLY_AUTHORIZED, got: $(cat "$audit_log")"
grep -q "authorization=audit_only_flag" "$audit_log" \
  || fail "audit-only audit line should record the authorization source"
grep -q "reason=empty_allowed_files_scope" "$audit_log" \
  || fail "audit-only audit line should record the underlying reason"
! grep -q "BRIEF EMPTY_SCOPE_REFUSED" "$audit_log" \
  || fail "audit-only path must not also emit EMPTY_SCOPE_REFUSED"

printf 'ok - brief_agents refuses empty allowed-files scope and honours --audit-only\n'
