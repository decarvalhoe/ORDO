#!/usr/bin/env bash
# tests/test_prompt_unblock_policy.sh — orchestrator-side consumer
# coverage for the prompt-unblock policy (#350; consumes #349 detector
# signals).
#
# Cases:
#   1. Default (no policy file) → audit-only → lane=needs_operator_permission.
#   2. Per-MCP allowlist: tool=mcp provider=claude.ai-figma → live-grant +
#      --live-grant flag → lane=auto_unblocked.
#   3. live-grant policy WITHOUT --live-grant flag → lane downgraded to
#      needs_operator_permission (a stale policy entry cannot answer
#      prompts unattended).
#   4. Generic catch-all: tool=browser-connector with empty provider
#      matches every browser-connector signal regardless of provider.
#   5. escalate policy → lane=blocked_external.
#   6. Rate-limit: same (pane, matcher_id) inside cooldown → second
#      lane state has alert_eligible=false.
#   7. Rate-limit: distinct (pane, matcher_id) pairs both fire alerts
#      (one stuck pane does not block other panes from alerting).
#   8. Dedupe: a batch with two identical signals emits one lane state
#      (first wins; second is dropped before classification).
#   9. Multiple prompt-blocked panes in one batch: capacity / dispatch
#      consumers must not count any of them as healthy busy — every
#      lane state lands in {needs_operator_permission, blocked_external,
#      auto_unblocked} (no leak into "ready"/"healthy" labels).
#   10. Operator-action queue: TSV header + one row per lane state
#       with pane, agent, repo/workdir, requested tool, safest next
#       action — no row is empty / no-op.
#   11. CLI: --ledger reads from a file; --from-stdin reads from stdin;
#       --since-last advances the cursor and a re-run yields zero new
#       lane states.
#   12. CLI: --policy <missing-file> exits 4 (policy unreadable).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/lib/prompt_unblock_policy.sh"
CLI="$ROOT/scripts/prompt_unblock_consume.sh"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

if ! command -v jq >/dev/null 2>&1; then
  fail "jq required to run this test"
fi

# Per-test isolated state dir so the cooldown index is fresh.
new_state_dir() {
  local dir="$TEST_TMP/state-$1"
  mkdir -p "$dir/_prompt_signals"
  printf '%s' "$dir"
}

# Build a v1 detector signal as one JSON line. Optional kvargs override
# defaults.
make_signal() {
  local pane="rbok-copilot:0.0"
  local matcher="figma-mcp-confirm"
  local tool="mcp"
  local provider="claude.ai-figma"
  local command="get_metadata"
  local cwd="/repos/foo"
  local agent="copilot"
  local project="ordo"
  local matched_text="Do you want to proceed? [claude.ai Figma]"
  local prompt_age_sec=""
  local arg key val
  for arg in "$@"; do
    key=${arg%%=*}
    val=${arg#*=}
    case "$key" in
      pane) pane=$val ;;
      matcher_id) matcher=$val ;;
      tool) tool=$val ;;
      provider) provider=$val ;;
      command) command=$val ;;
      cwd) cwd=$val ;;
      agent) agent=$val ;;
      project) project=$val ;;
      matched_text) matched_text=$val ;;
      prompt_age_sec) prompt_age_sec=$val ;;
    esac
  done
  jq -nc \
    --arg schema "ordo.prompt_detector.v1" \
    --arg detected_at "2026-05-08T13:00:00Z" \
    --arg pane "$pane" \
    --arg matcher_id "$matcher" \
    --arg tool "$tool" \
    --arg provider "$provider" \
    --arg command "$command" \
    --arg cwd "$cwd" \
    --arg agent "$agent" \
    --arg project "$project" \
    --arg matched_text "$matched_text" \
    --arg suggested_option_hint "review-required" \
    --arg prompt_class "allow-deny-confirmation" \
    --arg prompt_age_sec "$prompt_age_sec" \
    '{
       schema: $schema, detected_at: $detected_at,
       pane: $pane, matcher_id: $matcher_id,
       tool: $tool, provider: $provider, command: $command,
       cwd: $cwd, agent: $agent, project: $project,
       matched_text: $matched_text,
       suggested_option_hint: $suggested_option_hint,
       prompt_class: $prompt_class,
       session: null, ticket: null,
       linked_issue: null, linked_pr: null,
       prompt_age_sec: (if $prompt_age_sec == "" then null else ($prompt_age_sec | tonumber) end)
     }'
}

