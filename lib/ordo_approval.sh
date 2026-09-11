#!/usr/bin/env bash
# lib/ordo_approval.sh — approval-safe actions: typed approval records, the
# action authorization bridge and idempotent external mutations (#812, epic #806).
#
# An approval is a contract `approval` object persisted in the journal
# (lib/ordo_journal.sh), tied to a run, an action, a principal, a policy
# version and an expiry. Its lifecycle is the contracts table
# `pending -> granted | denied | expired`, `granted -> consumed | expired`.
# Only deterministic code decides: a model actor can never grant, and a model
# actor can never execute through the bridge.
#
# The bridge (`ordo_approval_authorize_and_run`) re-authorizes the action
# IMMEDIATELY before executing it — approval granted and not expired NOW,
# policy version still current, principal allowed for the action, run not
# terminal, provider op bound to the approved action — records a
# `policy_decision` event for the verdict, then executes through
# `ordo_provider` (lib/ordo_provider_adapter.sh) with the approval's
# idempotency key and marks the approval consumed with the mutation receipt.
# A second authorization of the same approval returns the recorded receipt
# with details.replayed=true and never calls the provider again.
#
# Live autonomous mutation stays OFF: the provider adapter still asserts
# ORCH_EXTERNAL_PR_MUTATIONS (lib/external_mutation_gate.sh). An approval
# does not widen that policy; it adds a second, per-action, human gate.
#
# Public API:
#   ordo_approval_request <run_id> <action> --principal P --idempotency-key K
#                         [--policy-version V] [--ttl S] [--payload JSON] [--actor JSON]
#   ordo_approval_get <approval_id>
#   ordo_approval_list <run_id> [--state S]
#   ordo_approval_grant <approval_id> [--by ACTOR] [--reason R]     # actor type operator|system only
#   ordo_approval_deny  <approval_id> [--by ACTOR] [--reason R]     # operator|system|agent
#   ordo_approval_sweep [--run-id R] [--actor JSON]                  # pending/granted past expires_at -> expired
#   ordo_approval_authorize_and_run <approval_id> [--actor JSON] -- <provider op> [args...]
#   ordo_approval_policy_version                                     # ORDO_POLICY_VERSION or gate-<hash>
#   ordo_approval_actor_json [SPEC]                                  # SPEC: JSON | type:id | id (=> operator)
#   ordo_approval_principal_allowed <principal> <action> [scope]
#
# Knobs:
#   ORDO_POLICY_VERSION        explicit policy version; when empty it is computed
#                              from the mutation-gate configuration (see
#                              ordo_approval_policy_version) so any policy edit
#                              invalidates approvals granted under the old one
#   ORDO_APPROVAL_PRINCIPALS   allow-list "p1=action1|action2,p2,*=pr.comment";
#                              a bare principal allows every action; empty list
#                              => the gate semantics decide (the action's scope
#                              must be in ORCH_EXTERNAL_PR_MUTATIONS)
#   ORDO_APPROVAL_DEFAULT_TTL  seconds before a fresh approval expires (3600)
#   ORDO_ACTOR                 default actor JSON for grant/deny/execute
#   ORDO_OPERATOR              operator id used when no actor is given ($USER)
#
# Journal event types written by this module (never `approval.*`, which the
# journal fold reserves for state changes):
#   approval_bridge.requested         request + pinned payload
#   policy.decided                    full policy_decision object (allow|deny)
#   approval_bridge.executed          mutation=true, carries the idempotency key
#   approval_bridge.execution_failed  provider refused/failed; approval stays granted
#
# Errors: ONE JSON line on stderr {"error":{"code","message","module":"approval","details"}}
# and the contract exit code: 2 usage, 3 policy_refused, 4 not_found,
# 5 invalid_state/conflict, 6 provider not available.
# Full reference: docs/architecture/approvals.md.

if [[ -n "${ORDO_APPROVAL_LIB_LOADED:-}" ]]; then
  return 0
fi
ORDO_APPROVAL_LIB_LOADED=1

_ORDO_APPROVAL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F ordo_journal_approval_create >/dev/null 2>&1; then
  # shellcheck source=lib/ordo_journal.sh
  source "$_ORDO_APPROVAL_LIB_DIR/ordo_journal.sh"
fi
if ! declare -F ordo_provider >/dev/null 2>&1; then
  # shellcheck source=lib/ordo_provider_adapter.sh
  source "$_ORDO_APPROVAL_LIB_DIR/ordo_provider_adapter.sh"
fi
if ! declare -F ordo_trace_start >/dev/null 2>&1; then
  # shellcheck source=lib/ordo_trace.sh
  source "$_ORDO_APPROVAL_LIB_DIR/ordo_trace.sh"
fi

ORDO_APPROVAL_MODULE="approval"
ORDO_APPROVAL_POLICY_NAME="approval_bridge"
ORDO_APPROVAL_DECIDER_TYPES="operator system"
ORDO_APPROVAL_DENIER_TYPES="operator system agent"
ORDO_APPROVAL_EXECUTOR_TYPES="operator system agent"
: "${ORDO_APPROVAL_DEFAULT_TTL:=3600}"
: "${ORDO_APPROVAL_PRINCIPALS:=}"
: "${ORDO_POLICY_VERSION:=}"
: "${ORDO_ACTOR:=}"

