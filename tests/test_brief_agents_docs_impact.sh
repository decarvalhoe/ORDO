#!/usr/bin/env bash
# test_brief_agents_docs_impact.sh — issue #779.
#
# Across the 2026-05-19/20/21 dispatch waves nearly every agent-authored
# PR failed docs-impact-gate (#260/#316) on the first run because the
# worker omitted the Docs-Impact trailer in its PR body / final commit
# message; ~12 PRs needed a manual operator body patch + empty-commit
# retrigger. brief_agents.sh now renders a "PR body trailer" section in
# every implementation brief with a suggested outcome pre-computed from
# scope_files (docs/ or non-test .md -> docs-updated; otherwise
# no-docs-needed).
#
# This regression check pins:
#   - the section is always present in the rendered brief (instruction
#     plus accepted-outcome vocabulary)
#   - scope_files touching docs/foo.md -> Suggested: Docs-Impact: docs-updated
#   - scope_files touching only scripts/ + tests/ -> no-docs-needed
#   - scope_files mixing tests/ + non-test .md (top-level README.md) ->
#     docs-updated (the .md tie-breaker wins)
#   - scope_files limited to a tests/*.md path -> no-docs-needed
#     (test markdown is not user-facing documentation)
#   - a BRIEF DOCS_IMPACT_TRAILER_SUGGESTED audit row is emitted with
#     the computed outcome for each render
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

# Fast `gh` stub so the source-substance fetch returns immediately.
cat > "$TEST_TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
exit 0
GH
chmod +x "$TEST_TMP/bin/gh"
export PATH="$TEST_TMP/bin:$PATH"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="brief-docs-impact"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
SUPERVISOR_REPO="origin"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
EOF

run_brief() {
  local ticket=$1
  local scope_files=$2
  local out=$3
  # `--validation-sufficiency=off` keeps the #724 sufficiency gate out
  # of this test's blast radius. The Docs-Impact trailer contract under
  # test here is independent of validation-class coverage; pinning the
  # gate to off ensures the assertions stay focused on Docs-Impact
  # suggestion rendering rather than chaining the canonical
  # sufficiency-check augmentation.
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_SOURCE_FETCH_TIMEOUT_SEC=2 \
  bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
    "$TEST_TMP/test.config.sh" \
    claude "$ticket" \
    --validation-sufficiency=off \
    branch_slug="feat/${ticket}-docs-impact-trailer" \
    summary="feat #779 docs-impact trailer ${ticket}" \
    scope_files="$scope_files" \
    > "$out"
}

audit_log_path() {
  # lib/audit_log.sh writes to "$ORCH_LOG_DIR/$PROJECT.log"; PROJECT
  # comes from $TEST_TMP/test.config.sh and ORCH_LOG_DIR is set inline
  # by run_brief().
  printf '%s/brief-docs-impact.log\n' "$TEST_TMP/logs"
}

# --- Case 1: scope_files touching docs/foo.md -> docs-updated -------------

docs_brief="$TEST_TMP/docs.md"
run_brief 77901 'docs/foo.md' "$docs_brief"

grep -Fq -- '## PR body trailer — Docs-Impact (#779)' "$docs_brief" \
  || fail "rendered brief must include the PR-body trailer section header"

grep -Fq -- 'Docs-Impact: <docs-updated|no-docs-needed|follow-up|blocked>' "$docs_brief" \
  || fail "rendered brief must list the accepted Docs-Impact outcome vocabulary"

grep -Fq -- 'Suggested: Docs-Impact: docs-updated' "$docs_brief" \
  || fail "scope touching docs/foo.md must surface Suggested: Docs-Impact: docs-updated (got: $(grep -F 'Suggested:' "$docs_brief"))"

! grep -Fq -- 'Suggested: Docs-Impact: no-docs-needed' "$docs_brief" \
  || fail "docs-touching scope must NOT also emit the no-docs-needed suggestion"

# --- Case 2: scope_files only under scripts/ + tests/ -> no-docs-needed ---

shell_brief="$TEST_TMP/shell.md"
shell_scope=$'- scripts/brief_agents.sh\n- tests/test_brief_agents_docs_impact.sh'
run_brief 77902 "$shell_scope" "$shell_brief"

