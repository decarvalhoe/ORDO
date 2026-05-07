#!/usr/bin/env bash
# scripts/preempt_assignment.sh — first-class agent preemption.
#
# Replaces ad-hoc `tmux send-keys ... Escape` followed by manual
# `recover.sh --reset-state` with a single, audited operation that:
#   1. Captures a pane snapshot before interrupting (post-mortem trail).
#   2. Sends a bounded interrupt through the configured pane adapter.
#   3. Verifies worktree cleanliness on the agent's effective workdir.
#   4. Releases, parks, or preserves the agent's assignment based on
#      explicit flags (default: preserve — the safest non-destructive
#      mode; release/park refuse to clear state on dirty worktree
#      unless --force-dirty is passed).
#   5. Records a structured PREEMPT audit event with reason, branch,
#      dirty count, snapshot path and chosen next action.
#
# Usage:
#   bash scripts/preempt_assignment.sh <project_short|config_path> <agent> \
#        --reason "<text>" \
#        [--park | --release | --preserve] \
#        [--force-dirty] \
#        [--snapshot-lines N] \
#        [--dry-run]
#
# Exit codes:
#   0 — preemption recorded (interrupt sent, audit logged).
#   1 — argument / config error (caught by die or set -u).
#   3 — agent has no live tmux pane (audited as missing_pane).
#   4 — release/park requested but worktree is dirty and --force-dirty
#       not provided (audited as dirty_refused, assignment untouched).
#
# Source finding: F-028 (raw tmux interruption used instead of
# documented ORDO preemption). See RBOKproject/ORDO#108.

set -euo pipefail
TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck disable=SC1091
source "$TK/lib/dry_run.sh"
# shellcheck disable=SC1091
source "$TK/lib/config_resolver.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

usage() {
  cat >&2 <<'USAGE'
usage: preempt_assignment.sh <project_short|config_path> <agent>
       --reason "<text>"
       [--park | --release | --preserve]
       [--force-dirty] [--snapshot-lines N] [--dry-run]
USAGE
  exit 1
}

maybe_load_project_config "${1:-}"
if [[ "${ORCH_CONFIG_CONSUMED:-0}" == "1" ]]; then
  shift
fi

agent=${1:-}
[[ -n "$agent" ]] || usage
shift

reason=""
mode="preserve"
force_dirty=0
snapshot_lines=80
while [[ $# -gt 0 ]]; do
  case $1 in
    --reason)
      reason=${2:?--reason requires a value}
      shift 2
      ;;
    --park)      mode="park"; shift ;;
    --release)   mode="release"; shift ;;
    --preserve)  mode="preserve"; shift ;;
    --force-dirty) force_dirty=1; shift ;;
    --snapshot-lines)
      snapshot_lines=${2:?--snapshot-lines requires a value}
      shift 2
      ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; usage ;;
  esac
done

[[ -n "$reason" ]] || { printf '--reason is required\n' >&2; usage; }

# shellcheck disable=SC1091
source "$TK/lib/audit_log.sh"
# shellcheck disable=SC1091
source "$TK/lib/state_persist.sh"
# shellcheck disable=SC1091
source "$TK/lib/tmux_helpers.sh"
# shellcheck disable=SC1091
source "$TK/lib/worktree_helpers.sh"

target=$(agent_target "$agent")
session="${target%%:*}"

# Resolve the assignment snapshot we are preempting.
assignments_json=$(state_get assignments)
old_ticket=$(jq -r --arg a "$agent" '.[$a].issue // .[$a].ticket // ""' <<<"$assignments_json")
old_branch=$(jq -r --arg a "$agent" '.[$a].branch // ""' <<<"$assignments_json")
old_workdir=$(jq -r --arg a "$agent" '.[$a].workdir // ""' <<<"$assignments_json")
if [[ -z "$old_workdir" || "$old_workdir" == "null" ]]; then
  old_workdir=$(agent_effective_workdir "$agent" 2>/dev/null || true)
fi
sanitize_field() {
  local v=${1:-}
  [[ -z "$v" || "$v" == "null" ]] && printf 'none' || printf '%s' "$v"
}

