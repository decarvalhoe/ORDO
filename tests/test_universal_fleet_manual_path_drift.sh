#!/usr/bin/env bash
# tests/test_universal_fleet_manual_path_drift.sh — guard against
# docs/universal-fleet-manual.md path-citation rot. Implements issue #445
# (parent epic #249).
#
# What this asserts:
#   Every (scripts|lib|templates|examples)/<path>.<ext> citation inside
#   docs/universal-fleet-manual.md must resolve to a real file on disk. The
#   manual is the durable operator entry point for the fleet onboarding
#   package shipped under EPIC #249; if a script gets renamed or removed
#   without updating the manual, operators following the doc will hit a
#   broken procedure and bypass the standard handoff.
#
# What this does NOT assert:
#   - Reverse drift (every script must be cited somewhere in the manual).
#   - Path citations in other docs (docs/onboarding-multi-project.md,
#     docs/runbooks/, etc.) — those have separate guards or no guard yet.
#   - Anchor (#section) targets inside Markdown links — only the file path
#     prefix is verified.
#
# Exit codes:
#   0  — no missing paths
#   1  — at least one cited path is missing on disk; the list is printed
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANUAL="$ROOT/docs/universal-fleet-manual.md"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

[ -s "$MANUAL" ] || fail "docs/universal-fleet-manual.md is missing or empty"

# Extract every fully-qualified (scripts|lib|templates|examples)/... path
# citation. The extension whitelist keeps us from matching stray strings or
# directory-only references. We strip trailing punctuation that grep would
# leave attached when the citation sits in prose (e.g. ", . ; ) ` ').
mapfile -t cited < <(
  grep -oE '(scripts|lib|templates|examples)/[A-Za-z0-9_./-]+\.(sh|md|tpl|json|yaml|yml|env)' "$MANUAL" \
    | sort -u
)

if [ "${#cited[@]}" -eq 0 ]; then
  fail "no (scripts|lib|templates|examples)/<path> citations found in docs/universal-fleet-manual.md — extraction regex is likely broken"
fi

missing=()
for path in "${cited[@]}"; do
  if [ ! -e "$ROOT/$path" ]; then
    missing+=("$path")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  printf 'docs/universal-fleet-manual.md cites %d path(s) that do not exist on disk:\n' \
    "${#missing[@]}" >&2
  for path in "${missing[@]}"; do
    printf '  - %s\n' "$path" >&2
  done
  printf '\nEither restore the file at the cited path or update docs/universal-fleet-manual.md to match the current layout.\n' >&2
  exit 1
fi

printf 'ok - test_universal_fleet_manual_path_drift (%d cited paths, all present)\n' \
  "${#cited[@]}"
