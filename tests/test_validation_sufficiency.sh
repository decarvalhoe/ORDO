#!/usr/bin/env bash
# test_validation_sufficiency.sh — unit coverage for lib/validation_sufficiency.sh.
#
# Source: issue #724. The 2026-05-16 ORDO dispatch wave shipped briefs
# whose validation_command was `bash -n` + 1 targeted shell test. That
# combination does not flag SC2034/SC2128/SC2178; PRs #719 and #722
# both accumulated lint follow-ups after push. This test pins the
# pure-bash classifier helpers that brief_agents.sh uses to decide
# whether a brief's validation_command actually covers each scope
# language class, so the regression cannot creep back via a refactor.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)

cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

# shellcheck source=../lib/validation_sufficiency.sh
source "$ROOT/lib/validation_sufficiency.sh"

# --- classify_scope ------------------------------------------------------

classes=$(validation_sufficiency_classify_scope $'- lib/foo.sh\n- src/bar.py\n- ui/baz.tsx\n- mod.mjs\n- legacy.php' | tr '\n' ' ')
[[ "$classes" == "sh py ts js php " ]] \
  || fail "classify_scope should emit sh,py,ts,js,php in canonical order, got: '$classes'"

# Globs should still classify by the trailing extension.
glob_classes=$(validation_sufficiency_classify_scope $'lib/*.sh\nsrc/**/*.py' | tr '\n' ' ')
[[ "$glob_classes" == "sh py " ]] \
  || fail "globs should classify by trailing extension, got: '$glob_classes'"

# Bare names with no recognized extension are ignored.
ignored=$(validation_sufficiency_classify_scope $'Makefile\nREADME\ndocs/foo.md' | tr '\n' ' ')
[[ "$ignored" == "" ]] \
  || fail "non-classifiable scope entries should yield no classes, got: '$ignored'"

# Empty input -> empty output, no error.
empty=$(validation_sufficiency_classify_scope "" || true)
[[ -z "$empty" ]] || fail "empty scope_files should classify to empty"

# Bullet-stripped entries ('- path') and comment markers ('# path') are honored.
bullet_classes=$(validation_sufficiency_classify_scope $'- a.sh\n* b.py\n# c.ts\n// d.js' | tr '\n' ' ')
[[ "$bullet_classes" == "sh py ts js " ]] \
  || fail "bullet-prefixed scope entries should classify, got: '$bullet_classes'"

# --- command_covers_class ------------------------------------------------

validation_sufficiency_command_covers_class sh "timeout 60 bash scripts/run_shellcheck.sh" \
  || fail "sh should be covered by run_shellcheck.sh"
validation_sufficiency_command_covers_class sh "timeout 60 shellcheck file.sh" \
  || fail "sh should be covered by shellcheck token"
validation_sufficiency_command_covers_class sh "timeout 60 SHELLCHECK file.sh" \
  || fail "shellcheck match must be case-insensitive"
! validation_sufficiency_command_covers_class sh "timeout 60 bash -n file.sh" \
  || fail "bash -n alone must NOT satisfy sh class (parser-only, the bug #724 fixes)"

validation_sufficiency_command_covers_class py "pytest -k focused" \
  || fail "pytest should cover py"
validation_sufficiency_command_covers_class py "python3 -m py_compile foo.py" \
  || fail "py_compile should cover py"
! validation_sufficiency_command_covers_class py "python3 foo.py" \
  || fail "running a python script must NOT satisfy py class"

validation_sufficiency_command_covers_class ts "npx tsc --noEmit" \
  || fail "tsc should cover ts"
validation_sufficiency_command_covers_class ts "npx jest" \
  || fail "jest should cover ts"

validation_sufficiency_command_covers_class js "npx eslint src/" \
  || fail "eslint should cover js"
validation_sufficiency_command_covers_class js "node --check src/bar.js" \
  || fail "node --check should cover js"
! validation_sufficiency_command_covers_class js "node src/bar.js" \
  || fail "node without --check must NOT satisfy js class"

validation_sufficiency_command_covers_class php "php -l file.php" \
  || fail "php -l should cover php"
validation_sufficiency_command_covers_class php "vendor/bin/phpunit" \
  || fail "phpunit should cover php"
! validation_sufficiency_command_covers_class php "php file.php" \
  || fail "running php script without -l must NOT satisfy php class"

! validation_sufficiency_command_covers_class sh "" \
  || fail "empty validation_command never covers any class"

# --- check (structured <class>=<status> lines) ---------------------------

