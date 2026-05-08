#!/usr/bin/env bash
# tests/test_prompt_detector.sh — universal interactive-prompt detector
# coverage (#349, parent epic #348).
#
# Cases:
#   1.  Figma MCP fixture matches with tool=mcp, provider=claude.ai-figma,
#       command=get_metadata, prompt_class=allow-deny-confirmation.
#   2.  Inline cwd in the prompt line is auto-extracted when --cwd is omitted.
#   3.  Explicit --cwd wins over the inline-cwd auto-extraction.
#   4.  Chrome DevTools connector fixture matches with tool=browser-connector.
#   5.  Generic browser-connector fixture matches when no provider hint exists.
#   6.  Auto-mode denial fixture matches with class=auto-mode-denial.
#   7.  Generic allow/deny confirmation fixture matches with the lowest-
#       priority generic matcher.
#   8.  False positive: regular "Yes." in conversation does NOT match.
#   9.  False positive: a "Do you want to" line WITHOUT the option pattern
#       does NOT match the figma-specific matcher.
#   10. Custom matcher via ORCH_PROMPT_MATCHERS_FILE extends the catalog
#       (and the new matcher fires on the fixture).
#   11. Multiple distinct prompts in the same capture emit multiple records;
#       duplicate identical lines emit only one (dedupe).
#   12. Highest-priority matcher wins when several patterns apply to the
#       same line (Figma-specific beats generic).
#   13. Persistence: --persist appends one JSON line per record to the
#       prompt-signals ledger and creates the parent dir on first call.
#   14. CLI: missing both --capture and --pane returns exit 2.
#   15. CLI: unknown matchers file lines (blank, comment) are tolerated.
#
# This test deliberately runs without `set -e` because some assertions
# capture deliberately non-zero exit codes via `out=$(...); rc=$?`.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/lib/prompt_detector.sh"
SCAN="$ROOT/scripts/prompt_detector_scan.sh"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local got=$1 want=$2 desc=$3
  [[ "$got" == "$want" ]] || fail "$desc: got=$got want=$want"
}

# Quick existence checks.
[[ -r "$LIB" ]] || fail "lib missing: $LIB"
[[ -x "$SCAN" ]] || fail "scan script not executable: $SCAN"
command -v jq >/dev/null 2>&1 || fail "jq required for these tests"

# Source the lib once so we can call its helpers directly.
# shellcheck source=../lib/prompt_detector.sh
source "$LIB"

# Force the ledger location to a sandboxed tmp dir.
export ORCH_STATE_BASE="$TEST_TMP/state"
export ORCH_PROMPT_DETECTOR_LEDGER="$TEST_TMP/state/_prompt_signals/signals.jsonl"

# --- Case 1: Figma MCP fixture matches with the right schema fields. -------

figma_capture='Random preceding line.
Do you want to proceed? 1.Yes 2.Yes-don'\''t-ask-again for claude.ai Figma - get_metadata commands in /repos/realisons-wordpress/claude
Trailing log line.'
record=$(prompt_detector_scan_text "$figma_capture" \
  session=claude pane=claude:0.0 agent=claude project=rbok 2>/dev/null \
  | head -n 1)
[[ -n "$record" ]] || fail "case 1: no record produced for figma fixture"
assert_eq "$(jq -r '.schema' <<< "$record")"           "ordo.prompt_detector.v1"           "case 1 schema"
assert_eq "$(jq -r '.tool' <<< "$record")"             "mcp"                                "case 1 tool"
assert_eq "$(jq -r '.provider' <<< "$record")"         "claude.ai-figma"                   "case 1 provider"
assert_eq "$(jq -r '.command' <<< "$record")"          "get_metadata"                      "case 1 command"
assert_eq "$(jq -r '.prompt_class' <<< "$record")"     "allow-deny-confirmation"           "case 1 class"
assert_eq "$(jq -r '.matcher_id' <<< "$record")"       "figma-mcp-confirm"                 "case 1 matcher_id"
assert_eq "$(jq -r '.session' <<< "$record")"          "claude"                            "case 1 session"
assert_eq "$(jq -r '.pane' <<< "$record")"             "claude:0.0"                        "case 1 pane"
assert_eq "$(jq -r '.agent' <<< "$record")"            "claude"                            "case 1 agent"
assert_eq "$(jq -r '.project' <<< "$record")"          "rbok"                              "case 1 project"

# --- Case 2: inline cwd auto-extracted when --cwd not passed. --------------
assert_eq "$(jq -r '.cwd' <<< "$record")" "/repos/realisons-wordpress/claude" "case 2 inline cwd"

# --- Case 3: explicit --cwd wins. ------------------------------------------
record_cwd=$(prompt_detector_scan_text "$figma_capture" \
  session=claude cwd=/explicit/path agent=claude 2>/dev/null \
  | head -n 1)
