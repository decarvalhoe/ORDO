#!/usr/bin/env bash
# scripts/prompt_unblock_consume.sh — orchestrator-side consumer for the
# universal prompt detector signals (#350; consumes #349's detector).
#
# This CLI is the operator-facing entry point for the consumer library.
# It reads detector signals (from the standard ledger or from stdin),
# applies the configured prompt-unblock policy, writes a lane-state
# JSON-Lines artifact + operator-action TSV queue, and (optionally) hands
# off live-grant cases to the existing `auto_unblock` helper which
# already gates against dangerous patterns.
#
# Default policy: `audit-only`. The CLI never answers a prompt unless
# the operator passes --live-grant AND the policy file explicitly maps
# the (tool, provider) pair to `live-grant`.
#
# Modes (exactly one):
#   --ledger <path>   Consume an existing JSON-Lines ledger.
#   --since-last      Consume only ledger lines newer than the last
#                     consume run (uses a persistent cursor file under
#                     the prompt-signals state dir).
#   --from-stdin      Read JSON-Lines from stdin.
#
# Flags:
#   --policy <path>   Override ORCH_PROMPT_UNBLOCK_POLICY_FILE.
#   --live-grant      Profile-gated opt-in for live-grant action. Without
#                     this flag a `live-grant` policy entry is downgraded
#                     to `needs_operator_permission` so a stale policy
#                     entry cannot answer prompts unattended.
#   --summary         Print a per-lane TSV summary on stderr.
#   --json            Emit lane states as JSON-Lines on stdout (default).
#
# Exit codes:
#   0  consume completed.
#   2  invalid args.
#   3  jq missing.
#   4  policy file unreadable.
#   5  ledger file unreadable.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=../lib/prompt_unblock_policy.sh
source "$TK/lib/prompt_unblock_policy.sh"

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

LEDGER=""
USE_STDIN=0
USE_SINCE_LAST=0
POLICY=""
LIVE_GRANT=0
DO_SUMMARY=0
FORMAT="json"

if ! command -v jq >/dev/null 2>&1; then
  printf 'prompt_unblock_consume: jq required\n' >&2
  exit 3
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ledger) LEDGER=${2:?missing value for --ledger}; shift 2 ;;
    --ledger=*) LEDGER=${1#--ledger=}; shift ;;
    --since-last) USE_SINCE_LAST=1; shift ;;
    --from-stdin) USE_STDIN=1; shift ;;
    --policy) POLICY=${2:?missing value for --policy}; shift 2 ;;
    --policy=*) POLICY=${1#--policy=}; shift ;;
    --live-grant) LIVE_GRANT=1; shift ;;
    --summary) DO_SUMMARY=1; shift ;;
    --json) FORMAT="json"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'prompt_unblock_consume: unknown arg: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
done

mode_count=0
[[ -n "$LEDGER" ]] && mode_count=$((mode_count + 1))
[[ "$USE_STDIN" -eq 1 ]] && mode_count=$((mode_count + 1))
[[ "$USE_SINCE_LAST" -eq 1 ]] && mode_count=$((mode_count + 1))
if [[ "$mode_count" -ne 1 ]]; then
  printf 'prompt_unblock_consume: exactly one of --ledger / --from-stdin / --since-last is required\n' >&2
  usage
  exit 2
fi

if [[ -n "$POLICY" ]]; then
  if [[ ! -r "$POLICY" ]]; then
    printf 'prompt_unblock_consume: policy file unreadable: %s\n' "$POLICY" >&2
    exit 4
  fi
  export ORCH_PROMPT_UNBLOCK_POLICY_FILE="$POLICY"
fi

read_ledger() {
  local path=${1:?usage: read_ledger <path>}
  if [[ ! -r "$path" ]]; then
    printf 'prompt_unblock_consume: ledger file unreadable: %s\n' "$path" >&2
    exit 5
  fi
  cat "$path"
}

cursor_path() {
  local base
  base=$(prompt_unblock_signals_ledger_path)
  printf '%s/consume_cursor\n' "$(dirname "$base")"
}

read_since_last() {
  local ledger cursor last
  ledger=$(prompt_unblock_signals_ledger_path)
  cursor=$(cursor_path)
  if [[ ! -r "$ledger" ]]; then
    printf 'prompt_unblock_consume: ledger file unreadable: %s\n' "$ledger" >&2
    exit 5
  fi
  last=0
  if [[ -s "$cursor" ]]; then
    last=$(<"$cursor")
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
  fi
  local total
  total=$(wc -l < "$ledger" | tr -d ' ')
  if [[ "$last" -ge "$total" ]]; then
    return 0
  fi
  tail -n "+$((last + 1))" "$ledger"
  printf '%s' "$total" > "$cursor"
}

PAYLOAD=""
if [[ -n "$LEDGER" ]]; then
  PAYLOAD=$(read_ledger "$LEDGER")
elif [[ "$USE_SINCE_LAST" -eq 1 ]]; then
  PAYLOAD=$(read_since_last)
else
  PAYLOAD=$(cat)
fi

LIVE_GRANT_ARGS=()
if [[ "$LIVE_GRANT" -eq 1 ]]; then
  LIVE_GRANT_ARGS+=(--live-grant)
fi

OUTPUT=$(prompt_unblock_consume_signals_text "$PAYLOAD" "${LIVE_GRANT_ARGS[@]}" || true)
if [[ "$FORMAT" == json && -n "$OUTPUT" ]]; then
  printf '%s\n' "$OUTPUT"
fi

if [[ "$DO_SUMMARY" -eq 1 ]]; then
  printf '\n# prompt-unblock summary\n' >&2
  printf 'lane_state_count\t%s\n' "${PROMPT_UNBLOCK_LAST_LANE_COUNT:-0}" >&2
  printf 'alerts_emitted\t%s\n' "${PROMPT_UNBLOCK_LAST_ALERT_COUNT:-0}" >&2
  printf 'lane_states_path\t%s\n' "$(prompt_unblock_lane_state_path)" >&2
  printf 'operator_actions_path\t%s\n' "$(prompt_unblock_operator_actions_path)" >&2
fi
