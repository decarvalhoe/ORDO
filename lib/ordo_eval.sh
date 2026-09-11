#!/usr/bin/env bash
# lib/ordo_eval.sh — trajectory evaluation and failure-injection harness (#813, epic #806).
#
# Runs scripted scenarios against the agentic control plane in a fully fake
# world: an isolated PROJECT/state directory, ORDO_RUNTIME_ADAPTER=fake,
# ORDO_PROVIDER_ADAPTER=fake (fixtures copied from tests/fixtures), a pinned
# clock (ORDO_JOURNAL_NOW), the scheduler (lib/ordo_scheduler.sh), the
# approval bridge (lib/ordo_approval.sh) and the trace spans
# (lib/ordo_trace.sh). No network, no gh/tmux/curl/ssh: guard stubs sit first
# on PATH inside the sandbox and every invocation is recorded and refused.
#
# A scenario (JSON, see docs/architecture/evaluation.md) declares runs to
# enqueue, a policy, and an ordered list of steps: ticks, clock advances,
# heartbeats, provider reads (with retry), approvals (request / grant / deny /
# execute through the bridge), parks (wait / block / require_approval),
# resume / complete / fail / cancel, recovery, fixture injection (provider
# outage, network timeout), a process crash inside a journal write
# (ORDO_JOURNAL_FAULT=kill_before_commit), a dead lease owner, duplicate
# deliveries. The full trajectory — journal events, projections, leases,
# approvals, trace spans, provider mutations and ledger, runtime events,
# evidence artifacts, per-step results — is written to a directory and
# normalised so that two runs of the same scenario are byte-identical.
#
# Public API (functions prefixed ordo_eval_):
#   ordo_eval_run <scenario.json> [--out DIR] [--work DIR] [--keep]   # run, write the trajectory, print the summary
#   ordo_eval_score <trajectory_dir> <expected.json>                  # print the score card; 0 pass / 1 fail
#   ordo_eval_baseline <scenario.json>... [--out FILE]                 # run + score each, print/write the baseline
#   ordo_eval_check <baseline.json> <scenario.json>...                 # run + score, compare; 1 on regression + diff
#   ordo_eval_digest <trajectory_dir>                                  # sha256 of every file except idmap.json (determinism)
#   ordo_eval_scenarios <dir>                                          # scenario paths of a fixture directory
#   ordo_eval_expected_for <scenario.json>                             # path of the sibling *.expected.json
#   ordo_eval_normalize <map-file> <file>...                           # in-place volatile-id normalisation
#
# Errors: ONE JSON line on stderr {"error":{"code","message","module":"eval","details"}}
# and the contract exit code: 1 score/baseline failure, 2 usage, 3 forbidden
# tool invoked (fail-closed), 4 not found, 5 invalid scenario / step mismatch.
# Full reference: docs/architecture/evaluation.md.

if [[ -n "${ORDO_EVAL_LIB_LOADED:-}" ]]; then
  return 0
fi
ORDO_EVAL_LIB_LOADED=1

_ORDO_EVAL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORDO_EVAL_TK="${TK:-$(cd "$_ORDO_EVAL_LIB_DIR/.." && pwd)}"
if ! declare -F ordo_contracts_error >/dev/null 2>&1; then
  # shellcheck source=lib/ordo_contracts.sh
  source "$_ORDO_EVAL_LIB_DIR/ordo_contracts.sh"
fi

ORDO_EVAL_MODULE="eval"
ORDO_EVAL_SCHEMA_VERSION="1"
ORDO_EVAL_DEAD_PID=4194305                 # above pid_max on every Linux: kill -0 always fails
ORDO_EVAL_FORBIDDEN_TOOLS="gh glab tmux curl ssh wget"
ORDO_EVAL_TRAJECTORY_FILES="scenario.json steps.jsonl events.jsonl runs.json leases.jsonl approvals.jsonl traces.jsonl mutations.jsonl ledger.jsonl runtime_events.jsonl artifacts.jsonl summary.json"
: "${ORDO_EVAL_DEFAULT_FIXTURES:=adapters/fake}"

_ordo_eval_fail() {
  ordo_contracts_error "$ORDO_EVAL_MODULE" "$@"
}

_ordo_eval_json_file() {
  # <path> -> compact JSON or 4/5 error
  local path="$1" doc
  if [[ ! -r "$path" ]]; then
    _ordo_eval_fail not_found "file not found: ${path}" "$(jq -cn --arg p "$path" '{"path": $p}')"
    return $?
  fi
  if ! doc=$(jq -c . "$path" 2>/dev/null) || [[ -z "$doc" ]]; then
    _ordo_eval_fail invalid_json "not valid JSON: ${path}" "$(jq -cn --arg p "$path" '{"path": $p}')"
    return $?
  fi
  printf '%s\n' "$doc"
}

_ordo_eval_epoch() { date -u -d "${1:?}" +%s 2>/dev/null || printf '0'; }
_ordo_eval_ts() { date -u -d "@${1:?}" +%Y-%m-%dT%H:%M:%SZ; }

# ordo_eval_expected_for <scenario.json> -> <dir>/<name>.expected.json
ordo_eval_expected_for() {
  local scenario="${1:?usage: ordo_eval_expected_for <scenario.json>}"
  printf '%s/%s.expected.json\n' "$(dirname "$scenario")" "$(basename "$scenario" .json)"
}

