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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/configs"

for rel in \
  scripts/portfolio_poc.sh \
  lib/config_resolver.sh \
  lib/portfolio_config.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/portfolio_poc.sh"

cat > "$SANITIZED_ROOT/scripts/portfolio_status.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
[
  {"alias":"alpha","priority":20,"gate_state":"dispatchable","rebalance_signal":"dispatch_capacity_available","counts":{"free":1,"dirty":0,"local_work":0,"open_prs":0}},
  {"alias":"beta","priority":10,"gate_state":"review_wait","rebalance_signal":"","counts":{"free":0,"dirty":1,"local_work":1,"open_prs":1}}
]
JSON
EOF

cat > "$SANITIZED_ROOT/scripts/portfolio_session_start.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
[
  {"alias":"alpha","priority":20,"label":"worker","ready":1,"status":"ready"},
  {"alias":"beta","priority":10,"label":"worker","ready":0,"status":"dirty_worktree"}
]
JSON
EOF

cat > "$SANITIZED_ROOT/scripts/agent_product_switch.sh" <<'EOF'
#!/usr/bin/env bash
printf 'DRY-RUN: portfolio unblock task id=test code=target-dirty-worktree action=Review target\n'
EOF

for script in agent_pool_status pr_block_signals; do
  cat > "$SANITIZED_ROOT/scripts/${script}.sh" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
done

cat > "$SANITIZED_ROOT/scripts/dispatch_plan.sh" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" --atomize "*)
    printf 'DRY-RUN: gh issue create --repo example/repo --title "[parent #1] child" --body-file <generated> # parent=1 trace=ORDO-ATOMIZE:test\n'
    ;;
  *)
    printf '[]\n'
    ;;
esac
EOF

cat > "$SANITIZED_ROOT/scripts/gh_actions_optimize.sh" <<'EOF'
#!/usr/bin/env bash
printf 'INFO\tgha-ok\t.github/workflows/ci.yml\tok\n'
EOF

cat > "$SANITIZED_ROOT/scripts/sixsigma_autoupgrade.sh" <<'EOF'
#!/usr/bin/env bash
printf 'DRY-RUN: sixsigma\n'
EOF

chmod +x "$SANITIZED_ROOT"/scripts/*.sh

cat > "$TEST_TMP/configs/alpha.config.sh" <<'EOF'
PROJECT="alpha"
GH_REPO="example/alpha"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/tmp/gh"
AGENT_REPO_PREFIX="/tmp/alpha-"
export AGENT_WORKDIR_TEMPLATE="/tmp/alpha-%s"
EOF

cat > "$TEST_TMP/configs/beta.config.sh" <<'EOF'
PROJECT="beta"
GH_REPO="example/beta"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/tmp/gh"
AGENT_REPO_PREFIX="/tmp/beta-"
export AGENT_WORKDIR_TEMPLATE="/tmp/beta-%s"
EOF

cat > "$TEST_TMP/configs/portfolio.config.sh" <<EOF
PORTFOLIO_NAME="test"
PORTFOLIO_PROJECTS=(
  "alpha|$TEST_TMP/configs/alpha.config.sh"
  "beta|$TEST_TMP/configs/beta.config.sh"
)
PORTFOLIO_PRIORITIES=(
  "alpha=20"
  "beta=10"
)
EOF

local_out="$TEST_TMP/local-poc"
local_output=$(
  bash "$SANITIZED_ROOT/scripts/portfolio_poc.sh" "$TEST_TMP/configs/portfolio.config.sh" \
    --phase local \
    --output-dir "$local_out" \
    --switch alpha:worker:beta:worker
)
[[ "$local_output" == *"$local_out/report.md"* ]] || fail "local POC should print report path: $local_output"
[[ -s "$local_out/report.md" ]] || fail "local report missing"
jq -e 'select(.phase == "local" and .priority_mode == "explicit")' "$local_out/manifest.json" >/dev/null \
  || fail "manifest missing local phase"
jq -s 'map(select(.name == "local_soft_switch_dry_run" and .status == 0)) | length == 1' "$local_out/steps.jsonl" >/dev/null \
  || fail "switch dry-run step missing"

fleet_out="$TEST_TMP/fleet-poc"
bash "$SANITIZED_ROOT/scripts/portfolio_poc.sh" "$TEST_TMP/configs/portfolio.config.sh" \
  --phase fleet \
  --output-dir "$fleet_out" >/dev/null
jq -s 'map(select(.name == "fleet_alpha_agent_pool_status" or .name == "fleet_beta_sixsigma_dry_run")) | length == 2' \
  "$fleet_out/steps.jsonl" >/dev/null \
  || fail "fleet steps missing"
jq -s 'map(select(.name == "fleet_alpha_dispatch_plan_atomize_dry_run" and .status == 0)) | length == 1' \
  "$fleet_out/steps.jsonl" >/dev/null \
  || fail "fleet atomize dry-run step missing"
[[ "$(cat "$fleet_out/fleet_alpha_dispatch_plan_atomize_dry_run.out")" == *"ORDO-ATOMIZE:"* ]] \
  || fail "fleet atomize dry-run should preserve trace marker"
[[ -s "$fleet_out/report.md" ]] || fail "fleet report missing"

cat > "$TEST_TMP/configs/no-priority.config.sh" <<EOF
PORTFOLIO_NAME="missing-priority"
PORTFOLIO_PROJECTS=(
  "alpha|$TEST_TMP/configs/alpha.config.sh"
)
EOF

set +e
missing_output=$(bash "$SANITIZED_ROOT/scripts/portfolio_poc.sh" "$TEST_TMP/configs/no-priority.config.sh" --output-dir "$TEST_TMP/missing" 2>&1)
missing_status=$?
set -e
[[ "$missing_status" -eq 14 ]] || fail "missing priorities should exit 14, got $missing_status: $missing_output"
[[ "$missing_output" == *'portfolio priorities are required'* ]] || fail "missing priority message unclear: $missing_output"

yolo_out="$TEST_TMP/yolo-poc"
bash "$SANITIZED_ROOT/scripts/portfolio_poc.sh" "$TEST_TMP/configs/no-priority.config.sh" \
  --phase local \
  --output-dir "$yolo_out" \
  --yolo-priority >/dev/null
jq -e 'select(.priority_mode == "yolo")' "$yolo_out/manifest.json" >/dev/null \
  || fail "yolo priority mode missing"

printf 'ok - portfolio_poc runs local and fleet POC reports\n'
