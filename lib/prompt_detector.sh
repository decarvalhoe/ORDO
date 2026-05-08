#!/usr/bin/env bash
# lib/prompt_detector.sh — universal interactive-prompt detector for ORDO
# fleet panes (#349, parent epic #348).
#
# Sourced by scripts/prompt_detector_scan.sh and any future consumer
# (#350). Read-only: this library NEVER grants permissions, NEVER answers
# prompts. It only inspects pane capture text and emits structured signals
# the orchestrator can act on.
#
# Design contract:
#   - Project-agnostic. No Claude-CLI-specific keywords; no Figma-specific
#     hardcoding except as one matcher in the default catalog.
#   - Configurable. Operator can extend the catalog via
#     ORCH_PROMPT_MATCHERS_FILE without editing this lib.
#   - Stable JSON schema (`ordo.prompt_detector.v1`) consumed by #350 and
#     by portfolio/project status commands.
#   - Pure-bash core (jq is required for JSON output, awk for line walking).
#     No tmux/git dependency in the lib itself; the consumer wires those in.

# --- Defaults ---------------------------------------------------------------

# Each default matcher is a pipe-separated 6-tuple:
#   id|tool|provider|class|priority|regex
#
# Where:
#   id        Stable matcher identifier (snake-case).
#   tool      Generic tool family (e.g. mcp, browser-connector, auto-mode).
#   provider  Concrete provider when known (e.g. claude.ai-figma,
#             chrome-devtools); empty when not provider-specific.
#   class     Prompt class for the orchestrator router (e.g.
#             allow-deny-confirmation, auto-mode-denial,
#             generic-confirmation).
#   priority  Match priority. Higher wins when multiple matchers apply to
#             the same capture.
#   regex     ERE pattern. Must match a single canonical line of the
#             prompt.
#
# Why ERE: bash's `=~` uses ERE; awk's `~` uses ERE; both consume the same
# pattern without quoting tricks.
prompt_detector_default_matchers() {
  cat <<'EOF'
figma-mcp-confirm|mcp|claude.ai-figma|allow-deny-confirmation|110|Do you want to proceed\?.*claude\.ai Figma
mcp-allow-deny-confirm|mcp||allow-deny-confirmation|90|Do you want to proceed\?.*1\.[[:space:]]*Yes.*2\.[[:space:]]*Yes-don't-ask-again
chrome-devtools-connect|browser-connector|chrome-devtools|browser-connector-confirmation|105|Allow connection.*chrome[-[:space:]]*devtools
browser-connector-confirm|browser-connector||browser-connector-confirmation|95|Allow connection (to|from) (browser|chromium|firefox|webkit)
auto-mode-denial|auto-mode||auto-mode-denial|100|auto-mode (denied|disabled|requires confirmation)
generic-confirmation|generic||generic-confirmation|10|^[[:space:]]*\[?(y|Y)/(n|N)\]?[[:space:]]*$|^[[:space:]]*Allow .*Deny [[:space:]]*$|^[[:space:]]*Confirm \(y/n\)
EOF
}

# Effective matcher catalog = defaults + ORCH_PROMPT_MATCHERS_FILE entries
# (one matcher per non-blank, non-`#` line; same 6-tuple format).
prompt_detector_matchers() {
  prompt_detector_default_matchers
  if [[ -n "${ORCH_PROMPT_MATCHERS_FILE:-}" && -s "${ORCH_PROMPT_MATCHERS_FILE}" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      printf '%s\n' "$line"
    done < "${ORCH_PROMPT_MATCHERS_FILE}"
  fi
}

# Ledger path. Persistence sits under $ORCH_STATE_BASE/_prompt_signals/
# rather than under any single project, since the detector is fleet-wide.
# Operators can override with ORCH_PROMPT_DETECTOR_LEDGER.
prompt_detector_record_path() {
  local base
  base="${ORCH_PROMPT_DETECTOR_LEDGER:-${ORCH_STATE_BASE:-${XDG_DATA_HOME:-/root/.local/share}/orch-state}/_prompt_signals/signals.jsonl}"
  printf '%s\n' "$base"
}

# Heuristic: try to parse a tool subcommand out of a Figma-style prompt
# line. Examples consumed:
#   "for claude.ai Figma - get_metadata commands in /repos/..."
#   "for claude.ai Figma - whoami commands"
# Returns empty when the prompt does not carry a command hint.
_prompt_detector_extract_command() {
  local line=$1
  printf '%s' "$line" \
    | sed -nE 's/.*[Ff]or[[:space:]]+[A-Za-z0-9._-]+([[:space:]]+[A-Za-z0-9._-]+)?[[:space:]]+-[[:space:]]+([A-Za-z0-9_-]+)[[:space:]]+commands.*/\2/p' \
    | head -n 1
}

# Heuristic: extract a workdir hint when the prompt mentions one inline
# (Claude-CLI prompts use "in /path/to/repo"). Returns empty otherwise.
_prompt_detector_extract_inline_cwd() {
  local line=$1
  printf '%s' "$line" \
    | sed -nE 's|.*[Ii]n[[:space:]]+(/[A-Za-z0-9_./-]+).*|\1|p' \
    | head -n 1
}

# Heuristic: pick a sensible default option hint for a matched class.
# Operators with explicit unblock policy (#350) override this; the lib
# only proposes a hint, never executes it.
_prompt_detector_suggest_option() {
  local class=$1
  case "$class" in
    allow-deny-confirmation)
      printf 'review-required (likely 1.Yes for one-shot, 2.Yes-dont-ask-again for sticky grant)'
      ;;
    browser-connector-confirmation)
      printf 'review-required (verify origin before granting)'
      ;;
    auto-mode-denial)
      printf 'review-required (re-dispatch with explicit grant or interactive operator action)'
      ;;
    generic-confirmation)
      printf 'review-required (operator must confirm)'
      ;;
    *)
      printf 'review-required'
      ;;
  esac
}

