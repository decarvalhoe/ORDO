#!/usr/bin/env bats

# Tests for lib/visual_lane.sh and scripts/visual_lane_probe.sh — #264.
#
# Coverage matrix:
#   - GUI-unavailable host (no ORCH_VISUAL_DISPLAY)             → silent no-op
#   - GUI opt-in but display probe fails                        → display_ready=false
#   - GUI opt-in, mocked xdpyinfo OK                            → display_ready=true
#   - Browser auto-detection from candidate list                → browser_ready=true
#   - No browser candidate available                            → browser_ready=false
#   - Automation auto-detection (npx-playwright path)           → automation_ready=true
#   - Evidence dir resolves under $PWD                          → evidence_dir_in_worktree=true
#   - --require-enabled exits 1 when lane is off                → exit code

setup() {
  TEST_TMP=$(mktemp -d)
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LIB="$REPO_ROOT/lib/visual_lane.sh"
  PROBE="$REPO_ROOT/scripts/visual_lane_probe.sh"
  STUB_BIN="$TEST_TMP/bin"
  mkdir -p "$STUB_BIN"

  # Minimal PATH the tests can rely on. Real binaries (`awk`, `printf`,
  # `mkdir`, `python3` for JSON validation) come from /usr/bin and
  # /bin so they keep working; the tests prepend STUB_BIN so individual
  # cases can intercept tools (`xdpyinfo`, browser candidates, npx).
  PATH_ORIG="$PATH"
  export PATH="$STUB_BIN:/usr/bin:/bin"

  # Default: lane is OFF. Each test opts in as needed.
  unset ORCH_VISUAL_DISPLAY ORCH_VISUAL_XAUTHORITY \
        ORCH_VISUAL_BROWSER ORCH_VISUAL_BROWSER_CANDIDATES \
        ORCH_VISUAL_AUTOMATION ORCH_VISUAL_AUTOMATION_CANDIDATES \
        ORCH_VISUAL_DESIGN_MCP_HINT \
        ORCH_VISUAL_EVIDENCE_DIR ORCH_VISUAL_VIEWPORTS \
        ORCH_VISUAL_FALLBACK ORCH_VISUAL_HOST_EVIDENCE \
        ORCH_VISUAL_PROBE_TIMEOUT_SEC || true
}

teardown() {
  PATH="$PATH_ORIG"
  rm -rf "$TEST_TMP"
}

write_stub() {
  local name=$1 status=$2 stdout=${3:-}
  cat > "$STUB_BIN/$name" <<EOF
#!/usr/bin/env bash
[ -n "${stdout//\"/\\\"}" ] && printf '%s\n' "${stdout//\"/\\\"}"
exit $status
EOF
  chmod +x "$STUB_BIN/$name"
}

@test "lane is silent when ORCH_VISUAL_DISPLAY is unset" {
  run bash -c "source '$LIB'; visual_lane_collect --format json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"enabled":false'* ]]
  [[ "$output" == *'"summary":{}'* ]]
  [[ "$output" == *'"details":{}'* ]]
}

@test "text format announces disabled state with hint" {
  run bash -c "source '$LIB'; visual_lane_collect --format text"
  [ "$status" -eq 0 ]
  [[ "$output" == *"visual lane: disabled"* ]]
  [[ "$output" == *"ORCH_VISUAL_DISPLAY"* ]]
}

@test "lane is enabled when ORCH_VISUAL_DISPLAY is set" {
  ORCH_VISUAL_DISPLAY=":20" run bash -c "source '$LIB'; visual_lane_collect --format json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"enabled":true'* ]]
}

@test "display_ready=true when xdpyinfo stub succeeds" {
  write_stub xdpyinfo 0 "name of display: :20"
  # No browser/automation candidates → those probes will report false,
  # but the test focuses on display readiness.
  run env ORCH_VISUAL_DISPLAY=":20" \
          ORCH_VISUAL_BROWSER_CANDIDATES="nonexistent-browser" \
          ORCH_VISUAL_AUTOMATION_CANDIDATES="nonexistent-tool" \
          PATH="$STUB_BIN:/usr/bin:/bin" \
          bash -c "source '$LIB'; visual_lane_collect --format json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"display_ready":true'* ]]
}

@test "display_ready=false when xdpyinfo stub fails" {
  write_stub xdpyinfo 1 ""
  run env ORCH_VISUAL_DISPLAY=":99" \
          ORCH_VISUAL_BROWSER_CANDIDATES="nonexistent-browser" \
          ORCH_VISUAL_AUTOMATION_CANDIDATES="nonexistent-tool" \
          PATH="$STUB_BIN:/usr/bin:/bin" \
          bash -c "source '$LIB'; visual_lane_collect --format json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"display_ready":false'* ]]
  [[ "$output" == *"xdpyinfo-failed"* ]]
}

