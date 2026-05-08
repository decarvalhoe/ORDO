#!/usr/bin/env bash
# lib/prompt_unblock_policy.sh — orchestrator-side consumer + policy
# library for the universal interactive prompt detector (#349). This is
# the consumer ticket #350 ships: it converts each
# `ordo.prompt_detector.v1` signal into a lane state the orchestrator
# can act on, posts a concise operator-action queue, and rate-limits
# alerts so a single stuck pane cannot spam the loop.
#
# Design contract:
#   - Project-agnostic. No Claude-CLI-specific keywords; no Figma-only
#     hardcoding (Figma travels through the same generic path as any
#     other MCP/connector).
#   - **Profile-gated by default**: the default action for every signal
#     is `audit-only`. Live grants require an explicit per-provider
#     entry in the policy file AND an opt-in flag at consume time. A
#     plain `audit-only` profile NEVER answers a prompt — it logs the
#     signal and emits a `needs_operator_permission` lane state so
#     capacity rollups can stop counting that pane as healthy.
#   - Rate-limited: each (pane, matcher_id) pair emits at most one
#     alert per cooldown window (`ORCH_PROMPT_UNBLOCK_ALERT_COOLDOWN_SEC`,
#     default 600s). The cooldown index lives next to the signals
#     ledger so it survives orchestrator restarts.
#   - Read-only over external systems. The consumer NEVER calls
#     `tmux send-keys` itself; live-grant delegates to the existing
#     `auto_unblock` helper in `lib/tmux_helpers.sh`, which already
#     gates against dangerous commands. This keeps the consumer
#     auditable and the danger guard in one place.
#
# Public functions:
#   prompt_unblock_policy_path                 — resolve policy file
#   prompt_unblock_lane_state_path             — JSON-Lines lane states
#   prompt_unblock_operator_actions_path       — TSV operator queue
#   prompt_unblock_alert_index_path            — cooldown index
#   prompt_unblock_signals_ledger_path         — defers to detector lib
#   prompt_unblock_load_policy                 — emit policy lines
#   prompt_unblock_lookup_action <tool> <prov> — resolve policy action
#   prompt_unblock_lookup_cooldown <tool> <prov>
#   prompt_unblock_safest_next_action <tool> <prov> <cmd> <pane> <cwd>
#   prompt_unblock_classify_signal <signal>    — emit one lane state
#   prompt_unblock_should_emit_alert <pane> <matcher_id>
#   prompt_unblock_record_alert      <pane> <matcher_id>
#   prompt_unblock_consume_signals_text <text> [--live-grant]
#       Walk a JSON-Lines block of detector signals and produce one
#       lane state per signal (deduped by `(pane, matcher_id, cooldown)`).
#       Persists the lane states + operator-action queue to disk and
#       prints lane states to stdout (one per line) so callers can pipe.
#
# Exit codes used by the CLI wrapper (scripts/prompt_unblock_consume.sh):
#   0  consume completed (zero or more lane states emitted).
#   2  invalid args.
#   3  jq missing (the consumer needs structured output).
#   4  policy file path provided but unreadable.

if [[ -n "${ORCH_PROMPT_UNBLOCK_LIB_LOADED:-}" ]]; then
  return 0
fi
ORCH_PROMPT_UNBLOCK_LIB_LOADED=1

: "${ORCH_PROMPT_UNBLOCK_ALERT_COOLDOWN_SEC:=600}"
: "${ORCH_PROMPT_UNBLOCK_DEFAULT_ACTION:=audit-only}"
: "${ORCH_PROMPT_UNBLOCK_LIVE_GRANT_ENABLED:=0}"

_orch_prompt_unblock_state_root() {
  local base="${ORCH_PROMPT_DETECTOR_LEDGER:-${ORCH_STATE_BASE:-${XDG_DATA_HOME:-/root/.local/share}/orch-state}/_prompt_signals/signals.jsonl}"
  printf '%s\n' "$(dirname "$base")"
}

prompt_unblock_signals_ledger_path() {
  printf '%s\n' "${ORCH_PROMPT_DETECTOR_LEDGER:-${ORCH_STATE_BASE:-${XDG_DATA_HOME:-/root/.local/share}/orch-state}/_prompt_signals/signals.jsonl}"
}