assert_eq "$(jq -r '.cwd' <<< "$record_cwd")" "/explicit/path" "case 3 explicit cwd"

# --- Case 4: Chrome DevTools connector. ------------------------------------

chrome_capture='Some output
Allow connection to chrome-devtools (port 9222)?
More output'
record=$(prompt_detector_scan_text "$chrome_capture" 2>/dev/null | head -n 1)
[[ -n "$record" ]] || fail "case 4: no record for chrome fixture"
assert_eq "$(jq -r '.tool' <<< "$record")"         "browser-connector"               "case 4 tool"
assert_eq "$(jq -r '.provider' <<< "$record")"     "chrome-devtools"                 "case 4 provider"
assert_eq "$(jq -r '.prompt_class' <<< "$record")" "browser-connector-confirmation"  "case 4 class"
assert_eq "$(jq -r '.matcher_id' <<< "$record")"   "chrome-devtools-connect"         "case 4 matcher_id"

# --- Case 5: generic browser-connector (no provider hint). -----------------

browser_capture='Allow connection from firefox to host:port?'
record=$(prompt_detector_scan_text "$browser_capture" 2>/dev/null | head -n 1)
[[ -n "$record" ]] || fail "case 5: no record for generic browser fixture"
assert_eq "$(jq -r '.tool' <<< "$record")"         "browser-connector"              "case 5 tool"
assert_eq "$(jq -r '.provider' <<< "$record")"     "null"                            "case 5 provider null"
assert_eq "$(jq -r '.matcher_id' <<< "$record")"   "browser-connector-confirm"      "case 5 matcher_id"

# --- Case 6: auto-mode denial. ---------------------------------------------

automode_capture='auto-mode denied: command requires confirmation.'
record=$(prompt_detector_scan_text "$automode_capture" 2>/dev/null | head -n 1)
[[ -n "$record" ]] || fail "case 6: no record for auto-mode fixture"
assert_eq "$(jq -r '.tool' <<< "$record")"         "auto-mode"           "case 6 tool"
assert_eq "$(jq -r '.prompt_class' <<< "$record")" "auto-mode-denial"    "case 6 class"
assert_eq "$(jq -r '.matcher_id' <<< "$record")"   "auto-mode-denial"    "case 6 matcher_id"

# --- Case 7: generic confirmation. -----------------------------------------

generic_capture='[y/n]'
record=$(prompt_detector_scan_text "$generic_capture" 2>/dev/null | head -n 1)
[[ -n "$record" ]] || fail "case 7: no record for generic fixture"
assert_eq "$(jq -r '.matcher_id' <<< "$record")" "generic-confirmation" "case 7 matcher_id"
assert_eq "$(jq -r '.tool' <<< "$record")"       "generic"              "case 7 tool"

# --- Case 8: false positive — plain "Yes" should NOT match. ---------------

false_capture_1='User said: Yes please.
Assistant: ok.'
records=$(prompt_detector_scan_text "$false_capture_1" 2>/dev/null)
[[ -z "$records" ]] || fail "case 8: false positive on plain Yes; got=$records"

# --- Case 9: false positive — "Do you want to" without options. -----------

false_capture_2='Do you want to also include the docs section?'
records=$(prompt_detector_scan_text "$false_capture_2" 2>/dev/null)
# This SHOULD NOT match the figma matcher (no claude.ai Figma) nor the
# generic mcp matcher (no 1.Yes/2.Yes-don't-ask-again). Other matchers do
# not match either.
[[ -z "$records" ]] || fail "case 9: figma/mcp false positive on bare 'Do you want to'; got=$records"

# --- Case 10: custom matcher via ORCH_PROMPT_MATCHERS_FILE. ----------------

custom_file="$TEST_TMP/custom_matchers.txt"
cat > "$custom_file" <<'EOF'
# operator-supplied custom matchers
custom-vault-grant|secrets-manager|hashicorp-vault|allow-deny-confirmation|120|grant access to vault path
EOF
custom_capture='Please grant access to vault path /secret/foo'
export ORCH_PROMPT_MATCHERS_FILE="$custom_file"
record=$(prompt_detector_scan_text "$custom_capture" 2>/dev/null | head -n 1)
unset ORCH_PROMPT_MATCHERS_FILE
[[ -n "$record" ]] || fail "case 10: no record for custom matcher fixture"
assert_eq "$(jq -r '.matcher_id' <<< "$record")" "custom-vault-grant" "case 10 matcher_id"
assert_eq "$(jq -r '.provider' <<< "$record")"   "hashicorp-vault"    "case 10 provider"

# --- Case 11: multi-prompt capture with one duplicate line (dedupe). ------