@test "display probe reports unknown when probe binary is absent" {
  # ORCH_VISUAL_DISPLAY_PROBE points at a binary the operator has not
  # installed (e.g. `wlr-randr` on a Wayland host without it). The lane
  # falls back to `unknown` instead of pretending the display works.
  run env ORCH_VISUAL_DISPLAY=":20" \
          ORCH_VISUAL_DISPLAY_PROBE="absolutely-not-a-real-probe-zzz" \
          ORCH_VISUAL_BROWSER_CANDIDATES="nonexistent-browser" \
          ORCH_VISUAL_AUTOMATION_CANDIDATES="nonexistent-tool" \
          PATH="$STUB_BIN:/usr/bin:/bin" \
          bash -c "source '$LIB'; visual_lane_collect --format json"
  [ "$status" -eq 0 ]
  # `display_ready` collapses the unknown state to `false` so callers
  # do not treat "we don't know" as readiness; the detail string preserves
  # the probe name so operators see which command to install or override.
  [[ "$output" == *'"display_probe":"unknown"'* ]]
  [[ "$output" == *"absolutely-not-a-real-probe-zzz-missing"* ]]
}

@test "browser is auto-detected from candidate list" {
  write_stub xdpyinfo 0 "ok"
  write_stub fake-browser 0 "Fake Browser 9.9"
  run env ORCH_VISUAL_DISPLAY=":20" \
          ORCH_VISUAL_BROWSER_CANDIDATES="fake-browser" \
          ORCH_VISUAL_AUTOMATION_CANDIDATES="nonexistent-tool" \
          PATH="$STUB_BIN:/usr/bin:/bin" \
          bash -c "source '$LIB'; visual_lane_collect --format json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"browser_ready":true'* ]]
  [[ "$output" == *"name=fake-browser"* ]]
  [[ "$output" == *"Fake Browser 9.9"* ]]
}

@test "browser_ready=false when no candidate is on PATH" {
  write_stub xdpyinfo 0 "ok"
  run env ORCH_VISUAL_DISPLAY=":20" \
          ORCH_VISUAL_BROWSER_CANDIDATES="absolutely-not-a-real-binary-zzz" \
          ORCH_VISUAL_AUTOMATION_CANDIDATES="nonexistent-tool" \
          PATH="$STUB_BIN:/usr/bin:/bin" \
          bash -c "source '$LIB'; visual_lane_collect --format json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"browser_ready":false'* ]]
  [[ "$output" == *"no-candidate-on-path"* ]]
}

@test "explicit ORCH_VISUAL_BROWSER skips candidate probing" {
  write_stub xdpyinfo 0 "ok"
  write_stub explicit-browser 0 "Explicit 1.0"
  run env ORCH_VISUAL_DISPLAY=":20" \
          ORCH_VISUAL_BROWSER="explicit-browser" \
          ORCH_VISUAL_BROWSER_CANDIDATES="should-not-be-tried" \
          ORCH_VISUAL_AUTOMATION_CANDIDATES="nonexistent-tool" \
          PATH="$STUB_BIN:/usr/bin:/bin" \
          bash -c "source '$LIB'; visual_lane_collect --format json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"name=explicit-browser"* ]]
  [[ "$output" != *"should-not-be-tried"* ]]
}

@test "automation auto-detected via npx-playwright path" {
  write_stub xdpyinfo 0 "ok"
  write_stub npx 0 "1.59.1"
  run env ORCH_VISUAL_DISPLAY=":20" \
          ORCH_VISUAL_BROWSER_CANDIDATES="nonexistent-browser" \
          ORCH_VISUAL_AUTOMATION_CANDIDATES="nonexistent-tool" \
          PATH="$STUB_BIN:/usr/bin:/bin" \
          bash -c "source '$LIB'; visual_lane_collect --format json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"automation_ready":true'* ]]
  [[ "$output" == *"npx-playwright"* ]]
}

@test "evidence_dir defaults under HOME" {
  run env ORCH_VISUAL_DISPLAY=":20" \
          ORCH_VISUAL_BROWSER_CANDIDATES="nonexistent-browser" \
          ORCH_VISUAL_AUTOMATION_CANDIDATES="nonexistent-tool" \
          HOME="$TEST_TMP/home" \
          PATH="$STUB_BIN:/usr/bin:/bin" \
          bash -c "source '$LIB'; visual_lane_evidence_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "$TEST_TMP/home/orch-visual-evidence" ]
}

@test "evidence_dir_in_worktree=true when path resolves under PWD" {
  write_stub xdpyinfo 0 "ok"
  local in_worktree="$TEST_TMP/worktree"
  mkdir -p "$in_worktree"
  cd "$in_worktree"
  run env ORCH_VISUAL_DISPLAY=":20" \
          ORCH_VISUAL_BROWSER_CANDIDATES="nonexistent-browser" \
          ORCH_VISUAL_AUTOMATION_CANDIDATES="nonexistent-tool" \
          ORCH_VISUAL_EVIDENCE_DIR="$in_worktree/screenshots" \
          PATH="$STUB_BIN:/usr/bin:/bin" \
          bash -c "source '$LIB'; visual_lane_collect --format json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"evidence_dir_in_worktree":true'* ]]
}

