#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

if ! command -v shellcheck >/dev/null 2>&1; then
  printf '%s\n' "shellcheck not found" >&2
  exit 1
fi

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
    "$ROOT/examples" \
    "$ROOT/lib" \
    "$ROOT/scripts" \
    "$ROOT/tests" \
    -type f \
    \( -name '*.sh' -o -name '*.bash' -o -name '*.config.sh' \) \
    | sort
)

mirror_file "install.sh"

cd "$SANITIZED_ROOT"

shellcheck -e SC1090,SC1091 -x \
  install.sh \
  lib/*.sh \
  scripts/*.sh \
  tests/*.sh \
  tests/*.bash
