#!/usr/bin/env bash
# scripts/debug_audit_watchdog.sh — detect stale live debug-audit loop and
# (optionally) relaunch it (#541).
#
# Usage:
#   debug_audit_watchdog.sh <project_short|config_path> \
#       [--log-path PATH] \
#       [--max-age-sec N] \
#       [--process-pattern PATTERN] \
#       [--relaunch-command "CMD"] \
#       [--dry-run]
#
# Decision keywords (echoed on stdout, also embedded in the audit line):
#   fresh                  log mtime within window AND a process matches the
#                          pattern. Watchdog is a no-op.
#   stale_log              log mtime exceeds --max-age-sec but a process
#                          matching the pattern is still running.
#   no_process             log is fresh but no process matches the pattern
#                          (e.g. the loop crashed mid-tick).
#   stale_log_no_process   log is stale AND no process matches — the case
#                          captured by #541.
#   relaunched             the watchdog ran the configured relaunch command
#                          and emitted a `config_path=… project=… previous_pid=…
#                          new_pid=…` record on the next stdout line.
#   refused_sample_config  the active project config points at sample
#                          placeholder topology (e.g. `project-a`); the
#                          watchdog refuses to relaunch anything against
#                          live infrastructure with a placeholder config.

set -euo pipefail

TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# shellcheck source=../lib/dry_run.sh
source "$TK/lib/dry_run.sh"
# shellcheck source=../lib/config_resolver.sh
source "$TK/lib/config_resolver.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

LOG_PATH_ARG=""
MAX_AGE_ARG=""
PROCESS_PATTERN_ARG=""
RELAUNCH_CMD=""
PROJECT_ARG=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --log-path) LOG_PATH_ARG=${2:?missing value for --log-path}; shift 2 ;;
    --log-path=*) LOG_PATH_ARG=${1#--log-path=}; shift ;;
    --max-age-sec) MAX_AGE_ARG=${2:?missing value for --max-age-sec}; shift 2 ;;
    --max-age-sec=*) MAX_AGE_ARG=${1#--max-age-sec=}; shift ;;
    --process-pattern) PROCESS_PATTERN_ARG=${2:?missing value for --process-pattern}; shift 2 ;;
    --process-pattern=*) PROCESS_PATTERN_ARG=${1#--process-pattern=}; shift ;;
    --relaunch-command) RELAUNCH_CMD=${2:?missing value for --relaunch-command}; shift 2 ;;
    --relaunch-command=*) RELAUNCH_CMD=${1#--relaunch-command=}; shift ;;
    -h|--help)
      sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      printf 'debug_audit_watchdog: unknown arg %s\n' "$1" >&2
      exit 2
      ;;
    *)
      if [ -n "$PROJECT_ARG" ]; then
        printf 'debug_audit_watchdog: extra positional arg %s\n' "$1" >&2
        exit 2
      fi
      PROJECT_ARG=$1
      shift
      ;;
  esac
done

PROJECT_ARG=${PROJECT_ARG:?usage: debug_audit_watchdog.sh <project_short|config_path> [flags]}

load_project_config "$PROJECT_ARG"

# shellcheck source=../lib/audit_log.sh
source "$TK/lib/audit_log.sh"
# shellcheck source=../lib/debug_audit_watchdog.sh
source "$TK/lib/debug_audit_watchdog.sh"

CONFIG_PATH_DISPLAY=${ORCH_CONFIG_PATH:-$PROJECT_ARG}

# Fail-fast guard: refuse to operate when the active project config still
# carries example placeholder topology. #541 acceptance: "The loop fails
# fast if it would use sample `project-a` config for live RBOK."
if debug_audit_loop_is_sample_config "${PROJECT:-}" "${GH_REPO:-}"; then
  audit "DEBUG_AUDIT_WATCHDOG decision=refused_sample_config project=${PROJECT:-} gh_repo=${GH_REPO:-} config_path=$CONFIG_PATH_DISPLAY"
  printf 'refused_sample_config\n'
  printf 'debug_audit_watchdog: refusing to operate with sample placeholder config (project=%s gh_repo=%s config_path=%s)\n' \
    "${PROJECT:-}" "${GH_REPO:-}" "$CONFIG_PATH_DISPLAY" >&2
  exit 3
fi

: "${ORCH_DEBUG_AUDIT_STALE_AFTER_SEC:=900}"
max_age=${MAX_AGE_ARG:-$ORCH_DEBUG_AUDIT_STALE_AFTER_SEC}

if ! [[ "$max_age" =~ ^[0-9]+$ ]]; then
  printf 'debug_audit_watchdog: --max-age-sec must be a non-negative integer, got %s\n' "$max_age" >&2
  exit 2
fi

log_path=${LOG_PATH_ARG:-$(debug_audit_log_default_path "$PROJECT")}
process_pattern=${PROCESS_PATTERN_ARG:-${ORCH_DEBUG_AUDIT_PROCESS_PATTERN:-$PROJECT-debug-audit-loop}}

age=$(debug_audit_log_age_sec "$log_path")
prev_pid=$(debug_audit_loop_pid_for_pattern "$process_pattern" || true)

is_stale=0
debug_audit_log_is_stale "$log_path" "$max_age" && is_stale=1

decision="fresh"
reason="log_age_sec=$age max_age_sec=$max_age process_pattern=$process_pattern previous_pid=${prev_pid:-none}"
if [ "$is_stale" = "1" ] && [ -z "$prev_pid" ]; then
  decision="stale_log_no_process"
elif [ "$is_stale" = "1" ]; then
  decision="stale_log"
elif [ -z "$prev_pid" ]; then
  decision="no_process"
fi

audit "DEBUG_AUDIT_WATCHDOG decision=$decision project=$PROJECT config_path=$CONFIG_PATH_DISPLAY log_path=$log_path $reason"

if [ "$decision" = "fresh" ] || [ -z "$RELAUNCH_CMD" ]; then
  printf '%s\n' "$decision"
  exit 0
fi

if dry_run_enabled; then
  record=$(debug_audit_loop_relaunch_record \
    "$CONFIG_PATH_DISPLAY" "$PROJECT" "${prev_pid:-none}" "DRY-RUN")
  audit "DEBUG_AUDIT_WATCHDOG action=would_relaunch reason=$decision $record"
  printf '%s\n' "$decision"
  printf '%s\n' "$record"
  exit 0
fi

log_parent=$(dirname -- "$log_path")
[ -d "$log_parent" ] || mkdir -p "$log_parent" 2>/dev/null || true

# Spawn the relaunch in the background; record the immediate child PID so
# the provenance line carries a useful identifier even if the underlying
# command exec'd into a long-running process (then it stays valid) or
# exited fast (then it documents what was attempted).
nohup bash -c "$RELAUNCH_CMD" >>"$log_path" 2>&1 &
new_pid=$!
disown "$new_pid" 2>/dev/null || true

record=$(debug_audit_loop_relaunch_record \
  "$CONFIG_PATH_DISPLAY" "$PROJECT" "${prev_pid:-none}" "$new_pid")

audit "DEBUG_AUDIT_WATCHDOG action=relaunched reason=$decision $record"
printf 'relaunched\n'
printf '%s\n' "$record"
