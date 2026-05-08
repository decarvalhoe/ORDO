#!/usr/bin/env bash
# scripts/visual_lane_probe.sh — emit a visual-verification capability report.
#
# Usage:
#   visual_lane_probe.sh [--json|--text] [--require-enabled]
#
# The lane is opt-in: set `ORCH_VISUAL_DISPLAY` (e.g. `:20`) to enable. When
# unset, the script exits 0 with an `enabled=false` payload so dispatchers
# that pipe its output never need to special-case "no GUI on this host".
# Pass `--require-enabled` to flip that into a hard error (exit 1) when the
# lane is disabled — useful in dispatch briefs that absolutely require a
# visual lane to be configured.
#
# All readiness probes are bounded by `ORCH_VISUAL_PROBE_TIMEOUT_SEC`
# (default 3s) so this script is safe to call from preflights without
# risking a hang. See `docs/visual-verification-lane.md` for the full
# configuration surface and JSON schema.

set -euo pipefail

TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# shellcheck source=../lib/visual_lane.sh
source "$TK/lib/visual_lane.sh"

usage() {
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
}

FORMAT="json"
REQUIRE_ENABLED=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --text) FORMAT="text"; shift ;;
    --require-enabled) REQUIRE_ENABLED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'visual_lane_probe.sh: unknown arg %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$REQUIRE_ENABLED" = "1" ] && ! visual_lane_enabled; then
  printf 'visual_lane_probe.sh: ORCH_VISUAL_DISPLAY is not set; lane is required by --require-enabled\n' >&2
  exit 1
fi

visual_lane_collect --format "$FORMAT"
