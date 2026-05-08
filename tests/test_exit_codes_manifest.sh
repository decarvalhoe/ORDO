#!/usr/bin/env bash
# tests/test_exit_codes_manifest.sh — drift guard for the ORDO exit-code
# manifest.
#
# Issue #314: docs/exit-codes.md (introduced by PR #306) is the operator-facing
# manifest of ORDO refusal exit codes. New ORCH_*_EXIT_CODE variables can be
# added to lib/ or scripts/ without updating the manifest, silently turning
# the manifest into a stale subset of the truth and letting operators rely on
# refusal codes that no longer match reality. This test detects that drift
# early.
#
# What it does:
#   1. Defines a pure helper (`exit_code_manifest_drift`) that takes a
#      manifest path and a set of code paths and emits two CSVs:
#        - drift=<vars present in code but missing from manifest>
#        - orphan=<vars present in manifest but absent from code>
#   2. Exercises the helper with controlled fixtures (clean / drift / orphan /
#      both / multi-var) so the detection logic itself is verified.
#   3. When docs/exit-codes.md is present in the real repo, runs the helper
#      against the actual lib/ + scripts/ tree and asserts no drift.
#      When the manifest is absent (e.g., PR #306 has not yet merged into
#      the base SHA this branch was cut from), the test emits a structured
#      "manifest absent" notice and exits 0 without enforcing — the
#      unit-fixture coverage still proves the detector works, and the
#      enforcement engages automatically the moment the manifest lands.
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

# Pure detector. Output is two lines: drift=<csv> and orphan=<csv>.
# - manifest_file: path to the operator-facing exit-code manifest
# - search_paths : remaining args, treated as paths to scan with grep -roE
# When the manifest is missing, every code-side token is reported as drift
# (including the empty case), so callers can decide whether to enforce.
exit_code_manifest_drift() {
  local manifest_file=${1:?usage: exit_code_manifest_drift <manifest> <path>...}
  shift
  local code_tokens manifest_tokens drift orphan
  code_tokens=$(grep -hroE 'ORCH_[A-Z_]*EXIT_CODE' "$@" 2>/dev/null \
    | LC_ALL=C sort -u || true)
  if [ -f "$manifest_file" ]; then
    manifest_tokens=$(grep -oE 'ORCH_[A-Z_]*EXIT_CODE' "$manifest_file" 2>/dev/null \
      | LC_ALL=C sort -u || true)
  else
    manifest_tokens=""
  fi
  drift=$(LC_ALL=C comm -23 <(printf '%s\n' "$code_tokens") <(printf '%s\n' "$manifest_tokens") \
    | awk 'NF' | paste -sd, -)
  orphan=$(LC_ALL=C comm -13 <(printf '%s\n' "$code_tokens") <(printf '%s\n' "$manifest_tokens") \
    | awk 'NF' | paste -sd, -)
  printf 'drift=%s\n' "$drift"
  printf 'orphan=%s\n' "$orphan"
}

# -----------------------------------------------------------------------------
# Unit fixtures
# -----------------------------------------------------------------------------
fixture_lib="$TEST_TMP/fixture/lib"
fixture_scripts="$TEST_TMP/fixture/scripts"
mkdir -p "$fixture_lib" "$fixture_scripts"

cat > "$fixture_lib/refuse.sh" <<'EOF'
#!/usr/bin/env bash
: "${ORCH_TIMEOUT_EXIT_CODE:=124}"
: "${ORCH_HOST_GATE_DEGRADED_EXIT_CODE:=7}"
exit "$ORCH_TIMEOUT_EXIT_CODE"
EOF

cat > "$fixture_scripts/dispatch.sh" <<'EOF'
#!/usr/bin/env bash
# uses ORCH_DISPATCH_NOT_READY_EXIT_CODE for the not-ready refusal
: "${ORCH_DISPATCH_NOT_READY_EXIT_CODE:=11}"
EOF

# Case 1: clean — manifest covers every code-side token.
manifest_clean="$TEST_TMP/manifest-clean.md"
cat > "$manifest_clean" <<'EOF'
# Exit codes manifest

| Variable | Value | Reason |
| --- | --- | --- |
| ORCH_TIMEOUT_EXIT_CODE | 124 | external command timeout |
| ORCH_HOST_GATE_DEGRADED_EXIT_CODE | 7 | host-load gate refusal |
| ORCH_DISPATCH_NOT_READY_EXIT_CODE | 11 | agent pane not ready |
EOF

out=$(exit_code_manifest_drift "$manifest_clean" "$fixture_lib" "$fixture_scripts")
[ "$(printf '%s' "$out" | grep '^drift=')"  = "drift=" ]  || fail "clean fixture must report no drift; got: $out"
[ "$(printf '%s' "$out" | grep '^orphan=')" = "orphan=" ] || fail "clean fixture must report no orphan; got: $out"

