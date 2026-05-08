#!/usr/bin/env bash
# visual_lane.sh — cheap diff-level guard against visual-lane env leaks.
#
# Purpose
#   The orchestrator-injected visual-verification lane is opt-in by design.
#   Visual-lane env vars (DISPLAY, XAUTHORITY, anything prefixed by the
#   ORDO visual namespace) MUST live in operator-controlled project profiles
#   only — never in shared examples, libs, scripts, templates, docs, or
#   canonical configs — so headless agents stay headless by default.
#
#   PR #319's `tests/docs_layers_optionality.bats` already enforces this at
#   the bats-suite level. Issue #324 noted that a doc/template/script PR
#   could introduce a leak and only discover it late in full CI. This file
#   provides the same pattern check as a fast, repo-rootable function set
#   so a pre-push hook, a workflow step, or `scripts/visual_lane_probe.sh`
#   can catch the leak in seconds — diff-only when invoked with a base ref.
#
# Sourcing contract
#   Self-contained: this file does not depend on audit_log.sh or any other
#   ORDO lib. It can be sourced by tests, CLI tools, or hooks running before
#   a project config is loaded.
#
# Public API
#   visual_lane_leak_patterns
#   visual_lane_default_search_paths
#   visual_lane_scan_paths <root> [<rel-path>...]
#   visual_lane_scan_files <root> <repo-relative-files>...
#   visual_lane_filter_diff_files [<rel-path>...]
#
# Self-detection avoidance
#   The unanchored prefix used by the visual env namespace is assembled at
#   runtime so this source file does not contain the literal token that the
#   guard itself flags. The two anchored line patterns (`^DISPLAY=`,
#   `^XAUTHORITY=`) cannot self-trigger because they require the line to
#   START with the env name, and our pattern strings are quoted assignments
#   inside shell code.

set -o pipefail

: "${VISUAL_LANE_DEFAULT_SEARCH_PATHS:=examples lib scripts}"
: "${VISUAL_LANE_LEAK_EXIT_CODE:=81}"

# Default scan scope is intentionally `examples lib scripts` — exactly the
# set PR #319's `tests/docs_layers_optionality.bats` already locks down,
# so this fast guard stays semantically aligned with the existing
# bats-suite gate. Docs are informational and do not get sourced; configs
# and templates may legitimately reference the env names in shipped
# patterns, and operators who want to scan additional surfaces can pass
# `--paths <prefix>...` to scripts/visual_lane_probe.sh.

visual_lane_leak_patterns() {
  # Assemble the visual env-namespace prefix at runtime to keep the literal
  # token out of this source file. Anchored DISPLAY / XAUTHORITY patterns
  # are line-start regexes and never self-match because the source carries
  # them as quoted strings, not as line-leading assignments.
  local visual_prefix
  visual_prefix=$(printf 'ORCH%sVISUAL%s' '_' '_')
  printf '%s\n' "$visual_prefix" '^DISPLAY=' '^XAUTHORITY='
}

visual_lane_default_search_paths() {
  # Intentional whitespace splitting — the env var holds a single
  # space-delimited string for readability.
  # shellcheck disable=SC2086
  printf '%s\n' $VISUAL_LANE_DEFAULT_SEARCH_PATHS
}

# visual_lane_scan_paths <root> [<rel-path>...]
#   Scan one or more repo-relative directories under <root> for visual-lane
#   leaks. Default search set is VISUAL_LANE_DEFAULT_SEARCH_PATHS. Returns
#   0 on clean, nonzero with file:line offenders on stdout otherwise.
visual_lane_scan_paths() {
  local root=${1:?usage: visual_lane_scan_paths <root> [<rel-path>...]}
  shift
  local -a paths=("$@")
  if [ "${#paths[@]}" -eq 0 ]; then
    while IFS= read -r p; do paths+=("$p"); done < <(visual_lane_default_search_paths)
  fi

  local pattern hit=0
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    local -a abs_paths=()
    local p
    for p in "${paths[@]}"; do
      [ -d "$root/$p" ] || continue
      abs_paths+=("$root/$p")
    done
    [ "${#abs_paths[@]}" -gt 0 ] || continue
    local matches
    matches=$(grep -rEHn "$pattern" "${abs_paths[@]}" 2>/dev/null || true)
    if [ -n "$matches" ]; then
      printf '%s\n' "$matches" \
        | sed "s|^$root/||" \
        | awk -v p="$pattern" '{ printf "%s\tpattern=%s\n", $0, p }'
      hit=1
    fi
  done < <(visual_lane_leak_patterns)
  [ "$hit" -eq 0 ]
}

# visual_lane_filter_diff_files [<rel-prefix>...]
#   Read newline-separated repo-relative paths from stdin and echo only
#   those that fall under one of the visual-lane search prefixes. Default
#   prefix set is VISUAL_LANE_DEFAULT_SEARCH_PATHS.
visual_lane_filter_diff_files() {
  local -a prefixes=("$@")
  if [ "${#prefixes[@]}" -eq 0 ]; then
    while IFS= read -r p; do prefixes+=("$p"); done < <(visual_lane_default_search_paths)
  fi

  local f prefix
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    for prefix in "${prefixes[@]}"; do
      case "$f" in
        "$prefix"/*) printf '%s\n' "$f"; break ;;
      esac
    done
  done
}

# visual_lane_scan_files <root> <repo-relative-files>...
#   Scan a specific list of repo-relative files (e.g. from
#   `git diff --name-only`) under <root>. Files that don't exist or are
#   not regular files are skipped. Returns 0 on clean.
visual_lane_scan_files() {
  local root=${1:?usage: visual_lane_scan_files <root> <files>...}
  shift
  [ "$#" -gt 0 ] || return 0

  local -a abs_files=()
  local f
  for f in "$@"; do
    [ -f "$root/$f" ] || continue
    abs_files+=("$root/$f")
  done
  [ "${#abs_files[@]}" -gt 0 ] || return 0

  local pattern hit=0
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    local matches
    matches=$(grep -EHn "$pattern" "${abs_files[@]}" 2>/dev/null || true)
    if [ -n "$matches" ]; then
      printf '%s\n' "$matches" \
        | sed "s|^$root/||" \
        | awk -v p="$pattern" '{ printf "%s\tpattern=%s\n", $0, p }'
      hit=1
    fi
  done < <(visual_lane_leak_patterns)
  [ "$hit" -eq 0 ]
}
