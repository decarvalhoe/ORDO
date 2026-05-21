#!/usr/bin/env bash
# tests/test_parked_decisions.sh — fixture tests for rbok#725.
#
# Covers the lib's idempotent add, clear-by-id, and reminders rendering,
# plus the CLI surface. Plain bash so it runs on the shared agent host
# without bats; emits TAP-ish "ok"/"not ok" lines.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export PARKED_DECISIONS_FILE="$TEST_TMP/parked_decisions.json"

# shellcheck source=../lib/parked_decisions.sh
. "$ROOT/lib/parked_decisions.sh"

TESTS_RUN=0
TESTS_FAIL=0

ok() {
  TESTS_RUN=$((TESTS_RUN + 1))
  printf 'ok %d - %s\n' "$TESTS_RUN" "$1"
}

not_ok() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAIL=$((TESTS_FAIL + 1))
  printf 'not ok %d - %s\n' "$TESTS_RUN" "$1"
  if [ -n "${2:-}" ]; then
    printf '  # %s\n' "$2"
  fi
}

reset_ledger() {
  rm -f "$PARKED_DECISIONS_FILE" "$PARKED_DECISIONS_FILE.lock"
}

count_entries() {
  jq 'length' "$PARKED_DECISIONS_FILE" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Empty ledger reads as []
# ---------------------------------------------------------------------------

reset_ledger
out=$(parked_decisions_read)
if [ "$(printf '%s' "$out" | jq -c '.')" = "[]" ]; then
  ok "empty ledger reads as []"
else
  not_ok "empty ledger reads as []" "got: $out"
fi

# ---------------------------------------------------------------------------
# add creates a single entry with expected fields
# ---------------------------------------------------------------------------

reset_ledger
parked_decisions_add \
  "needs-user-auth:dispatch:agent-001:#722:external-pr-mutations" \
  "needs_user_auth" \
  "dispatch_ticket" \
  "agent-001" \
  "#722" \
  "external-pr-mutations unauthorized (unmet=issue_assignees)" \
  "pass --external-pr-mutations=issue_assignees" \
  >/dev/null

if [ "$(count_entries)" = "1" ]; then
  ok "add inserts one row"
else
  not_ok "add inserts one row" "count=$(count_entries) content=$(cat "$PARKED_DECISIONS_FILE")"
fi

kind=$(jq -r '.[0].kind' "$PARKED_DECISIONS_FILE")
agent=$(jq -r '.[0].agent' "$PARKED_DECISIONS_FILE")
created=$(jq -r '.[0].created_at' "$PARKED_DECISIONS_FILE")
if [ "$kind" = "needs_user_auth" ] && [ "$agent" = "agent-001" ] && [ -n "$created" ]; then
  ok "add records kind/agent/created_at"
else
  not_ok "add records kind/agent/created_at" "kind=$kind agent=$agent created=$created"
fi

# ---------------------------------------------------------------------------
# add is idempotent on id: same id => one row; created_at preserved.
# ---------------------------------------------------------------------------

# Sleep 1s so the second add would produce a different timestamp if it overwrote
sleep 1
parked_decisions_add \
  "needs-user-auth:dispatch:agent-001:#722:external-pr-mutations" \
  "needs_user_auth" \
  "dispatch_ticket" \
  "agent-001" \
  "#722" \
  "second summary (refreshed)" \
  "second options" \
  >/dev/null

if [ "$(count_entries)" = "1" ]; then
  ok "re-add with same id stays at 1 row (idempotent)"
else
  not_ok "re-add with same id stays at 1 row (idempotent)" "count=$(count_entries)"
fi

created_after=$(jq -r '.[0].created_at' "$PARKED_DECISIONS_FILE")
summary_after=$(jq -r '.[0].summary' "$PARKED_DECISIONS_FILE")
updated_after=$(jq -r '.[0].updated_at' "$PARKED_DECISIONS_FILE")
if [ "$created_after" = "$created" ]; then
  ok "idempotent add preserves created_at"
else
  not_ok "idempotent add preserves created_at" "before=$created after=$created_after"
fi
if [ "$summary_after" = "second summary (refreshed)" ]; then
  ok "idempotent add refreshes summary"
else
  not_ok "idempotent add refreshes summary" "got: $summary_after"
fi
if [ -n "$updated_after" ] && [ "$updated_after" != "$created_after" ]; then
  ok "idempotent add bumps updated_at"
else
  not_ok "idempotent add bumps updated_at" "created=$created_after updated=$updated_after"
fi

# ---------------------------------------------------------------------------
# add with a different id adds a second row
# ---------------------------------------------------------------------------

parked_decisions_add \
  "operator-intervention:post_merge_cleanup:pr-722:agent-001:dirty_worktree" \
  "operator_intervention_required" \
  "post_merge_cleanup" \
  "agent-001" \
  "pr=#722" \
  "skip:dirty_worktree (source=assignment current_branch=feat/x dirty=3)" \
  "investigate workdir" \
  >/dev/null

if [ "$(count_entries)" = "2" ]; then
  ok "second distinct id adds a second row"
else
  not_ok "second distinct id adds a second row" "count=$(count_entries)"
fi

# ---------------------------------------------------------------------------
# clear by id removes exactly one row
# ---------------------------------------------------------------------------

parked_decisions_clear "needs-user-auth:dispatch:agent-001:#722:external-pr-mutations" >/dev/null
if [ "$(count_entries)" = "1" ]; then
  ok "clear by id removes one row"
else
  not_ok "clear by id removes one row" "count=$(count_entries) content=$(cat "$PARKED_DECISIONS_FILE")"
fi

remaining_id=$(jq -r '.[0].id' "$PARKED_DECISIONS_FILE")
if [ "$remaining_id" = "operator-intervention:post_merge_cleanup:pr-722:agent-001:dirty_worktree" ]; then
  ok "clear removed the targeted id"
else
  not_ok "clear removed the targeted id" "remaining=$remaining_id"
fi

# clear of absent id is a no-op (no error, count unchanged)
set +e
parked_decisions_clear "unknown-id-not-present" >/dev/null
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ "$(count_entries)" = "1" ]; then
  ok "clear of absent id is a no-op"
