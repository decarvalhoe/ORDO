#!/usr/bin/env bash
# test_brief_agents_audit_evidence.sh — issue #483.
#
# brief_agents.sh must preflight referenced audit-evidence paths before
# worker handoff. When `audit_evidence_files=<paths>` is declared:
#   * referenced files that exist on the agent workdir (the verified
#     base) get an excerpt embedded directly in the rendered brief so
#     the worker has the evidence inline;
#   * a missing referenced file refuses dispatch with a clear stderr
#     blocker and a BRIEF_AUDIT_EVIDENCE_MISSING audit row, so the
#     worker is never handed a brief that points at evidence it cannot
#     inspect;
#   * glob entries are skipped (same convention as scope_files) so a
#     future-only reference doesn't fire a false positive;
#   * the kvarg is opt-in — briefs that don't declare any audit
#     evidence are unaffected.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

mkdir -p "$TEST_TMP/logs" "$TEST_TMP/repos/claude/audit"

# Seed a real file under scope and a real audit doc on the verified base.
echo "real" > "$TEST_TMP/repos/claude/real_file.sh"
cat > "$TEST_TMP/repos/claude/audit/audit-001.md" <<'AUDIT'
# Audit 001

This is the audit excerpt the worker needs to inspect.
AUDIT

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/brief_agents.sh \
  templates/dispatch-canonical.md.tpl

chmod +x "$SANITIZED_ROOT/scripts/brief_agents.sh"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="brief-audit-evidence"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
SUPERVISOR_REPO="origin"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
EOF

audit_log="$TEST_TMP/logs/brief-audit-evidence.log"

# Case 1: referenced audit doc exists -> brief renders and embeds excerpt.
ok_stdout="$TEST_TMP/ok.md"
ok_stderr="$TEST_TMP/ok.err"
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/test.config.sh" \
  claude 4831 \
  summary="fix #483 audit evidence present" \
  scope_files="- real_file.sh" \
  audit_evidence_files="- audit/audit-001.md" \
  validation="timeout 30 bash -n scripts/brief_agents.sh" \
  > "$ok_stdout" 2> "$ok_stderr"

[[ -s "$ok_stdout" ]] \
  || fail "audit evidence present -> brief must render"
grep -Fq -- "## Audit evidence excerpts (preflight-embedded)" "$ok_stdout" \
  || fail "audit evidence present -> rendered brief must include excerpts section"
grep -Fq -- "### audit/audit-001.md" "$ok_stdout" \
  || fail "audit evidence present -> rendered brief must include referenced path heading"
grep -Fq -- "This is the audit excerpt the worker needs to inspect." "$ok_stdout" \
  || fail "audit evidence present -> rendered brief must include the actual file content"
grep -Fq -- "BRIEF_AUDIT_EVIDENCE_EMBEDDED ticket=#4831" "$audit_log" \
  || fail "audit evidence embedded -> audit log must record BRIEF_AUDIT_EVIDENCE_EMBEDDED row"
! grep -Fq -- "BRIEF_AUDIT_EVIDENCE_MISSING ticket=#4831" "$audit_log" \
  || fail "audit evidence present -> must not emit BRIEF_AUDIT_EVIDENCE_MISSING row"

# Case 2: referenced audit doc missing -> renderer refuses with clear blocker.
missing_stdout="$TEST_TMP/missing.md"
missing_stderr="$TEST_TMP/missing.err"
set +e
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/test.config.sh" \
  claude 4832 \
  summary="fix #483 audit evidence missing" \
  scope_files="- real_file.sh" \
  audit_evidence_files="- audit/missing-evidence.md" \
  validation="timeout 30 bash -n scripts/brief_agents.sh" \
  > "$missing_stdout" 2> "$missing_stderr"
rc=$?
set -e

[[ "$rc" -ne 0 ]] \
  || fail "missing audit evidence must refuse dispatch (exit non-zero)"
grep -Fq -- "AUDIT_EVIDENCE_MISSING path=audit/missing-evidence.md" "$missing_stderr" \
  || fail "missing audit evidence must surface a clear stderr blocker naming the path"
grep -Fq -- "ticket=#4832" "$missing_stderr" \
  || fail "missing audit evidence blocker must name the ticket"
grep -Fq -- "BRIEF_AUDIT_EVIDENCE_MISSING ticket=#4832" "$audit_log" \
  || fail "missing audit evidence must emit BRIEF_AUDIT_EVIDENCE_MISSING audit row"
grep -Fq -- "path=audit/missing-evidence.md" "$audit_log" \
  || fail "BRIEF_AUDIT_EVIDENCE_MISSING audit row must name the missing path"
grep -Fq -- "AUDIT_EVIDENCE_PREFLIGHT_REFUSED" "$audit_log" \
  || fail "renderer must record an AUDIT_EVIDENCE_PREFLIGHT_REFUSED audit row when refusing dispatch"

# Case 3: glob audit_evidence entry -> never blocks dispatch, even when no
# file currently matches the glob.
glob_stdout="$TEST_TMP/glob.md"
glob_stderr="$TEST_TMP/glob.err"
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/test.config.sh" \
  claude 4833 \
  summary="fix #483 audit evidence glob" \
  scope_files="- real_file.sh" \
  audit_evidence_files="- audit/**/*.md" \
  validation="timeout 30 bash -n scripts/brief_agents.sh" \
  > "$glob_stdout" 2> "$glob_stderr"

[[ -s "$glob_stdout" ]] \
  || fail "audit evidence glob -> brief must still render"
! grep -Fq -- "AUDIT_EVIDENCE_MISSING" "$glob_stderr" \
  || fail "audit evidence glob -> must not produce a missing-path blocker"

# Case 4: audit_evidence_files unset -> renderer is a no-op (no excerpt
# section, no audit row).
noop_stdout="$TEST_TMP/noop.md"
noop_stderr="$TEST_TMP/noop.err"
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/test.config.sh" \
  claude 4834 \
  summary="fix #483 audit evidence absent" \
  scope_files="- real_file.sh" \
  validation="timeout 30 bash -n scripts/brief_agents.sh" \
  > "$noop_stdout" 2> "$noop_stderr"

[[ -s "$noop_stdout" ]] \
  || fail "audit_evidence_files unset -> brief must still render"
! grep -Fq -- "## Audit evidence excerpts (preflight-embedded)" "$noop_stdout" \
  || fail "audit_evidence_files unset -> brief must not include audit excerpts section"
! grep -Fq -- "BRIEF_AUDIT_EVIDENCE_EMBEDDED ticket=#4834" "$audit_log" \
  || fail "audit_evidence_files unset -> must not emit BRIEF_AUDIT_EVIDENCE_EMBEDDED row"

printf 'ok - brief_agents preflights audit evidence: embed excerpts when present, refuse with clear blocker when missing\n'
