#!/usr/bin/env bash
# scripts/process_safety_preflight.sh - detect runaway processes before dispatch.
#
# Detects classes of process that have historically pinned cores during ORDO
# orchestration sessions:
#   - unbounded filesystem scans (`find /`, `bfs /`)
#   - validators/tests stuck in long background runs (run_shell_tests.sh,
#     run_bats.sh, tests/test_*.sh, bats) above the configurable threshold
#   - very long elapsed bash spawns owned by agent CLIs
#   - stuck validator waits in pane output (`Task Output`, `Monitor(...)`, or
#     foreground until/while polling loops) when explicitly requested
#
# The script is read-only by default. Pass --kill to terminate process
# offenders (SIGTERM, then SIGKILL after a brief grace period). Pass --refuse
# to exit non-zero when offenders are present, so wrapping orchestrators can
# short-circuit dispatch. Pass --detect-stuck-task-output to scan pane captures
# for stale wait primitives, and --nudge to send a bounded generic recovery
# instruction to candidate panes.
#
# Usage:
#   bash scripts/process_safety_preflight.sh
#   bash scripts/process_safety_preflight.sh --kill
#   bash scripts/process_safety_preflight.sh --refuse
#   bash scripts/process_safety_preflight.sh --kill --refuse
#   bash scripts/process_safety_preflight.sh --detect-stuck-task-output
#   bash scripts/process_safety_preflight.sh --detect-stuck-task-output --nudge
#
# Tunables (env):
#   PROC_SAFETY_RUNAWAY_MIN_ETIME_SEC=900   # 15 min etime threshold
#   PROC_SAFETY_RUNAWAY_MIN_PCPU=80         # 80% CPU sustained threshold for scans
#   PROC_SAFETY_PS_TIMEOUT_SEC=3            # bound process snapshot
#   PROC_SAFETY_PATTERNS=                   # additional regex (extends defaults)
#   PROC_SAFETY_STUCK_WAIT_MIN_HITS=3       # consecutive matching captures to report
#   PROC_SAFETY_STUCK_WAIT_STATE_DIR=       # persisted consecutive-hit state
#   PROC_SAFETY_STUCK_WAIT_STATE_TTL_SEC=600
#   PROC_SAFETY_STUCK_WAIT_TMUX_TIMEOUT_SEC=3
#   PROC_SAFETY_STUCK_WAIT_CAPTURE_LINES=80
#   PROC_SAFETY_STUCK_WAIT_CAPTURE_FILE=    # test fixture: one pane capture
#   PROC_SAFETY_STUCK_WAIT_CAPTURE_DIR=     # test fixture: one capture file per pane
#   PROC_SAFETY_STUCK_WAIT_NUDGE_MESSAGE=   # override generic nudge text

set -euo pipefail

DO_KILL=0
DO_REFUSE=0
DO_DETECT_STUCK=0
DO_NUDGE=0
CLEANUP_PATHS=()

# shellcheck disable=SC2317  # invoked by EXIT trap
cleanup() {
  local path
  for path in "${CLEANUP_PATHS[@]}"; do
    rm -rf "$path"
  done
}
trap cleanup EXIT

usage() {
  sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
  case "$arg" in
    --kill) DO_KILL=1 ;;
    --refuse) DO_REFUSE=1 ;;
    --detect-stuck-task-output) DO_DETECT_STUCK=1 ;;
    --nudge)
      DO_NUDGE=1
      DO_DETECT_STUCK=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

ETIME_MIN_SEC=${PROC_SAFETY_RUNAWAY_MIN_ETIME_SEC:-900}
PCPU_MIN=${PROC_SAFETY_RUNAWAY_MIN_PCPU:-80}
PS_TIMEOUT_SEC=${PROC_SAFETY_PS_TIMEOUT_SEC:-3}
STUCK_MIN_HITS=${PROC_SAFETY_STUCK_WAIT_MIN_HITS:-3}
STUCK_STATE_TTL_SEC=${PROC_SAFETY_STUCK_WAIT_STATE_TTL_SEC:-600}
STUCK_TMUX_TIMEOUT_SEC=${PROC_SAFETY_STUCK_WAIT_TMUX_TIMEOUT_SEC:-3}
STUCK_CAPTURE_LINES=${PROC_SAFETY_STUCK_WAIT_CAPTURE_LINES:-80}

