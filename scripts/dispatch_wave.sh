#!/usr/bin/env bash
# scripts/dispatch_wave.sh — ORDO-native wave dispatcher.
#
# Why this exists (#327):
#   When wave dispatch is modeled as multiple parallel interactive Bash tool
#   calls from an orchestrator pane, the host (e.g. an LLM tool harness)
#   can deny or cancel one call and silently cancel the unrelated siblings,
#   leaving the wave undispatched while the operator believes it is
#   running. ORDO must own the transaction semantics: each dispatch
#   invocation runs in process-isolation, every outcome is recorded in a
#   durable ledger, and an individual failure NEVER cancels independent
#   sibling dispatches.
#
# Usage:
#   dispatch_wave.sh <wave-id> <matrix-file>
#       [--dry-run]
#       [--resume]
#       [--child-timeout-sec N]
#       [--all-must-succeed]
#       [--continue-on-error]   (default; explicit form for clarity)
#
# Matrix file (TSV, one entry per line, optional header `#`-prefix):
#
#   <agent>\t<ticket>\t<prompt-file>\t<project-config>[\t<extra-flags>]
#
# Each entry runs `scripts/dispatch_ticket.sh` for the configured project.
# Extra flags (column 5) are forwarded verbatim — typically `--assign`,
# `--require-local-validators`, or `--no-validate`. Lines starting with `#`
# and blank lines are ignored.
#
# Per-entry outcome is appended to the wave ledger at
#   $ORCH_STATE_BASE/_waves/<wave-id>.json
# with shape:
#   {
#     "wave_id": "<id>",
#     "started_at": "<iso8601>",
#     "updated_at": "<iso8601>",
#     "entries": [
#       {
#         "agent": "<agent>",
#         "ticket": "<ticket>",
#         "project_config": "<path>",
#         "status": "dispatched|failed|denied|skipped|dry_run",
#         "exit_code": <int>,
#         "stderr_tail": "<last-N-lines>",
#         "started_at": "<iso8601>",
#         "finished_at": "<iso8601>"
#       }, ...
#     ]
#   }
#
# Exit code:
#   0  — at least one entry dispatched, none of the must-succeed rules fired
#   1  — under --all-must-succeed, any non-dispatched entry triggers exit 1
#   2  — usage / matrix parse error
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/dry_run.sh"
source "$TK/lib/process_safety.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

WAVE_ID=${1:?usage: dispatch_wave.sh <wave-id> <matrix-file> [...flags]}
MATRIX_FILE=${2:?usage: dispatch_wave.sh <wave-id> <matrix-file> [...flags]}
shift 2

[[ -f "$MATRIX_FILE" ]] || { echo "matrix file not found: $MATRIX_FILE" >&2; exit 2; }
[[ "$WAVE_ID" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "invalid wave id: $WAVE_ID (allowed: [A-Za-z0-9._-])" >&2
  exit 2
}

RESUME=0
ALL_MUST_SUCCEED=0
CHILD_TIMEOUT_SEC="${ORCH_DISPATCH_WAVE_CHILD_TIMEOUT_SEC:-180}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --resume) RESUME=1 ;;
    --all-must-succeed) ALL_MUST_SUCCEED=1 ;;
    --continue-on-error) ALL_MUST_SUCCEED=0 ;;
    --child-timeout-sec)
      CHILD_TIMEOUT_SEC=${2:?missing value for --child-timeout-sec}
      shift
      ;;
    --child-timeout-sec=*)
      CHILD_TIMEOUT_SEC=${1#--child-timeout-sec=}
      ;;
    --) shift; break ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
  shift
done

