#!/usr/bin/env bats

# tests/cli/test_persistent_flags.bats — regression coverage for issue
# #411 (Claude CLI loses --debug-file across internal worker restarts).
#
# We cannot trigger an actual Claude CLI internal restart from bash, so
# the test exercises the ORDO-side drift detector exposed by
# `lib/persistent_flags.sh` against synthetic /proc/<pid>/cmdline
# fixtures. The fixtures encode:
#   - the pre-restart state ("flag present, target matches contract"),
#   - the canonical post-restart symptom from #411 ("flag absent from
#     cmdline; lsof reports the CLI default debug path"),
#   - and the secondary drift case ("flag present but pointing at a
#     different target", e.g. an internally-restarted worker that does
#     re-apply some flags but with a default path).
#
# The detector return codes feed the existing
# `lib/worktree_helpers.sh` launch-contract healing path
# (`agent_product_switch --hard`); see docs/cli/persistent-flags.md.

load '../helpers.bash'

setup() {
  setup_orch_test
  TK="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export TK
  export LIB="$TK/lib/persistent_flags.sh"
  TEST_PROC="$BATS_TEST_TMPDIR/proc"
  export TEST_PROC
  mkdir -p "$TEST_PROC"
}

# write_cmdline <pid> <argv>...
#   Synthesise a /proc/<pid>/cmdline file with NUL-separated argv, mirroring
#   the kernel's on-disk format. The detector reads only this file, so the
#   test does not need a real running process.
write_cmdline() {
  local pid=$1; shift
  mkdir -p "$TEST_PROC/$pid"
  : > "$TEST_PROC/$pid/cmdline"
  local arg
  for arg in "$@"; do
    printf '%s\0' "$arg" >> "$TEST_PROC/$pid/cmdline"
  done
}

@test "persistent_flags_for_cli claude lists --debug-file and identity flags" {
  run bash -lc "source '$LIB' && persistent_flags_for_cli claude"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--name"* ]]
  [[ "$output" == *"--debug-file"* ]]
  [[ "$output" == *"--append-system-prompt"* ]]
  [[ "$output" == *"--mcp-config"* ]]
  [[ "$output" == *"--allowed-tools"* ]]
}

@test "persistent_flags_for_cli codex lists --debug-file and --name" {
  run bash -lc "source '$LIB' && persistent_flags_for_cli codex"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--name"* ]]
  [[ "$output" == *"--debug-file"* ]]
}

@test "persistent_flags_for_cli on unknown cli returns empty list with rc=0" {
  run bash -lc "source '$LIB' && persistent_flags_for_cli unknown-cli-zzz"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "persistent_flags_extract_value finds --flag value (separate argv entries)" {
  write_cmdline 1234 claude --name rbok-claude --debug-file /var/log/ordo/claude.log --append-system-prompt /tmp/p.md
  run bash -lc "source '$LIB' && persistent_flags_extract_value '$TEST_PROC/1234/cmdline' --debug-file"
  [ "$status" -eq 0 ]
  [ "$output" = "/var/log/ordo/claude.log" ]
}

@test "persistent_flags_extract_value finds --flag=value (single argv entry)" {
  write_cmdline 1234 claude --name=rbok-claude --debug-file=/var/log/ordo/claude.log
  run bash -lc "source '$LIB' && persistent_flags_extract_value '$TEST_PROC/1234/cmdline' --debug-file"
  [ "$status" -eq 0 ]
  [ "$output" = "/var/log/ordo/claude.log" ]
}

@test "persistent_flags_extract_value returns rc=1 with no stdout when flag is absent" {
  write_cmdline 1234 claude --name rbok-claude
  run bash -lc "source '$LIB' && persistent_flags_extract_value '$TEST_PROC/1234/cmdline' --debug-file"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "persistent_flags_extract_value returns rc=1 when cmdline file is missing" {
  run bash -lc "source '$LIB' && persistent_flags_extract_value '$TEST_PROC/9999/cmdline' --debug-file"
  [ "$status" -eq 1 ]
}

@test "persistent_flags_drift rc=0 when value matches the contract" {
  write_cmdline 1234 claude --name rbok-claude --debug-file /var/log/ordo/claude.log
  run bash -lc "source '$LIB' && persistent_flags_drift '$TEST_PROC/1234/cmdline' --debug-file /var/log/ordo/claude.log"
  [ "$status" -eq 0 ]
}

@test "persistent_flags_drift rc=1 when value points at a different target (mismatch)" {
  # Hypothetical post-restart shape: the CLI did re-apply --debug-file but
  # the value was clobbered to its own default. Less common than the
  # absent-flag case, but the detector must still flag it.
  write_cmdline 1234 claude --debug-file /root/.claude/debug/2026-05-08-21-11.log
  run bash -lc "source '$LIB' && persistent_flags_drift '$TEST_PROC/1234/cmdline' --debug-file /var/log/ordo/claude.log"
  [ "$status" -eq 1 ]
}

@test "persistent_flags_drift rc=2 when flag is absent (canonical #411 symptom)" {
  # Post-restart: the new worker process was re-launched without the
  # original --debug-file argument at all. lsof against this PID would
  # show the default ~/.claude/debug/<random>.log path; in the cmdline
  # the flag is simply missing. This is the symptom reported on 8 of 12
  # fleet panes in #411.
  write_cmdline 1234 claude --name rbok-claude
  run bash -lc "source '$LIB' && persistent_flags_drift '$TEST_PROC/1234/cmdline' --debug-file /var/log/ordo/claude.log"
  [ "$status" -eq 2 ]
}

@test "persistent_flags_drift rc=3 on usage error (missing expected arg)" {
  write_cmdline 1234 claude --debug-file /var/log/ordo/claude.log
  run bash -lc "source '$LIB' && persistent_flags_drift '$TEST_PROC/1234/cmdline' --debug-file"
  [ "$status" -eq 3 ]
}
