#!/usr/bin/env bash
# Issue #721: dispatch_ticket --auto-recover behaviour.
#
# Without --auto-recover the exit-code contract is unchanged: a stale
# pinned base exits 81 ("stale base, regenerate the brief") and a
# context mismatch after dispatch exits 76. With --auto-recover:
#
#   - exit 81 path: the brief is auto-rerendered in-place by swapping
#     the stale pinned SHA for the fresh origin/<default> SHA, and an
#     explicit `DISPATCH AUTO_RECOVER STALE_BASE` audit row is emitted.
#     Dispatch then continues with the regenerated brief.
#
#   - exit 76 path: dispatch_ticket sends `cd <workdir>` Enter into the
#     agent pane, waits for the settle delay, re-runs the context proof
#     once, and emits an explicit `DISPATCH AUTO_RECOVER CONTEXT_MISMATCH`
#     audit row. A second failure falls through to the canonical exit 76
#     so callers still see the contract signal.
#
# These two flows are exercised with narrow shell-only fixtures and
# stubs (no tmux, no gh, no real worktree handshake). The test asserts
# auditing and SHA rewrite behaviour rather than the entire dispatch
# pipeline, which has dedicated coverage in test_dispatch_ticket.sh.

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

# ---------------------------------------------------------------------------
# 1) Default-off contract: without --auto-recover the rewrite helper
#    must leave the brief untouched and dispatch_assert_pinned_base
#    must return the canonical 81 / 82 exit codes.
# ---------------------------------------------------------------------------

OLD_SHA=$(printf '%040d' 1)
NEW_SHA=$(printf '%040d' 2)

# Source the auto-recover helpers directly from dispatch_ticket.sh by
# extracting the two helper functions into an evaluable stub. The
# helpers are pure shell (no external state) so this isolated load is
# enough to verify the rewrite contract.
sed -n '/^dispatch_auto_recover_rewrite_pinned_base()/,/^}/p' \
  "$ROOT/scripts/dispatch_ticket.sh" > "$TEST_TMP/auto_recover.sh"
sed -n '/^dispatch_auto_recover_send_cd()/,/^}/p' \
  "$ROOT/scripts/dispatch_ticket.sh" >> "$TEST_TMP/auto_recover.sh"

# Pull in the helpers and exercise the rewrite contract.
# shellcheck disable=SC1090
source "$TEST_TMP/auto_recover.sh"

brief="$TEST_TMP/brief.md"
cat > "$brief" <<EOF
accepted immutable base: origin/main at $OLD_SHA
helper: git cat-file -e ${OLD_SHA}^{commit}
helper: git merge-base --is-ancestor $OLD_SHA origin/main
EOF

# Same-SHA / missing-file / empty input must all refuse the rewrite so
# we never silently corrupt an unrelated file.
if dispatch_auto_recover_rewrite_pinned_base "$brief" "$OLD_SHA" "$OLD_SHA" 2>/dev/null; then
  fail "rewrite should refuse when old==new"
fi
if dispatch_auto_recover_rewrite_pinned_base "$TEST_TMP/missing-brief.md" "$OLD_SHA" "$NEW_SHA" 2>/dev/null; then
  fail "rewrite should refuse when prompt file is missing"
fi

dispatch_auto_recover_rewrite_pinned_base "$brief" "$OLD_SHA" "$NEW_SHA" \
  || fail "rewrite returned non-zero for valid inputs"

if grep -F "$OLD_SHA" "$brief" >/dev/null; then
  fail "old SHA still present after rewrite: $(cat "$brief")"
fi
grep -F "$NEW_SHA" "$brief" >/dev/null \
  || fail "new SHA missing after rewrite: $(cat "$brief")"

# ---------------------------------------------------------------------------
# 2) Stale-base auto-recover via the dispatch_assert_pinned_base
#    freshness helper. We exercise the function in isolation against a
#    temporary git workdir whose origin/main has advanced past the
#    pinned SHA. With AUTO_RECOVER=0 the function returns 81 and leaves
#    the brief alone; with AUTO_RECOVER=1 the brief is rewritten and
#    the function returns 0.
# ---------------------------------------------------------------------------

git_origin="$TEST_TMP/origin.git"
seed="$TEST_TMP/seed"
workdir="$TEST_TMP/workdir"
git init --bare -b main "$git_origin" >/dev/null 2>&1 \
  || git init --bare "$git_origin" >/dev/null
# Force the bare repo's default ref to `main` so the clone below
# auto-checks out main even on hosts whose init.defaultBranch differs.
git -C "$git_origin" symbolic-ref HEAD refs/heads/main 2>/dev/null || true
git init -b main "$seed" >/dev/null 2>&1 || git init "$seed" >/dev/null
git -C "$seed" config user.email "test@local"
git -C "$seed" config user.name "Test"
git -C "$seed" checkout -b main >/dev/null 2>&1 || true
printf 'first\n' > "$seed/README.md"
git -C "$seed" add README.md
git -C "$seed" commit -m "first" >/dev/null
git -C "$seed" remote add origin "$git_origin"
git -C "$seed" push -u origin main >/dev/null
PINNED_SHA=$(git -C "$seed" rev-parse HEAD)
printf 'second\n' >> "$seed/README.md"
git -C "$seed" add README.md
git -C "$seed" commit -m "advance" >/dev/null
git -C "$seed" push origin main >/dev/null
CURRENT_SHA=$(git -C "$seed" rev-parse HEAD)
git clone --branch main "$git_origin" "$workdir" >/dev/null 2>&1

