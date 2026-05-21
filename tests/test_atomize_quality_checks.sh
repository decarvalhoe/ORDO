#!/usr/bin/env bash
# tests/test_atomize_quality_checks.sh — fixture tests for #766.
#
# One positive + one negative fixture per gate in
# lib/atomize_quality_checks.sh. Plain bash so it can run on the shared
# agent host without bats; emits TAP-ish "ok"/"not ok" lines so a future
# bats wrapper can re-export the same fixtures.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

# shellcheck source=../lib/atomize_quality_checks.sh
. "$ROOT/lib/atomize_quality_checks.sh"

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

assert_pass() {
  local label=$1
  shift
  local stderr_capture
  stderr_capture=$(mktemp -p "$TEST_TMP")
  if "$@" 2>"$stderr_capture" >/dev/null; then
    ok "$label"
  else
    not_ok "$label (expected pass)" "stderr: $(cat "$stderr_capture")"
  fi
}

assert_fail_reason() {
  local label=$1 expected_key=$2
  shift 2
  local stderr_capture
  stderr_capture=$(mktemp -p "$TEST_TMP")
  if "$@" 2>"$stderr_capture" >/dev/null; then
    not_ok "$label (expected fail)" "no failure observed"
    return
  fi
  if grep -Eq "reason=${expected_key}([[:space:]]|$)" "$stderr_capture"; then
    ok "$label"
  else
    not_ok "$label (expected reason=$expected_key)" \
      "got: $(cat "$stderr_capture")"
  fi
}

# ---------------------------------------------------------------------------
# 1. atomize_check_scope_declared
# ---------------------------------------------------------------------------

mkdir -p "$TEST_TMP/scope_pos" "$TEST_TMP/scope_neg"
cat > "$TEST_TMP/scope_pos/child.md" <<'EOF'
scope_files=lib/foo.sh scripts/foo.sh

## Acceptance Criteria

- [ ] one
- [ ] two
EOF
cat > "$TEST_TMP/scope_neg/child.md" <<'EOF'
No scope declared anywhere in this body.

## Acceptance Criteria

- [ ] one
- [ ] two
EOF
assert_pass "scope_declared positive (scope_files= line)" \
  atomize_check_scope_declared "$TEST_TMP/scope_pos/child.md"
assert_fail_reason "scope_declared negative (no scope)" \
  "scope_declared_missing" \
  atomize_check_scope_declared "$TEST_TMP/scope_neg/child.md"

# Bullet-list form is also accepted.
cat > "$TEST_TMP/scope_pos/bullet.md" <<'EOF'
## Allowed files (operator-scope)

- lib/foo.sh
- scripts/foo.sh
EOF
assert_pass "scope_declared positive (Allowed files bullets)" \
  atomize_check_scope_declared "$TEST_TMP/scope_pos/bullet.md"

# ---------------------------------------------------------------------------
# 2. atomize_check_no_overlap
# ---------------------------------------------------------------------------

cat > "$TEST_TMP/ledger.json" <<'EOF'
{
  "agent-001": { "scope_files": ["lib/other.sh", "scripts/other.sh"] },
  "agent-002": { "scope_files": ["lib/conflict.sh"] }
}
EOF
cat > "$TEST_TMP/overlap_pos.md" <<'EOF'
scope_files=lib/unique.sh
EOF
cat > "$TEST_TMP/overlap_neg.md" <<'EOF'
scope_files=lib/conflict.sh scripts/other.sh
EOF
assert_pass "no_overlap positive (no intersection)" \
  atomize_check_no_overlap "$TEST_TMP/overlap_pos.md" "$TEST_TMP/ledger.json"
assert_fail_reason "no_overlap negative (intersects active sibling)" \
  "no_overlap_failed" \
  atomize_check_no_overlap "$TEST_TMP/overlap_neg.md" "$TEST_TMP/ledger.json"
# Empty ledger -> pass (matches fail-soft convention).
assert_pass "no_overlap positive (ledger absent)" \
  atomize_check_no_overlap "$TEST_TMP/overlap_neg.md" "/nonexistent/ledger.json"