prompt_unblock_lane_state_path() {
  printf '%s/lane_states.jsonl\n' "$(_orch_prompt_unblock_state_root)"
}

prompt_unblock_operator_actions_path() {
  printf '%s/operator_actions.tsv\n' "$(_orch_prompt_unblock_state_root)"
}

prompt_unblock_alert_index_path() {
  printf '%s/alerts.idx\n' "$(_orch_prompt_unblock_state_root)"
}

prompt_unblock_policy_path() {
  if [[ -n "${ORCH_PROMPT_UNBLOCK_POLICY_FILE:-}" ]]; then
    printf '%s\n' "${ORCH_PROMPT_UNBLOCK_POLICY_FILE}"
  else
    printf '%s/policy.tsv\n' "$(_orch_prompt_unblock_state_root)"
  fi
}

# Policy file format — pipe-separated, one entry per line:
#   tool|provider|action|cooldown_sec
#
# Pipe (`|`) is used instead of TAB because bash's `read` collapses
# consecutive whitespace IFS characters (tab is whitespace) — empty
# `provider` fields between two tabs would silently fold into the
# previous field. Pipe is non-whitespace and reads positionally.
#
# Lookup precedence (highest first):
#   1. exact (tool, provider) match
#   2. tool match with empty provider (catch-all for that tool family)
#   3. ORCH_PROMPT_UNBLOCK_DEFAULT_ACTION (env, default audit-only)
#
# Recognized actions:
#   audit-only   record signal, emit lane=needs_operator_permission;
#                NEVER answer the prompt. (default)
#   escalate     emit lane=blocked_external (long-running block; expects
#                operator/CI intervention).
#   live-grant   emit lane=auto_unblocked AND, if the consumer was
#                invoked with --live-grant AND auto_unblock is wired,
#                delegate the keystrokes to lib/tmux_helpers.sh
#                auto_unblock (which guards against dangerous patterns).
#                Without --live-grant the policy stays advisory and the
#                lane drops to needs_operator_permission.
#
# Lines starting with `#` are comments. Empty fields are valid (e.g. a
# policy that fires for every provider of a given tool family).
prompt_unblock_load_policy() {
  local path
  path=$(prompt_unblock_policy_path)
  [[ -s "$path" ]] || return 0
  local raw tool provider action cooldown
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    [[ -n "$raw" ]] || continue
    [[ "$raw" =~ ^[[:space:]]*# ]] && continue
    IFS='|' read -r tool provider action cooldown <<< "$raw"
    [[ -n "$tool$provider$action" ]] || continue
    printf '%s|%s|%s|%s\n' "$tool" "$provider" "$action" "${cooldown:-${ORCH_PROMPT_UNBLOCK_ALERT_COOLDOWN_SEC}}"
  done < "$path"
}

# Resolve the policy action for a (tool, provider) pair. Falls back to
# ORCH_PROMPT_UNBLOCK_DEFAULT_ACTION when nothing matches.
prompt_unblock_lookup_action() {
  local want_tool=${1-}
  local want_provider=${2-}
  local tool provider action cooldown
  local generic_action=""
  while IFS='|' read -r tool provider action cooldown; do
    [[ -n "$tool" || -n "$provider" ]] || continue
    if [[ "$tool" == "$want_tool" && "$provider" == "$want_provider" ]]; then
      printf '%s\n' "$action"
      return 0
    fi
    if [[ "$tool" == "$want_tool" && -z "$provider" && -z "$generic_action" ]]; then
      generic_action="$action"
    fi
  done < <(prompt_unblock_load_policy)
  if [[ -n "$generic_action" ]]; then
    printf '%s\n' "$generic_action"
    return 0
  fi
  printf '%s\n' "$ORCH_PROMPT_UNBLOCK_DEFAULT_ACTION"
}

# Resolve the cooldown (seconds) for a (tool, provider) pair. Falls
# back to ORCH_PROMPT_UNBLOCK_ALERT_COOLDOWN_SEC.
prompt_unblock_lookup_cooldown() {
  local want_tool=${1-}
  local want_provider=${2-}
  local tool provider action cooldown
  local generic_cooldown=""
  while IFS='|' read -r tool provider action cooldown; do
    [[ -n "$tool" || -n "$provider" ]] || continue
    if [[ "$tool" == "$want_tool" && "$provider" == "$want_provider" ]]; then
      printf '%s\n' "${cooldown:-$ORCH_PROMPT_UNBLOCK_ALERT_COOLDOWN_SEC}"
      return 0
    fi
    if [[ "$tool" == "$want_tool" && -z "$provider" && -z "$generic_cooldown" ]]; then
      generic_cooldown="${cooldown:-$ORCH_PROMPT_UNBLOCK_ALERT_COOLDOWN_SEC}"
    fi
  done < <(prompt_unblock_load_policy)
  if [[ -n "$generic_cooldown" ]]; then
    printf '%s\n' "$generic_cooldown"
    return 0
  fi
  printf '%s\n' "$ORCH_PROMPT_UNBLOCK_ALERT_COOLDOWN_SEC"
}

# Build a concise operator-facing copy describing the safest next
# action. Universal: takes tool/provider/command and shapes the copy
# without baking in any specific provider's UI text.
prompt_unblock_safest_next_action() {
  local tool=${1-}
  local provider=${2-}
  local command=${3-}
  local pane=${4-}
  local cwd=${5-}
  local subject="$tool"
  [[ -n "$provider" ]] && subject="$tool/$provider"
  local payload="$subject"
  [[ -n "$command" ]] && payload="$payload $command"
  local where=""
  [[ -n "$pane" ]] && where=" pane=$pane"
  [[ -n "$cwd" ]] && where="$where cwd=$cwd"
  printf 'Operator: review %s grant%s, then either approve in pane or extend prompt-unblock policy for this provider.\n' \
    "$payload" "$where"
}

# Lane state mapping. Returns the lane name; live-grant collapses to
# needs_operator_permission unless live_grant_enabled is 1, so a stale
# policy entry cannot fire grants by accident.
_prompt_unblock_action_to_lane() {
  local action=$1
  local live_grant_enabled=${2:-0}
  case "$action" in
    audit-only)  printf 'needs_operator_permission\n' ;;
    escalate)    printf 'blocked_external\n' ;;
    live-grant)
      if [[ "$live_grant_enabled" == "1" ]]; then
        printf 'auto_unblocked\n'
      else
        printf 'needs_operator_permission\n'
      fi
      ;;
    *)           printf 'needs_operator_permission\n' ;;
  esac
}

