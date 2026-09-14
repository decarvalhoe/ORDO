#!/usr/bin/env bash
# lib/ordo_scheduler.sh — durable scheduler: leases, heartbeats, retries,
# timeouts, cancellation, crash recovery and enforced budgets (#810, epic #806).
#
# The scheduler is a state machine folded over the journal (lib/ordo_journal.sh).
# Every change is a journal event validated against the run transition table
# of lib/ordo_contracts.sh; nothing here writes a table directly. Runs move
# through queued, leased, running, waiting, blocked, approval_required,
# succeeded, failed, cancelled, expired. A run in a human-wait state
# (waiting / blocked / approval_required) holds NO lease and NO worker slot.
# Missing or unknown readiness data never becomes "ready" (fail-closed).
#
# This module is the substrate: it decides who may run, for how long and with
# which budget. Drain / merge decisions stay in #788; approvals are decided by
# #812 (which calls ordo_scheduler_require_approval / resume / fail).
#
# Public API (functions prefixed ordo_scheduler_):
#   ordo_scheduler_enqueue [--run-id ID] [--title T] [--ticket REF] [--priority N]
#       [--budget JSON] [--metadata JSON] [--depends-on a,b] [--readiness JSON]
#       [--not-before TS] [--expires-at TS] [--max-retries N]
#       [--runtime-target T] [--text-file F] [--actor JSON]      # run.created -> queued
#   ordo_scheduler_tick [--max-picks N] [--actor JSON]            # one scheduling pass, JSON report
#   ordo_scheduler_heartbeat <run_id> [--usage JSON] [--actor JSON]   # renew lease, report usage, enforce budgets
#   ordo_scheduler_report_usage <run_id> <usage-json> [--actor JSON]  # run.budget usage without renewing
#   ordo_scheduler_wait <run_id> [--reason R] [--deadline TS]     # running -> waiting (lease released)
#   ordo_scheduler_block <run_id> [--reason R] [--type T]         # running -> blocked  (lease released, blocker raised)
#   ordo_scheduler_require_approval <run_id> [--action A] [--reason R] [--deadline TS]
#                                                                 # running -> approval_required (lease released)
#   ordo_scheduler_resume <run_id> [--requeue] [--reason R]       # waiting|blocked|approval_required -> running (re-lease) | queued
#   ordo_scheduler_complete <run_id> [--result JSON]              # running -> succeeded
#   ordo_scheduler_fail <run_id> [--reason R]                     # running|waiting|blocked|approval_required -> failed
#   ordo_scheduler_cancel <run_id> [--reason R]                   # any non-terminal -> cancelled (lease released)
#   ordo_scheduler_recover                                        # rebuild projections, reconcile dead owners
#   ordo_scheduler_status [run_id]                                # JSON summary
#   ordo_scheduler_ready <run_id>                                 # readiness verdict (0 ready / 3 fail-closed)
#   ordo_scheduler_budgets <run_id>                               # budget verdict   (0 ok / 7 exhausted)
#   ordo_scheduler_backoff_seconds <retries>                      # pure backoff schedule
#   ordo_scheduler_owner                                          # this worker's lease owner id
#   ordo_scheduler_runtime <op> [args]                            # indirection to ordo_runtime (no-op when fake/absent)
#
# Knobs (all optional, defaults below): ORDO_SCHED_MAX_FANOUT, ORDO_SCHED_LEASE_TTL,
# ORDO_SCHED_HEARTBEAT_SEC, ORDO_SCHED_RUN_TIMEOUT_SEC, ORDO_SCHED_TIMEOUT_POLICY,
# ORDO_SCHED_LEASE_EXPIRY_POLICY, ORDO_SCHED_MAX_RETRIES, ORDO_SCHED_BACKOFF_BASE_SEC,
# ORDO_SCHED_BACKOFF_MAX_SEC, ORDO_SCHED_JITTER, ORDO_SCHED_QUEUE_TTL_SEC,
# ORDO_SCHED_WAIT_TIMEOUT_SEC, ORDO_SCHED_REQUIRE_READINESS, ORDO_SCHED_BUDGET_MAX_*,
# ORDO_SCHED_WORKER_ID, ORDO_SCHED_WORKER_PID, ORDO_SCHED_HOST. The clock is
# ordo_journal_now (ORDO_JOURNAL_NOW pins it for tests).
#
# Errors: ONE JSON line on stderr {"error":{"code","message","module":"scheduler","details"}}
# and the contract exit code: 2 usage, 3 fail_closed (not ready), 4 not_found,
# 5 invalid_state/invalid_transition, 7 budget_exhausted, 8 lease_lost.
# Full reference: docs/architecture/scheduler.md.
#
# Process budget (#817): a tick reads the journal once (ordo_journal_tick_view)
# and every state change of one run is written in ONE journal transaction
# (ordo_journal_batch: lease op + events), so a step costs one or two python3
# processes instead of one per journal call; jq runs are collapsed likewise.

if [[ -n "${ORDO_SCHEDULER_LIB_LOADED:-}" ]]; then
  return 0
fi
ORDO_SCHEDULER_LIB_LOADED=1

_ORDO_SCHEDULER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F ordo_journal_append >/dev/null 2>&1; then
  # shellcheck source=lib/ordo_journal.sh
  source "$_ORDO_SCHEDULER_LIB_DIR/ordo_journal.sh"
fi

ORDO_SCHEDULER_MODULE="scheduler"
: "${ORDO_SCHED_MAX_FANOUT:=2}"
: "${ORDO_SCHED_LEASE_TTL:=300}"
: "${ORDO_SCHED_HEARTBEAT_SEC:=60}"
: "${ORDO_SCHED_RUN_TIMEOUT_SEC:=3600}"
: "${ORDO_SCHED_TIMEOUT_POLICY:=requeue}"        # requeue | fail
: "${ORDO_SCHED_LEASE_EXPIRY_POLICY:=requeue}"   # requeue | fail
: "${ORDO_SCHED_MAX_RETRIES:=3}"                 # -> budget.max_attempts = retries + 1
: "${ORDO_SCHED_BACKOFF_BASE_SEC:=30}"
: "${ORDO_SCHED_BACKOFF_MAX_SEC:=1800}"
: "${ORDO_SCHED_JITTER:=1}"                      # 0 = deterministic schedule
: "${ORDO_SCHED_QUEUE_TTL_SEC:=0}"               # 0 = queued runs never expire
: "${ORDO_SCHED_WAIT_TIMEOUT_SEC:=0}"            # 0 = human waits never expire
: "${ORDO_SCHED_REQUIRE_READINESS:=0}"           # 1 = every pick needs metadata.readiness.state == ready
: "${ORDO_SCHED_BUDGET_MAX_TURNS:=200}"
: "${ORDO_SCHED_BUDGET_MAX_TOOL_CALLS:=2000}"
: "${ORDO_SCHED_BUDGET_MAX_SECONDS:=14400}"
: "${ORDO_SCHED_BUDGET_MAX_TOKENS:=5000000}"
: "${ORDO_SCHED_BUDGET_MAX_COST:=0}"             # per-run cost units; 0 = unlimited
: "${ORDO_SCHED_DEFAULT_PRIORITY:=100}"          # lower = picked first
: "${ORDO_SCHED_WORKER_ID:=worker}"
: "${ORDO_SCHED_WORKER_PID:=$$}"
: "${ORDO_SCHED_HOST:=}"

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------
_ordo_sched_fail() {
  ordo_contracts_error "$ORDO_SCHEDULER_MODULE" "$@"
}

_ordo_sched_audit() {
  if declare -F audit >/dev/null 2>&1; then
    audit "SCHEDULER $*"
  fi
}

_ordo_sched_default_actor() {
  printf '{"type":"system","id":"ordo_scheduler"}'
}

_ordo_sched_host() {
  local host="${ORDO_SCHED_HOST:-}"
  if [[ -z "$host" ]]; then
    host=$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'localhost')
  fi
  printf '%s\n' "${host//[@:[:space:]]/_}"
}

# Lease owner id: <worker>@<host>:<pid>. host+pid let recover check liveness.
ordo_scheduler_owner() {
  printf '%s@%s:%s\n' "${ORDO_SCHED_WORKER_ID//[@:[:space:]]/_}" "$(_ordo_sched_host)" "$ORDO_SCHED_WORKER_PID"
}

_ordo_sched_epoch() {
  # RFC3339 UTC -> epoch seconds (in bash for canonical input, GNU date otherwise).
  if _ordo_journal_epoch_var "${1:?}"; then
    printf '%s' "$_OJ_EPOCH"
    return 0
  fi
  date -u -d "${1:?}" +%s 2>/dev/null || printf '0'
}

_ordo_sched_ts() {
  _ordo_journal_rfc3339_var "${1:?}"
  printf '%s\n' "$_OJ_TS"
}

_ordo_sched_add() {
  # <rfc3339> <seconds> -> rfc3339
  _ordo_sched_ts "$(( $(_ordo_sched_epoch "$1") + $2 ))"
}

_ordo_sched_is_int() {
  [[ "${1-}" =~ ^[0-9]+$ ]]
}

_ordo_sched_json_arg() {
  # <json|-|@path> -> compact JSON; 5 invalid_json otherwise.
  local raw out
  if ! raw=$(_ordo_contracts_read_json_arg "${1-}"); then
    _ordo_sched_fail not_found "cannot read JSON input: ${1-}" "$(jq -cn --arg input "${1-}" '{"input": $input}')"
    return $?
  fi
  if ! out=$(printf '%s' "$raw" | jq -c . 2>/dev/null) || [[ -z "$out" ]]; then
    _ordo_sched_fail invalid_json "argument is not valid JSON" "$(jq -cn --arg input "${1-}" '{"input": ($input | .[0:200])}')"
    return $?
  fi
  printf '%s' "$out"
}

_ordo_sched_require_run_id() {
  if [[ ! "${1-}" =~ ^run_[0-9a-f]{24}$ ]]; then
    _ordo_sched_fail bad_argument "run_id must be a canonical run id (run_<24 hex>): '${1-}'" \
      "$(jq -cn --arg run_id "${1-}" '{"run_id": $run_id}')"
    return $?
  fi
}