# ---------------------------------------------------------------------------
# 3. atomize_check_filiation
# ---------------------------------------------------------------------------

cat > "$TEST_TMP/fil_pos.md" <<'EOF'
Labels: atomized-child, parent:#762

Parent: #762
EOF
cat > "$TEST_TMP/fil_neg.md" <<'EOF'
Labels: priority:P1

Some unrelated body.
EOF
assert_pass "filiation positive (Parent line + labels)" \
  atomize_check_filiation "$TEST_TMP/fil_pos.md" "762"
assert_fail_reason "filiation negative (no Parent: line)" \
  "filiation_body_missing" \
  atomize_check_filiation "$TEST_TMP/fil_neg.md" "762"

# Body has Parent: but labels do not have atomized-child -> fail.
cat > "$TEST_TMP/fil_partial.md" <<'EOF'
Labels: priority:P1, parent:#762

Parent: #762
EOF
assert_fail_reason "filiation negative (missing atomized-child label)" \
  "filiation_label_missing" \
  atomize_check_filiation "$TEST_TMP/fil_partial.md" "762"

# ---------------------------------------------------------------------------
# 4. atomize_check_acceptance
# ---------------------------------------------------------------------------

cat > "$TEST_TMP/acc_pos.md" <<'EOF'
## Acceptance Criteria

- [ ] First testable bullet with detail.
- [ ] Second testable bullet referencing a hash.
- [ ] Third testable bullet.
EOF
cat > "$TEST_TMP/acc_neg.md" <<'EOF'
## Acceptance Criteria

- [ ] only one bullet
EOF
assert_pass "acceptance positive (>=2 testable bullets)" \
  atomize_check_acceptance "$TEST_TMP/acc_pos.md"
assert_fail_reason "acceptance negative (single bullet)" \
  "acceptance_bullets_insufficient" \
  atomize_check_acceptance "$TEST_TMP/acc_neg.md"

cat > "$TEST_TMP/acc_no_section.md" <<'EOF'
No acceptance section here.
EOF
assert_fail_reason "acceptance negative (section absent)" \
  "acceptance_section_missing" \
  atomize_check_acceptance "$TEST_TMP/acc_no_section.md"

# ---------------------------------------------------------------------------
# 5. atomize_check_priority
# ---------------------------------------------------------------------------

assert_pass "priority positive (same as parent)" \
  atomize_check_priority "priority:P1" "P1"
assert_pass "priority positive (one notch less critical)" \
  atomize_check_priority "priority:P2" "P1"
assert_fail_reason "priority negative (too critical)" \
  "priority_out_of_band" \
  atomize_check_priority "priority:P0" "P1"
assert_fail_reason "priority negative (too far below)" \
  "priority_out_of_band" \
  atomize_check_priority "priority:P3" "P1"
assert_fail_reason "priority negative (child label missing)" \
  "priority_child_missing" \
  atomize_check_priority "effort:S" "P1"

# ---------------------------------------------------------------------------
# 6. atomize_check_effort
# ---------------------------------------------------------------------------

assert_pass "effort positive (S)" \
  atomize_check_effort "effort:S"
assert_pass "effort positive (M)" \
  atomize_check_effort "effort:M"
assert_pass "effort positive (L)" \
  atomize_check_effort "effort:L"
assert_fail_reason "effort negative (no label)" \
  "effort_label_missing" \
  atomize_check_effort "priority:P1"
assert_fail_reason "effort negative (invalid value)" \
  "effort_label_invalid" \
  atomize_check_effort "effort:XL"

# ---------------------------------------------------------------------------
# 7. atomize_check_title_format
# ---------------------------------------------------------------------------

assert_pass "title_format positive (feat(scope): summary)" \
  atomize_check_title_format "feat(supervisor): atomize gate child"
assert_fail_reason "title_format negative (no scope)" \
  "title_format_invalid" \
  atomize_check_title_format "feat: missing scope"
assert_fail_reason "title_format negative (empty)" \
  "title_empty" \
  atomize_check_title_format ""

