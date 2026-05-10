#!/usr/bin/env bash
# tests/test_dmaic_default_off.sh - guard the Level 2 project-DMAIC
# default-off invariant (#438).
#
# The project-DMAIC runtime helpers are tracked by sibling issues
# (#240/#241/#242/#243). On bases where the module command has not landed yet,
# this test still guards the published contract: Level 2 remains opt-in and
# disabled by default. Once scripts/sixsigma_project_module.sh exists, the same
# test exercises the concrete scaffold, gate, and evidence-ledger behavior.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

json_contains_disabled() {
  local json=$1
  jq -e '[.. | strings] | map(ascii_downcase) | join(" ") | test("disabled")' \
    <<< "$json" >/dev/null
}

json_not_disabled() {
  local json=$1
  ! json_contains_disabled "$json"
}

assert_no_dmaic_files() {
  local target=$1
  local hit
  if [[ ! -d "$target" ]]; then
    return 0
  fi
  hit=$(find "$target" -type f \
    \( -ipath '*/sixsigma/*' -o -iname '*dmaic*' -o -iname '*ledger*' \) \
    -print -quit)
  if [[ -n "$hit" ]]; then
    fail "disabled project must not create DMAIC dossier or ledger files"
  fi
}

assert_has_dmaic_files() {
  local target=$1
  local hit
  hit=$(find "$target" -type f \
    \( -ipath '*/sixsigma/*' -o -iname '*dmaic*' -o -iname '*ledger*' \) \
    -print -quit)
  [[ -n "$hit" ]] || fail "enabled project should create DMAIC dossier or ledger files"
}

assert_has_ledger_file() {
  local target=$1
  local hit
  hit=$(find "$target" -type f \( -iname '*ledger*' -o -ipath '*/evidence/*' \) \
    -print -quit)
  [[ -n "$hit" ]] || fail "enabled project should activate evidence ledger output"
}

run_module_json() {
  local config=$1 mode=$2 target=$3
  shift 3
  local stdout stderr status
  stdout="$TEST_TMP/${mode}.stdout.json"
  stderr="$TEST_TMP/${mode}.stderr.txt"

  set +e
  bash "$SANITIZED_ROOT/scripts/sixsigma_project_module.sh" "$config" "$mode" \
    --target-dir "$target" \
    --dossier-dir ".ordo/sixsigma" \
    --json \
    "$@" \
    >"$stdout" 2>"$stderr"
  status=$?
  set -e

  case "$status" in
    0|78) ;;
    *)
      fail "sixsigma_project_module.sh $mode exited $status: $(cat "$stderr")"
      ;;
  esac
  [[ -s "$stdout" ]] \
    || fail "sixsigma_project_module.sh $mode should emit JSON on stdout"
  cat "$stdout"
}

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"

extra_paths=()
if [[ -f "$ROOT/scripts/sixsigma_project_module.sh" ]]; then
  extra_paths+=(scripts/sixsigma_project_module.sh)
fi
sanitize_toolkit_copy "$SANITIZED_ROOT" "${extra_paths[@]}"

module_cli="$SANITIZED_ROOT/scripts/sixsigma_project_module.sh"
if [[ ! -f "$module_cli" ]]; then
  sixsigma_doc="$ROOT/docs/sixsigma/README.md"
  [[ -f "$sixsigma_doc" ]] || fail "missing Six Sigma architecture doc"
  grep -Eiq 'Level 2.*opt-in|opt-in project DMAIC module' "$sixsigma_doc" \
    || fail "Level 2 doc must identify the project-DMAIC module as opt-in"
  grep -Eiq 'disabled by default' "$sixsigma_doc" \
    || fail "Level 2 doc must state the project-DMAIC module is disabled by default"
  grep -qF 'scripts/sixsigma_project_scaffold.sh' "$sixsigma_doc" \
    || fail "Level 2 doc must keep the scaffold helper as a tracked placeholder"

  printf 'ok - dmaic default-off invariant registered; runtime helpers are pending sibling issues\n'
  exit 0
fi

disabled_config="$TEST_TMP/dmaic-disabled.config.sh"
enabled_config="$TEST_TMP/dmaic-enabled.config.sh"
disabled_target="$TEST_TMP/disabled-project"
enabled_target="$TEST_TMP/enabled-project"
mkdir -p "$disabled_target" "$enabled_target"
git init -q "$disabled_target"
git -C "$disabled_target" symbolic-ref HEAD refs/heads/main
git init -q "$enabled_target"
git -C "$enabled_target" symbolic-ref HEAD refs/heads/main

cat > "$disabled_config" <<'EOF'
PROJECT="dmaic-disabled-fixture"
DEFAULT_BRANCH="main"
SIXSIGMA_PROJECT_DOSSIER_DIR=".ordo/sixsigma"
EOF

cat > "$enabled_config" <<'EOF'
PROJECT="dmaic-enabled-fixture"
DEFAULT_BRANCH="main"
SIXSIGMA_PROJECT_ENABLED=1
SIXSIGMA_BY_DESIGN_DEFAULT=1
SIXSIGMA_PROJECT_DOSSIER_DIR=".ordo/sixsigma"
EOF

# Default-off assertion 1: scaffold mode reports disabled and creates no
# project-DMAIC dossier files.
disabled_scaffold_json=$(run_module_json "$disabled_config" scaffold "$disabled_target" --apply)
json_contains_disabled "$disabled_scaffold_json" \
  || fail "disabled scaffold must report an explicit disabled rationale"
assert_no_dmaic_files "$disabled_target"

# Default-off assertion 2: gate mode short-circuits with an explicit disabled
# rationale.
disabled_gate_json=$(run_module_json "$disabled_config" gate "$disabled_target" --phase define)
json_contains_disabled "$disabled_gate_json" \
  || fail "disabled gate must report an explicit disabled rationale"

# Default-off assertion 3: disabled paths do not auto-emit evidence ledger rows.
assert_no_dmaic_files "$disabled_target"

# Opt-in assertion: enabling the project flips scaffold, gate, and ledger
# behavior away from disabled.
enabled_scaffold_json=$(run_module_json "$enabled_config" scaffold "$enabled_target" --apply)
json_not_disabled "$enabled_scaffold_json" \
  || fail "enabled scaffold must not report disabled"
assert_has_dmaic_files "$enabled_target"
assert_has_ledger_file "$enabled_target"

enabled_gate_json=$(run_module_json "$enabled_config" gate "$enabled_target" --phase define)
json_not_disabled "$enabled_gate_json" \
  || fail "enabled gate must not report disabled"

printf 'ok - dmaic project module stays default-off and explicit opt-in activates scaffold, gate, and ledger paths\n'
