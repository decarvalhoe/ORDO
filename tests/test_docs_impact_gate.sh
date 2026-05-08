#!/usr/bin/env bash
# tests/test_docs_impact_gate.sh — fixture coverage for the docs impact
# gate (#260). Exercises classification, declaration parsing, decision
# matrix, render-evidence, and CLI surface for the gate. The test runs
# foreground and never spawns background processes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

GATE="$ROOT/scripts/docs_impact_gate.sh"
LIB="$ROOT/lib/docs_impact_gate.sh"

# --- Library tests --------------------------------------------------------

# Source the library in a clean subshell-driven fashion. We test pure
# functions directly because they are reused by callers other than the
# gate runner.

# shellcheck disable=SC1090
source "$LIB"

# Convenience wrapper used by the decision-matrix tests below: the library
# emits "<decision>\t<reason>"; tests want just the decision token.
docs_gate_decide_only() {
  docs_gate_decide "$@" | awk -F '\t' 'NR == 1 { print $1 }'
}

assert_classification() {
  local path="$1" expected="$2"
  local actual
  actual=$(docs_gate_classify_path "$path")
  [[ "$actual" == "$expected" ]] \
    || fail "classify '$path' expected=$expected actual=$actual"
}

assert_classification "docs/architecture.md" "docs"
assert_classification "README.md" "docs"
assert_classification "PRODUCT.md" "docs"
assert_classification "install.sh" "installation"
assert_classification "scripts/repository_bootstrap.sh" "installation"
assert_classification "scripts/guided_onboarding.sh" "onboarding"
assert_classification "lib/host_assessment.sh" "onboarding"
assert_classification "scripts/dispatch_ticket.sh" "dispatch"
assert_classification "scripts/orch_loop.sh" "dispatch"
assert_classification "scripts/pr_merge_wave.sh" "integration"
assert_classification "lib/governance_check.sh" "integration"
assert_classification "profiles/sample.config.sh" "profile"
assert_classification "examples/projects/example.config.sh" "profile"
assert_classification ".github/workflows/ci.yml" "workflow"
assert_classification "scripts/findings_ledger.sh" "cli"
assert_classification "lib/audit_log.sh" "lib"
assert_classification "tests/test_findings_ledger.sh" "tests"
assert_classification ".gitignore" "internal"
assert_classification "Makefile" "internal"

# --- Summarize ------------------------------------------------------------

summary_input="docs/a.md
scripts/foo.sh
scripts/bar.sh
tests/test_x.sh
README.md"

summary=$(printf '%s\n' "$summary_input" \
  | docs_gate_classify_stream \
  | docs_gate_summarize_stream)

