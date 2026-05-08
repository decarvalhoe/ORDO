#!/usr/bin/env bash
# scripts/visual_lane_probe.sh — visual-lane env-leak guard + capability probe.
#
# Two modes share this entry point because both PR #324 (leak guard) and
# PR #304 (capability probe) shipped under the same script name. The mode is
# selected by which flag the caller passes; the leak-guard remains the
# default so existing callers (`scripts/visual_lane_probe.sh --full`,
# `scripts/visual_lane_probe.sh --diff`) keep working.
#
# Leak-guard modes (default — assert no DISPLAY/XAUTHORITY/visual env leak):
#   --full              Scan the default visual-lane search paths under the
#                       repo root for env-leak patterns. (default)
#   --diff [<base>]     Scan only files changed since <base>. <base> defaults
#                       to origin/main, falling back to main, then HEAD~1.
#                       Changed paths are filtered to the default search set
#                       so a doc/template/script PR fails this guard in
#                       seconds rather than waiting for the full bats suite.
#   --paths <p>...      Override the search prefixes (test affordance).
#   --root <dir>        Override the repo root (test affordance). Defaults to
#                       the toolkit root resolved from this script's path.
#
# Capability-probe mode (emit a visual-lane capability report):
#   --json | --text     Pick the output format (default json) and switch into
#                       capability-probe mode.
#   --require-enabled   Switch into capability-probe mode and exit 1 if the
#                       lane is disabled (no `ORCH_VISUAL_DISPLAY` set).
#                       Useful in dispatch briefs that absolutely require a
#                       visual lane.
#
#   -h | --help         Show usage and exit 2.
#
# Exit codes:
#   0   clean / capability report emitted
#   1   --require-enabled was passed but the lane is disabled
#   $VISUAL_LANE_LEAK_EXIT_CODE (default 81) on leak
#   2   usage error or unresolvable diff base

set -euo pipefail

usage() {
  sed -n '2,37p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/visual_lane.sh
source "$TK/lib/visual_lane.sh"

mode="full"
base_ref=""
paths=()
root="$TK"
require_enabled=0
capability_format="json"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --full) mode="full" ;;
    --diff)
      mode="diff"
      if [ "${2:-}" ] && [ "${2#--}" = "${2}" ]; then
        base_ref=$2
        shift
      fi
      ;;
    --paths)
      shift
      while [ "$#" -gt 0 ] && [ "${1#--}" = "${1}" ]; do
        paths+=("$1")
        shift
      done
      continue
      ;;
    --root)
      root=${2:?--root requires a directory}
      shift
      ;;
    --json) mode="capability"; capability_format="json" ;;
    --text) mode="capability"; capability_format="text" ;;
    --require-enabled) mode="capability"; require_enabled=1 ;;
    -h|--help) usage ;;
    *) printf 'visual_lane_probe: unknown arg: %s\n' "$1" >&2; usage ;;
  esac
  shift
done

case "$mode" in
  capability)
    if [ "$require_enabled" = "1" ] && ! visual_lane_enabled; then
      printf 'visual_lane_probe.sh: ORCH_VISUAL_DISPLAY is not set; lane is required by --require-enabled\n' >&2
      exit 1
    fi
    visual_lane_collect --format "$capability_format"
    exit 0
    ;;
  full)
    if visual_lane_scan_paths "$root" "${paths[@]}"; then
      printf 'visual_lane_probe: clean (full scan, root=%s)\n' "$root"
      exit 0
    else
      printf 'visual_lane_probe: leak detected (full scan, root=%s)\n' "$root" >&2
      exit "$VISUAL_LANE_LEAK_EXIT_CODE"
    fi
    ;;
  diff)
    if [ -z "$base_ref" ]; then
      for cand in origin/main main HEAD~1; do
        if git -C "$root" rev-parse --verify "$cand" >/dev/null 2>&1; then
          base_ref=$cand
          break
        fi
      done
    fi
    if [ -z "$base_ref" ]; then
      printf 'visual_lane_probe: cannot resolve diff base (tried origin/main, main, HEAD~1)\n' >&2
      exit 2
    fi

    # Three-dot diff lists files changed on HEAD since the merge base — the
    # natural set for "what is this PR introducing". Fall back to two-dot
    # if the merge base cannot be computed (shallow clones, detached HEAD).
    changed=$(git -C "$root" diff --name-only "$base_ref"...HEAD 2>/dev/null || true)
    if [ -z "$changed" ]; then
      changed=$(git -C "$root" diff --name-only "$base_ref" 2>/dev/null || true)
    fi
    # Untracked files that were git-add-d but not committed are caught by
    # `git diff --cached --name-only`; include them so a pre-commit hook
    # sees the same surface as the upcoming commit.
    cached=$(git -C "$root" diff --cached --name-only 2>/dev/null || true)
    all_changed=$(printf '%s\n%s\n' "$changed" "$cached" | awk 'NF && !seen[$0]++')

    filtered=$(printf '%s\n' "$all_changed" | visual_lane_filter_diff_files "${paths[@]}")
    if [ -z "$filtered" ]; then
      printf 'visual_lane_probe: clean (diff base=%s, 0 in-scope changes)\n' "$base_ref"
      exit 0
    fi

    mapfile -t files <<< "$filtered"
    if visual_lane_scan_files "$root" "${files[@]}"; then
      printf 'visual_lane_probe: clean (diff base=%s, %d in-scope file(s))\n' \
        "$base_ref" "${#files[@]}"
      exit 0
    else
      printf 'visual_lane_probe: leak detected (diff base=%s, %d in-scope file(s))\n' \
        "$base_ref" "${#files[@]}" >&2
      exit "$VISUAL_LANE_LEAK_EXIT_CODE"
    fi
    ;;
esac