# Rate-limit primitive — returns 0 (true) when an alert should fire,
# 1 (false) when the cooldown is still active. The index is a flat
# TSV: pane<TAB>matcher_id<TAB>last_emitted_epoch_sec.
prompt_unblock_should_emit_alert() {
  local pane=${1-}
  local matcher_id=${2-}
  local cooldown=${3:-$ORCH_PROMPT_UNBLOCK_ALERT_COOLDOWN_SEC}
  [[ -n "$pane$matcher_id" ]] || return 0
  local idx
  idx=$(prompt_unblock_alert_index_path)
  [[ -s "$idx" ]] || return 0
  local now last_pane last_matcher last_ts
  now=$(date -u +%s)
  while IFS=$'\t' read -r last_pane last_matcher last_ts; do
    [[ "$last_pane" == "$pane" && "$last_matcher" == "$matcher_id" ]] || continue
    [[ "$last_ts" =~ ^[0-9]+$ ]] || continue
    if (( now - last_ts < cooldown )); then
      return 1
    fi
  done < "$idx"
  return 0
}

# Persist a (pane, matcher_id, now) entry into the alert index. Earlier
# entries for the same pair are collapsed so the index stays bounded.
prompt_unblock_record_alert() {
  local pane=${1-}
  local matcher_id=${2-}
  [[ -n "$pane$matcher_id" ]] || return 0
  local idx tmp now
  idx=$(prompt_unblock_alert_index_path)
  tmp="${idx}.tmp.$$"
  now=$(date -u +%s)
  mkdir -p "$(dirname "$idx")"
  if [[ -s "$idx" ]]; then
    awk -F'\t' -v p="$pane" -v m="$matcher_id" \
      '$1 != p || $2 != m { print }' "$idx" > "$tmp" || true
  else
    : > "$tmp"
  fi
  printf '%s\t%s\t%s\n' "$pane" "$matcher_id" "$now" >> "$tmp"
  mv "$tmp" "$idx"
}