# ---------------------------------------------------------------------------
# 8. atomize_check_no_duplicate
# ---------------------------------------------------------------------------

cat > "$TEST_TMP/dup_body.md" <<'EOF'
scope_files=lib/foo.sh scripts/foo.sh
EOF
cat > "$TEST_TMP/siblings_uniq.json" <<'EOF'
[
  {"title": "feat(supervisor): atomize previously shipped",
   "scope_files": ["lib/bar.sh"]}
]
EOF
cat > "$TEST_TMP/siblings_dup.json" <<'EOF'
[
  {"title": "feat(supervisor): atomize gate child probe",
   "scope_files": ["lib/foo.sh", "scripts/foo.sh"]}
]
EOF
assert_pass "no_duplicate positive (different fingerprint)" \
  atomize_check_no_duplicate "$TEST_TMP/dup_body.md" \
    "feat(supervisor): atomize gate child probe" \
    "$TEST_TMP/siblings_uniq.json"
assert_fail_reason "no_duplicate negative (fingerprint collides)" \
  "no_duplicate_failed" \
  atomize_check_no_duplicate "$TEST_TMP/dup_body.md" \
    "feat(supervisor): atomize gate child probe" \
    "$TEST_TMP/siblings_dup.json"

# ---------------------------------------------------------------------------
# 9. atomize_check_test_plan
# ---------------------------------------------------------------------------

cat > "$TEST_TMP/tp_pos.md" <<'EOF'
## Test plan

- [ ] Run fixture suite.
- [x] Smoke CLI manually.
EOF
cat > "$TEST_TMP/tp_neg.md" <<'EOF'
## Test plan

The plan is a vibe.
EOF
cat > "$TEST_TMP/tp_missing.md" <<'EOF'
Nothing about testing here.
EOF
assert_pass "test_plan positive (checkbox bullets)" \
  atomize_check_test_plan "$TEST_TMP/tp_pos.md"
assert_fail_reason "test_plan negative (prose only)" \
  "test_plan_checkbox_missing" \
  atomize_check_test_plan "$TEST_TMP/tp_neg.md"
assert_fail_reason "test_plan negative (section missing)" \
  "test_plan_section_missing" \
  atomize_check_test_plan "$TEST_TMP/tp_missing.md"

# ---------------------------------------------------------------------------
# 10. atomize_check_dependency_graph
# ---------------------------------------------------------------------------

cat > "$TEST_TMP/dep_parent.json" <<'EOF'
{
  "number": 762,
  "title": "feat(supervisor): theme",
  "body": "## Atomic tasks\n\n- [ ] #763 — first\n- [ ] #766 — gate library (depends on #763)\n",
  "labels": [{"name": "priority:P1"}]
}
EOF
cat > "$TEST_TMP/dep_child_pos.md" <<'EOF'
Parent: #762
Depends on: #763
EOF
cat > "$TEST_TMP/dep_child_unlisted.md" <<'EOF'
Parent: #762
Depends on: #999
EOF
cat > "$TEST_TMP/dep_child_none.md" <<'EOF'
Parent: #762
EOF
assert_pass "dependency_graph positive (dep listed in Atomic tasks)" \
  atomize_check_dependency_graph "$TEST_TMP/dep_child_pos.md" "$TEST_TMP/dep_parent.json"
assert_fail_reason "dependency_graph negative (dep not in Atomic tasks)" \
  "dependency_not_in_atomic" \
  atomize_check_dependency_graph "$TEST_TMP/dep_child_unlisted.md" "$TEST_TMP/dep_parent.json"
# No Depends on: -> pass (nothing to enforce).
assert_pass "dependency_graph positive (no Depends declared)" \
  atomize_check_dependency_graph "$TEST_TMP/dep_child_none.md" "$TEST_TMP/dep_parent.json"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '1..%d\n' "$TESTS_RUN"
if [ "$TESTS_FAIL" -eq 0 ]; then
  printf '# all %d gate-check assertions passed\n' "$TESTS_RUN"
  exit 0
fi
printf '# %d/%d assertions failed\n' "$TESTS_FAIL" "$TESTS_RUN" >&2
exit 1
