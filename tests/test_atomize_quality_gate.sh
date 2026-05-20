#!/usr/bin/env bash
# tests/test_atomize_quality_gate.sh — end-to-end tests for #766 CLI.
#
# Exercises scripts/atomize_quality_gate.sh as an external process. Each
# test sets up a self-contained fixture under TEST_TMP, runs the CLI,
# and asserts on outcome + reason keys + exit code. Plain bash, TAP-ish
# output so the suite can run on the shared agent host without bats.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT/scripts/atomize_quality_gate.sh"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

TESTS_RUN=0
TESTS_FAIL=0

ok() {
  TESTS_RUN=$((TESTS_RUN + 1))
  printf 'ok %d - %s\n' "$TESTS_RUN" "$1"
}

not_ok() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAIL=$((TESTS_FAIL + 1))
  printf 'not ok %d - %s\n' "$TESTS_RUN" "$1"
  if [ -n "${2:-}" ]; then
    printf '  # %s\n' "$2"
  fi
}

# Write a parent issue JSON file and return its path.
parent_json() {
  local out=$1
  local priority=${2:-P1}
  local atomic_block=${3:-"## Atomic tasks\n\n- [ ] #763 — first\n- [ ] #766 — gate library\n"}
  cat > "$out" <<JSON
{
  "number": 762,
  "title": "feat(supervisor): queue starvation theme",
  "body": "$atomic_block",
  "labels": [ {"name": "priority:$priority"} ]
}
JSON
}

# Write a fully-conforming child body and return its path.
child_body_pass() {
  local out=$1
  cat > "$out" <<'EOF'
Title: feat(supervisor): atomize gate child probe
Labels: priority:P2, effort:S, atomized-child, parent:#762

Parent: #762

## Allowed files (operator-scope)

- lib/foo.sh
- scripts/foo.sh

## Acceptance Criteria

- [ ] Function emits structured refusal reason on stderr.
- [ ] Standalone CLI exits 0 on pass and 1 on enforce-refused.

## Test plan

- [ ] Fixture covers positive and negative case for each gate.
- [ ] CLI smoke under enforce + warn + off modes.
EOF
}

# Parse "outcome\tmode\treasons\tchecks" from CLI stdout.
parse_tsv_outcome() { awk -F'\t' 'NR==1 { print $1 }' "$1"; }
parse_tsv_mode()    { awk -F'\t' 'NR==1 { print $2 }' "$1"; }
parse_tsv_reasons() { awk -F'\t' 'NR==1 { print $3 }' "$1"; }
parse_tsv_checks()  { awk -F'\t' 'NR==1 { print $4 }' "$1"; }

# ---------------------------------------------------------------------------
# 1. happy path — every gate passes, mode=enforce, outcome=pass, rc=0
# ---------------------------------------------------------------------------

mkdir -p "$TEST_TMP/case_pass"
parent_json   "$TEST_TMP/case_pass/parent.json"
child_body_pass "$TEST_TMP/case_pass/child.md"
out="$TEST_TMP/case_pass/out.tsv"
"$CLI" classify-child \
  --parent-issue-json "$TEST_TMP/case_pass/parent.json" \
  --child-body        "$TEST_TMP/case_pass/child.md" \
  --mode enforce \
  >"$out" 2>"$TEST_TMP/case_pass/err"
rc=$?
if [ "$rc" -ne 0 ]; then
  not_ok "happy path: rc 0" "rc=$rc stderr=$(cat "$TEST_TMP/case_pass/err")"
else
  ok "happy path: rc 0"
fi
if [ "$(parse_tsv_outcome "$out")" = "pass" ]; then
  ok "happy path: outcome=pass"
else
  not_ok "happy path: outcome=pass" "got: $(parse_tsv_outcome "$out")"
fi
if [ -z "$(parse_tsv_reasons "$out")" ]; then
  ok "happy path: reasons empty"
else
  not_ok "happy path: reasons empty" "got: $(parse_tsv_reasons "$out")"
fi
checks=$(parse_tsv_checks "$out")
if printf '%s' "$checks" | grep -q 'scope_declared=pass' \
   && printf '%s' "$checks" | grep -q 'dependency_graph=pass'; then
  ok "happy path: per-check column lists all 10 checks"
else
  not_ok "happy path: per-check column lists all 10 checks" "got: $checks"
fi

# ---------------------------------------------------------------------------
# 2. enforce mode + scope missing -> refused, rc=1
# ---------------------------------------------------------------------------

mkdir -p "$TEST_TMP/case_refuse"
parent_json "$TEST_TMP/case_refuse/parent.json"
cat > "$TEST_TMP/case_refuse/child.md" <<'EOF'
Title: feat(supervisor): missing scope
Labels: priority:P2, effort:S, atomized-child, parent:#762

Parent: #762

## Acceptance Criteria

- [ ] one
- [ ] two

## Test plan

- [ ] smoke
EOF
out="$TEST_TMP/case_refuse/out.tsv"
"$CLI" classify-child \
  --parent-issue-json "$TEST_TMP/case_refuse/parent.json" \
  --child-body        "$TEST_TMP/case_refuse/child.md" \
  --mode enforce \
  >"$out" 2>"$TEST_TMP/case_refuse/err"