# Source the lib under a fresh state dir for each case.
load_lib_with_state() {
  local dir=$1
  unset ORCH_PROMPT_UNBLOCK_LIB_LOADED
  export ORCH_STATE_BASE="$dir"
  unset ORCH_PROMPT_DETECTOR_LEDGER
  unset ORCH_PROMPT_UNBLOCK_POLICY_FILE
  unset ORCH_PROMPT_UNBLOCK_LIVE_GRANT_ENABLED
  # shellcheck source=lib/prompt_unblock_policy.sh
  source "$LIB"
}

# --- 1. Default: audit-only → needs_operator_permission --------------------
state=$(new_state_dir 1)
load_lib_with_state "$state"
sig=$(make_signal pane=p1:0.0 matcher_id=figma-mcp-confirm)
out=$(prompt_unblock_consume_signals_text "$sig")
[[ -n "$out" ]] || fail "case 1: empty consume output"
lane=$(jq -r '.lane' <<< "$out")
[[ "$lane" == "needs_operator_permission" ]] || fail "case 1: expected needs_operator_permission, got $lane"
policy_action=$(jq -r '.policy_action' <<< "$out")
[[ "$policy_action" == "audit-only" ]] || fail "case 1: expected policy_action=audit-only, got $policy_action"

# --- 2. Per-MCP allowlist: live-grant + --live-grant → auto_unblocked ------
state=$(new_state_dir 2)
load_lib_with_state "$state"
mkdir -p "$state/_prompt_signals"
printf 'mcp|claude.ai-figma|live-grant|30\n' > "$state/_prompt_signals/policy.tsv"
sig=$(make_signal pane=p2:0.0 matcher_id=figma-mcp-confirm)
out=$(prompt_unblock_consume_signals_text "$sig" --live-grant)
lane=$(jq -r '.lane' <<< "$out")
[[ "$lane" == "auto_unblocked" ]] || fail "case 2: expected auto_unblocked, got $lane"

# --- 3. live-grant WITHOUT --live-grant → downgrade to audit-only-like -----
state=$(new_state_dir 3)
load_lib_with_state "$state"
mkdir -p "$state/_prompt_signals"
printf 'mcp|claude.ai-figma|live-grant|30\n' > "$state/_prompt_signals/policy.tsv"
sig=$(make_signal pane=p3:0.0 matcher_id=figma-mcp-confirm)
out=$(prompt_unblock_consume_signals_text "$sig")
lane=$(jq -r '.lane' <<< "$out")
[[ "$lane" == "needs_operator_permission" ]] || fail "case 3: live-grant without flag should downgrade, got $lane"

# --- 4. Generic catch-all: empty provider ----------------------------------
state=$(new_state_dir 4)
load_lib_with_state "$state"
mkdir -p "$state/_prompt_signals"
printf 'browser-connector||escalate|60\n' > "$state/_prompt_signals/policy.tsv"
sig=$(make_signal pane=p4:0.0 matcher_id=chrome-devtools-connect tool=browser-connector provider=chrome-devtools)
out=$(prompt_unblock_consume_signals_text "$sig")
lane=$(jq -r '.lane' <<< "$out")
[[ "$lane" == "blocked_external" ]] || fail "case 4: catch-all should give blocked_external, got $lane"

# --- 5. escalate → blocked_external ----------------------------------------
state=$(new_state_dir 5)
load_lib_with_state "$state"
mkdir -p "$state/_prompt_signals"
printf 'auto-mode||escalate|300\n' > "$state/_prompt_signals/policy.tsv"
sig=$(make_signal pane=p5:0.0 matcher_id=auto-mode-denial tool=auto-mode provider=)
out=$(prompt_unblock_consume_signals_text "$sig")
lane=$(jq -r '.lane' <<< "$out")
[[ "$lane" == "blocked_external" ]] || fail "case 5: escalate should give blocked_external, got $lane"

# --- 6. Rate-limit: same (pane, matcher_id) inside cooldown ---------------
state=$(new_state_dir 6)
load_lib_with_state "$state"
mkdir -p "$state/_prompt_signals"
printf 'mcp|claude.ai-figma|audit-only|9999\n' > "$state/_prompt_signals/policy.tsv"
sig=$(make_signal pane=p6:0.0 matcher_id=figma-mcp-confirm)
first=$(prompt_unblock_consume_signals_text "$sig")
[[ "$(jq -r '.alert_eligible' <<< "$first")" == "true" ]] \
  || fail "case 6: first alert should be eligible"
