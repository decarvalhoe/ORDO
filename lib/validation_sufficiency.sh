#!/usr/bin/env bash
# lib/validation_sufficiency.sh — classify scope_files by language class
# and verify that a brief's validation_command actually covers each class
# with a class-appropriate linter/typechecker/runner.
#
# Source: issue #724. The 2026-05-16 ORDO dispatch wave shipped briefs
# whose validation_command was `bash -n + 1 targeted shell test`. `bash
# -n` is parser-only; it does not flag SC2034 / SC2128 / SC2178 that
# `scripts/run_shellcheck.sh` would catch. Three follow-up commits per
# PR were spent on lint that the worker could have caught pre-push.
#
# Scope -> required token mapping:
#   *.sh,*.bash       -> shellcheck or run_shellcheck.sh
#   *.py              -> pytest or py_compile
#   *.ts,*.tsx        -> tsc (e.g. --noEmit) or jest
#   *.mjs,*.js,*.jsx  -> eslint, jest, or node --check
#   *.php             -> php -l or phpunit
#
# Tokens are matched case-insensitively as substrings against the
# rendered validation_command so explicit `timeout` wrappers, `bash`
# prefixes, and operator-chosen invocations all continue to satisfy the
# gate without forcing a single canonical phrasing.
#
# This module is pure-bash. It does NOT call GitHub, fetch templates,
# or mutate the project state. It exports classifier + check + augment
# helpers so brief_agents.sh can decide whether to refuse the brief or
# auto-augment validation_command.

if [[ -n "${VALIDATION_SUFFICIENCY_LIB_LOADED:-}" ]]; then
  return 0
fi
VALIDATION_SUFFICIENCY_LIB_LOADED=1

# Canonical, ordered list of language classes the gate understands.
# Tests iterate this so adding a new class only requires extending the
# four arrays below plus a token list, never per-test plumbing.
validation_sufficiency_classes() {
  printf '%s\n' sh py ts js php
}

# Extension(s) -> class. Returns class on stdout, exit 0 if recognized.
validation_sufficiency_class_for_extension() {
  local ext=${1:-}
  ext=${ext,,}
  ext=${ext#.}
  case "$ext" in
    sh|bash) printf '%s\n' sh ;;
    py)      printf '%s\n' py ;;
    ts|tsx)  printf '%s\n' ts ;;
    js|jsx|mjs|cjs) printf '%s\n' js ;;
    php)     printf '%s\n' php ;;
    *)       return 1 ;;
  esac
}

# Tokens that satisfy each class. Matched case-insensitively as
# substrings against the validation_command. Order is irrelevant.
validation_sufficiency_tokens_for_class() {
  local class=${1:?usage: validation_sufficiency_tokens_for_class <class>}
  case "$class" in
    sh)  printf '%s\n' shellcheck run_shellcheck.sh ;;
    py)  printf '%s\n' pytest py_compile ;;
    ts)  printf '%s\n' 'tsc' jest ;;
    js)  printf '%s\n' eslint jest 'node --check' ;;
    php) printf '%s\n' 'php -l' phpunit ;;
    *)   return 1 ;;
  esac
}

# Canonical augment line the auto-augment mode prepends when a class is
# missing. The leading comment is emitted separately by the caller so
# the validation_command stays a single shell-runnable string while
# the audit row records the human-readable scope_class -> added pair.
#
# Augment lines deliberately avoid the heavy-validator runners
# (`bash scripts/run_shellcheck.sh` and friends) because those trip
# dispatch_ticket's heavy-validator refusal when the brief was not
# also marked `require-local-validators: yes`. Calling `shellcheck`
# directly satisfies the sufficiency token without crossing that gate,
# so the augment can land transparently on any dispatch-provided
# brief — the original intent of #724.
#
# The `$(...)` substitutions in py/js/sh augments are intentional: they
# expand on the worker host at validation time, not at brief render
# time, so the disabled SC2016 below is the correct behaviour.
# shellcheck disable=SC2016
validation_sufficiency_augment_for_class() {
  local class=${1:?usage: validation_sufficiency_augment_for_class <class>}
  case "$class" in
    sh)  printf '%s\n' 'shellcheck $(git ls-files "*.sh" "*.bash")' ;;
    py)  printf '%s\n' 'python3 -m py_compile $(git ls-files "*.py")' ;;
    ts)  printf '%s\n' 'npx --yes tsc --noEmit' ;;
    js)  printf '%s\n' 'node --check $(git ls-files "*.js" "*.mjs" "*.cjs" "*.jsx")' ;;
    php) printf '%s\n' 'find . -name "*.php" -not -path "./vendor/*" -print0 | xargs -0 -n1 php -l' ;;
    *)   return 1 ;;
  esac
}