grep -Fq -- '## PR body trailer — Docs-Impact (#779)' "$shell_brief" \
  || fail "shell-only brief must still include the PR-body trailer section header"

grep -Fq -- 'Suggested: Docs-Impact: no-docs-needed' "$shell_brief" \
  || fail "scope limited to scripts/ + tests/ must surface Suggested: Docs-Impact: no-docs-needed (got: $(grep -F 'Suggested:' "$shell_brief"))"

! grep -Fq -- 'Suggested: Docs-Impact: docs-updated' "$shell_brief" \
  || fail "scripts+tests scope must NOT emit the docs-updated suggestion"

# --- Case 3: top-level non-test .md path -> docs-updated -----------------

readme_brief="$TEST_TMP/readme.md"
readme_scope=$'- README.md\n- scripts/brief_agents.sh'
run_brief 77903 "$readme_scope" "$readme_brief"

grep -Fq -- 'Suggested: Docs-Impact: docs-updated' "$readme_brief" \
  || fail "non-test top-level .md scope must surface Suggested: Docs-Impact: docs-updated"

# --- Case 4: tests/*.md only -> no-docs-needed ---------------------------

tests_md_brief="$TEST_TMP/tests_md.md"
tests_md_scope=$'- tests/fixtures/sample.md\n- scripts/brief_agents.sh'
run_brief 77904 "$tests_md_scope" "$tests_md_brief"

grep -Fq -- 'Suggested: Docs-Impact: no-docs-needed' "$tests_md_brief" \
  || fail "tests/*.md scope must surface Suggested: Docs-Impact: no-docs-needed (test markdown is not user-facing documentation)"

# --- Case 5: docs/**/* glob -> docs-updated ------------------------------

glob_brief="$TEST_TMP/glob.md"
run_brief 77905 '- docs/**/*.md' "$glob_brief"

grep -Fq -- 'Suggested: Docs-Impact: docs-updated' "$glob_brief" \
  || fail "docs/**/*.md glob scope must surface Suggested: Docs-Impact: docs-updated"

# --- Case 6: section is placed before `## Preuves attendues` --------------
# Anchor placement: the canonical template ends with `## Preuves
# attendues` before the source appendix; the trailer instruction must
# appear in the main brief body, not buried inside the source dump.

trailer_line=$(grep -nF -- '## PR body trailer — Docs-Impact (#779)' "$docs_brief" | head -1 | cut -d: -f1)
preuves_line=$(grep -nF -- '## Preuves attendues' "$docs_brief" | head -1 | cut -d: -f1)
appendix_line=$(grep -nF -- '## Source ticket substance appendix - mandatory' "$docs_brief" | head -1 | cut -d: -f1)

[[ -n "$trailer_line" && -n "$preuves_line" && -n "$appendix_line" ]] \
  || fail "expected to find trailer + preuves + appendix sections in rendered brief"

[[ "$trailer_line" -lt "$preuves_line" ]] \
  || fail "trailer section must precede '## Preuves attendues' (trailer=$trailer_line preuves=$preuves_line)"

[[ "$trailer_line" -lt "$appendix_line" ]] \
  || fail "trailer section must precede source appendix (trailer=$trailer_line appendix=$appendix_line)"

# --- Case 7: audit row emitted with computed outcome ---------------------

audit_log=$(audit_log_path)
[[ -f "$audit_log" ]] \
  || fail "expected audit log at $audit_log after brief renders"

grep -Fq -- 'BRIEF DOCS_IMPACT_TRAILER_SUGGESTED' "$audit_log" \
  || fail "brief render must emit a BRIEF DOCS_IMPACT_TRAILER_SUGGESTED audit row"

grep -Fq -- 'ticket=#77901 outcome=docs-updated' "$audit_log" \
  || fail "audit row for ticket 77901 must record outcome=docs-updated"

grep -Fq -- 'ticket=#77902 outcome=no-docs-needed' "$audit_log" \
  || fail "audit row for ticket 77902 must record outcome=no-docs-needed"

printf 'ok - brief_agents emits Docs-Impact trailer instruction with scope-derived suggestion\n'
