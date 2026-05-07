#!/usr/bin/env bash
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

mkdir -p "$SANITIZED_ROOT/lib" "$SANITIZED_ROOT/examples" "$TEST_TMP/configs"

for rel in \
  lib/config_resolver.sh \
  lib/portfolio_config.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done

cat > "$TEST_TMP/configs/project.config.sh" <<'EOF'
PROJECT="portfolio-config-test"
GH_REPO="example/project"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/tmp/gh"
AGENT_REPO_PREFIX="/tmp/project-"
export AGENT_WORKDIR_TEMPLATE="/tmp/project-%s"
EOF

portfolio_cfg="$TEST_TMP/configs/portfolio.config.sh"
{
  printf 'PORTFOLIO_NAME="pipe-test"\n'
  printf 'PORTFOLIO_PROJECTS=(\n'
  for i in $(seq 1 20000); do
    printf '  "project-%05d|%s"\n' "$i" "$TEST_TMP/configs/project.config.sh"
  done
  printf ')\n'
  printf 'PORTFOLIO_PRIORITIES=(\n'
  for i in $(seq 1 20000); do
    printf '  "project-%05d=%d"\n' "$i" "$i"
  done
  printf ')\n'
} > "$portfolio_cfg"

set +e
entries_output=$(
  trap '' PIPE
  set -o pipefail
  # shellcheck source=/dev/null
  source "$SANITIZED_ROOT/lib/portfolio_config.sh"
  load_portfolio_config "$portfolio_cfg"
  portfolio_project_entries | head -n 1 >/dev/null
) 2>&1
entries_status=$?
set -e

[[ "$entries_status" -eq 0 ]] || fail "portfolio_project_entries should tolerate early pipe close, got $entries_status: $entries_output"
[[ "$entries_output" != *"Broken pipe"* ]] || fail "portfolio_project_entries leaked Broken pipe noise: $entries_output"

set +e
fleet_output=$(
  trap '' PIPE
  set -o pipefail
  # shellcheck source=/dev/null
  source "$SANITIZED_ROOT/lib/portfolio_config.sh"
  PORTFOLIO_FLEET_AGENTS=()
  for i in $(seq 1 20000); do
    PORTFOLIO_FLEET_AGENTS+=("agent-$i|pane-$i:0.0")
  done
  portfolio_fleet_spec | head -n 1 >/dev/null
) 2>&1
fleet_status=$?
set -e

[[ "$fleet_status" -eq 0 ]] || fail "portfolio_fleet_spec should tolerate early pipe close, got $fleet_status: $fleet_output"
[[ "$fleet_output" != *"Broken pipe"* ]] || fail "portfolio_fleet_spec leaked Broken pipe noise: $fleet_output"

printf 'ok - portfolio_config emitters tolerate early pipe close\n'
