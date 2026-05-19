#!/usr/bin/env bash
# lib/portfolio_supervisor.sh — first-class portfolio supervisor surface (#665).
#
# A "portfolio supervisor" is the long-lived loop that drives one ORDO fleet
# (canonically `fleet-000`) across every product in a portfolio. Historically
# fleets ran that loop through an operator-owned wrapper (for example
# `/root/.config/ordo/ordo-full-loop.sh`) and the ORDO control plane had no
# way to see it — `orch_ctl <profile> status` reported `loop: NOT RUNNING`
# even when the supervisor was actively dispatching work, which misled
# operators into double-dispatching or restarting a competing loop.
#
# This helper turns that wrapper into a first-class ORDO runtime via a small
# state directory that the wrapper writes and orch_ctl reads:
#
#   $ORCH_STATE_BASE/_portfolio/supervisor/
#     state.json    one-shot registration record (pid, wrapper, log, model,
#                   reasoning_effort, slot, started_at)
#     paused        sentinel file; exists iff the supervisor is paused
#     last_cycle    epoch seconds, rewritten at every supervisor cycle
#
# All write helpers are idempotent and tolerate a missing $ORCH_STATE_BASE
# (created on demand). Read helpers always succeed: when nothing is
# registered they report `not_registered`; when the registered pid is gone
# they report `stale` instead of pretending the supervisor is alive.

if [[ -n "${PORTFOLIO_SUPERVISOR_LIB_LOADED:-}" ]]; then
  return 0
fi
PORTFOLIO_SUPERVISOR_LIB_LOADED=1

portfolio_supervisor_base_dir() {
  local base
  base="${ORCH_STATE_BASE:-${XDG_DATA_HOME:-/root/.local/share}/orch-state}"
  printf '%s/_portfolio/supervisor\n' "$base"
}

portfolio_supervisor_state_path() {
  printf '%s/state.json\n' "$(portfolio_supervisor_base_dir)"
}

portfolio_supervisor_paused_path() {
  printf '%s/paused\n' "$(portfolio_supervisor_base_dir)"
}

portfolio_supervisor_last_cycle_path() {
  printf '%s/last_cycle\n' "$(portfolio_supervisor_base_dir)"
}

# Atomically write a small JSON object describing the running supervisor.
# Usage:
#   portfolio_supervisor_register \
#     --wrapper /root/.config/ordo/ordo-full-loop.sh \
#     --log /var/log/orch/ordo-full-portfolio-loop.log \
#     [--model claude-opus-4-7] \
#     [--reasoning-effort high] \
#     [--slot fleet-000] \
#     [--pid $$]
#
# The pid defaults to the current shell pid. started_at is captured at call
# time. Existing state.json is replaced atomically so a relaunch never leaves
# a half-written record on disk.
portfolio_supervisor_register() {
  local wrapper="" log="" model="" effort="" slot=""
  local pid=$$
  while (( $# > 0 )); do
    case "$1" in
      --wrapper) wrapper=${2:-}; shift 2 ;;
      --log) log=${2:-}; shift 2 ;;
      --model) model=${2:-}; shift 2 ;;
      --reasoning-effort) effort=${2:-}; shift 2 ;;
      --slot) slot=${2:-}; shift 2 ;;
      --pid) pid=${2:-$$}; shift 2 ;;
      *)
        printf 'portfolio_supervisor_register: unknown arg: %s\n' "$1" >&2
        return 2
        ;;
    esac
  done

  if [[ -z "$wrapper" || -z "$log" ]]; then
    printf 'portfolio_supervisor_register: --wrapper and --log are required\n' >&2
    return 2
  fi
  if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
    printf 'portfolio_supervisor_register: --pid must be numeric (got: %s)\n' "$pid" >&2
    return 2
  fi

  local base started_at state_path tmp
  base=$(portfolio_supervisor_base_dir)
  state_path=$(portfolio_supervisor_state_path)
  started_at=$(date -u +%FT%TZ)
  mkdir -p "$base"
  tmp="$state_path.tmp.$$"

  # Hand-roll the JSON so this helper has no jq dependency at write time.
  # All values are emitted via portfolio_supervisor_json_escape so embedded
  # quotes, backslashes, or control characters cannot break the document.
  {
    printf '{\n'
    printf '  "pid": %s,\n' "$pid"
    printf '  "wrapper": "%s",\n' "$(portfolio_supervisor_json_escape "$wrapper")"
    printf '  "log": "%s",\n' "$(portfolio_supervisor_json_escape "$log")"
    printf '  "model": "%s",\n' "$(portfolio_supervisor_json_escape "$model")"
    printf '  "reasoning_effort": "%s",\n' "$(portfolio_supervisor_json_escape "$effort")"
    printf '  "slot": "%s",\n' "$(portfolio_supervisor_json_escape "$slot")"
    printf '  "started_at": "%s"\n' "$(portfolio_supervisor_json_escape "$started_at")"
    printf '}\n'
  } > "$tmp"
  mv -f "$tmp" "$state_path"
}

