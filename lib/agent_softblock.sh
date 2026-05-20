#!/usr/bin/env bash
# lib/agent_softblock.sh — soft-block detection + idle-capacity rebalance helper.
#
# Issue #757: during a live ORDO wave the orchestrator kept an agent occupied
# on a single ticket for ~2h while the agent had already declared an
# out-of-scope blocker in its pane ("Recommendation for the dispatcher:
# ... needs to be resolved on main..."). The doctrine-mandated rebalance
# never fired because the supervisor loop treated the populated
# `assignments.json` row as opaque busy capacity and never inspected pane
# state. Ten other agents sat idle for the same window.
#
# This helper classifies one agent pane into one of:
#   working      — the pane shows recent progress (commits, pushes, file
#                  writes, "Wrote", "modified", "Created", or a shell prompt
#                  that immediately follows a tool-success line).
#   soft_blocked — the pane body matches operator-handoff vocabulary
#                  ("Recommendation for the dispatcher", "blocker",
#                  "out of scope", "needs another dispatch", "cannot
#                  resume", "waiting on", ...) configurable via
#                  `ORCH_SOFTBLOCK_PATTERNS`.
#   idle         — neither of the above; the pane is at a prompt with no
#                  recent progress or handoff signal.
#
# `agent_softblock_run_rebalance_step` is the orchestrator entry point: it
# walks `assignments.json` rows, captures each pane, classifies it, and when
# `idle_count > 0 AND soft_blocked_count > 0` emits one
# `REBALANCE_REQUIRED` audit row plus one structured row per soft-blocked
# agent in `<state_dir>/intervention_queue.md`. The classifier itself is
# pure (text in, classification out) so tests can exercise it from fixture
# files without tmux.
#
# Tuning hooks (env):
#   ORCH_SOFTBLOCK_PATTERNS         Newline- or `|`-separated extended regex
#                                    fragments that mark a pane as
#                                    soft-blocked. When unset, the helper
#                                    falls back to
#                                    `agent_softblock_default_patterns`.
#   ORCH_SOFTBLOCK_WORKING_PATTERNS Newline- or `|`-separated extended regex
#                                    fragments that mark a pane as actively
#                                    working. When unset, the helper falls
#                                    back to
#                                    `agent_softblock_default_working_patterns`.
#   ORCH_SOFTBLOCK_PANE_LINES       Tail line count captured per pane via
#                                    `tmux capture-pane -p -S -<N>`.
#                                    Default 200.
#   ORCH_SOFTBLOCK_DISABLED         When set to `1`, the rebalance step
#                                    no-ops. Recommended only when the
#                                    operator runs an external monitor.