# Strip the common bullet/comment markers (mirrors brief_scope_strip_marker
# in brief_agents.sh). Kept local so this lib is sourceable in isolation.
_validation_sufficiency_strip_marker() {
  local entry=$1
  entry=${entry#"${entry%%[![:space:]]*}"}
  entry=${entry%"${entry##*[![:space:]]}"}
  case "$entry" in
    '- '*|'* '*|'# '*|'// '*)
      entry=${entry#* }
      ;;
  esac
  printf '%s\n' "$entry"
}

# Tokenize scope_files into the set of language classes present. One
# class per line on stdout, deduplicated, in canonical order. Empty
# input -> no output, exit 0.
validation_sufficiency_classify_scope() {
  local raw=${1:-}
  [[ -n "$raw" ]] || return 0

  local -A seen=()
  local line entry base ext class
  while IFS= read -r line || [[ -n "$line" ]]; do
    entry=$(_validation_sufficiency_strip_marker "$line")
    [[ -n "$entry" ]] || continue
    # Reduce to the trailing extension on the last path segment. Globs
    # like `lib/*.sh` and `src/**/*.ts` still carry the same trailing
    # extension and classify correctly.
    base=${entry##*/}
    case "$base" in
      *.*) ext=${base##*.} ;;
      *)   continue ;;
    esac
    # Trim trailing glob/brace clutter from the extension (e.g. `sh}`,
    # `sh]`, `sh*`). We only need the alnum prefix.
    ext=${ext%%[^A-Za-z0-9]*}
    [[ -n "$ext" ]] || continue
    class=$(validation_sufficiency_class_for_extension "$ext") || continue
    seen[$class]=1
  done <<< "$raw"

  local c
  while IFS= read -r c; do
    if [[ -n "${seen[$c]:-}" ]]; then
      printf '%s\n' "$c"
    fi
  done < <(validation_sufficiency_classes)
}

# Does the validation_command contain any token that satisfies the class?
# Returns 0 if yes, 1 if no. Case-insensitive substring match.
validation_sufficiency_command_covers_class() {
  local class=${1:?usage: validation_sufficiency_command_covers_class <class> <validation_command>}
  local command=${2:-}
  [[ -n "$command" ]] || return 1

  local lowered=${command,,}
  local token
  while IFS= read -r token; do
    [[ -n "$token" ]] || continue
    local lowered_token=${token,,}
    case "$lowered" in
      *"$lowered_token"*) return 0 ;;
    esac
  done < <(validation_sufficiency_tokens_for_class "$class")

  return 1
}

# Brief-source-level waiver. Checked against the unrendered source body
# so operators can declare an exception directly in the issue text in
# the same style as `- external-pr-mutations: <scopes>` and
# `- require-local-validators: <yes|no>`. Returns 0 if a waiver is
# present, 1 otherwise. Empty/absent body -> no waiver.
validation_sufficiency_brief_declares_exception() {
  local body=${1:-}
  [[ -n "$body" ]] || return 1
  grep -Eiq '(^|[[:space:]])(-|\*)?[[:space:]]*validation-policy-exception[[:space:]]*:[[:space:]]*[^[:space:]]' <<< "$body"
}

# Emit one `<class>=<status>` line per class present in scope. status is
# `ok` when validation_command covers the class, `missing` otherwise.
# Stdout order matches validation_sufficiency_classes() (sh, py, ts, js,
# php) for stable consumer parsing.
validation_sufficiency_check() {
  local scope_files=${1:-}
  local validation_command=${2:-}
  local class status
  while IFS= read -r class; do
    [[ -n "$class" ]] || continue
    if validation_sufficiency_command_covers_class "$class" "$validation_command"; then
      status=ok
    else
      status=missing
    fi
    printf '%s=%s\n' "$class" "$status"
  done < <(validation_sufficiency_classify_scope "$scope_files")
}

# Prepend canonical invocations for each missing class to
# validation_command. The annotation comment lives on its own line so
# the augmented command remains a valid bash heredoc / `&&` chain when
# brief_agents.sh re-renders it via validation_as_command_line.
#
# Output: augmented multi-line validation block on stdout. Caller pipes
# back into validation_as_command_line / validation_as_focused_check_list
# to refresh the rendered template fields.
validation_sufficiency_augment_command() {
  local scope_files=${1:-}
  local validation_command=${2:-}
  local prepend=""
  local class status added augment

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    class=${line%%=*}
    status=${line##*=}
    [[ "$status" == "missing" ]] || continue
    augment=$(validation_sufficiency_augment_for_class "$class") || continue
    prepend+="# brief_agents: auto-augmented for scope class ${class}"$'\n'
    prepend+="${augment}"$'\n'
    added+="${added:+ }scope_class=${class}=${augment}"
  done < <(validation_sufficiency_check "$scope_files" "$validation_command")

  if [[ -z "$prepend" ]]; then
    printf '%s' "$validation_command"
    return 0
  fi

  if [[ -z "$validation_command" || "$validation_command" == "none" ]]; then
    printf '%s' "$prepend"
  else
    printf '%s%s' "$prepend" "$validation_command"
  fi
}

# Emit the comma-free additions string used in BRIEF_VALIDATION_AUTO_AUGMENTED
# audit rows. Format mirrors the issue example:
#   scope_class=sh added=bash scripts/run_shellcheck.sh
# One line per augmented class.
validation_sufficiency_augment_audit_lines() {
  local scope_files=${1:-}
  local validation_command=${2:-}
  local line class status augment

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    class=${line%%=*}
    status=${line##*=}
    [[ "$status" == "missing" ]] || continue
    augment=$(validation_sufficiency_augment_for_class "$class") || continue
    printf 'scope_class=%s added=%s\n' "$class" "$augment"
  done < <(validation_sufficiency_check "$scope_files" "$validation_command")
}

# Emit the space-separated `<class>=missing` list used in
# BRIEF_VALIDATION_INSUFFICIENT audit rows and stderr blockers.
validation_sufficiency_missing_classes() {
  local scope_files=${1:-}
  local validation_command=${2:-}
  local line class status missing=""

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    class=${line%%=*}
    status=${line##*=}
    [[ "$status" == "missing" ]] || continue
    missing+="${missing:+ }${class}"
  done < <(validation_sufficiency_check "$scope_files" "$validation_command")

  [[ -n "$missing" ]] && printf '%s\n' "$missing"
  return 0
}
