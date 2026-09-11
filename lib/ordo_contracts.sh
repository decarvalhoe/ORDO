#!/usr/bin/env bash
# lib/ordo_contracts.sh — canonical ORDO execution contracts, v1 (#807, epic #806).
#
# Single source of truth for the ten typed objects every agentic-control-plane
# module exchanges (run, task, attempt, agent, lease, event, approval,
# artifact, policy_decision, blocker), their state-transition tables, the
# redaction rules, and the error-object / exit-code convention shared by all
# new surfaces. Everything is embedded here on purpose: the test runners only
# mirror *.sh/*.bats/*.md files plus tests/fixtures/**, so the schema data must
# ship inside a bash file. `contracts/v1/emit.sh` is a thin CLI over this
# library for humans and tooling; it never carries data of its own.
#
# Public API (fixed by .work/agentic-control-plane-BRIEF.md):
#   ordo_contracts_kinds                          # one kind per line
#   ordo_contracts_new_id <kind>                  # print "<kind>_<24 hex>"
#   ordo_contracts_now                            # RFC3339 UTC (Z suffix)
#   ordo_contracts_validate <kind> <json>         # 0 ok; 5 + error object on stderr
#   ordo_contracts_transition <table> <from> <to> # 0 ok; 5 + error object
#   ordo_contracts_is_terminal <table> <state>    # 0 terminal / 1 not terminal
#   ordo_contracts_redact <json>                  # masked JSON on stdout
#   ordo_contracts_schema <kind>                  # JSON-Schema-like document
#   ordo_contracts_error <module> <code> <message> [details-json]
#                                                 # prints error object, returns mapped exit
# Supporting helpers (documented in docs/architecture/contracts.md):
#   ordo_contracts_exit_code <code>               # print the exit code mapped to <code>
#   ordo_contracts_exit_codes                     # print the whole code -> exit map (JSON)
#   ordo_contracts_transitions <table>            # print a transition table (JSON)
#   ordo_contracts_tables                         # one table name per line
#
# <json> arguments accept a literal JSON string, `-` (read stdin) or `@<path>`
# (read a file). Validation and transition failures print ONE JSON line to
# stderr: {"error":{"code","message","module":"contracts","details":{}}}.
#
# Dependencies: bash >= 4, jq, coreutils (date, od). No python, no network.

ORDO_CONTRACTS_SCHEMA_VERSION="1"
ORDO_CONTRACTS_MODULE="contracts"
ORDO_CONTRACTS_KINDS="run task attempt agent lease event approval artifact policy_decision blocker"
ORDO_CONTRACTS_TABLES="run approval lease"
ORDO_CONTRACTS_ID_HEX_LEN=24

# ---------------------------------------------------------------------------
# Error objects and exit codes (shared by every new ORDO surface)
# ---------------------------------------------------------------------------
# code (snake_case) -> exit status. Codes not listed here map to 1 (generic).
ORDO_CONTRACTS_EXIT_MAP='{
  "ok": 0,
  "generic_failure": 1,
  "internal_error": 1,
  "usage": 2,
  "bad_argument": 2,
  "unknown_command": 2,
  "unknown_kind": 2,
  "unknown_table": 2,
  "refused": 3,
  "policy_refused": 3,
  "fail_closed": 3,
  "not_found": 4,
  "invalid_state": 5,
  "invalid_transition": 5,
  "invalid_contract": 5,
  "invalid_json": 5,
  "unknown_state": 5,
  "conflict": 5,
  "duplicate_event": 5,
  "missing_dependency": 6,
  "not_implemented": 6,
  "provider_not_available": 6,
  "budget_exhausted": 7,
  "lease_lost": 8,
  "lease_stale": 8
}'

ordo_contracts_exit_codes() {
  printf '%s\n' "$ORDO_CONTRACTS_EXIT_MAP" | jq -S .
}

ordo_contracts_exit_code() {
  local code="${1:?usage: ordo_contracts_exit_code <code>}"
  printf '%s\n' "$ORDO_CONTRACTS_EXIT_MAP" | jq -r --arg c "$code" '.[$c] // 1'
}

