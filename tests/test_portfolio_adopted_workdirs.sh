#!/usr/bin/env bash
# tests/test_portfolio_adopted_workdirs.sh — #672
# shellcheck disable=SC2034
#
# Verify that `portfolio_status.sh` reconciles adopted assignment workdirs
# (e.g. /root/repos/RBOK-codex-2) as first-class capacity metadata so they
# stop being reported as `cap_switch_required` / `cap_local_work` drift.
#
# Cases:
#   1. Adopted lib helpers parse PORTFOLIO_ADOPTED_WORKDIRS entries and
#      emit a structured JSON view that callers can filter per-project.
#   2. PORTFOLIO_ADOPTED_WORKDIRS entries scope project=foo only attach
#      to that project's summary.
#   3. portfolio_status.sh re-buckets an agent whose pane points at an
#      adopted workdir from cap_switch_required to cap_adopted.
#   4. portfolio_status.sh re-buckets an agent whose live local_work
#      branch matches an adopted workdir into cap_adopted, leaving
#      true drift (unrelated agent on a feature branch) in cap_local_work.
#   5. cap_switch_required is still emitted when an agent's pane is in
#      an unrelated path with no matching adoption record.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local got=$1 want=$2 desc=$3
  [[ "$got" == "$want" ]] || fail "$desc: got='$got' want='$want'"
}

# ---------------------------------------------------------------------------
# Case 1 — lib helpers parse PORTFOLIO_ADOPTED_WORKDIRS entries.
# ---------------------------------------------------------------------------

(
  # shellcheck source=../lib/portfolio_config.sh
  source "$ROOT/lib/portfolio_config.sh"
  PORTFOLIO_ADOPTED_WORKDIRS=(
    "agent-005|/root/repos/RBOK-codex-2|issue=123|pr=456|project=rbok|pane=rbok:0.0"
    "agent-011|/root/repos/RBOK-gemini-2|issue=789|reason=adopted-by-operator"
  )
  json=$(portfolio_adopted_workdirs_json)
  count=$(printf '%s' "$json" | jq 'length')
  [[ "$count" == "2" ]] || fail "case 1: expected 2 adopted entries, got $count: $json"
  pr_value=$(printf '%s' "$json" | jq -r '.[0].pr')
  [[ "$pr_value" == "456" ]] || fail "case 1: expected pr=456, got '$pr_value'"
  reason_value=$(printf '%s' "$json" | jq -r '.[1].reason')
  [[ "$reason_value" == "adopted-by-operator" ]] || fail "case 1: expected reason from second entry, got '$reason_value'"
)

# ---------------------------------------------------------------------------
# Case 2 — project-scoped filter only returns entries for the alias.
# ---------------------------------------------------------------------------

(
  # shellcheck source=../lib/portfolio_config.sh
  source "$ROOT/lib/portfolio_config.sh"
  PORTFOLIO_ADOPTED_WORKDIRS=(
    "agent-005|/root/repos/RBOK-codex-2|project=alpha"
    "agent-011|/root/repos/RBOK-gemini-2|project=beta"
    "agent-006|/root/repos/RBOK-cursor-2|"
  )
  json=$(portfolio_adopted_workdirs_json)
  alpha=$(portfolio_adopted_workdirs_for_project alpha "$json")
  beta=$(portfolio_adopted_workdirs_for_project beta "$json")
  # alpha-scope entry + global entry => 2 visible to alpha.
  assert_eq "$(printf '%s' "$alpha" | jq 'length')" "2" "case 2 alpha count"
  assert_eq "$(printf '%s' "$beta"  | jq 'length')" "2" "case 2 beta count"
  alpha_labels=$(printf '%s' "$alpha" | jq -r '.[].label' | sort | paste -sd, -)
  assert_eq "$alpha_labels" "agent-005,agent-006" "case 2 alpha labels"
)

# ---------------------------------------------------------------------------
# Cases 3–5 — drive portfolio_status.sh end-to-end with a fake agent_pool
# and pr_block_signals adapter so we observe the actual JSON shape.
# ---------------------------------------------------------------------------

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/configs"
for rel in \
  scripts/portfolio_status.sh \
  lib/config_resolver.sh \
  lib/portfolio_config.sh \
  lib/process_safety.sh \
  lib/lane_registry.sh \
  lib/capacity_report.sh \
  lib/classifier_outage.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/portfolio_status.sh"

