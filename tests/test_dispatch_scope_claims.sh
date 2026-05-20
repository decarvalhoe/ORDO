#!/usr/bin/env bash
# tests/test_dispatch_scope_claims.sh — proves the in-flight scope-claim
# ledger (#721 sub-A) writes a row on dispatch ASSIGNMENT_PROMOTED, is
# read back as a union by downstream planners, and is released on PR
# merge cleanup. Also pins the canonical-brief parser so a rendered
# `Fichiers autorises` / `Fichiers interdits` block round-trips
# through the ledger without losing entries.
#
# Source: ORDO issue #721 (live-cycle finding 2026-05-16). Two
# agents were dispatched against the same file because the planner
# had no view of which paths another agent had already claimed.
# The lib-level unit pins keep that regression off the floor without
# requiring the full dispatch_ticket integration sandbox.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)

cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

mkdir -p "$TEST_TMP/state" "$TEST_TMP/logs"

export PROJECT="ordo-scope-claim-test"
export ORCH_STATE_BASE="$TEST_TMP/state"
export ORCH_LOG_DIR="$TEST_TMP/logs"
# audit_log.sh -> config_check.sh asserts AGENT_WORKDIR_TEMPLATE is set
# even though this unit test never resolves an agent workdir. Point it
# at the temp scratch so the sourcing chain succeeds.
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"

# shellcheck source=../lib/audit_log.sh
source "$ROOT/lib/audit_log.sh"
# shellcheck source=../lib/state_persist.sh
source "$ROOT/lib/state_persist.sh"
# shellcheck source=../lib/dispatch_capacity.sh
source "$ROOT/lib/dispatch_capacity.sh"

# --- Case 1: parser extracts both scope blocks from a canonical brief ---
prompt_file="$TEST_TMP/brief.md"
cat > "$prompt_file" <<'EOF'
# Dispatch canonique
## Boundaries / interdictions

- Fichiers autorises:

scripts/dispatch_ticket.sh
scripts/brief_agents.sh
lib/dispatch_capacity.sh

- Fichiers interdits:

scripts/portfolio_dispatch.sh
docs/portfolio.md

- Interdictions absolues:
  - pas de push
EOF

scope=$(dispatch_capacity_extract_scope_block "$prompt_file" "Fichiers autorises")
expected_scope=$'scripts/dispatch_ticket.sh\nscripts/brief_agents.sh\nlib/dispatch_capacity.sh'
[ "$scope" = "$expected_scope" ] \
  || fail "scope block parse mismatch: got $scope"

forbidden=$(dispatch_capacity_extract_scope_block "$prompt_file" "Fichiers interdits")
expected_forbidden=$'scripts/portfolio_dispatch.sh\ndocs/portfolio.md'
[ "$forbidden" = "$expected_forbidden" ] \
  || fail "forbidden block parse mismatch: got $forbidden"

# --- Case 2: write_scope_claim writes a row keyed by agent ---
claimed_at="2026-05-20T12:00:00Z"
dispatch_capacity_write_scope_claim \
  "agent-001" "721" "feat/issue-721" "$scope" "$forbidden" "$claimed_at" \
  || fail "write_scope_claim returned non-zero"

ledger="$(state_dir)/assignments_scope_claims.json"
[ -s "$ledger" ] || fail "claim ledger not created at $ledger"

[ "$(jq -r '."agent-001".agent' "$ledger")" = "agent-001" ] \
  || fail "claim agent field not agent-001"
[ "$(jq -r '."agent-001".ticket' "$ledger")" = "721" ] \
  || fail "claim ticket not 721"
[ "$(jq -r '."agent-001".branch' "$ledger")" = "feat/issue-721" ] \
  || fail "claim branch not feat/issue-721"
[ "$(jq -r '."agent-001".claimed_at' "$ledger")" = "$claimed_at" ] \
  || fail "claim claimed_at mismatch"
[ "$(jq -r '."agent-001".scope_files | length' "$ledger")" = "3" ] \
  || fail "claim scope_files length != 3 (got $(jq -c '."agent-001".scope_files' "$ledger"))"
[ "$(jq -r '."agent-001".forbidden_files | length' "$ledger")" = "2" ] \
  || fail "claim forbidden_files length != 2 (got $(jq -c '."agent-001".forbidden_files' "$ledger"))"
jq -e '."agent-001".scope_files | index("scripts/dispatch_ticket.sh")' "$ledger" >/dev/null \
  || fail "scope_files missing scripts/dispatch_ticket.sh"
