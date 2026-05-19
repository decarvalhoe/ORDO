#!/usr/bin/env bash
# lib/sixsigma_evidence.sh — append-only JSONL evidence ledger helpers (#241).
#
# Schema: ordo.sixsigma.evidence.v1
#
# Each row records an auditable Six Sigma metric collection point: metric,
# source, action, UTC timestamp, actor role, digest, limits, and disposition.
# Rows are written one-per-line to a JSONL ledger and validated with `jq` so
# downstream tooling can stream them without re-parsing free-form text.
#
# Hard boundary: this is operational evidence. It does not approve a release,
# waive a control, validate a system, or mark a DMAIC phase complete. The
# helper refuses any "approved", "released", "waived", "validated", or
# "complete" disposition value because those are human-decision verdicts that
# must never be emitted by automation. Allowed dispositions are restricted to
# "draft", "observed", "ready", "blocked", and "not_approved".
#
# Raw evidence input is digested into a sha256 hex (see --raw); the raw prose
# itself is intentionally never copied into the row, so uncontrolled agent
# output cannot leak into approval-facing fields.

set -euo pipefail

readonly ORDO_SIXSIGMA_EVIDENCE_SCHEMA="ordo.sixsigma.evidence.v1"

ORDO_SIXSIGMA_EVIDENCE_ALLOWED_DISPOSITIONS=(
  draft
  observed
  ready
  blocked
  not_approved
)

ORDO_SIXSIGMA_EVIDENCE_FORBIDDEN_DISPOSITIONS=(
  approved
  released
  waived
  validated
  complete
)

sixsigma_evidence_disposition_allowed() {
  local candidate=${1:?usage: sixsigma_evidence_disposition_allowed <disposition>}
  local allowed
  for allowed in "${ORDO_SIXSIGMA_EVIDENCE_ALLOWED_DISPOSITIONS[@]}"; do
    [[ "$candidate" == "$allowed" ]] && return 0
  done
  return 1
}

sixsigma_evidence_disposition_forbidden() {
  local candidate=${1:?usage: sixsigma_evidence_disposition_forbidden <disposition>}
  local forbidden
  for forbidden in "${ORDO_SIXSIGMA_EVIDENCE_FORBIDDEN_DISPOSITIONS[@]}"; do
    [[ "$candidate" == "$forbidden" ]] && return 0
  done
  return 1
}

sixsigma_evidence_now_utc() {
  date -u +'%Y-%m-%dT%H:%M:%SZ'
}

# sixsigma_evidence_digest <input>
#
# Returns the sha256 hex of <input>. If <input> is a path to an existing
# regular file, the file's content is hashed; otherwise <input> is treated
# as a literal string. Empty input yields an empty digest so callers can
# distinguish "no raw input" from "raw input hashed to all-zero".
sixsigma_evidence_digest() {
  local input=${1-}
  if [[ -z "$input" ]]; then
    printf ''
    return 0
  fi
  if [[ -f "$input" ]]; then
    sha256sum -- "$input" | awk '{print $1}'
    return 0
  fi
  printf '%s' "$input" | sha256sum | awk '{print $1}'
}

# sixsigma_evidence_append --ledger PATH --metric NAME --source ID \
#   --action TEXT --actor-role ROLE --limits LIMITS --disposition STATE \
#   [--project NAME] [--raw INPUT] [--digest HASH] [--timestamp UTC_ISO]
#
# Appends one JSONL row to <PATH>. The ledger's parent directory is created
# if missing. Required flags: --ledger, --metric, --source, --action,
# --actor-role, --limits, --disposition. --raw is hashed and stored in the
# row's `digest` field; the raw text itself is never recorded. An explicit
# --digest overrides the derived hash. Exit codes: 0 on success, 2 on
# missing/unknown args, 3 on disallowed disposition.
sixsigma_evidence_append() {
  local ledger="" project="" metric="" source_id="" action="" actor_role=""
  local digest="" limits="" disposition="" raw="" timestamp=""
  local digest_supplied=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ledger)       ledger=${2-}; shift 2 ;;
      --project)      project=${2-}; shift 2 ;;
      --metric)       metric=${2-}; shift 2 ;;
      --source)       source_id=${2-}; shift 2 ;;
      --action)       action=${2-}; shift 2 ;;
      --actor-role)   actor_role=${2-}; shift 2 ;;
      --digest)       digest=${2-}; digest_supplied=1; shift 2 ;;
      --limits)       limits=${2-}; shift 2 ;;
      --disposition)  disposition=${2-}; shift 2 ;;
      --raw)          raw=${2-}; shift 2 ;;
      --timestamp)    timestamp=${2-}; shift 2 ;;
      *)
        printf 'sixsigma_evidence_append: unknown arg %s\n' "$1" >&2
        return 2
        ;;
    esac
  done

  local missing=()
  [[ -n "$ledger" ]]      || missing+=("--ledger")
  [[ -n "$metric" ]]      || missing+=("--metric")
  [[ -n "$source_id" ]]   || missing+=("--source")
  [[ -n "$action" ]]      || missing+=("--action")
  [[ -n "$actor_role" ]]  || missing+=("--actor-role")
  [[ -n "$limits" ]]      || missing+=("--limits")
  [[ -n "$disposition" ]] || missing+=("--disposition")
  if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'sixsigma_evidence_append: missing required args: %s\n' \
      "${missing[*]}" >&2
    return 2
  fi

  if sixsigma_evidence_disposition_forbidden "$disposition"; then
    printf 'sixsigma_evidence_append: disposition %s forbidden; automation must not emit approval/release/waiver/validation/phase-completion verdicts\n' \
      "$disposition" >&2
    return 3
  fi
  if ! sixsigma_evidence_disposition_allowed "$disposition"; then
    printf 'sixsigma_evidence_append: disposition %s not allowed; allowed=%s\n' \
      "$disposition" "${ORDO_SIXSIGMA_EVIDENCE_ALLOWED_DISPOSITIONS[*]}" >&2
    return 3
  fi

  [[ -n "$timestamp" ]] || timestamp=$(sixsigma_evidence_now_utc)

  if [[ "$digest_supplied" -eq 0 ]]; then
    if [[ -n "$raw" ]]; then
      digest=$(sixsigma_evidence_digest "$raw")
    elif [[ -f "$source_id" ]]; then
      digest=$(sixsigma_evidence_digest "$source_id")
    fi
  fi

  local ledger_dir
  ledger_dir=$(dirname -- "$ledger")
  [[ -d "$ledger_dir" ]] || mkdir -p -- "$ledger_dir"

  local row
  row=$(jq -cn \
    --arg schema "$ORDO_SIXSIGMA_EVIDENCE_SCHEMA" \
    --arg timestamp_utc "$timestamp" \
    --arg project "$project" \
    --arg metric "$metric" \
    --arg source "$source_id" \
    --arg action "$action" \
    --arg actor_role "$actor_role" \
    --arg digest "$digest" \
    --arg limits "$limits" \
    --arg disposition "$disposition" \
    '{
      schema: $schema,
      timestamp_utc: $timestamp_utc,
      project: $project,
      metric: $metric,
      source: $source,
      action: $action,
      actor_role: $actor_role,
      digest: $digest,
      limits: $limits,
      disposition: $disposition
    }')

  printf '%s\n' "$row" >> "$ledger"
}