_ordo_approval_fail() {
  ordo_contracts_error "$ORDO_APPROVAL_MODULE" "$@"
}

# ---------------------------------------------------------------------------
# Policy version, actors, principals
# ---------------------------------------------------------------------------
# ORDO_POLICY_VERSION when set; otherwise "gate-<16 hex>" hashed from every
# input that changes what the bridge would allow.
ordo_approval_policy_version() {
  if [[ -n "${ORDO_POLICY_VERSION:-}" ]]; then
    printf '%s\n' "$ORDO_POLICY_VERSION"
    return 0
  fi
  local digest
  digest=$(printf 'external_mutations=%s\nprincipals=%s\nadapter=%s\nscopes=%s\n' \
    "${ORCH_EXTERNAL_PR_MUTATIONS:-}" "${ORDO_APPROVAL_PRINCIPALS:-}" "$(ordo_provider_adapter_name)" \
    "$(external_pr_mutation_known_scopes | paste -sd, -)" | sha256sum | cut -c1-16)
  printf 'gate-%s\n' "$digest"
}

# ordo_approval_actor_json [SPEC]
#   SPEC may be a JSON actor object, "type:id", or a bare id (=> operator).
#   Falls back to ORDO_ACTOR, then to operator ${ORDO_OPERATOR:-$USER}.
ordo_approval_actor_json() {
  local spec="${1:-${ORDO_ACTOR:-}}" json
  if [[ -z "$spec" ]]; then
    spec="operator:${ORDO_OPERATOR:-${USER:-operator}}"
  fi
  case "$spec" in
    \{*)
      if ! json=$(printf '%s' "$spec" | jq -c 'select(type == "object")' 2>/dev/null) || [[ -z "$json" ]]; then
        _ordo_approval_fail bad_argument "actor must be a JSON object {\"type\",\"id\"}" "$(jq -cn --arg s "$spec" '{"actor": ($s | .[0:120])}')"
        return $?
      fi
      ;;
    *:*)
      json=$(jq -cn --arg t "${spec%%:*}" --arg i "${spec#*:}" '{"type": $t, "id": $i}')
      ;;
    *)
      json=$(jq -cn --arg i "$spec" '{"type": "operator", "id": $i}')
      ;;
  esac
  if ! printf '%s' "$json" | jq -e '(.type | IN("operator","agent","system","model")) and ((.id | type) == "string") and ((.id | length) > 0)' >/dev/null 2>&1; then
    _ordo_approval_fail bad_argument "actor needs type operator|agent|system|model and a non-empty id" \
      "$(printf '%s' "$json" | jq -c '{"actor": .}')"
    return $?
  fi
  printf '%s\n' "$json"
}

_ordo_approval_actor_type() {
  printf '%s' "$1" | jq -r '.type'
}

_ordo_approval_type_in() {
  # <type> <allowed list>
  local t="$1" allowed="$2" a
  for a in $allowed; do
    [[ "$a" == "$t" ]] && return 0
  done
  return 1
}

_ordo_approval_norm_action() {
  # pr.merge and pr_merge name the same action.
  printf '%s' "${1//./_}"
}

# ordo_approval_principal_allowed <principal> <action> [scope]
#   0 allowed, 1 not allowed. With an empty ORDO_APPROVAL_PRINCIPALS the
#   gate semantics decide: the action's mutation scope must be authorised.
ordo_approval_principal_allowed() {
  local principal="${1-}" action="${2-}" scope="${3-}"
  [[ -n "$principal" && -n "$action" ]] || return 1
  local list="${ORDO_APPROVAL_PRINCIPALS:-}"
  if [[ -z "$list" ]]; then
    [[ -n "$scope" ]] || return 1
    external_pr_mutation_authorized "$scope"
    return $?
  fi
  local want entry p actions a
  want=$(_ordo_approval_norm_action "$action")
  local IFS=','
  for entry in $list; do
    entry="${entry## }"
    entry="${entry%% }"
    [[ -n "$entry" ]] || continue
    p="${entry%%=*}"
    if [[ "$entry" == *=* ]]; then actions="${entry#*=}"; else actions=""; fi
    [[ "$p" == "$principal" || "$p" == "*" ]] || continue
    [[ -n "$actions" ]] || return 0
    local IFS='|'
    for a in $actions; do
      [[ "$(_ordo_approval_norm_action "$a")" == "$want" ]] && return 0
    done
    IFS=','
  done
  return 1
}

# ---------------------------------------------------------------------------
# Time helpers (clock: ordo_journal_now, pinned by ORDO_JOURNAL_NOW in tests)
# ---------------------------------------------------------------------------
_ordo_approval_epoch() {
  date -u -d "$1" +%s 2>/dev/null
}

# _ordo_approval_expired_now <approval-json> -> 0 when expires_at <= now
_ordo_approval_expired_now() {
  local expires now e n
  expires=$(printf '%s' "$1" | jq -r '.expires_at // empty')
  [[ -n "$expires" ]] || return 1
  now=$(ordo_journal_now)
  e=$(_ordo_approval_epoch "$expires") || return 1
  n=$(_ordo_approval_epoch "$now") || return 1
  [[ "$n" -ge "$e" ]]
}

