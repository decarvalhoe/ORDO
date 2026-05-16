#!/usr/bin/env bash
# tests/test_dispatch_unknown_scope_refusal.sh — coverage for ORDO #488.
#
# With `ORDO_SCOPE_REFUSE_UNKNOWN=1`, `scripts/dispatch_ticket.sh` MUST
# refuse dispatch BEFORE assignment persistence and BEFORE any tmux pane
# writes when the rendered brief carries `scope classification: unknown`
# or `out_of_scope`. Otherwise
# the orchestrator marks a lane occupied while the worker short-circuits
# on needs_scope_clarification, leaving the assignments ledger stale and
# the lane appearing busy while doing no work.
#
# The test has two sections:
#
#   Section A (fast unit checks on lib/scope_check.sh, sub-second)
#     Exercises `ordo_scope_brief_classification`,
#     `ordo_scope_brief_active_key`, and `ordo_scope_dispatch_preflight`
#     directly against synthetic brief fixtures covering the full
#     classification taxonomy: unknown, out_of_scope, in_scope, held,
#     and missing-block (legacy brief). Fast unit checks keep the
#     contract surface fully covered even when the heavy dispatch
#     smoke is host-load bound.
#
#   Section B (focused dispatch smoke, two cases)
#     Runs `scripts/dispatch_ticket.sh` end-to-end in dry-run, with
#     stubbed gh and tmux, against one refusal brief (unknown) and one
#     proceed brief (in_scope). Proves the dispatch wiring routes a
#     scope_unknown brief into the structured DISPATCH REFUSED audit
#     line + exit 82, and that an in_scope brief crosses the preflight
#     to the dry-run `record assignment` note. The out_of_scope refusal
#     path is exercised in section A (same code branch in
#     ordo_scope_dispatch_preflight, same exit/audit shape).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() {
  rm -rf "$TEST_TMP"
  rm -f /tmp/dispatch-claude-8801.md /tmp/dispatch-claude-8803.md
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" \
  "$TEST_TMP/bin" "$TEST_TMP/logs" "$TEST_TMP/briefs"

# ---------------------------------------------------------------------------
# Section A — unit checks on lib/scope_check.sh helpers.
# ---------------------------------------------------------------------------
# Source the live library and exercise it against synthetic fixtures
# that mirror the rendered Scope Posture block.
# shellcheck disable=SC1090
source "$ROOT/lib/scope_check.sh"
export ORDO_SCOPE_REFUSE_UNKNOWN=1

