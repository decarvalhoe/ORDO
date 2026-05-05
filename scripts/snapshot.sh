#!/usr/bin/env bash
# scripts/snapshot.sh — capture an immutable .tar.gz of the toolkit at three
# independent paths. Run this BEFORE any risky operation (cleanup, restructure).
# Idempotent: writes to a per-second-precision UTC timestamp.
#
# Usage: snapshot.sh
#
# Snapshot paths (all paired with .sha256 sidecar, mode 0444):
#   /root/repos/RBOK-orchestrator/.local-backups/
#   /root/.config/orch-toolkit-snapshots/
#   /var/log/orch/orch-toolkit-snapshots/
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TS=$(date -u +%Y%m%dT%H%M%SZ)
SNAP="orchestrator-toolkit-${TS}.tar.gz"
PARENT=$(dirname "$TK")

DESTS=(
  "/root/repos/RBOK-orchestrator/.local-backups"
  "/root/.config/orch-toolkit-snapshots"
  "/var/log/orch/orch-toolkit-snapshots"
)

# Build once in /tmp, then distribute.
( cd "$PARENT" && tar -czf "/tmp/${SNAP}" "$(basename "$TK")" )

declare -a SHA_LINES
for dest in "${DESTS[@]}"; do
  mkdir -p "$dest"
  cp "/tmp/${SNAP}" "${dest}/${SNAP}"
  ( cd "$dest" && sha256sum "$SNAP" > "${SNAP}.sha256" )
  chmod 444 "${dest}/${SNAP}" "${dest}/${SNAP}.sha256"
  SHA_LINES+=("$(sha256sum "${dest}/${SNAP}")")
done
rm "/tmp/${SNAP}"

# Verify the three copies are byte-identical.
echo "=== ${SNAP} written to ${#DESTS[@]} paths ==="
for line in "${SHA_LINES[@]}"; do echo "  $line"; done

# All three sha256 should match.
uniq_count=$(printf '%s\n' "${SHA_LINES[@]}" | awk '{print $1}' | sort -u | wc -l)
if [ "$uniq_count" -ne 1 ]; then
  echo "ERROR: snapshots diverge across destinations" >&2
  exit 1
fi

# Audit (best-effort — works only when sourced as part of a project context).
if command -v audit >/dev/null 2>&1; then
  audit "TOOLKIT SNAPSHOT created ${SNAP} at ${#DESTS[@]} paths"
fi

echo "OK"