else
  not_ok "clear of absent id is a no-op" "rc=$rc count=$(count_entries)"
fi

# ---------------------------------------------------------------------------
# reminders rendering: Markdown bullet lines for non-empty ledger
# ---------------------------------------------------------------------------

# Add a second row with options so we can verify the options suffix.
parked_decisions_add \
  "needs-user-auth:dispatch:agent-002:#999:external-pr-mutations" \
  "needs_user_auth" \
  "dispatch_ticket" \
  "agent-002" \
  "#999" \
  "external-pr-mutations unauthorized (unmet=pr_comment)" \
  "pass --external-pr-mutations=pr_comment" \
  >/dev/null

reminders=$(parked_decisions_reminders)
if printf '%s\n' "$reminders" | grep -q '^- \*\*operator_intervention_required\*\*'; then
  ok "reminders emits operator_intervention bullet"
else
  not_ok "reminders emits operator_intervention bullet" "got: $reminders"
fi
if printf '%s\n' "$reminders" | grep -q '^- \*\*needs_user_auth\*\*'; then
  ok "reminders emits needs_user_auth bullet"
else
  not_ok "reminders emits needs_user_auth bullet" "got: $reminders"
fi
if printf '%s\n' "$reminders" | grep -q 'options: pass --external-pr-mutations=pr_comment'; then
  ok "reminders renders options suffix"
else
  not_ok "reminders renders options suffix" "got: $reminders"
fi

# Empty ledger => empty reminders stdout.
reset_ledger
empty_reminders=$(parked_decisions_reminders)
if [ -z "$empty_reminders" ]; then
  ok "reminders prints nothing on empty ledger"
else
  not_ok "reminders prints nothing on empty ledger" "got: $empty_reminders"
fi

# ---------------------------------------------------------------------------
# list emits TSV rows
# ---------------------------------------------------------------------------

