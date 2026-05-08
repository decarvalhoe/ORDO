#!/usr/bin/env bash
# scripts/runtime_freshness_preflight.sh — auto-fast-forward orchestrator
# runtime (#377).
#
# Verify the orchestrator runtime checkout is a fresh sibling of
# `origin/<default>`. When the runtime is `clean-behind` (or only
# untracked sidecars are present), fetch and fast-forward it to the remote
# tip. When the runtime is `dirty-tracked`, `ahead-only`, or `diverged`,
# refuse and emit a structured audit line so the operator sees the stall.
#
# Usage:
#   bash runtime_freshness_preflight.sh [--path <runtime-path>]
#                                       [--context <tag>]
#                                       [--no-fetch]
#                                       [--summary]
#
# Flags:
#   --path     Runtime path to check. Defaults to $ORCH_RUNTIME_FRESHNESS_PATH
#              or to the toolkit root that loaded this script (TK).
#   --context  Audit context tag (default: runtime_freshness_preflight).
#   --no-fetch Skip `git fetch origin <branch>` (operator already fetched, or
#              we are running offline / from a test fixture).
#   --summary  Echo the one-line status (`runtime_sha=... behind=N ahead=M
#              classification=K action=A`) and exit 0 without mutating.
#
# Exit codes (mirrors `runtime_freshness_assert`):
#   0   runtime is fresh (already up-to-date or fast-forwarded)
#   10  refused: tracked dirt blocks auto-update
#   11  refused: local ahead of / diverged from origin
#   12  refused: runtime path is not a git repo
#   13  refused: fetch failed
#
# Audit emission falls back to stderr `printf` when this script is run
# without a project config sourced. When `PROJECT` is set, the project
# audit log under `$ORCH_LOG_DIR/$PROJECT.log` receives the structured
# RUNTIME_FRESHNESS line.

set -euo pipefail

TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
}

PATH_ARG=""
CONTEXT_ARG=""
SUMMARY_ONLY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --path)
      PATH_ARG=${2:?--path needs a value}
      shift 2
      ;;
    --context)
      CONTEXT_ARG=${2:?--context needs a value}
      shift 2
      ;;
    --no-fetch)
      export ORCH_RUNTIME_FRESHNESS_NO_FETCH=1
      shift
      ;;
    --summary)
      SUMMARY_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      printf 'runtime_freshness_preflight: unknown arg %s\n' "$1" >&2
      exit 2
      ;;
    *)
      if [ -z "$PATH_ARG" ]; then
        PATH_ARG=$1
        shift
      else
        printf 'runtime_freshness_preflight: unexpected extra arg %s\n' "$1" >&2
        exit 2
      fi
      ;;
  esac
done

PATH_ARG=${PATH_ARG:-${ORCH_RUNTIME_FRESHNESS_PATH:-$TK}}
CONTEXT_ARG=${CONTEXT_ARG:-runtime_freshness_preflight}

# Source the project audit pipeline when PROJECT is set so the
# RUNTIME_FRESHNESS line lands in the per-project log + OTel hook. When
# PROJECT is unset, the lib's `_runtime_freshness_audit` falls back to a
# stderr `printf`, which keeps the preflight useful for ad-hoc operator
# runs without forcing a config load.
if [ -n "${PROJECT:-}" ] && [ -f "$TK/lib/audit_log.sh" ]; then
  # shellcheck source=../lib/audit_log.sh
  source "$TK/lib/audit_log.sh"
fi

# shellcheck source=../lib/runtime_freshness.sh
source "$TK/lib/runtime_freshness.sh"

if [ "$SUMMARY_ONLY" -eq 1 ]; then
  runtime_freshness_summary_line "$PATH_ARG"
  exit 0
fi

runtime_freshness_assert "$PATH_ARG" "$CONTEXT_ARG"
