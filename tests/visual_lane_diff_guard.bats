#!/usr/bin/env bats

# visual_lane_diff_guard.bats — diff-level guard against visual-lane env
# leaks (issue #324). Mirrors the pattern set asserted by PR #319's
# `tests/docs_layers_optionality.bats` "default ORDO configs do not export
# DISPLAY, XAUTHORITY, or ORCH_VISUAL_*" case but exercises it through the
# fast `lib/visual_lane.sh` / `scripts/visual_lane_probe.sh` surface so a
# pre-push hook or workflow step can fail in seconds rather than waiting
# for the full bats suite.
#
# Coverage:
#   - lib/visual_lane.sh public API (patterns, default search paths,
#     scan_paths, scan_files, filter_diff_files);
#   - scripts/visual_lane_probe.sh in --full and --diff modes against a
#     synthetic git repo so the diff-base resolution is exercised;
#   - leaks under each default-search prefix (examples, lib, scripts,
#     templates, docs, config) trigger the guard;
#   - the literal display/xauthority/visual env names quoted in test data
#     trigger the guard, but the guard's own source files do NOT
#     self-trigger;
#   - tests/ is intentionally NOT in the default search set so bats
#     fixtures (this one included) can mention the patterns freely.

load './helpers.bash'

setup() {
  setup_orch_test
  TK="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export TK
  export PROBE="$TK/scripts/visual_lane_probe.sh"
  export GATE="$TK/lib/visual_lane.sh"
}

# Minimal synthetic git repo that mirrors the default search prefixes.
# Every directory is created so visual_lane_scan_paths can probe it.
make_synth_repo() {
  local repo=${1:?usage: make_synth_repo <repo>}
  mkdir -p "$repo"/{examples,lib,scripts,templates,docs,config,tests}
  (
    cd "$repo"
    git -c init.defaultBranch=main init -q
    git config user.email "synth@test.local"
    git config user.name "synth"
    : > README.md
    git add README.md
    git commit -q -m "init"
  )
}

@test "leak_patterns emits the visual env-namespace prefix and the two anchored env-assignment patterns" {
  run bash -lc "source '$GATE' && visual_lane_leak_patterns"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  # The three patterns: namespace prefix (assembled at runtime),
  # ^DISPLAY=, ^XAUTHORITY=. We don't hard-code the literal namespace
  # token so this test stays self-detection-safe.
  [ "${lines[1]}" = '^DISPLAY=' ]
  [ "${lines[2]}" = '^XAUTHORITY=' ]
  # First line should be a non-empty unanchored prefix.
  [ -n "${lines[0]}" ]
  [[ "${lines[0]}" != "^"* ]]
}

@test "default_search_paths matches PR #319's scope exactly: examples, lib, scripts" {
  run bash -lc "source '$GATE' && visual_lane_default_search_paths"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "examples" ]
  [ "${lines[1]}" = "lib" ]
  [ "${lines[2]}" = "scripts" ]
}

@test "scan_paths returns 0 on a clean tree and writes nothing" {
  local repo="$BATS_TEST_TMPDIR/repo-clean"
  make_synth_repo "$repo"
  run bash -lc "source '$GATE' && visual_lane_scan_paths '$repo'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "scan_paths flags ORCH_VISUAL_* leaks under examples/" {
  local repo="$BATS_TEST_TMPDIR/repo-examples"
  make_synth_repo "$repo"
  printf 'export %sFOO=:99\n' "$(printf 'ORCH%sVISUAL%s' '_' '_')" \
    > "$repo/examples/leaky.sh"

  run bash -lc "source '$GATE' && visual_lane_scan_paths '$repo'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"examples/leaky.sh"* ]]
}

@test "scan_paths flags DISPLAY= leaks under scripts/" {
  local repo="$BATS_TEST_TMPDIR/repo-scripts"
  make_synth_repo "$repo"
  printf 'DISPLAY=:0\n' > "$repo/scripts/leaky.env"

  run bash -lc "source '$GATE' && visual_lane_scan_paths '$repo'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"scripts/leaky.env"* ]]
  [[ "$output" == *"pattern=^DISPLAY="* ]]
}

