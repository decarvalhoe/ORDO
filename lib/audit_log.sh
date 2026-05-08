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

# audit_external_mutation <scope> <mode> [context]
#   Structured signal for the external-PR-mutation gate (Required Rule 11).
#   `mode` is one of `allowed`, `refused`, `unknown`. The shape is consumed
#   by audit dashboards so it must stay stable; do not reorder fields. The
#   gate library (`lib/external_mutation_gate.sh`) is the only intended
#   caller — direct callers should prefer `external_pr_mutation_assert`.
audit_external_mutation() {
  local scope=${1:?usage: audit_external_mutation <scope> <mode> [context]}
  local mode=${2:?usage: audit_external_mutation <scope> <mode> [context]}
  local context=${3:-}
  audit "EXTERNAL_PR_MUTATION action=${scope} mode=${mode} context=${context}"
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

# External PR mutation authority gate (#268).
# ORDO distinguishes verification/audit evidence from mutations on third-party
# managed PRs. Default policy: local audit evidence only. External mutations
# (PR comments, draft/ready state changes, labels/assignees, merge actions,
# external issue-pack notifications) require an explicit per-action scope in
# ORCH_EXTERNAL_PR_MUTATIONS, which is a comma-separated list of scope names.
#
# Recognised scopes (repo-neutral; do not hardcode any provider or repo):
#   audit_evidence       - local capture only; always authorized.
#   issue_pack_notify    - notify the orchestrator's own issue pack.
#   pr_comment           - post a comment on an externally-managed PR.
#   pr_state             - flip draft/ready/reopen/close on such a PR.
#   pr_labels            - add/remove labels on such a PR.
#   pr_assignees         - add/remove assignees on such a PR.
#   pr_merge             - merge such a PR.
: "${ORCH_EXTERNAL_PR_MUTATIONS:=}"

ORCH_EXTERNAL_PR_MUTATION_KNOWN_SCOPES=(
  audit_evidence
  issue_pack_notify
  pr_comment
  pr_state
  pr_labels
  pr_assignees
  pr_merge
)

external_pr_mutation_known_scope() {
  local candidate=${1:?usage: external_pr_mutation_known_scope <scope>}
  local known
  for known in "${ORCH_EXTERNAL_PR_MUTATION_KNOWN_SCOPES[@]}"; do
    [ "$candidate" = "$known" ] && return 0
  done
  return 1
}

external_pr_mutation_authorized() {
  local scope=${1:?usage: external_pr_mutation_authorized <scope>}
  if ! external_pr_mutation_known_scope "$scope"; then
    return 2
  fi
  # audit_evidence is always authorized: capturing local evidence is the
  # default safe path and the whole point of audit-only mode.
  if [ "$scope" = "audit_evidence" ]; then
    return 0
  fi
  local entry
  IFS=',' read -r -a __orch_epm_entries <<<"${ORCH_EXTERNAL_PR_MUTATIONS:-}"
  for entry in "${__orch_epm_entries[@]}"; do
    entry=${entry// /}
    [ -z "$entry" ] && continue
    if [ "$entry" = "all" ] || [ "$entry" = "$scope" ]; then
      unset __orch_epm_entries
      return 0
    fi
  done
  unset __orch_epm_entries
  return 1
}

external_pr_mutation_assert() {
  local scope=${1:?usage: external_pr_mutation_assert <scope> [context]}
  local context=${2:-}
  if external_pr_mutation_authorized "$scope"; then
    audit "EXTERNAL_PR_MUTATION authorized scope=${scope} context=${context:-unspecified}"
    return 0
  fi
  case "$?" in
    2)
      audit "EXTERNAL_PR_MUTATION refused scope=${scope} reason=unknown_scope context=${context:-unspecified}"
      printf 'external_pr_mutation_refused: unknown scope %s; authorize via ORCH_EXTERNAL_PR_MUTATIONS\n' \
        "$scope" >&2
      return "${ORCH_EXTERNAL_PR_MUTATION_REFUSED_EXIT_CODE:-80}"
      ;;
    *)
      audit "EXTERNAL_PR_MUTATION refused scope=${scope} reason=not_authorized context=${context:-unspecified}"
      printf 'external_pr_mutation_refused: scope=%s not in ORCH_EXTERNAL_PR_MUTATIONS=%s; default is audit-only\n' \
        "$scope" "${ORCH_EXTERNAL_PR_MUTATIONS:-<empty>}" >&2
      return "${ORCH_EXTERNAL_PR_MUTATION_REFUSED_EXIT_CODE:-80}"
      ;;
  esac
}

