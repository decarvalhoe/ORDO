#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/repos"

for rel in \
  scripts/agent_status.sh \
  lib/agent_status.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/agent_status.sh"

repo="$TEST_TMP/repos/agent-work"
git init -q "$repo"
git -C "$repo" config user.email codex@example.invalid
git -C "$repo" config user.name "RBOK-codex"
printf 'ok\n' > "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -q -m 'init'
git -C "$repo" branch -M main
git -C "$repo" checkout -q -b feat/issue-638
head_sha=$(git -C "$repo" rev-parse HEAD)

record=$(
  ORCH_STATE_BASE="$TEST_TMP/state" \
  AGENT_STATUS_WAKE_SIGNAL=0 \
  bash "$SANITIZED_ROOT/scripts/agent_status.sh" declare \
    --project ordo \
    --agent 'Codex/CLI:agent one' \
    --target issue:638 \
    --workdir "$repo" \
    --status handoff_ready \
    --reason 'local commit ready for handoff' \
    --evidence "$repo/handoff.txt" \
    --phase finalizing \
    --progress-note 'commit created locally' \
    --validation-state pass \
    --next-action 'orchestrator should collect handoff' \
    --retry-count 1
)

printf '%s' "$record" \
  | jq -e --arg repo "$repo" --arg head "$head_sha" '
      .schema_version == 1
      and .project == "ordo"
      and .agent_id == "Codex/CLI:agent one"
      and .target == "issue:638"
      and .status == "handoff_ready"
      and .reason == "local commit ready for handoff"
      and .workspace.workdir == $repo
      and .git.branch == "feat/issue-638"
      and .git.head == $head
      and .optional.phase == "finalizing"
      and .optional.progress_note == "commit created locally"
      and .optional.validation_state == "pass"
      and .optional.retry_count == 1
      and .optional.next_action == "orchestrator should collect handoff"
      and .continuation_signal.queued == true
    ' >/dev/null \
  || fail "declaration record missing required fields: $record"

latest_count=$(find "$TEST_TMP/state/ordo/agent-status/latest" -type f | wc -l | tr -d ' ')
[[ "$latest_count" == "1" ]] || fail "expected one latest declaration, got $latest_count"

latest_file=$(find "$TEST_TMP/state/ordo/agent-status/latest" -type f | head -1)
cmp <(printf '%s\n' "$record" | jq -S .) <(jq -S . "$latest_file") >/dev/null \
  || fail "latest declaration file did not match emitted JSON"

ledger_lines=$(wc -l < "$TEST_TMP/state/ordo/agent-status/declarations.jsonl" | tr -d ' ')
[[ "$ledger_lines" == "1" ]] || fail "expected append-only declaration ledger line, got $ledger_lines"

event_lines=$(wc -l < "$TEST_TMP/state/ordo/agent-status/events.jsonl" | tr -d ' ')
[[ "$event_lines" == "1" ]] || fail "expected durable continuation event, got $event_lines"
[[ -f "$TEST_TMP/state/ordo/orch.run_now" ]] || fail "handoff_ready should request local orchestrator wake-up"
[[ -f "$TEST_TMP/state/ordo/agent-status/wake.pending" ]] || fail "handoff_ready should leave visible wake marker"
grep -q $'\thandoff_ready\t0$' "$TEST_TMP/state/ordo/agent-status/wake.signal" \
  || fail "wake.signal should record local signal attempts"

if ORCH_STATE_BASE="$TEST_TMP/state" \
  AGENT_STATUS_WAKE_SIGNAL=0 \
  bash "$SANITIZED_ROOT/scripts/agent_status.sh" declare \
    --project ordo \
    --agent bad-agent \
    --status sleeping \
    --reason 'invalid state' >"$TEST_TMP/invalid-status.out" 2>&1; then
  fail "invalid status should be refused"
fi
grep -q 'unknown status: sleeping' "$TEST_TMP/invalid-status.out" \
  || fail "invalid status refusal should name the bad state"

printf 'ok - agent_status declaration helper writes schema, latest record, and wake event\n'
