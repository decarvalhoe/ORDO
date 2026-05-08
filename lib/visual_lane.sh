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
: "${ORCH_VISUAL_BROWSER_CANDIDATES:=chromium chromium-browser google-chrome google-chrome-stable firefox firefox-esr}"
: "${ORCH_VISUAL_AUTOMATION_CANDIDATES:=playwright cypress puppeteer webdriver-manager}"
: "${ORCH_VISUAL_VIEWPORTS:=desktop:1280x800,mobile:390x844}"
: "${ORCH_VISUAL_FALLBACK:=skip}"
: "${ORCH_VISUAL_PROBE_TIMEOUT_SEC:=3}"
# `xdpyinfo` is the X-specific reference probe; operators on Wayland or
# other windowing systems point this at the equivalent (`wlr-randr`,
# `swaymsg`, etc.). When the named binary is absent, the lane reports
# `display_probe=unknown` rather than guessing readiness.
: "${ORCH_VISUAL_DISPLAY_PROBE:=xdpyinfo}"

# Default scan scope is intentionally `examples lib scripts` — exactly the
# set PR #319's `tests/docs_layers_optionality.bats` already locks down,
# so this fast guard stays semantically aligned with the existing
# bats-suite gate. Docs are informational and do not get sourced; configs
# and templates may legitimately reference the env names in shipped
# patterns, and operators who want to scan additional surfaces can pass
# `--paths <prefix>...` to scripts/visual_lane_probe.sh.

# ---- opt-in capability probe (issue #264) ----------------------------------
# The functions below answer "does this host expose a usable GUI verification
# lane right now?". They are independent of the leak-guard scanners further
# down. The lane is OPT-IN: when ORCH_VISUAL_DISPLAY is empty/unset every
# function returns a silent no-op result so headless hosts spend no audit
# noise on a feature they do not use.

