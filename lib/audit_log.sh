#!/usr/bin/env bash
# audit_log.sh — central audit + state-dir helpers for orch-toolkit.
# Sourced by every script. NEVER run directly.
#
# Functions:
#   audit MSG         — append timestamped line to /var/log/orch/<PROJECT>.log
#                       and echo to stdout. Auto-creates dir.
#   state_dir         — echo per-project state dir
#                       ($XDG_DATA_HOME/orch-state/$PROJECT, default
#                       /root/.local/share/orch-state/$PROJECT). Auto-creates.
#   audit_action ACTION KEY=VAL...
#                     — structured event: 'AUDIT LOG: <ts> <ACTION> k=v k=v'
#   die MSG           — log error + exit 1.
#
# Required env: PROJECT (from sourced config)

set -euo pipefail

: "${PROJECT:?audit_log.sh: PROJECT must be set (source a config first)}"
: "${ORCH_LOG_DIR:=/var/log/orch}"
: "${ORCH_STATE_BASE:=${XDG_DATA_HOME:-/root/.local/share}/orch-state}"
: "${ORCH_OTEL_ENDPOINT:=}"
: "${ORCH_OTEL_SERVICE_NAME:=ordo}"
: "${ORCH_OTEL_SCOPE_NAME:=ordo.audit}"
: "${ORCH_OTEL_TIMEOUT_SEC:=0.2}"

_ORCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config_check.sh
source "$_ORCH_LIB_DIR/config_check.sh"
# shellcheck source=lib/log_bounds.sh
source "$_ORCH_LIB_DIR/log_bounds.sh"

mkdir -p "$ORCH_LOG_DIR" 2>/dev/null || true

otel_python_bin() {
  if [ -n "${ORCH_OTEL_PYTHON_BIN:-}" ] && command -v "$ORCH_OTEL_PYTHON_BIN" >/dev/null 2>&1; then
    printf '%s\n' "$ORCH_OTEL_PYTHON_BIN"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    command -v python3
    return 0
  fi

  if command -v python >/dev/null 2>&1; then
    command -v python
    return 0
  fi

  return 1
}

otel_export_async() {
  local ts=${1:?usage: otel_export_async <timestamp> <message>}
  local msg=${2:-}
  local pybin

  [ -n "$ORCH_OTEL_ENDPOINT" ] || return 0
  pybin=$(otel_python_bin) || return 0

  ORCH_OTEL_ENDPOINT="$ORCH_OTEL_ENDPOINT" \
  ORCH_OTEL_SERVICE_NAME="$ORCH_OTEL_SERVICE_NAME" \
  ORCH_OTEL_SCOPE_NAME="$ORCH_OTEL_SCOPE_NAME" \
  ORCH_OTEL_TIMEOUT_SEC="$ORCH_OTEL_TIMEOUT_SEC" \
  PROJECT="$PROJECT" \
  "$pybin" - "$ts" "$msg" >/dev/null 2>&1 <<'PY' &
import datetime
import json
import os
import sys
import time
import urllib.request
import uuid

timestamp, message = sys.argv[1:3]
event_type = (message.split()[0].rstrip(":") if message.split() else "AUDIT") or "AUDIT"

attributes = {
    "project": os.environ["PROJECT"],
    "event_type": event_type,
    "audit.message": message,
}

for token in message.split()[1:]:
    if "=" not in token:
        continue
    key, value = token.split("=", 1)
    if key:
        attributes[key] = value

try:
    start_ns = int(
        datetime.datetime.strptime(timestamp, "%Y-%m-%dT%H:%M:%SZ")
        .replace(tzinfo=datetime.timezone.utc)
        .timestamp()
        * 1_000_000_000
    )
except ValueError:
    start_ns = time.time_ns()

end_ns = max(start_ns, time.time_ns())

payload = {
    "resourceSpans": [
        {
            "resource": {
                "attributes": [
                    {"key": "service.name", "value": {"stringValue": os.environ["ORCH_OTEL_SERVICE_NAME"]}},
                    {"key": "service.namespace", "value": {"stringValue": "ordo"}},
                ]
            },
            "scopeSpans": [
                {
                    "scope": {
                        "name": os.environ["ORCH_OTEL_SCOPE_NAME"],
                        "version": "1.0",
                    },
                    "spans": [
                        {
                            "traceId": uuid.uuid4().hex,
                            "spanId": uuid.uuid4().hex[:16],
                            "name": event_type,
                            "startTimeUnixNano": str(start_ns),
                            "endTimeUnixNano": str(end_ns),
                            "attributes": [
                                {"key": key, "value": {"stringValue": value}}
                                for key, value in attributes.items()
                            ],
                        }
                    ],
                }
            ],
        }
    ]
}

request = urllib.request.Request(
    os.environ["ORCH_OTEL_ENDPOINT"],
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
timeout = max(float(os.environ.get("ORCH_OTEL_TIMEOUT_SEC", "0.2")), 0.01)

try:
    with urllib.request.urlopen(request, timeout=timeout) as response:
        response.read()
except Exception:
    pass
PY
}

audit() {
  local msg="$*"
  local ts
  ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  local line="AUDIT LOG: $ts $msg"
  local log_file="$ORCH_LOG_DIR/$PROJECT.log"
  orch_log_rotate_if_needed "$log_file"
  printf '%s\n' "$line" | tee -a "$log_file" >&2
  orch_log_rotate_if_needed "$log_file"
  otel_export_async "$ts" "$msg"
}

audit_action() {
  local action=$1; shift
  audit "$action $*"
}

state_dir() {
  local d="$ORCH_STATE_BASE/$PROJECT"
  mkdir -p "$d" 2>/dev/null || true
  printf '%s' "$d"
}

die() {
  audit "FATAL: $*"
  exit 1
}

# Self-test if invoked directly (will fail since we set -u and PROJECT
# isn't set without a config, hence "sourced only" in the docstring).
