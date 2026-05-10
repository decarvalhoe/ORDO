#!/usr/bin/env bash
# test_prompt_integrity.sh — covers lib/prompt_integrity.sh, the staged
# prompt corruption detector wired into dispatch_ticket.sh (issue #121).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

# shellcheck source=lib/prompt_integrity.sh
source "$ROOT/lib/prompt_integrity.sh"

ok_prompt="$TEST_TMP/ok.md"
cat > "$ok_prompt" <<'EOF'
## Objectif
Une dispatch brief plausible avec assez de contenu pour passer la
verification de taille. Backticks litterals: `git status` rendus tels
quels, sans execution. Quotes 'simples' et "doubles" ok. Voila une
deuxieme phrase pour atteindre la taille minimum confortablement.
EOF
validate_prompt_integrity "$ok_prompt" || fail "valid prompt should pass"

tiny_prompt="$TEST_TMP/tiny.md"
printf 'too short\n' > "$tiny_prompt"
if validate_prompt_integrity "$tiny_prompt" 2>"$TEST_TMP/err"; then
  fail "tiny prompt should fail"
fi
grep -q "file too small" "$TEST_TMP/err" || fail "expected size error"

# Invalid UTF-8: lone 0xC3 (start byte without continuation).
bad_utf8="$TEST_TMP/badutf8.md"
{
  printf '## Objectif\n\n'
  head -c 300 /dev/zero | tr '\0' 'a'
  printf '\xc3\xc3\xc3 invalid\n'
} > "$bad_utf8"
if validate_prompt_integrity "$bad_utf8" 2>"$TEST_TMP/err"; then
  fail "invalid UTF-8 prompt should fail"
fi
grep -q "invalid UTF-8" "$TEST_TMP/err" || fail "expected UTF-8 error"

# Shell-error contamination — what an unquoted heredoc leaves behind
# when command substitution explodes mid-render.
contaminated="$TEST_TMP/contaminated.md"
{
  printf '## Objectif\n\n'
  head -c 300 /dev/zero | tr '\0' 'a'
  printf '\nbash: foo: command not found\nmore body\n'
} > "$contaminated"
if validate_prompt_integrity "$contaminated" 2>"$TEST_TMP/err"; then
  fail "contaminated prompt should fail"
fi
grep -q "shell-error contamination" "$TEST_TMP/err" || fail "expected shell-error detection"

# Unresolved placeholder — the half-rendered brief case.
unresolved="$TEST_TMP/unresolved.md"
{
  printf '## Objectif\n\n'
  head -c 300 /dev/zero | tr '\0' 'a'
  printf '\nticket {{ticket}} not substituted\n'
} > "$unresolved"
if validate_prompt_integrity "$unresolved" 2>"$TEST_TMP/err"; then
  fail "unresolved placeholder should fail"
fi
grep -q "unresolved template placeholder" "$TEST_TMP/err" \
  || fail "expected placeholder detection"

stripped_literals="$TEST_TMP/stripped-literals.md"
cat > "$stripped_literals" <<'EOF'
## Objectif

This prompt is large enough to pass the byte threshold, but it carries
the stripped-literal grammar produced when a dispatch prompt is rendered
through an unquoted shell heredoc. It still has plausible markdown body
text, so size, UTF-8, shell-error, and unresolved-template checks are not
enough to catch it.

## Tools / sources autorises

- Use , targeted shell tests, and existing prompt validation patterns.
- PR target: .
- No direct push to , no , no admin merge.
- PR body references .
EOF
if validate_prompt_integrity "$stripped_literals" 2>"$TEST_TMP/err"; then
  fail "stripped required literals should fail"
fi
grep -q "stripped required literal" "$TEST_TMP/err" \
  || fail "expected stripped required literal detection"

missing="$TEST_TMP/does-not-exist.md"
if validate_prompt_integrity "$missing" 2>"$TEST_TMP/err"; then
  fail "missing file should fail"
fi
grep -q "file not found" "$TEST_TMP/err" || fail "expected missing-file error"

if ! closeout_output=$(bash "$ROOT/tests/test_dispatch_closeout.sh" 2>&1); then
  printf '%s\n' "$closeout_output" >&2
  fail "dispatch closeout regression should pass"
fi

printf 'ok - prompt_integrity catches truncation, bad utf8, contamination, placeholders\n'