# Case 2: drift — manifest missing one code-side token.
manifest_drift="$TEST_TMP/manifest-drift.md"
cat > "$manifest_drift" <<'EOF'
| ORCH_TIMEOUT_EXIT_CODE | 124 | timeout |
| ORCH_DISPATCH_NOT_READY_EXIT_CODE | 11 | not ready |
EOF
out=$(exit_code_manifest_drift "$manifest_drift" "$fixture_lib" "$fixture_scripts")
case "$(printf '%s' "$out" | grep '^drift=')" in
  drift=*ORCH_HOST_GATE_DEGRADED_EXIT_CODE*) ;;
  *) fail "drift fixture must list missing token; got: $out" ;;
esac
[ "$(printf '%s' "$out" | grep '^orphan=')" = "orphan=" ] || fail "drift fixture must report no orphan; got: $out"

# Case 3: orphan — manifest lists a token no longer present in code.
manifest_orphan="$TEST_TMP/manifest-orphan.md"
cat > "$manifest_orphan" <<'EOF'
| ORCH_TIMEOUT_EXIT_CODE | 124 | timeout |
| ORCH_HOST_GATE_DEGRADED_EXIT_CODE | 7 | host gate |
| ORCH_DISPATCH_NOT_READY_EXIT_CODE | 11 | not ready |
| ORCH_REMOVED_EXIT_CODE | 99 | removed (orphan) |
EOF
out=$(exit_code_manifest_drift "$manifest_orphan" "$fixture_lib" "$fixture_scripts")
[ "$(printf '%s' "$out" | grep '^drift=')" = "drift=" ] || fail "orphan fixture must report no drift; got: $out"
case "$(printf '%s' "$out" | grep '^orphan=')" in
  orphan=*ORCH_REMOVED_EXIT_CODE*) ;;
  *) fail "orphan fixture must list extra manifest token; got: $out" ;;
esac

# Case 4: drift + orphan together.
manifest_both="$TEST_TMP/manifest-both.md"
cat > "$manifest_both" <<'EOF'
| ORCH_TIMEOUT_EXIT_CODE | 124 | timeout |
| ORCH_DISPATCH_NOT_READY_EXIT_CODE | 11 | not ready |
| ORCH_REMOVED_EXIT_CODE | 99 | removed (orphan) |
EOF
out=$(exit_code_manifest_drift "$manifest_both" "$fixture_lib" "$fixture_scripts")
case "$(printf '%s' "$out" | grep '^drift=')" in
  drift=*ORCH_HOST_GATE_DEGRADED_EXIT_CODE*) ;;
  *) fail "drift+orphan fixture must list drifted token; got: $out" ;;
esac
case "$(printf '%s' "$out" | grep '^orphan=')" in
  orphan=*ORCH_REMOVED_EXIT_CODE*) ;;
  *) fail "drift+orphan fixture must list orphan token; got: $out" ;;
esac

# Case 5: missing manifest — every code-side token surfaces as drift.
out=$(exit_code_manifest_drift "$TEST_TMP/does-not-exist.md" "$fixture_lib" "$fixture_scripts")
case "$(printf '%s' "$out" | grep '^drift=')" in
  drift=*ORCH_DISPATCH_NOT_READY_EXIT_CODE*) ;;
  *) fail "missing manifest must surface code tokens as drift; got: $out" ;;
esac
case "$(printf '%s' "$out" | grep '^drift=')" in
  drift=*ORCH_HOST_GATE_DEGRADED_EXIT_CODE*) ;;
  *) fail "missing manifest must surface every code token; got: $out" ;;
esac
case "$(printf '%s' "$out" | grep '^drift=')" in
  drift=*ORCH_TIMEOUT_EXIT_CODE*) ;;
  *) fail "missing manifest must surface every code token; got: $out" ;;
esac
[ "$(printf '%s' "$out" | grep '^orphan=')" = "orphan=" ] || fail "missing manifest must report no orphan; got: $out"

# Case 6: multi-var sanity — duplicated mentions of the same token in code do
# not produce duplicate drift entries.
cat > "$fixture_lib/dup.sh" <<'EOF'
: "${ORCH_TIMEOUT_EXIT_CODE:=124}"
exit "$ORCH_TIMEOUT_EXIT_CODE"
echo "$ORCH_TIMEOUT_EXIT_CODE"
EOF
out=$(exit_code_manifest_drift "$manifest_clean" "$fixture_lib" "$fixture_scripts")
[ "$(printf '%s' "$out" | grep '^drift=')"  = "drift=" ]  || fail "duplicates must not produce drift; got: $out"
[ "$(printf '%s' "$out" | grep '^orphan=')" = "orphan=" ] || fail "duplicates must not produce orphan; got: $out"

# -----------------------------------------------------------------------------
# Real-repo scan
# -----------------------------------------------------------------------------
real_manifest="$ROOT/docs/exit-codes.md"
if [ -f "$real_manifest" ]; then
  out=$(exit_code_manifest_drift "$real_manifest" "$ROOT/lib" "$ROOT/scripts")
  drift_line=$(printf '%s' "$out" | grep '^drift=')
  if [ "$drift_line" != "drift=" ]; then
    fail "real-repo manifest drift detected: $drift_line — update docs/exit-codes.md"
  fi
else
  printf 'note - exit-codes manifest absent (%s) — drift enforcement disabled until PR #306 merges\n' \
    "$real_manifest"
fi

printf 'ok - test_exit_codes_manifest\n'