parked_decisions_add "id-a" "needs_user_auth" "dispatch_ticket" "agent-001" "#1" "summary-a" "" >/dev/null
parked_decisions_add "id-b" "operator_intervention_required" "post_merge_cleanup" "agent-002" "pr=#2" "summary-b" "" >/dev/null

list_out=$(parked_decisions_list)
line_count=$(printf '%s\n' "$list_out" | grep -c .)
if [ "$line_count" = "2" ]; then
  ok "list emits one row per entry"
else
  not_ok "list emits one row per entry" "got: $list_out"
fi

if printf '%s\n' "$list_out" | awk -F '\t' '$1=="id-a" && $2=="needs_user_auth" && $4=="agent-001"{found=1} END{exit !found}'; then
  ok "list TSV columns line up"
else
  not_ok "list TSV columns line up" "got: $list_out"
fi

# ---------------------------------------------------------------------------
# should_park TTL gate
# ---------------------------------------------------------------------------

reset_ledger

# TTL=0 always parks, even repeatedly.
if parked_decisions_should_park "ttl-id" 0; then ok "should_park returns yes when entry missing (ttl=0)"; else not_ok "should_park returns yes when entry missing (ttl=0)"; fi
parked_decisions_add "ttl-id" "operator_intervention_required" "post_merge_cleanup" "" "pr=#1" "x" "" >/dev/null
if parked_decisions_should_park "ttl-id" 0; then ok "should_park returns yes for existing entry when ttl=0"; else not_ok "should_park returns yes for existing entry when ttl=0"; fi

# TTL=3600 suppresses re-reminding within the window.
if parked_decisions_should_park "ttl-id" 3600; then
  not_ok "should_park suppresses within ttl window" "expected suppress, got park"
else
  ok "should_park suppresses within ttl window"
fi

# ---------------------------------------------------------------------------
# CLI subcommands
# ---------------------------------------------------------------------------

reset_ledger
"$ROOT/scripts/parked_decisions.sh" add \
  --id "cli-id" --kind needs_user_auth --source dispatch_ticket \
  --agent agent-001 --target "#42" --summary "cli summary" \
  --options "approve | resolve" >/dev/null
if [ "$(count_entries)" = "1" ]; then
  ok "CLI add inserts a row"
else
  not_ok "CLI add inserts a row" "count=$(count_entries)"
fi

cli_list=$("$ROOT/scripts/parked_decisions.sh" list)
if printf '%s\n' "$cli_list" | awk -F '\t' '$1=="cli-id" && $2=="needs_user_auth"{found=1} END{exit !found}'; then
  ok "CLI list emits the inserted row"
else
  not_ok "CLI list emits the inserted row" "got: $cli_list"
fi

cli_reminders=$("$ROOT/scripts/parked_decisions.sh" reminders)
if printf '%s\n' "$cli_reminders" | grep -q 'cli-id'; then
  ok "CLI reminders surfaces the entry id"
else
  not_ok "CLI reminders surfaces the entry id" "got: $cli_reminders"
fi

"$ROOT/scripts/parked_decisions.sh" clear --id "cli-id" >/dev/null
if [ "$(count_entries)" = "0" ]; then
  ok "CLI clear removes the row"
else
  not_ok "CLI clear removes the row" "count=$(count_entries)"
fi

# CLI add without required flag must fail
set +e
"$ROOT/scripts/parked_decisions.sh" add --id missing-fields >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 2 ]; then
  ok "CLI add without required flags exits 2"
else
  not_ok "CLI add without required flags exits 2" "rc=$rc"
fi

# Unknown subcommand exits 2
set +e
"$ROOT/scripts/parked_decisions.sh" bogus >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 2 ]; then
  ok "CLI unknown subcommand exits 2"
else
  not_ok "CLI unknown subcommand exits 2" "rc=$rc"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '1..%d\n' "$TESTS_RUN"
if [ "$TESTS_FAIL" -eq 0 ]; then
  printf '# all %d parked-decisions assertions passed\n' "$TESTS_RUN"
  exit 0
fi
printf '# %d/%d assertions failed\n' "$TESTS_FAIL" "$TESTS_RUN" >&2
exit 1