# ordo_contracts_error <module> <code> <message> [details-json]
# Prints exactly one JSON line on stderr and returns the exit code mapped to
# <code>. Callers typically write: `ordo_contracts_error m c "msg"; return $?`
# or `exit "$(ordo_contracts_exit_code c)"` after printing.
ordo_contracts_error() {
  local module="${1:?usage: ordo_contracts_error <module> <code> <message> [details-json]}"
  local code="${2:?usage: ordo_contracts_error <module> <code> <message> [details-json]}"
  local message="${3:?usage: ordo_contracts_error <module> <code> <message> [details-json]}"
  local details="${4:-{\}}"
  local details_json
  if ! details_json=$(printf '%s' "$details" | jq -c 'if type == "object" then . else {"value": .} end' 2>/dev/null); then
    details_json=$(jq -cn --arg raw "$details" '{"raw": $raw}')
  fi
  jq -cn \
    --arg module "$module" \
    --arg code "$code" \
    --arg message "$message" \
    --argjson details "$details_json" \
    '{"error": {"code": $code, "message": $message, "module": $module, "details": $details}}' >&2
  return "$(ordo_contracts_exit_code "$code")"
}

_ordo_contracts_fail() {
  # Internal: error helper bound to this module.
  ordo_contracts_error "$ORDO_CONTRACTS_MODULE" "$@"
}

# ---------------------------------------------------------------------------
# Kinds, ids, time
# ---------------------------------------------------------------------------
ordo_contracts_kinds() {
  local kind
  for kind in $ORDO_CONTRACTS_KINDS; do
    printf '%s\n' "$kind"
  done
}

ordo_contracts_tables() {
  local table
  for table in $ORDO_CONTRACTS_TABLES; do
    printf '%s\n' "$table"
  done
}

_ordo_contracts_is_kind() {
  local kind="${1-}" k
  for k in $ORDO_CONTRACTS_KINDS; do
    [[ "$k" == "$kind" ]] && return 0
  done
  return 1
}

_ordo_contracts_is_table() {
  local table="${1-}" t
  for t in $ORDO_CONTRACTS_TABLES; do
    [[ "$t" == "$table" ]] && return 0
  done
  return 1
}

_ordo_contracts_id_pattern() {
  # Regex (ERE / jq test) matching a canonical id of <kind>.
  printf '^%s_[0-9a-f]{%s}$' "$1" "$ORDO_CONTRACTS_ID_HEX_LEN"
}