portfolio_supervisor_json_escape() {
  local s=${1-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# Update last_cycle to the current epoch (or an override for tests).
portfolio_supervisor_heartbeat() {
  local ts=${1:-$(date -u +%s)}
  local base path tmp
  base=$(portfolio_supervisor_base_dir)
  path=$(portfolio_supervisor_last_cycle_path)
  mkdir -p "$base"
  tmp="$path.tmp.$$"
  printf '%s\n' "$ts" > "$tmp"
  mv -f "$tmp" "$path"
}

portfolio_supervisor_pause() {
  local base path
  base=$(portfolio_supervisor_base_dir)
  path=$(portfolio_supervisor_paused_path)
  mkdir -p "$base"
  : > "$path"
}

portfolio_supervisor_resume() {
  rm -f "$(portfolio_supervisor_paused_path)"
}

portfolio_supervisor_unregister() {
  local base
  base=$(portfolio_supervisor_base_dir)
  [[ -d "$base" ]] || return 0
  rm -f "$base/state.json" "$base/paused" "$base/last_cycle"
}

# Read one field out of state.json without depending on jq. The parser is
# intentionally narrow: it only handles the flat string/number layout we
# emit ourselves. Unknown fields or malformed files return empty + rc=1.
portfolio_supervisor_state_field() {
  local field=${1:?usage: portfolio_supervisor_state_field <name>}
  local state_path line value
  state_path=$(portfolio_supervisor_state_path)
  [[ -s "$state_path" ]] || return 1

  # Accept `"field": "value"` (string) or `"field": value` (number).
  while IFS= read -r line; do
    case "$line" in
      *"\"$field\""*:*)
        # Trim everything up to and including the first colon.
        value=${line#*:}
        # Strip leading spaces and trailing comma.
        value=${value# }
        value=${value%,}
        value=${value%[[:space:]]}
        if [[ "$value" == \"*\" ]]; then
          value=${value#\"}
          value=${value%\"}
          # Reverse the writer-side escapes.
          value=${value//\\\"/\"}
          value=${value//\\n/$'\n'}
          value=${value//\\r/$'\r'}
          value=${value//\\t/$'\t'}
          value=${value//\\\\/\\}
        fi
        printf '%s' "$value"
        return 0
        ;;
    esac
  done < "$state_path"
  return 1
}

# Returns 0 when /proc/<pid> exists and (when wrapper basename is known) the
# process argv still mentions that wrapper. We do NOT trust pid alone — a pid
# can be recycled between supervisor crashes and an unrelated process; the
# argv check keeps us from misreporting an unrelated pid as the supervisor.
portfolio_supervisor_pid_matches() {
  local pid=${1:?usage: portfolio_supervisor_pid_matches <pid> [wrapper-basename]}
  local wrapper_base=${2:-}
  local proc_dir=${ORCH_PROC_DIR:-/proc}
  local arg base

  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ -r "$proc_dir/$pid/cmdline" ]] || return 1

  [[ -n "$wrapper_base" ]] || return 0

  local -a argv
  mapfile -d '' -t argv < "$proc_dir/$pid/cmdline" 2>/dev/null || return 1
  for arg in "${argv[@]}"; do
    base=${arg##*/}
    [[ "$base" == "$wrapper_base" ]] && return 0
  done
  return 1
}

# One-word status used in audit logs and tests: alive | stale | not_registered.
portfolio_supervisor_status_word() {
  local state_path pid wrapper wrapper_base
  state_path=$(portfolio_supervisor_state_path)
  [[ -s "$state_path" ]] || { printf 'not_registered'; return; }

  pid=$(portfolio_supervisor_state_field pid 2>/dev/null || true)
  wrapper=$(portfolio_supervisor_state_field wrapper 2>/dev/null || true)
  wrapper_base=${wrapper##*/}

  if [[ -z "$pid" ]] || ! portfolio_supervisor_pid_matches "$pid" "$wrapper_base"; then
    printf 'stale'
    return
  fi
  printf 'alive'
}

# Render the orch_ctl status block. Caller supplies a format_last_activity
# function name (so we can reuse the elapsed formatter that already lives in
# scripts/orch_ctl.sh). When that function is not defined we fall back to a
# raw ISO timestamp.
#
# Output shape (added below the existing orch_ctl status lines):
#
#   portfolio_supervisor: alive (pid=X) | STALE (registered pid=X not alive) | not registered
#     wrapper:           <path>
#     log:               <path>
#     model:             <name>
#     reasoning_effort:  <effort>
#     slot:              <slot>
#     paused:            true|false
#     last_cycle:        <iso> (<elapsed> ago)
#
# When nothing is registered we still print a one-liner so the operator sees
# the surface and is not silently misled.
portfolio_supervisor_status_block() {
  local formatter=${1:-format_last_activity}
  local state_path word pid wrapper log model effort slot paused last_cycle
  local wrapper_base elapsed_text

  state_path=$(portfolio_supervisor_state_path)
  word=$(portfolio_supervisor_status_word)

  if [[ "$word" == "not_registered" ]]; then
    echo "portfolio_supervisor: not registered"
    return 0
  fi

  pid=$(portfolio_supervisor_state_field pid 2>/dev/null || true)
  wrapper=$(portfolio_supervisor_state_field wrapper 2>/dev/null || true)
  log=$(portfolio_supervisor_state_field log 2>/dev/null || true)
  model=$(portfolio_supervisor_state_field model 2>/dev/null || true)
  effort=$(portfolio_supervisor_state_field reasoning_effort 2>/dev/null || true)
  slot=$(portfolio_supervisor_state_field slot 2>/dev/null || true)
  wrapper_base=${wrapper##*/}

  if [[ -f "$(portfolio_supervisor_paused_path)" ]]; then
    paused=true
  else
    paused=false
  fi

  last_cycle=$(cat "$(portfolio_supervisor_last_cycle_path)" 2>/dev/null || printf '0')
  if [[ -n "$formatter" ]] && declare -F "$formatter" >/dev/null 2>&1; then
    elapsed_text=$("$formatter" "$last_cycle")
  elif [[ "$last_cycle" =~ ^[0-9]+$ ]] && (( last_cycle > 0 )); then
    elapsed_text=$(date -u -d "@$last_cycle" '+%FT%TZ' 2>/dev/null || printf '%s' "$last_cycle")
  else
    elapsed_text=never
  fi

  if [[ "$word" == "stale" ]]; then
    echo "portfolio_supervisor: STALE (registered pid=${pid:-?} not alive)"
  else
    echo "portfolio_supervisor: alive (pid=$pid)"
  fi
  printf '  wrapper:           %s\n' "${wrapper:-unknown}"
  printf '  log:               %s\n' "${log:-unknown}"
  printf '  model:             %s\n' "${model:-unknown}"
  printf '  reasoning_effort:  %s\n' "${effort:-unknown}"
  printf '  slot:              %s\n' "${slot:-unknown}"
  printf '  paused:            %s\n' "$paused"
  printf '  last_cycle:        %s\n' "$elapsed_text"
}
