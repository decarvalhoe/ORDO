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