[[ "$summary" == "cli=2
docs=2
tests=1" ]] || fail "summary mismatch:
$summary"

docs_gate_summary_has "$summary" cli || fail "summary should report cli"
docs_gate_summary_has "$summary" tests || fail "summary should report tests"
if docs_gate_summary_has "$summary" workflow; then
  fail "summary should not report workflow"
fi
docs_gate_summary_touches_surface "$summary" \
  || fail "summary with cli=2 should be flagged as touching a surface"

internal_summary=$(printf '%s\n' "tests/test_a.sh\n.gitignore\ndocs/x.md" \
  | docs_gate_classify_stream \
  | docs_gate_summarize_stream)
if docs_gate_summary_touches_surface "$internal_summary"; then
  fail "summary with only tests/docs/internal should not touch surface"
fi

# --- Declaration parsing --------------------------------------------------

decl_input='Some intro line.
Docs-Impact: no-docs-needed
Docs-Impact-Note: internal helper rename, no behavior change
Random: ignore me
Docs-Impact-Followup: #999
'
decl_parsed=$(printf '%s' "$decl_input" | docs_gate_parse_declaration)
echo "$decl_parsed" | grep -q '^outcome=no-docs-needed$' \
  || fail "declaration outcome not parsed: $decl_parsed"
echo "$decl_parsed" | grep -q '^note=internal helper rename, no behavior change$' \
  || fail "declaration note not parsed: $decl_parsed"
echo "$decl_parsed" | grep -q '^followup=#999$' \
  || fail "declaration followup not parsed: $decl_parsed"

decl_case_input='docs-impact: docs-updated
'
decl_case_parsed=$(printf '%s' "$decl_case_input" | docs_gate_parse_declaration)
echo "$decl_case_parsed" | grep -q '^outcome=docs-updated$' \
  || fail "declaration outcome (lowercase trailer) not parsed: $decl_case_parsed"

# --- Decision matrix ------------------------------------------------------

# 1. internal-only change → pass
decision=$(docs_gate_decide_only "tests=1" "")
[[ "$decision" == "pass" ]] || fail "internal-only should pass; got $decision"

# 2. docs-only change → pass
decision=$(docs_gate_decide_only "docs=3" "")
[[ "$decision" == "pass" ]] || fail "docs-only should pass; got $decision"

# 3. surface change without declaration and without docs → block
decision=$(docs_gate_decide_only "cli=2" "")
[[ "$decision" == "block" ]] || fail "surface-without-decl should block; got $decision"

# 4. surface change with docs touched and no declaration → warn
decision=$(docs_gate_decide_only $'cli=2\ndocs=1' "")
[[ "$decision" == "warn" ]] || fail "surface+docs no-decl should warn; got $decision"

# 5. surface change with declaration outcome=docs-updated AND docs touched → pass
decision=$(docs_gate_decide_only $'cli=2\ndocs=1' $'outcome=docs-updated')
[[ "$decision" == "pass" ]] || fail "docs-updated with docs touched should pass; got $decision"

# 6. surface change with outcome=docs-updated but no docs touched → warn
decision=$(docs_gate_decide_only "cli=2" $'outcome=docs-updated')
[[ "$decision" == "warn" ]] || fail "docs-updated without docs touched should warn; got $decision"

# 7. no-docs-needed with rationale → pass
decision=$(docs_gate_decide_only "cli=2" $'outcome=no-docs-needed\nnote=internal refactor')
[[ "$decision" == "pass" ]] || fail "no-docs-needed+note should pass; got $decision"

# 8. no-docs-needed without rationale → block
decision=$(docs_gate_decide_only "cli=2" $'outcome=no-docs-needed')
[[ "$decision" == "block" ]] || fail "no-docs-needed without note should block; got $decision"

# 9. follow-up with ref → pass
decision=$(docs_gate_decide_only "cli=2" $'outcome=follow-up\nfollowup=#1234')
[[ "$decision" == "pass" ]] || fail "follow-up+ref should pass; got $decision"

# 10. follow-up without ref → block
decision=$(docs_gate_decide_only "cli=2" $'outcome=follow-up')
[[ "$decision" == "block" ]] || fail "follow-up without ref should block; got $decision"

# 11. blocked outcome always blocks
decision=$(docs_gate_decide_only "cli=2" $'outcome=blocked')
[[ "$decision" == "block" ]] || fail "blocked outcome should block; got $decision"

# 12. invalid outcome → block
decision=$(docs_gate_decide_only "cli=2" $'outcome=banana')
[[ "$decision" == "block" ]] || fail "invalid outcome should block; got $decision"

# DOCS_GATE_LAST_REASON populated by decide
docs_gate_decide "tests=1" "" >/dev/null
[[ -n "$DOCS_GATE_LAST_REASON" ]] || fail "DOCS_GATE_LAST_REASON should be set"

# decide emits "<decision>\t<reason>" so callers in subshells can recover both
decide_line=$(docs_gate_decide "cli=1" "")
case "$decide_line" in
  $'block\t'*) ;;
  *) fail "decide stdout should be tab-delimited 'decision\\treason': $decide_line" ;;
esac

# --- CLI surface ----------------------------------------------------------

paths_file="$TEST_TMP/paths.txt"
decl_file="$TEST_TMP/decl.txt"
evidence_file="$TEST_TMP/evidence.md"