# Bootstrap audit_log.sh against an internal pseudo-project namespace so
# the ledger lives in a per-wave path rather than colliding with project
# state. Each entry will switch PROJECT to the entry's actual project for
# the dispatch_ticket child invocation.
#
# audit_log.sh's transitive config_check.sh requires AGENT_WORKDIR_TEMPLATE
# to be set; the wave dispatcher does NOT resolve agent workdirs itself
# (dispatch_ticket.sh does, per entry), so we set a sentinel placeholder
# that is never used by either audit_log.sh or the wave dispatcher.
: "${ORCH_STATE_BASE:=${XDG_DATA_HOME:-/root/.local/share}/orch-state}"
: "${ORCH_LOG_DIR:=/var/log/orch}"
: "${AGENT_WORKDIR_TEMPLATE:=__wave_dispatcher__}"
export AGENT_WORKDIR_TEMPLATE ORCH_LOG_DIR
PROJECT="_waves" source "$TK/lib/audit_log.sh"
# audit_log.sh's `set -euo pipefail` propagates into our shell after sourcing;
# re-affirm to make the post-source state explicit.
set -euo pipefail
PROJECT="_waves"

# Use a wave-scoped ledger name so multiple waves coexist.
LEDGER_NAME="$WAVE_ID"

# Build the started_at sentinel into the ledger if it is empty / new.
ensure_ledger_started() {
  local target tmp
  target="$(state_dir)/${LEDGER_NAME}.json"
  if [[ ! -s "$target" ]]; then
    tmp="${target}.tmp.$$"
    jq -n \
      --arg wave_id "$WAVE_ID" \
      --arg started_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
      '{wave_id:$wave_id, started_at:$started_at, updated_at:$started_at, entries:[]}' \
      > "$tmp"
    mv "$tmp" "$target"
  fi
}

ledger_path() {
  printf '%s/%s.json' "$(state_dir)" "$LEDGER_NAME"
}

# Skip an entry on --resume if a prior run already recorded it as
# successfully dispatched. Failure / denial entries are NOT skipped — the
# operator can rerun them after fixing the cause.
already_dispatched() {
  local agent=$1 ticket=$2
  local path
  path=$(ledger_path)
  [[ -s "$path" ]] || return 1
  jq -e \
    --arg agent "$agent" \
    --arg ticket "$ticket" \
    '
      (.entries // [])
      | map(select(.agent == $agent and .ticket == $ticket and .status == "dispatched"))
      | length > 0
    ' "$path" >/dev/null 2>&1
}

record_entry() {
  local agent=$1 ticket=$2 project_config=$3 status=$4 exit_code=$5 stderr_tail=$6 started_at=$7
  local finished_at entry
  finished_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  entry=$(jq -nc \
    --arg agent "$agent" \
    --arg ticket "$ticket" \
    --arg project_config "$project_config" \
    --arg status "$status" \
    --argjson exit_code "$exit_code" \
    --arg stderr_tail "$stderr_tail" \
    --arg started_at "$started_at" \
    --arg finished_at "$finished_at" \
    '{
      agent:$agent,
      ticket:$ticket,
      project_config:$project_config,
      status:$status,
      exit_code:$exit_code,
      stderr_tail:$stderr_tail,
      started_at:$started_at,
      finished_at:$finished_at
    }')
  audit_ledger_append "$LEDGER_NAME" "$entry"
}

# Process-isolated dispatch: a failure in this child cannot affect the
# parent loop. We capture stderr to a temp file, exit code to a variable,
# and never propagate `set -e` behavior into the loop body.
dispatch_one() {
  local agent=$1 ticket=$2 prompt=$3 project_config=$4 extra=$5
  local started_at exit_code=0 stderr_tail status
  local stderr_file
  stderr_file=$(mktemp)
  started_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

  if dry_run_enabled; then
    record_entry "$agent" "$ticket" "$project_config" "dry_run" 0 "" "$started_at"
    rm -f "$stderr_file"
    printf 'DRY_RUN  agent=%s ticket=%s prompt=%s\n' "$agent" "$ticket" "$prompt"
    return 0
  fi

  set +e
  # shellcheck disable=SC2086 # $extra is intentionally word-split (forwarded flags)
  orch_run_timeout "$CHILD_TIMEOUT_SEC" bash "$TK/scripts/dispatch_ticket.sh" \
    "$project_config" "$agent" "$ticket" "$prompt" $extra \
    >/dev/null 2>"$stderr_file"
  exit_code=$?
  set -e

  stderr_tail=$(tail -c 2000 "$stderr_file" | tr -d '\000' | tr '\r' ' ')
  rm -f "$stderr_file"

  case "$exit_code" in
    0)
      status="dispatched"
      ;;
    77|78|79)
      # ORCH_DISPATCH_NOT_READY_EXIT_CODE=77,
      # ORCH_HEAVY_VALIDATION_EXIT_CODE=78,
      # ORCH_DISPATCH_NOT_CONSUMED_EXIT_CODE=79.
      # All three are "policy-style" denials — the brief never landed in
      # the agent pane, but the call itself completed deterministically.
      # Record them as denied (NOT failed) so siblings keep dispatching.
      status="denied"
      ;;
    *)
      status="failed"
      ;;
  esac

  record_entry "$agent" "$ticket" "$project_config" "$status" "$exit_code" "$stderr_tail" "$started_at"
  printf '%-9s agent=%s ticket=%s exit=%s\n' "${status^^}" "$agent" "$ticket" "$exit_code"
  return 0
}

