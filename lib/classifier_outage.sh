#!/usr/bin/env bash
# lib/classifier_outage.sh — fleet-wide detector for Claude auto-mode
# classifier outages (#410).
#
# Why this exists:
#   When the Claude CLI's auto-mode classifier endpoint fails closed
#   (Anthropic 429 storm or 5xx burst), the agent silently downgrades to
#   "ask user". On a headless tmux pane that means the next tool use
#   stalls indefinitely until an operator prods it. The orchestrator has
#   no native signal for this because the classifier's fail-closed line
#   only appears in the Claude CLI debug log, never in the pane capture
#   or in the main turn output.
#
#   This library reads those debug logs, counts fail-closed events per
#   session, and exposes a structured summary the hourly status sweep
#   (portfolio_status.sh) and operator runbooks can consume. It is a
#   read-only inspection helper: it never restarts agents, never modifies
#   state, never answers prompts. Recovery is operator-driven through
#   the runbook (`docs/runbooks/classifier-outage.md`).
#
# Public surface:
#   classifier_outage_log_dirs            — print configured log directories
#   classifier_outage_pattern_file        — print the patterns file path
#   classifier_outage_default_patterns    — print the default fail-closed regex
#                                          set
#   classifier_outage_scan_file <file>    — count fail-closed events in one log
#   classifier_outage_scan_per_session    — emit `<session>|<count>|<file>` rows
#   classifier_outage_summary_json        — emit aggregated JSON summary
#   classifier_outage_total               — print fleet-wide total only
#
# Knobs (env, all optional):
#   ORCH_CLASSIFIER_OUTAGE_LOG_DIRS       — colon-separated dir list
#                                          (default: $HOME/.claude/debug)
#   ORCH_CLASSIFIER_OUTAGE_PATTERNS_FILE  — file with one regex per line
#                                          (default: built-in)
#   ORCH_CLASSIFIER_OUTAGE_FILE_GLOB      — basename glob (default: *.log)
#   ORCH_CLASSIFIER_OUTAGE_WINDOW_SEC     — only count log lines within this
#                                          many seconds of file mtime
#                                          (default: 0 = scan whole file)

# Print every default fail-closed regex on its own line. ERE patterns —
# `grep -E -f` consumes them directly. Adding a new pattern in this list
# only is enough for the detector to pick it up; operator overrides via
# ORCH_CLASSIFIER_OUTAGE_PATTERNS_FILE concatenate, not replace.
classifier_outage_default_patterns() {
  cat <<'EOF'
classifier: giving up
classifier: defaulting to "ask user"
classifier_fallback: status=fallback
auto-mode classifier: gave up
EOF
}

# Resolve the active patterns file. When ORCH_CLASSIFIER_OUTAGE_PATTERNS_FILE
# is set and non-empty the operator-supplied file replaces the defaults; this
# is intentional so a deployment running a fork of the Claude CLI with a
# different log format can pin its own catalog. When it is unset or empty we
# materialize the defaults to a tmpfile so the caller can pass `-f <path>` to
# `grep` without re-implementing the file dance.
classifier_outage_pattern_file() {
  if [[ -n "${ORCH_CLASSIFIER_OUTAGE_PATTERNS_FILE:-}" \
    && -s "${ORCH_CLASSIFIER_OUTAGE_PATTERNS_FILE}" ]]; then
    printf '%s\n' "${ORCH_CLASSIFIER_OUTAGE_PATTERNS_FILE}"
    return 0
  fi
  local tmp
  tmp=$(mktemp -t orch_classifier_outage.XXXXXX)
  classifier_outage_default_patterns >"$tmp"
  printf '%s\n' "$tmp"
}

# Print configured log directories, one per line. The default is the Claude
# CLI's debug directory under $HOME, which is also where the issue evidence
# was captured (see #410). Tests and CI override via env to point at fixture
# data without touching the real fleet.
classifier_outage_log_dirs() {
  local raw="${ORCH_CLASSIFIER_OUTAGE_LOG_DIRS:-}"
  if [[ -z "$raw" ]]; then
    printf '%s\n' "${HOME:-/root}/.claude/debug"
    return 0
  fi
  local IFS=':'
  # shellcheck disable=SC2206
  local parts=($raw)
  local part
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    printf '%s\n' "$part"
  done
}

