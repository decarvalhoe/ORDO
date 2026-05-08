#!/usr/bin/env bash
# visual_lane.sh — opt-in visual verification capability probe.
#
# The library answers a single question: "does this host expose a usable GUI
# verification lane right now, and what should the dispatch brief know about
# it?". It is provider-neutral by design: nothing here references a specific
# host, browser, automation tool, or design tool. The well-known names that
# show up as defaults are candidate lists the operator can override.
#
# The lane is OPT-IN. When `ORCH_VISUAL_DISPLAY` is empty or unset, every
# function in this file returns a silent no-op result (`enabled=false` in
# JSON, exit 0 in scripts) so that hosts without a display never spend
# audit/log noise on a feature they do not use. Set `ORCH_VISUAL_DISPLAY`
# to the X display value (e.g. `:20`) — or to a non-empty equivalent value
# on whatever windowing system the operator runs — to opt in.
#
# Public functions (sourced API):
#   visual_lane_enabled
#       Return 0 if the lane is opt-in active, 1 otherwise.
#
#   visual_lane_evidence_dir
#       Echo the configured evidence directory (default
#       $HOME/orch-visual-evidence). Acceptance criterion #5 of #264 says
#       evidence MUST live OUTSIDE active worktrees, so this defaults to
#       a path under $HOME — never $PWD.
#
#   visual_lane_collect [--format json|text]
#       Emit a structured capability report. Always returns 0 so callers
#       can parse the output regardless of readiness.
#
# Configuration (all optional except `ORCH_VISUAL_DISPLAY`):
#   ORCH_VISUAL_DISPLAY            opt-in switch + display value
#   ORCH_VISUAL_XAUTHORITY         X authority file path, if any
#   ORCH_VISUAL_BROWSER            explicit browser command (skips probing)
#   ORCH_VISUAL_BROWSER_CANDIDATES whitespace-separated probe list
#   ORCH_VISUAL_AUTOMATION         explicit automation command
#   ORCH_VISUAL_AUTOMATION_CANDIDATES whitespace-separated probe list
#   ORCH_VISUAL_DESIGN_MCP_HINT    free-form hint string for design MCP
#   ORCH_VISUAL_EVIDENCE_DIR       where screenshots/videos land
#   ORCH_VISUAL_VIEWPORTS          comma-separated `name:WxH` list
#   ORCH_VISUAL_FALLBACK           "headless" | "skip" — what dispatchers do
#                                  when the lane is enabled but not ready
#   ORCH_VISUAL_HOST_EVIDENCE      optional path to a host-capability audit
#                                  file the dispatcher should link from PRs

set -o pipefail

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

_visual_lane_run_with_timeout() {
  local seconds=${1:?usage: _visual_lane_run_with_timeout <seconds> <cmd> [args...]}
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

# ---- public ----

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

# ---- internal probes ----
# Each probe echoes a single line: "<bool>\t<detail>". The boolean is "true"
# or "false". Detail is a free-form string (may be empty). Probes never fail
# the script — they classify host state.

_visual_lane_probe_display() {
  local display=${ORCH_VISUAL_DISPLAY:-}
  local xauth=${ORCH_VISUAL_XAUTHORITY:-}
  local probe=${ORCH_VISUAL_DISPLAY_PROBE:-xdpyinfo}
  if [ -z "$display" ]; then
    printf 'false\t\n'
    return 0
  fi
  if ! command -v "$probe" >/dev/null 2>&1; then
    # Probe absent — we cannot prove the display works, but the operator
    # has explicitly opted in, so report the display value with a hint
    # that we could not actively confirm it. The probe binary name is
    # included so an operator on Wayland (`wlr-randr`, `swaymsg`) sees
    # which command they need to install or override.
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
        "$explicit" --version 2>/dev/null | head -1)
      printf 'true\tname=%s path=%s version=%s\n' "$explicit" "$path" "${version:-unknown}"
      return 0
    fi
    printf 'false\tname=%s probe=not-on-path\n' "$explicit"
    return 0
  fi
  for cmd in $ORCH_VISUAL_BROWSER_CANDIDATES; do
    if path=$(command -v "$cmd" 2>/dev/null); then
      version=$(_visual_lane_run_with_timeout "$ORCH_VISUAL_PROBE_TIMEOUT_SEC" \
        "$cmd" --version 2>/dev/null | head -1)
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
        "$explicit" --version 2>/dev/null | head -1)
      printf 'true\tname=%s path=%s version=%s\n' "$explicit" "$path" "${version:-unknown}"
      return 0
    fi
    printf 'false\tname=%s probe=not-on-path\n' "$explicit"
    return 0
  fi
  # Special case: Playwright is most often invoked via `npx playwright`.
  if command -v npx >/dev/null 2>&1; then
    version=$(_visual_lane_run_with_timeout "$ORCH_VISUAL_PROBE_TIMEOUT_SEC" \
      npx --no-install playwright --version 2>/dev/null | head -1)
    if [ -n "$version" ]; then
      printf 'true\tname=npx-playwright version=%s\n' "$version"
      return 0
    fi
  fi
  for cmd in $ORCH_VISUAL_AUTOMATION_CANDIDATES; do
    if path=$(command -v "$cmd" 2>/dev/null); then
      version=$(_visual_lane_run_with_timeout "$ORCH_VISUAL_PROBE_TIMEOUT_SEC" \
        "$cmd" --version 2>/dev/null | head -1)
      printf 'true\tname=%s path=%s version=%s\n' "$cmd" "$path" "${version:-unknown}"
      return 0
    fi
  done
  printf 'false\tprobe=no-candidate-on-path\n'
}

_visual_lane_evidence_state() {
  local dir
  dir=$(visual_lane_evidence_dir)
  # Guardrail (#264 acceptance #5): the evidence directory MUST be outside
  # any active worktree so screenshots cannot accidentally land in a PR.
  # We treat $PWD as the active worktree heuristic — a dispatch that runs
  # this from a repo will reject evidence paths that resolve under it.
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
  # Minimal JSON string escape — quotes, backslash, control chars to \uXXXX.
  # Input is whatever the caller passes; embedded newlines map to \n. Awk's
  # default record separator splits on \n, so NR > 1 marks "this is record
  # past the first" and we re-emit a literal \n in the JSON output.
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

# ---- emitter ----

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
