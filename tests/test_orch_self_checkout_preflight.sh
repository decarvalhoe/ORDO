#!/usr/bin/env bash
# test_orch_self_checkout_preflight.sh — coverage for the ORDO self-checkout
# preflight. Verifies that a behind local main and a dirty working tree are
# surfaced with local SHA, upstream SHA, branch, and repo path, and that the
# preflight refuses to proceed silently in both cases.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFLIGHT="$ROOT/scripts/orch_self_checkout_preflight.sh"

TEST_TMP=$(mktemp -d)
cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

[[ -f "$PREFLIGHT" ]] || fail "preflight script missing at $PREFLIGHT"

# Deterministic git identity so commits succeed without relying on host config.
export GIT_AUTHOR_NAME='preflight-test'
export GIT_AUTHOR_EMAIL='preflight-test@example.com'
export GIT_COMMITTER_NAME='preflight-test'
export GIT_COMMITTER_EMAIL='preflight-test@example.com'

UPSTREAM="$TEST_TMP/upstream.git"
LOCAL="$TEST_TMP/local"
SEED="$TEST_TMP/seed"

git init --bare -q -b main "$UPSTREAM"

git init -q -b main "$SEED"
( cd "$SEED" \
    && printf 'one\n' > file.txt \
    && git add file.txt \
    && git commit -q -m seed \
    && git remote add origin "$UPSTREAM" \
    && git push -q -u origin main )

git clone -q "$UPSTREAM" "$LOCAL"
git -C "$LOCAL" checkout -q main

run_preflight() {
  ORCH_SELF_CHECKOUT_REPO="$LOCAL" bash "$PREFLIGHT"
}

# --- Case 1: clean & current ------------------------------------------------
set +e
current_out=$(run_preflight 2>&1)
current_rc=$?
set -e
[[ $current_rc -eq 0 ]] || fail "current: expected rc=0, got rc=$current_rc, out: $current_out"
[[ "$current_out" == *"state:    current"* ]] || fail "current: missing 'state: current', got: $current_out"

# --- Case 2: behind ---------------------------------------------------------
( cd "$SEED" \
    && printf 'two\n' >> file.txt \
    && git add file.txt \
    && git commit -q -m second \
    && git push -q origin main )
git -C "$LOCAL" fetch -q origin

expected_local=$(git -C "$LOCAL" rev-parse HEAD)
expected_upstream=$(git -C "$LOCAL" rev-parse origin/main)
[[ "$expected_local" != "$expected_upstream" ]] \
  || fail "behind: precondition failed — local and upstream SHAs should differ"

set +e
behind_out=$(run_preflight 2>&1)
behind_rc=$?
set -e
[[ $behind_rc -ne 0 ]] \
  || fail "behind: expected non-zero rc, got rc=$behind_rc, out: $behind_out"
[[ "$behind_out" == *"state:    behind"* ]] \
  || fail "behind: missing 'state: behind', got: $behind_out"
[[ "$behind_out" == *"$expected_local"* ]] \
  || fail "behind: missing local SHA $expected_local, got: $behind_out"
[[ "$behind_out" == *"$expected_upstream"* ]] \
  || fail "behind: missing upstream SHA $expected_upstream, got: $behind_out"
[[ "$behind_out" == *"branch:   main"* ]] \
  || fail "behind: missing branch, got: $behind_out"
[[ "$behind_out" == *"repo:     $LOCAL"* ]] \
  || fail "behind: missing repo path, got: $behind_out"
[[ "$behind_out" == *"refuse to proceed"* ]] \
  || fail "behind: must emit block message, got: $behind_out"

# Operator override demotes the block to a warning and exits 0.
set +e
allow_out=$(ORCH_SELF_CHECKOUT_REPO="$LOCAL" ORCH_SELF_CHECKOUT_ALLOW_STALE=1 \
              bash "$PREFLIGHT" 2>&1)
allow_rc=$?
set -e
[[ $allow_rc -eq 0 ]] \
  || fail "allow-stale override: expected rc=0, got rc=$allow_rc, out: $allow_out"
[[ "$allow_out" == *"operator override"* ]] \
  || fail "allow-stale: missing override notice, got: $allow_out"

# --- Case 3: dirty ----------------------------------------------------------
# Catch up first so the dirty signal is isolated from the behind signal.
git -C "$LOCAL" pull -q --ff-only origin main
printf 'dirty\n' >> "$LOCAL/file.txt"

dirty_local=$(git -C "$LOCAL" rev-parse HEAD)

set +e
dirty_out=$(run_preflight 2>&1)
dirty_rc=$?
set -e
[[ $dirty_rc -ne 0 ]] \
  || fail "dirty: expected non-zero rc, got rc=$dirty_rc, out: $dirty_out"
[[ "$dirty_out" == *"state:    dirty"* ]] \
  || fail "dirty: missing 'state: dirty', got: $dirty_out"
[[ "$dirty_out" == *"branch:   main"* ]] \
  || fail "dirty: missing branch, got: $dirty_out"
[[ "$dirty_out" == *"repo:     $LOCAL"* ]] \
  || fail "dirty: missing repo path, got: $dirty_out"
[[ "$dirty_out" == *"$dirty_local"* ]] \
  || fail "dirty: missing local SHA $dirty_local, got: $dirty_out"
[[ "$dirty_out" == *"refuse to proceed"* ]] \
  || fail "dirty: must emit block message, got: $dirty_out"

printf 'ok - orch_self_checkout_preflight surfaces behind and dirty state\n'
