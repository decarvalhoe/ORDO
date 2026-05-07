#!/usr/bin/env bash
# tests/test_test_sanitize.sh — coverage for #148 sanitize_toolkit_copy.
#
# Validates that the helper:
#   - copies every lib/*.sh from $ROOT into $dest/lib (default sweep);
#   - normalizes CRLF into LF on every copied file;
#   - copies extra paths under scripts/, templates/, examples/;
#   - silently ignores extra entries that already match the lib/ sweep;
#   - preserves the executable bit when the source is executable;
#   - returns 1 with a diagnostic when an extra path is missing.
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

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"

dest="$TEST_TMP/toolkit"

sanitize_toolkit_copy "$dest" \
  scripts/orch_ctl.sh \
  templates/dispatch-canonical.md.tpl \
  examples/realisons-wp.config.sh

# 1) Every lib/*.sh from the repo must exist under dest/lib (default sweep).
for src in "$ROOT"/lib/*.sh; do
  rel="lib/$(basename "$src")"
  [[ -f "$dest/$rel" ]] || fail "default sweep missed $rel"
done

# 2) CRLF must be stripped: copies must not contain a literal carriage
# return even if (hypothetically) the source did.
if grep -lU $'\r' "$dest"/lib/*.sh "$dest"/scripts/*.sh "$dest"/templates/* >/dev/null 2>&1; then
  fail "sanitize_toolkit_copy must strip CRLF on every copied file"
fi

# 3) Extra paths landed in the right shape.
for rel in scripts/orch_ctl.sh templates/dispatch-canonical.md.tpl examples/realisons-wp.config.sh; do
  [[ -f "$dest/$rel" ]] || fail "extra path $rel was not copied"
done

# 4) Executable bit on extras under scripts/ is always +x (script convention),
# even on hosts whose intermediate copies already stripped the bit.
[[ -x "$dest/scripts/orch_ctl.sh" ]] || \
  fail "executable bit must be preserved for scripts/orch_ctl.sh"
# And NOT granted on a non-executable extra outside scripts/ (config example).
if [[ -x "$dest/examples/realisons-wp.config.sh" ]] && \
  [[ ! -x "$ROOT/examples/realisons-wp.config.sh" ]]; then
  fail "non-executable extras must not gain +x"
fi

# 5) lib/*.sh entries passed as extras are silently absorbed by the sweep
# (regression guard: the whole point of #148 is no per-test list).
sanitize_toolkit_copy "$TEST_TMP/toolkit-2" \
  lib/audit_log.sh \
  lib/log_bounds.sh \
  lib/process_safety.sh
[[ -f "$TEST_TMP/toolkit-2/lib/audit_log.sh" ]] || \
  fail "lib/* extras should still be present via the default sweep"

# 6) Missing extras must surface a clear error and a non-zero status.
set +e
err=$(sanitize_toolkit_copy "$TEST_TMP/toolkit-3" scripts/this_does_not_exist.sh 2>&1)
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "missing extra must yield non-zero exit"
[[ "$err" == *"missing source file"* ]] || \
  fail "missing extra must mention 'missing source file', got: $err"

# 7) Unset ROOT must surface a clear error and a non-zero status.
set +e
err=$(ROOT="" sanitize_toolkit_copy "$TEST_TMP/toolkit-4" 2>&1)
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "missing ROOT must yield non-zero exit"
[[ "$err" == *"ROOT must point at the repo root"* ]] || \
  fail "missing ROOT must mention diagnostic, got: $err"

# 8) CRLF normalization works when the source genuinely has CR bytes
# (synthetic fixture so we do not need a CRLF file in the repo).
fixture_root="$TEST_TMP/fixture-root"
mkdir -p "$fixture_root/lib" "$fixture_root/scripts"
printf 'echo lib\r\n' > "$fixture_root/lib/with_crlf.sh"
printf 'echo script\r\n' > "$fixture_root/scripts/with_crlf.sh"
chmod +x "$fixture_root/scripts/with_crlf.sh"

(
  ROOT="$fixture_root"
  sanitize_toolkit_copy "$TEST_TMP/toolkit-5" scripts/with_crlf.sh
)

if grep -lU $'\r' "$TEST_TMP/toolkit-5"/lib/*.sh "$TEST_TMP/toolkit-5"/scripts/*.sh >/dev/null 2>&1; then
  fail "synthetic CRLF source was not normalized in the copy"
fi
[[ -x "$TEST_TMP/toolkit-5/scripts/with_crlf.sh" ]] || \
  fail "synthetic +x source must remain executable in the copy"

printf 'ok - sanitize_toolkit_copy auto-imports lib/*.sh and copies extras safely\n'