jq -e '."agent-001".forbidden_files | index("docs/portfolio.md")' "$ledger" >/dev/null \
  || fail "forbidden_files missing docs/portfolio.md"

# --- Case 3: scope_claim_files emits union across agents ---
dispatch_capacity_write_scope_claim \
  "agent-002" "742" "feat/issue-742" \
  $'scripts/dispatch_plan.sh\nlib/dispatch_capacity.sh' \
  "" \
  "2026-05-20T12:30:00Z" \
  || fail "second write_scope_claim failed"

union=$(dispatch_capacity_scope_claim_files | sort)
expected_union=$'lib/dispatch_capacity.sh\nscripts/brief_agents.sh\nscripts/dispatch_plan.sh\nscripts/dispatch_ticket.sh'
[ "$union" = "$expected_union" ] \
  || fail "scope_claim_files union mismatch: got $union"

# --- Case 4: scope_claim_files excludes a named agent ---
union_excl=$(dispatch_capacity_scope_claim_files "agent-001" | sort)
expected_excl=$'lib/dispatch_capacity.sh\nscripts/dispatch_plan.sh'
[ "$union_excl" = "$expected_excl" ] \
  || fail "scope_claim_files exclude-agent mismatch: got $union_excl"

# --- Case 5: tickets_for_file maps a path to its claiming tickets ---
owners=$(dispatch_capacity_scope_claim_tickets_for_file "lib/dispatch_capacity.sh" | sort)
expected_owners=$'721\n742'
[ "$owners" = "$expected_owners" ] \
  || fail "tickets_for_file mismatch: got $owners"

owners_unique=$(dispatch_capacity_scope_claim_tickets_for_file "scripts/dispatch_ticket.sh")
[ "$owners_unique" = "721" ] \
  || fail "tickets_for_file expected 721 for dispatch_ticket.sh, got $owners_unique"

# --- Case 6: release_scope_claim removes the row, leaves siblings ---
dispatch_capacity_release_scope_claim "agent-001" \
  || fail "release_scope_claim returned non-zero"
remaining=$(jq -r 'keys | sort | .[]' "$ledger" | tr '\n' ' ')
[ "${remaining% }" = "agent-002" ] \
  || fail "agent-001 not released; remaining: $remaining"

# --- Case 7: releasing a non-existent agent is a no-op ---
dispatch_capacity_release_scope_claim "agent-999" \
  || fail "release_scope_claim on missing agent should not error"
remaining_after=$(jq -r 'keys | sort | .[]' "$ledger" | tr '\n' ' ')
[ "${remaining_after% }" = "agent-002" ] \
  || fail "noop release mutated ledger; got $remaining_after"

# --- Case 8: empty ledger -> empty union, no error ---
dispatch_capacity_release_scope_claim "agent-002" \
  || fail "second release returned non-zero"
empty_union=$(dispatch_capacity_scope_claim_files)
[ -z "$empty_union" ] \
  || fail "empty ledger should emit no scope_files; got $empty_union"

# --- Case 9: integration callsites — dispatch_ticket promotes, post_merge_cleanup releases ---
# The lib helpers are wired into the unsanitized scripts at the
# documented integration points. These greps act as a structural lock
# so refactors do not silently sever the promote/release contract.
grep -q 'dispatch_capacity_write_scope_claim' "$ROOT/scripts/dispatch_ticket.sh" \
  || fail "scripts/dispatch_ticket.sh does not call dispatch_capacity_write_scope_claim"
grep -q 'promote_dispatch_assignment' "$ROOT/scripts/dispatch_ticket.sh" \
  || fail "promote_dispatch_assignment missing from dispatch_ticket.sh"
grep -q 'dispatch_capacity_release_scope_claim' "$ROOT/scripts/post_merge_cleanup.sh" \
  || fail "scripts/post_merge_cleanup.sh does not call dispatch_capacity_release_scope_claim"
grep -q 'dispatch_capacity_scope_claim_files' "$ROOT/scripts/brief_agents.sh" \
  || fail "scripts/brief_agents.sh does not consult dispatch_capacity_scope_claim_files"
grep -q '\-\-ignore-scope-claims' "$ROOT/scripts/brief_agents.sh" \
  || fail "scripts/brief_agents.sh does not declare --ignore-scope-claims"
grep -q 'dispatch_plan_compute_conflict_with' "$ROOT/scripts/dispatch_plan.sh" \
  || fail "scripts/dispatch_plan.sh does not compute conflict_with"

printf 'ok - dispatch scope-claim ledger writes, unions, releases, and integrates\n'