make_brief_fixture() {
  local classification=$1 active_key=$2 path=$3
  cat > "$path" <<EOF
# Dispatch fixture

## Scope Posture

- active project key: \`${active_key}\`
- active repo: \`RBOKproject/ORDO\`
- active branch: \`main\`
- scope classification: \`${classification}\`
- in-scope project keys (allowlist): \`<none-configured>\`
EOF
}

unit_unknown="$TEST_TMP/briefs/unit-unknown.md"
unit_out="$TEST_TMP/briefs/unit-out.md"
unit_in="$TEST_TMP/briefs/unit-in.md"
unit_held="$TEST_TMP/briefs/unit-held.md"
unit_missing="$TEST_TMP/briefs/unit-missing.md"
make_brief_fixture unknown      legacy-key  "$unit_unknown"
make_brief_fixture out_of_scope legacy-key  "$unit_out"
make_brief_fixture in_scope     legacy-key  "$unit_in"
make_brief_fixture held         legacy-key  "$unit_held"
cat > "$unit_missing" <<'EOF'
# Legacy brief without a Scope Posture block (pre-#343).

## Objectif

Synthetic missing-block fixture.
EOF

# Classification extraction.
[ "$(ordo_scope_brief_classification "$unit_unknown")" = "unknown" ] \
  || fail "unit — brief_classification(unknown) wrong"
[ "$(ordo_scope_brief_classification "$unit_out")" = "out_of_scope" ] \
  || fail "unit — brief_classification(out_of_scope) wrong"
[ "$(ordo_scope_brief_classification "$unit_in")" = "in_scope" ] \
  || fail "unit — brief_classification(in_scope) wrong"
[ "$(ordo_scope_brief_classification "$unit_held")" = "held" ] \
  || fail "unit — brief_classification(held) wrong"
[ "$(ordo_scope_brief_classification "$unit_missing")" = "missing" ] \
  || fail "unit — brief_classification(missing) wrong"

# Active key extraction.
[ "$(ordo_scope_brief_active_key "$unit_unknown")" = "legacy-key" ] \
  || fail "unit — brief_active_key(unknown) wrong"
[ -z "$(ordo_scope_brief_active_key "$unit_missing")" ] \
  || fail "unit — brief_active_key(missing) must be empty"

# Dispatch preflight — refuses unknown / out_of_scope, allows
# in_scope / held / missing.
set +e
ordo_scope_dispatch_preflight "$unit_unknown" 2>/dev/null
rc=$?
set -e
[ "$rc" -eq 1 ] \
  || fail "unit — dispatch_preflight(unknown) must return 1, got $rc"
[ "$ORDO_SCOPE_DISPATCH_PREFLIGHT_CLASSIFICATION" = "unknown" ] \
  || fail "unit — dispatch_preflight(unknown) classification global wrong"
[ "$ORDO_SCOPE_DISPATCH_PREFLIGHT_ACTIVE_KEY" = "legacy-key" ] \
  || fail "unit — dispatch_preflight(unknown) active_key global wrong"

set +e
ordo_scope_dispatch_preflight "$unit_out" 2>/dev/null
rc=$?
set -e
[ "$rc" -eq 1 ] \
  || fail "unit — dispatch_preflight(out_of_scope) must return 1, got $rc"
[ "$ORDO_SCOPE_DISPATCH_PREFLIGHT_CLASSIFICATION" = "out_of_scope" ] \
  || fail "unit — dispatch_preflight(out_of_scope) classification global wrong"

set +e
ordo_scope_dispatch_preflight "$unit_in" 2>/dev/null
rc=$?
set -e
[ "$rc" -eq 0 ] \
  || fail "unit — dispatch_preflight(in_scope) must return 0, got $rc"

set +e
ordo_scope_dispatch_preflight "$unit_held" 2>/dev/null
rc=$?
set -e
[ "$rc" -eq 0 ] \
  || fail "unit — dispatch_preflight(held) must return 0, got $rc"

set +e
ordo_scope_dispatch_preflight "$unit_missing" 2>/dev/null
rc=$?
set -e
[ "$rc" -eq 0 ] \
  || fail "unit — dispatch_preflight(missing) must return 0 (legacy brief), got $rc"

# Refusal stderr carries the structured needs_scope_clarification line
# so the orchestrator can pattern-match against it.
preflight_stderr=$(ordo_scope_dispatch_preflight "$unit_unknown" 2>&1 >/dev/null || true)
[[ "$preflight_stderr" == *"needs_scope_clarification"* ]] \
  || fail "unit — dispatch_preflight(unknown) stderr missing 'needs_scope_clarification': $preflight_stderr"
[[ "$preflight_stderr" == *"classification=unknown"* ]] \
  || fail "unit — dispatch_preflight(unknown) stderr missing 'classification=unknown': $preflight_stderr"

# ---------------------------------------------------------------------------
# Section B — focused dispatch_ticket.sh integration smoke (2 cases).
# ---------------------------------------------------------------------------
# Sanitize a copy of the toolkit (CRLF→LF) so dispatch_ticket.sh runs
# cleanly under Windows-checkout repos.
for rel in \
  scripts/dispatch_ticket.sh \
  lib/api_rate_limiter.sh \
  lib/audit_log.sh \
  lib/log_bounds.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/dispatch_router.sh \
  lib/dispatch_workdir_preflight.sh \
  lib/dry_run.sh \
  lib/external_mutation_gate.sh \
  lib/github_identity.sh \
  lib/host_load_gate.sh \
  lib/portfolio_config.sh \
  lib/process_safety.sh \
  lib/prompt_integrity.sh \
  lib/mcp_permission_preflight.sh \
  lib/recovery_context.sh \
  lib/scope_check.sh \
  lib/state_persist.sh \
  lib/tmux_helpers.sh \
  lib/worktree_helpers.sh
do
  if [ -f "$ROOT/$rel" ]; then
    tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
  fi
done
chmod +x "$SANITIZED_ROOT/scripts/dispatch_ticket.sh"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="dispatch-unknown-scope-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worktrees/%s"
EOF

# gh stub : every issue is OPEN so the closed-issue guard never fires
# and the scope preflight is the only refusal path under test.
cat > "$TEST_TMP/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"issue view"*) printf '%s\n' '{"state":"OPEN","closedAt":""}' ;;
  *"pr view"*) exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

# tmux stub : no-op. ORCH_DRY_RUN=1 below already suppresses tmux
# mutations in dispatch_ticket.sh; the stub is defense-in-depth.
cat > "$TEST_TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

# Canonical brief — satisfies validate_canonical_prompt AND carries a
# controlled Scope Posture block. The classification token is the
# actionable signal the preflight reads.
make_brief() {
  local agent=$1 ticket=$2 classification=$3 path=$4
  cat > "$path" <<EOF
# Dispatch — agent=${agent} ticket=#${ticket}

## Scope Posture

- active project key: \`dispatch-unknown-scope-test\`
- active repo: \`RBOKproject/ORDO\`
- active branch: \`main\`
- scope classification: \`${classification}\`
- in-scope project keys (allowlist): \`<none-configured>\`
- held project keys (work paused, awaiting external gate): \`<none>\`
- out-of-scope project keys (forbidden for autonomous dispatch): \`<none>\`

## Objectif

Synthetic fixture for ORDO #488.

## Format de sortie attendu

n/a — fixture brief.

## Tools / sources autorises

- bash

## Boundaries / interdictions

- fixture brief, no real mutations.

## Definition of Done verifiable

- [ ] fixture executed.

## Preuves attendues

- audit log lines.
EOF
}

run_dispatch() {
  local prompt=$1
  local ticket=$2
  shift 2
  # BASH_ENV=/dev/null neutralizes any inherited agent-identity hook
  # that would otherwise call `tmux display-message` and recurse
  # through our bash-shebanged tmux stub. Hermetic by construction:
  # CI never sets BASH_ENV, so this is a no-op there; locally it
  # short-circuits the recursion.
  PATH="$TEST_TMP/bin:$PATH" \
  BASH_ENV=/dev/null \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_DRY_RUN=1 \
  ORCH_LOAD_GATE_MODE=off \
  "$@" \
    bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" \
      "$TEST_TMP/test.config.sh" claude "$ticket" "$prompt"
}

audit_log="$TEST_TMP/logs/dispatch-unknown-scope-test.log"

# Case 1: classification=unknown — dispatch MUST refuse.
brief1="$TEST_TMP/dispatch-claude-8801.md"
make_brief claude 8801 unknown "$brief1"
set +e
out1=$(run_dispatch "$brief1" 8801 2>&1)
rc1=$?
set -e

[ "$rc1" -eq 82 ] \
  || fail "case 1 (unknown) — expected exit 82, got $rc1: $out1"

[[ "$out1" == *"REFUSED #8801"*"scope classification unknown"* ]] \
  || fail "case 1 (unknown) — expected 'REFUSED #8801 — scope classification unknown' on stderr, got: $out1"

[[ "$out1" == *"needs_scope_clarification"* ]] \
  || fail "case 1 (unknown) — expected 'needs_scope_clarification' line on stderr, got: $out1"

if ! grep -q 'DISPATCH REFUSED reason=scope_unknown.*ticket=#8801' "$audit_log" 2>/dev/null; then
  fail "case 1 (unknown) — expected audit line 'DISPATCH REFUSED reason=scope_unknown ticket=#8801', got: $(cat "$audit_log" 2>/dev/null)"
fi

# The dry-run `record assignment` note is emitted at line 1005 of
# dispatch_ticket.sh, AFTER all the preflights. If the scope guard ran,
# the note must NOT appear in dispatch output.
if printf '%s\n' "$out1" | grep -q 'DRY-RUN: record assignment'; then
  fail "case 1 (unknown) — scope refusal must short-circuit before 'record assignment'; got: $out1"
fi

# /tmp staging happens after canonical validation. Confirm the brief
# was never copied into /tmp — proof that no post-refusal side effect
# escaped.
if [ -f /tmp/dispatch-claude-8801.md ]; then
  fail "case 1 (unknown) — /tmp/dispatch-claude-8801.md must NOT exist after scope refusal"
fi

# Case 2: classification=in_scope — scope guard must let dispatch
# proceed. Downstream dry-run flow records the assignment note; we
# assert ONLY that the scope refusal did not fire and the dispatch
# crossed the preflight successfully.
brief3="$TEST_TMP/dispatch-claude-8803.md"
make_brief claude 8803 in_scope "$brief3"
set +e
out3=$(run_dispatch "$brief3" 8803 2>&1)
set -e

[[ "$out3" != *"REFUSED #8803"*"scope classification"* ]] \
  || fail "case 2 (in_scope) — must NOT trigger scope refusal, got: $out3"

if grep -q 'DISPATCH REFUSED reason=scope_.*ticket=#8803' "$audit_log" 2>/dev/null; then
  fail "case 2 (in_scope) — expected NO 'DISPATCH REFUSED reason=scope_*' audit for in_scope, got: $(cat "$audit_log")"
fi

if ! printf '%s\n' "$out3" | grep -q 'DRY-RUN: record assignment'; then
  fail "case 2 (in_scope) — expected dispatch to proceed past scope preflight to dry-run 'record assignment'; got: $out3"
fi

printf 'ok - dispatch_ticket refuses unknown/out_of_scope before assignment persistence (5 unit + 2 dispatch smoke)\n'