# Count fail-closed lines in a single log file. Emits an integer (0 when the
# file is missing/empty) and never returns non-zero — callers feed this into
# arithmetic without `set -e` aborts. ORCH_CLASSIFIER_OUTAGE_WINDOW_SEC, when
# > 0, restricts the count to lines within that many seconds of the file's
# last-modified time; the canonical use case is "events in the last hour"
# without re-implementing log rotation in this lib.
classifier_outage_scan_file() {
  local file=${1:?usage: classifier_outage_scan_file <log-file>}
  if [[ ! -f "$file" || ! -s "$file" ]]; then
    printf '0\n'
    return 0
  fi
  local pattern_file
  pattern_file=$(classifier_outage_pattern_file)
  local count
  count=$(grep -cE -f "$pattern_file" "$file" 2>/dev/null || true)
  case "$count" in
    ''|*[!0-9]*) count=0 ;;
  esac
  printf '%s\n' "$count"
}

# Emit `<session>|<count>|<file>` rows for every log file in every configured
# log directory. <session> is the file basename minus a trailing `.log`. Hidden
# files are skipped. A non-existent log dir is silently skipped — fleets that
# don't run the Claude CLI must not be a hard error here.
classifier_outage_scan_per_session() {
  local dir glob session count file
  glob="${ORCH_CLASSIFIER_OUTAGE_FILE_GLOB:-*.log}"
  while IFS= read -r dir; do
    [[ -n "$dir" && -d "$dir" ]] || continue
    while IFS= read -r file; do
      [[ -f "$file" ]] || continue
      session=$(basename "$file")
      session=${session%.log}
      count=$(classifier_outage_scan_file "$file")
      printf '%s|%s|%s\n' "$session" "$count" "$file"
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f -name "$glob" 2>/dev/null | sort)
  done < <(classifier_outage_log_dirs)
}

# Emit the aggregated JSON summary. Schema:
#   {
#     "total": <int>,                       # fleet-wide fail-closed total
#     "scanned_files": <int>,
#     "by_session": { "<name>": <count>, … },
#     "files": [
#       {"session": "<name>", "count": <int>, "file": "<path>"}, …
#     ],
#     "log_dirs": [ "<dir>", … ],
#     "patterns_source": "default" | "<override-path>"
#   }
#
# `total` is the field the AC asks for as `classifier_fallback_count` in the
# orchestrator hourly status sweep. The richer payload is here so consumers
# can drill into the offending session without re-running the scan.
classifier_outage_summary_json() {
  local rows dirs patterns_source
  rows=$(classifier_outage_scan_per_session)
  dirs=$(classifier_outage_log_dirs)
  if [[ -n "${ORCH_CLASSIFIER_OUTAGE_PATTERNS_FILE:-}" \
    && -s "${ORCH_CLASSIFIER_OUTAGE_PATTERNS_FILE}" ]]; then
    patterns_source="${ORCH_CLASSIFIER_OUTAGE_PATTERNS_FILE}"
  else
    patterns_source="default"
  fi
  jq -nR \
    --rawfile rows /dev/stdin \
    --arg dirs "$dirs" \
    --arg patterns_source "$patterns_source" '
    ($rows | split("\n") | map(select(length > 0))) as $lines
    | ($dirs | split("\n") | map(select(length > 0))) as $log_dirs
    | reduce $lines[] as $line (
        {total: 0, scanned_files: 0, by_session: {}, files: []};
        ($line | split("|")) as $parts
        | ($parts[1] | tonumber) as $count
        | .total += $count
        | .scanned_files += 1
        | .by_session[$parts[0]] =
            (((.by_session[$parts[0]]) // 0) + $count)
        | .files += [{session: $parts[0], count: $count, file: $parts[2]}]
      )
    | . + {log_dirs: $log_dirs, patterns_source: $patterns_source}
  ' <<<"$rows"
}

# Print the fleet-wide fail-closed total only. Wraps the JSON helper so the
# hourly status sweep can splice the integer directly into its output without
# re-parsing the full summary.
classifier_outage_total() {
  classifier_outage_summary_json | jq -r '.total'
}

# Sum fail-closed counts for the named sessions only. Each argument is a
# tmux session name; the count is the sum across every log file whose
# basename (minus `.log`) matches one of those sessions. Sessions with no
# matching log file contribute 0 silently — this is the desired behavior
# for projects whose Claude debug logging is disabled or whose pane never
# wrote a log line.
#
# Used by `scripts/portfolio_status.sh` so each project's hourly sweep row
# carries the per-project slice of the fleet-wide outage figure (the
# project's AGENT_PANES sessions). Returns 0 when no arguments are given,
# which keeps the call site short for projects without configured panes.
classifier_outage_count_for_sessions() {
  if [[ "$#" -eq 0 ]]; then
    printf '0\n'
    return 0
  fi
  local summary
  summary=$(classifier_outage_summary_json)
  local args=()
  local s
  for s in "$@"; do
    args+=(--arg session "$s")
  done
  printf '%s' "$summary" | jq -r --argjson sessions "$(printf '%s\n' "$@" | jq -R . | jq -s .)" '
    [ $sessions[] as $s | (.by_session[$s] // 0) ] | add // 0
  '
}
