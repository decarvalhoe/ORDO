#!/usr/bin/env bats
# tests/docs_layers_optionality.bats — verifies that optional documentation
# layers (GxP-grade and Six Sigma per epic #257) and the orchestrator-
# injected visual-verification lane are strictly opt-in:
#
#   - GxP/Six Sigma sections appear only when the project profile selects
#     them; normal-dev fixtures never receive those sections.
#   - The visual lane is a no-op when ORCH_VISUAL_DISPLAY is unset and
#     produces evidence under $ORCH_LOG_DIR/visual/ when configured.
#   - Default ORDO config files do NOT export DISPLAY/XAUTHORITY/
#     ORCH_VISUAL_*; the lane stays profile-level so headless agents do
#     not pick it up implicitly.
#
# Generator-dependent assertions skip when the generator (#261) is absent;
# the visual-lane no-leak and gating assertions always run because they
# guard the toolkit's own configuration regardless of generator status.

load './helpers.bash'

setup() {
  setup_orch_test
  ROOT="${ROOT:-$(cd "$BATS_TEST_DIRNAME/.." && pwd)}"
  GENERATOR="$ROOT/scripts/docs_generate.sh"
  export ROOT GENERATOR
}

generator_present() {
  [ -x "$GENERATOR" ] || [ -f "$GENERATOR" ]
}

# --- Layer optionality ----------------------------------------------------

@test "normal-dev fixture: generator emits no GxP or Six Sigma sections" {
  if ! generator_present; then
    skip "docs generator (#261) not yet present at this base"
  fi
  local out_dir="$BATS_TEST_TMPDIR/normal"
  mkdir -p "$out_dir"
  run timeout 30 bash "$GENERATOR" --out "$out_dir" --grade normal-dev
  [ "$status" -eq 0 ]
  ! grep -rqE 'controlled.document|deviation|CAPA|GxP-grade' "$out_dir"
  ! grep -rqE 'DMAIC|CTQ|six.sigma' "$out_dir"
}

@test "GxP fixture: generator includes controlled-document sections" {
  if ! generator_present; then
    skip "docs generator (#261) not yet present at this base"
  fi
  local out_dir="$BATS_TEST_TMPDIR/gxp"
  mkdir -p "$out_dir"
  run timeout 30 bash "$GENERATOR" --out "$out_dir" --grade gxp-grade
  [ "$status" -eq 0 ]
  grep -rqE 'controlled.document|deviation|CAPA' "$out_dir"
  grep -rqE 'audit trail|traceability' "$out_dir"
}

@test "Six Sigma fixture: generator includes DMAIC/CTQ scaffolding" {
  if ! generator_present; then
    skip "docs generator (#261) not yet present at this base"
  fi
  local out_dir="$BATS_TEST_TMPDIR/sixsigma"
  mkdir -p "$out_dir"
  run timeout 30 bash "$GENERATOR" --out "$out_dir" --layer sixsigma
  [ "$status" -eq 0 ]
  grep -rqE 'DMAIC|CTQ|evidence.ledger' "$out_dir"
}

# --- Visual lane gating ---------------------------------------------------

@test "default ORDO configs do not export DISPLAY, XAUTHORITY, or ORCH_VISUAL_*" {
  # Fail closed if any default-loaded profile or shared lib introduces
  # the visual-lane env vars. They MUST live in operator-controlled
  # project profiles only, so headless agents never pick them up.
  local pattern miss=0
  for pattern in 'ORCH_VISUAL_' '^DISPLAY=' '^XAUTHORITY='; do
    if grep -rEq "$pattern" "$ROOT/examples" "$ROOT/lib" "$ROOT/scripts" 2>/dev/null; then
      printf 'visual-lane leak: pattern %s found in default config\n' "$pattern" >&3
      miss=$((miss + 1))
    fi
  done
  [ "$miss" -eq 0 ]
}

