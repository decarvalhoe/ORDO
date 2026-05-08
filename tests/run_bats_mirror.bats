#!/usr/bin/env bats
# tests/run_bats_mirror.bats — coverage for ORDO #325.
#
# `scripts/run_bats.sh::mirror_file` MUST preserve the source file's mode
# bits. The previous implementation did `tr -d '\r' < src > dest` only,
# which drops the executable bit and produces a 0644 file. Bats suites
# that exec a mirrored script directly then fail with rc=126
# (permission denied), creating CI-only aggregate failures while
# isolated `bats <one-file.bats>` runs pass because no mirroring happens.
#
# This fixture extracts the mirror_file definition from
# scripts/run_bats.sh, exercises it against a synthetic ROOT layout, and
# asserts that:
#   - executable scripts stay executable in the sanitized tree;
#   - non-executable text files stay non-executable;
#   - the mirrored script can be exec'd directly with rc=0.

load './helpers.bash'

setup() {
  setup_orch_test
  export FAKE_ROOT="$BATS_TEST_TMPDIR/fake-root"
  export SANITIZED_ROOT="$BATS_TEST_TMPDIR/sanitized"
  mkdir -p "$FAKE_ROOT/scripts" "$FAKE_ROOT/lib" "$SANITIZED_ROOT"

  cat > "$FAKE_ROOT/scripts/exec_probe.sh" <<'EOF'
#!/usr/bin/env bash
echo "exec_probe ok"
EOF
  chmod 0755 "$FAKE_ROOT/scripts/exec_probe.sh"

  cat > "$FAKE_ROOT/lib/text_only.sh" <<'EOF'
#!/usr/bin/env bash
# sourced library, intentionally not executable
EOF
  chmod 0644 "$FAKE_ROOT/lib/text_only.sh"

  # Extract mirror_file from the in-tree run_bats.sh and source the
  # extraction into the test shell. This guarantees the test exercises
  # the actual function body shipped in the repo, not a copy.
  extracted="$BATS_TEST_TMPDIR/mirror_file.sh"
  sed -n '/^mirror_file()/,/^}/p' "$TK/scripts/run_bats.sh" > "$extracted"
  [ -s "$extracted" ] || { echo "failed to extract mirror_file" >&2; return 1; }
  ROOT="$FAKE_ROOT"
  # shellcheck disable=SC1090
  source "$extracted"
}

@test "executable source keeps the executable bit after mirroring" {
  mirror_file "scripts/exec_probe.sh"

  # The dest file must exist.
  [ -f "$SANITIZED_ROOT/scripts/exec_probe.sh" ]

  # The dest file must be executable.
  [ -x "$SANITIZED_ROOT/scripts/exec_probe.sh" ]

  # Direct execution must succeed (rc=0), proving the bug from #325 is
  # fixed: previously this returned rc=126 (permission denied).
  run "$SANITIZED_ROOT/scripts/exec_probe.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "exec_probe ok" ]
}

@test "non-executable source stays non-executable after mirroring" {
  mirror_file "lib/text_only.sh"

  [ -f "$SANITIZED_ROOT/lib/text_only.sh" ]
  [ ! -x "$SANITIZED_ROOT/lib/text_only.sh" ]
}

@test "mirrored mode matches source mode bit-for-bit" {
  mirror_file "scripts/exec_probe.sh"
  src_mode=$(stat -c '%a' "$FAKE_ROOT/scripts/exec_probe.sh")
  dst_mode=$(stat -c '%a' "$SANITIZED_ROOT/scripts/exec_probe.sh")
  [ "$src_mode" = "$dst_mode" ]
}

@test "fallback chmod +x preserves exec bit when --reference is unavailable" {
  # Simulate an environment where `chmod --reference` is unavailable: the
  # mirror_file function falls back to a literal `chmod +x` when the
  # source is executable. We exercise the fallback by overriding `chmod`
  # on PATH so --reference fails (rc=1), forcing the fallback branch.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/chmod" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" --reference="*) exit 1 ;;
  *) exec /usr/bin/chmod "$@" ;;
esac
EOF
  /usr/bin/chmod +x "$BATS_TEST_TMPDIR/bin/chmod"

  PATH="$BATS_TEST_TMPDIR/bin:$PATH" mirror_file "scripts/exec_probe.sh"

  [ -x "$SANITIZED_ROOT/scripts/exec_probe.sh" ]
}

# ---------------------------------------------------------------------------
# Coverage for ORDO #326 — fixture mirror.
#
# scripts/run_bats.sh's main mirror loop is extension-driven: it copies only
# *.sh / *.bash / *.bats / *.config.sh / *.md / *.txt files. Bats suites that
# load fixture data (TSV baselines, JSON inputs, golden output files, sample
# binaries) used to fail in aggregate because their fixtures were silently
# dropped from the sanitized toolkit while isolated `bats <one-file.bats>`
# runs passed (no mirroring happens there). The mirror_test_fixtures helper
# closes that gap by copying every file under tests/{fixtures,data,golden,
# snapshots}/** regardless of extension, while reusing mirror_file so the
# mode-bit preservation introduced for #325 still applies.
# ---------------------------------------------------------------------------

