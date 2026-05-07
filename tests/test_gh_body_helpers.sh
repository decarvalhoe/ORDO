#!/usr/bin/env bash
# tests/test_gh_body_helpers.sh — body-file integrity tests for the gh body helpers.
#
# Verifies that backticks, command substitutions, single/double quotes, and
# multi-line markdown all round-trip exactly through the helper into a
# tempfile passed to gh via --body-file.
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

GH_MOCK_OUT="$TEST_TMP/out"
mkdir -p "$GH_MOCK_OUT" "$TEST_TMP/bin"

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
captured=""
declare -a captured_argv=()
while [ $# -gt 0 ]; do
  case "$1" in
    --body-file)
      captured="$2"
      shift 2
      ;;
    *)
      captured_argv+=("$1")
      shift
      ;;
  esac
done
if [ -z "$captured" ]; then
  printf 'mock gh: missing --body-file arg\n' >&2
  exit 99
fi
cp "$captured" "$GH_MOCK_OUT/last_body.md"
if [ "${#captured_argv[@]}" -gt 0 ]; then
  printf '%s\n' "${captured_argv[@]}" > "$GH_MOCK_OUT/last_argv.txt"
else
  : > "$GH_MOCK_OUT/last_argv.txt"
fi
EOF
chmod +x "$TEST_TMP/bin/gh"

export GH_MOCK_OUT
export PATH="$TEST_TMP/bin:$PATH"

# shellcheck source=lib/gh_body_helpers.sh
source "$ROOT/lib/gh_body_helpers.sh"

assert_body_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [ ! -f "$actual" ]; then
    fail "$label: body file missing at $actual"
  fi
  if ! diff -u <(printf '%s' "$expected") "$actual" >/dev/null; then
    printf 'not ok - %s: body content mismatch\n' "$label" >&2
    diff -u <(printf '%s' "$expected") "$actual" >&2 || true
    exit 1
  fi
}

assert_argv_contains() {
  local label="$1"
  local needle="$2"
  if ! grep -qxF -- "$needle" "$GH_MOCK_OUT/last_argv.txt"; then
    printf 'not ok - %s: argv missing token %s\n' "$label" "$needle" >&2
    printf 'argv was:\n' >&2
    cat "$GH_MOCK_OUT/last_argv.txt" >&2 || true
    exit 1
  fi
}

# Case 1 — backticks must remain literal.
# shellcheck disable=SC2016 # backticks are part of the test fixture.
body_backtick='Backtick test: `echo OOPS` and ``inline`` must stay literal.'
printf '%s' "$body_backtick" | gh_issue_comment_body_file 42 --repo RBOKproject/ORDO \
  || fail "backticks: gh_issue_comment_body_file returned non-zero"
assert_body_eq "backticks" "$body_backtick" "$GH_MOCK_OUT/last_body.md"
assert_argv_contains "backticks" "issue"
assert_argv_contains "backticks" "comment"
assert_argv_contains "backticks" "42"

# Case 2 — command substitution must remain literal.
# shellcheck disable=SC2016 # $(...) and $HOME are part of the test fixture.
body_subst='Subst: $(rm -rf /) and `whoami` and $HOME must not run or expand.'
printf '%s' "$body_subst" | gh_pr_comment_body_file 7 --repo RBOKproject/ORDO \
  || fail "subst: gh_pr_comment_body_file returned non-zero"
assert_body_eq "command-substitution" "$body_subst" "$GH_MOCK_OUT/last_body.md"
assert_argv_contains "command-substitution" "pr"
assert_argv_contains "command-substitution" "comment"
assert_argv_contains "command-substitution" "7"

# Case 3 — single and double quotes must remain literal.
body_quotes="Quotes: it's said \"don't trust args\" — both kinds matter."
printf '%s' "$body_quotes" | gh_pr_review_body_file 9 --repo RBOKproject/ORDO --comment \
  || fail "quotes: gh_pr_review_body_file returned non-zero"
assert_body_eq "quotes" "$body_quotes" "$GH_MOCK_OUT/last_body.md"
assert_argv_contains "quotes" "review"
assert_argv_contains "quotes" "9"
assert_argv_contains "quotes" "--comment"

# Case 4 — multi-line markdown (newlines, fenced code blocks, lists).
body_multi=$'Line 1\nLine 2\n\n```bash\necho "fenced `block`"\n```\n- bullet a\n- bullet b\n'
printf '%s' "$body_multi" | gh_issue_create_body_file --repo RBOKproject/ORDO --title 'multi-line body' \
  || fail "multiline: gh_issue_create_body_file returned non-zero"
assert_body_eq "multiline" "$body_multi" "$GH_MOCK_OUT/last_body.md"
assert_argv_contains "multiline" "issue"
assert_argv_contains "multiline" "create"
assert_argv_contains "multiline" "--title"
assert_argv_contains "multiline" "multi-line body"

# Case 5 — gh_pr_create_body_file with a multi-line body too, to cover all wrappers.
body_pr=$'## Summary\n\nA `code` block and $(do not run) and "quoted" text.\n'
printf '%s' "$body_pr" | gh_pr_create_body_file --repo RBOKproject/ORDO --title 'pr-create body' --base main --head feat/x \
  || fail "pr-create: gh_pr_create_body_file returned non-zero"
assert_body_eq "pr-create" "$body_pr" "$GH_MOCK_OUT/last_body.md"
assert_argv_contains "pr-create" "pr"
assert_argv_contains "pr-create" "create"
assert_argv_contains "pr-create" "--base"
assert_argv_contains "pr-create" "main"

printf 'ok - test_gh_body_helpers\n'
