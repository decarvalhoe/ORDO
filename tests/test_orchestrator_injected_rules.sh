#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

brief="$ROOT/templates/orch_briefing.md"
loop="$ROOT/scripts/orch_loop.sh"
doc="$ROOT/docs/orchestrator-injected-rules.md"

grep -q 'Continuous improvement capture' "$brief" || \
  fail "orchestrator briefing must inject continuous improvement capture"
grep -q 'Preflight before dispatch' "$brief" || \
  fail "orchestrator briefing must inject preflight-before-dispatch"
grep -q 'No silent blockers' "$brief" || \
  fail "orchestrator briefing must inject silent-blocker handling"
grep -q 'Post-apply verification' "$brief" || \
  fail "orchestrator briefing must inject post-apply verification"
grep -q 'CI-delegated by default' "$brief" || \
  fail "orchestrator briefing must inject CI-delegated validator policy"
grep -q 'gh pr checks' "$brief" || \
  fail "orchestrator briefing must treat PR checks as verification evidence"
grep -q -- '--require-local-validators' "$brief" || \
  fail "orchestrator briefing must preserve local-validator opt-in"
grep -q 'Continuation guard before stopping' "$brief" || \
  fail "orchestrator briefing must inject continuation guard before stopping"
grep -q 'dispatch_required' "$brief" || \
  fail "orchestrator briefing must inject dispatch-required action state"
grep -q 'work requires one outcome' "$brief" || \
  fail "orchestrator briefing must require an action when capacity has ready work"
grep -q 'idle ready agent' "$brief" || \
  fail "orchestrator briefing must require idle ready agent blockers"
grep -q 'Context isolation' "$brief" || \
  fail "orchestrator briefing must inject multi-product context isolation"
grep -q 'Metadata-first load policy' "$brief" || \
  fail "orchestrator briefing must inject metadata-first load policy"

grep -q 'Mandatory ORDO operating rules' "$loop" || \
  fail "orch_loop fallback prompt must preserve injected operating rules"
grep -q 'continuation_guard' "$loop" || \
  fail "orch_loop fallback prompt must require continuation guard"
grep -q 'rebalance_required' "$loop" || \
  fail "orch_loop fallback prompt must preserve rebalance-required action state"

grep -q 'Opportunity Item Fields' "$doc" || \
  fail "orchestrator injected rules doc must define opportunity fields"
grep -q 'gh pr checks' "$doc" || \
  fail "orchestrator injected rules doc must treat PR checks as verification evidence"
grep -q 'safe remediation candidate' "$doc" || \
  fail "orchestrator injected rules doc must require safe remediation candidate"
grep -q 'Capacity with ready work requires' "$doc" || \
  fail "orchestrator injected rules doc must require capacity-ready action"
grep -q 'idle ready agent' "$doc" || \
  fail "orchestrator injected rules doc must require idle ready agent blockers"

printf 'ok - orchestrator injected rules are present\n'