# Second invocation with a NEW signal but SAME (pane, matcher_id) — still
# inside cooldown.
second=$(prompt_unblock_consume_signals_text "$sig")
[[ "$(jq -r '.alert_eligible' <<< "$second")" == "false" ]] \
  || fail "case 6: second alert should be cooldown-suppressed (got $(jq -c . <<< "$second"))"

# --- 7. Rate-limit independence across panes -------------------------------
state=$(new_state_dir 7)
load_lib_with_state "$state"
mkdir -p "$state/_prompt_signals"
printf 'mcp|claude.ai-figma|audit-only|9999\n' > "$state/_prompt_signals/policy.tsv"
sig_a=$(make_signal pane=p7a:0.0 matcher_id=figma-mcp-confirm)
sig_b=$(make_signal pane=p7b:0.0 matcher_id=figma-mcp-confirm)
out=$(printf '%s\n%s\n' "$sig_a" "$sig_b" | (
  payload=$(cat)
  prompt_unblock_consume_signals_text "$payload"
))
eligible_count=$(jq -s '[.[] | select(.alert_eligible == true)] | length' <<< "$out")
[[ "$eligible_count" -eq 2 ]] \
  || fail "case 7: each distinct pane should fire its own alert, got $eligible_count eligible"

# --- 8. Dedupe: two identical signals → one lane state ---------------------
state=$(new_state_dir 8)
load_lib_with_state "$state"
mkdir -p "$state/_prompt_signals"
sig=$(make_signal pane=p8:0.0 matcher_id=figma-mcp-confirm)
out=$(printf '%s\n%s\n' "$sig" "$sig" | (
  payload=$(cat)
  prompt_unblock_consume_signals_text "$payload"
))
count=$(printf '%s\n' "$out" | grep -c '^{')
[[ "$count" -eq 1 ]] || fail "case 8: dedupe should collapse identical signals to one lane state, got $count"

# --- 9. Multiple blocked panes: every lane is a non-healthy state ----------
state=$(new_state_dir 9)
load_lib_with_state "$state"
mkdir -p "$state/_prompt_signals"
sig_a=$(make_signal pane=p9a:0.0 matcher_id=figma-mcp-confirm tool=mcp provider=claude.ai-figma)
sig_b=$(make_signal pane=p9b:0.0 matcher_id=chrome-devtools-connect tool=browser-connector provider=chrome-devtools)
sig_c=$(make_signal pane=p9c:0.0 matcher_id=auto-mode-denial tool=auto-mode provider=)
out=$(printf '%s\n%s\n%s\n' "$sig_a" "$sig_b" "$sig_c" | (
  payload=$(cat)
  prompt_unblock_consume_signals_text "$payload"
))
healthy_count=$(jq -s '[.[] | select(.lane == "ready" or .lane == "healthy" or .lane == "busy")] | length' <<< "$out")
[[ "$healthy_count" -eq 0 ]] \
  || fail "case 9: blocked panes must not leak into healthy/ready lanes (got $healthy_count)"
distinct_panes=$(jq -s '[.[].pane] | unique | length' <<< "$out")
[[ "$distinct_panes" -eq 3 ]] \
  || fail "case 9: each blocked pane should yield its own lane state, got $distinct_panes"

# --- 10. Operator-action queue rows ---------------------------------------
state=$(new_state_dir 10)
load_lib_with_state "$state"
mkdir -p "$state/_prompt_signals"
sig_a=$(make_signal pane=p10a:0.0 matcher_id=figma-mcp-confirm tool=mcp provider=claude.ai-figma command=get_metadata cwd=/repos/A agent=alice)
sig_b=$(make_signal pane=p10b:0.0 matcher_id=chrome-devtools-connect tool=browser-connector provider=chrome-devtools command= cwd=/repos/B agent=bob)
out=$(printf '%s\n%s\n' "$sig_a" "$sig_b" | (
  payload=$(cat)
  prompt_unblock_consume_signals_text "$payload"
))
actions_path=$(prompt_unblock_operator_actions_path)
[[ -s "$actions_path" ]] || fail "case 10: operator actions TSV should be persisted"
header=$(head -n 1 "$actions_path")
[[ "$header" == $'pane\tagent\trepo_workdir\trequested_tool\tsafest_next_action' ]] \
  || fail "case 10: TSV header mismatch ($header)"
