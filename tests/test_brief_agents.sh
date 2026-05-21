#!/usr/bin/env bash
# test_brief_agents.sh — issue #753.
#
# brief_agents.sh must inject an `## Acceptance proof` section into the
# rendered dispatch brief, pre-filling a fenced ```acceptance``` block
# with one bullet per DoD bullet extracted from the source issue body.
# When no DoD section is detected, the section must emit the fallback
# line `acceptance: no-DoD-section-found-in-issue-body` instead — so the
# closure_acceptance gate (#723) sees a deterministic acknowledgement
# either way.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

mkdir -p "$TEST_TMP/logs" "$TEST_TMP/repos/claude" "$TEST_TMP/gh" "$TEST_TMP/bin"
echo "real" > "$TEST_TMP/repos/claude/real_file.sh"

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/brief_agents.sh \
  templates/dispatch-canonical.md.tpl

chmod +x "$SANITIZED_ROOT/scripts/brief_agents.sh"

# Fast `gh` stub so brief_agents.sh's source-substance fetch returns
# immediately. We pass source_body= directly via kvargs, but the renderer
# still wraps `gh issue view` in a 15 s timeout when source_body is
# empty, so the stub keeps the no-source case deterministic too.
cat > "$TEST_TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
exit 0
GH
chmod +x "$TEST_TMP/bin/gh"
export PATH="$TEST_TMP/bin:$PATH"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="brief-acceptance"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
SUPERVISOR_REPO="origin"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
EOF

run_brief() {
  local out=$1 err=$2 ticket=$3 summary=$4 source_body=$5
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_SOURCE_FETCH_TIMEOUT_SEC=2 \
  bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
    "$TEST_TMP/test.config.sh" \
    claude "$ticket" \
    scope_files="- real_file.sh" \
    summary="$summary" \
    source_body="$source_body" \
    > "$out" 2> "$err"
}

# --- Case 1: ## Acceptance Criteria header with multiple bullets --------

ac_body=$(cat <<'BODY'
## Finding

Some context paragraph.

## Acceptance Criteria

- [ ] Item one must be verifiable.
- [ ] Item two shall also be verifiable.
- [ ] Item three is the third bullet.

## Source

Closing line.
BODY
)

ac_out="$TEST_TMP/ac.md"
ac_err="$TEST_TMP/ac.err"
run_brief "$ac_out" "$ac_err" 7530 "acceptance criteria header path" "$ac_body"

[[ -s "$ac_out" ]] \
  || fail "case 1: brief must render with source_body containing DoD bullets (stderr: $(cat "$ac_err"))"
grep -Fq -- "## Acceptance proof" "$ac_out" \
  || fail "case 1: brief must include the Acceptance proof section header"
grep -Fq -- '```acceptance' "$ac_out" \
  || fail "case 1: brief must include a fenced acceptance block"
grep -Fq -- "Replace each placeholder with a verifiable artifact reference produced by your validation run." "$ac_out" \
  || fail "case 1: brief must include the canonical one-line instruction"
grep -Fq -- "- Item one must be verifiable." "$ac_out" \
  || fail "case 1: bullet 1 must appear in the acceptance scaffold"
grep -Fq -- "- Item two shall also be verifiable." "$ac_out" \
  || fail "case 1: bullet 2 must appear in the acceptance scaffold"
grep -Fq -- "- Item three is the third bullet." "$ac_out" \
  || fail "case 1: bullet 3 must appear in the acceptance scaffold"
! grep -Fq -- "acceptance: no-DoD-section-found-in-issue-body" "$ac_out" \
  || fail "case 1: fallback line must NOT appear when DoD bullets were extracted"

# --- Case 2: ## Definition of Done header -------------------------------

dod_body=$(cat <<'BODY'
## Background

Words.

## Definition of Done

- [ ] First DoD bullet must hold.
- [ ] Second DoD bullet must hold too.
BODY
)

dod_out="$TEST_TMP/dod.md"
dod_err="$TEST_TMP/dod.err"
run_brief "$dod_out" "$dod_err" 7531 "definition of done header path" "$dod_body"

grep -Fq -- '```acceptance' "$dod_out" \
  || fail "case 2: Definition of Done header must trigger a fenced acceptance block"
grep -Fq -- "- First DoD bullet must hold." "$dod_out" \
  || fail "case 2: DoD bullet 1 must appear"
grep -Fq -- "- Second DoD bullet must hold too." "$dod_out" \
  || fail "case 2: DoD bullet 2 must appear"

