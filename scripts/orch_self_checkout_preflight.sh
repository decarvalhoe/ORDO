#!/usr/bin/env bash
# orch_self_checkout_preflight.sh — Surface ORDO orchestrator self-checkout
# state before live dispatch and audit, and refuse to proceed silently from a
# behind, diverged, or dirty toolkit checkout.
#
# Usage:
#   bash orch_self_checkout_preflight.sh [<project_short|config_path>]
#
# Exit codes:
#   0   clean and current with upstream, or local-ahead, or operator override
#   2   behind / diverged / dirty / upstream-missing
#
# Env overrides:
#   ORCH_SELF_CHECKOUT_REPO         path of the checkout to inspect
#                                   (default: toolkit root resolved from
#                                   this script's location)
#   ORCH_SELF_CHECKOUT_ALLOW_STALE  set to 1 to demote a block to a warning
#                                   and exit 0 — operator-acknowledged stale
#                                   run
#
# Why: live dispatch/audit ships scripts, templates, and heuristics from the
# toolkit checkout. Running them from a behind or dirty local main can
# re-report already-fixed behavior or apply outdated rules, undermining the
# audit loop's trust.

set -euo pipefail

TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO="${ORCH_SELF_CHECKOUT_REPO:-$TK}"

# An optional config arg is accepted for callsite symmetry with the rest of
# the session-start sequence; the preflight inspects the orchestrator's own
# checkout, not a per-project workdir, so the value is not used.
: "${1:-}"

emit() { printf 'orch self-checkout preflight: %s\n' "$*" >&2; }

if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  emit "skip: $REPO is not a git checkout"
  exit 0
fi

branch=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'HEAD')
local_sha=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || printf 'unknown')

dirty=$(git -C "$REPO" status --porcelain 2>/dev/null || printf '')

upstream_ref=$(git -C "$REPO" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || printf '')
if [[ -n "$upstream_ref" ]]; then
  upstream_sha=$(git -C "$REPO" rev-parse "$upstream_ref" 2>/dev/null || printf 'unknown')
else
  upstream_sha='unknown'
fi

determine_state() {
  if [[ -n "$dirty" ]]; then
    printf 'dirty'
    return
  fi
  if [[ -z "$upstream_ref" || "$upstream_sha" == "unknown" ]]; then
    printf 'upstream-missing'
    return
  fi
  if [[ "$local_sha" == "$upstream_sha" ]]; then
    printf 'current'
    return
  fi
  if git -C "$REPO" merge-base --is-ancestor "$local_sha" "$upstream_sha" 2>/dev/null; then
    printf 'behind'
    return
  fi
  if git -C "$REPO" merge-base --is-ancestor "$upstream_sha" "$local_sha" 2>/dev/null; then
    printf 'ahead'
    return
  fi
  printf 'diverged'
}

state=$(determine_state)

cat >&2 <<EOF
orch self-checkout preflight
  repo:     $REPO
  branch:   $branch
  local:    $local_sha
  upstream: ${upstream_ref:-<none>} $upstream_sha
  state:    $state
EOF

case "$state" in
  current|ahead)
    exit 0
    ;;
  behind|diverged|dirty|upstream-missing)
    if [[ "${ORCH_SELF_CHECKOUT_ALLOW_STALE:-0}" == "1" ]]; then
      emit "operator override ORCH_SELF_CHECKOUT_ALLOW_STALE=1 — proceeding from $state checkout"
      exit 0
    fi
    emit "block: refuse to proceed from $state checkout. Resolve with 'git -C $REPO status' then 'git -C $REPO pull --ff-only', or set ORCH_SELF_CHECKOUT_ALLOW_STALE=1 to override."
    exit 2
    ;;
esac