# ---------------------------------------------------------------------------
# Journal helpers
# ---------------------------------------------------------------------------
_ordo_approval_payload_for() {
  # <run_id> <approval_id> -> pinned payload JSON (object) or {}
  local found
  found=$(ordo_journal_events "$1" 2>/dev/null | jq -c --arg id "$2" \
    'select(.type == "approval_bridge.requested" and .payload.approval_id == $id) | .payload.payload // {}' | tail -n 1)
  printf '%s\n' "${found:-\{\}}"
}

_ordo_approval_with_payload() {
  # <approval-json> -> approval + {"payload": ...}
  local approval="$1" run_id id payload
  run_id=$(printf '%s' "$approval" | jq -r '.run_id')
  id=$(printf '%s' "$approval" | jq -r '.id')
  payload=$(_ordo_approval_payload_for "$run_id" "$id")
  printf '%s' "$approval" | jq -c --argjson p "$payload" '. + {"payload": $p}'
}

_ordo_approval_load() {
  # <approval_id> -> approval JSON (exit 4 when unknown, message under this module)
  local approval_id="$1" approval rc=0
  if [[ ! "$approval_id" =~ ^approval_[0-9a-f]{24}$ ]]; then
    _ordo_approval_fail bad_argument "approval_id must be a canonical approval id (approval_<24 hex>): '${approval_id}'" \
      "$(jq -cn --arg id "$approval_id" '{"approval_id": $id}')"
    return $?
  fi
  approval=$(ordo_journal_approval_get "$approval_id" 2>/dev/null) || rc=$?
  if [[ "$rc" -ne 0 || -z "$approval" ]]; then
    _ordo_approval_fail not_found "unknown approval ${approval_id}" "$(jq -cn --arg id "$approval_id" '{"approval_id": $id}')"
    return $?
  fi
  printf '%s\n' "$approval"
}

# _ordo_approval_record_decision <run_id> <subject> <decision> <reasons-json> <approval_id> <actor-json> [metadata-json]
#   Builds, validates and journals a policy_decision object (event type
#   policy.decided). Prints the object.
_ordo_approval_record_decision() {
  local run_id="$1" subject="$2" decision="$3" reasons="$4" approval_id="$5" actor="$6" metadata="${7:-{\}}"
  local id now version decision_obj
  id=$(ordo_contracts_new_id policy_decision) || return $?
  now=$(ordo_journal_now)
  version=$(ordo_approval_policy_version)
  decision_obj=$(jq -cn --arg id "$id" --arg now "$now" --arg run_id "$run_id" --argjson actor "$actor" \
    --arg policy "$ORDO_APPROVAL_POLICY_NAME" --arg version "$version" --arg subject "$subject" \
    --arg decision "$decision" --argjson reasons "$reasons" --arg approval_id "$approval_id" --argjson metadata "$metadata" '
    {"schema_version": "1", "kind": "policy_decision", "id": $id, "created_at": $now, "correlation_id": $run_id,
     "actor": $actor, "run_id": $run_id, "policy": $policy, "policy_version": $version, "subject": $subject,
     "decision": $decision, "reasons": $reasons, "approval_id": $approval_id, "metadata": $metadata}')
  decision_obj=$(ordo_trace_redact "$decision_obj")
  ordo_contracts_validate policy_decision "$decision_obj" || return $?
  ordo_journal_append "$run_id" policy.decided "$decision_obj" --actor "$actor" >/dev/null || return $?
  if [[ -n "${_OA_POLICY_SPAN:-}" ]]; then
    ordo_trace_event "$_OA_POLICY_SPAN" "policy.decided" --trace "${_OA_TRACE:-}" \
      --attr "policy.decision=$decision" --attr "policy.reasons=$(printf '%s' "$reasons" | jq -r 'join(",")')" >/dev/null 2>&1 || true
  fi
  printf '%s\n' "$decision_obj"
}

# _ordo_approval_refuse <run_id> <subject> <reason> <approval_id> <actor> <message> [details-json]
#   Records a deny decision then fails with policy_refused (exit 3).
_ordo_approval_refuse() {
  local run_id="$1" subject="$2" reason="$3" approval_id="$4" actor="$5" message="$6" details="${7:-{\}}"
  local decision
  decision=$(_ordo_approval_record_decision "$run_id" "$subject" deny "$(jq -cn --arg r "$reason" '[$r]')" "$approval_id" "$actor" "$details") || true
  local merged
  merged=$(printf '%s' "$details" | jq -c --arg reason "$reason" --arg approval_id "$approval_id" --arg run_id "$run_id" \
    --arg decision_id "$(printf '%s' "$decision" | jq -r '.id // empty')" \
    '. + {"reason": $reason, "approval_id": $approval_id, "run_id": $run_id, "decision": "deny"}
       + (if $decision_id == "" then {} else {"policy_decision_id": $decision_id} end)')
  _ordo_approval_fail policy_refused "$message" "$merged"
}

# ---------------------------------------------------------------------------
# Requests, decisions, listing, sweep
# ---------------------------------------------------------------------------
_ordo_approval_parse_opts() {
  _OA_PRINCIPAL="" _OA_POLICY_VERSION="" _OA_KEY="" _OA_TTL="" _OA_PAYLOAD="" _OA_ACTOR="" _OA_BY="" _OA_REASON="" _OA_STATE="" _OA_RUN_ID=""
  local fn="$1"; shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --principal) _OA_PRINCIPAL="${2-}"; shift 2 ;;
      --policy-version) _OA_POLICY_VERSION="${2-}"; shift 2 ;;
      --idempotency-key|-k) _OA_KEY="${2-}"; shift 2 ;;
      --ttl) _OA_TTL="${2-}"; shift 2 ;;
      --payload) _OA_PAYLOAD="${2-}"; shift 2 ;;
      --actor) _OA_ACTOR="${2-}"; shift 2 ;;
      --by) _OA_BY="${2-}"; shift 2 ;;
      --reason) _OA_REASON="${2-}"; shift 2 ;;
      --state) _OA_STATE="${2-}"; shift 2 ;;
      --run-id) _OA_RUN_ID="${2-}"; shift 2 ;;
      *)
        _ordo_approval_fail usage "unknown option for ${fn}: ${1}" "$(jq -cn --arg opt "$1" '{"option": $opt}')"
        return $?
        ;;
    esac
  done
  if [[ -n "$_OA_TTL" && ! "$_OA_TTL" =~ ^[1-9][0-9]*$ ]]; then
    _ordo_approval_fail bad_argument "--ttl expects a positive integer number of seconds" "$(jq -cn --arg v "$_OA_TTL" '{"ttl": $v}')"
    return $?
  fi
}