ordo_contracts_new_id() {
  local kind="${1-}"
  if ! _ordo_contracts_is_kind "$kind"; then
    _ordo_contracts_fail unknown_kind "unknown contract kind: '${kind}'" \
      "$(jq -cn --arg kind "$kind" --arg kinds "$ORDO_CONTRACTS_KINDS" '{"kind": $kind, "known": ($kinds | split(" "))}')"
    return $?
  fi
  local hex
  hex=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
  if [[ ${#hex} -ne "$ORDO_CONTRACTS_ID_HEX_LEN" ]]; then
    _ordo_contracts_fail internal_error "could not read 12 random bytes from /dev/urandom"
    return $?
  fi
  printf '%s_%s\n' "$kind" "$hex"
}

ordo_contracts_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# ---------------------------------------------------------------------------
# Schemas (v1). Common envelope + per-kind fields. Unknown extra fields are
# accepted (forward compatibility); additive changes stay in v1, breaking
# changes open contracts/v2 (see contracts/README.md).
# ---------------------------------------------------------------------------
_ordo_contracts_common_props() {
  local kind="$1"
  cat <<EOF
{
  "schema_version": {"type": "string", "const": "1",
    "description": "Contract schema major version. Additive changes keep \"1\"."},
  "kind": {"type": "string", "const": "${kind}"},
  "id": {"type": "string", "pattern": "$(_ordo_contracts_id_pattern "$kind")",
    "description": "Canonical id: <kind>_<24 lowercase hex>, from ordo_contracts_new_id."},
  "created_at": {"type": "string", "format": "date-time",
    "description": "RFC3339 UTC timestamp with a Z suffix, from ordo_contracts_now."},
  "correlation_id": {"type": "string", "minLength": 1,
    "description": "Opaque trace id shared by every object of one causal chain (normally the root run id)."},
  "actor": {"type": "object", "required": ["type", "id"], "additionalProperties": true,
    "properties": {
      "type": {"type": "string", "enum": ["operator", "agent", "system", "model"]},
      "id": {"type": "string", "minLength": 1}
    },
    "description": "Who produced this object. A model actor never owns authorization, persistence or irreversible mutations."}
}
EOF
}

_ordo_contracts_kind_spec() {
  # Prints {"description":..., "required":[...], "properties":{...}, "allOf":[...]}
  local kind="$1"
  local run_states='["queued","leased","running","waiting","blocked","approval_required","succeeded","failed","cancelled","expired"]'
  local error_obj='{"type": "object", "required": ["code", "message"], "additionalProperties": true, "properties": {"code": {"type": "string"}, "message": {"type": "string"}, "module": {"type": "string"}, "details": {"type": "object"}}}'
  case "$kind" in
    run) cat <<EOF
{
  "description": "One unit of orchestrated work for a project (typically a ticket). Owns tasks and the budget.",
  "required": ["state", "project"],
  "properties": {
    "state": {"type": "string", "enum": ${run_states}},
    "project": {"type": "string", "minLength": 1, "description": "Configured project key (never inferred from a path)."},
    "ticket_ref": {"type": "string", "description": "Provider-neutral ticket reference, e.g. owner/repo#123."},
    "title": {"type": "string"},
    "tasks": {"type": "array", "items": {"type": "string", "pattern": "$(_ordo_contracts_id_pattern task)"}},
    "budget": {"type": "object", "additionalProperties": true, "properties": {
      "max_attempts": {"type": "integer", "minimum": 0},
      "max_seconds": {"type": "integer", "minimum": 0},
      "max_tokens": {"type": "integer", "minimum": 0}}},
    "updated_at": {"type": "string", "format": "date-time"},
    "labels": {"type": "array", "items": {"type": "string"}},
    "metadata": {"type": "object"}
  }
}
EOF
    ;;
    task) cat <<EOF
{
  "description": "A schedulable step inside a run. Shares the run state vocabulary.",
  "required": ["run_id", "state", "title"],
  "properties": {
    "run_id": {"type": "string", "pattern": "$(_ordo_contracts_id_pattern run)"},
    "state": {"type": "string", "enum": ${run_states}},
    "title": {"type": "string", "minLength": 1},
    "depends_on": {"type": "array", "items": {"type": "string", "pattern": "$(_ordo_contracts_id_pattern task)"}},
    "attempts": {"type": "array", "items": {"type": "string", "pattern": "$(_ordo_contracts_id_pattern attempt)"}},
    "assignee": {"type": "string", "pattern": "$(_ordo_contracts_id_pattern agent)"},
    "priority": {"type": "integer", "minimum": 0},
    "updated_at": {"type": "string", "format": "date-time"},
    "metadata": {"type": "object"}
  }
}
EOF
    ;;
    attempt) cat <<EOF
{
  "description": "One execution of a task by one agent under one lease. Retries create new attempts; attempts are never rewritten.",
  "required": ["run_id", "task_id", "agent_id", "attempt_no", "state"],
  "properties": {
    "run_id": {"type": "string", "pattern": "$(_ordo_contracts_id_pattern run)"},
    "task_id": {"type": "string", "pattern": "$(_ordo_contracts_id_pattern task)"},
    "agent_id": {"type": "string", "pattern": "$(_ordo_contracts_id_pattern agent)"},
    "lease_id": {"type": "string", "pattern": "$(_ordo_contracts_id_pattern lease)"},
    "attempt_no": {"type": "integer", "minimum": 1},
    "state": {"type": "string", "enum": ${run_states}},
    "started_at": {"type": "string", "format": "date-time"},
    "ended_at": {"type": "string", "format": "date-time"},
    "exit_code": {"type": "integer", "minimum": 0},
    "evidence": {"type": "array", "items": {"type": "string", "pattern": "$(_ordo_contracts_id_pattern artifact)"}},
    "error": ${error_obj},
    "metadata": {"type": "object"}
  }
}
EOF
    ;;
    agent) cat <<EOF
{
  "description": "A worker identity: a fleet slot bound to a runtime and a provider. Identity is the slot, never the model.",
  "required": ["name", "slot", "runtime", "provider"],
  "properties": {
    "name": {"type": "string", "minLength": 1},
    "slot": {"type": "string", "minLength": 1, "description": "Neutral slot label, e.g. fleet-001."},
    "runtime": {"type": "string", "minLength": 1, "description": "Runtime adapter name: tmux, ssh, fake, ..."},
    "provider": {"type": "string", "minLength": 1, "description": "Provider adapter name: github, fake, ..."},
    "pane": {"type": "string", "description": "Runtime-specific target, e.g. fleet-001:0.0."},
    "capabilities": {"type": "array", "items": {"type": "string"}},
    "status": {"type": "string", "enum": ["idle", "busy", "degraded", "offline"]},
    "metadata": {"type": "object"}
  }
}
EOF
    ;;
    lease) cat <<EOF
{
  "description": "Exclusive, expiring ownership of a run (or task) by one owner. Heartbeats renew it; a lost lease stops mutations.",
  "required": ["run_id", "owner", "state", "expires_at"],
  "properties": {
    "run_id": {"type": "string", "pattern": "$(_ordo_contracts_id_pattern run)"},
    "task_id": {"type": "string", "pattern": "$(_ordo_contracts_id_pattern task)"},
    "owner": {"type": "string", "minLength": 1, "description": "Holder identity (agent id, slot or process label)."},
    "state": {"type": "string", "enum": ["active", "renewed", "released", "expired"]},
    "expires_at": {"type": "string", "format": "date-time"},
    "heartbeat_at": {"type": "string", "format": "date-time"},
    "ttl_seconds": {"type": "integer", "minimum": 1},
    "generation": {"type": "integer", "minimum": 0, "description": "Increments on every renewal; stale holders compare generations."},
    "metadata": {"type": "object"}
  }
}
EOF
    ;;
    event) cat <<EOF
{
  "description": "Append-only journal entry. mutation=true marks an external side effect and requires an idempotency_key so replay never repeats it.",
  "required": ["run_id", "type", "payload", "mutation"],
  "properties": {
    "run_id": {"type": "string", "pattern": "$(_ordo_contracts_id_pattern run)"},
    "run_seq": {"type": "integer", "minimum": 0, "description": "Monotonic per-run sequence assigned by the journal."},
    "type": {"type": "string", "pattern": "^[a-z][a-z0-9_.]*$", "description": "snake_case event type, dots allowed for namespaces."},
    "payload": {"type": "object"},
    "mutation": {"type": "boolean"},
    "idempotency_key": {"type": "string", "minLength": 1},
    "metadata": {"type": "object"}
  },
  "allOf": [
    {"if": {"properties": {"mutation": {"const": true}}, "required": ["mutation"]},
     "then": {"required": ["idempotency_key"]}}
  ]
}
EOF
    ;;
    approval) cat <<EOF
{
  "description": "A human/policy gate for one action. Always carries an idempotency_key: granting twice must not act twice.",
  "required": ["run_id", "action", "principal", "policy_version", "state", "idempotency_key"],
  "properties": {
    "run_id": {"type": "string", "pattern": "$(_ordo_contracts_id_pattern run)"},
    "action": {"type": "string", "minLength": 1, "description": "The gated action, e.g. pr.merge or external_pr_mutation."},
    "principal": {"type": "string", "minLength": 1, "description": "Who must decide (operator identity or role)."},
    "policy_version": {"type": "string", "minLength": 1},
    "state": {"type": "string", "enum": ["pending", "granted", "denied", "consumed", "expired"]},
    "idempotency_key": {"type": "string", "minLength": 1},
    "expires_at": {"type": "string", "format": "date-time"},
    "decided_at": {"type": "string", "format": "date-time"},
    "decided_by": {"type": "object", "required": ["type", "id"], "properties": {
      "type": {"type": "string", "enum": ["operator", "agent", "system", "model"]},
      "id": {"type": "string", "minLength": 1}}},
    "reason": {"type": "string"},
    "result": {"type": "object"},
    "metadata": {"type": "object"}
  }
}
EOF
    ;;
    artifact) cat <<EOF
{
  "description": "Evidence produced by a run: log, diff, report, transcript, file. Stored by reference (uri) with an optional digest.",
  "required": ["run_id", "type", "uri"],
  "properties": {
    "run_id": {"type": "string", "pattern": "$(_ordo_contracts_id_pattern run)"},
    "attempt_id": {"type": "string", "pattern": "$(_ordo_contracts_id_pattern attempt)"},
    "type": {"type": "string", "minLength": 1, "description": "log, diff, report, transcript, evidence, ..."},
    "uri": {"type": "string", "minLength": 1},
    "media_type": {"type": "string"},
    "sha256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
    "size_bytes": {"type": "integer", "minimum": 0},
    "redacted": {"type": "boolean", "description": "true once ordo_contracts_redact has been applied to the content."},
    "metadata": {"type": "object"}
  }
}
EOF
    ;;
    policy_decision) cat <<EOF
{
  "description": "Deterministic verdict of a policy over one subject. Models may propose; only code decides.",
  "required": ["run_id", "policy", "policy_version", "subject", "decision", "reasons"],
  "properties": {
    "run_id": {"type": "string", "pattern": "$(_ordo_contracts_id_pattern run)"},
    "policy": {"type": "string", "minLength": 1},
    "policy_version": {"type": "string", "minLength": 1},
    "subject": {"type": "string", "minLength": 1, "description": "The action or object judged, e.g. mutate:pr.merge owner/repo#12."},
    "decision": {"type": "string", "enum": ["allow", "deny", "require_approval"]},
    "reasons": {"type": "array", "items": {"type": "string"}},
    "approval_id": {"type": "string", "pattern": "$(_ordo_contracts_id_pattern approval)"},
    "inputs_digest": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
    "metadata": {"type": "object"}
  }
}
EOF
    ;;
    blocker) cat <<EOF
{
  "description": "Something outside the run's control that stops progress (missing data, red CI, external dependency). Fail-closed: a blocker never auto-resolves.",
  "required": ["run_id", "type", "severity", "summary"],
  "properties": {
    "run_id": {"type": "string", "pattern": "$(_ordo_contracts_id_pattern run)"},
    "task_id": {"type": "string", "pattern": "$(_ordo_contracts_id_pattern task)"},
    "type": {"type": "string", "minLength": 1},
    "severity": {"type": "string", "enum": ["info", "warning", "blocking"]},
    "summary": {"type": "string", "minLength": 1},
    "state": {"type": "string", "enum": ["open", "resolved"]},
    "external_ref": {"type": "string"},
    "resolved_at": {"type": "string", "format": "date-time"},
    "resolution": {"type": "string"},
    "metadata": {"type": "object"}
  }
}
EOF
    ;;
    *) return 1 ;;
  esac
}

