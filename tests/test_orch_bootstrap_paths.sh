#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

legacy_path="RBOK-orchestrator/orchestrator-toolkit"
expected_tk_literal="TK=\${TK:-\$(pwd)}"
docs=(
  "$ROOT/README.md"
  "$ROOT/templates/orch_briefing.md"
)

for doc in "${docs[@]}"; do
  [[ -f "$doc" ]] || fail "missing bootstrap doc: ${doc#"$ROOT"/}"
done

if grep -RIn --fixed-strings -- "$legacy_path" "${docs[@]}" >&2; then
  fail "legacy ORDO bootstrap toolkit path is still documented"
fi

grep -Fq "$expected_tk_literal" "$ROOT/templates/orch_briefing.md" \
  || fail "orch briefing should default TK to the current checkout"

printf 'ok - ORDO bootstrap docs do not reference legacy toolkit paths\n'
