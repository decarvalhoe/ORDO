#!/usr/bin/env bash
# audit_log.sh — central audit + state-dir helpers for orch-toolkit.
# Sourced by every script. NEVER run directly.
#
# Functions:
#   audit MSG         — append timestamped line to /var/log/orch/<PROJECT>.log
#                       and echo to stdout. Auto-creates dir.
#   state_dir         — echo per-project state dir
#                       ($XDG_DATA_HOME/orch-state/$PROJECT, default
#                       /root/.local/share/orch-state/$PROJECT). Auto-creates.
#   audit_action ACTION KEY=VAL...
#                     — structured event: 'AUDIT LOG: <ts> <ACTION> k=v k=v'
#   die MSG           — log error + exit 1.
#
# Required env: PROJECT (from sourced config)

set -euo pipefail

: "${PROJECT:?audit_log.sh: PROJECT must be set (source a config first)}"
: "${ORCH_LOG_DIR:=/var/log/orch}"
: "${ORCH_STATE_BASE:=${XDG_DATA_HOME:-/root/.local/share}/orch-state}"

_ORCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config_check.sh
source "$_ORCH_LIB_DIR/config_check.sh"

mkdir -p "$ORCH_LOG_DIR" 2>/dev/null || true

audit() {
  local msg="$*"
  local ts
  ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  local line="AUDIT LOG: $ts $msg"
  printf '%s\n' "$line" | tee -a "$ORCH_LOG_DIR/$PROJECT.log" >&2
}

audit_action() {
  local action=$1; shift
  audit "$action $*"
}

state_dir() {
  local d="$ORCH_STATE_BASE/$PROJECT"
  mkdir -p "$d" 2>/dev/null || true
  printf '%s' "$d"
}

die() {
  audit "FATAL: $*"
  exit 1
}

# Self-test if invoked directly (will fail since we set -u and PROJECT
# isn't set without a config, hence "sourced only" in the docstring).