# record_local_gate_evidence stores audit-only evidence under the project
# state directory so audit-only mode still leaves durable traces. Repo-neutral:
# the caller supplies a scope-tag and a body. The path is returned on stdout.
record_local_gate_evidence() {
  local scope_tag=${1:?usage: record_local_gate_evidence <scope-tag> <body>}
  local body=${2-}
  local ts dir target
  ts=$(date -u +'%Y%m%dT%H%M%SZ')
  dir="$(state_dir)/gate-evidence"
  mkdir -p "$dir" 2>/dev/null || true
  # scope-tag is sanitised to a safe filename: replace anything non
  # alnum/dash/underscore with a dash to keep the audit path predictable.
  local safe_tag=${scope_tag//[^A-Za-z0-9_.-]/-}
  target="$dir/${ts}-${safe_tag}.md"
  printf '%s' "$body" > "$target"
  audit "EXTERNAL_PR_MUTATION local_evidence scope=${scope_tag} path=${target}"
  printf '%s' "$target"
}

# audit_assert_evidence_outside_worktree <path> [<context>]
#
# Refuse (or warn about) attempts to write evidence/artifact files inside
# the active worktree. ORDO doctrine (#264 PR #304 finding, durable item
# #313): screenshots, forensic dumps, capability JSON, runtime logs and
# any other operator-readable artifact must NOT live under a working tree,
# otherwise they end up committed to feature branches by accident or
# pollute `git status`.
#
# Modes (`ORCH_EVIDENCE_PATH_GUARD`, default `strict`):
#   strict — emit `EVIDENCE PATH GUARD status=refused`, return 1
#   warn   — emit `EVIDENCE PATH GUARD status=warned`,  return 0
#   off    — silent return 0 (escape hatch for tests / migrations)
#
# The detector lives in `lib/worktree_helpers.sh`; we source it lazily so
# callers that only need the audit primitives keep working when sourced
# in isolation. If the detector cannot be located, the assertion logs a
# `status=skipped reason=detector-unavailable` line and returns 0 — the
# audit trail still records the attempt, but the dispatcher does not get
# blocked by a missing helper.
audit_assert_evidence_outside_worktree() {
  local path=${1:?usage: audit_assert_evidence_outside_worktree <path> [<context>]}
  local context=${2:-unspecified}
  local mode=${ORCH_EVIDENCE_PATH_GUARD:-strict}
  case "$mode" in off) return 0 ;; esac

  if ! declare -F worktree_path_is_inside >/dev/null 2>&1; then
    local _audit_self_dir
    _audit_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    if [[ -f "$_audit_self_dir/worktree_helpers.sh" ]]; then
      # shellcheck source=lib/worktree_helpers.sh
      source "$_audit_self_dir/worktree_helpers.sh"
    fi
  fi
  if ! declare -F worktree_path_is_inside >/dev/null 2>&1; then
    audit "EVIDENCE PATH GUARD status=skipped reason=detector-unavailable path=$path context=$context"
    return 0
  fi

  if worktree_path_is_inside "$path"; then
    case "$mode" in
      warn)
        audit "EVIDENCE PATH GUARD status=warned path=$path context=$context"
        return 0
        ;;
      *)
        audit "EVIDENCE PATH GUARD status=refused path=$path context=$context mode=strict"
        return 1
        ;;
    esac
  fi
  return 0
}

# Self-test if invoked directly (will fail since we set -u and PROJECT
# isn't set without a config, hence "sourced only" in the docstring).
