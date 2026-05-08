#!/usr/bin/env bash
# lane_registry.sh — central registry of ORDO capability lanes plus a single
# canonical evidence envelope.
#
# What is a "lane"?
# A capability lane is a bounded probe ORDO runs to decide whether it is safe
# to dispatch a particular kind of work: host_health, host_assessment, visual
# (Figma/Playwright), network egress, auth, future checks, etc. Each lane has
# its own data, but the wrapping shape (lane id, status, when it was captured,
# whether it is configured/available, extra details) is the same.
#
# Why a registry?
# Pre-#312, lanes appeared as ad-hoc `ORCH_<LANE>_*` env families and one-off
# JSON shapes. Dispatchers had to know each lane's internals, and adding a new
# lane meant teaching every consumer about a new shape. The registry makes the
# set of known lanes discoverable and makes the wrapping JSON identical across
# lanes — consumers read the envelope, lanes own only their `details`.
#
# Public API:
#   lane_registry_register <id> <description> [env_prefix] [require_command]
#       Register or update a lane. Idempotent. env_prefix is the configured
#       env var prefix (e.g. "ORCH_VISUAL_") and require_command is the binary
#       a lane needs (e.g. "google-chrome"); both are optional.
#
#   lane_registry_lanes
#       Print one lane id per line, sorted, suitable for shell loops.
#
#   lane_registry_meta <id>
#       Print "id|description|env_prefix|require_command" or return 1 if the
#       lane is not registered.
#
#   lane_registry_known <id>
#       Return 0 when <id> is registered, 1 otherwise.
#
#   lane_registry_evidence_envelope <id> [status] [details_json] [configured] [available]
#       Emit a canonical JSON object on stdout:
#         {
#           "schema_version": "ordo.lane.v1",
#           "lane": "<id>",
#           "lane_description": "<description>",
#           "captured_at": "<UTC ISO-8601>",
#           "host": "<short hostname>",
#           "status": "<status>",
#           "configured": <bool>,
#           "available": <bool>,
#           "details": <details_json or {}>
#         }
#       status defaults to "unknown" and must be one of the recognised values
#       (see ORDO_LANE_KNOWN_STATUSES below). details_json defaults to "{}".
#       configured / available default to false. Returns 2 on unknown lane id
#       and 3 on unrecognised status.
#
#   lane_registry_envelope_validate <json>
#       Return 0 when the input has every required envelope key with the right
#       schema_version, 1 otherwise. Used by tests and consumers that want to
#       refuse mis-shaped payloads.
#
# This file is sourced by other libs/scripts. It must not run side-effects
# beyond preregistering the known lanes when sourced.

set -uo pipefail

ORDO_LANE_SCHEMA_VERSION="ordo.lane.v1"

# Recognised envelope statuses. Match the host_assessment vocabulary so a lane
# can pass through host_assessment_classify_metric output unchanged.
ORDO_LANE_KNOWN_STATUSES=(
  ok
  warning
  critical
  unknown
  unavailable_optional
)

# Required keys on the envelope. Mirrored by lane_registry_envelope_validate.
ORDO_LANE_ENVELOPE_REQUIRED_KEYS=(
  schema_version
  lane
  lane_description
  captured_at
  host
  status
  configured
  available
  details
)

# Internal storage: associative array keyed by lane id, value packed as
# "description|env_prefix|require_command". Bash assoc arrays do not survive
# subshell forks, but every consumer either sources this lib in its own
# process or runs in the same shell — same model as portfolio_config.sh.
declare -A ORDO_LANE_REGISTRY=()

lane_registry_known() {
  local id=${1:?usage: lane_registry_known <id>}
  [[ -n "${ORDO_LANE_REGISTRY[$id]+x}" ]]
}

lane_registry_register() {
  local id=${1:?usage: lane_registry_register <id> <description> [env_prefix] [require_command]}
  local description=${2:?usage: lane_registry_register <id> <description> [env_prefix] [require_command]}
  local env_prefix=${3:-}
  local require_command=${4:-}
  if [[ "$id" == *"|"* ]]; then
    printf 'lane_registry_register: id must not contain "|": %s\n' "$id" >&2
    return 2
  fi
  ORDO_LANE_REGISTRY[$id]="${description}|${env_prefix}|${require_command}"
}