ordo_contracts_schema() {
  local kind="${1-}"
  if ! _ordo_contracts_is_kind "$kind"; then
    _ordo_contracts_fail unknown_kind "unknown contract kind: '${kind}'" \
      "$(jq -cn --arg kind "$kind" --arg kinds "$ORDO_CONTRACTS_KINDS" '{"kind": $kind, "known": ($kinds | split(" "))}')"
    return $?
  fi
  jq -n \
    --arg kind "$kind" \
    --arg version "$ORDO_CONTRACTS_SCHEMA_VERSION" \
    --argjson common "$(_ordo_contracts_common_props "$kind")" \
    --argjson spec "$(_ordo_contracts_kind_spec "$kind")" '
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": ("https://ordo.invalid/contracts/v" + $version + "/" + $kind + ".schema.json"),
      "title": ("ORDO " + $kind + " contract v" + $version),
      "description": $spec.description,
      "x-ordo-kind": $kind,
      "x-ordo-schema-version": $version,
      "type": "object",
      "additionalProperties": true,
      "required": (["schema_version", "kind", "id", "created_at", "correlation_id", "actor"] + $spec.required),
      "properties": ($common + $spec.properties)
    }
    + (if ($spec.allOf // []) | length > 0 then {"allOf": $spec.allOf} else {} end)'
}

# ---------------------------------------------------------------------------
# Validation. A small, deterministic interpreter of the schema subset used
# above: type, const, enum, pattern, minLength, minimum, format=date-time,
# properties, required, items, allOf[if/then]. Extra keys are ignored.
# ---------------------------------------------------------------------------
_ordo_contracts_read_json_arg() {
  # Resolves the <json> argument convention: literal | - | @path.
  local arg="${1-}"
  case "$arg" in
    -) cat ;;
    @*)
      local path="${arg#@}"
      if [[ ! -r "$path" ]]; then
        return 4
      fi
      cat "$path"
      ;;
    *) printf '%s' "$arg" ;;
  esac
}

