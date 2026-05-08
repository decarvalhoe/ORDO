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

grep -q 'Production CAPA and self-improvement capture' "$brief" || \
  fail "orchestrator briefing must inject CAPA and self-improvement capture"
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
grep -q 'findings_ledger.sh' "$brief" || \
  fail "orchestrator briefing must inject outside-worktree findings ledger guidance"
grep -q 'linked audit evidence' "$brief" || \
  fail "orchestrator briefing must require linked audit evidence"
grep -q 'IQ, OQ' "$brief" || \
  fail "orchestrator briefing must require phase reports to reference CAPA items"

grep -q 'Mandatory ORDO operating rules' "$loop" || \
  fail "orch_loop fallback prompt must preserve injected operating rules"
grep -q 'continuation_guard' "$loop" || \
  fail "orch_loop fallback prompt must require continuation guard"
grep -q 'rebalance_required' "$loop" || \
  fail "orch_loop fallback prompt must preserve rebalance-required action state"
grep -q 'live findings ledgers must stay outside active worktrees by default' "$loop" || \
  fail "orch_loop fallback prompt must preserve findings ledger storage policy"
grep -q 'linked audit evidence' "$loop" || \
  fail "orch_loop fallback prompt must require linked audit evidence"
grep -q 'CAPA' "$loop" || \
  fail "orch_loop fallback prompt must preserve CAPA wording"

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
grep -q 'findings_ledger.sh' "$doc" || \
  fail "orchestrator injected rules doc must document findings ledger curation"
grep -q 'linked audit evidence' "$doc" || \
  fail "orchestrator injected rules doc must require linked audit evidence"
grep -q 'IQ/OQ/PQ CAPA references' "$doc" || \
  fail "orchestrator injected rules doc must require IQ/OQ/PQ CAPA references"

printf 'ok - orchestrator injected rules are present\n'