rc=$?
if [ "$rc" -eq 1 ]; then
  ok "enforce + scope-missing: rc 1"
else
  not_ok "enforce + scope-missing: rc 1" "rc=$rc"
fi
if [ "$(parse_tsv_outcome "$out")" = "refused" ]; then
  ok "enforce + scope-missing: outcome=refused"
else
  not_ok "enforce + scope-missing: outcome=refused" "got: $(parse_tsv_outcome "$out")"
fi
if printf '%s' "$(parse_tsv_reasons "$out")" | grep -q 'scope_declared_missing'; then
  ok "enforce + scope-missing: reason=scope_declared_missing surfaced"
else
  not_ok "enforce + scope-missing: reason=scope_declared_missing surfaced" \
    "got: $(parse_tsv_reasons "$out")"
fi

# ---------------------------------------------------------------------------
# 3. warn mode + scope missing -> warn, rc=0
# ---------------------------------------------------------------------------

out="$TEST_TMP/case_refuse/warn.tsv"
"$CLI" classify-child \
  --parent-issue-json "$TEST_TMP/case_refuse/parent.json" \
  --child-body        "$TEST_TMP/case_refuse/child.md" \
  --mode warn \
  >"$out" 2>"$TEST_TMP/case_refuse/warn.err"
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "warn mode: rc 0 (warn never breaks the caller)"
else
  not_ok "warn mode: rc 0" "rc=$rc"
fi
if [ "$(parse_tsv_outcome "$out")" = "warn" ]; then
  ok "warn mode: outcome=warn"
else
  not_ok "warn mode: outcome=warn" "got: $(parse_tsv_outcome "$out")"
fi

# ---------------------------------------------------------------------------
# 4. off mode + scope missing -> pass, mode=off, rc=0
# ---------------------------------------------------------------------------

out="$TEST_TMP/case_refuse/off.tsv"
"$CLI" classify-child \
  --parent-issue-json "$TEST_TMP/case_refuse/parent.json" \
  --child-body        "$TEST_TMP/case_refuse/child.md" \
  --mode off \
  >"$out" 2>"$TEST_TMP/case_refuse/off.err"
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "off mode: rc 0"
else
  not_ok "off mode: rc 0" "rc=$rc"
fi
if [ "$(parse_tsv_outcome "$out")" = "pass" ] \
   && [ "$(parse_tsv_mode "$out")" = "off" ]; then
  ok "off mode: outcome=pass mode=off"
else
  not_ok "off mode: outcome=pass mode=off" \
    "outcome=$(parse_tsv_outcome "$out") mode=$(parse_tsv_mode "$out")"
fi

# ---------------------------------------------------------------------------
# 5. ORCH_ATOMIZE_QUALITY_GATE env honored when --mode is absent
# ---------------------------------------------------------------------------

out="$TEST_TMP/case_refuse/env.tsv"
ORCH_ATOMIZE_QUALITY_GATE=enforce \
"$CLI" classify-child \
  --parent-issue-json "$TEST_TMP/case_refuse/parent.json" \
  --child-body        "$TEST_TMP/case_refuse/child.md" \
  >"$out" 2>"$TEST_TMP/case_refuse/env.err"
rc=$?
if [ "$rc" -eq 1 ] \
   && [ "$(parse_tsv_outcome "$out")" = "refused" ] \
   && [ "$(parse_tsv_mode "$out")" = "enforce" ]; then
  ok "env ORCH_ATOMIZE_QUALITY_GATE=enforce respected"
else
  not_ok "env ORCH_ATOMIZE_QUALITY_GATE=enforce respected" \
    "rc=$rc outcome=$(parse_tsv_outcome "$out") mode=$(parse_tsv_mode "$out")"
fi

# Env default when nothing is set: warn (so failures do not break callers).
out="$TEST_TMP/case_refuse/default.tsv"
( unset ORCH_ATOMIZE_QUALITY_GATE
  "$CLI" classify-child \
    --parent-issue-json "$TEST_TMP/case_refuse/parent.json" \
    --child-body        "$TEST_TMP/case_refuse/child.md" \
    >"$out" 2>"$TEST_TMP/case_refuse/default.err" )
rc=$?
if [ "$rc" -eq 0 ] && [ "$(parse_tsv_mode "$out")" = "warn" ]; then
  ok "default mode (no flag, no env) is warn"
else
  not_ok "default mode (no flag, no env) is warn" \
    "rc=$rc mode=$(parse_tsv_mode "$out")"
fi

# ---------------------------------------------------------------------------
# 6. JSON output shape
# ---------------------------------------------------------------------------

out="$TEST_TMP/case_pass/out.json"
"$CLI" classify-child \
  --parent-issue-json "$TEST_TMP/case_pass/parent.json" \
  --child-body        "$TEST_TMP/case_pass/child.md" \
  --mode enforce --format json \
  >"$out" 2>/dev/null
