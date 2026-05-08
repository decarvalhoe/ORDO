#!/usr/bin/env bash
# scripts/prompt_detector_scan.sh — scan a pane capture (or a fleet's worth
# of panes) for interactive permission prompts and emit structured signals
# (#349). Read-only: never grants permissions, never answers prompts.
#
# Modes:
#   --capture <file>      Scan a capture file. Pass "-" to read stdin.
#   --pane <target>       Capture the named tmux pane in-process. Repeatable.
#   --pane-list <file>    Read pane targets one per line from a file. Pass
#                         "-" to read stdin.
#
# Per-pane metadata (applies to every record from that source unless the
# capture line carries an inline override that the lib detects):
#   --session <name>
#   --pane-id <session:window.pane>   (defaults to --pane when --pane mode)
#   --cwd <path>
#   --agent <label>
#   --project <name>
#   --ticket <id>
#   --linked-issue <number>
#   --linked-pr <number>
#
# Output:
#   --json               One JSON object per line on stdout (default).
#   --persist            Also append every record to the prompt-signals
#                        ledger ($ORCH_STATE_BASE/_prompt_signals/signals.jsonl).
#   --summary            Print a short tab-separated summary on stderr after
#                        scan, useful for orchestrator logs.
#
# Exit codes:
#   0  scan completed (zero or more records emitted).
#   2  invalid args.
#   3  required dependency missing (jq).
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=lib/prompt_detector.sh
source "$TK/lib/prompt_detector.sh"

usage() {
  cat <<'EOF' >&2
usage:
  prompt_detector_scan.sh --capture <file>   [meta...] [--json] [--persist] [--summary]
  prompt_detector_scan.sh --pane <target>... [meta...] [--json] [--persist] [--summary]
  prompt_detector_scan.sh --pane-list <file> [meta...] [--json] [--persist] [--summary]

Meta keys (all optional): --session, --pane-id, --cwd, --agent, --project,
--ticket, --linked-issue, --linked-pr.

Pass "-" to --capture or --pane-list to read from stdin (only one of
--capture / --pane-list may use stdin in a single invocation).
EOF
}

CAPTURE_SOURCE=""
PANE_TARGETS=()
PANE_LIST_SOURCE=""
META_SESSION=""
META_PANE_ID=""
META_CWD=""
META_AGENT=""
META_PROJECT=""
META_TICKET=""
META_LINKED_ISSUE=""
META_LINKED_PR=""
DO_PERSIST=0
DO_SUMMARY=0
FORMAT="json"

if ! command -v jq >/dev/null 2>&1; then
  printf 'prompt_detector_scan.sh: jq is required\n' >&2
  exit 3
fi

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --capture) CAPTURE_SOURCE=${2:?missing value for --capture}; shift 2 ;;
    --capture=*) CAPTURE_SOURCE=${1#--capture=}; shift ;;
    --pane) PANE_TARGETS+=("${2:?missing value for --pane}"); shift 2 ;;
    --pane=*) PANE_TARGETS+=("${1#--pane=}"); shift ;;
    --pane-list) PANE_LIST_SOURCE=${2:?missing value for --pane-list}; shift 2 ;;
    --pane-list=*) PANE_LIST_SOURCE=${1#--pane-list=}; shift ;;
    --session) META_SESSION=${2:?missing value for --session}; shift 2 ;;
    --pane-id) META_PANE_ID=${2:?missing value for --pane-id}; shift 2 ;;
    --cwd) META_CWD=${2:?missing value for --cwd}; shift 2 ;;
    --agent) META_AGENT=${2:?missing value for --agent}; shift 2 ;;
    --project) META_PROJECT=${2:?missing value for --project}; shift 2 ;;
    --ticket) META_TICKET=${2:?missing value for --ticket}; shift 2 ;;
    --linked-issue) META_LINKED_ISSUE=${2:?missing value for --linked-issue}; shift 2 ;;
    --linked-pr) META_LINKED_PR=${2:?missing value for --linked-pr}; shift 2 ;;
    --json) FORMAT="json"; shift ;;
    --persist) DO_PERSIST=1; shift ;;
    --summary) DO_SUMMARY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'prompt_detector_scan.sh: unknown arg: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
done

mode_count=0
[[ -n "$CAPTURE_SOURCE" ]] && mode_count=$((mode_count + 1))
[[ "${#PANE_TARGETS[@]}" -gt 0 ]] && mode_count=$((mode_count + 1))
[[ -n "$PANE_LIST_SOURCE" ]] && mode_count=$((mode_count + 1))

if [[ "$mode_count" -ne 1 ]]; then
  printf 'prompt_detector_scan.sh: exactly one of --capture / --pane / --pane-list is required\n' >&2
  usage
  exit 2
fi

if [[ "$CAPTURE_SOURCE" == "-" && "$PANE_LIST_SOURCE" == "-" ]]; then
  printf 'prompt_detector_scan.sh: only one stdin consumer may be active\n' >&2
  exit 2
