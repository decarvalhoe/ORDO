#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

# shellcheck source=../lib/host_load_gate.sh
source "$ROOT/lib/host_load_gate.sh"
orch_host_load_gate "local_validator:run_bats" \
  "${ORCH_HOST_GATE_LOCAL_VALIDATORS_MODE:-${ORCH_HOST_GATE_MODE:-off}}"
orch_validator_fork_preflight "run_bats"

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
    \( -name '*.sh' -o -name '*.bash' -o -name '*.bats' -o -name '*.config.sh' -o -name '*.md' -o -name '*.txt' \) \
    | sort
)

mirror_file "install.sh"

bats_bin=$(find_bats_bin)

cd "$SANITIZED_ROOT"
"$bats_bin" tests/*.bats
