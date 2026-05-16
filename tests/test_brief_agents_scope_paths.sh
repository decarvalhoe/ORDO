#!/usr/bin/env bash
# test_brief_agents_scope_paths.sh — issue #520.
#
# brief_agents.sh must warn when scope_files lists an explicit (non-glob)
# path that does not exist in the agent workdir. The warning is audit-
# logged but must not block dispatch, and glob patterns are skipped.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

mkdir -p "$TEST_TMP/logs" "$TEST_TMP/repos/claude"

# Seed the agent workdir with one real file so we have something to
# distinguish "exists" from "missing".
echo "real" > "$TEST_TMP/repos/claude/real_file.sh"
mkdir -p "$TEST_TMP/repos/claude/lib"
echo "real" > "$TEST_TMP/repos/claude/lib/real_helper.sh"

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/brief_agents.sh \
  templates/dispatch-canonical.md.tpl

chmod +x "$SANITIZED_ROOT/scripts/brief_agents.sh"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="brief-scope-paths"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
SUPERVISOR_REPO="origin"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
EOF

audit_log="$TEST_TMP/logs/brief-scope-paths.log"

# Case 1: scope_files with one literal that exists → no warning.
existing_stdout="$TEST_TMP/existing.md"
existing_stderr="$TEST_TMP/existing.err"
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/test.config.sh" \
  claude 5201 \
  summary="fix #520 existing scope path" \
  scope_files="- real_file.sh" \
  validation="timeout 30 bash -n scripts/brief_agents.sh" \
  > "$existing_stdout" 2> "$existing_stderr"

! grep -Fq -- "WARN: brief scope_files entry" "$existing_stderr" \
  || fail "existing scope path must not produce a missing-path warning"
! grep -Fq -- "BRIEF_SCOPE_PATH_MISSING" "$audit_log" \
  || fail "existing scope path must not emit a BRIEF_SCOPE_PATH_MISSING audit row"

# Case 2: scope_files with one literal that does NOT exist → WARN + audit.
missing_stdout="$TEST_TMP/missing.md"
missing_stderr="$TEST_TMP/missing.err"
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/test.config.sh" \
  claude 5202 \
  summary="fix #520 missing scope path" \
  scope_files="- tests/test_state_persist.sh" \
  validation="timeout 30 bash -n scripts/brief_agents.sh" \
  > "$missing_stdout" 2> "$missing_stderr"

[[ -s "$missing_stdout" ]] \
  || fail "missing scope path must not block dispatch — brief must still render"
grep -Fq -- "WARN: brief scope_files entry tests/test_state_persist.sh does not exist" "$missing_stderr" \
  || fail "missing literal scope path must surface a WARN on stderr"
grep -Fq -- "BRIEF_SCOPE_PATH_MISSING ticket=#5202" "$audit_log" \
  || fail "missing literal scope path must emit BRIEF_SCOPE_PATH_MISSING audit row"
grep -Fq -- "path=tests/test_state_persist.sh" "$audit_log" \
  || fail "BRIEF_SCOPE_PATH_MISSING audit row must name the missing path"

# Case 3: glob patterns must never produce a missing-path warning, even
# when no file currently matches the glob.
glob_stdout="$TEST_TMP/glob.md"
glob_stderr="$TEST_TMP/glob.err"
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/test.config.sh" \
  claude 5203 \
  summary="fix #520 glob scope" \
  scope_files="- docs/**/*.md"$'\n'"- tests/test_*.bats"$'\n'"- lib/?_helper.sh" \
  validation="timeout 30 bash -n scripts/brief_agents.sh" \
  > "$glob_stdout" 2> "$glob_stderr"

! grep -Fq -- "WARN: brief scope_files entry" "$glob_stderr" \
  || fail "glob scope entries must not produce a missing-path warning"

# Case 4: mixed scope — real literal + missing literal + glob. Only the
# missing literal should warn.
mixed_stdout="$TEST_TMP/mixed.md"
mixed_stderr="$TEST_TMP/mixed.err"
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/test.config.sh" \
  claude 5204 \
  summary="fix #520 mixed scope" \
  scope_files="- real_file.sh"$'\n'"- lib/missing_helper.sh"$'\n'"- docs/**/*.md" \
  validation="timeout 30 bash -n scripts/brief_agents.sh" \
  > "$mixed_stdout" 2> "$mixed_stderr"

mixed_warn_count=$(grep -Fc -- "WARN: brief scope_files entry" "$mixed_stderr" || true)
[[ "$mixed_warn_count" -eq 1 ]] \
  || fail "mixed scope must produce exactly one missing-path warning, got $mixed_warn_count"
grep -Fq -- "WARN: brief scope_files entry lib/missing_helper.sh does not exist" "$mixed_stderr" \
  || fail "mixed scope warning must name the missing literal lib/missing_helper.sh"
! grep -Fq -- "WARN: brief scope_files entry real_file.sh" "$mixed_stderr" \
  || fail "mixed scope must not warn on the existing literal real_file.sh"
! grep -Fq -- "WARN: brief scope_files entry docs" "$mixed_stderr" \
  || fail "mixed scope must not warn on the glob entry"

printf 'ok - brief_agents warns on missing scope_files literals while skipping globs\n'