# Common option parser. Sets _OS_* globals; unknown options are usage errors.
_ordo_sched_parse_opts() {
  _OS_ACTOR="" _OS_REASON="" _OS_USAGE="" _OS_RESULT="" _OS_TYPE="" _OS_ACTION="" _OS_DEADLINE="" \
  _OS_REQUEUE=0 _OS_MAX_PICKS="" _OS_RUN_ID="" _OS_TITLE="" _OS_TICKET="" _OS_PRIORITY="" _OS_BUDGET="" \
  _OS_METADATA="" _OS_DEPENDS="" _OS_READINESS="" _OS_NOT_BEFORE="" _OS_EXPIRES_AT="" _OS_MAX_RETRIES="" \
  _OS_RT_TARGET="" _OS_TEXT_FILE=""
  local fn="$1"; shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --actor) _OS_ACTOR="${2-}"; shift 2 ;;
      --reason) _OS_REASON="${2-}"; shift 2 ;;
      --usage) _OS_USAGE="${2-}"; shift 2 ;;
      --result) _OS_RESULT="${2-}"; shift 2 ;;
      --type) _OS_TYPE="${2-}"; shift 2 ;;
      --action) _OS_ACTION="${2-}"; shift 2 ;;
      --deadline) _OS_DEADLINE="${2-}"; shift 2 ;;
      --requeue) _OS_REQUEUE=1; shift ;;
      --max-picks) _OS_MAX_PICKS="${2-}"; shift 2 ;;
      --run-id) _OS_RUN_ID="${2-}"; shift 2 ;;
      --title) _OS_TITLE="${2-}"; shift 2 ;;
      --ticket) _OS_TICKET="${2-}"; shift 2 ;;
      --priority) _OS_PRIORITY="${2-}"; shift 2 ;;
      --budget) _OS_BUDGET="${2-}"; shift 2 ;;
      --metadata) _OS_METADATA="${2-}"; shift 2 ;;
      --depends-on) _OS_DEPENDS="${2-}"; shift 2 ;;
      --readiness) _OS_READINESS="${2-}"; shift 2 ;;
      --not-before) _OS_NOT_BEFORE="${2-}"; shift 2 ;;
      --expires-at) _OS_EXPIRES_AT="${2-}"; shift 2 ;;
      --max-retries) _OS_MAX_RETRIES="${2-}"; shift 2 ;;
      --runtime-target) _OS_RT_TARGET="${2-}"; shift 2 ;;
      --text-file) _OS_TEXT_FILE="${2-}"; shift 2 ;;
      *)
        _ordo_sched_fail usage "unknown option for ${fn}: ${1}" "$(jq -cn --arg opt "$1" '{"option": $opt}')"
        return $?
        ;;
    esac
  done
  local v
  for v in "$_OS_PRIORITY" "$_OS_MAX_PICKS" "$_OS_MAX_RETRIES"; do
    if [[ -n "$v" ]] && ! _ordo_sched_is_int "$v"; then
      _ordo_sched_fail bad_argument "expected a non-negative integer, got '${v}'" "$(jq -cn --arg v "$v" '{"value": $v}')"
      return $?
    fi
  done
  if [[ -z "$_OS_ACTOR" ]]; then
    _OS_ACTOR_JSON=$(_ordo_sched_default_actor)
  else
    _OS_ACTOR_JSON=$(_ordo_sched_json_arg "$_OS_ACTOR") || return $?
  fi
}

# _ordo_sched_snap <run_id> -> snapshot JSON (4 not_found under this module)
_ordo_sched_snap() {
  local run_id="$1" out rc=0
  # stdout and stderr are both single JSON lines: captured together, told
  # apart by their first key (a snapshot starts with "approval", an error
  # with "error"), so no temp file is needed.
  out=$(ordo_journal_project "$run_id" 2>&1) || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    if [[ "$out" == *'{"error":{"code":"not_found",'* ]]; then
      _ordo_sched_fail not_found "unknown run ${run_id}" "$(jq -cn --arg run_id "$run_id" '{"run_id": $run_id}')"
      return $?
    fi
    printf '%s\n' "$out" >&2
    return "$rc"
  fi
  printf '%s' "$out"
}

# _ordo_sched_live_lease <snapshot> -> lease JSON when the mirrored lease is
# active/renewed and not past expiry; empty otherwise.
_ordo_sched_live_lease() {
  local now
  now=$(ordo_journal_now)
  printf '%s' "$1" | jq -c --arg now "$now" '
    .lease // empty
    | select((.state == "acquired" or .state == "active" or .state == "renewed") and ((.expires_at // "") > $now))'
}

# _ordo_sched_release_lease <lease_id> — best effort: released, or expired when
# already stale; a lost/released lease is not an error for the caller.
_ordo_sched_release_lease() {
  local lease_id="$1" rc=0
  [[ -n "$lease_id" && "$lease_id" != "null" ]] || return 0
  ordo_journal_lease_release "$lease_id" --actor "$_OS_ACTOR_JSON" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0|5) return 0 ;;
    8) ordo_journal_lease_expire_stale --actor "$_OS_ACTOR_JSON" >/dev/null 2>&1 || true; return 0 ;;
    *) return "$rc" ;;
  esac
}

# _ordo_sched_check <run_id> <from> <to>
# Validates the transition against the contracts table (5 invalid_transition
# under this module, with the allowed targets). No process on success.
_ordo_sched_check() {
  local run_id="$1" from="$2" to="$3" err rc=0
  err=$(ordo_contracts_transition run "$from" "$to" 2>&1 >/dev/null) || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    local details
    details=$(printf '%s' "$err" | jq -c '.error.details // {}' 2>/dev/null || printf '{}')
    _ordo_sched_fail invalid_transition "run ${run_id}: transition ${from} -> ${to} is not allowed" \
      "$(printf '%s' "$details" | jq -c --arg run_id "$run_id" '. + {"run_id": $run_id}')"
    return $?
  fi
}

# _ordo_sched_emit <run_id> <from> <to> <type> <payload-json>
# Transition check + one appended event.
_ordo_sched_emit() {
  local run_id="$1" from="$2" to="$3" type="$4" payload="$5"
  _ordo_sched_check "$run_id" "$from" "$to" || return $?
  _ordo_journal_append_compact "$run_id" "$type" "$payload" "$_OS_ACTOR_JSON" >/dev/null
}

# Batch op builders (compact JSON fragments for ordo_journal_batch; run and
# lease ids are canonical ids, payloads compact jq output).
_ordo_sched_op_append() {   # <run_id> <type> <payload-json>
  printf '{"op":"append","run_id":"%s","type":"%s","payload":%s}' "$1" "$2" "$3"
}
_ordo_sched_op_release() {  # <lease_id> -> best-effort release (skipped when not live, expired when stale)
  printf '{"op":"lease_release","lease_id":"%s","lenient":true}' "$1"
}
_ordo_sched_op_acquire() {  # <run_id> <owner> <lease_id>
  printf '{"op":"lease_acquire","run_id":"%s","owner":%s,"id":"%s","ttl":%s}' "$1" "$(_ordo_journal_json_string "$2")" "$3" "$ORDO_SCHED_LEASE_TTL"
}
# _ordo_sched_batch <op-json>... -> runs them in ONE transaction; prints the batch result.
_ordo_sched_batch() {
  local ops
  ops=$(IFS=,; printf '[%s]' "$*")   # IFS scoped to the subshell (callees word-split on IFS)
  _ordo_journal_batch_ops object "$ops" "$_OS_ACTOR_JSON"
}