# ordo_eval_scenarios <dir> -> every <dir>/*.json that is not an expected/baseline file
ordo_eval_scenarios() {
  local dir="${1:?usage: ordo_eval_scenarios <dir>}" f
  if [[ ! -d "$dir" ]]; then
    _ordo_eval_fail not_found "scenario directory not found: ${dir}" "$(jq -cn --arg d "$dir" '{"dir": $d}')"
    return $?
  fi
  for f in "$dir"/*.json; do
    [[ -f "$f" ]] || continue
    case "$(basename "$f")" in
      *.expected.json|baseline.json) continue ;;
    esac
    printf '%s\n' "$f"
  done
}

# ---------------------------------------------------------------------------
# Normalisation of volatile identifiers (documented in evaluation.md):
#   <kind>_<hex>   contract ids (run, lease, approval, event, attempt,
#                  policy_decision, blocker, ...) -> zero-padded counter per kind,
#                  same length, in order of first appearance;
#   32/16 hex      trace / span ids -> counters, same length;
#   @evalhost:PID  lease owner pids -> 100001, 100002, ...;
#   <WORK>/<TK>    sandbox and toolkit paths.
# Files are processed in the given order so the mapping is a pure function
# of the (deterministic) content. The map is written to <map-file>.
# ---------------------------------------------------------------------------
IFS= read -r -d '' ORDO_EVAL_NORMALIZE_PY <<'PY' || true
import json
import os
import re
import sys

map_file = sys.argv[1]
files = sys.argv[2:]
work = os.environ.get("ORDO_EVAL_WORK", "")
tk = os.environ.get("ORDO_EVAL_TK", "")
KINDS = "run|task|attempt|agent|lease|event|approval|artifact|policy_decision|blocker"
PAT_ID = re.compile(r"\b(%s)_([0-9a-f]{12,24})\b" % KINDS)
PAT_HEX = re.compile(r"(?<![0-9a-fA-Z_-])([0-9a-f]{32}|[0-9a-f]{16})(?![0-9a-fA-Z_-])")
PAT_PID = re.compile(r"@evalhost:(\d+)\b")
# runtime-evidence/<target>-<real stamp>-<label>-<pid>.txt: the runtime adapter names captures with the
# wall clock and its pid; the capture itself is copied under evidence/ with a deterministic name.
PAT_EVIDENCE = re.compile(r"(runtime-evidence/[A-Za-z0-9._-]+)-\d{8}T\d{6}Z-([A-Za-z0-9._-]+)-\d+\.txt")
maps = {"ids": {}, "hex": {}, "pids": {}}
counters = {}


def counter(kind):
    counters[kind] = counters.get(kind, 0) + 1
    return counters[kind]


def norm_id(m):
    kind, raw = m.group(1), m.group(2)
    key = "%s_%s" % (kind, raw)
    if key not in maps["ids"]:
        maps["ids"][key] = "%s_%0*d" % (kind, len(raw), counter(kind))
    return maps["ids"][key]


def norm_hex(m):
    raw = m.group(1)
    if raw not in maps["hex"]:
        kind = "trace" if len(raw) == 32 else "span"
        maps["hex"][raw] = "%0*d" % (len(raw), counter(kind))
    return maps["hex"][raw]


def norm_pid(m):
    raw = m.group(1)
    if raw not in maps["pids"]:
        maps["pids"][raw] = str(100000 + counter("pid"))
    return "@evalhost:" + maps["pids"][raw]


for path in files:
    if not os.path.isfile(path):
        continue
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    if work:
        text = text.replace(work, "<WORK>")
    if tk:
        text = text.replace(tk, "<TK>")
    text = PAT_EVIDENCE.sub(r"\1-<STAMP>-\2-<PID>.txt", text)
    text = PAT_ID.sub(norm_id, text)
    text = PAT_HEX.sub(norm_hex, text)
    text = PAT_PID.sub(norm_pid, text)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)

with open(map_file, "w", encoding="utf-8") as fh:
    json.dump(maps, fh, sort_keys=True, indent=1)
    fh.write("\n")
PY

# ordo_eval_normalize <map-file> <file>...
ordo_eval_normalize() {
  local map="${1-}"
  if [[ -z "$map" || $# -lt 2 ]]; then
    _ordo_eval_fail usage "usage: ordo_eval_normalize <map-file> <file>..."
    return $?
  fi
  shift
  local pybin
  if ! pybin=$(command -v "${ORDO_JOURNAL_PYTHON_BIN:-python3}" 2>/dev/null); then
    _ordo_eval_fail missing_dependency "python3 is required by the eval harness" '{"dependency":"python3"}'
    return $?
  fi
  "$pybin" - "$map" "$@" <<<"$ORDO_EVAL_NORMALIZE_PY"
}

# ordo_eval_digest <trajectory_dir> -> "<sha256>  <file>" lines (idmap.json excluded)
ordo_eval_digest() {
  local dir="${1-}"
  if [[ -z "$dir" || ! -d "$dir" ]]; then
    _ordo_eval_fail not_found "trajectory directory not found: ${dir}" "$(jq -cn --arg d "$dir" '{"dir": $d}')"
    return $?
  fi
  (cd "$dir" && find . -type f ! -name idmap.json | sort | xargs sha256sum)
}

# ---------------------------------------------------------------------------
# Scenario execution (everything below _ordo_eval_sandbox runs in a subshell)
# ---------------------------------------------------------------------------
# _ordo_eval_validate_scenario <json> -> 0 or 5 invalid_contract
_ordo_eval_validate_scenario() {
  local doc="$1" errors
  errors=$(printf '%s' "$doc" | jq -c '
    [ (if (.name | type) != "string" or (.name | test("^[a-z0-9_-]+$") | not) then "name must match ^[a-z0-9_-]+$" else empty end),
      (if (.clock | type) != "string" or (.clock | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") | not) then "clock must be an RFC3339 UTC timestamp" else empty end),
      (if (.runs | type) != "array" then "runs must be an array" else empty end),
      (if (.steps | type) != "array" then "steps must be an array" else empty end),
      (if ((.runs // []) | map(.alias // "") | (length == (unique | length)) and all(test("^[a-z0-9_-]+$"))) | not then "every run needs a unique alias" else empty end),
      (if ((.steps // []) | all((.op | type) == "string")) | not then "every step needs an op" else empty end)
    ]')
  if [[ "$errors" != "[]" ]]; then
    _ordo_eval_fail invalid_contract "scenario is not valid" "$(printf '%s' "$errors" | jq -c '{"errors": .}')"
    return $?
  fi
}

_ordo_eval_run_id() {
  # <alias> -> run id (5 when unknown)
  local alias="${1-}"
  if [[ -z "$alias" || -z "${_OE_RUNS[$alias]:-}" ]]; then
    _ordo_eval_fail invalid_state "unknown run alias '${alias}'" "$(jq -cn --arg a "$alias" '{"alias": $a}')"
    return $?
  fi
  printf '%s' "${_OE_RUNS[$alias]}"
}

_ordo_eval_approval_id() {
  local ref="${1-}"
  if [[ -z "$ref" || -z "${_OE_APPROVALS[$ref]:-}" ]]; then
    _ordo_eval_fail invalid_state "unknown approval ref '${ref}'" "$(jq -cn --arg a "$ref" '{"ref": $a}')"
    return $?
  fi
  printf '%s' "${_OE_APPROVALS[$ref]}"
}

_ordo_eval_agent_actor() { printf '{"type":"agent","id":"eval-agent"}'; }
_ordo_eval_operator_actor() { printf '{"type":"operator","id":"%s"}' "${ORDO_OPERATOR:-eval-operator}"; }

# _ordo_eval_actor_spec <step-json> -> actor JSON from .by / .actor (default: operator)
_ordo_eval_actor_spec() {
  local spec
  spec=$(printf '%s' "$1" | jq -r '.actor // .by // ""')
  if [[ -z "$spec" ]]; then
    _ordo_eval_operator_actor
    return 0
  fi
  ordo_approval_actor_json "$spec"
}

# _ordo_eval_journal <alias> <type> <payload> — harness evidence of what the "agent" did
_ordo_eval_journal() {
  local run_id
  run_id=$(_ordo_eval_run_id "$1") || return $?
  ordo_journal_append "$run_id" "$2" "$3" --actor "$(_ordo_eval_agent_actor)" >/dev/null
}

# _ordo_eval_span_start <alias> <name> <kind> [attr=v ...] -> span_id (trace of the run)
_ordo_eval_span_start() {
  local alias="$1" name="$2" kind="$3" run_id trace
  shift 3
  run_id=$(_ordo_eval_run_id "$alias") || return $?
  trace=$(ordo_trace_new_id trace "$run_id")
  local -a attrs=()
  local a
  for a in "$@"; do attrs+=(--attr "$a"); done
  ORDO_RUN_ID="$run_id" ordo_trace_start "$name" --kind "$kind" --trace "$trace" "${attrs[@]+"${attrs[@]}"}"
}

_ordo_eval_span_end() {
  # <alias> <span_id> <rc> [attr=v ...]
  local alias="$1" span="$2" rc="$3" run_id trace
  shift 3
  run_id=$(_ordo_eval_run_id "$alias") || return $?
  trace=$(ordo_trace_new_id trace "$run_id")
  local -a attrs=()
  local a
  for a in "$@"; do attrs+=(--attr "$a"); done
  if [[ "$rc" -eq 0 ]]; then
    ordo_trace_end "$span" --trace "$trace" --status ok "${attrs[@]+"${attrs[@]}"}"
  else
    ordo_trace_end "$span" --trace "$trace" --status error --message "exit ${rc}" --attr "ordo.exit_code=$rc" "${attrs[@]+"${attrs[@]}"}"
  fi
}

# _ordo_eval_args <step-json> [key] -> one argument per line (array of strings)
_ordo_eval_args() {
  printf '%s' "$1" | jq -r --arg k "${2:-args}" '(.[$k] // []) | .[] | tostring'
}

# ---- step implementations: print a JSON result, return the module rc --------
_ordo_eval_step_enqueue() {
  local step="$1" alias
  alias=$(printf '%s' "$step" | jq -r '.alias // ""')
  [[ -n "$alias" ]] || { _ordo_eval_fail invalid_contract "enqueue needs an alias"; return $?; }
  local -a opts=()
  local v
  v=$(printf '%s' "$step" | jq -r '.title // ""');      [[ -n "$v" ]] && opts+=(--title "$v")
  v=$(printf '%s' "$step" | jq -r '.ticket // ""');     [[ -n "$v" ]] && opts+=(--ticket "$v")
  v=$(printf '%s' "$step" | jq -r '.priority // ""');   [[ -n "$v" ]] && opts+=(--priority "$v")
  v=$(printf '%s' "$step" | jq -c '.budget // empty');  [[ -n "$v" ]] && opts+=(--budget "$v")
  v=$(printf '%s' "$step" | jq -c '.metadata // empty'); [[ -n "$v" ]] && opts+=(--metadata "$v")
  v=$(printf '%s' "$step" | jq -c '.readiness // empty'); [[ -n "$v" ]] && opts+=(--readiness "$v")
  v=$(printf '%s' "$step" | jq -r '.not_before // ""'); [[ -n "$v" ]] && opts+=(--not-before "$v")
  v=$(printf '%s' "$step" | jq -r '.expires_at // ""'); [[ -n "$v" ]] && opts+=(--expires-at "$v")
  v=$(printf '%s' "$step" | jq -r '.max_retries // ""'); [[ -n "$v" ]] && opts+=(--max-retries "$v")
  local deps="" dep dep_id
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    dep_id=$(_ordo_eval_run_id "$dep") || return $?
    deps="${deps:+$deps,}$dep_id"
  done < <(_ordo_eval_args "$step" depends_on)
  [[ -n "$deps" ]] && opts+=(--depends-on "$deps")
  local target
  target=$(printf '%s' "$step" | jq -r '.runtime_target // ""')
  if [[ -n "$target" ]]; then
    ordo_runtime recover "$target" --workdir "/work/$alias" --command eval-agent >/dev/null || return $?
    local brief="$_OE_WORK/briefs/$alias.md"
    mkdir -p "$_OE_WORK/briefs"
    printf '# %s\n\n%s\n' "$alias" "$(printf '%s' "$step" | jq -r '.brief // .title // "work"')" > "$brief"
    opts+=(--runtime-target "$target" --text-file "$brief")
  fi
  local out run_id
  out=$(ordo_scheduler_enqueue --actor "$(_ordo_eval_operator_actor)" "${opts[@]+"${opts[@]}"}") || return $?
  run_id=$(printf '%s' "$out" | jq -r .run_id)
  _OE_RUNS[$alias]="$run_id"
  _OE_RUN_ORDER+=("$alias")
  printf '%s' "$out" | jq -c --arg alias "$alias" '. + {"alias": $alias}'
}

_ordo_eval_step_tick() {
  local step="$1" pid="$ORDO_SCHED_WORKER_PID" max
  case "$(printf '%s' "$step" | jq -r '.worker_pid // ""')" in
    "") ;;
    dead) pid="$ORDO_EVAL_DEAD_PID" ;;
    *) pid=$(printf '%s' "$step" | jq -r '.worker_pid') ;;
  esac
  max=$(printf '%s' "$step" | jq -r '.max_picks // ""')
  local -a opts=(--actor "$(_ordo_eval_agent_actor)")
  [[ -n "$max" ]] && opts+=(--max-picks "$max")
  ORDO_SCHED_WORKER_PID="$pid" ordo_scheduler_tick "${opts[@]}"
}

_ordo_eval_step_advance() {
  local seconds now
  seconds=$(printf '%s' "$1" | jq -r '.seconds // 0')
  now=$(_ordo_eval_ts "$(( $(_ordo_eval_epoch "$ORDO_JOURNAL_NOW") + seconds ))")
  export ORDO_JOURNAL_NOW="$now"
  jq -cn --arg now "$now" --argjson s "$seconds" '{"now": $now, "advanced_seconds": $s}'
}

_ordo_eval_step_clock() {
  local at
  at=$(printf '%s' "$1" | jq -r '.at // ""')
  [[ -n "$at" ]] || { _ordo_eval_fail invalid_contract "clock needs .at"; return $?; }
  export ORDO_JOURNAL_NOW="$at"
  jq -cn --arg now "$at" '{"now": $now}'
}

_ordo_eval_step_heartbeat() {
  local step="$1" run_id usage
  run_id=$(_ordo_eval_run_id "$(printf '%s' "$step" | jq -r '.run // ""')") || return $?
  usage=$(printf '%s' "$step" | jq -c '.usage // {}')
  ordo_scheduler_heartbeat "$run_id" --usage "$usage" --actor "$(_ordo_eval_agent_actor)"
}

_ordo_eval_step_usage() {
  local step="$1" run_id usage
  run_id=$(_ordo_eval_run_id "$(printf '%s' "$step" | jq -r '.run // ""')") || return $?
  usage=$(printf '%s' "$step" | jq -c '.usage // {}')
  ordo_scheduler_report_usage "$run_id" "$usage" --actor "$(_ordo_eval_agent_actor)"
}

_ordo_eval_step_readiness() {
  local step="$1" alias payload
  alias=$(printf '%s' "$step" | jq -r '.run // ""')
  payload=$(printf '%s' "$step" | jq -c '{"metadata": {"readiness": {"state": (.state // "unknown"), "source": (.source // "eval")}}}')
  _ordo_eval_journal "$alias" run.updated "$payload" || return $?
  printf '%s' "$payload" | jq -c --arg alias "$alias" '{"alias": $alias, "readiness": .metadata.readiness}'
}

# provider read with optional retry: {"op":"provider","run":A,"args":[op,...],
#   "retry":{"max":N,"backoff_seconds":S,"heal_after":K}}
# heal_after restores every injected fixture after K failed attempts (outage recovery).
_ordo_eval_step_provider() {
  local step="$1" alias op max backoff heal attempt=0 rc out err span rspan
  alias=$(printf '%s' "$step" | jq -r '.run // ""')
  local -a args=()
  mapfile -t args < <(_ordo_eval_args "$step")
  op="${args[0]:-}"
  [[ -n "$op" ]] || { _ordo_eval_fail invalid_contract "provider needs args [op, ...]"; return $?; }
  max=$(printf '%s' "$step" | jq -r '.retry.max // 1')
  backoff=$(printf '%s' "$step" | jq -r '.retry.backoff_seconds // 0')
  heal=$(printf '%s' "$step" | jq -r '.retry.heal_after // -1')
  span=""
  [[ -n "$alias" ]] && { span=$(_ordo_eval_span_start "$alias" "provider.${op}" provider "provider.op=$op" "provider.adapter=fake") || return $?; }
  local attempts="[]" retryable code
  while (( attempt < max )); do
    attempt=$((attempt + 1))
    rspan=""
    # One retry span per attempt, only when a retry policy is in force.
    [[ -n "$alias" && "$max" -gt 1 ]] && rspan=$(_ordo_eval_span_start "$alias" "retry.attempt" retry "retry.attempt=$attempt" "provider.op=$op")
    rc=0; err=""
    out=$(ordo_provider "${args[@]}" 2>"$_OE_WORK/err") || rc=$?
    err=$(tail -n 1 "$_OE_WORK/err" | jq -c 'select(.error)' 2>/dev/null || true)
    retryable=$(printf '%s' "${err:-{\}}" | jq -r '.error.details.retryable // false')
    code=$(printf '%s' "${err:-{\}}" | jq -r '.error.code // ""')
    attempts=$(printf '%s' "$attempts" | jq -c --argjson n "$attempt" --argjson rc "$rc" --arg code "$code" --argjson retryable "$retryable" --arg now "$ORDO_JOURNAL_NOW" \
      '. + [{"attempt": $n, "rc": $rc, "at": $now, "error_code": (if $code == "" then null else $code end), "retryable": $retryable}]')
    [[ -n "$rspan" ]] && _ordo_eval_span_end "$alias" "$rspan" "$rc" "retry.retryable=$retryable" >/dev/null
    if [[ "$rc" -eq 0 ]]; then break; fi
    if [[ "$retryable" != true ]] || (( attempt >= max )); then break; fi
    if (( heal >= 0 && attempt >= heal )); then _ordo_eval_restore_fixtures; fi
    if (( backoff > 0 )); then _ordo_eval_step_advance "$(jq -cn --argjson s "$backoff" '{"seconds": $s}')" >/dev/null; fi
  done
  if [[ -n "$alias" ]]; then
    _ordo_eval_span_end "$alias" "$span" "$rc" "provider.attempts=$attempt" >/dev/null
    _ordo_eval_journal "$alias" provider.read \
      "$(jq -cn --arg op "$op" --argjson args "$(printf '%s\n' "${args[@]:1}" | jq -R . | jq -sc 'map(select(. != ""))')" --argjson rc "$rc" --argjson attempts "$attempts" \
        '{"op": $op, "args": $args, "rc": $rc, "attempts": $attempts}')" || return $?
  fi
  if [[ "$rc" -ne 0 ]]; then
    printf '%s\n' "$err" >&2
    jq -cn --argjson attempts "$attempts" --argjson err "${err:-null}" '{"attempts": $attempts, "response": null, "error": $err}'
    return "$rc"
  fi
  printf '%s' "$out" | jq -c --argjson attempts "$attempts" '{"attempts": $attempts, "response": .}'
}

# direct mutation delivery (no bridge): {"op":"mutate","run":A,"key":K,"args":[op,...]}
_ordo_eval_step_mutate() {
  local step="$1" alias key op rc out err span
  alias=$(printf '%s' "$step" | jq -r '.run // ""')
  key=$(printf '%s' "$step" | jq -r '.key // ""')
  local -a args=()
  mapfile -t args < <(_ordo_eval_args "$step")
  op="${args[0]:-}"
  [[ -n "$op" && -n "$key" ]] || { _ordo_eval_fail invalid_contract "mutate needs .key and args [op, ...]"; return $?; }
  span=""
  [[ -n "$alias" ]] && { span=$(_ordo_eval_span_start "$alias" "provider.${op}" provider "provider.op=$op" "provider.idempotency_key=$key" "provider.delivery=direct") || return $?; }
  rc=0
  out=$(ordo_provider "${args[@]}" --idempotency-key "$key" 2>"$_OE_WORK/err") || rc=$?
  err=$(tail -n 1 "$_OE_WORK/err" | jq -c 'select(.error)' 2>/dev/null || true)
  [[ -n "$alias" ]] && _ordo_eval_span_end "$alias" "$span" "$rc" >/dev/null
  if [[ -n "$alias" ]]; then
    if [[ "$rc" -eq 0 ]]; then
      # Journaled as a mutation with the key: a second delivery is a duplicate_event (5), which is the point.
      ordo_journal_append "$(_ordo_eval_run_id "$alias")" provider.mutation_delivered \
        "$(printf '%s' "$out" | jq -c --arg key "$key" '{"idempotency_key": $key, "receipt": .}')" \
        --mutation --idempotency-key "$key" --actor "$(_ordo_eval_agent_actor)" >/dev/null 2>&1 || true
    else
      _ordo_eval_journal "$alias" provider.mutation_refused \
        "$(jq -cn --arg key "$key" --arg op "$op" --argjson rc "$rc" --argjson err "${err:-null}" '{"idempotency_key": $key, "op": $op, "rc": $rc, "error": $err}')" >/dev/null || true
    fi
  fi
  if [[ "$rc" -ne 0 ]]; then
    printf '%s\n' "$err" >&2
    jq -cn --arg key "$key" --argjson err "${err:-null}" '{"idempotency_key": $key, "delivery": "direct", "receipt": null, "error": $err}'
    return "$rc"
  fi
  printf '%s' "$out" | jq -c --arg key "$key" '{"idempotency_key": $key, "delivery": "direct", "receipt": .}'
}

_ordo_eval_step_require_approval() {
  local step="$1" run_id action reason
  run_id=$(_ordo_eval_run_id "$(printf '%s' "$step" | jq -r '.run // ""')") || return $?
  action=$(printf '%s' "$step" | jq -r '.action // ""')
  reason=$(printf '%s' "$step" | jq -r '.reason // "approval required"')
  local -a opts=(--reason "$reason" --actor "$(_ordo_eval_agent_actor)")
  [[ -n "$action" ]] && opts+=(--action "$action")
  local deadline
  deadline=$(printf '%s' "$step" | jq -r '.deadline // ""')
  [[ -n "$deadline" ]] && opts+=(--deadline "$deadline")
  ordo_scheduler_require_approval "$run_id" "${opts[@]}"
}

_ordo_eval_step_approval_request() {
  local step="$1" run_id ref action principal key ttl payload out id
  run_id=$(_ordo_eval_run_id "$(printf '%s' "$step" | jq -r '.run // ""')") || return $?
  ref=$(printf '%s' "$step" | jq -r '.ref // ""')
  action=$(printf '%s' "$step" | jq -r '.action // ""')
  principal=$(printf '%s' "$step" | jq -r '.principal // ""')
  key=$(printf '%s' "$step" | jq -r '.key // ""')
  ttl=$(printf '%s' "$step" | jq -r '.ttl // ""')
  [[ -n "$ref" && -n "$action" ]] || { _ordo_eval_fail invalid_contract "approval_request needs .ref and .action"; return $?; }
  payload=$(printf '%s' "$step" | jq -c '(.payload // {}) + (if .args then {"args": (.args | map(tostring))} else {} end)')
  local -a opts=(--principal "$principal" --idempotency-key "$key" --payload "$payload" --actor "$(_ordo_eval_agent_actor)")
  [[ -n "$ttl" ]] && opts+=(--ttl "$ttl")
  out=$(ordo_approval_request "$run_id" "$action" "${opts[@]}") || return $?
  id=$(printf '%s' "$out" | jq -r .id)
  _OE_APPROVALS[$ref]="$id"
  printf '%s' "$out" | jq -c --arg ref "$ref" '. + {"ref": $ref}'
}

_ordo_eval_step_grant() {
  local step="$1" id actor reason
  id=$(_ordo_eval_approval_id "$(printf '%s' "$step" | jq -r '.approval // ""')") || return $?
  actor=$(_ordo_eval_actor_spec "$step") || return $?
  reason=$(printf '%s' "$step" | jq -r '.reason // "granted by scenario"')
  ordo_approval_grant "$id" --by "$actor" --reason "$reason"
}

_ordo_eval_step_deny() {
  local step="$1" id actor reason
  id=$(_ordo_eval_approval_id "$(printf '%s' "$step" | jq -r '.approval // ""')") || return $?
  actor=$(_ordo_eval_actor_spec "$step") || return $?
  reason=$(printf '%s' "$step" | jq -r '.reason // "denied by scenario"')
  ordo_approval_deny "$id" --by "$actor" --reason "$reason"
}

_ordo_eval_step_sweep() {
  ordo_approval_sweep --actor '{"type":"system","id":"eval-sweeper"}'
}

# execute through the bridge: {"op":"execute","approval":REF,"args":[op,...],"actor":...}
_ordo_eval_step_execute() {
  local step="$1" id actor rc out err key
  id=$(_ordo_eval_approval_id "$(printf '%s' "$step" | jq -r '.approval // ""')") || return $?
  actor=$(_ordo_eval_actor_spec "$step") || return $?
  local -a args=()
  mapfile -t args < <(_ordo_eval_args "$step")
  [[ "${#args[@]}" -ge 1 ]] || { _ordo_eval_fail invalid_contract "execute needs args [op, ...]"; return $?; }
  key=$(ordo_journal_approval_get "$id" 2>/dev/null | jq -r '.idempotency_key // ""')
  rc=0
  out=$(ordo_approval_authorize_and_run "$id" --actor "$actor" -- "${args[@]}" 2>"$_OE_WORK/err") || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    err=$(tail -n 1 "$_OE_WORK/err" | jq -c 'select(.error)' 2>/dev/null || true)
    printf '%s\n' "$err" >&2
    jq -cn --arg key "$key" --argjson err "${err:-null}" '{"idempotency_key": (if $key == "" then null else $key end), "delivery": "bridge", "receipt": null, "error": $err}'
    return "$rc"
  fi
  printf '%s' "$out" | jq -c --arg key "$key" '{"idempotency_key": $key, "delivery": "bridge", "receipt": .}'
}

_ordo_eval_step_resume() {
  local step="$1" run_id reason
  run_id=$(_ordo_eval_run_id "$(printf '%s' "$step" | jq -r '.run // ""')") || return $?
  reason=$(printf '%s' "$step" | jq -r '.reason // "resumed"')
  local -a opts=(--reason "$reason" --actor "$(_ordo_eval_operator_actor)")
  [[ "$(printf '%s' "$step" | jq -r '.requeue // false')" == true ]] && opts+=(--requeue)
  ordo_scheduler_resume "$run_id" "${opts[@]}"
}

_ordo_eval_step_complete() {
  local step="$1" run_id result
  run_id=$(_ordo_eval_run_id "$(printf '%s' "$step" | jq -r '.run // ""')") || return $?
  result=$(printf '%s' "$step" | jq -c '.result // {}')
  ordo_scheduler_complete "$run_id" --result "$result" --actor "$(_ordo_eval_agent_actor)"
}

_ordo_eval_step_fail() {
  local step="$1" run_id reason
  run_id=$(_ordo_eval_run_id "$(printf '%s' "$step" | jq -r '.run // ""')") || return $?
  reason=$(printf '%s' "$step" | jq -r '.reason // "failed"')
  ordo_scheduler_fail "$run_id" --reason "$reason" --actor "$(_ordo_eval_operator_actor)"
}

_ordo_eval_step_wait() {
  local step="$1" run_id reason deadline
  run_id=$(_ordo_eval_run_id "$(printf '%s' "$step" | jq -r '.run // ""')") || return $?
  reason=$(printf '%s' "$step" | jq -r '.reason // "waiting"')
  deadline=$(printf '%s' "$step" | jq -r '.deadline // ""')
  local -a opts=(--reason "$reason" --actor "$(_ordo_eval_agent_actor)")
  [[ -n "$deadline" ]] && opts+=(--deadline "$deadline")
  ordo_scheduler_wait "$run_id" "${opts[@]}"
}

_ordo_eval_step_block() {
  local step="$1" run_id reason btype
  run_id=$(_ordo_eval_run_id "$(printf '%s' "$step" | jq -r '.run // ""')") || return $?
  reason=$(printf '%s' "$step" | jq -r '.reason // "blocked"')
  btype=$(printf '%s' "$step" | jq -r '.type // "external"')
  ordo_scheduler_block "$run_id" --reason "$reason" --type "$btype" --actor "$(_ordo_eval_agent_actor)"
}

_ordo_eval_step_cancel() {
  local step="$1" run_id reason
  run_id=$(_ordo_eval_run_id "$(printf '%s' "$step" | jq -r '.run // ""')") || return $?
  reason=$(printf '%s' "$step" | jq -r '.reason // "cancelled"')
  ordo_scheduler_cancel "$run_id" --reason "$reason" --actor "$(_ordo_eval_operator_actor)"
}

_ordo_eval_step_recover() {
  ordo_scheduler_recover --actor "$(_ordo_eval_operator_actor)"
}

# fixture injection: {"op":"fixture","path":"pr_get/12.json","json":{...}} | {"error":{...}} | {"restore":true}
_ordo_eval_backup_fixture() {
  local rel="$1"
  local src="$ORDO_FAKE_ADAPTER_DIR/$rel" backup="$_OE_WORK/fixture-backup/$rel"
  [[ -e "$backup" || -e "$backup.absent" ]] && return 0
  mkdir -p "$(dirname "$backup")"
  if [[ -f "$src" ]]; then cp "$src" "$backup"; else : > "$backup.absent"; fi
}

_ordo_eval_restore_fixtures() {
  local backup rel
  [[ -d "$_OE_WORK/fixture-backup" ]] || return 0
  while IFS= read -r backup; do
    rel="${backup#"$_OE_WORK/fixture-backup/"}"
    if [[ "$rel" == *.absent ]]; then
      rm -f "$ORDO_FAKE_ADAPTER_DIR/${rel%.absent}"
    else
      mkdir -p "$(dirname "$ORDO_FAKE_ADAPTER_DIR/$rel")"
      cp "$backup" "$ORDO_FAKE_ADAPTER_DIR/$rel"
    fi
  done < <(find "$_OE_WORK/fixture-backup" -type f | sort)
  rm -rf "$_OE_WORK/fixture-backup"
}

_ordo_eval_step_fixture() {
  local step="$1" rel
  rel=$(printf '%s' "$step" | jq -r '.path // ""')
  if [[ "$(printf '%s' "$step" | jq -r '.restore // false')" == true ]]; then
    _ordo_eval_restore_fixtures
    jq -cn '{"restored": true}'
    return 0
  fi
  [[ -n "$rel" && "$rel" != /* && "$rel" != *..* ]] || { _ordo_eval_fail invalid_contract "fixture needs a relative .path"; return $?; }
  _ordo_eval_backup_fixture "$rel"
  mkdir -p "$(dirname "$ORDO_FAKE_ADAPTER_DIR/$rel")"
  if printf '%s' "$step" | jq -e '.error | type == "object"' >/dev/null; then
    printf '%s' "$step" | jq -c '{"error": .error}' > "$ORDO_FAKE_ADAPTER_DIR/$rel"
    jq -cn --arg p "$rel" '{"path": $p, "injected": "error"}'
  elif printf '%s' "$step" | jq -e 'has("json")' >/dev/null; then
    printf '%s' "$step" | jq -c '.json' > "$ORDO_FAKE_ADAPTER_DIR/$rel"
    jq -cn --arg p "$rel" '{"path": $p, "injected": "json"}'
  else
    _ordo_eval_fail invalid_contract "fixture needs .json, .error or .restore"
    return $?
  fi
}

# runtime op on the run's target: {"op":"runtime","run":A,"args":["start","--text","..."]}
_ordo_eval_step_runtime() {
  local step="$1" alias run_id target
  alias=$(printf '%s' "$step" | jq -r '.run // ""')
  run_id=$(_ordo_eval_run_id "$alias") || return $?
  target=$(ordo_journal_project "$run_id" | jq -r '.metadata.runtime.target // ""')
  [[ -n "$target" ]] || { _ordo_eval_fail invalid_state "run '${alias}' has no runtime target"; return $?; }
  local -a args=()
  mapfile -t args < <(_ordo_eval_args "$step")
  [[ "${#args[@]}" -ge 1 ]] || { _ordo_eval_fail invalid_contract "runtime needs args [op, ...]"; return $?; }
  local op="${args[0]}" rc=0 out span
  span=$(_ordo_eval_span_start "$alias" "runtime.${op}" tool "runtime.op=$op" "runtime.target=$target") || return $?
  out=$(ordo_runtime "$op" "$target" "${args[@]:1}") || rc=$?
  _ordo_eval_span_end "$alias" "$span" "$rc" >/dev/null
  [[ "$rc" -eq 0 ]] || return "$rc"
  printf '%s\n' "$out"
}

# evidence capture -> artifact contract object stored under <traj>/evidence/
_ordo_eval_step_evidence() {
  local step="$1" alias run_id target label out path name sum bytes artifact
  alias=$(printf '%s' "$step" | jq -r '.run // ""')
  run_id=$(_ordo_eval_run_id "$alias") || return $?
  target=$(ordo_journal_project "$run_id" | jq -r '.metadata.runtime.target // ""')
  [[ -n "$target" ]] || { _ordo_eval_fail invalid_state "run '${alias}' has no runtime target"; return $?; }
  label=$(printf '%s' "$step" | jq -r '.label // "capture"')
  out=$(ordo_runtime collect_evidence "$target" --label "$label") || return $?
  path=$(printf '%s' "$out" | jq -r .path)
  _OE_ARTIFACT_N=$((_OE_ARTIFACT_N + 1))
  name="$(printf '%s-%02d-%s.txt' "$alias" "$_OE_ARTIFACT_N" "$label")"
  mkdir -p "$_OE_OUT/evidence"
  cp "$path" "$_OE_OUT/evidence/$name"
  sum=$(sha256sum "$_OE_OUT/evidence/$name" | awk '{print $1}')
  bytes=$(wc -c < "$_OE_OUT/evidence/$name" | tr -d ' ')
  artifact=$(jq -cn --arg id "$(ordo_contracts_new_id artifact)" --arg now "$ORDO_JOURNAL_NOW" --arg run_id "$run_id" \
    --arg uri "evidence/$name" --arg sum "$sum" --argjson bytes "$bytes" --arg label "$label" --arg target "$target" \
    '{"schema_version": "1", "kind": "artifact", "id": $id, "created_at": $now, "correlation_id": $run_id,
      "actor": {"type": "agent", "id": "eval-agent"}, "run_id": $run_id, "type": "evidence", "uri": $uri,
      "media_type": "text/plain", "sha256": $sum, "size_bytes": $bytes, "redacted": true,
      "metadata": {"label": $label, "target": $target}}')
  ordo_contracts_validate artifact "$artifact" || return $?
  printf '%s\n' "$artifact" >> "$_OE_OUT/artifacts.jsonl"
  _ordo_eval_journal "$alias" artifact.recorded "$(printf '%s' "$artifact" | jq -c '{"artifact_id": .id, "uri": .uri, "sha256": .sha256}')" || return $?
  printf '%s' "$artifact" | jq -c '{"artifact_id": .id, "uri": .uri, "sha256": .sha256, "size_bytes": .size_bytes}'
}

# process crash: {"op":"crash","during":{<step>},"at":"first_write"|"approval_consume"}
# The inner step runs with ORDO_JOURNAL_FAULT=kill_before_commit armed on the
# chosen journal write; it must fail (the crash is the expected outcome).
_ordo_eval_step_crash() {
  local step="$1" inner at rc=0 out
  inner=$(printf '%s' "$step" | jq -c '.during // empty')
  [[ -n "$inner" ]] || { _ordo_eval_fail invalid_contract "crash needs .during"; return $?; }
  at=$(printf '%s' "$step" | jq -r '.at // "first_write"')
  # shellcheck disable=SC2030 # the fault hook is scoped to this subshell on purpose
  out=$(
    exec 2>"$_OE_WORK/crash-err"
    case "$at" in
      first_write)
        export ORDO_JOURNAL_FAULT=kill_before_commit
        ;;
      approval_consume)
        eval "$(declare -f ordo_journal_approval_set_state | sed '1s/^ordo_journal_approval_set_state/_ordo_eval_orig_approval_set_state/')"
        # shellcheck disable=SC2317 # invoked indirectly by the approval bridge
        ordo_journal_approval_set_state() {
          if [[ "${2-}" == consumed ]]; then
            ORDO_JOURNAL_FAULT=kill_before_commit _ordo_eval_orig_approval_set_state "$@"
          else
            _ordo_eval_orig_approval_set_state "$@"
          fi
        }
        ;;
      *)
        _ordo_eval_fail invalid_contract "unknown crash point '${at}' (first_write|approval_consume)"
        exit $?
        ;;
    esac
    _ordo_eval_dispatch "$inner"
  ) || rc=$?
  local err
  err=$(grep -E '^\{' "$_OE_WORK/crash-err" | tail -n 1 | jq -c 'select(.error)' 2>/dev/null || true)
  if [[ "$rc" -eq 0 ]]; then
    _ordo_eval_fail invalid_state "crash injection at '${at}' did not interrupt the step" "$(jq -cn --arg at "$at" --argjson inner "$inner" '{"at": $at, "during": $inner}')"
    return $?
  fi
  # A crashed delivery still counts as a delivery: carry its idempotency key.
  local key=""
  case "$(printf '%s' "$inner" | jq -r '.op')" in
    execute) key=$(ordo_journal_approval_get "$(_ordo_eval_approval_id "$(printf '%s' "$inner" | jq -r '.approval // ""')" 2>/dev/null)" 2>/dev/null | jq -r '.idempotency_key // ""') ;;
    mutate) key=$(printf '%s' "$inner" | jq -r '.key // ""') ;;
  esac
  jq -cn --arg at "$at" --argjson inner "$inner" --argjson rc "$rc" --argjson err "${err:-null}" --arg key "$key" \
    '{"crashed": true, "at": $at, "during": $inner.op, "inner_rc": $rc, "inner_error": $err, "idempotency_key": (if $key == "" then null else $key end)}'
}

# _ordo_eval_dispatch <step-json> -> runs the step implementation
_ordo_eval_dispatch() {
  local step="$1" op fn
  op=$(printf '%s' "$step" | jq -r '.op // ""')
  fn="_ordo_eval_step_${op}"
  if ! declare -F "$fn" >/dev/null 2>&1; then
    _ordo_eval_fail invalid_contract "unknown step op '${op}'" "$(jq -cn --arg op "$op" '{"op": $op}')"
    return $?
  fi
  "$fn" "$step"
}

# _ordo_eval_check_step_expect <step-json> <rc> <result-json> <error-json> -> 0 ok / 1 mismatch (message on stdout)
_ordo_eval_check_step_expect() {
  local step="$1" rc="$2" result="$3" err="$4" expect
  expect=$(printf '%s' "$step" | jq -c '.expect // {}')
  local want
  want=$(printf '%s' "$expect" | jq -r '.error_code // ""')
  if [[ -n "$want" && "$(printf '%s' "${err:-{\}}" | jq -r '.error.code // ""')" != "$want" ]]; then
    printf 'expected error_code %s, got %s' "$want" "$(printf '%s' "${err:-{\}}" | jq -r '.error.code // "none"')"
    return 1
  fi
  want=$(printf '%s' "$expect" | jq -r '.reason // ""')
  if [[ -n "$want" && "$(printf '%s' "${err:-{\}}" | jq -r '.error.details.reason // ""')" != "$want" ]]; then
    printf 'expected details.reason %s, got %s' "$want" "$(printf '%s' "${err:-{\}}" | jq -r '.error.details.reason // "none"')"
    return 1
  fi
  want=$(printf '%s' "$expect" | jq -r '.retryable // ""')
  if [[ -n "$want" && "$(printf '%s' "${err:-{\}}" | jq -r '.error.details.retryable | if . == null then "" else tostring end')" != "$want" ]]; then
    printf 'expected details.retryable %s' "$want"
    return 1
  fi
  local alias state actual
  alias=$(printf '%s' "$expect" | jq -r '.run // ""')
  state=$(printf '%s' "$expect" | jq -r '.state // ""')
  if [[ -n "$state" ]]; then
    # expect.run, else the step's run, else the scenario's first run.
    [[ -n "$alias" ]] || alias=$(printf '%s' "$step" | jq -r '.run // ""')
    [[ -n "$alias" ]] || alias="${_OE_RUN_ORDER[0]:-}"
    actual=$(ordo_journal_state "$(_ordo_eval_run_id "$alias" 2>/dev/null)" 2>/dev/null || printf 'unknown')
    if [[ "$actual" != "$state" ]]; then
      printf 'expected run %s in state %s, got %s' "$alias" "$state" "$actual"
      return 1
    fi
  fi
  want=$(printf '%s' "$expect" | jq -r '.attempts // ""')
  if [[ -n "$want" && "$(printf '%s' "${result:-{\}}" | jq -r '.attempts | if type == "array" then length else "" end')" != "$want" ]]; then
    printf 'expected %s provider attempt(s), got %s' "$want" "$(printf '%s' "${result:-{\}}" | jq -r '.attempts | if type == "array" then length else "none" end')"
    return 1
  fi
  want=$(printf '%s' "$expect" | jq -r '.replayed // ""')
  if [[ -n "$want" && "$(printf '%s' "${result:-{\}}" | jq -r '.receipt.details.replayed | if . == null then "" else tostring end')" != "$want" ]]; then
    printf 'expected receipt.details.replayed %s' "$want"
    return 1
  fi
  return 0
}

# _ordo_eval_collect — write the raw trajectory files into $_OE_OUT
_ordo_eval_collect() {
  local alias run_id trace
  : > "$_OE_OUT/events.jsonl"; : > "$_OE_OUT/leases.jsonl"; : > "$_OE_OUT/approvals.jsonl"; : > "$_OE_OUT/traces.jsonl"
  local runs="{}"
  for alias in "${_OE_RUN_ORDER[@]+"${_OE_RUN_ORDER[@]}"}"; do
    run_id="${_OE_RUNS[$alias]}"
    ordo_journal_events "$run_id" | jq -c --arg alias "$alias" '. + {"alias": $alias}' >> "$_OE_OUT/events.jsonl"
    runs=$(printf '%s' "$runs" | jq -c --arg alias "$alias" --argjson snap "$(ordo_journal_project "$run_id")" '.[$alias] = $snap')
    ordo_journal_lease_list "$run_id" | jq -c --arg alias "$alias" '. + {"alias": $alias}' >> "$_OE_OUT/leases.jsonl"
    ordo_approval_list "$run_id" | jq -c --arg alias "$alias" '. + {"alias": $alias}' >> "$_OE_OUT/approvals.jsonl"
    trace=$(ordo_trace_new_id trace "$run_id")
    if [[ -f "$(ordo_trace_dir)/$trace.jsonl" ]]; then
      # Folded spans in the order their start lines were appended (causal order), not by random span id.
      ordo_trace_spans "$trace" | jq -sc --arg alias "$alias" \
        --argjson order "$(jq -c 'select(.phase == "start") | .span_id' "$(ordo_trace_dir)/$trace.jsonl" | jq -sc .)" \
        'sort_by(.span_id as $s | $order | index($s)) | .[] | . + {"alias": $alias}' >> "$_OE_OUT/traces.jsonl"
    fi
  done
  printf '%s\n' "$runs" | jq -S . > "$_OE_OUT/runs.json"
  if [[ -f "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl" ]]; then cp "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl" "$_OE_OUT/mutations.jsonl"; else : > "$_OE_OUT/mutations.jsonl"; fi
  local ledger
  ledger=$(ordo_provider_adapter_ledger_file)
  if [[ -f "$ledger" ]]; then cp "$ledger" "$_OE_OUT/ledger.jsonl"; else : > "$_OE_OUT/ledger.jsonl"; fi
  if [[ -f "$ORDO_FAKE_ADAPTER_DIR/runtime/events.jsonl" ]]; then cp "$ORDO_FAKE_ADAPTER_DIR/runtime/events.jsonl" "$_OE_OUT/runtime_events.jsonl"; else : > "$_OE_OUT/runtime_events.jsonl"; fi
  [[ -f "$_OE_OUT/artifacts.jsonl" ]] || : > "$_OE_OUT/artifacts.jsonl"
}

# The sandboxed scenario driver. Runs in a subshell created by ordo_eval_run.
_ordo_eval_sandbox() {
  local scenario_json="$1" scenario_path="$2" name fixtures clock
  name=$(printf '%s' "$scenario_json" | jq -r .name)
  clock=$(printf '%s' "$scenario_json" | jq -r .clock)
  fixtures=$(printf '%s' "$scenario_json" | jq -r --arg d "$ORDO_EVAL_DEFAULT_FIXTURES" '.fixtures // $d')

  # --- isolated world ------------------------------------------------------
  export PROJECT="eval-${name}"
  export ORCH_STATE_BASE="$_OE_WORK/state" ORCH_LOG_DIR="$_OE_WORK/log"
  export AGENT_WORKDIR_TEMPLATE="$_OE_WORK/work/%s"
  export ORDO_FAKE_ADAPTER_DIR="$_OE_WORK/fake"
  export ORDO_RUNTIME_ADAPTER=fake ORDO_PROVIDER_ADAPTER=fake
  # shellcheck disable=SC2031 # a fresh sandbox: the crash step's fault hook never leaks here
  export ORDO_JOURNAL_NOW="$clock" ORDO_JOURNAL_FAULT=""
  export ORDO_TRACE_ENABLED=1
  export ORDO_SCHED_JITTER=0 ORDO_SCHED_WORKER_ID=eval ORDO_SCHED_HOST=evalhost ORDO_SCHED_WORKER_PID="$$"
  ORDO_OPERATOR=$(printf '%s' "$scenario_json" | jq -r '.operator // "eval-operator"')
  ORDO_FORGE_REPO=$(printf '%s' "$scenario_json" | jq -r '.repo // "acme/widgets"')
  ORCH_EXTERNAL_PR_MUTATIONS=$(printf '%s' "$scenario_json" | jq -r '.policy.external_mutations // ""')
  ORDO_APPROVAL_PRINCIPALS=$(printf '%s' "$scenario_json" | jq -r '.policy.principals // ""')
  ORDO_POLICY_VERSION=$(printf '%s' "$scenario_json" | jq -r '.policy.policy_version // "eval-policy-v1"')
  export ORDO_OPERATOR ORDO_FORGE_REPO ORCH_EXTERNAL_PR_MUTATIONS ORDO_APPROVAL_PRINCIPALS ORDO_POLICY_VERSION
  unset GH_TOKEN GITHUB_TOKEN GH_REPO GH_HOST ORDO_FORGE_TOKEN_FILE ORDO_FORGE_TOKEN ORDO_FORGE_URL ORDO_ACTOR \
    ORDO_TRACE_ID ORDO_TRACE_PARENT_SPAN ORDO_RUN_ID ORDO_JOURNAL_DB ORDO_PROVIDER_LEDGER_FILE ORDO_TRACE_DIR \
    ORDO_RUNTIME_EVIDENCE_DIR ORDO_TRACE_NOW_NS ORDO_SCHEDULER_ENABLED
  local k v
  while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    case "$k" in
      ORDO_SCHED_*|ORDO_APPROVAL_DEFAULT_TTL|ORDO_JOURNAL_DEFAULT_*|ORDO_PROVIDER_TIMEOUT_SEC) ;;
      *) _ordo_eval_fail invalid_contract "scenario env may only set ORDO_SCHED_* / ORDO_APPROVAL_DEFAULT_TTL / ORDO_JOURNAL_DEFAULT_* knobs" "$(jq -cn --arg k "$k" '{"key": $k}')"; return $? ;;
    esac
    v=$(printf '%s' "$scenario_json" | jq -r --arg k "$k" '.env[$k] | tostring')
    export "$k=$v"
  done < <(printf '%s' "$scenario_json" | jq -r '(.env // {}) | keys[]')

  # Forbidden tools: guard stubs first on PATH; every call is recorded and refused (exit 6).
  mkdir -p "$_OE_WORK/bin" "$ORCH_STATE_BASE" "$ORCH_LOG_DIR"
  local tool
  for tool in $ORDO_EVAL_FORBIDDEN_TOOLS; do
    printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "%s" "$*" >> "%s/forbidden.log"\nprintf %%s\\\\n '"'"'{"error":{"code":"missing_dependency","message":"%s is forbidden inside the eval sandbox","module":"eval","details":{"tool":"%s"}}}'"'"' >&2\nexit 6\n' \
      "$tool" "$_OE_WORK" "$tool" "$tool" > "$_OE_WORK/bin/$tool"
    chmod +x "$_OE_WORK/bin/$tool"
  done
  export PATH="$_OE_WORK/bin:$PATH"

  # Fixtures of the fake provider.
  local src="$ORDO_EVAL_TK/tests/fixtures/$fixtures"
  if [[ ! -d "$src" ]]; then
    _ordo_eval_fail not_found "fixture directory not found: ${src}" "$(jq -cn --arg d "$src" '{"fixtures": $d}')"
    return $?
  fi
  mkdir -p "$ORDO_FAKE_ADAPTER_DIR"
  cp -R "$src"/. "$ORDO_FAKE_ADAPTER_DIR"/
  rm -f "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl"

  # Libraries (audit_log needs PROJECT first). The audit line goes to the
  # sandbox log only, so stderr carries nothing but error objects; the
  # contracts clock is the pinned clock so receipts and fake records are stable.
  # shellcheck source=lib/audit_log.sh
  source "$_ORDO_EVAL_LIB_DIR/audit_log.sh"
  # shellcheck source=lib/state_persist.sh
  source "$_ORDO_EVAL_LIB_DIR/state_persist.sh"
  set +e
  set +u
  # shellcheck source=lib/ordo_scheduler.sh
  source "$_ORDO_EVAL_LIB_DIR/ordo_scheduler.sh"
  # shellcheck source=lib/ordo_approval.sh
  source "$_ORDO_EVAL_LIB_DIR/ordo_approval.sh"
  # shellcheck source=lib/ordo_runtime_adapter.sh
  source "$_ORDO_EVAL_LIB_DIR/ordo_runtime_adapter.sh"
  # shellcheck disable=SC2317 # both are invoked indirectly by the libraries above
  audit() { printf 'AUDIT %s\n' "$*" >> "$ORCH_LOG_DIR/$PROJECT.log"; }
  # shellcheck disable=SC2317
  ordo_contracts_now() { printf '%s\n' "$ORDO_JOURNAL_NOW"; }
  ordo_journal_init >/dev/null || return $?

  declare -gA _OE_RUNS=() _OE_APPROVALS=()
  declare -ga _OE_RUN_ORDER=()
  _OE_ARTIFACT_N=0
  mkdir -p "$_OE_OUT"
  : > "$_OE_OUT/steps.jsonl"
  printf '%s\n' "$scenario_json" | jq -S . > "$_OE_OUT/scenario.json"

  # --- runs then steps ----------------------------------------------------
  local step out rc err ok index=0 op label expect_rc mismatch="" total
  local -a all_steps=()
  while IFS= read -r step; do
    [[ -n "$step" ]] || continue
    all_steps+=("$(printf '%s' "$step" | jq -c '. + {"op": "enqueue"}')")
  done < <(printf '%s' "$scenario_json" | jq -c '.runs[]')
  while IFS= read -r step; do
    [[ -n "$step" ]] || continue
    all_steps+=("$step")
  done < <(printf '%s' "$scenario_json" | jq -c '.steps[]')
  total="${#all_steps[@]}"
  for step in "${all_steps[@]+"${all_steps[@]}"}"; do
    op=$(printf '%s' "$step" | jq -r '.op')
    label=$(printf '%s' "$step" | jq -r '.label // ""')
    expect_rc=$(printf '%s' "$step" | jq -r '.expect_rc // 0')
    rc=0; err=""
    # No command substitution here: steps update the alias tables and the clock of this shell.
    _ordo_eval_dispatch "$step" >"$_OE_WORK/step-out" 2>"$_OE_WORK/step-err" || rc=$?
    out=$(cat "$_OE_WORK/step-out")
    err=$(grep -E '^\{' "$_OE_WORK/step-err" | tail -n 1 | jq -c 'select(.error)' 2>/dev/null || true)
    if ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
      out=$(jq -cn --arg raw "${out:0:400}" '{"raw": $raw}')
    fi
    ok=true
    if [[ "$rc" -ne "$expect_rc" ]]; then
      ok=false; mismatch="step ${index} (${op}${label:+ [$label]}) exited ${rc}, expected ${expect_rc}"
    elif ! reason=$(_ordo_eval_check_step_expect "$step" "$rc" "$out" "$err"); then
      ok=false; mismatch="step ${index} (${op}${label:+ [$label]}): ${reason}"
    fi
    jq -cn --argjson i "$index" --arg op "$op" --arg label "$label" --argjson rc "$rc" --argjson expect_rc "$expect_rc" \
      --argjson ok "$ok" --arg now "$ORDO_JOURNAL_NOW" --argjson result "$out" --argjson err "${err:-null}" \
      --arg key "$(case "$op" in execute|mutate|crash) printf '%s' "$out" | jq -r '.idempotency_key // ""' ;; esac)" \
      '{"index": $i, "op": $op, "label": (if $label == "" then null else $label end), "clock": $now, "rc": $rc, "expect_rc": $expect_rc, "ok": $ok,
        "idempotency_key": (if $key == "" then null else $key end), "result": $result, "error": $err}' >> "$_OE_OUT/steps.jsonl"
    index=$((index + 1))
    [[ "$ok" == true ]] || break
  done

  # --- trajectory -----------------------------------------------------------
  _ordo_eval_collect
  local forbidden="[]"
  if [[ -s "$_OE_WORK/forbidden.log" ]]; then
    forbidden=$(jq -R . "$_OE_WORK/forbidden.log" | jq -sc .)
  fi
  local run_states="{}" alias
  for alias in "${_OE_RUN_ORDER[@]+"${_OE_RUN_ORDER[@]}"}"; do
    run_states=$(printf '%s' "$run_states" | jq -c --arg a "$alias" --arg id "${_OE_RUNS[$alias]}" \
      --arg st "$(ordo_journal_state "${_OE_RUNS[$alias]}" 2>/dev/null || printf unknown)" '.[$a] = {"run_id": $id, "state": $st}')
  done
  jq -cn --arg name "$name" --arg scenario "$scenario_path" --arg start "$clock" --arg end "$ORDO_JOURNAL_NOW" \
    --argjson steps "$index" --argjson total "$total" --arg mismatch "$mismatch" --argjson runs "$run_states" --argjson forbidden "$forbidden" \
    --argjson elapsed "$(( $(_ordo_eval_epoch "$ORDO_JOURNAL_NOW") - $(_ordo_eval_epoch "$clock") ))" --arg sv "$ORDO_EVAL_SCHEMA_VERSION" \
    --argjson mutations "$(grep -c . "$_OE_OUT/mutations.jsonl" || true)" --argjson events "$(grep -c . "$_OE_OUT/events.jsonl" || true)" \
    '{"schema_version": $sv, "scenario": $name, "scenario_path": $scenario, "clock_start": $start, "clock_end": $end,
      "elapsed_seconds": $elapsed, "steps_executed": $steps, "steps_total": $total,
      "ok": ($mismatch == "" and ($forbidden | length) == 0), "mismatch": (if $mismatch == "" then null else $mismatch end),
      "forbidden_calls": $forbidden, "runs": $runs, "mutations": $mutations, "events": $events}' | jq -S . > "$_OE_OUT/summary.json"

  # --- normalisation (fixed file order => deterministic mapping) ------------
  local -a files=()
  local f
  for f in $ORDO_EVAL_TRAJECTORY_FILES; do files+=("$_OE_OUT/$f"); done
  ORDO_EVAL_WORK="$_OE_WORK" ORDO_EVAL_TK="$ORDO_EVAL_TK" ordo_eval_normalize "$_OE_OUT/idmap.json" "${files[@]}" || return $?
  jq -c . "$_OE_OUT/summary.json"
  if [[ "$forbidden" != "[]" ]]; then
    _ordo_eval_fail fail_closed "a forbidden tool was invoked inside the eval sandbox" "$(printf '%s' "$forbidden" | jq -c '{"calls": .}')"
    return $?
  fi
  if [[ -n "$mismatch" ]]; then
    _ordo_eval_fail invalid_state "scenario ${name} diverged: ${mismatch}" "$(jq -cn --arg m "$mismatch" --argjson i "$((index - 1))" '{"mismatch": $m, "step": $i}')"
    return $?
  fi
}

# ordo_eval_run <scenario.json> [--out DIR] [--work DIR] [--keep]
ordo_eval_run() {
  local scenario="${1-}" out="" work="" keep=0
  if [[ -z "$scenario" ]]; then
    _ordo_eval_fail usage "usage: ordo_eval_run <scenario.json> [--out DIR] [--work DIR] [--keep]"
    return $?
  fi
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) out="${2-}"; shift 2 ;;
      --work) work="${2-}"; shift 2 ;;
      --keep) keep=1; shift ;;
      *) _ordo_eval_fail usage "unknown option for ordo_eval_run: ${1}" "$(jq -cn --arg o "$1" '{"option": $o}')"; return $? ;;
    esac
  done
  local doc path
  doc=$(_ordo_eval_json_file "$scenario") || return $?
  _ordo_eval_validate_scenario "$doc" || return $?
  path=$(cd "$(dirname "$scenario")" && pwd)/$(basename "$scenario")
  local made_work=0
  if [[ -z "$work" ]]; then
    work=$(mktemp -d "${TMPDIR:-/tmp}/ordo-eval.XXXXXX") || return 1
    made_work=1
  fi
  mkdir -p "$work"
  [[ -n "$out" ]] || out="$work/trajectory"
  # Only a previous trajectory (or an empty directory) is replaced; anything else is refused.
  if [[ -d "$out" && -n "$(ls -A "$out" 2>/dev/null)" && ! -f "$out/summary.json" ]]; then
    [[ "$made_work" -eq 0 ]] || rm -rf "$work"
    _ordo_eval_fail conflict "output directory is not empty and is not a trajectory: ${out}" "$(jq -cn --arg d "$out" '{"out": $d}')"
    return $?
  fi
  rm -rf "$out"
  mkdir -p "$out"
  out=$(cd "$out" && pwd)
  work=$(cd "$work" && pwd)
  local rc=0
  (
    _OE_WORK="$work"
    _OE_OUT="$out"
    _ordo_eval_sandbox "$doc" "$path"
  ) || rc=$?
  if [[ "$keep" -eq 0 && "$made_work" -eq 1 ]]; then
    rm -rf "$work"
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016 # jq program
ORDO_EVAL_SCORE_JQ='
  def bool(x): if x then true else false end;
  def failures_of(f): [f | select(. != null)];
  ($expected[0]) as $exp
  | ($summary[0]) as $sum
  | ($runs[0]) as $runs
  | ($events) as $ev
  | ($steps) as $steps
  | ($approvals) as $approvals
  | ($mutations) as $mut
  | ($ledger) as $ledger
  | ($traces) as $traces
  | ($artifacts) as $artifacts
  # --- completion --------------------------------------------------------
  | (($exp.runs // {}) | to_entries | map(
        . as $e | ($runs[$e.key] // null) as $snap
        | {"alias": $e.key, "expected": $e.value.state, "actual": ($snap.state // "missing"),
           "pass": ($snap != null and $snap.state == $e.value.state
                    and (($e.value.terminal == null) or ($snap.terminal == $e.value.terminal)))})) as $completion_rows
  | {"pass": (($completion_rows | all(.pass)) and ($sum.ok == true)),
     "runs": $completion_rows,
     "harness_ok": $sum.ok,
     "failures": (($completion_rows | map(select(.pass | not) | "run \(.alias): expected \(.expected), got \(.actual)"))
                  + (if $sum.ok then [] else ["harness: \($sum.mismatch // "forbidden tool invoked")"] end))} as $completion
  # --- policy compliance --------------------------------------------------
  | ([$approvals[] | select(.state == "consumed") | .idempotency_key]) as $consumed_keys
  | ([$mut[] | .idempotency_key]) as $executed_keys
  | ([$executed_keys[] | select(. as $k | $consumed_keys | index($k) | not)]) as $unapproved
  | ([$steps[] | select((.op == "execute" or .op == "mutate") and .rc == 3)] | length) as $refused
  | ([$ev[] | select(.type == "policy.decided" and .payload.decision == "deny")] | length) as $denials
  | ([$ev[] | select((.type == "approval.granted" or .type == "approval.consumed" or .type == "policy.decided") and .actor.type == "model")] | length) as $model_decisions
  | ([$ev[] | select(.mutation == true and (.idempotency_key | type) == "string" and (.idempotency_key as $k | $consumed_keys | index($k) | not) and (.idempotency_key as $k | $executed_keys | index($k)))] | length) as $unapproved_journaled
  | (($exp.policy // {}) | {"max_unapproved": (.max_unapproved // 0), "refused": .refused, "denials": .denials}) as $pexp
  | {"pass": (($unapproved | length) <= $pexp.max_unapproved and $model_decisions == 0
              and ($pexp.refused == null or $pexp.refused == $refused) and ($pexp.denials == null or $pexp.denials == $denials)),
     "mutations_executed": ($executed_keys | length), "mutations_approved": (($executed_keys | length) - ($unapproved | length)),
     "mutations_unapproved": ($unapproved | length), "unapproved_keys": $unapproved,
     "mutations_refused": $refused, "policy_denials": $denials, "model_decisions": $model_decisions,
     "failures": (failures_of(
        (if ($unapproved | length) > $pexp.max_unapproved then "\($unapproved | length) mutation(s) executed without a consumed approval: \($unapproved | join(","))" else null end),
        (if $model_decisions > 0 then "\($model_decisions) approval decision(s) taken by a model actor" else null end),
        (if $pexp.refused != null and $pexp.refused != $refused then "expected \($pexp.refused) refused mutation(s), got \($refused)" else null end),
        (if $pexp.denials != null and $pexp.denials != $denials then "expected \($pexp.denials) policy denial(s), got \($denials)" else null end)))} as $policy
  # --- evidence completeness ---------------------------------------------
  | def subsequence($have; $want): reduce $want[] as $w ({"rest": $have, "missing": []};
        (.rest | index($w)) as $i | if $i == null then .missing += [$w] else .rest = .rest[($i + 1):] end) | .missing;
    ((($exp.evidence // {}).events // {}) | to_entries | map(
        . as $e | {"alias": $e.key, "missing": subsequence([$ev[] | select(.alias == $e.key) | .type]; $e.value)})) as $ev_rows
  | ([$traces[] | .name]) as $span_names
  | ([(($exp.evidence // {}).spans // [])[] | select(. as $s | $span_names | index($s) | not)]) as $missing_spans
  | ((($exp.evidence // {}).artifacts // 0)) as $min_artifacts
  | ([$mut[] | .idempotency_key | select(. as $k | [$ev[] | select(.mutation == true) | .idempotency_key] | index($k) | not)]) as $unjournaled
  | ([$ev[] | select(.mutation == true) | .idempotency_key] | group_by(.) | map(select(length > 1) | .[0])) as $dup_journal
  | {"pass": (($ev_rows | all(.missing == [])) and $missing_spans == [] and ($artifacts | length) >= $min_artifacts and $unjournaled == [] and $dup_journal == []),
     "events_total": ($ev | length), "spans_total": ($traces | length), "artifacts": ($artifacts | length),
     "required_events": $ev_rows, "missing_spans": $missing_spans, "unjournaled_mutations": $unjournaled,
     "failures": (($ev_rows | map(select(.missing != []) | "run \(.alias): missing events \(.missing | join(","))"))
                  + (if $missing_spans == [] then [] else ["missing spans \($missing_spans | join(","))"] end)
                  + (if ($artifacts | length) >= $min_artifacts then [] else ["expected at least \($min_artifacts) artifact(s), got \($artifacts | length)"] end)
                  + (if $unjournaled == [] then [] else ["mutations executed without a journal record: \($unjournaled | join(","))"] end)
                  + (if $dup_journal == [] then [] else ["mutation keys journaled twice: \($dup_journal | join(","))"] end))} as $evidence
  # --- cost ----------------------------------------------------------------
  | ($runs | to_entries | map({"alias": .key, "attempts_used": (.value.budgets.attempts_used // 0), "tokens_used": (.value.budgets.tokens_used // 0),
        "seconds_used": (.value.budgets.seconds_used // 0), "turns_used": (.value.budgets.turns_used // 0),
        "tool_calls_used": (.value.budgets.tool_calls_used // 0), "cost_used": (.value.budgets.cost_used // 0),
        "exhausted": (.value.budgets.exhausted // [])})) as $cost_rows
  | ((($exp.cost // {}) | to_entries | map(. as $c | ($cost_rows[] | select(.alias == $c.key)) as $row
        | [ (if $c.value.max_attempts != null and $row.attempts_used > $c.value.max_attempts then "run \($c.key): attempts \($row.attempts_used) > \($c.value.max_attempts)" else empty end),
            (if $c.value.max_tokens != null and $row.tokens_used > $c.value.max_tokens then "run \($c.key): tokens \($row.tokens_used) > \($c.value.max_tokens)" else empty end),
            (if $c.value.max_seconds != null and $row.seconds_used > $c.value.max_seconds then "run \($c.key): seconds \($row.seconds_used) > \($c.value.max_seconds)" else empty end),
            (if $c.value.max_turns != null and $row.turns_used > $c.value.max_turns then "run \($c.key): turns \($row.turns_used) > \($c.value.max_turns)" else empty end),
            (if $c.value.max_tool_calls != null and $row.tool_calls_used > $c.value.max_tool_calls then "run \($c.key): tool calls \($row.tool_calls_used) > \($c.value.max_tool_calls)" else empty end),
            (if $c.value.max_cost != null and $row.cost_used > $c.value.max_cost then "run \($c.key): cost \($row.cost_used) > \($c.value.max_cost)" else empty end),
            (if $c.value.exhausted != null and $row.exhausted != $c.value.exhausted then "run \($c.key): exhausted \($row.exhausted) != \($c.value.exhausted)" else empty end) ]) | add // [])) as $cost_failures
  | {"pass": ($cost_failures == []), "runs": $cost_rows,
     "totals": {"attempts_used": ($cost_rows | map(.attempts_used) | add // 0), "tokens_used": ($cost_rows | map(.tokens_used) | add // 0),
                "seconds_used": ($cost_rows | map(.seconds_used) | add // 0), "turns_used": ($cost_rows | map(.turns_used) | add // 0),
                "tool_calls_used": ($cost_rows | map(.tool_calls_used) | add // 0), "cost_used": ($cost_rows | map(.cost_used) | add // 0)},
     "failures": $cost_failures} as $cost
  # --- latency (pinned clock) ---------------------------------------------
  | ($sum.elapsed_seconds) as $elapsed
  | (($exp.latency // {}).max_elapsed_seconds) as $max_elapsed
  | ($runs | to_entries | map({"alias": .key, "enqueued_at": .value.metadata.enqueued_at, "finished_at": (.value.metadata.finished_at // null),
        "seconds": (((.value.metadata.finished_at // $sum.clock_end) | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) - (.value.metadata.enqueued_at | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime))})) as $lat_rows
  | {"pass": ($max_elapsed == null or $elapsed <= $max_elapsed), "elapsed_seconds": $elapsed, "max_elapsed_seconds": $max_elapsed,
     "clock_start": $sum.clock_start, "clock_end": $sum.clock_end, "runs": $lat_rows,
     "failures": (if $max_elapsed != null and $elapsed > $max_elapsed then ["elapsed \($elapsed)s > \($max_elapsed)s"] else [] end)} as $latency
  # --- duplicate side effects ---------------------------------------------
  | ($executed_keys | group_by(.) | map(select(length > 1) | .[0])) as $repeated
  | ([$ledger[] | .idempotency_key] | group_by(.) | map(select(length > 1) | .[0])) as $repeated_ledger
  | ([$steps[] | select(.idempotency_key != null and (.op == "execute" or .op == "mutate" or .op == "crash"))] | length) as $deliveries
  | ([$steps[] | select(.idempotency_key != null and (.op == "execute" or .op == "mutate") and .rc == 0 and .result.receipt.details.replayed == true)] | length) as $replayed
  | (($exp.side_effects // {}) | {"executed": .executed, "deliveries": .deliveries}) as $sexp
  | {"pass": ($repeated == [] and $repeated_ledger == [] and ($sexp.executed == null or $sexp.executed == ($executed_keys | length))
              and ($sexp.deliveries == null or $sexp.deliveries == $deliveries)),
     "mutations_executed": ($executed_keys | length), "distinct_keys": ($executed_keys | unique | length),
     "deliveries": $deliveries, "replayed_deliveries": $replayed, "repeated_keys": $repeated, "repeated_ledger_keys": $repeated_ledger,
     "failures": (failures_of(
        (if $repeated == [] then null else "idempotency key(s) executed more than once: \($repeated | join(","))" end),
        (if $repeated_ledger == [] then null else "ledger holds duplicate key(s): \($repeated_ledger | join(","))" end),
        (if $sexp.executed != null and $sexp.executed != ($executed_keys | length) then "expected \($sexp.executed) executed mutation(s), got \($executed_keys | length)" else null end),
        (if $sexp.deliveries != null and $sexp.deliveries != $deliveries then "expected \($sexp.deliveries) deliveries, got \($deliveries)" else null end)))} as $dup
  | {"schema_version": "1", "scenario": $sum.scenario,
     "pass": ($completion.pass and $policy.pass and $evidence.pass and $cost.pass and $latency.pass and $dup.pass),
     "dimensions": {"completion": $completion, "policy_compliance": $policy, "evidence_completeness": $evidence,
                    "cost": $cost, "latency": $latency, "duplicate_side_effects": $dup},
     "metrics": {"states": ($runs | to_entries | map({(.key): .value.state}) | add // {}),
                 "mutations_executed": ($executed_keys | length), "mutations_unapproved": ($unapproved | length),
                 "mutations_refused": $refused, "policy_denials": $denials, "repeated_keys": ($repeated | length),
                 "deliveries": $deliveries, "replayed_deliveries": $replayed,
                 "events_total": ($ev | length), "spans_total": ($traces | length), "artifacts": ($artifacts | length),
                 "elapsed_seconds": $elapsed, "attempts_used": $cost.totals.attempts_used, "tokens_used": $cost.totals.tokens_used,
                 "seconds_used": $cost.totals.seconds_used, "turns_used": $cost.totals.turns_used,
                 "tool_calls_used": $cost.totals.tool_calls_used, "cost_used": $cost.totals.cost_used}}'

# ordo_eval_score <trajectory_dir> <expected.json> -> score card (sorted keys); 0 pass, 1 fail
ordo_eval_score() {
  local dir="${1-}" expected="${2-}"
  if [[ -z "$dir" || -z "$expected" ]]; then
    _ordo_eval_fail usage "usage: ordo_eval_score <trajectory_dir> <expected.json>"
    return $?
  fi
  local f
  for f in summary.json runs.json steps.jsonl events.jsonl; do
    if [[ ! -f "$dir/$f" ]]; then
      _ordo_eval_fail not_found "trajectory file missing: ${dir}/${f}" "$(jq -cn --arg d "$dir" --arg f "$f" '{"dir": $d, "file": $f}')"
      return $?
    fi
  done
  local exp
  exp=$(_ordo_eval_json_file "$expected") || return $?
  local card
  card=$(jq -n -S \
    --argjson expected "[$exp]" \
    --slurpfile summary "$dir/summary.json" --slurpfile runs "$dir/runs.json" \
    --slurpfile events "$dir/events.jsonl" --slurpfile steps "$dir/steps.jsonl" \
    --slurpfile approvals "$dir/approvals.jsonl" --slurpfile mutations "$dir/mutations.jsonl" \
    --slurpfile ledger "$dir/ledger.jsonl" --slurpfile traces "$dir/traces.jsonl" \
    --slurpfile artifacts "$dir/artifacts.jsonl" \
    "$ORDO_EVAL_SCORE_JQ") || {
    _ordo_eval_fail internal_error "scoring failed for ${dir}" "$(jq -cn --arg d "$dir" '{"dir": $d}')"
    return $?
  }
  printf '%s\n' "$card"
  printf '%s' "$card" | jq -e '.pass' >/dev/null
}

# ---------------------------------------------------------------------------
# Baseline: run + score every scenario, keep pass flags and metrics.
# ---------------------------------------------------------------------------
# _ordo_eval_run_and_score <scenario.json> -> score card JSON (rc: 0 pass, 1 fail, other: harness error)
_ordo_eval_run_and_score() {
  local scenario="$1" expected out rc=0 card
  expected=$(ordo_eval_expected_for "$scenario")
  out=$(mktemp -d "${TMPDIR:-/tmp}/ordo-eval-traj.XXXXXX") || return 1
  ordo_eval_run "$scenario" --out "$out" >/dev/null || rc=$?
  if [[ "$rc" -ne 0 && ! -f "$out/summary.json" ]]; then
    rm -rf "$out"
    return "$rc"
  fi
  rc=0
  card=$(ordo_eval_score "$out" "$expected") || rc=$?
  rm -rf "$out"
  printf '%s\n' "$card"
  return "$rc"
}

_ordo_eval_baseline_entry() {
  # <card> -> {"pass","dimensions":{d: pass},"metrics":{...}}
  printf '%s' "$1" | jq -S '{"pass": .pass, "dimensions": (.dimensions | to_entries | map({(.key): .value.pass}) | add), "metrics": .metrics}'
}

# ordo_eval_baseline <scenario.json>... [--out FILE]
ordo_eval_baseline() {
  local out="" scenario
  local -a scenarios=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) out="${2-}"; shift 2 ;;
      *) scenarios+=("$1"); shift ;;
    esac
  done
  if [[ "${#scenarios[@]}" -eq 0 ]]; then
    _ordo_eval_fail usage "usage: ordo_eval_baseline <scenario.json>... [--out FILE]"
    return $?
  fi
  local baseline='{"schema_version":"1","generated_by":"scripts/ordo_eval.sh baseline","scenarios":{}}' card name rc=0 failed="[]"
  for scenario in "${scenarios[@]}"; do
    name=$(basename "$scenario" .json)
    rc=0
    card=$(_ordo_eval_run_and_score "$scenario") || rc=$?
    if [[ "$rc" -ne 0 && -z "$card" ]]; then
      _ordo_eval_fail invalid_state "scenario ${name} could not be run (rc=${rc})" "$(jq -cn --arg s "$scenario" --argjson rc "$rc" '{"scenario": $s, "rc": $rc}')"
      return $?
    fi
    [[ "$rc" -eq 0 ]] || failed=$(printf '%s' "$failed" | jq -c --arg n "$name" '. + [$n]')
    baseline=$(printf '%s' "$baseline" | jq -c --arg n "$name" --argjson e "$(_ordo_eval_baseline_entry "$card")" '.scenarios[$n] = $e')
  done
  baseline=$(printf '%s' "$baseline" | jq -S .)
  if [[ -n "$out" ]]; then
    mkdir -p "$(dirname "$out")"
    printf '%s\n' "$baseline" > "$out"
  fi
  printf '%s\n' "$baseline"
  if [[ "$failed" != "[]" ]]; then
    _ordo_eval_fail generic_failure "baseline recorded but these scenarios do not pass their expectations: $(printf '%s' "$failed" | jq -r 'join(",")')" \
      "$(printf '%s' "$failed" | jq -c '{"failed": .}')"
    return $?
  fi
}

# shellcheck disable=SC2016 # jq program
ORDO_EVAL_CHECK_JQ='
  # $base, $cur: baseline entries; produce {"regressions":[...],"improvements":[...],"changes":[...]}
  def cmp_more(k): if ($cur.metrics[k] // 0) > ($base.metrics[k] // 0) then ["\(k): \($base.metrics[k]) -> \($cur.metrics[k])"] else [] end;
  def cmp_less(k): if ($cur.metrics[k] // 0) < ($base.metrics[k] // 0) then ["\(k): \($base.metrics[k]) -> \($cur.metrics[k])"] else [] end;
  def cmp_eq(k): if ($cur.metrics[k]) != ($base.metrics[k]) then ["\(k): \($base.metrics[k]) -> \($cur.metrics[k])"] else [] end;
  {"regressions": (
      (if $base.pass and ($cur.pass | not) then ["pass: true -> false"] else [] end)
      + ($base.dimensions | to_entries | map(select(.value == true and ($cur.dimensions[.key] // false) == false) | "dimension \(.key): pass -> fail"))
      + (if $cur.metrics.states != $base.metrics.states then ["states: \($base.metrics.states | tojson) -> \($cur.metrics.states | tojson)"] else [] end)
      + cmp_eq("mutations_executed") + cmp_eq("mutations_unapproved") + cmp_eq("mutations_refused") + cmp_eq("policy_denials")
      + cmp_eq("repeated_keys") + cmp_eq("deliveries") + cmp_eq("replayed_deliveries") + cmp_eq("artifacts")
      + cmp_more("elapsed_seconds") + cmp_more("attempts_used") + cmp_more("tokens_used") + cmp_more("seconds_used")
      + cmp_more("turns_used") + cmp_more("tool_calls_used") + cmp_more("cost_used") + cmp_more("events_total")),
   "improvements": (
      (if ($base.pass | not) and $cur.pass then ["pass: false -> true"] else [] end)
      + cmp_less("elapsed_seconds") + cmp_less("attempts_used") + cmp_less("tokens_used") + cmp_less("seconds_used")
      + cmp_less("turns_used") + cmp_less("tool_calls_used") + cmp_less("cost_used") + cmp_less("events_total")),
   "changes": (if $cur.metrics.spans_total != $base.metrics.spans_total then ["spans_total: \($base.metrics.spans_total) -> \($cur.metrics.spans_total)"] else [] end)}'

# ordo_eval_check <baseline.json> <scenario.json>... -> report JSON; 1 on regression
ordo_eval_check() {
  local baseline="${1-}"
  if [[ -z "$baseline" || $# -lt 2 ]]; then
    _ordo_eval_fail usage "usage: ordo_eval_check <baseline.json> <scenario.json>..."
    return $?
  fi
  shift
  local base
  base=$(_ordo_eval_json_file "$baseline") || return $?
  local scenario name card rc entry cmp report='{"schema_version":"1","regressions":0,"scenarios":{}}' seen="[]"
  for scenario in "$@"; do
    name=$(basename "$scenario" .json)
    seen=$(printf '%s' "$seen" | jq -c --arg n "$name" '. + [$n]')
    rc=0
    card=$(_ordo_eval_run_and_score "$scenario") || rc=$?
    if [[ -z "$card" ]]; then
      report=$(printf '%s' "$report" | jq -c --arg n "$name" --argjson rc "$rc" '.scenarios[$n] = {"status": "error", "rc": $rc, "regressions": ["scenario could not be run (rc=\($rc))"]} | .regressions += 1')
      continue
    fi
    entry=$(_ordo_eval_baseline_entry "$card")
    if ! printf '%s' "$base" | jq -e --arg n "$name" '.scenarios[$n] != null' >/dev/null; then
      report=$(printf '%s' "$report" | jq -c --arg n "$name" --argjson e "$entry" '.scenarios[$n] = {"status": "new", "current": $e, "regressions": [], "improvements": [], "changes": []}')
      continue
    fi
    cmp=$(jq -n -S --argjson base "$(printf '%s' "$base" | jq -c --arg n "$name" '.scenarios[$n]')" --argjson cur "$entry" "$ORDO_EVAL_CHECK_JQ")
    report=$(printf '%s' "$report" | jq -c --arg n "$name" --argjson e "$entry" --argjson cmp "$cmp" '
      .scenarios[$n] = ($cmp + {"status": (if ($cmp.regressions | length) > 0 then "regression" elif ($cmp.improvements | length) > 0 then "improved" else "ok" end), "current": $e})
      | .regressions += ($cmp.regressions | length)')
  done
  local missing
  missing=$(printf '%s' "$base" | jq -c --argjson seen "$seen" '[.scenarios | keys[] | select(. as $k | $seen | index($k) | not)]')
  report=$(printf '%s' "$report" | jq -c --argjson m "$missing" 'reduce $m[] as $n (.; .scenarios[$n] = {"status": "missing", "regressions": ["scenario present in the baseline was not run"]} | .regressions += 1)')
  report=$(printf '%s' "$report" | jq -S '.pass = (.regressions == 0)')
  printf '%s\n' "$report"
  if ! printf '%s' "$report" | jq -e '.pass' >/dev/null; then
    _ordo_eval_fail generic_failure "$(printf '%s' "$report" | jq -r '.regressions') regression(s) against the baseline" \
      "$(printf '%s' "$report" | jq -c '{"regressions": (.scenarios | to_entries | map(select(.value.regressions | length > 0) | {(.key): .value.regressions}) | add // {})}')"
    return $?
  fi
}
