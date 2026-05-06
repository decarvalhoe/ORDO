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
grep -q 'Context isolation' "$brief" || \
  fail "orchestrator briefing must inject multi-product context isolation"
grep -q 'Metadata-first load policy' "$brief" || \
  fail "orchestrator briefing must inject metadata-first load policy"

grep -q 'Mandatory ORDO operating rules' "$loop" || \
  fail "orch_loop fallback prompt must preserve injected operating rules"

grep -q 'Opportunity Item Fields' "$doc" || \
  fail "orchestrator injected rules doc must define opportunity fields"
grep -q 'safe remediation candidate' "$doc" || \
  fail "orchestrator injected rules doc must require safe remediation candidate"

printf 'ok - orchestrator injected rules are present\n'
