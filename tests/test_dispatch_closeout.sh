#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

template="$ROOT/templates/dispatch-canonical.md.tpl"
doc="$ROOT/docs/dispatch-planning.md"

grep -Fq 'Closeout final base guard' "$template" || \
  fail "dispatch template must require a closeout final base guard"
grep -Fq 'apres la validation et immediatement avant le rapport final' "$template" || \
  fail "final base recheck must happen after validation and before final report"
grep -Fq 'stale-base' "$template" || \
  fail "dispatch template must require stale-base reporting when base advances"

grep -Fq 'Closeout Final Base Guard' "$doc" || \
  fail "dispatch planning doc must describe the closeout final base guard"
grep -Fq 'origin/main advances while validation runs' "$doc" || \
  fail "dispatch planning doc must include the concurrent main advance POC"

git -c init.defaultBranch=main init --bare "$TEST_TMP/origin.git" >/dev/null
git -c init.defaultBranch=main init "$TEST_TMP/seed" >/dev/null
git -C "$TEST_TMP/seed" config user.name "Dispatch Closeout Test"
git -C "$TEST_TMP/seed" config user.email "dispatch-closeout@test.local"
printf 'seed\n' > "$TEST_TMP/seed/README.md"
git -C "$TEST_TMP/seed" add README.md
git -C "$TEST_TMP/seed" commit -m "seed" >/dev/null
git -C "$TEST_TMP/seed" remote add origin "$TEST_TMP/origin.git"
git -C "$TEST_TMP/seed" push -q -u origin main >/dev/null

git clone -q "$TEST_TMP/origin.git" "$TEST_TMP/worker" >/dev/null 2>&1
git -C "$TEST_TMP/worker" checkout -q -b feat/closeout origin/main >/dev/null
initial_base=$(git -C "$TEST_TMP/worker" rev-parse origin/main)

printf 'validation ran on initial base\n' > "$TEST_TMP/validation.log"

printf 'main advanced\n' >> "$TEST_TMP/seed/README.md"
git -C "$TEST_TMP/seed" add README.md
git -C "$TEST_TMP/seed" commit -m "advance main during closeout" >/dev/null
git -C "$TEST_TMP/seed" push -q origin main >/dev/null

git -C "$TEST_TMP/worker" fetch -q origin >/dev/null
final_base=$(git -C "$TEST_TMP/worker" rev-parse origin/main)
[[ "$initial_base" != "$final_base" ]] || \
  fail "concurrent main advance POC did not advance origin/main"
if git -C "$TEST_TMP/worker" merge-base --is-ancestor "$final_base" HEAD; then
  fail "worker branch should be stale after origin/main advances during closeout"
fi

report="$TEST_TMP/report.txt"
printf 'base: origin/main @ %s (stale-base; final base advanced from %s after validation)\n' \
  "$final_base" "$initial_base" > "$report"
grep -Fq 'stale-base' "$report" || fail "POC report must mark stale base"

printf 'ok - dispatch closeout requires final base guard and stale-base reporting\n'