lane_registry_lanes() {
  local id
  for id in "${!ORDO_LANE_REGISTRY[@]}"; do
    printf '%s\n' "$id"
  done | LC_ALL=C sort
}

lane_registry_meta() {
  local id=${1:?usage: lane_registry_meta <id>}
  if ! lane_registry_known "$id"; then
    return 1
  fi
  printf '%s|%s\n' "$id" "${ORDO_LANE_REGISTRY[$id]}"
}

lane_registry_status_known() {
  local status=${1:?usage: lane_registry_status_known <status>}
  local known
  for known in "${ORDO_LANE_KNOWN_STATUSES[@]}"; do
    [[ "$status" == "$known" ]] && return 0
  done
  return 1
}

lane_registry_short_hostname() {
  if command -v hostname >/dev/null 2>&1; then
    hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'unknown\n'
  else
    printf '%s\n' "${HOSTNAME:-unknown}"
  fi
}

lane_registry_evidence_envelope() {
  local id=${1:?usage: lane_registry_evidence_envelope <id> [status] [details_json] [configured] [available]}
  local status=${2:-unknown}
  local details_json=${3:-{\}}
  local configured=${4:-false}
  local available=${5:-false}

  if ! lane_registry_known "$id"; then
    printf 'lane_registry_evidence_envelope: unknown lane: %s\n' "$id" >&2
    return 2
  fi
  if ! lane_registry_status_known "$status"; then
    printf 'lane_registry_evidence_envelope: unknown status: %s (allowed: %s)\n' \
      "$status" "${ORDO_LANE_KNOWN_STATUSES[*]}" >&2
    return 3
  fi

  local description env_prefix require_command
  IFS='|' read -r description env_prefix require_command <<<"${ORDO_LANE_REGISTRY[$id]}"

  local captured_at host
  captured_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  host=$(lane_registry_short_hostname)

  case "$configured" in
    true|1|yes|on) configured=true ;;
    *) configured=false ;;
  esac
  case "$available" in
    true|1|yes|on) available=true ;;
    *) available=false ;;
  esac

  jq -nc \
    --arg schema_version "$ORDO_LANE_SCHEMA_VERSION" \
    --arg lane "$id" \
    --arg lane_description "$description" \
    --arg env_prefix "$env_prefix" \
    --arg require_command "$require_command" \
    --arg captured_at "$captured_at" \
    --arg host "$host" \
    --arg status "$status" \
    --argjson configured "$configured" \
    --argjson available "$available" \
    --argjson details "$details_json" \
    '{
      schema_version:$schema_version,
      lane:$lane,
      lane_description:$lane_description,
      env_prefix:$env_prefix,
      require_command:$require_command,
      captured_at:$captured_at,
      host:$host,
      status:$status,
      configured:$configured,
      available:$available,
      details:$details
    }'
}

lane_registry_envelope_validate() {
  local payload=${1:?usage: lane_registry_envelope_validate <json>}
  local key
  printf '%s' "$payload" | jq -e --arg expected "$ORDO_LANE_SCHEMA_VERSION" \
    '(type == "object") and (.schema_version == $expected)' >/dev/null 2>&1 || return 1
  for key in "${ORDO_LANE_ENVELOPE_REQUIRED_KEYS[@]}"; do
    printf '%s' "$payload" | jq -e --arg k "$key" 'has($k)' >/dev/null 2>&1 || return 1
  done
}

# Preregister the known lanes. New lanes (visual, network, auth) get a slot
# here so consumers can list them even before the lane code itself ships.
# Concrete lane implementations call lane_registry_register again from their
# own libs; the second call is idempotent and refreshes the description.
lane_registry_register host_health \
  "Host log/journal/session pressure probe (lib/host_health.sh)" \
  "HOST_HEALTH_" ""
lane_registry_register host_assessment \
  "Host capacity / suitability probe (lib/host_assessment.sh)" \
  "ORDO_HOST_ASSESSMENT_" ""
lane_registry_register visual \
  "Visual verification probe (Figma/Playwright/Chrome) — opt-in via ORCH_VISUAL_DISPLAY" \
  "ORCH_VISUAL_" "google-chrome"
lane_registry_register network \
  "Network egress / DNS probe (planned)" \
  "ORCH_NETWORK_" ""
lane_registry_register auth \
  "Provider auth / token probe (planned)" \
  "ORCH_AUTH_" ""