# Stub child scripts the portfolio runner shells out to. The pool models
# the canonical bug from #672:
#   agent-005: pane in adopted RBOK-codex-2 dir, clean clone, classifier
#              already flagged it as switch_required.
#   agent-011: clean clone on a feature branch tied to adopted RBOK-gemini-2,
#              classifier flagged it as local_work.
#   agent-007: clean clone on a feature branch with no adoption record,
#              must remain in cap_local_work (true drift).
#   drift-x:   pane in /tmp/elsewhere with no adoption record, must remain
#              in cap_switch_required.
#   default-y: clean default branch, available — sanity check.
cat > "$SANITIZED_ROOT/scripts/agent_pool_status.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
[
  {"label":"agent-005","pane":"rbok:0.0","assigned_workdir":"/root/repos/fleet-agent-005","live_pane_cwd":"/root/repos/RBOK-codex-2","capacity_class":"switch_required","branch":"main","dirty":"0","pr":"","signals":["needs-product-switch"]},
  {"label":"agent-011","pane":"rbok:0.1","assigned_workdir":"/root/repos/RBOK-gemini-2","live_pane_cwd":"/root/repos/RBOK-gemini-2","capacity_class":"local_work","branch":"feat/adopted-789","dirty":"0","pr":"","signals":[]},
  {"label":"agent-007","pane":"shared:0.2","assigned_workdir":"/root/repos/fleet-agent-007","live_pane_cwd":"/root/repos/fleet-agent-007","capacity_class":"local_work","branch":"feat/something","dirty":"0","pr":"","signals":[]},
  {"label":"drift-x","pane":"shared:0.3","assigned_workdir":"/root/repos/fleet-drift-x","live_pane_cwd":"/tmp/elsewhere","capacity_class":"switch_required","branch":"main","dirty":"0","pr":"","signals":["needs-product-switch"]},
  {"label":"default-y","pane":"shared:0.4","assigned_workdir":"/root/repos/fleet-default-y","live_pane_cwd":"/root/repos/fleet-default-y","capacity_class":"available","branch":"main","dirty":"0","pr":"","signals":[]}
]
JSON
EOF
chmod +x "$SANITIZED_ROOT/scripts/agent_pool_status.sh"

cat > "$SANITIZED_ROOT/scripts/pr_block_signals.sh" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
chmod +x "$SANITIZED_ROOT/scripts/pr_block_signals.sh"

cat > "$TEST_TMP/configs/alpha.config.sh" <<'EOF'
PROJECT="alpha"
GH_REPO="example/alpha"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/tmp/gh"
AGENT_REPO_PREFIX="/root/repos/fleet-"
export AGENT_WORKDIR_TEMPLATE="/root/repos/fleet-%s"
EOF

cat > "$TEST_TMP/configs/portfolio.config.sh" <<EOF
PORTFOLIO_NAME="adopted-test"
PORTFOLIO_PROJECTS=(
  "alpha|$TEST_TMP/configs/alpha.config.sh"
)
PORTFOLIO_PRIORITIES=(
  "alpha=100"
)
PORTFOLIO_ADOPTED_WORKDIRS=(
  "agent-005|/root/repos/RBOK-codex-2|issue=123|pr=456|project=alpha|pane=rbok:0.0"
  "agent-011|/root/repos/RBOK-gemini-2|issue=789|project=alpha"
)
EOF

output=$(ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/portfolio_status.sh" \
  "$TEST_TMP/configs/portfolio.config.sh" --json)

# Case 3 — agent-005 (pane in adopted dir) is now in cap_adopted, not switch_required.
adopted_labels=$(printf '%s' "$output" | jq -r '.[0].capacity_reconciliation.adopted_labels | sort | join(",")')
assert_eq "$adopted_labels" "agent-005,agent-011" "case 3 adopted_labels"

# cap_switch_required must NOT include agent-005 anymore.
switch_labels=$(printf '%s' "$output" | jq -r '.[0].capacity_reconciliation.switch_required_labels | sort | join(",")')
assert_eq "$switch_labels" "drift-x" "case 3 switch_required_labels (must keep drift only)"

# Case 4 — agent-011 (local_work on adopted dir) is in cap_adopted; agent-007 stays in local_work.
local_labels=$(printf '%s' "$output" | jq -r '.[0].capacity_reconciliation.local_work_labels | sort | join(",")')
assert_eq "$local_labels" "agent-007" "case 4 local_work_labels (true drift only)"

# Case 5 — cap_switch_required count is exactly 1 (drift-x).
switch_count=$(printf '%s' "$output" | jq -r '.[0].capacity_reconciliation.switch_required')
assert_eq "$switch_count" "1" "case 5 switch_required count"
adopted_count=$(printf '%s' "$output" | jq -r '.[0].capacity_reconciliation.adopted')
assert_eq "$adopted_count" "2" "case 5 adopted count"

# Adopted records carry the operator-supplied metadata for downstream
# consumers (issue, pr, reason). Verify the issue field round-trips.
agent_005_issue=$(printf '%s' "$output" \
  | jq -r '.[0].capacity_reconciliation.adopted_records[] | select(.label=="agent-005") | .issue')
assert_eq "$agent_005_issue" "123" "case 5 adopted_records carries issue"

# Adopted agents are listed in the agents.adopted bucket as well.
agents_adopted=$(printf '%s' "$output" | jq -r '.[0].agents.adopted | sort | join(",")')
assert_eq "$agents_adopted" "agent-005,agent-011" "case 5 agents.adopted bucket"

# TSV header must advertise the new cap_adopted column so downstream
# consumers can opt-in without parsing JSON.
tsv_output=$(ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/portfolio_status.sh" \
  "$TEST_TMP/configs/portfolio.config.sh" --tsv | head -n1)
case "$tsv_output" in
  *cap_adopted*cap_adopted_agents*)
    ;;
  *)
    fail "case 5 TSV header missing cap_adopted columns: $tsv_output"
    ;;
esac

printf 'ok - test_portfolio_adopted_workdirs.sh\n'