extract_mirror_test_fixtures_into_shell() {
  # Source the mirror_test_fixtures function definition from the in-tree
  # run_bats.sh into the current shell. mirror_file is already loaded by
  # setup() above. This guarantees the test exercises the actual function
  # body shipped in the repo, not a copy.
  local extracted="$BATS_TEST_TMPDIR/mirror_test_fixtures.sh"
  sed -n '/^mirror_test_fixtures()/,/^}/p' "$TK/scripts/run_bats.sh" > "$extracted"
  [ -s "$extracted" ] || { echo "failed to extract mirror_test_fixtures" >&2; return 1; }
  # shellcheck disable=SC1090
  source "$extracted"
}

@test "fixture mirror copies tests/fixtures/* regardless of extension (#326)" {
  extract_mirror_test_fixtures_into_shell

  mkdir -p "$FAKE_ROOT/tests/fixtures/nested"
  printf 'callsite\toccurrences\nfoo\t1\n' \
    > "$FAKE_ROOT/tests/fixtures/sample_baseline.tsv"
  printf '{"x":1}\n' > "$FAKE_ROOT/tests/fixtures/nested/payload.json"
  printf 'binary blob' > "$FAKE_ROOT/tests/fixtures/blob.bin"

  mirror_test_fixtures

  [ -f "$SANITIZED_ROOT/tests/fixtures/sample_baseline.tsv" ]
  [ -f "$SANITIZED_ROOT/tests/fixtures/nested/payload.json" ]
  [ -f "$SANITIZED_ROOT/tests/fixtures/blob.bin" ]

  # Content must round-trip (mirror_file uses `tr -d '\r'` which is a
  # no-op on these UNIX-line-ending fixtures).
  src_tsv=$(cat "$FAKE_ROOT/tests/fixtures/sample_baseline.tsv")
  dst_tsv=$(cat "$SANITIZED_ROOT/tests/fixtures/sample_baseline.tsv")
  [ "$src_tsv" = "$dst_tsv" ]
}

@test "fixture mirror is a no-op when tests/fixtures/ does not exist (#326)" {
  extract_mirror_test_fixtures_into_shell

  # FAKE_ROOT from setup() has tests/scripts but no tests/fixtures.
  [ ! -d "$FAKE_ROOT/tests/fixtures" ]

  run mirror_test_fixtures
  [ "$status" -eq 0 ]
  [ ! -d "$SANITIZED_ROOT/tests/fixtures" ]
}

@test "fixture mirror also covers tests/{data,golden,snapshots} (#326)" {
  extract_mirror_test_fixtures_into_shell

  mkdir -p "$FAKE_ROOT/tests/data" "$FAKE_ROOT/tests/golden" "$FAKE_ROOT/tests/snapshots"
  printf 'data\n'      > "$FAKE_ROOT/tests/data/input.csv"
  printf 'golden\n'    > "$FAKE_ROOT/tests/golden/expected.txt"
  printf 'snapshot\n'  > "$FAKE_ROOT/tests/snapshots/2026-05-08.json"

  mirror_test_fixtures

  [ -f "$SANITIZED_ROOT/tests/data/input.csv" ]
  [ -f "$SANITIZED_ROOT/tests/golden/expected.txt" ]
  [ -f "$SANITIZED_ROOT/tests/snapshots/2026-05-08.json" ]
}

@test "fixture mirror preserves mode bits on executable fixture helpers (#326 + #325)" {
  extract_mirror_test_fixtures_into_shell

  # A fixture-side helper script that bats suites might exec directly.
  # Combines #326 (the file is mirrored even though its extension is not
  # in the main allowlist — here .sh IS in the allowlist, but a fixture
  # could equally be an .exec/.bin or a no-extension helper) with #325
  # (the executable bit must survive the mirror).
  mkdir -p "$FAKE_ROOT/tests/fixtures/helpers"
  cat > "$FAKE_ROOT/tests/fixtures/helpers/probe" <<'EOF'
#!/usr/bin/env bash
echo "fixture probe ok"
EOF
  /usr/bin/chmod 0755 "$FAKE_ROOT/tests/fixtures/helpers/probe"

  mirror_test_fixtures

  [ -f "$SANITIZED_ROOT/tests/fixtures/helpers/probe" ]
  [ -x "$SANITIZED_ROOT/tests/fixtures/helpers/probe" ]
  run "$SANITIZED_ROOT/tests/fixtures/helpers/probe"
  [ "$status" -eq 0 ]
  [ "$output" = "fixture probe ok" ]
}