lines=$(tail -n +2 "$actions_path" | wc -l | tr -d ' ')
[[ "$lines" -eq 2 ]] || fail "case 10: expected 2 operator action rows, got $lines"
# Each row must surface a non-empty safest_next_action (no silent no-op).
empty_actions=$(awk -F'\t' 'NR>1 && (length($5) == 0 || $5 == "?")' "$actions_path" | wc -l | tr -d ' ')
[[ "$empty_actions" -eq 0 ]] || fail "case 10: $empty_actions operator rows have empty safest action"
# Each row must reference the requested tool subject so capacity rollups
# can correlate the blocker to the right MCP/connector family.
grep -F $'\tmcp/claude.ai-figma\t' "$actions_path" >/dev/null \
  || fail "case 10: TSV missing mcp/claude.ai-figma row"
grep -F $'\tbrowser-connector/chrome-devtools\t' "$actions_path" >/dev/null \
  || fail "case 10: TSV missing browser-connector/chrome-devtools row"

# --- 11. CLI modes ---------------------------------------------------------
state=$(new_state_dir 11)
mkdir -p "$state/_prompt_signals"
ledger="$state/_prompt_signals/signals.jsonl"
sig=$(ORCH_STATE_BASE="$state" make_signal pane=p11:0.0 matcher_id=figma-mcp-confirm)
printf '%s\n' "$sig" > "$ledger"

# --ledger
out=$(ORCH_STATE_BASE="$state" bash "$CLI" --ledger "$ledger" --json 2>/dev/null)
[[ -n "$out" ]] || fail "case 11a: --ledger should emit lane state on stdout"

# --from-stdin
out=$(printf '%s\n' "$sig" | ORCH_STATE_BASE="$state" bash "$CLI" --from-stdin --json 2>/dev/null)
[[ -n "$out" ]] || fail "case 11b: --from-stdin should emit lane state on stdout"

# --since-last advances the cursor; a re-run yields zero new lane states.
state=$(new_state_dir 11s)
mkdir -p "$state/_prompt_signals"
ledger="$state/_prompt_signals/signals.jsonl"
printf '%s\n' "$sig" > "$ledger"
out1=$(ORCH_STATE_BASE="$state" bash "$CLI" --since-last --json 2>/dev/null)
out2=$(ORCH_STATE_BASE="$state" bash "$CLI" --since-last --json 2>/dev/null)
[[ -n "$out1" ]] || fail "case 11c: first --since-last run should consume the new line"
if [[ -n "$out2" ]]; then
  fail "case 11c: second --since-last run should yield zero new lane states (got: $out2)"
fi

# --- 12. --policy with unreadable file → exit 4 ----------------------------
set +e
out=$(bash "$CLI" --from-stdin --policy "$TEST_TMP/no-such.tsv" 2>&1 < /dev/null)
rc=$?
set -e
[[ "$rc" -eq 4 ]] || fail "case 12: missing policy file should exit 4, got $rc"

# --- 13. Stale-prompt-age force-escalation (#430 / #348 AC#6+#7) -----------
# Default ORCH_PROMPT_STALE_AGE_SEC=1800. A signal with prompt_age_sec
# below the threshold MUST behave like the default audit-only flow:
# lane=needs_operator_permission, stale_escalation.applied=false, no
# audit log file emission.
state=$(new_state_dir 13a)
load_lib_with_state "$state"
sig=$(make_signal pane=p13a:0.0 matcher_id=figma-mcp-confirm prompt_age_sec=120)
out=$(prompt_unblock_consume_signals_text "$sig")
[[ "$(jq -r '.lane' <<< "$out")" == "needs_operator_permission" ]] \
  || fail "case 13a: non-stale signal should keep needs_operator_permission lane"
[[ "$(jq -r '.stale_escalation.applied' <<< "$out")" == "false" ]] \
  || fail "case 13a: non-stale signal must NOT carry stale_escalation.applied=true"
audit_log="$state/_prompt_signals/audit.log"
[[ ! -e "$audit_log" ]] \
  || fail "case 13a: non-stale signal must NOT write to audit.log"

# A signal with prompt_age_sec >= threshold MUST force-escalate the lane
# to blocked_external regardless of the configured policy mode, populate
# stale_escalation.applied=true, and append a single audit line.
state=$(new_state_dir 13b)
load_lib_with_state "$state"
sig=$(make_signal pane=p13b:0.0 matcher_id=figma-mcp-confirm prompt_age_sec=2400)
out=$(prompt_unblock_consume_signals_text "$sig")
[[ "$(jq -r '.lane' <<< "$out")" == "blocked_external" ]] \
  || fail "case 13b: stale signal must force-escalate to blocked_external (got $(jq -c .lane <<< "$out"))"