# _ordo_sched_snap_fields <snapshot> [now]: one jq run fills the _SF_* facts
# every command reads from a snapshot (empty string when absent; _SF_LEASE
# is the live lease JSON or empty, like _ordo_sched_live_lease).
_ordo_sched_snap_fields() {
  local now="${2:-}"
  [[ -n "$now" ]] || now=$(ordo_journal_now)
  # The tick loads a candidate once and calls the pick on the same snapshot:
  # a repeated load of the very same document is skipped.
  if [[ "${_SF_DOC-}" == "$1" && "${_SF_NOW-}" == "$now" ]]; then
    return 0
  fi
  _SF_DOC="$1" _SF_NOW="$now"
  local -a f
  mapfile -t f < <(printf '%s' "$1" | jq -r --arg now "$now" '
    .run_id, .state, (.terminal | tostring), (.metadata.blocker_id // ""),
    ((.budgets.attempts_used // 0) | tostring),
    (.metadata.runtime.target // ""), (.metadata.runtime.text_file // ""),
    (.metadata.active_since // .metadata.attempt_started_at // ""),
    (.metadata.heartbeat_at // .metadata.active_since // ""),
    (.metadata.heartbeat_at // .metadata.active_since // .metadata.attempt_started_at // ""),
    (.metadata.expires_at // ""), (.metadata.wait_deadline // ""), (.metadata.not_before // ""),
    (((.lease // null) | if . != null and (.state == "acquired" or .state == "active" or .state == "renewed") and ((.expires_at // "") > $now)
                         then . else null end) as $live
     | ($live | tojson), ($live.id // ""), ($live.owner // "")),
    ((.metadata.priority // 0) | tojson)')
  _SF_RUN_ID="${f[0]-}" _SF_STATE="${f[1]-}" _SF_TERMINAL="${f[2]-}" _SF_BLOCKER_ID="${f[3]-}" _SF_ATTEMPTS="${f[4]-0}"
  _SF_TARGET="${f[5]-}" _SF_TEXT_FILE="${f[6]-}" _SF_STARTED="${f[7]-}" _SF_HB_TICK="${f[8]-}" _SF_HB_LAST="${f[9]-}"
  _SF_EXPIRES="${f[10]-}" _SF_DEADLINE="${f[11]-}" _SF_NOT_BEFORE="${f[12]-}" _SF_LEASE="${f[13]-null}"
  _SF_LEASE_ID="${f[14]-}" _SF_LEASE_OWNER="${f[15]-}" _SF_PRIORITY="${f[16]-0}"
  if [[ "$_SF_LEASE" == null ]]; then _SF_LEASE=""; fi
  return 0
}

# _ordo_sched_join <var> [json...]: sets <var> to the JSON array of the given
# compact JSON documents (no process).
_ordo_sched_join() {
  local __name="$1"
  shift
  local IFS=,
  printf -v "$__name" '[%s]' "$*"
}

# _ordo_sched_exhausted <verdict-json> -> 0 when .exhausted is not empty
_ordo_sched_exhausted() {
  [[ "$1" != *'"exhausted":[]}' ]]
}

# ---------------------------------------------------------------------------
# Runtime indirection (adapters are #811; never a hard dependency here)
# ---------------------------------------------------------------------------
ordo_scheduler_runtime() {
  local op="${1:?usage: ordo_scheduler_runtime <op> [args]}"
  shift
  if [[ "${ORDO_RUNTIME_ADAPTER:-}" == "fake" || ! -f "$_ORDO_SCHEDULER_LIB_DIR/ordo_runtime_adapter.sh" ]]; then
    jq -cn --arg op "$op" --arg adapter "${ORDO_RUNTIME_ADAPTER:-none}" --arg target "${1-}" \
      '{"op": $op, "adapter": $adapter, "target": $target, "noop": true}'
    return 0
  fi
  if ! declare -F ordo_runtime >/dev/null 2>&1; then
    # shellcheck source=lib/ordo_runtime_adapter.sh
    source "$_ORDO_SCHEDULER_LIB_DIR/ordo_runtime_adapter.sh"
  fi
  ordo_runtime "$op" "$@"
}

# ---------------------------------------------------------------------------
# Pure helpers: backoff, budgets, readiness
# ---------------------------------------------------------------------------
# ordo_scheduler_backoff_seconds <retries-so-far>
# delay = min(BACKOFF_MAX, BACKOFF_BASE * 2^retries); with ORDO_SCHED_JITTER=1
# "equal jitter": delay/2 + random(0..delay/2). Deterministic when JITTER=0.
ordo_scheduler_backoff_seconds() {
  local n="${1:-0}" base="$ORDO_SCHED_BACKOFF_BASE_SEC" cap="$ORDO_SCHED_BACKOFF_MAX_SEC" delay
  _ordo_sched_is_int "$n" || n=0
  (( n > 30 )) && n=30
  delay=$(( base * (1 << n) ))
  (( delay > cap )) && delay=$cap
  (( delay < 0 )) && delay=$cap
  if [[ "${ORDO_SCHED_JITTER:-1}" != "0" && "$delay" -gt 1 ]]; then
    local half=$(( delay / 2 ))
    delay=$(( half + RANDOM % (half + 1) ))
  fi
  printf '%s\n' "$delay"
}

# _ordo_sched_apply_usage <snapshot> <usage-json> -> snapshot with the usage
# added to its counters, exactly as the journal fold will add it (additive).
# Lets heartbeat/report_usage judge the budget without a second projection.
_ordo_sched_apply_usage() {
  printf '%s' "$1" | jq -c --argjson u "$2" '
    .budgets.tokens_used += (($u.tokens // 0) | numbers) | .budgets.seconds_used += (($u.seconds // 0) | numbers)
    | .budgets.turns_used += (($u.turns // 0) | numbers) | .budgets.tool_calls_used += (($u.tool_calls // 0) | numbers)
    | .budgets.cost_used += (($u.cost // 0) | numbers)'
}

# _ordo_sched_budget_json <snapshot|/dev/stdin> -> {"limits":{},"used":{},"exhausted":[]}
# Limits: projection budgets (run.created / run.budget) overridden by
# metadata.budget (per-run overrides). Used counters: projection only.
# shellcheck disable=SC2016 # jq program
ORDO_SCHED_JQ_BUDGET='
    .budgets as $b | (.metadata.budget // {}) as $o
    | def lim(k): (if ($o[k] | type) == "number" then $o[k] else $b[k] end);
      {"max_attempts": lim("max_attempts"), "max_seconds": lim("max_seconds"), "max_tokens": lim("max_tokens"),
       "max_turns": lim("max_turns"), "max_tool_calls": lim("max_tool_calls"), "max_cost": lim("max_cost")} as $limits
    | {"attempts_used": ($b.attempts_used // 0), "seconds_used": ($b.seconds_used // 0), "tokens_used": ($b.tokens_used // 0),
       "turns_used": ($b.turns_used // 0), "tool_calls_used": ($b.tool_calls_used // 0), "cost_used": ($b.cost_used // 0)} as $used
    | [["max_attempts","attempts_used"],["max_seconds","seconds_used"],["max_tokens","tokens_used"],
       ["max_turns","turns_used"],["max_tool_calls","tool_calls_used"],["max_cost","cost_used"]]
      | map(select(($limits[.[0]] | type) == "number" and $limits[.[0]] > 0 and $used[.[1]] >= $limits[.[0]]) | .[0]) as $ex
    | {"limits": $limits, "used": $used, "exhausted": $ex}'
_ordo_sched_budget_json() {
  { if [[ "$1" == /dev/stdin ]]; then cat; else printf '%s' "$1"; fi; } | jq -c "$ORDO_SCHED_JQ_BUDGET"
}

ordo_scheduler_budgets() {
  local run_id="${1-}"
  [[ $# -ge 1 ]] || { _ordo_sched_fail usage "usage: ordo_scheduler_budgets <run_id>"; return $?; }
  _ordo_sched_require_run_id "$run_id" || return $?
  local snap verdict
  snap=$(_ordo_sched_snap "$run_id") || return $?
  verdict=$(_ordo_sched_budget_json "$snap")
  printf '%s\n' "$verdict"
  if _ordo_sched_exhausted "$verdict"; then
    _ordo_sched_fail budget_exhausted "run ${run_id} exhausted its budget" \
      "$(printf '%s' "$verdict" | jq -c --arg run_id "$run_id" '{"run_id": $run_id, "exhausted": .exhausted, "limits": .limits, "used": .used}')"
    return $?
  fi
}

# _ordo_sched_ready_json <snapshot> -> {"ready":bool,"reason":str,"checks":[...]}
# Fail-closed: every dependency run must be `succeeded` (unknown => not ready);
# when a readiness record is present or required, only state == "ready" passes;
# any open blocker keeps the run not ready.
_ordo_sched_ready_json() {
  local snap="$1" states_map="${2:-}" dep dep_state
  local -a deps=()
  if [[ -z "$states_map" ]]; then
    # Dependency states from the journal (one lookup per dependency).
    while IFS= read -r dep; do
      [[ -n "$dep" ]] || continue
      if [[ ! "$dep" =~ ^run_[0-9a-f]{24}$ ]] || ! dep_state=$(ordo_journal_state "$dep" 2>/dev/null); then
        dep_state="unknown"
      fi
      deps+=("$dep" "$dep_state")
    done < <(printf '%s' "$snap" | jq -r '(.metadata.depends_on // []) | if type == "array" then .[] else empty end | tostring')
    states_map="{}"
  fi
  # The verdict in one jq: dependencies (from the resolved pairs, or from the
  # run_id -> state map a tick already holds), readiness record, open blockers.
  printf '%s' "$snap" | jq -c --arg require "${ORDO_SCHED_REQUIRE_READINESS:-0}" --argjson states "$states_map" \
    --argjson npairs "${#deps[@]}" "$ORDO_SCHED_JQ_READY" --args "${deps[@]+"${deps[@]}"}"
}

# _ordo_sched_pick_verdicts <snapshot> <states-map-json>: two lines, the
# budget verdict then the readiness verdict (one jq; the tick's pick loop).
_ordo_sched_pick_verdicts() {
  printf '%s' "$1" | jq -c --arg require "${ORDO_SCHED_REQUIRE_READINESS:-0}" --argjson states "$2" --argjson npairs 0 \
    "($ORDO_SCHED_JQ_BUDGET), ($ORDO_SCHED_JQ_READY)"
}

# shellcheck disable=SC2016 # jq program
ORDO_SCHED_JQ_READY='
    (if $npairs > 0 then [range(0; $npairs; 2) as $i | [$ARGS.positional[$i], $ARGS.positional[$i + 1]]]
     else ((.metadata.depends_on // []) | if type == "array" then map(tostring) else [] end
           | map([., (if test("^run_[0-9a-f]{24}$") then ($states[.] // "unknown") else "unknown" end)])) end) as $deps
    | ($deps | map(.[1] | if . == "unknown" then "dependency_unknown" elif . != "succeeded" then "dependency_" + . else empty end) | first // "") as $dep_reason
    | (.metadata.readiness // null) as $readiness
    | (if $readiness != null or $require == "1"
       then [(if ($readiness | type) == "object" then (($readiness.state // "unknown") | tostring) else "missing" end)] else [] end) as $rstates
    | (.counters.blockers_open // 0) as $open
    | (($deps | map({"check": "dependency", "run_id": .[0], "state": .[1]}))
       + ($rstates | map({"check": "readiness", "state": .}))
       + (if $open != 0 then [{"check": "blockers", "open": $open}] else [] end)) as $checks
    | ($dep_reason
       | if . == "" and ($rstates | length) > 0 and $rstates[0] != "ready" then "readiness_" + $rstates[0] else . end
       | if . == "" and $open != 0 then "blockers_open" else . end) as $reason
    | {"ready": ($reason == ""), "reason": (if $reason == "" then "ready" else $reason end), "checks": $checks}'

ordo_scheduler_ready() {
  local run_id="${1-}"
  [[ $# -ge 1 ]] || { _ordo_sched_fail usage "usage: ordo_scheduler_ready <run_id>"; return $?; }
  _ordo_sched_require_run_id "$run_id" || return $?
  local snap verdict
  snap=$(_ordo_sched_snap "$run_id") || return $?
  verdict=$(_ordo_sched_ready_json "$snap")
  printf '%s\n' "$verdict"
  if ! printf '%s' "$verdict" | jq -e '.ready' >/dev/null; then
    _ordo_sched_fail fail_closed "run ${run_id} is not ready ($(printf '%s' "$verdict" | jq -r .reason))" \
      "$(printf '%s' "$verdict" | jq -c --arg run_id "$run_id" '{"run_id": $run_id, "reason": .reason, "checks": .checks}')"
    return $?
  fi
}

# ---------------------------------------------------------------------------
# Enqueue
# ---------------------------------------------------------------------------
ordo_scheduler_enqueue() {
  _ordo_sched_parse_opts ordo_scheduler_enqueue "$@" || return $?
  local run_id="$_OS_RUN_ID"
  if [[ -n "$run_id" ]]; then
    _ordo_sched_require_run_id "$run_id" || return $?
    if ordo_journal_state "$run_id" >/dev/null 2>&1; then
      _ordo_sched_fail conflict "run ${run_id} already exists" "$(jq -cn --arg run_id "$run_id" '{"run_id": $run_id}')"
      return $?
    fi
  else
    run_id=$(ordo_contracts_new_id run) || return $?
  fi
  local budget_over="{}" metadata="{}" readiness="null"
  [[ -n "$_OS_BUDGET" ]] && { budget_over=$(_ordo_sched_json_arg "$_OS_BUDGET") || return $?; }
  [[ -n "$_OS_METADATA" ]] && { metadata=$(_ordo_sched_json_arg "$_OS_METADATA") || return $?; }
  [[ -n "$_OS_READINESS" ]] && { readiness=$(_ordo_sched_json_arg "$_OS_READINESS") || return $?; }
  local now max_attempts expires_at="" text_file="$_OS_TEXT_FILE"
  now=$(ordo_journal_now)
  max_attempts=$(( ${_OS_MAX_RETRIES:-$ORDO_SCHED_MAX_RETRIES} + 1 ))
  if [[ -n "$_OS_EXPIRES_AT" ]]; then
    expires_at="$_OS_EXPIRES_AT"
  elif [[ "$ORDO_SCHED_QUEUE_TTL_SEC" -gt 0 ]]; then
    expires_at=$(_ordo_sched_add "$now" "$ORDO_SCHED_QUEUE_TTL_SEC")
  fi
  if [[ -n "$text_file" && ! -r "$text_file" ]]; then
    _ordo_sched_fail not_found "text file not readable: ${text_file}" "$(jq -cn --arg f "$text_file" '{"text_file": $f}')"
    return $?
  fi
  local payload
  payload=$(jq -cn \
    --arg title "$_OS_TITLE" --arg ticket "$_OS_TICKET" --arg project "${PROJECT:-}" \
    --arg now "$now" --arg not_before "$_OS_NOT_BEFORE" --arg expires_at "$expires_at" \
    --arg priority "${_OS_PRIORITY:-$ORDO_SCHED_DEFAULT_PRIORITY}" --arg depends "$_OS_DEPENDS" \
    --arg target "$_OS_RT_TARGET" --arg text_file "$text_file" --arg owner "$(ordo_scheduler_owner)" \
    --argjson max_attempts "$max_attempts" --argjson max_turns "$ORDO_SCHED_BUDGET_MAX_TURNS" \
    --argjson max_tool_calls "$ORDO_SCHED_BUDGET_MAX_TOOL_CALLS" --argjson max_seconds "$ORDO_SCHED_BUDGET_MAX_SECONDS" \
    --argjson max_tokens "$ORDO_SCHED_BUDGET_MAX_TOKENS" --argjson max_cost "$ORDO_SCHED_BUDGET_MAX_COST" \
    --argjson budget_over "$budget_over" --argjson metadata "$metadata" --argjson readiness "$readiness" '
    {"project": $project,
     "budget": ({"max_attempts": $max_attempts, "max_seconds": $max_seconds, "max_tokens": $max_tokens,
                 "max_turns": $max_turns, "max_tool_calls": $max_tool_calls, "max_cost": $max_cost}
                + $budget_over + ($metadata.budget // {})),
     "metadata": ({"priority": ($priority | tonumber), "enqueued_at": $now, "enqueued_by": $owner,
                   "attempt_started_at": null, "active_since": null, "heartbeat_at": null,
                   "lease_id": null, "lease_owner": null, "not_before": null, "blocker_id": null}
                  + (if $not_before == "" then {} else {"not_before": $not_before} end)
                  + (if $expires_at == "" then {} else {"expires_at": $expires_at} end)
                  + (if $depends == "" then {} else {"depends_on": ($depends | split(",") | map(select(. != "")))} end)
                  + (if $readiness == null then {} else {"readiness": $readiness} end)
                  + (if $target == "" then {} else {"runtime": {"target": $target, "text_file": $text_file}} end)
                  + $metadata)}
    + (if $title == "" then {} else {"title": $title} end)
    + (if $ticket == "" then {} else {"ticket_ref": $ticket} end)')
  ordo_journal_append "$run_id" run.created "$payload" --actor "$_OS_ACTOR_JSON" >/dev/null || return $?
  _ordo_sched_audit "ENQUEUED run=${run_id} priority=${_OS_PRIORITY:-$ORDO_SCHED_DEFAULT_PRIORITY} ticket=${_OS_TICKET:-none}"
  printf '%s' "$payload" | jq -c --arg run_id "$run_id" '
    {"run_id": $run_id, "state": "queued", "title": (.title // null), "ticket_ref": (.ticket_ref // null),
     "priority": .metadata.priority, "not_before": (.metadata.not_before // null), "expires_at": (.metadata.expires_at // null),
     "budgets": (.budget + {"attempts_used": 0, "seconds_used": 0, "tokens_used": 0, "turns_used": 0, "tool_calls_used": 0, "cost_used": 0, "exhausted": []})}'
}

# ---------------------------------------------------------------------------
# Worker-side transitions (need the live lease of this worker)
# ---------------------------------------------------------------------------
# _ordo_sched_require_owned_lease <run_id> <snapshot> -> lease JSON (8 lease_lost)
_ordo_sched_require_owned_lease() {
  local run_id="$1" snap="$2" self
  if [[ "${_SF_RUN_ID-}" != "$run_id" ]]; then
    _ordo_sched_snap_fields "$snap"
  fi
  local lease="$_SF_LEASE" owner="$_SF_LEASE_OWNER"
  self=$(ordo_scheduler_owner)
  if [[ -z "$lease" ]]; then
    _ordo_sched_fail lease_lost "run ${run_id} has no live lease" \
      "$(printf '%s' "$snap" | jq -c --arg run_id "$run_id" --arg self "$self" '{"run_id": $run_id, "lease": .lease, "worker": $self}')"
    return $?
  fi
  if [[ "$owner" != "$self" ]]; then
    _ordo_sched_fail lease_lost "run ${run_id} is leased by ${owner}, not by this worker (${self})" \
      "$(printf '%s' "$lease" | jq -c --arg run_id "$run_id" --arg self "$self" '{"run_id": $run_id, "owner": .owner, "lease_id": .id, "worker": $self}')"
    return $?
  fi
  printf '%s' "$lease"
}

# _ordo_sched_fail_budget <run_id> <snapshot> <verdict> — release the lease,
# fail the run (reason budget_exhausted), return 7 with the error object.
_ordo_sched_fail_budget() {
  local run_id="$1" snap="$2" verdict="$3" payload
  _ordo_sched_snap_fields "$snap"
  local state="$_SF_STATE" lease_id="$_SF_LEASE_ID" to=failed etype=run.failed
  payload=$(printf '%s' "$verdict" | jq -c '{"reason": "budget_exhausted", "exhausted": .exhausted, "limits": .limits, "used": .used,
    "metadata": {"lease_id": null, "lease_owner": null, "heartbeat_at": null, "failure_reason": "budget_exhausted"}}')
  case "$state" in
    queued|leased) to=expired etype=run.expired ;;
  esac
  _ordo_sched_check "$run_id" "$state" "$to" || return $?
  # _OS_BATCH_PREFIX (consumed): ops the caller wants committed first, in
  # the same transaction (the heartbeat's renewal + usage that exhausted it).
  local -a ops=("${_OS_BATCH_PREFIX[@]+"${_OS_BATCH_PREFIX[@]}"}")
  _OS_BATCH_PREFIX=()
  [[ -n "$lease_id" ]] && ops+=("$(_ordo_sched_op_release "$lease_id")")
  ops+=("$(_ordo_sched_op_append "$run_id" "$etype" "$payload")")
  _ordo_sched_batch "${ops[@]}" >/dev/null || return $?
  local exhausted
  exhausted=$(printf '%s' "$verdict" | jq -r '.exhausted | join(",")')
  _ordo_sched_audit "BUDGET_EXHAUSTED run=${run_id} from=${state} exhausted=${exhausted}"
  _ordo_sched_fail budget_exhausted "run ${run_id} exhausted its budget (${exhausted})" \
    "$(printf '%s' "$verdict" | jq -c --arg run_id "$run_id" --arg state "$state" '{"run_id": $run_id, "from": $state, "exhausted": .exhausted, "limits": .limits, "used": .used}')"
}

ordo_scheduler_heartbeat() {
  local run_id="${1-}"
  [[ $# -ge 1 ]] || { _ordo_sched_fail usage "usage: ordo_scheduler_heartbeat <run_id> [--usage JSON] [--actor JSON]"; return $?; }
  shift
  _ordo_sched_parse_opts ordo_scheduler_heartbeat "$@" || return $?
  _ordo_sched_require_run_id "$run_id" || return $?
  local snap usage="{}"
  [[ -n "$_OS_USAGE" ]] && { usage=$(_ordo_sched_json_arg "$_OS_USAGE") || return $?; }
  snap=$(_ordo_sched_snap "$run_id") || return $?
  _ordo_sched_heartbeat_snap "$run_id" "$snap" "$usage"
}

# _ordo_sched_heartbeat_snap <run_id> <snapshot> <usage-json> — the heartbeat
# on an already loaded snapshot (the tick passes the one it holds).
_ordo_sched_heartbeat_snap() {
  local run_id="$1" snap="$2" usage="$3" now
  now=$(ordo_journal_now)
  _ordo_sched_snap_fields "$snap" "$now"
  local state="$_SF_STATE" last="$_SF_HB_LAST"
  if [[ "$state" != "running" ]]; then
    _ordo_sched_fail invalid_state "run ${run_id} is ${state}; only a running run heartbeats" \
      "$(jq -cn --arg run_id "$run_id" --arg state "$state" '{"run_id": $run_id, "state": $state}')"
    return $?
  fi
  _ordo_sched_require_owned_lease "$run_id" "$snap" >/dev/null || return $?
  local lease_id="$_SF_LEASE_ID" delta=0
  if [[ -n "$last" ]]; then
    delta=$(( $(_ordo_sched_epoch "$now") - $(_ordo_sched_epoch "$last") ))
    (( delta < 0 )) && delta=0
  fi
  # One jq: the run.budget payload and the budget verdict the fold will
  # produce once the usage is added (same programs as apply_usage + budget_json).
  local payload verdict
  { IFS= read -r payload; IFS= read -r verdict; } < <(printf '%s' "$snap" | jq -c --argjson usage "$usage" --argjson delta "$delta" --arg now "$now" '
    ($usage + {"seconds": (($usage.seconds // 0) + $delta)}) as $u
    | {"usage": $u, "metadata": {"heartbeat_at": $now}},
      (.budgets.tokens_used += (($u.tokens // 0) | numbers) | .budgets.seconds_used += (($u.seconds // 0) | numbers)
       | .budgets.turns_used += (($u.turns // 0) | numbers) | .budgets.tool_calls_used += (($u.tool_calls // 0) | numbers)
       | .budgets.cost_used += (($u.cost // 0) | numbers)
       | '"$ORDO_SCHED_JQ_BUDGET"')')
  # ONE transaction: lease renewal + run.budget — and, when this usage
  # exhausts the budget, the release + run.failed of _ordo_sched_fail_budget
  # in the same transaction (same event order: renewed, budget, released, failed).
  local renew_op budget_op out
  renew_op="{\"op\":\"lease_renew\",\"lease_id\":\"${lease_id}\",\"run_id\":\"${run_id}\",\"ttl\":${ORDO_SCHED_LEASE_TTL}}"
  budget_op=$(_ordo_sched_op_append "$run_id" run.budget "$payload")
  if _ordo_sched_exhausted "$verdict"; then
    _OS_BATCH_PREFIX=("$renew_op" "$budget_op")
    _ordo_sched_fail_budget "$run_id" "$snap" "$verdict"
    return $?
  fi
  out=$(_ordo_sched_batch "$renew_op" "$budget_op") || return $?
  printf '%s' "$out" | jq -c --arg run_id "$run_id" --arg now "$now" --argjson delta "$delta" --argjson budgets "$verdict" '
    .results[0] as $lease
    | {"run_id": $run_id, "state": "running", "heartbeat_at": $now, "lease_id": $lease.id, "generation": $lease.generation,
       "expires_at": $lease.expires_at, "seconds_delta": $delta, "budgets": $budgets}'
}

ordo_scheduler_report_usage() {
  local run_id="${1-}" usage_arg="${2-}"
  [[ $# -ge 2 ]] || { _ordo_sched_fail usage "usage: ordo_scheduler_report_usage <run_id> <usage-json> [--actor JSON]"; return $?; }
  shift 2
  _ordo_sched_parse_opts ordo_scheduler_report_usage "$@" || return $?
  _ordo_sched_require_run_id "$run_id" || return $?
  local usage snap state
  usage=$(_ordo_sched_json_arg "$usage_arg") || return $?
  snap=$(_ordo_sched_snap "$run_id") || return $?
  _ordo_sched_snap_fields "$snap"
  state="$_SF_STATE"
  if [[ "$_SF_TERMINAL" == true ]]; then
    _ordo_sched_fail invalid_state "run ${run_id} is terminal (${state}); usage can no longer be reported" \
      "$(jq -cn --arg run_id "$run_id" --arg state "$state" '{"run_id": $run_id, "state": $state}')"
    return $?
  fi
  local verdict
  verdict=$(_ordo_sched_apply_usage "$snap" "$usage" | _ordo_sched_budget_json /dev/stdin)
  if _ordo_sched_exhausted "$verdict"; then
    # run.budget + release + run.failed/expired in one transaction.
    _OS_BATCH_PREFIX=("$(_ordo_sched_op_append "$run_id" run.budget "{\"usage\":${usage}}")")
    _ordo_sched_fail_budget "$run_id" "$snap" "$verdict"
    return $?
  fi
  _ordo_journal_append_compact "$run_id" run.budget "{\"usage\":${usage}}" "$_OS_ACTOR_JSON" >/dev/null || return $?
  printf '%s\n' "$verdict"
}

# _ordo_sched_park <run_id> <to-state> <event-type> <extra-payload-json> <fn>
# Shared by wait/block/require_approval: running -> <to>, lease released.
_ordo_sched_park() {
  local run_id="$1" to="$2" etype="$3" extra="$4"
  shift 4
  local snap state lease_id now deadline="" payload
  snap=$(_ordo_sched_snap "$run_id") || return $?
  now=$(ordo_journal_now)
  _ordo_sched_snap_fields "$snap" "$now"
  state="$_SF_STATE"
  if [[ "$state" != "running" ]]; then
    _ordo_sched_fail invalid_transition "run ${run_id}: transition ${state} -> ${to} is not allowed" \
      "$(jq -cn --arg run_id "$run_id" --arg from "$state" --arg to "$to" '{"run_id": $run_id, "from": $from, "to": $to}')"
    return $?
  fi
  _ordo_sched_require_owned_lease "$run_id" "$snap" >/dev/null || return $?
  lease_id="$_SF_LEASE_ID"
  if [[ -n "$_OS_DEADLINE" ]]; then
    deadline="$_OS_DEADLINE"
  elif [[ "$ORDO_SCHED_WAIT_TIMEOUT_SEC" -gt 0 ]]; then
    deadline=$(_ordo_sched_add "$now" "$ORDO_SCHED_WAIT_TIMEOUT_SEC")
  fi
  payload=$(jq -cn --argjson extra "$extra" --arg now "$now" --arg deadline "$deadline" --arg reason "$_OS_REASON" '
    $extra + {"reason": $reason, "metadata": (($extra.metadata // {}) + {"lease_id": null, "lease_owner": null, "heartbeat_at": null,
      "parked_at": $now, "wait_deadline": (if $deadline == "" then null else $deadline end)})}')
  _ordo_sched_check "$run_id" running "$to" || return $?
  # ONE transaction: lease released, state event, then the caller's extra ops.
  _ordo_sched_batch "$(_ordo_sched_op_release "$lease_id")" "$(_ordo_sched_op_append "$run_id" "$etype" "$payload")" "$@" >/dev/null || return $?
  _ordo_sched_audit "PARKED run=${run_id} state=${to} reason=${_OS_REASON:-none} lease=${lease_id}"
  jq -cn --arg run_id "$run_id" --arg state "$to" --arg lease_id "$lease_id" --arg deadline "$deadline" \
    '{"run_id": $run_id, "state": $state, "lease": null, "released_lease_id": $lease_id, "wait_deadline": (if $deadline == "" then null else $deadline end)}'
}

ordo_scheduler_wait() {
  local run_id="${1-}"
  [[ $# -ge 1 ]] || { _ordo_sched_fail usage "usage: ordo_scheduler_wait <run_id> [--reason R] [--deadline TS] [--actor JSON]"; return $?; }
  shift
  _ordo_sched_parse_opts ordo_scheduler_wait "$@" || return $?
  _ordo_sched_require_run_id "$run_id" || return $?
  _ordo_sched_park "$run_id" waiting run.waiting '{}'
}

ordo_scheduler_block() {
  local run_id="${1-}"
  [[ $# -ge 1 ]] || { _ordo_sched_fail usage "usage: ordo_scheduler_block <run_id> [--reason R] [--type T] [--actor JSON]"; return $?; }
  shift
  _ordo_sched_parse_opts ordo_scheduler_block "$@" || return $?
  _ordo_sched_require_run_id "$run_id" || return $?
  local btype="${_OS_TYPE:-external}" bid
  bid="blocker_$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
  local out
  out=$(_ordo_sched_park "$run_id" blocked run.blocked \
    "$(jq -cn --arg t "$btype" --arg id "$bid" '{"blocker_type": $t, "metadata": {"blocker_id": $id, "block_type": $t}}')" \
    "$(_ordo_sched_op_append "$run_id" blocker.raised \
      "$(jq -cn --arg id "$bid" --arg t "$btype" --arg s "${_OS_REASON:-blocked}" '{"id": $id, "type": $t, "severity": "blocking", "summary": $s}')")") || return $?
  printf '%s' "$out" | jq -c --arg id "$bid" --arg t "$btype" '. + {"blocker_id": $id, "blocker_type": $t}'
}

ordo_scheduler_require_approval() {
  local run_id="${1-}"
  [[ $# -ge 1 ]] || { _ordo_sched_fail usage "usage: ordo_scheduler_require_approval <run_id> [--action A] [--reason R] [--deadline TS] [--actor JSON]"; return $?; }
  shift
  _ordo_sched_parse_opts ordo_scheduler_require_approval "$@" || return $?
  _ordo_sched_require_run_id "$run_id" || return $?
  _ordo_sched_park "$run_id" approval_required run.approval_required \
    "$(jq -cn --arg a "${_OS_ACTION:-}" '{"action": $a, "metadata": {"approval_action": (if $a == "" then null else $a end)}}')"
}

ordo_scheduler_complete() {
  local run_id="${1-}"
  [[ $# -ge 1 ]] || { _ordo_sched_fail usage "usage: ordo_scheduler_complete <run_id> [--result JSON] [--actor JSON]"; return $?; }
  shift
  _ordo_sched_parse_opts ordo_scheduler_complete "$@" || return $?
  _ordo_sched_require_run_id "$run_id" || return $?
  local result="{}" snap state lease_id
  [[ -n "$_OS_RESULT" ]] && { result=$(_ordo_sched_json_arg "$_OS_RESULT") || return $?; }
  snap=$(_ordo_sched_snap "$run_id") || return $?
  _ordo_sched_snap_fields "$snap"
  state="$_SF_STATE"
  if [[ "$state" != "running" ]]; then
    _ordo_sched_fail invalid_transition "run ${run_id}: transition ${state} -> succeeded is not allowed" \
      "$(jq -cn --arg run_id "$run_id" --arg from "$state" '{"run_id": $run_id, "from": $from, "to": "succeeded"}')"
    return $?
  fi
  _ordo_sched_require_owned_lease "$run_id" "$snap" >/dev/null || return $?
  lease_id="$_SF_LEASE_ID"
  _ordo_sched_check "$run_id" running succeeded || return $?
  _ordo_sched_batch "$(_ordo_sched_op_release "$lease_id")" "$(_ordo_sched_op_append "$run_id" run.succeeded \
    "$(jq -cn --argjson r "$result" --arg now "$(ordo_journal_now)" '{"result": $r, "metadata": {"lease_id": null, "lease_owner": null, "heartbeat_at": null, "finished_at": $now}}')")" >/dev/null || return $?
  _ordo_sched_audit "SUCCEEDED run=${run_id}"
  jq -cn --arg run_id "$run_id" '{"run_id": $run_id, "state": "succeeded", "lease": null}'
}

# ---------------------------------------------------------------------------
# Authority transitions (operator / supervisor): fail, cancel, resume
# ---------------------------------------------------------------------------
ordo_scheduler_fail() {
  local run_id="${1-}"
  [[ $# -ge 1 ]] || { _ordo_sched_fail usage "usage: ordo_scheduler_fail <run_id> [--reason R] [--actor JSON]"; return $?; }
  shift
  _ordo_sched_parse_opts ordo_scheduler_fail "$@" || return $?
  _ordo_sched_require_run_id "$run_id" || return $?
  local snap state lease_id
  snap=$(_ordo_sched_snap "$run_id") || return $?
  _ordo_sched_snap_fields "$snap"
  state="$_SF_STATE" lease_id="$_SF_LEASE_ID"
  _ordo_sched_check "$run_id" "$state" failed || return $?   # the structured 5
  local -a ops=()
  [[ -n "$lease_id" ]] && ops+=("$(_ordo_sched_op_release "$lease_id")")
  ops+=("$(_ordo_sched_op_append "$run_id" run.failed \
    "$(jq -cn --arg r "${_OS_REASON:-failed}" --arg now "$(ordo_journal_now)" '{"reason": $r, "metadata": {"lease_id": null, "lease_owner": null, "heartbeat_at": null, "finished_at": $now, "failure_reason": $r}}')")")
  _ordo_sched_batch "${ops[@]}" >/dev/null || return $?
  _ordo_sched_audit "FAILED run=${run_id} from=${state} reason=${_OS_REASON:-failed}"
  jq -cn --arg run_id "$run_id" --arg from "$state" --arg r "${_OS_REASON:-failed}" '{"run_id": $run_id, "state": "failed", "from": $from, "reason": $r, "lease": null}'
}

ordo_scheduler_cancel() {
  local run_id="${1-}"
  [[ $# -ge 1 ]] || { _ordo_sched_fail usage "usage: ordo_scheduler_cancel <run_id> [--reason R] [--actor JSON]"; return $?; }
  shift
  _ordo_sched_parse_opts ordo_scheduler_cancel "$@" || return $?
  _ordo_sched_require_run_id "$run_id" || return $?
  local snap state lease_id target
  snap=$(_ordo_sched_snap "$run_id") || return $?
  _ordo_sched_snap_fields "$snap"
  state="$_SF_STATE" lease_id="$_SF_LEASE_ID" target="$_SF_TARGET"
  if [[ "$_SF_TERMINAL" == true ]]; then
    _ordo_sched_fail invalid_transition "run ${run_id} is already terminal (${state}); cancel is not allowed" \
      "$(jq -cn --arg run_id "$run_id" --arg from "$state" '{"run_id": $run_id, "from": $from, "to": "cancelled", "terminal": true}')"
    return $?
  fi
  _ordo_sched_check "$run_id" "$state" cancelled || return $?
  local -a ops=()
  if [[ "$state" == "running" && -n "$target" ]]; then
    # Release first, stop the runtime, then record the cancellation.
    [[ -n "$lease_id" ]] && { _ordo_sched_batch "$(_ordo_sched_op_release "$lease_id")" >/dev/null || return $?; }
    ordo_scheduler_runtime stop "$target" >/dev/null 2>&1 || true
  elif [[ -n "$lease_id" ]]; then
    ops+=("$(_ordo_sched_op_release "$lease_id")")
  fi
  ops+=("$(_ordo_sched_op_append "$run_id" run.cancelled \
    "$(jq -cn --arg r "${_OS_REASON:-cancelled}" --arg now "$(ordo_journal_now)" --arg lease "$lease_id" \
      '{"reason": $r, "released_lease_id": (if $lease == "" then null else $lease end),
        "metadata": {"lease_id": null, "lease_owner": null, "heartbeat_at": null, "finished_at": $now, "cancel_reason": $r}}')")")
  _ordo_sched_batch "${ops[@]}" >/dev/null || return $?
  _ordo_sched_audit "CANCELLED run=${run_id} from=${state} reason=${_OS_REASON:-cancelled}"
  jq -cn --arg run_id "$run_id" --arg from "$state" --arg r "${_OS_REASON:-cancelled}" --arg lease "$lease_id" \
    '{"run_id": $run_id, "state": "cancelled", "from": $from, "reason": $r, "released_lease_id": (if $lease == "" then null else $lease end), "lease": null}'
}

# _ordo_sched_slots_used -> number of runs holding a worker slot (leased|running)
_ordo_sched_slots_used() {
  ordo_journal_runs --state leased,running | grep -c . || true
}

# _ordo_sched_acquire_and_start <run_id> <snapshot> <mode:start|resume>
# Lease + run.leased (start mode) + runtime start + run.started/attempt.started,
# or lease + run.resumed. Prints {"run_id","state","lease_id","attempt_no"}.
_ordo_sched_acquire_and_start() {
  local run_id="$1" snap="$2" mode="$3" state now owner lease_id rc=0
  now=$(ordo_journal_now)
  _ordo_sched_snap_fields "$snap" "$now"
  state="$_SF_STATE"
  owner=$(ordo_scheduler_owner)
  lease_id=$(ordo_contracts_new_id lease) || return $?
  local blocker_id="$_SF_BLOCKER_ID" attempt_no=$(( _SF_ATTEMPTS + 1 ))
  local -a ops=("$(_ordo_sched_op_acquire "$run_id" "$owner" "$lease_id")")
  if [[ "$mode" == "resume" ]]; then
    _ordo_sched_check "$run_id" "$state" running || return $?
    if [[ -n "$blocker_id" ]]; then
      ops+=("$(_ordo_sched_op_append "$run_id" blocker.resolved "$(jq -cn --arg id "$blocker_id" '{"id": $id, "resolution": "resumed"}')")")
    fi
    ops+=("$(_ordo_sched_op_append "$run_id" run.resumed \
      "$(jq -cn --arg lease "$lease_id" --arg owner "$owner" --arg now "$now" --arg r "${_OS_REASON:-resumed}" \
        '{"lease_id": $lease, "owner": $owner, "reason": $r, "metadata": {"lease_id": $lease, "lease_owner": $owner, "active_since": $now, "heartbeat_at": $now, "blocker_id": null, "resumed_at": $now, "wait_deadline": null}}')")")
    _ordo_sched_batch "${ops[@]}" >/dev/null || return $?
    jq -cn --arg run_id "$run_id" --arg lease "$lease_id" --arg owner "$owner" --argjson n "$attempt_no" \
      '{"run_id": $run_id, "state": "running", "lease_id": $lease, "owner": $owner, "attempt_no": ($n - 1), "resumed": true}'
    return 0
  fi
  _ordo_sched_check "$run_id" "$state" leased || return $?
  _ordo_sched_check "$run_id" leased running || return $?
  local attempt_id p_leased p_started p_attempt
  attempt_id=$(ordo_contracts_new_id attempt) || return $?
  # The three start payloads in one jq run.
  { IFS= read -r p_leased; IFS= read -r p_started; IFS= read -r p_attempt; } < <(jq -cn \
    --arg lease "$lease_id" --arg owner "$owner" --arg now "$now" --argjson n "$attempt_no" --arg id "$attempt_id" '
    {"lease_id": $lease, "owner": $owner, "metadata": {"lease_id": $lease, "lease_owner": $owner, "leased_at": $now, "not_before": null}},
    {"lease_id": $lease, "attempt_no": $n, "metadata": {"attempt_started_at": $now, "active_since": $now, "heartbeat_at": $now, "blocker_id": null}},
    {"attempt_id": $id, "attempt_no": $n, "lease_id": $lease, "owner": $owner}')
  ops+=("$(_ordo_sched_op_append "$run_id" run.leased "$p_leased")")
  local target="$_SF_TARGET" text_file="$_SF_TEXT_FILE" rt_out
  local -a started=(
    "$(_ordo_sched_op_append "$run_id" run.started "$p_started")"
    "$(_ordo_sched_op_append "$run_id" attempt.started "$p_attempt")"
  )
  if [[ -n "$target" ]]; then
    # lease + run.leased, then the runtime, then run.started + attempt.started.
    _ordo_sched_batch "${ops[@]}" >/dev/null || return $?
    local -a rt_args=(start "$target")
    [[ -n "$text_file" ]] && rt_args+=(--text-file "$text_file")
    rt_out=$(ordo_scheduler_runtime "${rt_args[@]}" 2>&1) || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      _OS_RETRY_RELEASE_LEASE="$lease_id"
      _ordo_sched_retry_or_fail "$run_id" runtime_start_failed "$ORDO_SCHED_LEASE_EXPIRY_POLICY" \
        "$(printf '%s' "$rt_out" | tail -n 1 | cut -c1-300)" >/dev/null || true
      _ordo_sched_fail generic_failure "runtime start failed for run ${run_id} (rc=${rc})" \
        "$(jq -cn --arg run_id "$run_id" --arg target "$target" --argjson rc "$rc" --arg raw "$(printf '%s' "$rt_out" | tail -n 1 | cut -c1-300)" '{"run_id": $run_id, "target": $target, "rc": $rc, "raw": $raw}')"
      return $?
    fi
    _ordo_sched_batch "${started[@]}" >/dev/null || return $?
  else
    _ordo_sched_batch "${ops[@]}" "${started[@]}" >/dev/null || return $?
  fi
  jq -cn --arg run_id "$run_id" --arg lease "$lease_id" --arg owner "$owner" --argjson n "$attempt_no" \
    '{"run_id": $run_id, "state": "running", "lease_id": $lease, "owner": $owner, "attempt_no": $n, "resumed": false}'
}

ordo_scheduler_resume() {
  local run_id="${1-}"
  [[ $# -ge 1 ]] || { _ordo_sched_fail usage "usage: ordo_scheduler_resume <run_id> [--requeue] [--reason R] [--actor JSON]"; return $?; }
  shift
  _ordo_sched_parse_opts ordo_scheduler_resume "$@" || return $?
  _ordo_sched_require_run_id "$run_id" || return $?
  # One read: the stored projection of the run (what ordo_journal_project
  # folds — every write refreshes it) and the slots in use.
  local view snap state used
  view=$(ordo_journal_tick_view) || return $?
  { IFS= read -r snap; read -r used; } < <(printf '%s' "$view" | jq -c --arg r "$run_id" '(.runs[] | select(.run_id == $r)), .slots_used')
  if [[ "$snap" != '{'* ]]; then
    _ordo_sched_fail not_found "unknown run ${run_id}" "$(jq -cn --arg run_id "$run_id" '{"run_id": $run_id}')"
    return $?
  fi
  _ordo_sched_snap_fields "$snap"
  state="$_SF_STATE"
  case "$state" in
    waiting|blocked|approval_required) ;;
    *)
      _ordo_sched_fail invalid_transition "run ${run_id} is ${state}; only waiting, blocked or approval_required runs resume" \
        "$(jq -cn --arg run_id "$run_id" --arg from "$state" '{"run_id": $run_id, "from": $from, "to": "running", "allowed_from": ["waiting","blocked","approval_required"]}')"
      return $?
      ;;
  esac
  # Fail-closed readiness: the blocker the scheduler itself raised is
  # resolved by the resume, so it is not counted; anything else keeps the run parked.
  local verdict ready_snap
  ready_snap=$(printf '%s' "$snap" | jq -c '.metadata.blocker_id as $b
    | .blockers |= map(if .id == $b and .state == "open" then .state = "resolved" else . end)
    | .counters.blockers_open = ([.blockers[] | select(.state == "open")] | length)')
  verdict=$(_ordo_sched_ready_json "$ready_snap")
  if [[ "$verdict" != '{"ready":true,'* ]]; then
    _ordo_sched_fail fail_closed "run ${run_id} stays ${state}: not ready ($(printf '%s' "$verdict" | jq -r .reason))" \
      "$(printf '%s' "$verdict" | jq -c --arg run_id "$run_id" --arg state "$state" '{"run_id": $run_id, "state": $state, "reason": .reason, "checks": .checks}')"
    return $?
  fi
  local budgets
  budgets=$(_ordo_sched_budget_json "$snap")
  if _ordo_sched_exhausted "$budgets"; then
    _ordo_sched_fail_budget "$run_id" "$snap" "$budgets"
    return $?
  fi
  if [[ "$_OS_REQUEUE" == 1 ]]; then
    local blocker_id="$_SF_BLOCKER_ID"
    _ordo_sched_check "$run_id" "$state" queued || return $?
    local -a ops=()
    if [[ -n "$blocker_id" ]]; then
      ops+=("$(_ordo_sched_op_append "$run_id" blocker.resolved "$(jq -cn --arg id "$blocker_id" '{"id": $id, "resolution": "requeued"}')")")
    fi
    ops+=("$(_ordo_sched_op_append "$run_id" run.requeued \
      "$(jq -cn --arg r "${_OS_REASON:-resumed}" --arg now "$(ordo_journal_now)" '{"reason": $r, "metadata": {"not_before": null, "blocker_id": null, "wait_deadline": null, "requeued_at": $now, "requeue_reason": $r}}')")")
    _ordo_sched_batch "${ops[@]}" >/dev/null || return $?
    _ordo_sched_audit "RESUMED run=${run_id} from=${state} to=queued"
    jq -cn --arg run_id "$run_id" --arg from "$state" '{"run_id": $run_id, "state": "queued", "from": $from, "lease": null}'
    return 0
  fi
  if (( used >= ORDO_SCHED_MAX_FANOUT )); then
    _ordo_sched_fail budget_exhausted "fan-out limit reached (${used}/${ORDO_SCHED_MAX_FANOUT}); resume ${run_id} later or use --requeue" \
      "$(jq -cn --arg run_id "$run_id" --argjson used "$used" --argjson max "$ORDO_SCHED_MAX_FANOUT" '{"run_id": $run_id, "exhausted": ["max_fanout"], "used": $used, "limit": $max}')"
    return $?
  fi
  local out
  out=$(_ordo_sched_acquire_and_start "$run_id" "$snap" resume) || return $?
  _ordo_sched_audit "RESUMED run=${run_id} from=${state} to=running lease=$(printf '%s' "$out" | jq -r .lease_id)"
  printf '%s' "$out" | jq -c --arg from "$state" '. + {"from": $from}'
}

# ---------------------------------------------------------------------------
# Retry policy: lease loss / timeout / dead owner -> requeue with backoff or fail
# ---------------------------------------------------------------------------
# _ordo_sched_retry_or_fail <run_id> <reason> <policy:requeue|fail> [detail] [--no-backoff]
# Prints {"run_id","action":"requeued|failed|expired","not_before"?,"reason"}.
# Callers holding a current snapshot pass it in _OS_RETRY_SNAP (consumed);
# _OS_RETRY_RELEASE_LEASE (consumed) names a lease to release best-effort in
# the same transaction as the run events.
_OS_RETRY_SNAP="" _OS_RETRY_RELEASE_LEASE=""
_OS_BATCH_PREFIX=()
_ordo_sched_retry_or_fail() {
  local run_id="$1" reason="$2" policy="${3:-requeue}" detail="${4:-}" no_backoff=0
  [[ "${5:-}" == "--no-backoff" ]] && no_backoff=1
  local snap="$_OS_RETRY_SNAP" release="$_OS_RETRY_RELEASE_LEASE" state now attempts max_attempts verdict
  _OS_RETRY_SNAP="" _OS_RETRY_RELEASE_LEASE=""
  [[ -n "$snap" ]] || { snap=$(_ordo_sched_snap "$run_id") || return $?; }
  now=$(ordo_journal_now)
  _ordo_sched_snap_fields "$snap" "$now"
  state="$_SF_STATE"
  verdict=$(_ordo_sched_budget_json "$snap")
  { read -r attempts; read -r max_attempts; } < <(printf '%s' "$verdict" | jq -r '.used.attempts_used, (.limits.max_attempts // 0)')
  local fail_payload
  fail_payload=$(jq -cn --arg r "$reason" --arg d "$detail" --arg now "$now" --arg policy "$policy" --argjson a "$attempts" --argjson m "$max_attempts" '
    {"reason": $r, "detail": $d, "policy": $policy, "attempts_used": $a, "max_attempts": $m,
     "metadata": {"lease_id": null, "lease_owner": null, "heartbeat_at": null, "finished_at": $now, "failure_reason": $r}}')
  local retries_exhausted=0
  if [[ "$max_attempts" != "null" ]] && (( max_attempts > 0 && attempts >= max_attempts )); then
    retries_exhausted=1
  fi
  local -a ops=()
  [[ -n "$release" ]] && ops+=("$(_ordo_sched_op_release "$release")")
  if [[ "$policy" == "fail" || "$retries_exhausted" == 1 ]]; then
    local final_reason="$reason" to=failed etype=run.failed
    [[ "$retries_exhausted" == 1 ]] && final_reason="budget_exhausted"
    fail_payload=$(printf '%s' "$fail_payload" | jq -c --arg fr "$final_reason" --arg cause "$reason" \
      '.reason = $fr | .cause = $cause | .metadata.failure_reason = $fr | (if $fr == "budget_exhausted" then .exhausted = ["max_attempts"] else . end)')
    case "$state" in
      queued|leased) to=expired; etype=run.expired ;;
      running|waiting|blocked|approval_required) to=failed; etype=run.failed ;;
      *)
        [[ ${#ops[@]} -eq 0 ]] || _ordo_sched_batch "${ops[@]}" >/dev/null || true
        return 0 ;;
    esac
    _ordo_sched_check "$run_id" "$state" "$to" || return $?
    ops+=("$(_ordo_sched_op_append "$run_id" "$etype" "$fail_payload")")
    _ordo_sched_batch "${ops[@]}" >/dev/null || return $?
    _ordo_sched_audit "RETRY_EXHAUSTED run=${run_id} from=${state} to=${to} reason=${final_reason} cause=${reason} attempts=${attempts}/${max_attempts}"
    jq -cn --arg run_id "$run_id" --arg action "$to" --arg r "$final_reason" --arg cause "$reason" --argjson a "$attempts" \
      '{"run_id": $run_id, "action": $action, "reason": $r, "cause": $cause, "attempts_used": $a}'
    return 0
  fi
  local retries=$(( attempts > 0 ? attempts - 1 : 0 )) delay=0 not_before
  [[ "$no_backoff" == 1 ]] || delay=$(ordo_scheduler_backoff_seconds "$retries")
  not_before=$(_ordo_sched_add "$now" "$delay")
  local blocker_id="$_SF_BLOCKER_ID"
  if [[ "$state" == "running" ]]; then
    blocker_id="blocker_$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
    _ordo_sched_check "$run_id" running blocked || return $?
    ops+=("$(_ordo_sched_op_append "$run_id" run.blocked \
      "$(jq -cn --arg r "$reason" --arg d "$detail" --arg id "$blocker_id" '{"reason": $r, "detail": $d, "blocker_type": $r, "metadata": {"lease_id": null, "lease_owner": null, "heartbeat_at": null, "blocker_id": $id, "block_type": $r}}')")")
    ops+=("$(_ordo_sched_op_append "$run_id" blocker.raised \
      "$(jq -cn --arg id "$blocker_id" --arg t "$reason" --arg s "${detail:-$reason}" '{"id": $id, "type": $t, "severity": "blocking", "summary": $s}')")")
    state=blocked
  fi
  if [[ -n "$blocker_id" ]]; then
    ops+=("$(_ordo_sched_op_append "$run_id" blocker.resolved "$(jq -cn --arg id "$blocker_id" '{"id": $id, "resolution": "requeued"}')")")
  fi
  _ordo_sched_check "$run_id" "$state" queued || return $?
  ops+=("$(_ordo_sched_op_append "$run_id" run.requeued \
    "$(jq -cn --arg r "$reason" --arg d "$detail" --arg nb "$not_before" --arg now "$now" --argjson delay "$delay" --argjson retries "$retries" '
      {"reason": $r, "detail": $d, "not_before": $nb, "backoff_seconds": $delay, "retries": $retries,
       "metadata": {"not_before": $nb, "requeued_at": $now, "requeue_reason": $r, "backoff_seconds": $delay, "blocker_id": null,
                    "lease_id": null, "lease_owner": null, "heartbeat_at": null, "wait_deadline": null}}')")")
  _ordo_sched_batch "${ops[@]}" >/dev/null || return $?
  _ordo_sched_audit "REQUEUED run=${run_id} reason=${reason} not_before=${not_before} backoff=${delay}s retries=${retries}"
  jq -cn --arg run_id "$run_id" --arg r "$reason" --arg nb "$not_before" --argjson delay "$delay" --argjson retries "$retries" \
    '{"run_id": $run_id, "action": "requeued", "reason": $r, "not_before": $nb, "backoff_seconds": $delay, "retries": $retries}'
}

# ---------------------------------------------------------------------------
# Tick — one scheduling pass
# ---------------------------------------------------------------------------
ordo_scheduler_tick() {
  _ordo_sched_parse_opts ordo_scheduler_tick "$@" || return $?
  local now now_epoch self
  now=$(ordo_journal_now)
  now_epoch=$(_ordo_sched_epoch "$now")
  self=$(ordo_scheduler_owner)
  # Report sections as bash arrays of compact JSON (assembled once at the end).
  local -a r_expired_leases=() r_requeued=() r_failed=() r_expired=() r_timed_out=() r_heartbeats=() r_picked=() r_skipped=() r_errors=()
  _err() { r_errors+=("$(jq -cn --arg run_id "$1" --arg step "$2" --argjson rc "$3" '{"run_id": $run_id, "step": $step, "rc": $rc}')"); }
  # _snap_of <run_id>: the snapshot held in the current view (empty when absent).
  _snap_of() { printf '%s' "$view" | jq -c --arg r "$1" '.runs[] | select(.run_id == $r)' | head -n 1; }

  # The read phase: ONE python3 process (stale leases + the non-terminal runs).
  local view changed=0
  view=$(ordo_journal_tick_view --now "$now" --state leased,running,queued,waiting,approval_required) || return $?

  # 1. Stale leases: sweep (one transaction), then requeue/fail their runs per policy.
  local stale lease run_id rc out runs_lines
  { IFS= read -r stale; runs_lines=$(cat); } < <(printf '%s' "$view" | jq -c '.stale_leases, .runs[]')
  if [[ "$stale" != "[]" ]]; then
    local ops swept
    ops=$(printf '%s' "$stale" | jq -c 'map({"op": "lease_expire", "lease_id": .lease_id, "lenient": true})')
    swept=$(ordo_journal_batch "$ops" --actor "$_OS_ACTOR_JSON") || return $?
    changed=1
    while IFS= read -r lease; do
      [[ -n "$lease" ]] || continue
      local lease_id owner
      { read -r run_id; read -r lease_id; read -r owner; } < <(printf '%s' "$lease" | jq -r '.run_id, .id, .owner')
      r_expired_leases+=("$(printf '%s' "$lease" | jq -c '{"run_id": .run_id, "lease_id": .id, "owner": .owner, "expires_at": .expires_at}')")
      rc=0
      _OS_RETRY_SNAP=$(_snap_of "$run_id")
      out=$(_ordo_sched_retry_or_fail "$run_id" lease_expired "$ORDO_SCHED_LEASE_EXPIRY_POLICY" "lease ${lease_id} of ${owner} expired") || rc=$?
      if [[ "$rc" -eq 0 && -n "$out" ]]; then
        case "$(printf '%s' "$out" | jq -r .action)" in
          requeued) r_requeued+=("$out") ;;
          failed|expired) r_failed+=("$out") ;;
        esac
      elif [[ "$rc" -ne 0 ]]; then
        _err "$run_id" expire "$rc"
      fi
    done < <(printf '%s' "$swept" | jq -c '.results[] | select(has("skipped") | not)')
  fi

  # 2. Per-run housekeeping: timeouts, owned heartbeats, queue/wait expiry.
  if [[ "$changed" == 1 ]]; then
    view=$(ordo_journal_tick_view --now "$now" --state leased,running,queued,waiting,approval_required) || return $?
    runs_lines=$(printf '%s' "$view" | jq -c '.runs[]')
    changed=0
  fi
  local snap state started deadline expires owner last hb_due
  while IFS= read -r snap; do
    [[ -n "$snap" ]] || continue
    _ordo_sched_snap_fields "$snap" "$now"
    run_id="$_SF_RUN_ID" state="$_SF_STATE"
    case "$state" in
      running)
        started="$_SF_STARTED"
        if [[ -n "$started" && "$ORDO_SCHED_RUN_TIMEOUT_SEC" -gt 0 ]] && (( now_epoch - $(_ordo_sched_epoch "$started") >= ORDO_SCHED_RUN_TIMEOUT_SEC )); then
          rc=0
          _OS_RETRY_SNAP="$snap" _OS_RETRY_RELEASE_LEASE="$_SF_LEASE_ID"
          out=$(_ordo_sched_retry_or_fail "$run_id" timeout "$ORDO_SCHED_TIMEOUT_POLICY" "active since ${started}, timeout ${ORDO_SCHED_RUN_TIMEOUT_SEC}s") || rc=$?
          changed=1
          if [[ "$rc" -eq 0 ]]; then
            r_timed_out+=("$(printf '%s' "$out" | jq -c --arg since "$started" '. + {"active_since": $since}')")
          else
            _err "$run_id" timeout "$rc"
          fi
          continue
        fi
        owner="$_SF_LEASE_OWNER"
        if [[ -z "$_SF_LEASE" ]]; then
          # Running without a live lease (sweep raced us): treat as lease loss.
          rc=0
          _OS_RETRY_SNAP="$snap"
          out=$(_ordo_sched_retry_or_fail "$run_id" lease_expired "$ORDO_SCHED_LEASE_EXPIRY_POLICY" "no live lease") || rc=$?
          changed=1
          if [[ "$rc" -eq 0 ]]; then r_requeued+=("$out"); else _err "$run_id" lease "$rc"; fi
          continue
        fi
        if [[ "$owner" == "$self" ]]; then
          last="$_SF_HB_TICK"
          hb_due=1
          if [[ -n "$last" ]] && (( now_epoch - $(_ordo_sched_epoch "$last") < ORDO_SCHED_HEARTBEAT_SEC )); then
            hb_due=0
          fi
          if [[ "$hb_due" == 1 ]]; then
            rc=0
            out=$(_ordo_sched_heartbeat_snap "$run_id" "$snap" "{}" 2>/dev/null) || rc=$?
            changed=1
            if [[ "$rc" -eq 0 ]]; then
              r_heartbeats+=("$(printf '%s' "$out" | jq -c '{"run_id": .run_id, "generation": .generation, "expires_at": .expires_at, "seconds_delta": .seconds_delta}')")
            elif [[ "$rc" -eq 7 ]]; then
              r_failed+=("$(jq -cn --arg run_id "$run_id" '{"run_id": $run_id, "action": "failed", "reason": "budget_exhausted"}')")
            else
              _err "$run_id" heartbeat "$rc"
            fi
          fi
        fi
        ;;
      leased)
        if [[ -z "$_SF_LEASE" ]]; then
          rc=0
          _OS_RETRY_SNAP="$snap"
          out=$(_ordo_sched_retry_or_fail "$run_id" lease_expired "$ORDO_SCHED_LEASE_EXPIRY_POLICY" "leased run without a live lease") || rc=$?
          changed=1
          if [[ "$rc" -eq 0 ]]; then r_requeued+=("$out"); else _err "$run_id" lease "$rc"; fi
        fi
        ;;
      queued)
        expires="$_SF_EXPIRES"
        if [[ -n "$expires" ]] && ! [[ "$expires" > "$now" ]]; then
          rc=0
          _ordo_sched_emit "$run_id" queued expired run.expired \
            "$(jq -cn --arg e "$expires" --arg now "$now" '{"reason": "queue_ttl", "expires_at": $e, "metadata": {"finished_at": $now, "failure_reason": "queue_ttl"}}')" || rc=$?
          changed=1
          if [[ "$rc" -eq 0 ]]; then
            r_expired+=("$(jq -cn --arg run_id "$run_id" --arg e "$expires" '{"run_id": $run_id, "reason": "queue_ttl", "expires_at": $e}')")
          else
            _err "$run_id" expire "$rc"
          fi
        fi
        ;;
      waiting|approval_required)
        deadline="$_SF_DEADLINE"
        if [[ -n "$deadline" ]] && ! [[ "$deadline" > "$now" ]]; then
          rc=0
          _ordo_sched_emit "$run_id" "$state" expired run.expired \
            "$(jq -cn --arg d "$deadline" --arg now "$now" --arg from "$state" '{"reason": "wait_timeout", "from": $from, "wait_deadline": $d, "metadata": {"finished_at": $now, "failure_reason": "wait_timeout"}}')" || rc=$?
          changed=1
          if [[ "$rc" -eq 0 ]]; then
            r_expired+=("$(jq -cn --arg run_id "$run_id" --arg from "$state" --arg d "$deadline" '{"run_id": $run_id, "reason": "wait_timeout", "from": $from, "wait_deadline": $d}')")
          else
            _err "$run_id" expire "$rc"
          fi
        fi
        ;;
    esac
  done <<<"$runs_lines"

  # 3. Picks: capacity = fan-out minus slots in use; priority then FIFO.
  if [[ "$changed" == 1 ]]; then
    view=$(ordo_journal_tick_view --now "$now" --state queued) || return $?
  fi
  local used capacity picks=0 max_picks="${_OS_MAX_PICKS:-}" candidate not_before verdict states_map
  used=$(printf '%s' "$view" | jq -r '.slots_used')
  states_map=$(printf '%s' "$view" | jq -c '.states')
  capacity=$(( ORDO_SCHED_MAX_FANOUT - used ))
  (( capacity < 0 )) && capacity=0
  if [[ -n "$max_picks" ]] && (( max_picks < capacity )); then
    capacity=$max_picks
  fi
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    _ordo_sched_snap_fields "$candidate" "$now"
    run_id="$_SF_RUN_ID"
    if (( picks >= capacity )); then
      r_skipped+=("$(jq -cn --arg run_id "$run_id" '{"run_id": $run_id, "reason": "capacity_exhausted"}')")
      continue
    fi
    not_before="$_SF_NOT_BEFORE"
    if [[ -n "$not_before" && "$not_before" > "$now" ]]; then
      r_skipped+=("$(jq -cn --arg run_id "$run_id" --arg nb "$not_before" '{"run_id": $run_id, "reason": "not_before", "not_before": $nb}')")
      continue
    fi
    snap=$candidate                                   # the listing row is the stored projection
    local ready_verdict
    { IFS= read -r verdict; IFS= read -r ready_verdict; } < <(_ordo_sched_pick_verdicts "$snap" "$states_map")
    if _ordo_sched_exhausted "$verdict"; then
      if _ordo_sched_fail_budget "$run_id" "$snap" "$verdict" 2>/dev/null; then :; else
        # exit 7 is the expected outcome; the run is expired (a dependant evaluated later sees it)
        states_map="${states_map%\}},\"${run_id}\":\"expired\"}"
      fi
      r_failed+=("$(printf '%s' "$verdict" | jq -c --arg run_id "$run_id" '{"run_id": $run_id, "action": "expired", "reason": "budget_exhausted", "exhausted": .exhausted}')")
      continue
    fi
    verdict="$ready_verdict"
    if [[ "$verdict" != '{"ready":true,'* ]]; then
      r_skipped+=("$(printf '%s' "$verdict" | jq -c --arg run_id "$run_id" '{"run_id": $run_id, "reason": .reason, "checks": .checks}')")
      continue
    fi
    rc=0
    out=$(_ordo_sched_acquire_and_start "$run_id" "$snap" start 2>/dev/null) || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      picks=$((picks + 1))
      # Dependants evaluated later in this loop see the run as running (the
      # state ordo_journal_state would report now); a later duplicate key wins in jq.
      states_map="${states_map%\}},\"${run_id}\":\"running\"}"
      r_picked+=("${out%\}},\"priority\":${_SF_PRIORITY}}")   # `. + {"priority": p}` on the compact pick object
    elif [[ "$rc" -eq 5 ]]; then
      r_skipped+=("$(jq -cn --arg run_id "$run_id" '{"run_id": $run_id, "reason": "leased_elsewhere"}')")
    else
      _err "$run_id" start "$rc"
    fi
  done < <(printf '%s' "$view" | jq -c --argjson dp "$ORDO_SCHED_DEFAULT_PRIORITY" \
    '.runs | map(select(.state == "queued")) | map(.metadata.priority = ((.metadata.priority // $dp) | tonumber)) | sort_by(.metadata.priority) | .[]')
  local report j_expired_leases j_requeued j_failed j_expired j_timed_out j_heartbeats j_picked j_skipped j_errors
  _ordo_sched_join j_expired_leases "${r_expired_leases[@]+"${r_expired_leases[@]}"}"
  _ordo_sched_join j_requeued "${r_requeued[@]+"${r_requeued[@]}"}"
  _ordo_sched_join j_failed "${r_failed[@]+"${r_failed[@]}"}"
  _ordo_sched_join j_expired "${r_expired[@]+"${r_expired[@]}"}"
  _ordo_sched_join j_timed_out "${r_timed_out[@]+"${r_timed_out[@]}"}"
  _ordo_sched_join j_heartbeats "${r_heartbeats[@]+"${r_heartbeats[@]}"}"
  _ordo_sched_join j_picked "${r_picked[@]+"${r_picked[@]}"}"
  _ordo_sched_join j_skipped "${r_skipped[@]+"${r_skipped[@]}"}"
  _ordo_sched_join j_errors "${r_errors[@]+"${r_errors[@]}"}"
  report=$(jq -cn --arg now "$now" --arg self "$self" --argjson fanout "$ORDO_SCHED_MAX_FANOUT" \
    --argjson expired_leases "$j_expired_leases" --argjson requeued "$j_requeued" --argjson failed "$j_failed" \
    --argjson expired "$j_expired" --argjson timed_out "$j_timed_out" --argjson heartbeats "$j_heartbeats" \
    --argjson picked "$j_picked" --argjson skipped "$j_skipped" --argjson errors "$j_errors" \
    --argjson used "$used" --argjson cap "$capacity" --argjson picks "$picks" \
    '{"now": $now, "worker": $self, "max_fanout": $fanout, "expired_leases": $expired_leases, "requeued": $requeued,
      "failed": $failed, "expired": $expired, "timed_out": $timed_out, "heartbeats": $heartbeats, "picked": $picked,
      "skipped": $skipped, "errors": $errors, "slots_used_before": $used, "capacity": $cap, "picks": $picks}')
  _ordo_sched_audit "TICK worker=${self} slots_used=${used} capacity=${capacity} picked=${picks} expired_leases=${#r_expired_leases[@]} requeued=${#r_requeued[@]} failed=${#r_failed[@]} errors=${#r_errors[@]}"
  unset -f _err _snap_of
  printf '%s\n' "$report"
}

# ---------------------------------------------------------------------------
# Crash recovery
# ---------------------------------------------------------------------------
# _ordo_sched_owner_alive <owner> -> 0 alive, 1 dead (local host), 2 unknown (remote / unparsable)
_ordo_sched_owner_alive() {
  local owner="$1" host pid
  if [[ "$owner" =~ ^(.+)@([^@:]+):([0-9]+)$ ]]; then
    host="${BASH_REMATCH[2]}"; pid="${BASH_REMATCH[3]}"
  else
    return 2
  fi
  [[ "$host" == "$(_ordo_sched_host)" ]] || return 2
  kill -0 "$pid" 2>/dev/null && return 0
  return 1
}

ordo_scheduler_recover() {
  _ordo_sched_parse_opts ordo_scheduler_recover "$@" || return $?
  local rebuilt swept now
  rebuilt=$(ordo_journal_rebuild_all) || return $?
  now=$(ordo_journal_now)
  swept=$(ordo_journal_lease_expire_stale --actor "$_OS_ACTOR_JSON") || return $?
  local -a r_reconciled=() r_remote=() r_repaired=() r_errors=()
  local lease run_id rc out
  while IFS= read -r lease; do
    [[ -n "$lease" ]] || continue
    run_id=$(printf '%s' "$lease" | jq -r .run_id)
    rc=0
    out=$(_ordo_sched_retry_or_fail "$run_id" lease_expired "$ORDO_SCHED_LEASE_EXPIRY_POLICY" "expired during recovery" --no-backoff) || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      r_reconciled+=("$(printf '%s' "$out" | jq -c '. + {"cause": "lease_expired"}')")
    else
      r_errors+=("$(jq -cn --arg run_id "$run_id" --argjson rc "$rc" '{"run_id": $run_id, "rc": $rc}')")
    fi
  done < <(printf '%s' "$swept" | jq -c '.expired[]?')
  local snap state owner lease_id alive
  while IFS= read -r snap; do
    [[ -n "$snap" ]] || continue
    _ordo_sched_snap_fields "$snap" "$now"
    run_id="$_SF_RUN_ID" state="$_SF_STATE"
    [[ -n "$_SF_LEASE" ]] || continue
    owner="$_SF_LEASE_OWNER" lease_id="$_SF_LEASE_ID"
    case "$state" in
      waiting|blocked|approval_required)
        # Invariant repair: a parked run never holds a lease.
        _ordo_sched_batch "$(_ordo_sched_op_release "$lease_id")" >/dev/null 2>&1 || true
        r_repaired+=("$(jq -cn --arg run_id "$run_id" --arg state "$state" --arg lease "$lease_id" '{"run_id": $run_id, "state": $state, "released_lease_id": $lease}')")
        continue
        ;;
      leased|running) ;;
      *) continue ;;
    esac
    alive=0
    _ordo_sched_owner_alive "$owner" || alive=$?
    case "$alive" in
      0) continue ;;
      2) r_remote+=("$(jq -cn --arg run_id "$run_id" --arg owner "$owner" '{"run_id": $run_id, "owner": $owner, "action": "left_to_lease_ttl"}')"); continue ;;
    esac
    rc=0
    _OS_RETRY_SNAP="$snap" _OS_RETRY_RELEASE_LEASE="$lease_id"
    out=$(_ordo_sched_retry_or_fail "$run_id" owner_dead "$ORDO_SCHED_LEASE_EXPIRY_POLICY" "owner ${owner} is not running" --no-backoff) || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      r_reconciled+=("$(printf '%s' "$out" | jq -c --arg owner "$owner" --arg lease "$lease_id" '. + {"owner": $owner, "released_lease_id": $lease}')")
    else
      r_errors+=("$(jq -cn --arg run_id "$run_id" --argjson rc "$rc" '{"run_id": $run_id, "rc": $rc}')")
    fi
  done < <(ordo_journal_runs --state leased,running,waiting,blocked,approval_required)
  local report j_reconciled j_remote j_repaired j_errors
  _ordo_sched_join j_reconciled "${r_reconciled[@]+"${r_reconciled[@]}"}"
  _ordo_sched_join j_remote "${r_remote[@]+"${r_remote[@]}"}"
  _ordo_sched_join j_repaired "${r_repaired[@]+"${r_repaired[@]}"}"
  _ordo_sched_join j_errors "${r_errors[@]+"${r_errors[@]}"}"
  report=$(jq -cn --arg now "$now" --arg host "$(_ordo_sched_host)" --argjson rebuilt "$(printf '%s' "$rebuilt" | jq '.rebuilt')" \
    --argjson swept "$(printf '%s' "$swept" | jq '.count')" \
    --argjson reconciled "$j_reconciled" --argjson remote "$j_remote" \
    --argjson repaired "$j_repaired" --argjson errors "$j_errors" \
    '{"now": $now, "host": $host, "rebuilt": $rebuilt, "expired_leases": $swept, "reconciled": $reconciled, "remote": $remote, "repaired": $repaired, "errors": $errors}')
  _ordo_sched_audit "RECOVER rebuilt=$(printf '%s' "$rebuilt" | jq -r .rebuilt) reconciled=${#r_reconciled[@]} repaired=${#r_repaired[@]} remote=${#r_remote[@]}"
  printf '%s\n' "$report"
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
ordo_scheduler_status() {
  local run_id="${1-}"
  if [[ -n "$run_id" ]]; then
    _ordo_sched_require_run_id "$run_id" || return $?
    local snap lease
    snap=$(_ordo_sched_snap "$run_id") || return $?
    lease=$(_ordo_sched_live_lease "$snap")
    [[ -n "$lease" ]] || lease=null
    jq -cn --argjson snap "$snap" --argjson budgets "$(_ordo_sched_budget_json "$snap")" \
      --argjson ready "$(_ordo_sched_ready_json "$snap")" --argjson lease "$lease" \
      '{"run_id": $snap.run_id, "state": $snap.state, "terminal": $snap.terminal, "title": $snap.title, "ticket_ref": $snap.ticket_ref,
        "priority": $snap.metadata.priority, "not_before": $snap.metadata.not_before, "lease": $lease,
        "attempts": $snap.budgets.attempts_used, "budgets": $budgets, "readiness": $ready,
        "blockers_open": $snap.counters.blockers_open, "updated_at": $snap.updated_at, "metadata": $snap.metadata}'
    return 0
  fi
  local now view
  now=$(ordo_journal_now)
  view=$(ordo_journal_tick_view --now "$now") || return $?
  printf '%s' "$view" | jq -c --arg now "$now" --arg self "$(ordo_scheduler_owner)" --argjson max "$ORDO_SCHED_MAX_FANOUT" '
    .slots_used as $used | .runs |
    {"now": $now, "worker": $self,
     "capacity": {"max_fanout": $max, "in_use": $used, "available": ([$max - $used, 0] | max)},
     "counts": (group_by(.state) | map({(.[0].state): length}) | add // {}),
     "runs": map({"run_id": .run_id, "state": .state, "title": .title, "priority": .metadata.priority,
                  "not_before": .metadata.not_before, "attempts": .budgets.attempts_used,
                  "lease": (.lease | if . != null and (.state == "acquired" or .state == "active" or .state == "renewed") and (.expires_at > $now)
                                     then {"id": .id, "owner": .owner, "expires_at": .expires_at} else null end),
                  "exhausted": .budgets.exhausted, "blockers_open": .counters.blockers_open})}'
}
