#!/usr/bin/env bash
# start-ordo-loop.sh -- foreground interactive ORDO launcher template.
#
# Operator-owned live profiles may install this as
# /root/.config/ordo/start-ordo-loop.sh and override the paths below.
# The launcher intentionally does not use exec, tmux run-shell, nohup, setsid,
# or backgrounding: ORDO must be started by the current interactive operator
# session and return control to that same session when the loop exits.

set -euo pipefail

ORDO_SUPERVISOR_ROOT="${ORDO_SUPERVISOR_ROOT:-/root/repos/fleet-000}"
ORDO_FULL_LOOP="${ORDO_FULL_LOOP:-/root/.config/ordo/rbokproject-full-claude-loop.sh}"
ORDO_FULL_CONFIG="${ORDO_FULL_CONFIG:-/root/.config/ordo/rbok-live.config.sh}"
ORDO_FULL_MIN_AGENTS="${ORDO_FULL_MIN_AGENTS:-1}"

if [[ $# -gt 0 ]]; then
  printf 'start-ordo-loop.sh: refused partial launch arguments: %s\n' "$*" >&2
  exit 14
fi

for selector_var in \
  ORDO_AGENT_FILTER \
  ORDO_AGENT_ALLOWLIST \
  ORDO_AGENT_INCLUDE \
  ORDO_AGENT_EXCLUDE \
  ORCH_AGENT_FILTER \
  ORCH_AGENT_ALLOWLIST \
  ORCH_AGENT_INCLUDE \
  ORCH_AGENT_EXCLUDE \
  SMART_POLL_AGENT_FILTER; do
  if [[ -n "${!selector_var:-}" ]]; then
    printf 'start-ordo-loop.sh: refused agent cherry-pick selector %s\n' "$selector_var" >&2
    exit 14
  fi
done

if [[ ! -d "$ORDO_SUPERVISOR_ROOT" ]]; then
  printf 'start-ordo-loop.sh: missing supervisor root: %s\n' "$ORDO_SUPERVISOR_ROOT" >&2
  exit 2
fi

if [[ ! -x "$ORDO_FULL_LOOP" ]]; then
  printf 'start-ordo-loop.sh: missing executable ORDO loop: %s\n' "$ORDO_FULL_LOOP" >&2
  exit 2
fi

if ! [[ "$ORDO_FULL_MIN_AGENTS" =~ ^[0-9]+$ ]]; then
  printf 'start-ordo-loop.sh: ORDO_FULL_MIN_AGENTS must be numeric: %s\n' "$ORDO_FULL_MIN_AGENTS" >&2
  exit 2
fi

if [[ "$ORDO_FULL_MIN_AGENTS" -gt 0 ]]; then
  if [[ ! -f "$ORDO_FULL_CONFIG" ]]; then
    printf 'start-ordo-loop.sh: missing full-fleet config: %s\n' "$ORDO_FULL_CONFIG" >&2
    exit 2
  fi
  full_agent_count=$(
    bash -c '
      set -euo pipefail
      source "$1"
      if declare -p AGENT_PANES >/dev/null 2>&1; then
        declare -p AGENT_PANES | sed -n "s/^declare -[^=]*=//p" >/dev/null
        printf "%s\n" "${#AGENT_PANES[@]}"
      elif declare -p AGENTS >/dev/null 2>&1; then
        printf "%s\n" "${#AGENTS[@]}"
      else
        printf "0\n"
      fi
    ' _ "$ORDO_FULL_CONFIG"
  )
  if [[ "$full_agent_count" -lt "$ORDO_FULL_MIN_AGENTS" ]]; then
    printf 'start-ordo-loop.sh: refused partial fleet config=%s agents=%s min=%s\n' \
      "$ORDO_FULL_CONFIG" "$full_agent_count" "$ORDO_FULL_MIN_AGENTS" >&2
    exit 14
  fi
fi

cd "$ORDO_SUPERVISOR_ROOT"
printf 'TECHNAI fleet-000 full ORDO launching foreground interactive agents=%s min=%s\n' \
  "${full_agent_count:-unknown}" "$ORDO_FULL_MIN_AGENTS"
"$ORDO_FULL_LOOP"