if [[ -n "${AGENT_SOFTBLOCK_LIB_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
AGENT_SOFTBLOCK_LIB_LOADED=1

# Default vocabulary, one extended-regex fragment per line. Lower-cased on
# match so callers do not need to predict pane casing.
agent_softblock_default_patterns() {
  cat <<'EOF'
recommendation for the dispatcher
recommendation: the dispatcher
needs another dispatch
out of scope
out-of-scope
cannot resume
waiting on
waiting for the dispatcher
blocker:
blockers:
blocked by
blocked on
soft[- ]blocked
needs operator
operator intervention
needs human
human decision
escalate to the operator
escalation required
EOF
}

agent_softblock_default_working_patterns() {
  cat <<'EOF'
^\[(main|develop|feat/|fix/|chore/|refactor/|docs/|test/)[^]]*\][[:space:]]
\bgit commit\b
\bgit push\b
\bcreated commit\b
\bpushed to\b
^to https://
^to git@
^\s*\d+ files? changed
^create mode \d+
^modify mode \d+
^[[:space:]]*writing\b
^[[:space:]]*wrote\b
^[[:space:]]*created\b
^[[:space:]]*modified\b
^[[:space:]]*updated\b
^[[:space:]]*applying patch\b
\bok, i\b
EOF
}

# Normalise an env-supplied pattern list. Both newline-separated and
# `|`-separated lists are accepted to match the way humans tend to type
# bash exports. Empty / pure-whitespace entries are skipped.
agent_softblock__normalise_patterns() {
  local raw=${1:-}
  [[ -n "$raw" ]] || return 0
  printf '%s\n' "$raw" \
    | tr '|' '\n' \
    | awk 'NF { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print }'
}

agent_softblock_patterns() {
  local raw=${ORCH_SOFTBLOCK_PATTERNS:-}
  if [[ -n "$raw" ]]; then
    agent_softblock__normalise_patterns "$raw"
    return 0
  fi
  agent_softblock_default_patterns
}

agent_softblock_working_patterns() {
  local raw=${ORCH_SOFTBLOCK_WORKING_PATTERNS:-}
  if [[ -n "$raw" ]]; then
    agent_softblock__normalise_patterns "$raw"
    return 0
  fi
  agent_softblock_default_working_patterns
}

# Resolve the pane body for a tmux target. Accepts either:
#   - a path to a readable file (treated as a pre-captured pane dump), or
#   - a tmux pane target (session:window.pane) — captured via tmux when
#     the binary is available.
# Empty target returns empty body successfully.
agent_softblock_capture_pane() {
  local target=${1:-}
  local lines=${ORCH_SOFTBLOCK_PANE_LINES:-200}
  [[ -n "$target" ]] || return 0
  if [[ -f "$target" ]]; then
    cat -- "$target"
    return 0
  fi
  command -v tmux >/dev/null 2>&1 || return 0
  tmux capture-pane -p -t "$target" -S "-${lines}" 2>/dev/null || true
}

# Return the first body line that matches the soft-block vocabulary so the
# intervention queue carries a one-line operator excerpt instead of the
# whole capture. The match is case-insensitive against the configured
# patterns. Stdout is empty when no pattern matches.
agent_softblock_match_excerpt() {
  local body=${1:-}
  [[ -n "$body" ]] || return 0
  local patterns
  patterns=$(agent_softblock_patterns)
  [[ -n "$patterns" ]] || return 0
  printf '%s\n' "$body" \
    | awk '{ print tolower($0) "|||" $0 }' \
    | grep -E -m1 -f <(printf '%s\n' "$patterns" | awk 'NF { print tolower($0) }') \
    | head -n1 \
    | awk -F '\\|\\|\\|' '{ sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2); print $2 }'
}

# Classify a pane body. The two pattern sets are checked in priority order:
# soft-block first (an explicit operator-handoff signal always wins over a
# stale "working" line that scrolled by earlier in the pane), then working,
# then idle as the fallback.
classify_agent_pane_body() {
  local body=${1:-}
  if [[ -z "$body" ]]; then
    printf 'idle\n'
    return 0
  fi
  local sb_patterns wk_patterns
  sb_patterns=$(agent_softblock_patterns)
  if [[ -n "$sb_patterns" ]]; then
    if printf '%s\n' "$body" \
         | awk '{ print tolower($0) }' \
         | grep -E -q -f <(printf '%s\n' "$sb_patterns" | awk 'NF { print tolower($0) }'); then
      printf 'soft_blocked\n'
      return 0
    fi
  fi
  wk_patterns=$(agent_softblock_working_patterns)
  if [[ -n "$wk_patterns" ]]; then
    if printf '%s\n' "$body" \
         | grep -E -q -f <(printf '%s\n' "$wk_patterns"); then
      printf 'working\n'
      return 0
    fi
  fi
  printf 'idle\n'
}

# classify_agent_pane <pane-target-or-file>
#   When the argument is a regular file, its contents are classified
#   directly. Otherwise, the argument is treated as a tmux pane target and
#   captured via `tmux capture-pane`. An empty argument classifies as
#   `idle` rather than failing, so the orchestrator loop stays warning-free
#   when an agent row has no pane wired up yet.
classify_agent_pane() {
  local target=${1:-}
  local body
  body=$(agent_softblock_capture_pane "$target")
  classify_agent_pane_body "$body"
}

# Append one row to the per-project intervention queue. The file is
# markdown so operators can grep / glow it without a JSON tool, and the
# row layout is deliberately wide so `column -t -s '|'` renders cleanly.
# Caller passes the recommended action so the orchestrator stays the
# authority on remediation language.
agent_softblock_append_intervention() {
  local queue_path=${1:?usage: agent_softblock_append_intervention <queue_path> <agent> <ticket> <excerpt> <recommendation>}
  local agent=${2:-unknown}
  local ticket=${3:-unknown}
  local excerpt=${4:-}
  local recommendation=${5:-}
  local ts
  ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  mkdir -p "$(dirname "$queue_path")" 2>/dev/null || true
  if [[ ! -s "$queue_path" ]]; then
    {
      printf '# ORDO intervention queue\n\n'
      printf 'One row per soft-blocked agent surfaced by `agent_softblock_run_rebalance_step`.\n'
      printf 'Operator action drains the row; orch_loop will re-add the row next cycle if the soft-block persists.\n\n'
      printf '| timestamp | agent | ticket | blocker_excerpt | recommended_action |\n'
      printf '| --- | --- | --- | --- | --- |\n'
    } > "$queue_path"
  fi
  local clean_excerpt clean_reco
  clean_excerpt=$(printf '%s' "$excerpt" | tr '\n' ' ' | tr '|' '/' | awk '{ sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print }')
  clean_reco=$(printf '%s' "$recommendation" | tr '\n' ' ' | tr '|' '/' | awk '{ sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print }')
  [[ -n "$clean_excerpt" ]] || clean_excerpt='(no excerpt captured)'
  [[ -n "$clean_reco" ]] || clean_reco='triage soft-block; dispatch the blocker fix to an idle agent or release the assignment'
  printf '| %s | %s | %s | %s | %s |\n' \
    "$ts" "$agent" "$ticket" "$clean_excerpt" "$clean_reco" >> "$queue_path"
}

# Look up `<agent>` in assignments.json and emit the ticket number (issue or
# ticket field). Empty when the agent row or the file is missing. Pure
# read; no jq is fine because the schema is simple but using jq stays
# consistent with the rest of the toolkit.
agent_softblock__ticket_for_agent() {
  local assignments_file=${1:?usage: agent_softblock__ticket_for_agent <assignments_file> <agent>}
  local agent=${2:?usage: agent_softblock__ticket_for_agent <assignments_file> <agent>}
  [[ -s "$assignments_file" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg agent "$agent" '
    (.[$agent].issue // .[$agent].ticket // "")
    | tostring
    | select(. != "" and . != "null")
  ' "$assignments_file" 2>/dev/null || true
}

# Run one rebalance step. Per-cycle entry point for orch_loop.
#   $1 project (used as audit context)
#   $2 state_dir (where assignments.json + intervention_queue.md live)
# Behaviour:
#   - iterate `agent_inventory_entries` (must be sourced by the caller),
#   - classify each agent's pane,
#   - count idle vs soft-blocked agents (only counts agents that hold a
#     row in assignments.json for soft_blocked; idle is counted on all
#     panes regardless of assignment because an idle pane with no
#     assignment is exactly the rebalance target),
#   - when idle > 0 AND soft-blocked > 0, emit one REBALANCE_REQUIRED
#     audit row and append one intervention_queue.md row per
#     soft-blocked agent.
# Returns 0 always; failure modes (missing audit, missing inventory) are
# logged via the caller-provided audit hook.
agent_softblock_run_rebalance_step() {
  local project=${1:?usage: agent_softblock_run_rebalance_step <project> <state_dir>}
  local state_dir=${2:?usage: agent_softblock_run_rebalance_step <project> <state_dir>}

  if [[ "${ORCH_SOFTBLOCK_DISABLED:-0}" == "1" ]]; then
    return 0
  fi
  if ! declare -F agent_inventory_entries >/dev/null 2>&1; then
    return 0
  fi
  if ! declare -F audit >/dev/null 2>&1; then
    return 0
  fi

  local assignments_file="$state_dir/assignments.json"
  local queue_path="$state_dir/intervention_queue.md"

  local idle_agents=()
  local softblocked_rows=()
  local working_agents=()
  local label pane workdir class ticket excerpt

  while IFS='|' read -r label pane workdir; do
    [[ -n "$label" ]] || continue
    class=$(classify_agent_pane "$pane" 2>/dev/null || printf 'idle\n')
    case "$class" in
      soft_blocked)
        ticket=$(agent_softblock__ticket_for_agent "$assignments_file" "$label")
        [[ -n "$ticket" ]] || ticket="(unassigned)"
        local body
        body=$(agent_softblock_capture_pane "$pane")
        excerpt=$(agent_softblock_match_excerpt "$body")
        softblocked_rows+=("$label|$ticket|$excerpt")
        ;;
      working)
        working_agents+=("$label")
        ;;
      idle|*)
        idle_agents+=("$label")
        ;;
    esac
  done < <(agent_inventory_entries 2>/dev/null || true)

  local idle_count=${#idle_agents[@]}
  local soft_count=${#softblocked_rows[@]}
  local working_count=${#working_agents[@]}

  if (( soft_count == 0 )); then
    audit_action ORCH_LOOP_SOFTBLOCK_SCAN \
      project="$project" \
      idle="$idle_count" \
      soft_blocked=0 \
      working="$working_count" \
      decision=no_softblock
    return 0
  fi
  if (( idle_count == 0 )); then
    audit_action ORCH_LOOP_SOFTBLOCK_SCAN \
      project="$project" \
      idle=0 \
      soft_blocked="$soft_count" \
      working="$working_count" \
      decision=no_idle_capacity
    return 0
  fi

  local row agent ticket
  local idle_csv
  idle_csv=$(IFS=,; printf '%s' "${idle_agents[*]}")
  local soft_csv_parts=()
  for row in "${softblocked_rows[@]}"; do
    agent=${row%%|*}
    local rest=${row#*|}
    ticket=${rest%%|*}
    soft_csv_parts+=("${agent}#${ticket}")
  done
  local soft_csv
  soft_csv=$(IFS=,; printf '%s' "${soft_csv_parts[*]}")

  audit_action ORCH_LOOP_REBALANCE_REQUIRED \
    project="$project" \
    idle_count="$idle_count" \
    soft_blocked_count="$soft_count" \
    idle_agents="$idle_csv" \
    soft_blocked="$soft_csv" \
    reason=soft_blocked_capacity_waste

  for row in "${softblocked_rows[@]}"; do
    agent=${row%%|*}
    local rest=${row#*|}
    ticket=${rest%%|*}
    excerpt=${rest#*|}
    agent_softblock_append_intervention \
      "$queue_path" \
      "$agent" \
      "$ticket" \
      "$excerpt" \
      "dispatch the blocker fix to one of: $idle_csv, or release agent=$agent on ticket=$ticket"
    audit_action ORCH_LOOP_OPERATOR_INTERVENTION_REQUIRED \
      project="$project" \
      agent="$agent" \
      ticket="$ticket" \
      reason=soft_blocked_capacity_waste \
      idle_pool="$idle_csv" \
      queue_path="$queue_path"
  done
  return 0
}
