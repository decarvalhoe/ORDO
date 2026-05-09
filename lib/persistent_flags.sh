#!/usr/bin/env bash
# lib/persistent_flags.sh — detect drift of CLI persistent flags across
# internal worker restarts (issue #411).
#
# Background. Some agent CLIs (notably Claude Code; Codex behaves the same
# way) have an internal "session worker" that the launcher process
# re-spawns on long-running runs or on certain error recoveries. The
# launcher parses CLI flags once at process start. If it does not re-apply
# the originally parsed set to the new worker, persistent operator flags
# such as `--debug-file`, `--mcp-config`, `--allowed-tools`, `--name`, and
# `--append-system-prompt` silently revert to their CLI defaults. Issue
# #411 captured the operator-visible symptom: 8 of 12 fleet panes lost
# their `--debug-file` target after a Claude CLI internal restart, so log
# output stopped landing at the operator-supplied path and started landing
# at the CLI default; log aggregation broke silently.
#
# The fix proper lives in the upstream CLI (it must persist its own
# originally-parsed argv across worker re-spawns). This library is the
# ORDO-side detector that makes the regression observable. It is
# read-only: it parses `/proc/<pid>/cmdline` (the live argv of the
# running process; updated only when the kernel re-execs, never silently
# rewritten) and compares the observed flag value against the
# operator-supplied contract. Operators feed the result to the existing
# `lib/worktree_helpers.sh` launch-contract path
# (`agent_product_switch --hard`) to heal a drifted pane.
#
# Sourcing contract. Self-contained: this file does not depend on any
# other ORDO lib so the detector can run from a host-health hook before
# the project profile is loaded.
#
# Public API:
#   persistent_flags_for_cli <cli>
#       Echo, one per line, the canonical persistent flag set for the
#       named CLI. Returns 0 even when the CLI is unknown (empty list).
#
#   persistent_flags_extract_value <cmdline_file> <flag>
#       Read a NUL-separated cmdline file (e.g. /proc/<pid>/cmdline) and
#       echo the value associated with <flag>. Handles both `--flag value`
#       (separate argv entries) and `--flag=value` (single argv entry).
#       Returns 1 (no stdout) when the flag is absent.
#
#   persistent_flags_drift <cmdline_file> <flag> <expected_value>
#       Return 0 when the live value matches <expected_value>, 1 when it
#       differs (drift), 2 when <flag> is absent from cmdline (the
#       canonical post-restart symptom from #411), and 3 on usage error.
#
# Exit-code policy. Return values are local function status indicators
# only; this library does not introduce any `ORCH_*_EXIT_CODE` variable,
# so the manifest at docs/exit-codes.md does not gain a new row.

set -o pipefail

persistent_flags_for_cli() {
  local cli=${1:?usage: persistent_flags_for_cli <cli>}
  case "$cli" in
    claude)
      printf '%s\n' --name --debug-file --append-system-prompt --mcp-config --allowed-tools
      ;;
    codex)
      printf '%s\n' --name --debug-file
      ;;
    *)
      ;;
  esac
}

persistent_flags_extract_value() {
  local cmdline=${1:?usage: persistent_flags_extract_value <cmdline> <flag>}
  local flag=${2:?usage: persistent_flags_extract_value <cmdline> <flag>}
  [ -r "$cmdline" ] || return 1

  # Read NUL-separated argv into a newline-delimited stream so the loop
  # below can iterate without depending on `mapfile -d ''` (which only
  # exists from bash 4.4 and is missing on a few CI hosts).
  local argv
  argv=$(tr '\0' '\n' < "$cmdline")

  local IFS=$'\n'
  local entry capture=0
  for entry in $argv; do
    if [ "$capture" = "1" ]; then
      printf '%s\n' "$entry"
      return 0
    fi
    case "$entry" in
      "$flag"=*)
        printf '%s\n' "${entry#*=}"
        return 0
        ;;
      "$flag")
        capture=1
        ;;
    esac
  done
  return 1
}

persistent_flags_drift() {
  if [ "$#" -lt 3 ]; then
    printf 'persistent_flags_drift: usage: persistent_flags_drift <cmdline> <flag> <expected>\n' >&2
    return 3
  fi
  local cmdline=$1 flag=$2 expected=$3
  local actual
  if ! actual=$(persistent_flags_extract_value "$cmdline" "$flag"); then
    return 2
  fi
  [ "$actual" = "$expected" ] && return 0
  return 1
}
