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
# tests/test_docs_impact_gate.sh — guard for multi-agent template changes (#316).
#
# Covers:
#   - No guarded paths changed: gate exits 0 silently regardless of body.
#   - Guarded path changed AND PR body has the docs-impact block: exit 0.
#   - Guarded path changed AND body lacks the block: exit 4 by default,
#     exit 0 with --warn-only or DOCS_IMPACT_GATE_MODE=warn.
#   - Localized header (Impact documentation, Impact docs) accepted.
#   - DOCS_IMPACT_GUARDED_PATHS extends defaults; comma + semicolon
#     separators work.
#   - Glob entries in DOCS_IMPACT_GUARDED_PATHS match correctly.
#   - Stdin input via --diff - or --pr-body - (one at a time).
#   - --json output emits a valid status payload.
#
# Note: this test deliberately runs without `set -e` because most assertions
# capture a deliberately non-zero gate exit via `out=$("$GATE" ...); rc=$?`,
# which would otherwise be swallowed by errexit in command substitutions.
set -uo pipefail
GATE="$ROOT/scripts/docs_impact_gate.sh"
trap 'rm -rf "$TEST_TMP"' EXIT

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
# shellcheck disable=SC2016 # backticks are literal markdown in the expected evidence body.
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
# shellcheck disable=SC2016 # backticks are literal markdown in the expected evidence body.
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
# shellcheck disable=SC2016 # backticks are literal markdown in the expected evidence body.
grep -q 'Decision: `block`' "$evidence_file" \
  || fail "cli without declaration evidence should record block"

# check: --soft converts block into advisory pass
set +e
bash "$GATE" check --paths-from "$paths_file" --declaration-from "$decl_file" \
  --evidence-out "$evidence_file" --quiet --soft
soft_status=$?
set -e
[[ "$soft_status" -eq 0 ]] || fail "--soft should turn block into exit 0; got $soft_status"
# shellcheck disable=SC2016 # backticks are literal markdown in the expected evidence body.
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
# shellcheck disable=SC2016 # backticks are literal markdown in the expected evidence body.
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
# shellcheck disable=SC2016 # backticks are literal markdown in the expected evidence body.
grep -q 'Decision: `warn`' "$evidence_file" \
  || fail "surface+docs no-decl evidence should record warn"

# render-evidence does not exit non-zero on a block scope
cat >"$paths_file" <<'EOF'
scripts/foo.sh
EOF
: >"$decl_file"
rendered=$(bash "$GATE" render-evidence --paths-from "$paths_file" \
  --declaration-from "$decl_file")