# classify subcommand
cat >"$paths_file" <<'EOF'
docs/architecture.md
scripts/dispatch_ticket.sh
tests/test_findings_ledger.sh
EOF
classified=$(bash "$GATE" classify --paths-from "$paths_file")
echo "$classified" | grep -qF $'docs\tdocs/architecture.md' \
  || fail "classify cli missing docs row: $classified"
echo "$classified" | grep -qF $'dispatch\tscripts/dispatch_ticket.sh' \
  || fail "classify cli missing dispatch row: $classified"
echo "$classified" | grep -qF $'tests\ttests/test_findings_ledger.sh' \
  || fail "classify cli missing tests row: $classified"

# summarize subcommand
sum_out=$(bash "$GATE" summarize --paths-from "$paths_file")
[[ "$sum_out" == "dispatch=1
docs=1
tests=1" ]] || fail "summarize cli mismatch: $sum_out"

# stdin path support
sum_stdin=$(printf '%s\n' "scripts/foo.sh" "docs/x.md" | bash "$GATE" summarize)
[[ "$sum_stdin" == "cli=1
docs=1" ]] || fail "summarize stdin mismatch: $sum_stdin"

# declare subcommand happy paths
decl_out=$(bash "$GATE" declare --outcome docs-updated)
[[ "$decl_out" == "Docs-Impact: docs-updated" ]] \
  || fail "declare docs-updated mismatch: $decl_out"

decl_out=$(bash "$GATE" declare --outcome no-docs-needed --note "internal rename")
echo "$decl_out" | grep -qxF "Docs-Impact: no-docs-needed" \
  || fail "declare no-docs-needed missing outcome: $decl_out"
echo "$decl_out" | grep -qxF "Docs-Impact-Note: internal rename" \
  || fail "declare no-docs-needed missing note: $decl_out"

decl_out=$(bash "$GATE" declare --outcome follow-up --followup "#1234")
echo "$decl_out" | grep -qxF "Docs-Impact-Followup: #1234" \
  || fail "declare follow-up missing followup: $decl_out"

# declare validation errors
if bash "$GATE" declare --outcome bogus 2>/dev/null; then
  fail "declare should reject invalid outcome"
fi
if bash "$GATE" declare --outcome no-docs-needed 2>/dev/null; then
  fail "declare should require --note for no-docs-needed"
fi
if bash "$GATE" declare --outcome follow-up 2>/dev/null; then
  fail "declare should require --followup for follow-up"
fi

# check: docs-only change passes
cat >"$paths_file" <<'EOF'
docs/architecture.md
README.md
EOF
: >"$decl_file"
bash "$GATE" check --paths-from "$paths_file" --declaration-from "$decl_file" \
  --evidence-out "$evidence_file" --quiet \
  || fail "docs-only check should pass"
grep -q '## Documentation Impact Gate Evidence' "$evidence_file" \
  || fail "evidence file missing header"
grep -q 'Decision: `pass`' "$evidence_file" \
  || fail "evidence file should record pass decision"

# check: tests-only change passes (internal-only)
cat >"$paths_file" <<'EOF'
tests/test_a.sh
tests/test_b.sh
EOF
bash "$GATE" check --paths-from "$paths_file" --declaration-from "$decl_file" \
  --evidence-out "$evidence_file" --quiet \
  || fail "tests-only check should pass"
grep -q 'Decision: `pass`' "$evidence_file" \
  || fail "tests-only evidence should record pass"

# check: cli change without declaration blocks (exit 1)
cat >"$paths_file" <<'EOF'
scripts/foo.sh
lib/foo.sh
EOF
: >"$decl_file"
set +e
bash "$GATE" check --paths-from "$paths_file" --declaration-from "$decl_file" \
  --evidence-out "$evidence_file" --quiet
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "cli change without declaration should exit 1; got $status"
grep -q 'Decision: `block`' "$evidence_file" \
  || fail "cli without declaration evidence should record block"

# check: --soft converts block into advisory pass
set +e
bash "$GATE" check --paths-from "$paths_file" --declaration-from "$decl_file" \
  --evidence-out "$evidence_file" --quiet --soft
soft_status=$?
set -e
[[ "$soft_status" -eq 0 ]] || fail "--soft should turn block into exit 0; got $soft_status"
grep -q 'Decision: `block`' "$evidence_file" \
  || fail "--soft should still report block decision in evidence"

# check: cli change with valid no-docs-needed declaration passes
cat >"$decl_file" <<'EOF'
Some PR description text.

Docs-Impact: no-docs-needed
Docs-Impact-Note: internal helper rename, no surface change
EOF
bash "$GATE" check --paths-from "$paths_file" --declaration-from "$decl_file" \
  --evidence-out "$evidence_file" --quiet \
  || fail "no-docs-needed with note should pass"
grep -q 'Decision: `pass`' "$evidence_file" \
  || fail "no-docs-needed evidence should record pass"

# check: cli change with no-docs-needed but missing note blocks
cat >"$decl_file" <<'EOF'
Docs-Impact: no-docs-needed
EOF
set +e
bash "$GATE" check --paths-from "$paths_file" --declaration-from "$decl_file" \
  --evidence-out "$evidence_file" --quiet
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "no-docs-needed without note should exit 1; got $status"

# check: cli change with follow-up + ref passes
cat >"$decl_file" <<'EOF'
Docs-Impact: follow-up
Docs-Impact-Followup: RBOKproject/ORDO#999
EOF
bash "$GATE" check --paths-from "$paths_file" --declaration-from "$decl_file" \
  --evidence-out "$evidence_file" --quiet \
  || fail "follow-up with ref should pass"

# check: empty paths input → pass
: >"$paths_file"
bash "$GATE" check --paths-from "$paths_file" --evidence-out "$evidence_file" --quiet \
  || fail "empty paths input should pass"

# check: surface + docs in same change with no declaration → warn (still pass)
cat >"$paths_file" <<'EOF'
scripts/foo.sh
docs/foo.md
EOF
: >"$decl_file"
bash "$GATE" check --paths-from "$paths_file" --declaration-from "$decl_file" \
  --evidence-out "$evidence_file" --quiet \
  || fail "surface+docs no-decl should warn (pass exit)"
grep -q 'Decision: `warn`' "$evidence_file" \
  || fail "surface+docs no-decl evidence should record warn"

# render-evidence does not exit non-zero on a block scope
cat >"$paths_file" <<'EOF'
scripts/foo.sh
EOF
: >"$decl_file"
rendered=$(bash "$GATE" render-evidence --paths-from "$paths_file" \
  --declaration-from "$decl_file")
echo "$rendered" | grep -q 'Decision: `informational`' \
  || fail "render-evidence should mark decision as informational"

# unknown command exits 2
set +e
bash "$GATE" totally-unknown >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "unknown subcommand should exit 2; got $status"

# Pattern override via env var works
override_out=$(
  DOCS_GATE_CLI_PATTERN='^lib/should-not-match' \
  DOCS_GATE_LIB_PATTERN='^lib/should-not-match' \
  DOCS_GATE_DOCS_PATTERN='^docs/' \
  DOCS_GATE_INSTALL_PATTERN='^install\.sh$' \
  DOCS_GATE_ONBOARDING_PATTERN='^scripts/guided_onboarding\.sh$' \
  DOCS_GATE_DISPATCH_PATTERN='^scripts/dispatch_' \
  DOCS_GATE_INTEGRATION_PATTERN='^scripts/pr_merge' \
  DOCS_GATE_PROFILE_PATTERN='^profiles/' \
  DOCS_GATE_WORKFLOW_PATTERN='^\.github/workflows/' \
  DOCS_GATE_TESTS_PATTERN='^tests/' \
    bash "$GATE" summarize <<<'scripts/foo.sh'
)
[[ "$override_out" == "internal=1" ]] \
  || fail "env override should let scripts/foo.sh fall through to internal; got '$override_out'"

printf 'ok - docs_impact_gate library + CLI cover classification, decision matrix, and evidence emission\n'