audit "DISPATCH_WAVE start wave=$WAVE_ID matrix=$(basename "$MATRIX_FILE") child_timeout=${CHILD_TIMEOUT_SEC}s"
ensure_ledger_started

count_total=0
count_dispatched=0
count_denied=0
count_failed=0
count_skipped=0

# Read matrix line-by-line. Continue past empty / commented lines.
while IFS=$'\t' read -r agent ticket prompt project_config extra; do
  agent=${agent:-}
  case "$agent" in
    ''|\#*) continue ;;
  esac
  ticket=${ticket:-}
  prompt=${prompt:-}
  project_config=${project_config:-}
  extra=${extra:-}

  if [[ -z "$agent" || -z "$ticket" || -z "$prompt" || -z "$project_config" ]]; then
    printf 'MATRIX_ERR row=%s reason=missing_field\n' "${agent:-?}/${ticket:-?}" >&2
    continue
  fi

  count_total=$((count_total + 1))

  if [[ "$RESUME" -eq 1 ]] && already_dispatched "$agent" "$ticket"; then
    count_skipped=$((count_skipped + 1))
    printf 'SKIP     agent=%s ticket=%s reason=resume_already_dispatched\n' "$agent" "$ticket"
    continue
  fi

  dispatch_one "$agent" "$ticket" "$prompt" "$project_config" "$extra"
  # Tally based on the latest ledger entry for this agent/ticket.
  case "$(jq -r --arg a "$agent" --arg t "$ticket" '
    (.entries // []) | map(select(.agent == $a and .ticket == $t)) | last.status // "unknown"
  ' "$(ledger_path)" 2>/dev/null)" in
    dispatched|dry_run) count_dispatched=$((count_dispatched + 1)) ;;
    denied)             count_denied=$((count_denied + 1)) ;;
    failed)             count_failed=$((count_failed + 1)) ;;
  esac
done < "$MATRIX_FILE"

audit "DISPATCH_WAVE end wave=$WAVE_ID total=$count_total dispatched=$count_dispatched denied=$count_denied failed=$count_failed skipped=$count_skipped"

printf '\n=== wave %s summary ===\n' "$WAVE_ID"
printf 'total=%d dispatched=%d denied=%d failed=%d skipped=%d ledger=%s\n' \
  "$count_total" "$count_dispatched" "$count_denied" "$count_failed" "$count_skipped" \
  "$(ledger_path)"

if [[ "$ALL_MUST_SUCCEED" -eq 1 ]] && \
   { [[ "$count_denied" -gt 0 ]] || [[ "$count_failed" -gt 0 ]]; }; then
  exit 1
fi

exit 0