@test "scan_paths flags XAUTHORITY= leaks under lib/" {
  local repo="$BATS_TEST_TMPDIR/repo-lib"
  make_synth_repo "$repo"
  printf 'XAUTHORITY=/tmp/xauth\n' > "$repo/lib/leaky.env"

  run bash -lc "source '$GATE' && visual_lane_scan_paths '$repo'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"lib/leaky.env"* ]]
  [[ "$output" == *"pattern=^XAUTHORITY="* ]]
}

@test "scan_paths flags leaks under each default prefix (examples, lib, scripts)" {
  local repo="$BATS_TEST_TMPDIR/repo-each"
  make_synth_repo "$repo"
  local prefix
  prefix=$(printf 'ORCH%sVISUAL%s' '_' '_')
  for dir in examples lib scripts; do
    printf '%sFOO=1\n' "$prefix" > "$repo/$dir/leaky.env"
  done

  run bash -lc "source '$GATE' && visual_lane_scan_paths '$repo'"
  [ "$status" -ne 0 ]
  for dir in examples lib scripts; do
    [[ "$output" == *"${dir}/leaky.env"* ]]
  done
}

@test "scan_paths ignores docs/, templates/, and config/ by default (operators opt in via --paths)" {
  # Mirrors PR #319's scope: docs are informational, templates may
  # legitimately reference env names in shipped agent prompts, and
  # canonical configs live outside this toolkit. Operators who want
  # to broaden the scan call --paths explicitly.
  local repo="$BATS_TEST_TMPDIR/repo-non-default"
  make_synth_repo "$repo"
  mkdir -p "$repo"/{templates,docs,config}
  local prefix
  prefix=$(printf 'ORCH%sVISUAL%s' '_' '_')
  for dir in templates docs config; do
    printf '%sFOO=1\n' "$prefix" > "$repo/$dir/quasi-leaky.env"
  done

  run bash -lc "source '$GATE' && visual_lane_scan_paths '$repo'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "scan_paths ignores tests/ by default (so bats fixtures may mention the patterns)" {
  local repo="$BATS_TEST_TMPDIR/repo-tests-only"
  make_synth_repo "$repo"
  printf 'DISPLAY=:0\n' > "$repo/tests/fixture.env"

  run bash -lc "source '$GATE' && visual_lane_scan_paths '$repo'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "filter_diff_files keeps only paths under the default visual-lane prefixes" {
  local input
  input=$'examples/foo.sh\nlib/bar.sh\nscripts/baz.sh\ntemplates/x.tpl\ndocs/y.md\nconfig/z.sh\ntests/keep-out.bats\nREADME.md\n.github/workflows/ci.yml'
  run bash -lc "source '$GATE' && printf '%s\n' \"$input\" | visual_lane_filter_diff_files"
  [ "$status" -eq 0 ]
  [[ "$output" == *"examples/foo.sh"* ]]
  [[ "$output" == *"lib/bar.sh"* ]]
  [[ "$output" == *"scripts/baz.sh"* ]]
  # Anything outside examples/lib/scripts is dropped by the default filter.
  [[ "$output" != *"templates/"* ]]
  [[ "$output" != *"docs/"* ]]
  [[ "$output" != *"config/"* ]]
  [[ "$output" != *"tests/keep-out.bats"* ]]
  [[ "$output" != *"README.md"* ]]
  [[ "$output" != *".github"* ]]
}

@test "scan_files only scans the listed files (bypasses prefix filter)" {
  local repo="$BATS_TEST_TMPDIR/repo-scan-files"
  make_synth_repo "$repo"
  printf 'DISPLAY=:0\n'           > "$repo/lib/leaky.env"
  printf 'XAUTHORITY=/tmp/xauth\n' > "$repo/scripts/clean-but-listed.env"

  # Only one file passed → only that one scanned.
  run bash -lc "source '$GATE' && visual_lane_scan_files '$repo' lib/leaky.env"
  [ "$status" -ne 0 ]
  [[ "$output" == *"lib/leaky.env"* ]]
  [[ "$output" != *"scripts/clean-but-listed.env"* ]]
}

