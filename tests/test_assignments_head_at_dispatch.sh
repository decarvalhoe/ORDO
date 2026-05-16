#!/usr/bin/env bash
# tests/test_assignments_head_at_dispatch.sh — rbok#500.
# shellcheck disable=SC2034
#
# scripts/dispatch_ticket.sh persists assignment ledgers through
# `dispatch_assignment_payload`. The payload feeds both the pending and
# promoted entries (assignments_pending.json and assignments.json), so
# whatever fields it emits land in both. rbok#500 requires the field
# `head_at_dispatch` — the assigned workdir's `git rev-parse HEAD`
# captured at dispatch time — so cycle 2 can mechanically distinguish
# post-dispatch commits from pre-existing branch heads.
#
# This test:
#   1. Loads only the `dispatch_assignment_payload` function from
#      scripts/dispatch_ticket.sh, in isolation, so it stays fast and
#      stable against unrelated dispatch lifecycle changes.
#   2. Asserts that when HEAD_AT_DISPATCH is set, the emitted JSON
#      carries `head_at_dispatch` equal to the workdir HEAD.
#   3. Asserts that when HEAD_AT_DISPATCH is empty, the field is still
#      declared and serialises to null (so consumers see a tri-state of
#      "no comparison possible" rather than an absent key).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

# Extract `dispatch_assignment_payload` (a self-contained jq invocation
# that reads from env vars) without sourcing the full dispatch script —
# sourcing dispatch_ticket.sh runs its CLI flow and pulls in tmux,
# orchestration state, MCP preflight, etc., none of which are relevant
# to validating the payload's field set.
fn_file="$TEST_TMP/payload_fn.sh"
awk '
  /^dispatch_assignment_payload\(\) \{/ { capture = 1 }
  capture { print }
  capture && /^\}$/ { exit }
' "$ROOT/scripts/dispatch_ticket.sh" > "$fn_file"

grep -q '^dispatch_assignment_payload() {' "$fn_file" \
  || fail "could not extract dispatch_assignment_payload from scripts/dispatch_ticket.sh"
grep -q '^}$' "$fn_file" \
  || fail "extracted dispatch_assignment_payload is missing closing brace"

# Stub the only external helper the payload function calls.
agent_repo_root() { printf '%s\n' "$TEST_TMP/repos/${1}"; }

# Build a real git workdir so HEAD is a real, comparable SHA.
mkdir -p "$TEST_TMP/repos/claude"
git init -q "$TEST_TMP/repos/claude"
git -C "$TEST_TMP/repos/claude" config user.name "Head Dispatch Test"
git -C "$TEST_TMP/repos/claude" config user.email "head-dispatch@test.local"
printf 'seed\n' > "$TEST_TMP/repos/claude/README.md"
git -C "$TEST_TMP/repos/claude" add README.md
git -C "$TEST_TMP/repos/claude" commit -q -m "seed"
expected_head=$(git -C "$TEST_TMP/repos/claude" rev-parse HEAD)
[[ -n "$expected_head" ]] || fail "workdir setup did not produce a HEAD"

# Load only the function.
# shellcheck disable=SC1090
source "$fn_file"
declare -F dispatch_assignment_payload >/dev/null \
  || fail "dispatch_assignment_payload should be defined after sourcing extracted snippet"

# Case 1: HEAD_AT_DISPATCH set — payload must carry it verbatim.
WORKDIR="$TEST_TMP/repos/claude"
AGENT="claude"
TICKET_NUM=5500
BRANCH="feat/issue-5500"
STAGED="/tmp/dispatch-claude-5500.md"
DISPATCHED_AT="2026-05-16T01:23:45Z"
HEAD_AT_DISPATCH="$expected_head"
DISPATCH_ROUTE=""
PANE_CONTEXT_PROOF_ROUTE=""
PANE_CONTEXT_PROOF_LIVE_PATH=""

payload=$(dispatch_assignment_payload "" "" "")
[[ -n "$payload" ]] || fail "payload should be non-empty"
printf '%s' "$payload" | jq -e . >/dev/null \
  || fail "payload should be valid JSON, got: $payload"

actual_head=$(printf '%s' "$payload" | jq -r '.head_at_dispatch')
[[ "$actual_head" == "$expected_head" ]] \
  || fail "head_at_dispatch should equal workdir HEAD ($expected_head), got: $actual_head"

# rbok#500 names the key explicitly; guard against silent renames that
# would let a value comparison pass via some other field.
printf '%s' "$payload" | jq -e 'has("head_at_dispatch")' >/dev/null \
  || fail "payload must declare a head_at_dispatch key"

# The existing assignment fields must still be present (regression
# guard: the payload schema is the surface for downstream consumers).
for required in ticket issue branch workdir repo_root prompt_file dispatched_at head_at_dispatch; do
  printf '%s' "$payload" | jq -e --arg k "$required" 'has($k)' >/dev/null \
    || fail "payload missing required key: $required"
done

# Case 2: HEAD_AT_DISPATCH empty — field must still be present, value
# must serialise to JSON null so consumers can mechanically distinguish
# "no comparison possible" from "field not yet wired up".
HEAD_AT_DISPATCH=""
empty_payload=$(dispatch_assignment_payload "" "" "")
printf '%s' "$empty_payload" | jq -e 'has("head_at_dispatch") and .head_at_dispatch == null' >/dev/null \
  || fail "empty HEAD_AT_DISPATCH must serialise as JSON null, got: $(printf '%s' "$empty_payload" | jq -c .head_at_dispatch)"

# Case 3: the same payload path serves pending records too — when a
# status/reason/updated_at trio is supplied, head_at_dispatch must
# continue to ride along.
HEAD_AT_DISPATCH="$expected_head"
pending_payload=$(dispatch_assignment_payload "pending" "queued" "2026-05-16T01:23:46Z")
pending_head=$(printf '%s' "$pending_payload" | jq -r '.head_at_dispatch')
[[ "$pending_head" == "$expected_head" ]] \
  || fail "pending payload should also carry head_at_dispatch=$expected_head, got: $pending_head"
printf '%s' "$pending_payload" | jq -e '.status == "pending" and .reason == "queued"' >/dev/null \
  || fail "pending payload should preserve status/reason"

printf 'ok - test_assignments_head_at_dispatch\n'