# shellcheck disable=SC2016 # jq program, not shell expansion.
ORDO_CONTRACTS_JQ_VALIDATOR='
def is_int: type == "number" and (. == floor);
def rfc3339_utc:
  type == "string"
  and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$")
  and (sub("\\.[0-9]+Z$"; "Z") | try (strptime("%Y-%m-%dT%H:%M:%SZ") | true) catch false);
def type_ok($t):
  if $t == "integer" then is_int
  elif $t == "number" then type == "number"
  else type == $t end;
def check($s; $v; $p):
  (if ($s | has("type")) and ($v | type_ok($s.type) | not)
     then ["\($p): expected \($s.type), got \($v | type)"] else [] end)
  + (if ($s | has("const")) and ($v != $s.const)
     then ["\($p): expected constant \($s.const | tojson)"] else [] end)
  + (if ($s | has("enum")) and (($s.enum | index([$v])) == null)
     then ["\($p): value \($v | tojson) not in \($s.enum | tojson)"] else [] end)
  + (if ($s | has("pattern")) and ($v | type == "string") and ($v | test($s.pattern) | not)
     then ["\($p): value \($v | tojson) does not match \($s.pattern)"] else [] end)
  + (if ($s | has("minLength")) and ($v | type == "string") and (($v | length) < $s.minLength)
     then ["\($p): shorter than minLength \($s.minLength)"] else [] end)
  + (if ($s | has("minimum")) and ($v | type == "number") and ($v < $s.minimum)
     then ["\($p): below minimum \($s.minimum)"] else [] end)
  + (if ($s.format == "date-time") and ($v | type == "string") and ($v | rfc3339_utc | not)
     then ["\($p): not an RFC3339 UTC timestamp (YYYY-MM-DDTHH:MM:SS[.fff]Z)"] else [] end)
  + (if ($v | type == "object")
     then ([ ($s.required // [])[] | . as $r | select(($v | has($r)) | not) | "\($p).\($r): required field missing" ]
           + [ ($s.properties // {}) | to_entries[] | . as $e | select($v | has($e.key))
               | check($e.value; $v[$e.key]; "\($p).\($e.key)")[] ])
     else [] end)
  + (if ($v | type == "array") and ($s | has("items"))
     then [ $v | to_entries[] | . as $e | check($s.items; $e.value; "\($p)[\($e.key)]")[] ]
     else [] end)
  + (if ($s | has("allOf"))
     then [ $s.allOf[] | . as $c
            | if ($c | has("if"))
              then (if (check($c.if; $v; $p) | length) == 0 then check($c.then // {}; $v; $p)[] else empty end)
              else check($c; $v; $p)[] end ]
     else [] end);
check($schema; .; "$")
'

ordo_contracts_validate() {
  local kind="${1-}"
  local arg="${2-}"
  if [[ -z "$kind" || $# -lt 2 ]]; then
    _ordo_contracts_fail usage "usage: ordo_contracts_validate <kind> <json|-|@path>"
    return $?
  fi
  if ! _ordo_contracts_is_kind "$kind"; then
    _ordo_contracts_fail unknown_kind "unknown contract kind: '${kind}'" \
      "$(jq -cn --arg kind "$kind" --arg kinds "$ORDO_CONTRACTS_KINDS" '{"kind": $kind, "known": ($kinds | split(" "))}')"
    return $?
  fi
  local raw
  if ! raw=$(_ordo_contracts_read_json_arg "$arg"); then
    _ordo_contracts_fail not_found "cannot read JSON input: ${arg}" \
      "$(jq -cn --arg input "$arg" '{"input": $input}')"
    return $?
  fi
  local doc
  if ! doc=$(printf '%s' "$raw" | jq -c . 2>/dev/null) || [[ -z "$doc" ]]; then
    _ordo_contracts_fail invalid_json "input is not valid JSON" \
      "$(jq -cn --arg kind "$kind" '{"kind": $kind}')"
    return $?
  fi
  local schema errors
  schema=$(ordo_contracts_schema "$kind")
  errors=$(printf '%s' "$doc" | jq -c --argjson schema "$schema" "$ORDO_CONTRACTS_JQ_VALIDATOR") || {
    _ordo_contracts_fail internal_error "validator failed for kind ${kind}"
    return $?
  }
  if [[ "$errors" != "[]" ]]; then
    _ordo_contracts_fail invalid_contract "object does not satisfy the ${kind} v${ORDO_CONTRACTS_SCHEMA_VERSION} contract" \
      "$(jq -cn --arg kind "$kind" --arg version "$ORDO_CONTRACTS_SCHEMA_VERSION" --argjson errors "$errors" \
          '{"kind": $kind, "schema_version": $version, "errors": $errors}')"
    return $?
  fi
  return 0
}

# ---------------------------------------------------------------------------
# State machines. One table for run/task/attempt (the scheduler vocabulary),
# one for approvals, one for leases. A state with no entry is terminal.
# ---------------------------------------------------------------------------
ORDO_CONTRACTS_TRANSITIONS_RUN='{
  "queued":            ["leased", "cancelled", "expired"],
  "leased":            ["running", "queued", "expired", "cancelled"],
  "running":           ["waiting", "blocked", "approval_required", "succeeded", "failed", "cancelled"],
  "waiting":           ["running", "expired", "cancelled", "failed"],
  "blocked":           ["running", "queued", "failed", "cancelled"],
  "approval_required": ["running", "queued", "expired", "cancelled", "failed"],
  "succeeded": [], "failed": [], "cancelled": [], "expired": []
}'
ORDO_CONTRACTS_TRANSITIONS_APPROVAL='{
  "pending": ["granted", "denied", "expired"],
  "granted": ["consumed", "expired"],
  "denied": [], "consumed": [], "expired": []
}'
ORDO_CONTRACTS_TRANSITIONS_LEASE='{
  "active":  ["renewed", "released", "expired"],
  "renewed": ["renewed", "released", "expired"],
  "released": [], "expired": []
}'

ordo_contracts_transitions() {
  local table="${1-}"
  case "$table" in
    run)      printf '%s\n' "$ORDO_CONTRACTS_TRANSITIONS_RUN" | jq . ;;
    approval) printf '%s\n' "$ORDO_CONTRACTS_TRANSITIONS_APPROVAL" | jq . ;;
    lease)    printf '%s\n' "$ORDO_CONTRACTS_TRANSITIONS_LEASE" | jq . ;;
    *)
      _ordo_contracts_fail unknown_table "unknown transition table: '${table}'" \
        "$(jq -cn --arg table "$table" --arg tables "$ORDO_CONTRACTS_TABLES" '{"table": $table, "known": ($tables | split(" "))}')"
      return $?
      ;;
  esac
}