# Classify a single detector signal (one JSON object on stdin or the
# first arg) and emit one lane state JSON object on stdout. Returns
# the numeric lane code via $PROMPT_UNBLOCK_LAST_LANE for convenience.
prompt_unblock_classify_signal() {
  local signal=${1-}
  if [[ -z "$signal" ]]; then
    signal=$(cat)
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'prompt_unblock_classify_signal: jq required\n' >&2
    return 2
  fi
  local tool provider command pane cwd matcher_id session agent project ticket suggested_hint linked_issue linked_pr matched_text
  tool=$(jq -r '.tool // ""' <<< "$signal")
  provider=$(jq -r '.provider // ""' <<< "$signal")
  command=$(jq -r '.command // ""' <<< "$signal")
  pane=$(jq -r '.pane // ""' <<< "$signal")
  cwd=$(jq -r '.cwd // ""' <<< "$signal")
  matcher_id=$(jq -r '.matcher_id // ""' <<< "$signal")
  session=$(jq -r '.session // ""' <<< "$signal")
  agent=$(jq -r '.agent // ""' <<< "$signal")
  project=$(jq -r '.project // ""' <<< "$signal")
  ticket=$(jq -r '.ticket // ""' <<< "$signal")
  suggested_hint=$(jq -r '.suggested_option_hint // ""' <<< "$signal")
  linked_issue=$(jq -r '.linked_issue // empty' <<< "$signal")
  linked_pr=$(jq -r '.linked_pr // empty' <<< "$signal")
  matched_text=$(jq -r '.matched_text // ""' <<< "$signal")

  local action lane cooldown safest live_enabled
  action=$(prompt_unblock_lookup_action "$tool" "$provider")
  cooldown=$(prompt_unblock_lookup_cooldown "$tool" "$provider")
  live_enabled="${ORCH_PROMPT_UNBLOCK_LIVE_GRANT_ENABLED:-0}"
  lane=$(_prompt_unblock_action_to_lane "$action" "$live_enabled")
  safest=$(prompt_unblock_safest_next_action "$tool" "$provider" "$command" "$pane" "$cwd")

  local alert_eligible="false"
  if prompt_unblock_should_emit_alert "$pane" "$matcher_id" "$cooldown"; then
    alert_eligible="true"
  fi

  local recorded_at
  recorded_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

  jq -nc \
    --arg schema "ordo.prompt_unblock_lane_state.v1" \
    --arg recorded_at "$recorded_at" \
    --arg pane "$pane" \
    --arg session "$session" \
    --arg agent "$agent" \
    --arg project "$project" \
    --arg ticket "$ticket" \
    --arg lane "$lane" \
    --arg tool "$tool" \
    --arg provider "$provider" \
    --arg command "$command" \
    --arg cwd "$cwd" \
    --arg matcher_id "$matcher_id" \
    --arg policy_action "$action" \
    --argjson alert_eligible "$alert_eligible" \
    --arg cooldown_sec "$cooldown" \
    --arg suggested_hint "$suggested_hint" \
    --arg matched_text "$matched_text" \
    --arg linked_issue "$linked_issue" \
    --arg linked_pr "$linked_pr" \
    --arg safest_next_action "$safest" \
    --argjson source_signal "$signal" \
    '{
       schema: $schema,
       recorded_at: $recorded_at,
       lane: $lane,
       pane: (if $pane == "" then null else $pane end),
       session: (if $session == "" then null else $session end),
       agent: (if $agent == "" then null else $agent end),
       project: (if $project == "" then null else $project end),
       ticket: (if $ticket == "" then null else $ticket end),
       tool: (if $tool == "" then null else $tool end),
       provider: (if $provider == "" then null else $provider end),
       command: (if $command == "" then null else $command end),
       cwd: (if $cwd == "" then null else $cwd end),
       matcher_id: $matcher_id,
       policy_action: $policy_action,
       alert_eligible: $alert_eligible,
       cooldown_sec: ($cooldown_sec | tonumber? // 600),
       suggested_option_hint: (if $suggested_hint == "" then null else $suggested_hint end),
       matched_text: (if $matched_text == "" then null else $matched_text end),
       linked_issue: (if $linked_issue == "" then null else ($linked_issue | tonumber? // $linked_issue) end),
       linked_pr: (if $linked_pr == "" then null else ($linked_pr | tonumber? // $linked_pr) end),
       safest_next_action: $safest_next_action,
       source_signal: $source_signal
     }'
  # shellcheck disable=SC2034  # consumed by callers after sourcing
  PROMPT_UNBLOCK_LAST_LANE="$lane"
}

# Format the operator-action TSV row. Columns:
#   pane<TAB>agent<TAB>repo_workdir<TAB>requested_tool<TAB>safest_next_action
prompt_unblock_format_operator_row() {
  local lane_state=${1-}
  local pane agent cwd tool provider safest
  pane=$(jq -r '.pane // ""' <<< "$lane_state")
  agent=$(jq -r '.agent // ""' <<< "$lane_state")
  cwd=$(jq -r '.cwd // ""' <<< "$lane_state")
  tool=$(jq -r '.tool // ""' <<< "$lane_state")
  provider=$(jq -r '.provider // ""' <<< "$lane_state")
  safest=$(jq -r '.safest_next_action // ""' <<< "$lane_state")
  local subject="$tool"
  [[ -n "$provider" ]] && subject="$tool/$provider"
  printf '%s\t%s\t%s\t%s\t%s\n' "${pane:-?}" "${agent:-?}" "${cwd:-?}" "${subject:-?}" "${safest:-?}"
}

# Walk a JSON-Lines block of detector signals and emit one lane state
# per signal, deduped by (pane, matcher_id) inside this batch and
# rate-limited against the persisted alert index. Persists the lane
# states + operator-action queue to disk; prints lane states to stdout.
#
# Args after the JSON-Lines block (passed via $1):
#   --live-grant   Allow `live-grant` policy entries to fire. Without
#                  this flag a `live-grant` policy is downgraded to
#                  `needs_operator_permission` so a stale policy entry
#                  cannot answer prompts unattended.
prompt_unblock_consume_signals_text() {
  local payload=${1-}
  shift || true
  local live_grant_arg=0
  local arg
  for arg in "$@"; do
    case "$arg" in
      --live-grant) live_grant_arg=1 ;;
      *) ;;
    esac
  done
  if [[ "$live_grant_arg" -eq 1 ]]; then
    export ORCH_PROMPT_UNBLOCK_LIVE_GRANT_ENABLED=1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    printf 'prompt_unblock_consume_signals_text: jq required\n' >&2
    return 2
  fi

  local lane_path action_path
  lane_path=$(prompt_unblock_lane_state_path)
  action_path=$(prompt_unblock_operator_actions_path)
  mkdir -p "$(dirname "$lane_path")"
  : > "$lane_path"
  : > "$action_path"
  printf 'pane\tagent\trepo_workdir\trequested_tool\tsafest_next_action\n' >> "$action_path"

  PROMPT_UNBLOCK_LAST_LANE_COUNT=0
  PROMPT_UNBLOCK_LAST_ALERT_COUNT=0

  declare -A seen_in_batch=()
  local signal lane_state pane matcher dedupe_key alert_eligible

  while IFS= read -r signal || [[ -n "$signal" ]]; do
    [[ -n "$signal" ]] || continue
    pane=$(jq -r '.pane // ""' <<< "$signal" 2>/dev/null || printf '')
    matcher=$(jq -r '.matcher_id // ""' <<< "$signal" 2>/dev/null || printf '')
    dedupe_key="${pane}::${matcher}"
    if [[ -n "$dedupe_key" && -n "${seen_in_batch[$dedupe_key]:-}" ]]; then
      continue
    fi
    seen_in_batch[$dedupe_key]=1

    lane_state=$(prompt_unblock_classify_signal "$signal")
    [[ -n "$lane_state" ]] || continue

    alert_eligible=$(jq -r '.alert_eligible // false' <<< "$lane_state")
    if [[ "$alert_eligible" == "true" ]]; then
      prompt_unblock_record_alert "$pane" "$matcher"
      PROMPT_UNBLOCK_LAST_ALERT_COUNT=$((PROMPT_UNBLOCK_LAST_ALERT_COUNT + 1))
    fi

    printf '%s\n' "$lane_state" >> "$lane_path"
    prompt_unblock_format_operator_row "$lane_state" >> "$action_path"
    printf '%s\n' "$lane_state"
    PROMPT_UNBLOCK_LAST_LANE_COUNT=$((PROMPT_UNBLOCK_LAST_LANE_COUNT + 1))
  done <<< "$payload"
}
