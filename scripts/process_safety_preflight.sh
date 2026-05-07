#!/usr/bin/env bash
# scripts/process_safety_preflight.sh — detect runaway processes before dispatch.
#
# Detects classes of process that have historically pinned cores during ORDO
# orchestration sessions:
#   - unbounded filesystem scans (`find /`, `bfs /`)
#   - validators/tests stuck in long background runs (run_shell_tests.sh,
#     run_bats.sh, tests/test_*.sh, bats) above the configurable threshold
#   - very long elapsed bash spawns owned by Claude Code agents
#
# The script is read-only by default. Pass --kill to terminate offenders
# (SIGTERM, then SIGKILL after a brief grace period). Pass --refuse to exit
# non-zero when offenders are present, so wrapping orchestrators (eg.
# portfolio_session_start.sh, cycle.sh) can short-circuit dispatch.
#
# Usage:
#   bash scripts/process_safety_preflight.sh                 # report only
#   bash scripts/process_safety_preflight.sh --kill          # report + kill
#   bash scripts/process_safety_preflight.sh --refuse        # report + nonzero exit if any
#   bash scripts/process_safety_preflight.sh --kill --refuse # both
#
# Tunables (env):
#   PROC_SAFETY_RUNAWAY_MIN_ETIME_SEC=900   # 15 min etime threshold
#   PROC_SAFETY_RUNAWAY_MIN_PCPU=80         # 80% CPU sustained threshold for scans
#   PROC_SAFETY_PATTERNS=                   # additional regex (extends defaults)

set -euo pipefail

DO_KILL=0
DO_REFUSE=0
for arg in "$@"; do
  case "$arg" in
    --kill) DO_KILL=1 ;;
    --refuse) DO_REFUSE=1 ;;
    -h|--help)
      sed -n '1,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

ETIME_MIN_SEC=${PROC_SAFETY_RUNAWAY_MIN_ETIME_SEC:-900}
PCPU_MIN=${PROC_SAFETY_RUNAWAY_MIN_PCPU:-80}

# Patterns are matched against full args. Defaults cover the failure modes
# observed during the 2026-05-06 incident (bfs scan + queued validators).
DEFAULT_PATTERNS=(
  'bfs +(-S +[a-z]+ +)?(-regextype +[a-zA-Z-]+ +)?/ '
  'find +/ +'
  'find +~ +-type'
  'bash +scripts/run_shell_tests\.sh'
  'bash +scripts/run_bats\.sh'
  'bash +tests/test_[a-zA-Z0-9_]+\.sh'
  '\bbats +tests/'
)
EXTRA="${PROC_SAFETY_PATTERNS:-}"
if [ -n "$EXTRA" ]; then
  DEFAULT_PATTERNS+=("$EXTRA")
fi

PATTERN_RE=$(IFS='|'; printf '%s' "${DEFAULT_PATTERNS[*]}")

# Snapshot ps once (reduce repeat scans under load).
SNAP=$(mktemp)
trap 'rm -f "$SNAP"' EXIT
ps -e -o pid=,ppid=,etimes=,pcpu=,args= --no-headers > "$SNAP" 2>/dev/null || {
  echo "process_safety_preflight: ps unavailable" >&2
  exit 0
}

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

if [ -z "$OFFENDERS" ]; then
  echo "process_safety_preflight: ok (no runaway candidates above thresholds)"
  exit 0
fi

echo "process_safety_preflight: runaway candidates found"
printf 'PID\tPPID\tETIME\tCPU%%\tCMD\n'
echo "$OFFENDERS"

if [ "$DO_KILL" -eq 1 ]; then
  PIDS=$(echo "$OFFENDERS" | awk '{print $1}')
  # shellcheck disable=SC2086
  echo "process_safety_preflight: SIGTERM" $PIDS
  # shellcheck disable=SC2086
  kill $PIDS 2>/dev/null || true
  sleep 2
  STILL=$(echo "$PIDS" | xargs -n1 -I{} sh -c 'kill -0 {} 2>/dev/null && echo {}' 2>/dev/null || true)
  if [ -n "$STILL" ]; then
    # shellcheck disable=SC2086
    echo "process_safety_preflight: SIGKILL" $STILL
    # shellcheck disable=SC2086
    kill -9 $STILL 2>/dev/null || true
  fi
fi

if [ "$DO_REFUSE" -eq 1 ]; then
  exit 7
fi

exit 0