# Prepare snapshot dir up-front so we can record even on early exits.
snapshot_dir="$(state_dir)/preempt"
mkdir -p "$snapshot_dir" 2>/dev/null || true
ts=$(date -u +'%Y%m%dT%H%M%SZ')
snapshot_path="$snapshot_dir/${agent}-${old_ticket:-none}-${ts}.log"

audit_preempt() {
  # Emits a single structured PREEMPT event, with stable key=value pairs.
  local next_action=$1
  local dirty_count=$2
  audit_action PREEMPT \
    "agent=$agent" \
    "session=$session" \
    "old_ticket=$(sanitize_field "$old_ticket")" \
    "branch=$(sanitize_field "$old_branch")" \
    "workdir=$(sanitize_field "$old_workdir")" \
    "dirty_count=$dirty_count" \
    "next_action=$next_action" \
    "reason=\"$reason\"" \
    "snapshot=$snapshot_path"
}

# 1. Pane probe — refuse early if the session is missing. We record a
# best-effort empty snapshot for the audit trail.
pane_alive=1
if dry_run_enabled; then
  dry_run_note "tmux has-session -t $session"
else
  if ! tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" has-session -t "$session" 2>/dev/null; then
    pane_alive=0
  fi
fi

if [[ "$pane_alive" -eq 0 ]]; then
  : > "$snapshot_path"
  audit_preempt "missing_pane" 0
  printf 'preempt: tmux session %s missing for agent %s\n' "$session" "$agent" >&2
  exit 3
fi

# 2. Capture pane snapshot BEFORE interrupting — preserves the busy
# state for forensics. capture_pane echoes lines; redirect to file.
if dry_run_enabled; then
  dry_run_note "capture_pane $target $snapshot_lines > $snapshot_path"
  : > "$snapshot_path"
else
  capture_pane "$target" "$snapshot_lines" > "$snapshot_path" 2>/dev/null || : > "$snapshot_path"
fi

# 3. Send the interrupt through the pane adapter. Escape is the
# Claude Code / Codex cancel sequence; bounded by ORCH_TMUX_TIMEOUT_SEC.
if dry_run_enabled; then
  dry_run_note "tmux send-keys -t $target Escape"
else
  tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" send-keys -t "$target" Escape 2>/dev/null || true
  sleep 0.5
fi

# 4. Verify worktree state — branch + dirty count. Best-effort; a
# missing or non-git workdir reports as dirty=0 but is recorded as
# branch=none so the audit trail is honest.
dirty_count=0
current_branch="$old_branch"
if [[ -n "$old_workdir" && -d "$old_workdir" ]] \
   && git -C "$old_workdir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  dirty_count=$(git -C "$old_workdir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  current_branch=$(git -C "$old_workdir" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '%s' "$old_branch")
fi
old_branch="$current_branch"

# 5. Decide next action.
case "$mode" in
  release|park)
    if [[ "$dirty_count" -gt 0 && "$force_dirty" -ne 1 ]]; then
      audit_preempt "dirty_refused" "$dirty_count"
      printf 'preempt: refusing to %s assignment for %s — %d dirty entries (use --force-dirty to override)\n' \
        "$mode" "$agent" "$dirty_count" >&2
      exit 4
    fi
    ;;
  preserve) : ;;
esac

case "$mode" in
  release)
    if dry_run_enabled; then
      dry_run_note "state_update assignments del(.\"$agent\")"
    else
      state_update assignments ". | del(.\"$agent\")"
    fi
    audit_preempt "released" "$dirty_count"
    ;;
  park)
    parked_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    reason_json=$(jq -Rn --arg r "$reason" '$r')
    park_filter='. | .["'"$agent"'"] = ((.["'"$agent"'"] // {}) + {parked: true, parked_at: "'"$parked_at"'", parked_reason: '"$reason_json"'})'
    if dry_run_enabled; then
      dry_run_note "state_update assignments park"
    else
      state_update assignments "$park_filter"
    fi
    audit_preempt "parked" "$dirty_count"
    ;;
  preserve)
    audit_preempt "preserved" "$dirty_count"
    ;;
esac