# ordo_approval_request <run_id> <action> --principal P --idempotency-key K
#                       [--policy-version V] [--ttl S] [--payload JSON] [--actor JSON]
ordo_approval_request() {
  local run_id="${1-}" action="${2-}"
  if [[ $# -lt 2 || -z "$run_id" || -z "$action" ]]; then
    _ordo_approval_fail usage "usage: ordo_approval_request <run_id> <action> --principal P --idempotency-key K [--policy-version V] [--ttl S] [--payload JSON] [--actor JSON]"
    return $?
  fi
  shift 2
  _ordo_approval_parse_opts ordo_approval_request "$@" || return $?
  if [[ -z "$_OA_PRINCIPAL" || -z "$_OA_KEY" ]]; then
    _ordo_approval_fail usage "ordo_approval_request requires --principal and --idempotency-key" \
      "$(jq -cn --arg p "$_OA_PRINCIPAL" --arg k "$_OA_KEY" '{"missing": [(if $p == "" then "principal" else empty end), (if $k == "" then "idempotency_key" else empty end)]}')"
    return $?
  fi
  local actor
  actor=$(ordo_approval_actor_json "$_OA_ACTOR") || return $?
  local payload
  if [[ -n "$_OA_PAYLOAD" ]]; then
    if ! payload=$(printf '%s' "$_OA_PAYLOAD" | jq -c 'select(type == "object")' 2>/dev/null) || [[ -z "$payload" ]]; then
      _ordo_approval_fail invalid_json "--payload must be a JSON object" "$(jq -cn --arg p "$_OA_PAYLOAD" '{"payload": ($p | .[0:200])}')"
      return $?
    fi
    payload=$(ordo_trace_redact "$payload")
  else
    payload='{}'
  fi
  # Fail-closed on the run: it must exist in the journal and not be terminal.
  local state
  state=$(ordo_journal_state "$run_id") || return $?
  if ordo_contracts_is_terminal run "$state" 2>/dev/null; then
    _ordo_approval_fail invalid_state "run ${run_id} is ${state} (terminal); nothing left to approve" \
      "$(jq -cn --arg run_id "$run_id" --arg state "$state" '{"run_id": $run_id, "state": $state}')"
    return $?
  fi
  local version approval
  version="${_OA_POLICY_VERSION:-$(ordo_approval_policy_version)}"
  approval=$(ordo_journal_approval_create "$run_id" "$action" "$_OA_PRINCIPAL" \
    --policy-version "$version" --idempotency-key "$_OA_KEY" --ttl "${_OA_TTL:-$ORDO_APPROVAL_DEFAULT_TTL}" --actor "$actor") || return $?
  local id
  id=$(printf '%s' "$approval" | jq -r '.id')
  ordo_journal_append "$run_id" approval_bridge.requested \
    "$(printf '%s' "$approval" | jq -c --argjson p "$payload" '{"approval_id": .id, "action": .action, "principal": .principal, "policy_version": .policy_version, "expires_at": .expires_at, "payload": $p}')" \
    --actor "$actor" >/dev/null || return $?
  printf '%s' "$approval" | jq -c --argjson p "$payload" '. + {"payload": $p}'
}

ordo_approval_get() {
  local approval_id="${1-}"
  if [[ -z "$approval_id" ]]; then
    _ordo_approval_fail usage "usage: ordo_approval_get <approval_id>"
    return $?
  fi
  local approval
  approval=$(_ordo_approval_load "$approval_id") || return $?
  _ordo_approval_with_payload "$approval"
}

ordo_approval_list() {
  local run_id="${1-}"
  if [[ -z "$run_id" ]]; then
    _ordo_approval_fail usage "usage: ordo_approval_list <run_id> [--state S]"
    return $?
  fi
  shift
  _ordo_approval_parse_opts ordo_approval_list "$@" || return $?
  local rows
  if [[ -n "$_OA_STATE" ]]; then
    rows=$(ordo_journal_approval_list "$run_id" --state "$_OA_STATE") || return $?
  else
    rows=$(ordo_journal_approval_list "$run_id") || return $?
  fi
  [[ -n "$rows" ]] || return 0
  local events
  events=$(ordo_journal_events "$run_id" 2>/dev/null | jq -c 'select(.type == "approval_bridge.requested") | {"id": .payload.approval_id, "payload": (.payload.payload // {})}' | jq -sc 'map({(.id): .payload}) | add // {}')
  printf '%s\n' "$rows" | jq -c --argjson payloads "$events" '. + {"payload": ($payloads[.id] // {})}'
}

# _ordo_approval_decide <granted|denied> <approval_id> [--by ACTOR] [--reason R] [--actor JSON]
_ordo_approval_decide() {
  local to="$1" approval_id="${2-}"
  if [[ -z "$approval_id" ]]; then
    _ordo_approval_fail usage "usage: ordo_approval_grant|deny <approval_id> [--by ACTOR] [--reason R]"
    return $?
  fi
  shift 2
  _ordo_approval_parse_opts "ordo_approval_${to}" "$@" || return $?
  local actor atype
  actor=$(ordo_approval_actor_json "${_OA_BY:-$_OA_ACTOR}") || return $?
  atype=$(_ordo_approval_actor_type "$actor")
  local approval run_id state action principal
  approval=$(_ordo_approval_load "$approval_id") || return $?
  run_id=$(printf '%s' "$approval" | jq -r '.run_id')
  state=$(printf '%s' "$approval" | jq -r '.state')
  action=$(printf '%s' "$approval" | jq -r '.action')
  principal=$(printf '%s' "$approval" | jq -r '.principal')
  local subject="decide:${to}:${action}"
  local allowed_types verb
  if [[ "$to" == granted ]]; then allowed_types="$ORDO_APPROVAL_DECIDER_TYPES" verb=grant; else allowed_types="$ORDO_APPROVAL_DENIER_TYPES" verb=deny; fi
  if ! _ordo_approval_type_in "$atype" "$allowed_types"; then
    _ordo_approval_refuse "$run_id" "$subject" "actor_type_not_allowed" "$approval_id" "$actor" \
      "an actor of type '${atype}' may not ${verb} approvals (allowed: ${allowed_types// /|}); models never decide" \
      "$(jq -cn --arg t "$atype" --arg allowed "$allowed_types" --argjson actor "$actor" '{"actor": $actor, "actor_type": $t, "allowed_types": ($allowed | split(" "))}')"
    return $?
  fi
  if [[ "$state" != pending ]]; then
    _ordo_approval_fail invalid_state "approval ${approval_id} is ${state}, not pending" \
      "$(jq -cn --arg id "$approval_id" --arg state "$state" --arg to "$to" '{"approval_id": $id, "state": $state, "requested": $to}')"
    return $?
  fi
  if _ordo_approval_expired_now "$approval"; then
    ordo_journal_approval_set_state "$approval_id" expired --reason ttl_elapsed --actor '{"type":"system","id":"ordo_approval"}' >/dev/null 2>&1 || true
    _ordo_approval_fail invalid_state "approval ${approval_id} expired at $(printf '%s' "$approval" | jq -r '.expires_at'); it is now expired" \
      "$(printf '%s' "$approval" | jq -c --arg now "$(ordo_journal_now)" '{"approval_id": .id, "expires_at": .expires_at, "now": $now, "state": "expired"}')"
    return $?
  fi
  if [[ "$to" == granted ]]; then
    local expected current
    expected=$(printf '%s' "$approval" | jq -r '.policy_version')
    current=$(ordo_approval_policy_version)
    if [[ "$expected" != "$current" ]]; then
      _ordo_approval_refuse "$run_id" "$subject" "policy_version_drift" "$approval_id" "$actor" \
        "approval ${approval_id} was requested under policy ${expected}; the current policy is ${current}" \
        "$(jq -cn --arg e "$expected" --arg c "$current" '{"expected_policy_version": $e, "current_policy_version": $c}')"
      return $?
    fi
    _ordo_approval_record_decision "$run_id" "$subject" allow \
      "$(jq -cn '["actor_type_allowed", "approval_pending", "policy_version_match"]')" "$approval_id" "$actor" \
      "$(jq -cn --arg p "$principal" '{"principal": $p}')" >/dev/null || return $?
  fi
  local -a extra=()
  [[ -n "$_OA_REASON" ]] && extra+=(--reason "$_OA_REASON")
  local updated
  updated=$(ordo_journal_approval_set_state "$approval_id" "$to" --decided-by "$actor" --actor "$actor" "${extra[@]+"${extra[@]}"}") || return $?
  _ordo_approval_with_payload "$updated"
}

ordo_approval_grant() { _ordo_approval_decide granted "$@"; }
ordo_approval_deny() { _ordo_approval_decide denied "$@"; }

# ordo_approval_sweep [--run-id R] [--actor JSON]
#   Every pending/granted approval whose expires_at is <= now becomes expired
#   (the journal appends approval.expired). Prints {"now","expired":[...],"count"}.
ordo_approval_sweep() {
  _ordo_approval_parse_opts ordo_approval_sweep "$@" || return $?
  local actor
  if [[ -n "$_OA_ACTOR" ]]; then
    actor=$(ordo_approval_actor_json "$_OA_ACTOR") || return $?
  else
    actor='{"type":"system","id":"ordo_approval"}'
  fi
  local -a runs=()
  if [[ -n "$_OA_RUN_ID" ]]; then
    runs=("$_OA_RUN_ID")
  else
    # shellcheck disable=SC2119 # ordo_journal_runs takes only --state; none here
    mapfile -t runs < <(ordo_journal_runs 2>/dev/null | jq -r '.run_id // empty')
  fi
  local now expired='[]' run_id state row id was
  now=$(ordo_journal_now)
  for run_id in "${runs[@]+"${runs[@]}"}"; do
    for state in pending granted; do
      while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        _ordo_approval_expired_now "$row" || continue
        id=$(printf '%s' "$row" | jq -r '.id')
        was=$(printf '%s' "$row" | jq -r '.state')
        if ordo_journal_approval_set_state "$id" expired --reason ttl_elapsed --actor "$actor" >/dev/null; then
          expired=$(printf '%s' "$expired" | jq -c --argjson r "$(printf '%s' "$row" | jq -c --arg was "$was" '{"approval_id": .id, "run_id": .run_id, "action": .action, "was": $was, "expires_at": .expires_at}')" '. + [$r]')
        fi
      done < <(ordo_journal_approval_list "$run_id" --state "$state" 2>/dev/null)
    done
  done
  jq -cn --arg now "$now" --argjson expired "$expired" '{"now": $now, "expired": $expired, "count": ($expired | length)}'
}

# ---------------------------------------------------------------------------
# The bridge
# ---------------------------------------------------------------------------
# ordo_approval_authorize_and_run <approval_id> [--actor JSON] -- <provider op> [args...]
ordo_approval_authorize_and_run() {
  local approval_id="${1-}"
  if [[ -z "$approval_id" ]]; then
    _ordo_approval_fail usage "usage: ordo_approval_authorize_and_run <approval_id> [--actor JSON] -- <provider op> [args...]"
    return $?
  fi
  shift
  local actor_spec="" op="" a
  local -a args=()
  local seen_dd=0
  while [[ $# -gt 0 ]]; do
    if [[ "$seen_dd" -eq 1 ]]; then
      if [[ -z "$op" ]]; then op="$1"; else args+=("$1"); fi
      shift
      continue
    fi
    case "$1" in
      --actor) actor_spec="${2-}"; shift 2 ;;
      --) seen_dd=1; shift ;;
      *)
        _ordo_approval_fail usage "unknown option for ordo_approval_authorize_and_run: ${1} (the provider op goes after --)" "$(jq -cn --arg opt "$1" '{"option": $opt}')"
        return $?
        ;;
    esac
  done
  if [[ -z "$op" ]]; then
    _ordo_approval_fail usage "ordo_approval_authorize_and_run needs a provider op after --" '{"missing":"op"}'
    return $?
  fi
  for a in "${args[@]+"${args[@]}"}"; do
    if [[ "$a" == --idempotency-key || "$a" == -k ]]; then
      _ordo_approval_fail usage "the idempotency key comes from the approval; do not pass --idempotency-key to the bridge" \
        "$(jq -cn --arg id "$approval_id" '{"approval_id": $id, "argument": "--idempotency-key"}')"
      return $?
    fi
  done
  local actor atype
  actor=$(ordo_approval_actor_json "$actor_spec") || return $?
  atype=$(_ordo_approval_actor_type "$actor")

  local approval run_id action principal state key expected expires
  approval=$(_ordo_approval_load "$approval_id") || return $?
  run_id=$(printf '%s' "$approval" | jq -r '.run_id')
  action=$(printf '%s' "$approval" | jq -r '.action')
  principal=$(printf '%s' "$approval" | jq -r '.principal')
  state=$(printf '%s' "$approval" | jq -r '.state')
  key=$(printf '%s' "$approval" | jq -r '.idempotency_key')
  expected=$(printf '%s' "$approval" | jq -r '.policy_version')
  expires=$(printf '%s' "$approval" | jq -r '.expires_at // ""')
  local subject="execute:${action}:${op}"

  # Trace context: one trace per run, root span for the authorization.
  _OA_TRACE=$(ordo_trace_new_id trace "$run_id")
  local root
  root=$(ORDO_RUN_ID="$run_id" ordo_trace_start approval.authorize --kind approval --trace "$_OA_TRACE" \
    --attr "approval.id=$approval_id" --attr "ordo.run_id=$run_id" --attr "approval.action=$action" \
    --attr "approval.principal=$principal" --attr "provider.op=$op" --attr "actor.type=$atype" 2>/dev/null) || root=""

  # Replay: a consumed approval with a recorded receipt never re-executes.
  if [[ "$state" == consumed ]]; then
    local result
    result=$(printf '%s' "$approval" | jq -c '.result // empty')
    if [[ -n "$result" && "$result" != null ]]; then
      [[ -n "$root" ]] && ordo_trace_end "$root" --trace "$_OA_TRACE" --status ok --attr "approval.replayed=true" >/dev/null 2>&1
      printf '%s' "$result" | jq -c --arg id "$approval_id" '.details.replayed = true | .details.approval_id = $id | .approval_id = $id'
      return 0
    fi
  fi

  _OA_POLICY_SPAN=$(ORDO_RUN_ID="$run_id" ordo_trace_start policy.reauthorize --kind policy --trace "$_OA_TRACE" \
    ${root:+--parent "$root"} --attr "approval.id=$approval_id" --attr "policy.name=$ORDO_APPROVAL_POLICY_NAME" 2>/dev/null) || _OA_POLICY_SPAN=""

  _ordo_approval_bridge_refuse() {
    # <reason> <message> [details]
    local rc
    _ordo_approval_refuse "$run_id" "$subject" "$1" "$approval_id" "$actor" "$2" "${3:-{\}}"
    rc=$?
    [[ -n "$_OA_POLICY_SPAN" ]] && ordo_trace_end "$_OA_POLICY_SPAN" --trace "$_OA_TRACE" --status error --message "$1" >/dev/null 2>&1
    [[ -n "$root" ]] && ordo_trace_end "$root" --trace "$_OA_TRACE" --status error --message "refused: $1" >/dev/null 2>&1
    _OA_POLICY_SPAN=""
    return "$rc"
  }

  # (0) the executor is never a model
  if ! _ordo_approval_type_in "$atype" "$ORDO_APPROVAL_EXECUTOR_TYPES"; then
    _ordo_approval_bridge_refuse actor_type_not_allowed \
      "an actor of type '${atype}' may not execute approved actions (allowed: ${ORDO_APPROVAL_EXECUTOR_TYPES// /|})" \
      "$(jq -cn --arg t "$atype" --argjson actor "$actor" '{"actor": $actor, "actor_type": $t}')"
    return $?
  fi
  # (d) the run must be known and not terminal (fail-closed on unknown)
  local run_state
  if ! run_state=$(ordo_journal_state "$run_id" 2>/dev/null) || [[ -z "$run_state" ]]; then
    _ordo_approval_bridge_refuse run_unknown "run ${run_id} has no journal state; refusing (fail-closed)" \
      "$(jq -cn --arg r "$run_id" '{"run_id": $r}')"
    return $?
  fi
  if ordo_contracts_is_terminal run "$run_state" 2>/dev/null; then
    _ordo_approval_bridge_refuse run_terminal "run ${run_id} is ${run_state} (terminal); the approved action can no longer run" \
      "$(jq -cn --arg r "$run_id" --arg s "$run_state" '{"run_id": $r, "run_state": $s}')"
    return $?
  fi
  # (a) approval state granted and not expired NOW
  case "$state" in
    granted) ;;
    pending)
      _ordo_approval_bridge_refuse approval_not_granted "approval ${approval_id} is still pending" \
        "$(jq -cn --arg s "$state" '{"state": $s}')"
      return $? ;;
    *)
      _ordo_approval_bridge_refuse "approval_${state}" "approval ${approval_id} is ${state}; only a granted approval executes" \
        "$(jq -cn --arg s "$state" '{"state": $s}')"
      return $? ;;
  esac
  if _ordo_approval_expired_now "$approval"; then
    ordo_journal_approval_set_state "$approval_id" expired --reason ttl_elapsed --actor '{"type":"system","id":"ordo_approval"}' >/dev/null 2>&1 || true
    _ordo_approval_bridge_refuse approval_expired "approval ${approval_id} expired at ${expires} (now $(ordo_journal_now)); marked expired" \
      "$(jq -cn --arg e "$expires" --arg now "$(ordo_journal_now)" '{"expires_at": $e, "now": $now, "state": "expired"}')"
    return $?
  fi
  # (b) policy version still current
  local current
  current=$(ordo_approval_policy_version)
  if [[ "$expected" != "$current" ]]; then
    _ordo_approval_bridge_refuse policy_version_drift \
      "approval ${approval_id} was granted under policy ${expected}; the current policy is ${current}" \
      "$(jq -cn --arg e "$expected" --arg c "$current" '{"expected_policy_version": $e, "current_policy_version": $c}')"
    return $?
  fi
  # (e) the provider op is the approved action, and the pinned payload matches
  if [[ "$(_ordo_approval_norm_action "$action")" != "$(_ordo_approval_norm_action "$op")" ]]; then
    _ordo_approval_bridge_refuse action_mismatch "approval ${approval_id} covers action ${action}, not provider op ${op}" \
      "$(jq -cn --arg a "$action" --arg op "$op" '{"approved_action": $a, "requested_op": $op}')"
    return $?
  fi
  if ! ordo_provider_adapter_is_mutating "$op"; then
    _ordo_approval_bridge_refuse op_not_mutating "provider op ${op} is not a mutation; the bridge only executes approved mutations" \
      "$(jq -cn --arg op "$op" '{"op": $op}')"
    return $?
  fi
  local payload pinned
  payload=$(_ordo_approval_payload_for "$run_id" "$approval_id")
  pinned=$(printf '%s' "$payload" | jq -c '.args // empty')
  if [[ -n "$pinned" && "$pinned" != null ]]; then
    local given
    given=$(printf '%s\n' "${args[@]+"${args[@]}"}" | jq -R . | jq -sc 'map(select(. != ""))')
    if [[ "$pinned" != "$given" ]]; then
      _ordo_approval_bridge_refuse payload_mismatch "the arguments differ from the payload pinned on approval ${approval_id}" \
        "$(jq -cn --argjson p "$pinned" --argjson g "$given" '{"pinned_args": $p, "given_args": $g}')"
      return $?
    fi
  fi
  # (c) principal allowed for the action (allow-list, else gate semantics)
  local scope=""
  if ordo_provider_adapter_parse_args "$op" "${args[@]+"${args[@]}"}" --idempotency-key "$key" 2>/dev/null; then
    scope=$(ordo_provider_adapter_scope_for "$op" 2>/dev/null) || scope=""
  fi
  if ! ordo_approval_principal_allowed "$principal" "$action" "$scope"; then
    _ordo_approval_bridge_refuse principal_not_allowed \
      "principal ${principal} is not allowed to ${action} (ORDO_APPROVAL_PRINCIPALS or, when empty, ORCH_EXTERNAL_PR_MUTATIONS scope ${scope:-unknown})" \
      "$(jq -cn --arg p "$principal" --arg a "$action" --arg s "$scope" --arg l "${ORDO_APPROVAL_PRINCIPALS:-}" '{"principal": $p, "action": $a, "scope": $s, "allow_list": $l}')"
    return $?
  fi
  _ordo_approval_record_decision "$run_id" "$subject" allow \
    "$(jq -cn '["actor_type_allowed", "run_active", "approval_granted", "not_expired", "policy_version_match", "action_bound", "principal_allowed"]')" \
    "$approval_id" "$actor" "$(jq -cn --arg p "$principal" --arg s "$scope" --arg op "$op" '{"principal": $p, "scope": $s, "op": $op}')" >/dev/null || return $?
  [[ -n "$_OA_POLICY_SPAN" ]] && ordo_trace_end "$_OA_POLICY_SPAN" --trace "$_OA_TRACE" --status ok --attr "policy.decision=allow" >/dev/null 2>&1
  _OA_POLICY_SPAN=""

  # Execute through the provider with the approval's idempotency key.
  local pspan
  pspan=$(ORDO_RUN_ID="$run_id" ordo_trace_start "provider.${op}" --kind provider --trace "$_OA_TRACE" ${root:+--parent "$root"} \
    --attr "provider.op=$op" --attr "provider.adapter=$(ordo_provider_adapter_name)" --attr "approval.id=$approval_id" \
    --attr "approval.idempotency_key=$key" --attr "provider.scope=$scope" 2>/dev/null) || pspan=""
  local receipt errfile rc=0
  errfile=$(mktemp "${TMPDIR:-/tmp}/ordo-approval-err.XXXXXX")
  receipt=$(ordo_provider "$op" "${args[@]+"${args[@]}"}" --idempotency-key "$key" 2>"$errfile") || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    local err
    err=$(jq -c '.' "$errfile" 2>/dev/null | tail -n 1)
    [[ -n "$err" ]] || err=$(jq -cn --arg raw "$(tail -c 400 "$errfile")" '{"raw": $raw}')
    cat "$errfile" >&2
    rm -f "$errfile"
    err=$(ordo_trace_redact "$err")
    ordo_journal_append "$run_id" approval_bridge.execution_failed \
      "$(jq -cn --arg id "$approval_id" --arg op "$op" --argjson rc "$rc" --argjson err "$err" '{"approval_id": $id, "op": $op, "exit_code": $rc, "error": $err}')" \
      --actor "$actor" >/dev/null 2>&1 || true
    [[ -n "$pspan" ]] && ordo_trace_end "$pspan" --trace "$_OA_TRACE" --status error --message "provider exit ${rc}" --attr "ordo.exit_code=$rc" >/dev/null 2>&1
    [[ -n "$root" ]] && ordo_trace_end "$root" --trace "$_OA_TRACE" --status error --message "provider exit ${rc}" >/dev/null 2>&1
    return "$rc"
  fi
  rm -f "$errfile"
  local replayed
  replayed=$(printf '%s' "$receipt" | jq -r '.details.replayed // false')
  receipt=$(printf '%s' "$receipt" | jq -c --arg id "$approval_id" '.approval_id = $id | .details.approval_id = $id')
  # Consume in the same logical step, after the receipt (a replayed receipt consumes too).
  ordo_journal_approval_set_state "$approval_id" consumed --decided-by "$actor" --actor "$actor" \
    --result "$(ordo_trace_redact "$receipt")" >/dev/null || return $?
  ordo_journal_append "$run_id" approval_bridge.executed \
    "$(printf '%s' "$receipt" | jq -c --arg id "$approval_id" --arg op "$op" '{"approval_id": $id, "op": $op, "replayed": (.details.replayed // false), "receipt": .}')" \
    --mutation --idempotency-key "$key" --actor "$actor" >/dev/null 2>&1 || true
  [[ -n "$pspan" ]] && ordo_trace_end "$pspan" --trace "$_OA_TRACE" --status ok --attr "provider.replayed=$replayed" >/dev/null 2>&1
  [[ -n "$root" ]] && ordo_trace_end "$root" --trace "$_OA_TRACE" --status ok --attr "approval.state=consumed" >/dev/null 2>&1
  printf '%s\n' "$receipt"
}
