#!/usr/bin/env bash
# host_forensics_probe.sh - bounded host forensic/log probes.
#
# Usage:
#   host_forensics_probe.sh journal [journalctl filters...]
#
# The journal probe always uses a timeout, a since/until window, --no-pager,
# a capped line count, and a cleanup trap. Broad wildcard user-unit scans are
# refused because they can become a load contributor during outages.

set -euo pipefail

TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# shellcheck source=../lib/host_forensics.sh
source "$TK/lib/host_forensics.sh"

cleanup() {
  if [[ -n "${ORCH_HOST_FORENSICS_TMP_ROOT:-}" ]]; then
    rm -rf "$ORCH_HOST_FORENSICS_TMP_ROOT"
  fi
}
trap cleanup EXIT HUP INT TERM

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
}

command_name=${1:-}
case "$command_name" in
  journal)
    shift
    ORCH_HOST_FORENSICS_TMP_ROOT=$(mktemp -d -t host-forensics.XXXXXX)
    orch_host_forensics_journalctl "$@"
    ;;
  -h|--help|"")
    usage
    [[ -n "$command_name" ]] && exit 0
    exit 2
    ;;
  *)
    echo "unknown probe: $command_name" >&2
    usage
    exit 2
    ;;
esac
