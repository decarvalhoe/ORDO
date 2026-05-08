#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

template="$ROOT/templates/dispatch-canonical.md.tpl"
doc="$ROOT/docs/fleet-injected-rules.md"

grep -q 'Regles ORDO injectees pour la flotte' "$template" || \
  fail "dispatch template must inject fleet rules"
grep -q 'context-mismatch' "$template" || \
  fail "fleet rules must require context mismatch stop"
grep -q 'Isolation multi-produit' "$template" || \
  fail "fleet rules must require multi-product isolation"
grep -q 'opportunity_findings' "$template" || \
  fail "fleet final report must include opportunity_findings"
grep -q 'validation/POC plan' "$template" || \
  fail "fleet final report must include validation/POC plan for findings"
grep -q 'linked evidence' "$template" || \
  fail "fleet final report must include linked evidence for findings"
grep -q 'Mutations interdites' "$template" || \
  fail "fleet rules must preserve forbidden mutations"
grep -q 'CI-delegated validation' "$template" || \
  fail "dispatch template must default heavy validators to CI"
grep -q 'gh pr checks <pr> --watch' "$template" || \
  fail "dispatch template must accept PR checks as validation proof"

grep -q 'Fleet Injected Rules' "$doc" || \
  fail "fleet injected rules doc missing"
grep -q 'Orchestrator Follow-Up' "$doc" || \
  fail "fleet doc must connect findings to orchestrator follow-up"
grep -q 'linked evidence' "$doc" || \
  fail "fleet doc must require linked evidence when available"

printf 'ok - fleet injected rules are present\n'