multi_capture='Some intro
Do you want to proceed? 1.Yes 2.Yes-don'\''t-ask-again for claude.ai Figma - get_metadata commands in /repos/figma/a
Allow connection to chrome-devtools (port 9222)?
Do you want to proceed? 1.Yes 2.Yes-don'\''t-ask-again for claude.ai Figma - get_metadata commands in /repos/figma/a
auto-mode denied: command requires confirmation'
records=$(prompt_detector_scan_text "$multi_capture" 2>/dev/null)
record_count=$(printf '%s\n' "$records" | sed '/^$/d' | wc -l | tr -d ' ')
# Expect: figma (deduped to 1) + chrome (1) + auto-mode (1) = 3.
assert_eq "$record_count" "3" "case 11 record count after dedupe"
matcher_ids=$(printf '%s\n' "$records" | jq -r '.matcher_id' | sort -u | paste -sd, -)
assert_eq "$matcher_ids" "auto-mode-denial,chrome-devtools-connect,figma-mcp-confirm" "case 11 matcher set"

# --- Case 12: priority — figma-specific wins over generic mcp. ------------

# Both figma-mcp-confirm (priority 110) and mcp-allow-deny-confirm (90)
# match the canonical Figma line. The detector must keep figma-mcp-confirm.
priority_capture='Do you want to proceed? 1.Yes 2.Yes-don'\''t-ask-again for claude.ai Figma - whoami commands in /repos/x'
record=$(prompt_detector_scan_text "$priority_capture" 2>/dev/null | head -n 1)
assert_eq "$(jq -r '.matcher_id' <<< "$record")" "figma-mcp-confirm" "case 12 priority winner"

# A line that matches the generic-mcp pattern but not the figma pattern
# (e.g. another MCP) should win the generic mcp matcher.
generic_mcp_capture='Do you want to proceed? 1.Yes 2.Yes-don'\''t-ask-again for some.other MCP commands'
record=$(prompt_detector_scan_text "$generic_mcp_capture" 2>/dev/null | head -n 1)
assert_eq "$(jq -r '.matcher_id' <<< "$record")" "mcp-allow-deny-confirm" "case 12 generic mcp winner"

# --- Case 13: persistence to ledger via the CLI --persist flag. ------------

ledger="$ORCH_PROMPT_DETECTOR_LEDGER"
rm -f "$ledger"
[[ ! -f "$ledger" ]] || fail "case 13: ledger should start empty"

cat > "$TEST_TMP/case13_capture.txt" <<'EOF'
Random.
Do you want to proceed? 1.Yes 2.Yes-don't-ask-again for claude.ai Figma - get_metadata commands in /repos/case13
Tail.
EOF

out=$(bash "$SCAN" --capture "$TEST_TMP/case13_capture.txt" \
  --session ledger-test --agent ledger-agent --project ledger-project \
  --persist 2>/dev/null)
[[ -n "$out" ]] || fail "case 13: no stdout record"
[[ -f "$ledger" ]] || fail "case 13: ledger file not created"
ledger_count=$(wc -l < "$ledger" | tr -d ' ')
assert_eq "$ledger_count" "1" "case 13 ledger record count"
assert_eq "$(jq -r '.matcher_id' "$ledger")" "figma-mcp-confirm" "case 13 ledger matcher_id"

# Re-running --persist must append, not overwrite.
out=$(bash "$SCAN" --capture "$TEST_TMP/case13_capture.txt" \
  --session ledger-test --agent ledger-agent --project ledger-project \
  --persist 2>/dev/null)
ledger_count=$(wc -l < "$ledger" | tr -d ' ')
assert_eq "$ledger_count" "2" "case 13 ledger appends"

# --- Case 14: CLI rejects missing source. ----------------------------------

out=$(bash "$SCAN" 2>&1)
rc=$?
[[ "$rc" -eq 2 ]] || fail "case 14: missing args expected exit 2, got=$rc out=$out"

# --- Case 15: matcher file with comments and blanks is tolerated. ---------

cat > "$TEST_TMP/with_comments.txt" <<'EOF'
# leading comment
   # indented comment

ledger-tolerated|tool-x||generic-confirmation|150|^TOLERATED-LINE$

# trailing comment
EOF
export ORCH_PROMPT_MATCHERS_FILE="$TEST_TMP/with_comments.txt"
record=$(prompt_detector_scan_text 'TOLERATED-LINE' 2>/dev/null | head -n 1)
unset ORCH_PROMPT_MATCHERS_FILE
[[ -n "$record" ]] || fail "case 15: comment-laden matcher file did not load"
assert_eq "$(jq -r '.matcher_id' <<< "$record")" "ledger-tolerated" "case 15 matcher_id"

# --- Case 16: list_matcher_ids exposes the catalog. ------------------------

ids=$(prompt_detector_list_matcher_ids | sort | paste -sd, -)
expected_ids='auto-mode-denial,browser-connector-confirm,chrome-devtools-connect,figma-mcp-confirm,generic-confirmation,mcp-allow-deny-confirm'
assert_eq "$ids" "$expected_ids" "case 16 default matcher ids"

printf 'ok - prompt_detector tests passed\n'