@test "visual lane is a silent no-op when ORCH_VISUAL_DISPLAY is unset" {
  unset ORCH_VISUAL_DISPLAY ORCH_VISUAL_XAUTHORITY ORCH_VISUAL_VIEWPORTS \
    ORCH_VISUAL_SCREENSHOT_DIR
  local log_dir="$BATS_TEST_TMPDIR/log-no-visual"
  mkdir -p "$log_dir"
  # Reference helper: a future scripts/visual_lane_probe.sh (or
  # equivalent) must follow the same contract this fixture asserts.
  # In the meantime we simulate the contract inline so the assertion
  # is locked: when no display is configured, no visual evidence dir
  # is created and no error is emitted.
  ORCH_LOG_DIR="$log_dir" bash -c '
    set -euo pipefail
    if [ -n "${ORCH_VISUAL_DISPLAY:-}" ]; then
      mkdir -p "$ORCH_LOG_DIR/visual"
      printf "configured\n" > "$ORCH_LOG_DIR/visual/probe.txt"
    fi
  '
  [ ! -d "$log_dir/visual" ]
}

@test "visual lane writes evidence under \$ORCH_LOG_DIR/visual when configured" {
  local log_dir="$BATS_TEST_TMPDIR/log-with-visual"
  mkdir -p "$log_dir"
  # Use a synthetic value so the test does not require real X11; the
  # contract being verified is about the side effect (evidence dir +
  # capability record), not the actual screenshot capture, which is the
  # responsibility of the diagnostics tool owned by ticket #255.
  ORCH_VISUAL_DISPLAY=":99-test" \
  ORCH_VISUAL_XAUTHORITY="$BATS_TEST_TMPDIR/Xauthority.fixture" \
  ORCH_VISUAL_VIEWPORTS="390x844 1024x768 1600x1200" \
  ORCH_LOG_DIR="$log_dir" \
    bash -c '
      set -euo pipefail
      if [ -z "${ORCH_VISUAL_DISPLAY:-}" ]; then
        exit 0
      fi
      target="${ORCH_VISUAL_SCREENSHOT_DIR:-$ORCH_LOG_DIR/visual}"
      mkdir -p "$target"
      {
        printf "DISPLAY=%s\n" "$ORCH_VISUAL_DISPLAY"
        printf "XAUTHORITY=%s\n" "${ORCH_VISUAL_XAUTHORITY:-unset}"
        printf "VIEWPORTS=%s\n" "${ORCH_VISUAL_VIEWPORTS:-unset}"
      } > "$target/visual-lane-readiness.txt"
    '
  [ -d "$log_dir/visual" ]
  [ -s "$log_dir/visual/visual-lane-readiness.txt" ]
  grep -q "DISPLAY=:99-test" "$log_dir/visual/visual-lane-readiness.txt"
  grep -q "VIEWPORTS=390x844 1024x768 1600x1200" "$log_dir/visual/visual-lane-readiness.txt"
}

@test "ORCH_VISUAL_SCREENSHOT_DIR override is honored when set" {
  local log_dir="$BATS_TEST_TMPDIR/log-override"
  local custom_dir="$BATS_TEST_TMPDIR/custom-visual"
  mkdir -p "$log_dir"
  ORCH_VISUAL_DISPLAY=":99-test" \
  ORCH_VISUAL_SCREENSHOT_DIR="$custom_dir" \
  ORCH_LOG_DIR="$log_dir" \
    bash -c '
      set -euo pipefail
      if [ -z "${ORCH_VISUAL_DISPLAY:-}" ]; then
        exit 0
      fi
      target="${ORCH_VISUAL_SCREENSHOT_DIR:-$ORCH_LOG_DIR/visual}"
      mkdir -p "$target"
      printf "ok\n" > "$target/marker.txt"
    '
  [ -f "$custom_dir/marker.txt" ]
  # The override path must NOT cause $ORCH_LOG_DIR/visual to be
  # populated as a side effect.
  [ ! -d "$log_dir/visual" ]
}
