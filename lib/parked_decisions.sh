#!/usr/bin/env bash
# parked_decisions.sh — JSON ledger for needs-user-auth / operator-arbitration
# items that must NOT pause the orchestrator cycle.
#
# Source ticket: rbok#725. The behavioral source of truth is captured in
# memory `feedback_pending_arbitration_no_block.md` (filed 2026-05-16):
# the orchestrator surfaces a parked decision once with options and then
# continues cycling on the next priority. Cycle wakeup pauses only when
# the genuine queue is exhausted, not because an item is parked.
#
# Storage shape (array of objects, atomic rewrites):
#   [
#     {
#       "id":         "<stable-key>",            # idempotency key
#       "kind":       "needs_user_auth"          # |operator_intervention_required
#       "source":     "dispatch_ticket"          # | post_merge_cleanup | pr_merge | ...
#       "agent":      "agent-001",
#       "target":     "#725",                    # ticket / PR / branch
#       "summary":    "short human line",
#       "options":    "comma,separated,actions", # operator-facing hints
#       "created_at": "2026-05-21T11:22:33Z"
#     }
#   ]
#
# Public API (idempotent, safe to source multiple times):
#   parked_decisions_file_path                   — echo resolved file path
#   parked_decisions_read                        — cat current array (or "[]")
#   parked_decisions_write <json-array>          — atomic write
#   parked_decisions_add  <id> <kind> <source> \
#                         <agent> <target> <summary> [options]
#   parked_decisions_clear <id>
#   parked_decisions_list                        — TSV: id<TAB>kind<TAB>...
#   parked_decisions_reminders                   — Markdown bullet lines

if [[ -n "${__PARKED_DECISIONS_SH_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
__PARKED_DECISIONS_SH_SOURCED=1

parked_decisions_file_path() {
  if [[ -n "${PARKED_DECISIONS_FILE:-}" ]]; then
    printf '%s' "$PARKED_DECISIONS_FILE"
    return 0
  fi
  if declare -F state_file >/dev/null 2>&1; then
    state_file parked_decisions.json
    return 0
  fi
  local base="${ORCH_STATE_BASE:-/root/.local/share/orch-state}"
  local project="${PROJECT:-default}"
  printf '%s/%s/parked_decisions.json' "$base" "$project"
}

parked_decisions_read() {
  local target
  target=$(parked_decisions_file_path)
  if [[ -s "$target" ]]; then
    if jq -e 'type == "array"' "$target" >/dev/null 2>&1; then
      cat "$target"
      return 0
    fi
  fi
  printf '[]\n'
}

# parked_decisions_write <json-array> — atomic replace under flock.
parked_decisions_write() {
  local payload=${1?usage: parked_decisions_write <json-array>}
  local target lock tmp
  target=$(parked_decisions_file_path)
  lock="${target}.lock"
  tmp="${target}.tmp.$$"

  mkdir -p "$(dirname "$target")" 2>/dev/null || true
  (
    flock 9
    # Validate before persisting so we never write corrupt state.
    printf '%s' "$payload" | jq -e 'type == "array"' >/dev/null
    printf '%s\n' "$payload" | jq '.' > "$tmp"
    mv "$tmp" "$target"
  ) 9>"$lock"
}

# parked_decisions_add <id> <kind> <source> <agent> <target> <summary> [options]
# Idempotent on <id>: re-adding the same id updates the row in place but does
# NOT duplicate it; created_at is preserved from the first add.
parked_decisions_add() {
  local id=${1:?usage: parked_decisions_add <id> <kind> <source> <agent> <target> <summary> [options]}
  local kind=${2:?usage: parked_decisions_add <id> <kind> <source> <agent> <target> <summary> [options]}
  local source=${3:?usage: parked_decisions_add <id> <kind> <source> <agent> <target> <summary> [options]}
  local agent=${4:-}
  local target_ref=${5:-}
  local summary=${6:-}
  local options=${7:-}
  local now current updated
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  current=$(parked_decisions_read)
  updated=$(printf '%s' "$current" | jq -c \
    --arg id "$id" \
    --arg kind "$kind" \
    --arg source "$source" \
    --arg agent "$agent" \
    --arg target "$target_ref" \
    --arg summary "$summary" \
    --arg options "$options" \
    --arg now "$now" '
      . as $arr
      | ($arr | map(select(.id == $id)) | .[0]) as $existing
      | ($arr | map(select(.id != $id))) as $rest
      | $rest + [
          {
            id:         $id,
            kind:       $kind,
            source:     $source,
            agent:      $agent,
            target:     $target,
            summary:    $summary,
            options:    $options,
            created_at: ($existing.created_at // $now),
            updated_at: $now
          }
        ]
    ')
  parked_decisions_write "$updated"
}

# parked_decisions_should_park <id> [ttl-seconds]
# TTL gate for callers that observe an operator-intervention condition many
# times in a row and want to avoid re-reminding within a quiet window.
# Returns 0 (yes, park) when:
#   - no existing entry has this id, OR
#   - the existing entry's created_at is older than <ttl-seconds> (default 0).
# Returns 1 (suppress) otherwise. TTL of 0 = always park.
parked_decisions_should_park() {
  local id=${1:?usage: parked_decisions_should_park <id> [ttl-seconds]}
  local ttl=${2:-0}
  local existing now created_at age
  existing=$(parked_decisions_read \
    | jq -r --arg id "$id" '.[] | select(.id == $id) | .created_at // ""' \
    | head -n1)
  if [[ -z "$existing" ]]; then
    return 0
  fi
  if [[ "$ttl" -le 0 ]] 2>/dev/null; then
    return 0
  fi
  now=$(date -u +%s)
  created_at=$(date -u -d "$existing" +%s 2>/dev/null || printf '0')
  age=$((now - created_at))
  if [[ "$age" -ge "$ttl" ]]; then
    return 0
  fi
  return 1
}

# parked_decisions_clear <id>
parked_decisions_clear() {
  local id=${1:?usage: parked_decisions_clear <id>}
  local current updated
  current=$(parked_decisions_read)
  updated=$(printf '%s' "$current" | jq -c \
    --arg id "$id" 'map(select(.id != $id))')
  parked_decisions_write "$updated"
}

# parked_decisions_list — compact TSV for status-line embedding.
# Columns: id<TAB>kind<TAB>source<TAB>agent<TAB>target<TAB>summary
parked_decisions_list() {
  parked_decisions_read \
    | jq -r '.[] | [.id, .kind, .source, .agent, .target, .summary] | @tsv'
}

# parked_decisions_reminders — Markdown bullet lines suitable for trailing a
# compact cycle status report. Empty stdout when no entries are parked.
parked_decisions_reminders() {
  parked_decisions_read \
    | jq -r '
        if length == 0 then empty
        else
          .[] | "- **\(.kind)** [\(.id)] \(.target // "") — \(.summary // "")" +
                (if (.options // "") == "" then ""
                 else " — options: \(.options)" end)
        end
      '
}