ordo_contracts_transition() {
  local table="${1-}" from="${2-}" to="${3-}"
  if [[ $# -lt 3 ]]; then
    _ordo_contracts_fail usage "usage: ordo_contracts_transition <table> <from> <to>"
    return $?
  fi
  local tbl
  tbl=$(ordo_contracts_transitions "$table" 2>/dev/null) || {
    _ordo_contracts_fail unknown_table "unknown transition table: '${table}'" \
      "$(jq -cn --arg table "$table" --arg tables "$ORDO_CONTRACTS_TABLES" '{"table": $table, "known": ($tables | split(" "))}')"
    return $?
  }
  local state
  for state in "$from" "$to"; do
    if ! printf '%s' "$tbl" | jq -e --arg s "$state" 'has($s)' >/dev/null; then
      _ordo_contracts_fail unknown_state "unknown state '${state}' for table ${table}" \
        "$(printf '%s' "$tbl" | jq -c --arg table "$table" --arg state "$state" '{"table": $table, "state": $state, "known": keys}')"
      return $?
    fi
  done
  if printf '%s' "$tbl" | jq -e --arg f "$from" --arg t "$to" '.[$f] | index([$t]) != null' >/dev/null; then
    return 0
  fi
  _ordo_contracts_fail invalid_transition "transition ${from} -> ${to} is not allowed in table ${table}" \
    "$(printf '%s' "$tbl" | jq -c --arg table "$table" --arg from "$from" --arg to "$to" \
        '{"table": $table, "from": $from, "to": $to, "allowed": .[$from], "terminal": ((.[$from] | length) == 0)}')"
  return $?
}

ordo_contracts_is_terminal() {
  local table="${1-}" state="${2-}"
  if [[ $# -lt 2 ]]; then
    _ordo_contracts_fail usage "usage: ordo_contracts_is_terminal <table> <state>"
    return $?
  fi
  local tbl
  tbl=$(ordo_contracts_transitions "$table" 2>/dev/null) || {
    _ordo_contracts_fail unknown_table "unknown transition table: '${table}'" \
      "$(jq -cn --arg table "$table" --arg tables "$ORDO_CONTRACTS_TABLES" '{"table": $table, "known": ($tables | split(" "))}')"
    return $?
  }
  if ! printf '%s' "$tbl" | jq -e --arg s "$state" 'has($s)' >/dev/null; then
    _ordo_contracts_fail unknown_state "unknown state '${state}' for table ${table}" \
      "$(printf '%s' "$tbl" | jq -c --arg table "$table" --arg state "$state" '{"table": $table, "state": $state, "known": keys}')"
    return $?
  fi
  if printf '%s' "$tbl" | jq -e --arg s "$state" '(.[$s] | length) == 0' >/dev/null; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Redaction. Keys matching the secret-key regex get "[REDACTED]" as value;
# token-looking values are masked wherever they appear (strings at any
# depth, including inside arrays). Output is compact JSON, always parseable.
# ---------------------------------------------------------------------------
ORDO_CONTRACTS_REDACT_KEY_RE='token|secret|password|passwd|api[_-]?key|authorization|cookie'
ORDO_CONTRACTS_REDACT_VALUE_RE='gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|Bearer [A-Za-z0-9._-]{20,}'
ORDO_CONTRACTS_REDACT_MASK='[REDACTED]'

ordo_contracts_redact() {
  local arg="${1-}"
  if [[ $# -lt 1 ]]; then
    _ordo_contracts_fail usage "usage: ordo_contracts_redact <json|-|@path>"
    return $?
  fi
  local raw
  if ! raw=$(_ordo_contracts_read_json_arg "$arg"); then
    _ordo_contracts_fail not_found "cannot read JSON input: ${arg}" \
      "$(jq -cn --arg input "$arg" '{"input": $input}')"
    return $?
  fi
  local out
  if ! out=$(printf '%s' "$raw" | jq -c \
      --arg key_re "$ORDO_CONTRACTS_REDACT_KEY_RE" \
      --arg value_re "$ORDO_CONTRACTS_REDACT_VALUE_RE" \
      --arg mask "$ORDO_CONTRACTS_REDACT_MASK" '
      walk(
        if type == "object" then
          with_entries(if (.key | test($key_re; "i")) then .value = $mask else . end)
        elif type == "string" then
          gsub($value_re; $mask)
        else . end)' 2>/dev/null); then
    _ordo_contracts_fail invalid_json "input is not valid JSON"
    return $?
  fi
  printf '%s\n' "$out"
}