@test "evidence_dir_in_worktree=false when path is outside PWD" {
  write_stub xdpyinfo 0 "ok"
  local outside="$TEST_TMP/elsewhere"
  mkdir -p "$outside"
  local cwd="$TEST_TMP/cwd"
  mkdir -p "$cwd"
  cd "$cwd"
  run env ORCH_VISUAL_DISPLAY=":20" \
          ORCH_VISUAL_BROWSER_CANDIDATES="nonexistent-browser" \
          ORCH_VISUAL_AUTOMATION_CANDIDATES="nonexistent-tool" \
          ORCH_VISUAL_EVIDENCE_DIR="$outside" \
          PATH="$STUB_BIN:/usr/bin:/bin" \
          bash -c "source '$LIB'; visual_lane_collect --format json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"evidence_dir_in_worktree":false'* ]]
}

@test "design_mcp_hint surfaces operator string verbatim" {
  write_stub xdpyinfo 0 "ok"
  run env ORCH_VISUAL_DISPLAY=":20" \
          ORCH_VISUAL_DESIGN_MCP_HINT="claude.ai Figma" \
          ORCH_VISUAL_BROWSER_CANDIDATES="nonexistent-browser" \
          ORCH_VISUAL_AUTOMATION_CANDIDATES="nonexistent-tool" \
          PATH="$STUB_BIN:/usr/bin:/bin" \
          bash -c "source '$LIB'; visual_lane_collect --format json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"design_mcp_hint":"claude.ai Figma"'* ]]
}

@test "host_evidence path is surfaced under audit when set" {
  write_stub xdpyinfo 0 "ok"
  run env ORCH_VISUAL_DISPLAY=":20" \
          ORCH_VISUAL_HOST_EVIDENCE="/tmp/host-cap.md" \
          ORCH_VISUAL_BROWSER_CANDIDATES="nonexistent-browser" \
          ORCH_VISUAL_AUTOMATION_CANDIDATES="nonexistent-tool" \
          PATH="$STUB_BIN:/usr/bin:/bin" \
          bash -c "source '$LIB'; visual_lane_collect --format json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"host_evidence":"/tmp/host-cap.md"'* ]]
}

@test "probe script exits 1 with --require-enabled when lane disabled" {
  # Invoke via `bash "$PROBE"` rather than executing the script directly:
  # `scripts/run_bats.sh` mirrors files into a sanitized tree without
  # preserving the exec bit, so a direct invocation would 126 in the
  # aggregate run. Going through `bash` is exec-bit-agnostic and exercises
  # exactly the same script body.
  run env PATH="$STUB_BIN:/usr/bin:/bin" bash "$PROBE" --require-enabled
  [ "$status" -eq 1 ]
  [[ "$output" == *"ORCH_VISUAL_DISPLAY"* ]]
}

@test "probe script exits 0 with --require-enabled when lane enabled" {
  write_stub xdpyinfo 0 "ok"
  run env ORCH_VISUAL_DISPLAY=":20" \
          ORCH_VISUAL_BROWSER_CANDIDATES="nonexistent-browser" \
          ORCH_VISUAL_AUTOMATION_CANDIDATES="nonexistent-tool" \
          PATH="$STUB_BIN:/usr/bin:/bin" \
          bash "$PROBE" --require-enabled --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"enabled":true'* ]]
}

@test "JSON output is valid for both enabled and disabled states" {
  # Disabled
  run bash -c "source '$LIB'; visual_lane_collect --format json | python3 -m json.tool > /dev/null"
  [ "$status" -eq 0 ]

  # Enabled (with one stub so the probe path runs)
  write_stub xdpyinfo 0 "ok"
  run env ORCH_VISUAL_DISPLAY=":20" \
          ORCH_VISUAL_BROWSER_CANDIDATES="nonexistent-browser" \
          ORCH_VISUAL_AUTOMATION_CANDIDATES="nonexistent-tool" \
          PATH="$STUB_BIN:/usr/bin:/bin" \
          bash -c "source '$LIB'; visual_lane_collect --format json | python3 -m json.tool > /dev/null"
  [ "$status" -eq 0 ]
}

@test "fallback policy round-trips into JSON output" {
  write_stub xdpyinfo 0 "ok"
  run env ORCH_VISUAL_DISPLAY=":20" \
          ORCH_VISUAL_FALLBACK="headless" \
          ORCH_VISUAL_BROWSER_CANDIDATES="nonexistent-browser" \
          ORCH_VISUAL_AUTOMATION_CANDIDATES="nonexistent-tool" \
          PATH="$STUB_BIN:/usr/bin:/bin" \
          bash -c "source '$LIB'; visual_lane_collect --format json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"fallback":"headless"'* ]]
}
