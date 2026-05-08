#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/host_load_gate.sh
source "$ROOT/lib/host_load_gate.sh"
orch_host_load_gate "local_validator:run_bats" \
  "${ORCH_HOST_GATE_LOCAL_VALIDATORS_MODE:-${ORCH_HOST_GATE_MODE:-off}}"
orch_validator_fork_preflight "run_bats"

if [[ "${ORCH_VALIDATOR_SEMAPHORE_HELD:-0}" != "1" ]]; then
  export ORCH_VALIDATOR_SEMAPHORE_HELD=1
  orch_validator_run_with_semaphore "run_bats" bash "$0" "$@"
  exit $?
fi

TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

find_bats_bin() {
  if [[ -n "${BATS_BIN:-}" ]]; then
    printf '%s\n' "$BATS_BIN"
    return 0
  fi

  if command -v bats >/dev/null 2>&1; then
    command -v bats
    return 0
  fi

  if [[ -x "$HOME/.local/bin/bats" ]]; then
    printf '%s\n' "$HOME/.local/bin/bats"
    return 0
  fi

  printf '%s\n' "bats not found; set BATS_BIN or install bats" >&2
  return 1
}

mirror_file() {
  local rel=${1:?usage: mirror_file <repo-relative-path>}
  local dest="$SANITIZED_ROOT/$rel"
  mkdir -p "$(dirname "$dest")"
  tr -d '\r' < "$ROOT/$rel" > "$dest"
  # Mirror the source file's mode bits so that bats suites which exec
  # mirrored scripts directly do not hit a 126 (permission denied / not
  # executable) failure (#325). Match the pattern used by run_shellcheck.sh
  # and run_shell_tests.sh: `chmod --reference` first, with a `+x` fallback
  # for environments where --reference is unavailable.
  chmod --reference="$ROOT/$rel" "$dest" 2>/dev/null || \
    { [[ -x "$ROOT/$rel" ]] && chmod +x "$dest"; }
}

mirror_test_fixtures() {
  # Mirror non-source test artifacts (fixture data, golden output,
  # snapshots, sample inputs) so bats suites that load TSV baselines,
  # JSON inputs, or any other non-extension-allowlisted file find their
  # data under the sanitized toolkit (#326). Complements the
  # extension-driven mirror above (which handles *.sh / *.bash / *.bats /
  # *.md / *.txt) and reuses mirror_file so the mode-bit preservation
  # introduced for #325 still applies to anything that happens to be
  # executable (for example a fixture-side helper script under
  # tests/fixtures/).
  local subdir abs_path rel_path
  for subdir in fixtures data golden snapshots; do
    [[ -d "$ROOT/tests/$subdir" ]] || continue
    while IFS= read -r abs_path; do
      rel_path=${abs_path#"$ROOT"/}
      mirror_file "$rel_path"
    done < <(find "$ROOT/tests/$subdir" -type f | sort)
  done
}

mkdir -p "$SANITIZED_ROOT"

while IFS= read -r abs_path; do
  rel_path=${abs_path#"$ROOT"/}
  mirror_file "$rel_path"
done < <(
  find \
    "$ROOT/config" \
    "$ROOT/examples" \
    "$ROOT/lib" \
    "$ROOT/scripts" \
    "$ROOT/templates" \
    "$ROOT/tests" \
    -type f \
    \( -name '*.sh' -o -name '*.bash' -o -name '*.bats' -o -name '*.config.sh' -o -name '*.md' -o -name '*.txt' -o -name '*.tpl' \) \
    | sort
)

mirror_test_fixtures

mirror_file "install.sh"

bats_bin=$(find_bats_bin)

cd "$SANITIZED_ROOT"
"$bats_bin" tests/*.bats