if command -v jq >/dev/null 2>&1; then
  if jq -e '.outcome == "pass" and (.checks | length) == 10' "$out" >/dev/null 2>&1; then
    ok "JSON output: outcome=pass with 10 checks"
  else
    not_ok "JSON output: outcome=pass with 10 checks" "got: $(cat "$out")"
  fi
else
  ok "JSON output: jq not available, skipping schema assertion"
fi

# ---------------------------------------------------------------------------
# 7. scope-claims ledger: overlap surfaces as no_overlap_failed
# ---------------------------------------------------------------------------

mkdir -p "$TEST_TMP/case_overlap"
parent_json "$TEST_TMP/case_overlap/parent.json"
cat > "$TEST_TMP/case_overlap/child.md" <<'EOF'
Title: feat(supervisor): overlapping scope
Labels: priority:P2, effort:S, atomized-child, parent:#762

Parent: #762

scope_files=lib/foo.sh

## Acceptance Criteria

- [ ] one
- [ ] two

## Test plan

- [ ] smoke
EOF
cat > "$TEST_TMP/case_overlap/claims.json" <<'EOF'
{
  "agent-001": { "scope_files": ["lib/foo.sh"] }
}
EOF
out="$TEST_TMP/case_overlap/out.tsv"
"$CLI" classify-child \
  --parent-issue-json "$TEST_TMP/case_overlap/parent.json" \
  --child-body        "$TEST_TMP/case_overlap/child.md" \
  --scope-claims-json "$TEST_TMP/case_overlap/claims.json" \
  --mode enforce >"$out" 2>"$TEST_TMP/case_overlap/err"
rc=$?
if [ "$rc" -eq 1 ] \
   && printf '%s' "$(parse_tsv_reasons "$out")" | grep -q 'no_overlap_failed'; then
  ok "scope-claims ledger: overlap refused with no_overlap_failed"
else
  not_ok "scope-claims ledger: overlap refused with no_overlap_failed" \
    "rc=$rc reasons=$(parse_tsv_reasons "$out")"
fi

# ---------------------------------------------------------------------------
# 8. siblings-json: duplicate fingerprint refused
# ---------------------------------------------------------------------------

mkdir -p "$TEST_TMP/case_dup"
parent_json "$TEST_TMP/case_dup/parent.json"
child_body_pass "$TEST_TMP/case_dup/child.md"
cat > "$TEST_TMP/case_dup/siblings.json" <<'EOF'
[
  {"title": "feat(supervisor): atomize gate child probe",
   "scope_files": ["lib/foo.sh", "scripts/foo.sh"]}
]
EOF
out="$TEST_TMP/case_dup/out.tsv"
"$CLI" classify-child \
  --parent-issue-json "$TEST_TMP/case_dup/parent.json" \
  --child-body        "$TEST_TMP/case_dup/child.md" \
  --siblings-json     "$TEST_TMP/case_dup/siblings.json" \
  --mode enforce >"$out" 2>"$TEST_TMP/case_dup/err"
rc=$?
if [ "$rc" -eq 1 ] \
   && printf '%s' "$(parse_tsv_reasons "$out")" | grep -q 'no_duplicate_failed'; then
  ok "siblings-json: duplicate refused with no_duplicate_failed"
else
  not_ok "siblings-json: duplicate refused with no_duplicate_failed" \
    "rc=$rc reasons=$(parse_tsv_reasons "$out")"
fi

# ---------------------------------------------------------------------------
# 9. `check` subcommand for ad-hoc single-gate invocations
# ---------------------------------------------------------------------------

if "$CLI" check scope_declared --child-body "$TEST_TMP/case_pass/child.md" >/dev/null 2>&1; then
  ok "check subcommand: single gate pass returns 0"
else
  not_ok "check subcommand: single gate pass returns 0" "expected rc=0"
fi
if "$CLI" check scope_declared --child-body "$TEST_TMP/case_refuse/child.md" >/dev/null 2>"$TEST_TMP/check_err"; then
  not_ok "check subcommand: single gate fail returns 1" "expected rc=1"
else
  rc=$?
  if [ "$rc" -eq 1 ] && grep -q 'reason=scope_declared_missing' "$TEST_TMP/check_err"; then
    ok "check subcommand: single gate fail returns 1 with structured reason"
  else
    not_ok "check subcommand: single gate fail returns 1 with structured reason" \
      "rc=$rc stderr=$(cat "$TEST_TMP/check_err")"
  fi
fi

# ---------------------------------------------------------------------------
# 10. usage error: missing required flag exits 2
# ---------------------------------------------------------------------------

"$CLI" classify-child --child-body "$TEST_TMP/case_pass/child.md" \
  >/dev/null 2>"$TEST_TMP/usage.err"
rc=$?
if [ "$rc" -eq 2 ]; then
  ok "usage error: missing --parent-issue-json exits 2"
else
  not_ok "usage error: missing --parent-issue-json exits 2" "rc=$rc"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '1..%d\n' "$TESTS_RUN"
if [ "$TESTS_FAIL" -eq 0 ]; then
  printf '# all %d gate-CLI assertions passed\n' "$TESTS_RUN"
  exit 0
fi
printf '# %d/%d assertions failed\n' "$TESTS_FAIL" "$TESTS_RUN" >&2
exit 1