[[ "$STUCK_MIN_HITS" =~ ^[0-9]+$ && "$STUCK_MIN_HITS" -ge 1 ]] || STUCK_MIN_HITS=3
[[ "$PS_TIMEOUT_SEC" =~ ^[0-9]+$ && "$PS_TIMEOUT_SEC" -ge 1 ]] || PS_TIMEOUT_SEC=3
[[ "$STUCK_STATE_TTL_SEC" =~ ^[0-9]+$ ]] || STUCK_STATE_TTL_SEC=600
[[ "$STUCK_TMUX_TIMEOUT_SEC" =~ ^[0-9]+$ && "$STUCK_TMUX_TIMEOUT_SEC" -ge 1 ]] \
  || STUCK_TMUX_TIMEOUT_SEC=3
[[ "$STUCK_CAPTURE_LINES" =~ ^[0-9]+$ && "$STUCK_CAPTURE_LINES" -ge 20 ]] \
  || STUCK_CAPTURE_LINES=80

run_bounded() {
  local seconds=${1:?usage: run_bounded <seconds> <command> [args...]}
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

state_root() {
  if [[ -n "${PROC_SAFETY_STUCK_WAIT_STATE_DIR:-}" ]]; then
    printf '%s\n' "$PROC_SAFETY_STUCK_WAIT_STATE_DIR"
  elif [[ -n "${XDG_STATE_HOME:-}" ]]; then
    printf '%s\n' "$XDG_STATE_HOME/ordo/process_safety_preflight/stuck-waits"
  elif [[ -n "${HOME:-}" ]]; then
    printf '%s\n' "$HOME/.local/state/ordo/process_safety_preflight/stuck-waits"
  else
    printf '%s\n' "/tmp/ordo-process-safety-preflight/stuck-waits"
  fi
}

stuck_wait_variant() {
  local capture_file=${1:?usage: stuck_wait_variant <capture-file>}

  if grep -Eq 'Task Output[[:space:]][[:alnum:]_.:-]+' "$capture_file" \
    && grep -Eiq 'Waiting for task' "$capture_file"; then
    printf '%s\n' "task_output_waiting"
    return 0
  fi

  if grep -Eq 'Monitor\([^)]*\)' "$capture_file" \
    && grep -Eiq '(Interrupted|Waiting for task|waiting for|still running|Running)' "$capture_file"; then
    printf '%s\n' "monitor_interrupted_waiting"
    return 0
  fi

  if grep -Eiq '(^|[^[:alnum:]_])(until|while)([^[:alnum:]_]|$)' "$capture_file" \
    && grep -Eiq '(grep|test[[:space:]]+|tail|cat|stat|wc|read[[:space:]])' "$capture_file" \
    && grep -Eiq '(sleep[[:space:]]+[0-9]+|Running|Waiting)' "$capture_file"; then
    printf '%s\n' "polling_without_progress"
    return 0
  fi

  return 1
}

stuck_wait_summary() {
  local capture_file=${1:?usage: stuck_wait_summary <capture-file>}
  awk '
    /Task Output|Waiting for task|Monitor\(|Interrupted|until|while|grep|sleep|Running/ {
      line=$0
      gsub(/^[[:space:]]+/, "", line)
      gsub(/[[:space:]]+$/, "", line)
      if (line != "") {
        out = out (out == "" ? "" : " | ") line
        count++
      }
      if (count >= 4) {
        exit
      }
    }
    END {
      print out
    }
  ' "$capture_file" \
    | tr '\t' ' ' \
    | sed -E \
      -e 's/[0-9]+m[[:space:]]+[0-9]+s/<elapsed>/g' \
      -e 's/[0-9]+s/<elapsed>/g' \
      -e 's/[[:space:]]+/ /g' \
      -e 's/^ //; s/ $//'
}

state_key_for() {
  local target=${1:?usage: state_key_for <target> <variant>}
  local variant=${2:?usage: state_key_for <target> <variant>}
  printf '%s\n' "$target|$variant" | cksum | awk '{print $1}'
}

record_stuck_wait_observation() {
  local target=${1:?usage: record_stuck_wait_observation <target> <variant> <signature>}
  local variant=${2:?usage: record_stuck_wait_observation <target> <variant> <signature>}
  local signature=${3:?usage: record_stuck_wait_observation <target> <variant> <signature>}
  local root key sig_file meta_file now previous_signature old_count old_first old_last
  local count first_seen last_seen

  root=$(state_root)
  mkdir -p "$root" 2>/dev/null || {
    root=$(mktemp -d -t process-safety-stuck.XXXXXX)
    CLEANUP_PATHS+=("$root")
  }

  key=$(state_key_for "$target" "$variant")
  sig_file="$root/$key.sig"
  meta_file="$root/$key.meta"
  now=$(date +%s)
  count=1
  first_seen=$now
  last_seen=$now

  if [[ -r "$sig_file" && -r "$meta_file" ]]; then
    previous_signature=$(cat "$sig_file" 2>/dev/null || true)
    read -r old_count old_first old_last < "$meta_file" || true
    if [[ "${old_count:-}" =~ ^[0-9]+$ \
      && "${old_first:-}" =~ ^[0-9]+$ \
      && "${old_last:-}" =~ ^[0-9]+$ \
      && "$previous_signature" == "$signature" \
      && $((now - old_last)) -le "$STUCK_STATE_TTL_SEC" ]]; then
      count=$((old_count + 1))
      first_seen=$old_first
    fi
  fi

  printf '%s\n' "$signature" > "$sig_file"
  printf '%s %s %s\n' "$count" "$first_seen" "$last_seen" > "$meta_file"
  printf '%s\t%s\n' "$count" "$((now - first_seen))"
}

nudge_stuck_wait() {
  local target=${1:?usage: nudge_stuck_wait <pane-target>}
  local message
  message=${PROC_SAFETY_STUCK_WAIT_NUDGE_MESSAGE:-validator-hang: stop waiting on stale Task Output/Monitor/polling output; kill the watched process if present, report blocker/opportunity_finding, and continue with bounded foreground commands.}

  command -v tmux >/dev/null 2>&1 || return 1
  run_bounded "$STUCK_TMUX_TIMEOUT_SEC" tmux send-keys -t "$target" Escape >/dev/null 2>&1 \
    || return 1
  run_bounded "$STUCK_TMUX_TIMEOUT_SEC" tmux send-keys -t "$target" "$message" >/dev/null 2>&1 \
    || return 1
  sleep 0.2
  run_bounded "$STUCK_TMUX_TIMEOUT_SEC" tmux send-keys -t "$target" Enter >/dev/null 2>&1 \
    || return 1
}

collect_stuck_wait_captures() {
  local out_dir=${1:?usage: collect_stuck_wait_captures <out-dir>}
  local fixture_file fixture_dir source_file target safe_target capture_file panes pane

  fixture_file=${PROC_SAFETY_STUCK_WAIT_CAPTURE_FILE:-}
  fixture_dir=${PROC_SAFETY_STUCK_WAIT_CAPTURE_DIR:-}

  if [[ -n "$fixture_file" ]]; then
    [[ -f "$fixture_file" ]] || return 0
    cp "$fixture_file" "$out_dir/fixture.capture"
    printf '%s\t%s\n' "fixture" "$out_dir/fixture.capture"
    return 0
  fi

  if [[ -n "$fixture_dir" ]]; then
    [[ -d "$fixture_dir" ]] || return 0
    while IFS= read -r source_file; do
      target=$(basename "$source_file")
      safe_target=${target//[^A-Za-z0-9_.-]/_}
      capture_file="$out_dir/$safe_target.capture"
      cp "$source_file" "$capture_file"
      printf '%s\t%s\n' "$target" "$capture_file"
    done < <(find "$fixture_dir" -maxdepth 1 -type f | sort)
    return 0
  fi

  command -v tmux >/dev/null 2>&1 || return 0
  panes=$(run_bounded "$STUCK_TMUX_TIMEOUT_SEC" \
    tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)
  while IFS= read -r pane; do
    [[ -n "$pane" ]] || continue
    safe_target=${pane//[^A-Za-z0-9_.-]/_}
    capture_file="$out_dir/$safe_target.capture"
    if run_bounded "$STUCK_TMUX_TIMEOUT_SEC" \
      tmux capture-pane -t "$pane" -p -S "-$STUCK_CAPTURE_LINES" > "$capture_file" 2>/dev/null; then
      printf '%s\t%s\n' "$pane" "$capture_file"
    fi
  done <<< "$panes"
}

scan_stuck_waits() {
  local candidates_file=${1:?usage: scan_stuck_waits <candidates-file> <observations-file>}
  local observations_file=${2:?usage: scan_stuck_waits <candidates-file> <observations-file>}
  local capture_dir source_list target capture_file variant signature count age summary action

  capture_dir=$(mktemp -d -t process-safety-captures.XXXXXX)
  CLEANUP_PATHS+=("$capture_dir")
  source_list=$(mktemp)
  CLEANUP_PATHS+=("$source_list")
  collect_stuck_wait_captures "$capture_dir" > "$source_list"

  while IFS=$'\t' read -r target capture_file; do
    [[ -n "$target" && -n "$capture_file" && -f "$capture_file" ]] || continue
    variant=$(stuck_wait_variant "$capture_file" || true)
    [[ -n "$variant" ]] || continue
    summary=$(stuck_wait_summary "$capture_file")
    [[ -n "$summary" ]] || summary=$(tail -20 "$capture_file" | cksum | awk '{print "capture_checksum=" $1}')
    signature="$variant|$summary"
    IFS=$'\t' read -r count age < <(record_stuck_wait_observation "$target" "$variant" "$signature")
    action="report"
    if [[ "$count" -ge "$STUCK_MIN_HITS" ]]; then
      if [[ "$DO_NUDGE" -eq 1 ]]; then
        if nudge_stuck_wait "$target"; then
          action="nudged"
        else
          action="nudge-failed"
        fi
      fi
      printf '%s\t%s\t%s\t%ss\t%s\t%s\n' \
        "$target" "$variant" "$count" "$age" "$action" "$summary" >> "$candidates_file"
    else
      printf '%s\t%s\t%s/%s\t%s\n' \
        "$target" "$variant" "$count" "$STUCK_MIN_HITS" "$summary" >> "$observations_file"
    fi
  done < "$source_list"
}

# Patterns are matched against full args. Defaults cover failure modes observed
# during process incidents (filesystem scans + queued validators).
DEFAULT_PATTERNS=(
  'bfs +(-S +[a-z]+ +)?(-regextype +[a-zA-Z-]+ +)?/ '
  'find +/ +'
  'find +~ +-type'
  'bash +scripts/run_shell_tests\\.sh'
  'bash +scripts/run_bats\\.sh'
  'bash +tests/test_[a-zA-Z0-9_]+\\.sh'
  '(^|[^A-Za-z0-9_./-])bats +tests/'
)
EXTRA="${PROC_SAFETY_PATTERNS:-}"
if [[ -n "$EXTRA" ]]; then
  DEFAULT_PATTERNS+=("$EXTRA")
fi

PATTERN_RE=$(IFS='|'; printf '%s' "${DEFAULT_PATTERNS[*]}")

# Snapshot ps once (reduce repeat scans under load).
SNAP=$(mktemp)
CLEANUP_PATHS+=("$SNAP")
PS_UNAVAILABLE=0
if ! run_bounded "$PS_TIMEOUT_SEC" \
  ps -e -o pid=,ppid=,etimes=,pcpu=,args= --no-headers > "$SNAP" 2>/dev/null; then
  PS_UNAVAILABLE=1
fi

OFFENDERS=""
if [[ "$PS_UNAVAILABLE" -eq 0 ]]; then
  OFFENDERS=$(awk -v re="$PATTERN_RE" -v et_min="$ETIME_MIN_SEC" -v cpu_min="$PCPU_MIN" '
{
  pid=$1; ppid=$2; etimes=$3; pcpu=$4;
  $1=$2=$3=$4=""; sub(/^ */,"");
  cmd=$0;
  if (cmd ~ re) {
    # report when long-running OR high CPU OR a known dangerous filesystem-scan pattern
    if (etimes+0 >= et_min+0 || pcpu+0 >= cpu_min+0 || cmd ~ /(bfs|find) +(\/|~) /) {
      printf "%s\t%s\t%ss\t%s%%\t%s\n", pid, ppid, etimes, pcpu, cmd;
    }
  }
}' "$SNAP")
fi

STUCK_CANDIDATES=$(mktemp)
STUCK_OBSERVATIONS=$(mktemp)
CLEANUP_PATHS+=("$STUCK_CANDIDATES" "$STUCK_OBSERVATIONS")
if [[ "$DO_DETECT_STUCK" -eq 1 ]]; then
  scan_stuck_waits "$STUCK_CANDIDATES" "$STUCK_OBSERVATIONS"
fi

FOUND=0

if [[ "$PS_UNAVAILABLE" -eq 1 ]]; then
  echo "process_safety_preflight: ps unavailable or exceeded ${PS_TIMEOUT_SEC}s" >&2
fi

if [[ -n "$OFFENDERS" ]]; then
  FOUND=1
  echo "process_safety_preflight: runaway candidates found"
  printf 'PID\tPPID\tETIME\tCPU%%\tCMD\n'
  echo "$OFFENDERS"
fi

if [[ "$DO_DETECT_STUCK" -eq 1 ]]; then
  if [[ -s "$STUCK_CANDIDATES" ]]; then
    FOUND=1
    echo "process_safety_preflight: stuck wait candidates found"
    printf 'PANE\tVARIANT\tHITS\tAGE\tACTION\tSUMMARY\n'
    cat "$STUCK_CANDIDATES"
  elif [[ -s "$STUCK_OBSERVATIONS" ]]; then
    echo "process_safety_preflight: stuck wait observations below threshold"
    printf 'PANE\tVARIANT\tHITS\tSUMMARY\n'
    cat "$STUCK_OBSERVATIONS"
  fi
fi

if [[ "$FOUND" -eq 0 ]]; then
  if [[ "$DO_DETECT_STUCK" -eq 1 ]]; then
    echo "process_safety_preflight: ok (no runaway candidates above thresholds; no stuck wait candidates above threshold)"
  else
    echo "process_safety_preflight: ok (no runaway candidates above thresholds)"
  fi
fi

if [[ "$DO_KILL" -eq 1 && -n "$OFFENDERS" ]]; then
  PIDS=$(echo "$OFFENDERS" | awk '{print $1}')
  # shellcheck disable=SC2086
  echo "process_safety_preflight: SIGTERM" $PIDS
  # shellcheck disable=SC2086
  kill $PIDS 2>/dev/null || true
  sleep 2
  STILL=$(echo "$PIDS" | xargs -n1 -I{} sh -c 'kill -0 {} 2>/dev/null && echo {}' 2>/dev/null || true)
  if [[ -n "$STILL" ]]; then
    # shellcheck disable=SC2086
    echo "process_safety_preflight: SIGKILL" $STILL
    # shellcheck disable=SC2086
    kill -9 $STILL 2>/dev/null || true
  fi
fi

if [[ "$DO_REFUSE" -eq 1 && "$FOUND" -eq 1 ]]; then
  exit 7
fi

exit 0