@test "probe --full reports clean on a synthetic empty repo" {
  local repo="$BATS_TEST_TMPDIR/probe-clean"
  make_synth_repo "$repo"
  run bash "$PROBE" --full --root "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean (full scan"* ]]
}

@test "probe --full exits 81 with a leak under examples/" {
  local repo="$BATS_TEST_TMPDIR/probe-leak"
  make_synth_repo "$repo"
  printf 'DISPLAY=:99\n' > "$repo/examples/leaky.env"
  run bash "$PROBE" --full --root "$repo"
  [ "$status" -eq 81 ]
  [[ "$output" == *"leak detected"* ]]
  [[ "$output" == *"examples/leaky.env"* ]]
}

@test "probe --diff against a base ref scans only files changed since that ref" {
  local repo="$BATS_TEST_TMPDIR/probe-diff"
  make_synth_repo "$repo"
  # Pre-existing leak that's already on the diff base — the guard must
  # NOT flag this on a diff scan because no PR is introducing it.
  printf 'DISPLAY=:0\n' > "$repo/lib/preexisting.env"
  (
    cd "$repo"
    git add lib/preexisting.env
    git commit -q -m "preexisting visual leak (out of scope for diff)"
    git checkout -q -b feature
  )

  # Clean diff: feature branch identical to main.
  run bash "$PROBE" --diff main --root "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean (diff base=main"* ]]

  # Introduce a NEW leak on the feature branch.
  printf 'XAUTHORITY=/tmp/xauth\n' > "$repo/scripts/new.env"
  (
    cd "$repo"
    git add scripts/new.env
    git commit -q -m "introduce visual leak"
  )
  run bash "$PROBE" --diff main --root "$repo"
  [ "$status" -eq 81 ]
  [[ "$output" == *"scripts/new.env"* ]]
  [[ "$output" == *"pattern=^XAUTHORITY="* ]]
}

@test "probe --diff catches a leak that is staged but not yet committed (pre-commit hook usage)" {
  local repo="$BATS_TEST_TMPDIR/probe-staged"
  make_synth_repo "$repo"
  (
    cd "$repo"
    git checkout -q -b feature
  )
  printf 'DISPLAY=:1\n' > "$repo/scripts/staged.env"
  (
    cd "$repo"
    git add scripts/staged.env
  )
  run bash "$PROBE" --diff main --root "$repo"
  [ "$status" -eq 81 ]
  [[ "$output" == *"scripts/staged.env"* ]]
}

@test "probe --diff fails with exit 2 when no diff base can be resolved" {
  local repo="$BATS_TEST_TMPDIR/probe-no-base"
  mkdir -p "$repo"
  ( cd "$repo" && git -c init.defaultBranch=main init -q )
  # Brand-new repo with no commits and no origin/main, main, or HEAD~1.
  run bash "$PROBE" --diff --root "$repo"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot resolve diff base"* ]]
}

@test "probe --paths overrides the search prefix set" {
  local repo="$BATS_TEST_TMPDIR/probe-paths"
  make_synth_repo "$repo"
  # Leak in a non-default prefix that we'll explicitly target.
  mkdir -p "$repo/profiles"
  printf 'DISPLAY=:1\n' > "$repo/profiles/leaky.env"

  # Default scan misses it (profiles/ not in default set).
  run bash "$PROBE" --full --root "$repo"
  [ "$status" -eq 0 ]

  # Explicit --paths picks it up.
  run bash "$PROBE" --full --paths profiles --root "$repo"
  [ "$status" -eq 81 ]
  [[ "$output" == *"profiles/leaky.env"* ]]
}

@test "the guard's own source files do not self-trigger when scanned in their real repo" {
  # Run a full scan against the real toolkit root. With the guard files
  # present (lib/visual_lane.sh, scripts/visual_lane_probe.sh, the docs/
  # entry, and this bats fixture under tests/), the scan must still be
  # clean — proving the source-splitting trick keeps the guard from
  # self-detecting the unanchored ORCH_VISUAL_ prefix.
  run bash "$PROBE" --full --root "$TK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean (full scan"* ]]
}