_visual_lane_run_with_timeout() {
  local seconds=${1:?usage: _visual_lane_run_with_timeout <seconds> <cmd> [args...]}
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

visual_lane_enabled() {
  [ -n "${ORCH_VISUAL_DISPLAY:-}" ]
}

visual_lane_evidence_dir() {
  if [ -n "${ORCH_VISUAL_EVIDENCE_DIR:-}" ]; then
    printf '%s\n' "$ORCH_VISUAL_EVIDENCE_DIR"
    return 0
  fi
  printf '%s\n' "${HOME:-/root}/orch-visual-evidence"
}

_visual_lane_probe_display() {
  local display=${ORCH_VISUAL_DISPLAY:-}
  local xauth=${ORCH_VISUAL_XAUTHORITY:-}
  local probe=${ORCH_VISUAL_DISPLAY_PROBE:-xdpyinfo}
  if [ -z "$display" ]; then
    printf 'false\t\n'
    return 0
  fi
  if ! command -v "$probe" >/dev/null 2>&1; then
    printf 'unknown\tdisplay=%s probe=%s-missing\n' "$display" "$probe"
    return 0
  fi
  if DISPLAY="$display" XAUTHORITY="$xauth" \
      _visual_lane_run_with_timeout "$ORCH_VISUAL_PROBE_TIMEOUT_SEC" \
      "$probe" >/dev/null 2>&1; then
    printf 'true\tdisplay=%s\n' "$display"
  else
    printf 'false\tdisplay=%s probe=%s-failed\n' "$display" "$probe"
  fi
}

_visual_lane_probe_browser() {
  local explicit=${ORCH_VISUAL_BROWSER:-}
  local cmd path version
  if [ -n "$explicit" ]; then
    if path=$(command -v "$explicit" 2>/dev/null); then
      version=$(_visual_lane_run_with_timeout "$ORCH_VISUAL_PROBE_TIMEOUT_SEC" \
        "$explicit" --version 2>/dev/null | head -1 || true)
      printf 'true\tname=%s path=%s version=%s\n' "$explicit" "$path" "${version:-unknown}"
      return 0
    fi
    printf 'false\tname=%s probe=not-on-path\n' "$explicit"
    return 0
  fi
  for cmd in $ORCH_VISUAL_BROWSER_CANDIDATES; do
    if path=$(command -v "$cmd" 2>/dev/null); then
      version=$(_visual_lane_run_with_timeout "$ORCH_VISUAL_PROBE_TIMEOUT_SEC" \
        "$cmd" --version 2>/dev/null | head -1 || true)
      printf 'true\tname=%s path=%s version=%s\n' "$cmd" "$path" "${version:-unknown}"
      return 0
    fi
  done
  printf 'false\tprobe=no-candidate-on-path\n'
}

_visual_lane_probe_automation() {
  local explicit=${ORCH_VISUAL_AUTOMATION:-}
  local cmd path version
  if [ -n "$explicit" ]; then
    if path=$(command -v "$explicit" 2>/dev/null); then
      version=$(_visual_lane_run_with_timeout "$ORCH_VISUAL_PROBE_TIMEOUT_SEC" \
        "$explicit" --version 2>/dev/null | head -1 || true)
      printf 'true\tname=%s path=%s version=%s\n' "$explicit" "$path" "${version:-unknown}"
      return 0
    fi
    printf 'false\tname=%s probe=not-on-path\n' "$explicit"
    return 0
  fi
  if command -v npx >/dev/null 2>&1; then
    version=$(_visual_lane_run_with_timeout "$ORCH_VISUAL_PROBE_TIMEOUT_SEC" \
      npx --no-install playwright --version 2>/dev/null | head -1 || true)
    if [ -n "$version" ]; then
      printf 'true\tname=npx-playwright version=%s\n' "$version"
      return 0
    fi
  fi
  for cmd in $ORCH_VISUAL_AUTOMATION_CANDIDATES; do
    if path=$(command -v "$cmd" 2>/dev/null); then
      version=$(_visual_lane_run_with_timeout "$ORCH_VISUAL_PROBE_TIMEOUT_SEC" \
        "$cmd" --version 2>/dev/null | head -1 || true)
      printf 'true\tname=%s path=%s version=%s\n' "$cmd" "$path" "${version:-unknown}"
      return 0
    fi
  done
  printf 'false\tprobe=no-candidate-on-path\n'
}

_visual_lane_evidence_state() {
  local dir
  dir=$(visual_lane_evidence_dir)
  local in_worktree=false
  case "$dir/" in
    "$PWD"/*) in_worktree=true ;;
  esac
  local writable=false
  if mkdir -p "$dir" 2>/dev/null && [ -w "$dir" ]; then
    writable=true
  fi
  printf '%s\t%s\t%s\n' "$dir" "$writable" "$in_worktree"
}

_visual_lane_json_string() {
  local s=${1:-}
  printf '%s' "$s" | awk '
    BEGIN {
      for (i = 0; i < 32; i++) {
        ctl[sprintf("%c", i)] = sprintf("\\u%04x", i)
      }
    }
    NR > 1 { printf("\\n") }
    {
      out = ""
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c == "\\") { out = out "\\\\" }
        else if (c == "\"") { out = out "\\\"" }
        else if (c in ctl) { out = out ctl[c] }
        else { out = out c }
      }
      printf("%s", out)
    }'
}

_visual_lane_csv_to_json_array() {
  local csv=${1:-}
  local IFS=','
  local item first=true
  printf '['
  for item in $csv; do
    [ -n "$item" ] || continue
    if $first; then
      first=false
    else
      printf ','
    fi
    printf '"%s"' "$(_visual_lane_json_string "$item")"
  done
  printf ']'
}

visual_lane_collect() {
  local format="json"
  while [ $# -gt 0 ]; do
    case "$1" in
      --format) format=${2:?--format requires json|text}; shift 2 ;;
      --format=*) format=${1#--format=}; shift ;;
      --json) format="json"; shift ;;
      --text) format="text"; shift ;;
      *) printf 'visual_lane_collect: unknown arg %s\n' "$1" >&2; return 2 ;;
    esac
  done

  local enabled="false"
  if visual_lane_enabled; then
    enabled="true"
  fi

  if [ "$enabled" = "false" ]; then
    case "$format" in
      json)
        printf '{"lane":"visual","enabled":false,"summary":{},"details":{},"fallback":null,"audit":{"host_evidence":null,"schema_version":1}}\n'
        ;;
      text)
        printf 'visual lane: disabled (set ORCH_VISUAL_DISPLAY to enable)\n'
        ;;
    esac
    return 0
  fi

  local d_ok d_detail
  IFS=$'\t' read -r d_ok d_detail < <(_visual_lane_probe_display)
  local b_ok b_detail
  IFS=$'\t' read -r b_ok b_detail < <(_visual_lane_probe_browser)
  local a_ok a_detail
  IFS=$'\t' read -r a_ok a_detail < <(_visual_lane_probe_automation)
  local e_dir e_writable e_inwt
  IFS=$'\t' read -r e_dir e_writable e_inwt < <(_visual_lane_evidence_state)

  local fallback=${ORCH_VISUAL_FALLBACK:-skip}
  local mcp_hint=${ORCH_VISUAL_DESIGN_MCP_HINT:-}
  local host_evidence=${ORCH_VISUAL_HOST_EVIDENCE:-}

  case "$format" in
    json)
      printf '{'
      printf '"lane":"visual",'
      printf '"enabled":true,'
      printf '"summary":{'
      printf '"display_ready":%s,' "$([ "$d_ok" = "true" ] && echo true || echo false)"
      printf '"browser_ready":%s,' "$b_ok"
      printf '"automation_ready":%s,' "$a_ok"
      printf '"design_mcp_hint":%s,' "$([ -n "$mcp_hint" ] && printf '"%s"' "$(_visual_lane_json_string "$mcp_hint")" || echo null)"
      printf '"evidence_dir_ready":%s' "$e_writable"
      printf '},'
      printf '"details":{'
      printf '"display":"%s",' "$(_visual_lane_json_string "${ORCH_VISUAL_DISPLAY:-}")"
      printf '"display_probe":"%s",' "$(_visual_lane_json_string "$d_ok")"
      printf '"display_detail":"%s",' "$(_visual_lane_json_string "$d_detail")"
      printf '"xauthority":"%s",' "$(_visual_lane_json_string "${ORCH_VISUAL_XAUTHORITY:-}")"
      printf '"browser":"%s",' "$(_visual_lane_json_string "$b_detail")"
      printf '"automation":"%s",' "$(_visual_lane_json_string "$a_detail")"
      printf '"evidence_dir":"%s",' "$(_visual_lane_json_string "$e_dir")"
      printf '"evidence_dir_in_worktree":%s,' "$e_inwt"
      printf '"viewports":%s' "$(_visual_lane_csv_to_json_array "$ORCH_VISUAL_VIEWPORTS")"
      printf '},'
      printf '"fallback":"%s",' "$(_visual_lane_json_string "$fallback")"
      printf '"audit":{"host_evidence":%s,"schema_version":1}' "$([ -n "$host_evidence" ] && printf '"%s"' "$(_visual_lane_json_string "$host_evidence")" || echo null)"
      printf '}\n'
      ;;
    text)
      printf 'visual lane: enabled (fallback when not ready: %s)\n' "$fallback"
      printf '  display:    %s [%s]\n' "${ORCH_VISUAL_DISPLAY:-}" "$d_detail"
      [ -n "${ORCH_VISUAL_XAUTHORITY:-}" ] && printf '  xauthority: %s\n' "$ORCH_VISUAL_XAUTHORITY"
      printf '  browser:    %s\n' "$b_detail"
      printf '  automation: %s\n' "$a_detail"
      [ -n "$mcp_hint" ] && printf '  design MCP: %s\n' "$mcp_hint"
      printf '  evidence:   %s (writable=%s, in_worktree=%s)\n' "$e_dir" "$e_writable" "$e_inwt"
      printf '  viewports:  %s\n' "$ORCH_VISUAL_VIEWPORTS"
      [ -n "$host_evidence" ] && printf '  host audit: %s\n' "$host_evidence"
      ;;
    *)
      printf 'visual_lane_collect: unsupported format %s\n' "$format" >&2
      return 2
      ;;
  esac
  return 0
}

# ---- diff-level leak guard (issue #324) ------------------------------------

visual_lane_leak_patterns() {
  # Mirrors PR #319's `tests/docs_layers_optionality.bats` pattern set: only
  # actual top-level env-assignments / exports are flagged, so legitimate
  # references (comments, `: "${VAR:=…}"` defaults, `local x=$VAR` reads,
  # string literals) in the visual-lane probe library and example agents
  # do not self-trigger when the leak guard scans its own real repo.
  #
  # The visual env-namespace token is assembled at runtime so this source
  # file does not contain the literal token unanchored — keeping the
  # source-splitting trick that test 18 relies on.
  local visual_prefix
  visual_prefix=$(printf 'ORCH%sVISUAL%s' '_' '_')
  printf '^[[:space:]]*(export[[:space:]]+)?%s[A-Z0-9_]*=\n' "$visual_prefix"
  printf '^DISPLAY=\n'
  printf '^XAUTHORITY=\n'
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