[[ "$(jq -r '.policy_action' <<< "$out")" == "audit-only" ]] \
  || fail "case 13b: stale escalation must NOT mutate the underlying policy_action"
[[ "$(jq -r '.stale_escalation.applied' <<< "$out")" == "true" ]] \
  || fail "case 13b: stale signal must carry stale_escalation.applied=true"
[[ "$(jq -r '.stale_escalation.age_sec' <<< "$out")" == "2400" ]] \
  || fail "case 13b: stale_escalation.age_sec must reflect the input prompt_age_sec"
[[ "$(jq -r '.stale_escalation.threshold_sec' <<< "$out")" == "1800" ]] \
  || fail "case 13b: stale_escalation.threshold_sec must reflect ORCH_PROMPT_STALE_AGE_SEC default"
audit_log="$state/_prompt_signals/audit.log"
[[ -s "$audit_log" ]] \
  || fail "case 13b: stale signal must append a PROMPT_UNBLOCK_STALE_ESCALATED audit line"
grep -q 'PROMPT_UNBLOCK_STALE_ESCALATED pane=p13b:0.0 matcher_id=figma-mcp-confirm age_sec=2400 threshold_sec=1800' "$audit_log" \
  || fail "case 13b: audit line content mismatch: $(cat "$audit_log")"

# A second stale signal for the SAME (pane, matcher_id) pair inside the
# dedupe cooldown must NOT add a second audit line — the existing
# rate-limit machinery still applies.
out2=$(prompt_unblock_consume_signals_text "$sig")
[[ "$(jq -r '.lane' <<< "$out2")" == "blocked_external" ]] \
  || fail "case 13b: stale signal must still escalate the lane on a second emit"
[[ "$(jq -r '.alert_eligible' <<< "$out2")" == "false" ]] \
  || fail "case 13b: second stale signal must be cooldown-suppressed"
audit_lines=$(wc -l < "$audit_log")
[[ "$audit_lines" -eq 1 ]] \
  || fail "case 13b: cooldown-suppressed stale signal must NOT append a second audit line (got $audit_lines)"

# A stale signal whose policy is already escalate (lane already
# blocked_external) MUST NOT mark stale_escalation.applied=true: the
# escalation is one-way and never *re-escalates* an already-blocked lane.
state=$(new_state_dir 13c)
load_lib_with_state "$state"
mkdir -p "$state/_prompt_signals"
printf 'auto-mode||escalate|300\n' > "$state/_prompt_signals/policy.tsv"
sig=$(make_signal pane=p13c:0.0 matcher_id=auto-mode-denial \
  tool=auto-mode provider= prompt_age_sec=3600)
out=$(prompt_unblock_consume_signals_text "$sig")
[[ "$(jq -r '.lane' <<< "$out")" == "blocked_external" ]] \
  || fail "case 13c: escalate policy must keep blocked_external"
[[ "$(jq -r '.stale_escalation.applied' <<< "$out")" == "false" ]] \
  || fail "case 13c: stale_escalation.applied must stay false for already-escalated lanes"
audit_log="$state/_prompt_signals/audit.log"
[[ ! -e "$audit_log" ]] \
  || fail "case 13c: already-escalated lane must NOT add a stale-escalation audit line"

# Operator-tunable threshold: ORCH_PROMPT_STALE_AGE_SEC=60 must escalate
# a 90-second-old prompt; 30-second-old prompt must not escalate.
state=$(new_state_dir 13d)
load_lib_with_state "$state"
ORCH_PROMPT_STALE_AGE_SEC=60
sig_old=$(make_signal pane=p13d:0.0 matcher_id=figma-mcp-confirm prompt_age_sec=90)
out=$(prompt_unblock_consume_signals_text "$sig_old")
[[ "$(jq -r '.lane' <<< "$out")" == "blocked_external" ]] \
  || fail "case 13d: tuned threshold should escalate 90s prompt"
sig_young=$(make_signal pane=p13d2:0.0 matcher_id=figma-mcp-confirm prompt_age_sec=30)
out=$(prompt_unblock_consume_signals_text "$sig_young")
[[ "$(jq -r '.lane' <<< "$out")" == "needs_operator_permission" ]] \
  || fail "case 13d: tuned threshold should NOT escalate 30s prompt"
unset ORCH_PROMPT_STALE_AGE_SEC

printf 'ok - prompt_unblock_policy enforces audit-only default, per-MCP allowlist, rate-limit, dedupe, operator-action queue, and stale-prompt-age force-escalation (#430)\n'