# --- Case 3: case-insensitive lowercase ## acceptance criteria header ---

lc_body=$(cat <<'BODY'
## acceptance criteria

- [ ] Lowercase header bullet must work.
BODY
)

lc_out="$TEST_TMP/lc.md"
lc_err="$TEST_TMP/lc.err"
run_brief "$lc_out" "$lc_err" 7532 "lowercase header" "$lc_body"

grep -Fq -- '```acceptance' "$lc_out" \
  || fail "case 3: lowercase 'acceptance criteria' header must trigger the acceptance block"
grep -Fq -- "- Lowercase header bullet must work." "$lc_out" \
  || fail "case 3: bullet under lowercase header must appear"

# --- Case 4: source body without any DoD section -> fallback line -------

no_dod_body=$(cat <<'BODY'
## Background

This issue has no acceptance criteria block at all.

## Source

Done.
BODY
)

no_dod_out="$TEST_TMP/no-dod.md"
no_dod_err="$TEST_TMP/no-dod.err"
run_brief "$no_dod_out" "$no_dod_err" 7533 "no dod section fallback" "$no_dod_body"

grep -Fq -- "## Acceptance proof" "$no_dod_out" \
  || fail "case 4: Acceptance proof section header must appear even without DoD bullets"
grep -Fq -- "acceptance: no-DoD-section-found-in-issue-body" "$no_dod_out" \
  || fail "case 4: fallback line must appear when no DoD section is detected"
! grep -Fq -- '```acceptance' "$no_dod_out" \
  || fail "case 4: fenced acceptance block must NOT appear when no DoD found"

# --- Case 5: mixed `- [ ]`, `- [x]`, and `- ` bullet forms --------------

mixed_body=$(cat <<'BODY'
## Definition of Done

- [ ] Unchecked bullet must apply.
- [x] Already-checked bullet shall also apply.
- Plain bullet without checkbox must still be carried.
BODY
)

mixed_out="$TEST_TMP/mixed.md"
mixed_err="$TEST_TMP/mixed.err"
run_brief "$mixed_out" "$mixed_err" 7534 "mixed bullet forms" "$mixed_body"

grep -Fq -- "- Unchecked bullet must apply." "$mixed_out" \
  || fail "case 5: unchecked '- [ ]' bullet must appear"
grep -Fq -- "- Already-checked bullet shall also apply." "$mixed_out" \
  || fail "case 5: checked '- [x]' bullet must appear"
grep -Fq -- "- Plain bullet without checkbox must still be carried." "$mixed_out" \
  || fail "case 5: plain '- ' bullet must appear"

# --- Case 6: empty source body -> fallback line (no DoD to extract) -----

empty_out="$TEST_TMP/empty.md"
empty_err="$TEST_TMP/empty.err"
run_brief "$empty_out" "$empty_err" 7535 "empty source body" ""

[[ -s "$empty_out" ]] \
  || fail "case 6: brief must still render with empty source_body (stderr: $(cat "$empty_err"))"
grep -Fq -- "acceptance: no-DoD-section-found-in-issue-body" "$empty_out" \
  || fail "case 6: empty source body must emit the fallback line"

# --- Case 7: bullets after DoD section do not bleed into the scaffold ---

bleed_body=$(cat <<'BODY'
## Acceptance Criteria

- [ ] Inside DoD must apply.

## Other Section

- [ ] Outside DoD must NOT leak into the acceptance scaffold.
BODY
)

bleed_out="$TEST_TMP/bleed.md"
bleed_err="$TEST_TMP/bleed.err"
run_brief "$bleed_out" "$bleed_err" 7536 "section boundary" "$bleed_body"

# Pull just the fenced acceptance block (between opening and closing
# ```acceptance``` fences) so we can check the included bullets without
# matching incidental occurrences elsewhere in the rendered brief (the
# source body appendix carries the raw issue text verbatim).
acceptance_block=$(awk '
  /^```acceptance[[:space:]]*$/ { in_block = 1; next }
  /^```[[:space:]]*$/ { if (in_block) exit }
  in_block { print }
' "$bleed_out")

grep -Fq -- "- Inside DoD must apply." <<<"$acceptance_block" \
  || fail "case 7: in-section bullet must appear in the acceptance block"
! grep -Fq -- "- Outside DoD must NOT leak into the acceptance scaffold." <<<"$acceptance_block" \
  || fail "case 7: bullet under a later section must NOT bleed into the acceptance block"

printf 'ok - brief_agents injects acceptance proof scaffold from DoD bullets (or fallback when absent)\n'