stale_brief="$TEST_TMP/stale.md"
cat > "$stale_brief" <<EOF
accepted immutable base: origin/main at $PINNED_SHA
helper: git cat-file -e ${PINNED_SHA}^{commit}
EOF

# Stub `audit` so we can capture the structured audit row that the
# helper emits when it activates AUTO_RECOVER.
audit_log="$TEST_TMP/audit.log"
: > "$audit_log"
audit() { printf '%s\n' "$*" >> "$audit_log"; }
export -f audit

# Pull the freshness helper from dispatch_ticket.sh together with the
# pinned-SHA extractor it relies on; both are pure shell.
sed -n '/^dispatch_extract_pinned_base_sha()/,/^}/p' \
  "$ROOT/scripts/dispatch_ticket.sh" > "$TEST_TMP/freshness.sh"
sed -n '/^dispatch_assert_pinned_base_freshness()/,/^}/p' \
  "$ROOT/scripts/dispatch_ticket.sh" >> "$TEST_TMP/freshness.sh"
# shellcheck disable=SC1090
source "$TEST_TMP/freshness.sh"

AGENT="agent-x"
TICKET_NUM=900
# DEFAULT_BRANCH and AUTO_RECOVER are read by dispatch_assert_pinned_base_freshness
# (sourced from scripts/dispatch_ticket.sh). shellcheck does not track that, hence:
# shellcheck disable=SC2034
DEFAULT_BRANCH="main"
# shellcheck disable=SC2034
AUTO_RECOVER=0

set +e
dispatch_assert_pinned_base_freshness "$stale_brief" "$workdir"
rc=$?
set -e
[[ "$rc" == "81" ]] \
  || fail "expected exit 81 with AUTO_RECOVER=0, got $rc"
grep -F "$PINNED_SHA" "$stale_brief" >/dev/null \
  || fail "AUTO_RECOVER=0 must not rewrite the brief"
grep -q 'DISPATCH BASE_STALE_REFRESH' "$audit_log" \
  || fail "expected BASE_STALE_REFRESH audit row, got: $(cat "$audit_log")"

# Reset and re-run with AUTO_RECOVER=1. The brief must be rewritten to
# the current SHA and the helper must return 0 so dispatch continues.
: > "$audit_log"
# shellcheck disable=SC2034
AUTO_RECOVER=1
set +e
dispatch_assert_pinned_base_freshness "$stale_brief" "$workdir"
rc=$?
set -e
[[ "$rc" == "0" ]] \
  || fail "expected exit 0 with AUTO_RECOVER=1, got $rc"
if grep -F "$PINNED_SHA" "$stale_brief" >/dev/null; then
  fail "AUTO_RECOVER=1 should have replaced the stale SHA: $(cat "$stale_brief")"
fi
grep -F "$CURRENT_SHA" "$stale_brief" >/dev/null \
  || fail "AUTO_RECOVER=1 should have inserted the fresh SHA: $(cat "$stale_brief")"
grep -q 'DISPATCH AUTO_RECOVER STALE_BASE' "$audit_log" \
  || fail "expected AUTO_RECOVER STALE_BASE audit row: $(cat "$audit_log")"

# ---------------------------------------------------------------------------
# 3) Context-mismatch cd-and-retry: dispatch_auto_recover_send_cd must
#    forward `cd <workdir>` Enter to the pane via tmux, return 0 on
#    success, and short-circuit silently when tmux is unavailable.
# ---------------------------------------------------------------------------

tmux_log="$TEST_TMP/tmux.log"
: > "$tmux_log"
mkdir -p "$TEST_TMP/bin"
cat > "$TEST_TMP/bin/tmux" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$tmux_log"
EOF
chmod +x "$TEST_TMP/bin/tmux"

# Minimal orch_run_timeout stub: just exec.
orch_run_timeout() {
  shift
  "$@"
}
export -f orch_run_timeout

# Both read by dispatch_auto_recover_send_cd (sourced from scripts/dispatch_ticket.sh).
# shellcheck disable=SC2034
ORCH_TMUX_TIMEOUT_SEC=2
# shellcheck disable=SC2034
ORCH_DISPATCH_AUTO_RECOVER_SETTLE_SEC=0
PATH="$TEST_TMP/bin:$PATH" dispatch_auto_recover_send_cd "fleet:0.0" "/workdir/example"

grep -q "send-keys -t fleet:0.0 cd /workdir/example Enter" "$tmux_log" \
  || fail "tmux send-keys was not invoked with cd + Enter: $(cat "$tmux_log")"

# Without tmux on PATH the helper must short-circuit safely (no
# exceptions, no audit), returning non-zero so the caller knows the cd
# attempt did not land.
if PATH="/no-tmux:/usr/bin:/bin" dispatch_auto_recover_send_cd \
    "fleet:0.0" "/workdir/example" 2>/dev/null; then
  fail "send_cd helper should fail when tmux is missing"
fi

printf 'ok - dispatch_ticket --auto-recover rewrites stale-base briefs and tmux-cd retries on context mismatch\n'