# JSON-escape a string for embedding in a `--arg` value when jq is
# available, or for use in the fallback emitter when it is not.
_prompt_detector_jq_escape() {
  printf '%s' "$1" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
    | tr -d '\r' \
    | awk 'BEGIN{first=1} { if (!first) printf "\\n"; first=0; printf "%s", $0 }'
}

# Scan a capture string and emit zero or more JSON records (one per line).
#
# Usage:
#   prompt_detector_scan_text <capture-text> [meta-key=value ...]
#
# Recognized meta keys (all optional):
#   session, pane, cwd, agent, project, ticket,
#   linked_issue, linked_pr, captured_at, prompt_age_sec
#
# Returns the number of records emitted via $PROMPT_DETECTOR_LAST_COUNT.
prompt_detector_scan_text() {
  local capture=${1-}
  shift || true

  PROMPT_DETECTOR_LAST_COUNT=0
  local meta_session="" meta_pane="" meta_cwd="" meta_agent="" meta_project=""
  local meta_ticket="" meta_linked_issue="" meta_linked_pr=""
  local meta_captured_at="" meta_prompt_age=""

  local arg key val
  for arg in "$@"; do
    key="${arg%%=*}"
    val="${arg#*=}"
    case "$key" in
      session) meta_session=$val ;;
      pane) meta_pane=$val ;;
      cwd) meta_cwd=$val ;;
      agent) meta_agent=$val ;;
      project) meta_project=$val ;;
      ticket) meta_ticket=$val ;;
      linked_issue) meta_linked_issue=$val ;;
      linked_pr) meta_linked_pr=$val ;;
      captured_at) meta_captured_at=$val ;;
      prompt_age_sec) meta_prompt_age=$val ;;
      *) ;;  # ignore unknown keys to keep the lib forward-compatible
    esac
  done

  [[ -n "$capture" ]] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    printf 'prompt_detector_scan_text: jq is required for structured output\n' >&2
    return 2
  fi

  if [[ -z "$meta_captured_at" ]]; then
    meta_captured_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  fi

  # Per-pane dedupe: track which (matcher_id, matched-line) pairs we have
  # already emitted in this scan so the same multi-line capture does not
  # produce N copies of the same alert.
  local -A seen_pairs=()

  # Track best matcher per matched line so generic patterns lose to
  # specific patterns when both match the same line.
  local -A best_matcher_for_line=()
  local -A best_priority_for_line=()

  local matcher_line matcher_id tool provider class priority regex
  local cap_line line_idx=0

  # First pass: walk every capture line against every matcher and pick
  # the highest-priority match per line.
  while IFS= read -r cap_line || [[ -n "$cap_line" ]]; do
    line_idx=$((line_idx + 1))
    [[ -n "$cap_line" ]] || continue
    while IFS= read -r matcher_line || [[ -n "$matcher_line" ]]; do
      [[ -n "$matcher_line" ]] || continue
      [[ "$matcher_line" =~ ^[[:space:]]*# ]] && continue
      IFS='|' read -r matcher_id tool provider class priority regex <<< "$matcher_line"
      [[ -n "$matcher_id" && -n "$regex" ]] || continue
      [[ "$priority" =~ ^[0-9]+$ ]] || priority=0
      if printf '%s' "$cap_line" | grep -Eiq -- "$regex"; then
        local current_best=${best_priority_for_line[$line_idx]:-}
        if [[ -z "$current_best" || "$priority" -gt "$current_best" ]]; then
          best_matcher_for_line[$line_idx]="$matcher_id|$tool|$provider|$class|$priority|$regex"
          best_priority_for_line[$line_idx]="$priority"
        fi
      fi
    done < <(prompt_detector_matchers)
  done <<< "$capture"

  # Second pass: emit one record per winning line, with dedupe.
  line_idx=0
  while IFS= read -r cap_line || [[ -n "$cap_line" ]]; do
    line_idx=$((line_idx + 1))
    local winner=${best_matcher_for_line[$line_idx]:-}
    [[ -n "$winner" ]] || continue
    IFS='|' read -r matcher_id tool provider class priority regex <<< "$winner"

    local dedupe_key="${matcher_id}::${cap_line}"
    [[ -n "${seen_pairs[$dedupe_key]:-}" ]] && continue
    seen_pairs[$dedupe_key]=1

    local detected_command detected_inline_cwd suggested_option
    detected_command=$(_prompt_detector_extract_command "$cap_line")
    detected_inline_cwd=$(_prompt_detector_extract_inline_cwd "$cap_line")
    suggested_option=$(_prompt_detector_suggest_option "$class")

    local effective_cwd=$meta_cwd
    if [[ -z "$effective_cwd" && -n "$detected_inline_cwd" ]]; then
      effective_cwd=$detected_inline_cwd
    fi

    jq -nc \
      --arg schema "ordo.prompt_detector.v1" \
      --arg detected_at "$meta_captured_at" \
      --arg session "$meta_session" \
      --arg pane "$meta_pane" \
      --arg cwd "$effective_cwd" \
      --arg agent "$meta_agent" \
      --arg project "$meta_project" \
      --arg ticket "$meta_ticket" \
      --arg tool "$tool" \
      --arg provider "$provider" \
      --arg command "$detected_command" \
      --arg prompt_class "$class" \
      --arg matcher_id "$matcher_id" \
      --arg matched_text "$cap_line" \
      --arg suggested_option "$suggested_option" \
      --arg prompt_age_sec "$meta_prompt_age" \
      --arg linked_issue "$meta_linked_issue" \
      --arg linked_pr "$meta_linked_pr" \
      '{
         schema: $schema,
         detected_at: $detected_at,
         session: (if $session == "" then null else $session end),
         pane: (if $pane == "" then null else $pane end),
         cwd: (if $cwd == "" then null else $cwd end),
         agent: (if $agent == "" then null else $agent end),
         project: (if $project == "" then null else $project end),
         ticket: (if $ticket == "" then null else $ticket end),
         tool: (if $tool == "" then null else $tool end),
         provider: (if $provider == "" then null else $provider end),
         command: (if $command == "" then null else $command end),
         prompt_class: $prompt_class,
         matcher_id: $matcher_id,
         matched_text: $matched_text,
         suggested_option_hint: $suggested_option,
         prompt_age_sec: (if $prompt_age_sec == "" then null else ($prompt_age_sec | tonumber? // null) end),
         linked_issue: (if $linked_issue == "" then null else ($linked_issue | tonumber? // $linked_issue) end),
         linked_pr: (if $linked_pr == "" then null else ($linked_pr | tonumber? // $linked_pr) end)
       }'
    PROMPT_DETECTOR_LAST_COUNT=$((PROMPT_DETECTOR_LAST_COUNT + 1))
  done <<< "$capture"
}

# Append a record (one JSON object on a single line) to the prompt-signals
# ledger. Creates the parent directory on first call. Idempotent: callers
# that already wrote the line (e.g. via `tee`) can skip this. The ledger is
# JSON-Lines so consumers can `jq -c '.[]'` it after assembling.
prompt_detector_persist() {
  local record=${1:?usage: prompt_detector_persist <json-record>}
  local path
  path=$(prompt_detector_record_path)
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$record" >> "$path"
}

# Assist callers that already have the matcher catalog in memory: list
# every matcher id (one per line). Useful for tests and for documenting
# the active catalog at session start.
prompt_detector_list_matcher_ids() {
  prompt_detector_matchers \
    | awk -F'|' '!/^[[:space:]]*#/ && NF >= 6 { print $1 }'
}