fi

read_input() {
  local source=$1
  if [[ "$source" == "-" ]]; then
    cat
  else
    [[ -e "$source" ]] || {
      printf 'prompt_detector_scan.sh: input not found: %s\n' "$source" >&2
      exit 2
    }
    cat -- "$source"
  fi
}

# Build the meta argument list for prompt_detector_scan_text.
build_meta_args() {
  local pane_id=${1:-}
  local args=()
  [[ -n "$META_SESSION" ]] && args+=("session=$META_SESSION")
  if [[ -n "$pane_id" ]]; then
    args+=("pane=$pane_id")
  elif [[ -n "$META_PANE_ID" ]]; then
    args+=("pane=$META_PANE_ID")
  fi
  [[ -n "$META_CWD" ]] && args+=("cwd=$META_CWD")
  [[ -n "$META_AGENT" ]] && args+=("agent=$META_AGENT")
  [[ -n "$META_PROJECT" ]] && args+=("project=$META_PROJECT")
  [[ -n "$META_TICKET" ]] && args+=("ticket=$META_TICKET")
  [[ -n "$META_LINKED_ISSUE" ]] && args+=("linked_issue=$META_LINKED_ISSUE")
  [[ -n "$META_LINKED_PR" ]] && args+=("linked_pr=$META_LINKED_PR")
  printf '%s\n' "${args[@]:-}"
}

CAP_LINES_LIMIT=${PROMPT_DETECTOR_PANE_CAPTURE_LINES:-200}
TMUX_TIMEOUT=${PROMPT_DETECTOR_TMUX_TIMEOUT_SEC:-3}

capture_pane() {
  local target=$1
  if ! command -v tmux >/dev/null 2>&1; then
    printf 'prompt_detector_scan.sh: tmux not available, cannot capture pane=%s\n' "$target" >&2
    return 1
  fi
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TMUX_TIMEOUT" tmux capture-pane -t "$target" -p -S "-${CAP_LINES_LIMIT}" 2>/dev/null
  else
    tmux capture-pane -t "$target" -p -S "-${CAP_LINES_LIMIT}" 2>/dev/null
  fi
}

TOTAL_RECORDS=0

declare -a SUMMARY_ROWS=()

# emit_records: write zero or more JSON records to stdout (one per line),
# bump TOTAL_RECORDS for the summary, and append to the prompt-signals
# ledger when --persist is on.
emit_records() {
  local capture=$1
  local pane_id=${2:-}
  local -a meta_args=()
  while IFS= read -r ma || [[ -n "$ma" ]]; do
    [[ -n "$ma" ]] || continue
    meta_args+=("$ma")
  done < <(build_meta_args "$pane_id")
  local record
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    printf '%s\n' "$record"
    TOTAL_RECORDS=$((TOTAL_RECORDS + 1))
    if [[ "$DO_PERSIST" -eq 1 ]]; then
      prompt_detector_persist "$record"
    fi
  done < <(prompt_detector_scan_text "$capture" "${meta_args[@]:-}")
}

scan_capture_input() {
  local capture
  capture=$(read_input "$CAPTURE_SOURCE")
  local before=$TOTAL_RECORDS
  emit_records "$capture" ""
  if [[ "$DO_SUMMARY" -eq 1 ]]; then
    local count=$((TOTAL_RECORDS - before))
    SUMMARY_ROWS+=("source=capture\trecords=$count")
  fi
}

scan_pane_target() {
  local pane_id=$1
  local capture
  if ! capture=$(capture_pane "$pane_id"); then
    if [[ "$DO_SUMMARY" -eq 1 ]]; then
      SUMMARY_ROWS+=("pane=$pane_id\trecords=0\tstatus=capture-failed")
    fi
    return 0
  fi
  local before=$TOTAL_RECORDS
  emit_records "$capture" "$pane_id"
  if [[ "$DO_SUMMARY" -eq 1 ]]; then
    local count=$((TOTAL_RECORDS - before))
    SUMMARY_ROWS+=("pane=$pane_id\trecords=$count")
  fi
}

if [[ -n "$CAPTURE_SOURCE" ]]; then
  scan_capture_input
elif [[ "${#PANE_TARGETS[@]}" -gt 0 ]]; then
  for target in "${PANE_TARGETS[@]}"; do
    scan_pane_target "$target"
  done
elif [[ -n "$PANE_LIST_SOURCE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [[ -n "$line" ]] || continue
    [[ "$line" == \#* ]] && continue
    scan_pane_target "$line"
  done < <(read_input "$PANE_LIST_SOURCE")
fi

if [[ "$DO_SUMMARY" -eq 1 ]]; then
  printf 'prompt_detector_summary records=%d format=%s persist=%d\n' \
    "$TOTAL_RECORDS" "$FORMAT" "$DO_PERSIST" >&2
  for row in "${SUMMARY_ROWS[@]:-}"; do
    [[ -n "$row" ]] || continue
    printf '%b\n' "$row" >&2
  done
fi