# shellcheck disable=SC2016 # backticks are literal markdown in the expected evidence body.
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
write_diff() {
  local name=$1
  shift
  local out="$TEST_TMP/$name"
  : > "$out"
  for line in "$@"; do
    printf '%s\n' "$line" >> "$out"
  done
  printf '%s' "$out"
write_body() {
  local name=$1 content=$2
  local out="$TEST_TMP/$name"
  printf '%s' "$content" > "$out"
  printf '%s' "$out"
run_gate() {
  local out status
  out=$("$GATE" "$@" 2>&1)
  status=$?
  printf '%s\n' "$out"
  return "$status"
# --- Case 1: no guarded paths changed → status=ok exit 0 regardless of body.
diff_unrelated=$(write_diff diff_unrelated 'lib/foo.sh' 'README.md' 'tests/test_foo.sh')
body_empty=$(write_body body_empty '')
out=$(run_gate --diff "$diff_unrelated" --pr-body "$body_empty"); rc=$?
[[ "$rc" -eq 0 ]] || fail "unrelated diff: expected exit 0, got=$rc out=$out"
[[ "$out" == *"status=ok"* ]] || fail "unrelated diff: expected status=ok, got: $out"
[[ "$out" == *"guarded_paths=0"* ]] || fail "unrelated diff: expected guarded_paths=0, got: $out"
# --- Case 2: guarded path + body has the docs-impact block → status=ok.
diff_guarded=$(write_diff diff_guarded \
  'docs/templates/multi-agent/docs-impact.md' \
  'lib/foo.sh' \
body_with_block=$(write_body body_with_block '## Summary
This PR updates the docs-impact template.
## Docs Impact
- [x] Updated downstream onboarding doc
- [ ] Refresh the multi-agent README index
')
out=$(run_gate --diff "$diff_guarded" --pr-body "$body_with_block"); rc=$?
[[ "$rc" -eq 0 ]] || fail "guarded+block: expected exit 0, got=$rc out=$out"
[[ "$out" == *"status=ok"* ]] || fail "guarded+block: expected status=ok, got: $out"
[[ "$out" == *"guarded_paths=1"* ]] || fail "guarded+block: expected guarded_paths=1, got: $out"
[[ "$out" == *"docs/templates/multi-agent/docs-impact.md"* ]] \
  || fail "guarded+block: expected guarded path printed, got: $out"
# --- Case 3: guarded path + body MISSING block → exit 4 (block) by default.
body_missing=$(write_body body_missing '## Summary
This PR updates the multi-agent README without rendering the docs-impact
checklist. The gate should refuse.
')
out=$(run_gate --diff "$diff_guarded" --pr-body "$body_missing"); rc=$?
[[ "$rc" -eq 4 ]] || fail "missing block default: expected exit 4, got=$rc out=$out"
[[ "$out" == *"status=block"* ]] || fail "missing block default: expected status=block, got: $out"
[[ "$out" == *"docs-impact block missing"* ]] \
  || fail "missing block default: expected explanatory message, got: $out"
# --- Case 4: --warn-only downgrades missing block to status=warn exit 0.
out=$(run_gate --diff "$diff_guarded" --pr-body "$body_missing" --warn-only); rc=$?
[[ "$rc" -eq 0 ]] || fail "warn-only: expected exit 0, got=$rc out=$out"
[[ "$out" == *"status=warn"* ]] || fail "warn-only: expected status=warn, got: $out"
# --- Case 5: DOCS_IMPACT_GATE_MODE=warn has the same effect as --warn-only.
out=$(DOCS_IMPACT_GATE_MODE=warn run_gate --diff "$diff_guarded" --pr-body "$body_missing"); rc=$?
[[ "$rc" -eq 0 ]] || fail "env warn mode: expected exit 0, got=$rc out=$out"
[[ "$out" == *"status=warn"* ]] || fail "env warn mode: expected status=warn, got: $out"
# --- Case 6: localized headers accepted.
body_fr_header=$(write_body body_fr_header '## Résumé
Mise à jour du template multi-agent.
## Impact documentation
- [ ] Mettre à jour le guide opérateur
')
out=$(run_gate --diff "$diff_guarded" --pr-body "$body_fr_header"); rc=$?
[[ "$rc" -eq 0 ]] || fail "fr header: expected exit 0, got=$rc out=$out"
[[ "$out" == *"status=ok"* ]] || fail "fr header: expected status=ok, got: $out"
body_alt_header=$(write_body body_alt_header '## Documentation Impact
- [x] Existing onboarding doc still accurate
')
out=$(run_gate --diff "$diff_guarded" --pr-body "$body_alt_header"); rc=$?
[[ "$rc" -eq 0 ]] || fail "Documentation Impact header: expected exit 0, got=$rc out=$out"
body_impact_docs=$(write_body body_impact_docs '## Impact docs
- [ ] Refresh README')
out=$(run_gate --diff "$diff_guarded" --pr-body "$body_impact_docs"); rc=$?
[[ "$rc" -eq 0 ]] || fail "Impact docs header: expected exit 0, got=$rc out=$out"
# --- Case 7: DOCS_IMPACT_GUARDED_PATHS extends defaults, supports separators.
diff_extra_path=$(write_diff diff_extra_path 'config/agent-roster/main.yaml')
body_with_block_extra=$(write_body body_with_block_extra '## Docs Impact
- [ ] Update operator playbook
')
# Without override: extra path is NOT guarded.
out=$(run_gate --diff "$diff_extra_path" --pr-body "$body_with_block_extra"); rc=$?
[[ "$rc" -eq 0 ]] || fail "extra path no override: expected exit 0, got=$rc"
[[ "$out" == *"guarded_paths=0"* ]] || fail "extra path no override: expected guarded_paths=0, got: $out"
# With override: extra path is now guarded; body has block → exit 0.
out=$(DOCS_IMPACT_GUARDED_PATHS='config/agent-roster/' \
  run_gate --diff "$diff_extra_path" --pr-body "$body_with_block_extra"); rc=$?
[[ "$rc" -eq 0 ]] || fail "extra path with override: expected exit 0, got=$rc out=$out"
[[ "$out" == *"guarded_paths=1"* ]] || fail "extra path override: expected guarded_paths=1, got: $out"
# Same override, body MISSING block → exit 4.
body_missing_extra=$(write_body body_missing_extra '## Summary
Roster bump only.
')
out=$(DOCS_IMPACT_GUARDED_PATHS='config/agent-roster/' \
  run_gate --diff "$diff_extra_path" --pr-body "$body_missing_extra"); rc=$?
[[ "$rc" -eq 4 ]] || fail "extra path override no block: expected exit 4, got=$rc out=$out"
# Comma + semicolon separators in override; defaults still active.
diff_combo=$(write_diff diff_combo \
  'docs/templates/multi-agent/docs-impact.md' \
  'docs/runbooks/operator.md' \
out=$(DOCS_IMPACT_GUARDED_PATHS='docs/runbooks/,examples/profiles/;config/agent-roster/' \
  run_gate --diff "$diff_combo" --pr-body "$body_with_block_extra"); rc=$?
[[ "$rc" -eq 0 ]] || fail "combo override: expected exit 0, got=$rc out=$out"
[[ "$out" == *"guarded_paths=2"* ]] \
  || fail "combo override: expected guarded_paths=2 (default + override), got: $out"
# --- Case 8: glob entry in DOCS_IMPACT_GUARDED_PATHS.
diff_glob_match=$(write_diff diff_glob_match 'config/profiles/team-a/agents.yaml')
out=$(DOCS_IMPACT_GUARDED_PATHS='config/profiles/*/agents.yaml' \
  run_gate --diff "$diff_glob_match" --pr-body "$body_missing_extra"); rc=$?
[[ "$rc" -eq 4 ]] || fail "glob match: expected exit 4, got=$rc out=$out"
diff_glob_no_match=$(write_diff diff_glob_no_match 'config/profiles/team-a/other.txt')
out=$(DOCS_IMPACT_GUARDED_PATHS='config/profiles/*/agents.yaml' \
  run_gate --diff "$diff_glob_no_match" --pr-body "$body_missing_extra"); rc=$?
[[ "$rc" -eq 0 ]] || fail "glob no-match: expected exit 0, got=$rc out=$out"
[[ "$out" == *"guarded_paths=0"* ]] || fail "glob no-match: expected guarded_paths=0, got: $out"
# --- Case 9: stdin input.
out=$(printf '%s\n' 'docs/templates/multi-agent/docs-impact.md' \
  | "$GATE" --diff - --pr-body "$body_missing" 2>&1); rc=$?
[[ "$rc" -eq 4 ]] || fail "stdin diff: expected exit 4, got=$rc out=$out"
out=$(printf '%s\n' '## Docs Impact' '- [ ] update' \
  | "$GATE" --diff "$diff_guarded" --pr-body - 2>&1); rc=$?
[[ "$rc" -eq 0 ]] || fail "stdin body: expected exit 0, got=$rc out=$out"
# --- Case 10: --json output emits machine-readable status.
out=$(run_gate --diff "$diff_guarded" --pr-body "$body_missing" --json); rc=$?
[[ "$rc" -eq 4 ]] || fail "json missing: expected exit 4, got=$rc"
[[ "$out" == *'"status":"block"'* ]] || fail "json missing: expected status=block, got: $out"
[[ "$out" == *'"guarded_paths_changed":1'* ]] \
  || fail "json missing: expected guarded_paths_changed=1, got: $out"
[[ "$out" == *'"guarded_hits":["docs/templates/multi-agent/docs-impact.md"]'* ]] \
  || fail "json missing: expected guarded_hits array, got: $out"
out=$(run_gate --diff "$diff_unrelated" --pr-body "$body_empty" --json); rc=$?
[[ "$rc" -eq 0 ]] || fail "json clean: expected exit 0, got=$rc"
[[ "$out" == *'"status":"ok"'* ]] || fail "json clean: expected status=ok, got: $out"
[[ "$out" == *'"guarded_paths_changed":0'* ]] \
  || fail "json clean: expected guarded_paths_changed=0, got: $out"
[[ "$out" == *'"guarded_hits":[]'* ]] \
  || fail "json clean: expected empty guarded_hits, got: $out"
# --- Case 11: header that is NOT in the allowlist must NOT count as a block.
body_wrong_header=$(write_body body_wrong_header '## Implementation Notes
- [ ] some unrelated checkbox
')
out=$(run_gate --diff "$diff_guarded" --pr-body "$body_wrong_header"); rc=$?
[[ "$rc" -eq 4 ]] || fail "wrong header: expected exit 4, got=$rc out=$out"
# --- Case 12: docs-impact header followed by another header before any
#               checklist must NOT count as a present block.
body_empty_block=$(write_body body_empty_block '## Docs Impact
## Next Section
- [ ] something else
')
out=$(run_gate --diff "$diff_guarded" --pr-body "$body_empty_block"); rc=$?
[[ "$rc" -eq 4 ]] || fail "empty block: expected exit 4 (no checklist between header and next section), got=$rc out=$out"
# --- Case 13: comments and blank lines in --diff input are tolerated.
diff_with_comments=$(write_diff diff_with_comments \
  '# Generated by git diff --name-only HEAD~1' \
  '' \
  'docs/templates/multi-agent/docs-impact.md' \
  '' \
  '# trailing comment' \
out=$(run_gate --diff "$diff_with_comments" --pr-body "$body_with_block"); rc=$?
[[ "$rc" -eq 0 ]] || fail "diff with comments: expected exit 0, got=$rc out=$out"
[[ "$out" == *"guarded_paths=1"* ]] \
  || fail "diff with comments: expected guarded_paths=1, got: $out"
# --- Case 14: missing required arg returns usage error (exit 2).
out=$("$GATE" --pr-body "$body_empty" 2>&1)
rc=$?
[[ "$rc" -eq 2 ]] || fail "missing --diff: expected exit 2, got=$rc out=$out"
out=$("$GATE" --diff "$diff_unrelated" 2>&1)
rc=$?
[[ "$rc" -eq 2 ]] || fail "missing --pr-body: expected exit 2, got=$rc out=$out"
# --- Case 15: refuse when both inputs would read stdin.
out=$(printf 'x\n' | "$GATE" --diff - --pr-body - 2>&1)
rc=$?
[[ "$rc" -eq 2 ]] || fail "double-stdin: expected exit 2, got=$rc out=$out"
printf 'ok - docs_impact_gate tests passed\n'