mixed_scope=$'- foo.sh\n- bar.py'
check_out=$(validation_sufficiency_check "$mixed_scope" "timeout 60 bash scripts/run_shellcheck.sh")
grep -Fxq "sh=ok" <<< "$check_out" \
  || fail "check should mark sh=ok when shellcheck is present, got: $check_out"
grep -Fxq "py=missing" <<< "$check_out" \
  || fail "check should mark py=missing when no py token, got: $check_out"

clean_out=$(validation_sufficiency_check "- foo.sh" "timeout 60 bash scripts/run_shellcheck.sh")
[[ "$clean_out" == "sh=ok" ]] \
  || fail "fully-covered scope should emit only ok lines, got: $clean_out"

all_missing_out=$(validation_sufficiency_check "- foo.sh" "timeout 60 bash -n foo.sh")
[[ "$all_missing_out" == "sh=missing" ]] \
  || fail "bash -n alone should leave sh class missing, got: $all_missing_out"

# --- missing_classes --------------------------------------------------------

missing=$(validation_sufficiency_missing_classes \
  $'- foo.sh\n- bar.py\n- baz.ts' \
  "timeout 60 bash -n foo.sh")
[[ "$missing" == "sh py ts" ]] \
  || fail "missing_classes should list every missing class space-separated in canonical order, got: '$missing'"

none_missing=$(validation_sufficiency_missing_classes "- foo.sh" "shellcheck foo.sh")
[[ -z "$none_missing" ]] \
  || fail "fully covered scope should emit no missing classes, got: '$none_missing'"

# --- augment_command --------------------------------------------------------

original="timeout 60 bash -n foo.sh"
augmented=$(validation_sufficiency_augment_command "- foo.sh" "$original")
grep -Fq "# brief_agents: auto-augmented for scope class sh" <<< "$augmented" \
  || fail "augment_command must prepend the auto-augmented annotation line, got: $augmented"
grep -Fq "shellcheck" <<< "$augmented" \
  || fail "augment_command must prepend the canonical sh invocation (shellcheck token), got: $augmented"
[[ "$augmented" == *"$original" ]] \
  || fail "augment_command must keep the operator's original validation appended, got: $augmented"

# No augmentation when already covered.
covered_in=$'shellcheck foo.sh'
covered_out=$(validation_sufficiency_augment_command "- foo.sh" "$covered_in")
[[ "$covered_out" == "$covered_in" ]] \
  || fail "augment_command must be a no-op when scope is already covered, got: '$covered_out'"

# Augmentation when validation_command is `none` (or empty) replaces it cleanly.
augmented_none=$(validation_sufficiency_augment_command "- foo.sh" "none")
grep -Fq "shellcheck" <<< "$augmented_none" \
  || fail "augment_command should also handle validation_command=none, got: $augmented_none"
! grep -Fq "none" <<< "$augmented_none" \
  || fail "augment_command must drop the placeholder 'none' when augmenting, got: $augmented_none"

# Multi-class augmentation emits one block per missing class, sh first.
multi_out=$(validation_sufficiency_augment_command \
  $'- foo.sh\n- bar.py' \
  "")
grep -Fq "scope class sh" <<< "$multi_out" \
  || fail "multi-class augment must include sh class annotation"
grep -Fq "scope class py" <<< "$multi_out" \
  || fail "multi-class augment must include py class annotation"

# --- augment_audit_lines ----------------------------------------------------

audit_out=$(validation_sufficiency_augment_audit_lines "- foo.sh" "")
# shellcheck disable=SC2016 # the $(...) inside the literal is the emitted audit-row content, not a shell expansion.
[[ "$audit_out" == 'scope_class=sh added=shellcheck $(git ls-files "*.sh" "*.bash")' ]] \
  || fail "audit lines should mirror the scope_class=<class> added=<cmd> format, got: '$audit_out'"

# --- brief_declares_exception ----------------------------------------------

validation_sufficiency_brief_declares_exception "- validation-policy-exception: documentation-only change" \
  || fail "bullet-form exception declaration must be detected"
validation_sufficiency_brief_declares_exception "  validation-policy-exception: indented form" \
  || fail "indented exception declaration must be detected"
! validation_sufficiency_brief_declares_exception "" \
  || fail "empty body must not declare an exception"
! validation_sufficiency_brief_declares_exception "validation-policy-exception:" \
  || fail "exception declaration without a reason must NOT count as a waiver"
! validation_sufficiency_brief_declares_exception "this brief mentions validation-policy-exception in prose" \
  || fail "prose mention without leading bullet/whitespace structure must NOT count as a waiver"

printf 'ok - lib/validation_sufficiency.sh classifier/check/augment helpers behave per #724 acceptance criteria\n'
