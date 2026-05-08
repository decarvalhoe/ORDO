#!/usr/bin/env bash
# tests/test_portfolio_status_backlog.sh — backlog escalation counts and
# signal computation in portfolio_status.sh (#353).
#
# Cases:
#   1. Clean unblocker present (1 clean draft + 27 ci-failed drafts) →
#      backlog_signal=clean_unblocker_available, draft_prs=28,
#      failed_prs=27, failed_draft_prs=27, clean_unblocker_prs=1,
#      clean_unblocker_pr_numbers=["292"].
#   2. Drafts dominate (10/10 draft, 0 failed) → backlog_signal=drafts_blocked.
#   3. CI dominates on non-draft PRs (9/10 ci-failed, 0 draft) →
#      backlog_signal=ci_blocked.
#   4. Healthy project (3 open, 1 draft, 0 failed) → backlog_signal="".
#   5. Configurable threshold: PORTFOLIO_BACKLOG_DRAFT_RATIO_PCT=50 makes
#      a 50% drafts case fire drafts_blocked, while default (80%) does not.
#   6. Universality: identical fixtures with different alias names
#      produce identical signals (no project-name hardcoding).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"
trap 'rm -rf "$TEST_TMP"' EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/configs"

for rel in \
  scripts/portfolio_status.sh \
  lib/capacity_report.sh \
  lib/classifier_outage.sh \
  lib/config_resolver.sh \
  lib/lane_registry.sh \
  lib/portfolio_config.sh \
  lib/process_safety.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/portfolio_status.sh"

# Mocked agent_pool_status: one free agent so capacity exists. The
# backlog signal must NOT depend on agent state.
cat > "$SANITIZED_ROOT/scripts/agent_pool_status.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
[
  {"label":"agent-1","pane":"a:0.0","workdir":"/tmp/a","branch":"main","dirty":"0","pr":"","signals":[]}
]
JSON
EOF
chmod +x "$SANITIZED_ROOT/scripts/agent_pool_status.sh"

# Mocked pr_block_signals: SCENARIO env switches between the fixtures.
cat > "$SANITIZED_ROOT/scripts/pr_block_signals.sh" <<'PRBLOCK'
#!/usr/bin/env bash
case "${SCENARIO:-clean_unblocker}" in
  clean_unblocker)
    # 28 drafts: 1 clean (passes CI, draft) + 27 ci-failed drafts.
    # Emit a single clean unblocker (#292) and 27 failed draft PRs with
    # short PR numbers 1001..1027 (project-neutral, generic).
    {
      printf '['
      printf '{"pr":"292","branch":"infra-unblock","agent":"","merge_state":"BLOCKED","mergeable":"MERGEABLE","ci_fail":0,"ci_pending":0,"deploy_gate_pending":0,"base_current":"1","signals":["draft","ci-pass"]}'
      i=1001
      while [ "$i" -le 1027 ]; do
        printf ',{"pr":"%s","branch":"feat/dep-%s","agent":"","merge_state":"BLOCKED","mergeable":"MERGEABLE","ci_fail":1,"ci_pending":0,"deploy_gate_pending":0,"base_current":"1","signals":["draft","ci-failed"]}' "$i" "$i"
        i=$((i + 1))
      done
      printf ']'
    }
    ;;
  drafts_only)
    # 10 PRs, all drafts, all CI passing. Should fire drafts_blocked
    # (no clean unblocker because of empty pass list? wait — these
    # ARE clean unblockers). Use ci-pending so they are draft-only,
    # not "clean".
    {
      printf '['
      i=1
      while [ "$i" -le 10 ]; do
        sep=","
        [ "$i" -eq 1 ] && sep=""
        printf '%s{"pr":"%s","branch":"feat/d-%s","agent":"","merge_state":"BLOCKED","mergeable":"UNKNOWN","ci_fail":0,"ci_pending":1,"deploy_gate_pending":0,"base_current":"1","signals":["draft","ci-pending","mergeable-unknown"]}' "$sep" "$i" "$i"
        i=$((i + 1))
      done
      printf ']'
    }
    ;;
  ci_only)
    # 10 non-draft PRs, 9 ci-failed, 1 ci-pending → ci_blocked.
    {
      printf '['
      printf '{"pr":"500","branch":"feat/n-500","agent":"","merge_state":"BLOCKED","mergeable":"MERGEABLE","ci_fail":0,"ci_pending":1,"deploy_gate_pending":0,"base_current":"1","signals":["ci-pending"]}'
      i=501
      while [ "$i" -le 509 ]; do
        printf ',{"pr":"%s","branch":"feat/n-%s","agent":"","merge_state":"BLOCKED","mergeable":"MERGEABLE","ci_fail":1,"ci_pending":0,"deploy_gate_pending":0,"base_current":"1","signals":["ci-failed"]}' "$i" "$i"
        i=$((i + 1))
      done
      printf ']'
    }
    ;;
  healthy)
    # 3 open, 1 draft, 2 ci-pass clean → no backlog signal.
    cat <<'JSON'
[
  {"pr":"700","branch":"feat/h-1","agent":"","merge_state":"CLEAN","mergeable":"MERGEABLE","ci_fail":0,"ci_pending":0,"deploy_gate_pending":0,"base_current":"1","signals":["ci-pass","merge-ready"]},
  {"pr":"701","branch":"feat/h-2","agent":"","merge_state":"CLEAN","mergeable":"MERGEABLE","ci_fail":0,"ci_pending":0,"deploy_gate_pending":0,"base_current":"1","signals":["ci-pass","merge-ready"]},
  {"pr":"702","branch":"feat/h-3","agent":"","merge_state":"BLOCKED","mergeable":"UNKNOWN","ci_fail":0,"ci_pending":1,"deploy_gate_pending":0,"base_current":"1","signals":["draft","ci-pending","mergeable-unknown"]}
]
JSON
    ;;
  half_drafts)
    # 4/8 PRs are drafts (50%). Default threshold is 80% so no
    # drafts_blocked under defaults; with PORTFOLIO_BACKLOG_DRAFT_RATIO_PCT=50
    # it MUST fire drafts_blocked.
    {
      printf '['
      i=1
      while [ "$i" -le 4 ]; do
        sep=","
        [ "$i" -eq 1 ] && sep=""
        printf '%s{"pr":"%s","branch":"feat/h-%s","agent":"","merge_state":"BLOCKED","mergeable":"UNKNOWN","ci_fail":0,"ci_pending":1,"deploy_gate_pending":0,"base_current":"1","signals":["draft","ci-pending","mergeable-unknown"]}' "$sep" "$i" "$i"
        i=$((i + 1))
      done
      while [ "$i" -le 8 ]; do
        printf ',{"pr":"%s","branch":"feat/n-%s","agent":"","merge_state":"CLEAN","mergeable":"MERGEABLE","ci_fail":0,"ci_pending":0,"deploy_gate_pending":0,"base_current":"1","signals":["ci-pass","merge-ready"]}' "$i" "$i"
        i=$((i + 1))
      done
      printf ']'
    }
    ;;
  *)
    printf '[]\n'
    ;;
esac
PRBLOCK
chmod +x "$SANITIZED_ROOT/scripts/pr_block_signals.sh"

# Generic single-project portfolio. Alias name does not matter for the
# detector, but we use "demo-product" to make universality obvious.
cat > "$TEST_TMP/configs/demo.config.sh" <<'EOF'
PROJECT="demo-product"
GH_REPO="example/demo-product"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/tmp/gh"
AGENT_REPO_PREFIX="/tmp/demo-"
export AGENT_WORKDIR_TEMPLATE="/tmp/demo-%s"
EOF

cat > "$TEST_TMP/configs/portfolio.config.sh" <<EOF
PORTFOLIO_NAME="backlog-test"
PORTFOLIO_PROJECTS=(
  "demo-product|$TEST_TMP/configs/demo.config.sh"
)
PORTFOLIO_PRIORITIES=(
  "demo-product=100"
)
EOF

run_status() {
  local scenario=$1
  shift
  SCENARIO=$scenario \
  ORCH_STATE_BASE="$TEST_TMP/state-$scenario-$RANDOM" \
  "$@" \
  bash "$SANITIZED_ROOT/scripts/portfolio_status.sh" "$TEST_TMP/configs/portfolio.config.sh" --json
}

# --- Case 1: clean unblocker present. -------------------------------------

out=$(run_status clean_unblocker)
project=$(jq -r '.[0]' <<< "$out")
[[ -n "$project" ]] || fail "case 1: portfolio_status produced no project entry"
assert_field() {
  local got=$1 want=$2 desc=$3
  [[ "$got" == "$want" ]] || fail "$desc: got=$got want=$want"
}
assert_field "$(jq -r '.[0].backlog_signal' <<< "$out")"             "clean_unblocker_available" "case 1 backlog_signal"
assert_field "$(jq -r '.[0].counts.draft_prs' <<< "$out")"           "28"                         "case 1 draft_prs"
assert_field "$(jq -r '.[0].counts.failed_prs' <<< "$out")"          "27"                         "case 1 failed_prs"
assert_field "$(jq -r '.[0].counts.failed_draft_prs' <<< "$out")"    "27"                         "case 1 failed_draft_prs"
assert_field "$(jq -r '.[0].counts.clean_unblocker_prs' <<< "$out")" "1"                          "case 1 clean_unblocker_prs"
assert_field "$(jq -r '.[0].clean_unblocker_pr_numbers | join(",")' <<< "$out")" "292"             "case 1 unblocker pr number"

# --- Case 2: drafts dominate, no clean unblocker. -------------------------

out=$(run_status drafts_only)
assert_field "$(jq -r '.[0].backlog_signal' <<< "$out")"             "drafts_blocked"             "case 2 backlog_signal"
assert_field "$(jq -r '.[0].counts.draft_prs' <<< "$out")"           "10"                         "case 2 draft_prs"
assert_field "$(jq -r '.[0].counts.clean_unblocker_prs' <<< "$out")" "0"                          "case 2 clean_unblocker_prs"
# The fixture uses ci-pending, so failed_prs must be zero — drafts_blocked
# is correct, drafts_and_ci_blocked must NOT fire.
assert_field "$(jq -r '.[0].counts.failed_prs' <<< "$out")"          "0"                          "case 2 failed_prs"

# --- Case 3: CI failures dominate (non-draft). ----------------------------

out=$(run_status ci_only)
assert_field "$(jq -r '.[0].backlog_signal' <<< "$out")"             "ci_blocked"                 "case 3 backlog_signal"
assert_field "$(jq -r '.[0].counts.failed_prs' <<< "$out")"          "9"                          "case 3 failed_prs"
assert_field "$(jq -r '.[0].counts.draft_prs' <<< "$out")"           "0"                          "case 3 draft_prs"
assert_field "$(jq -r '.[0].counts.clean_unblocker_prs' <<< "$out")" "0"                          "case 3 clean_unblocker_prs"

# --- Case 4: healthy project — no backlog signal. -------------------------

out=$(run_status healthy)
assert_field "$(jq -r '.[0].backlog_signal' <<< "$out")"             ""                           "case 4 backlog_signal"
assert_field "$(jq -r '.[0].counts.draft_prs' <<< "$out")"           "1"                          "case 4 draft_prs"
assert_field "$(jq -r '.[0].counts.clean_unblocker_prs' <<< "$out")" "0"                          "case 4 clean_unblocker_prs (draft is ci-pending, not ci-pass)"

# --- Case 5: configurable threshold. --------------------------------------

# Default threshold (80%): half_drafts (50%) does NOT fire drafts_blocked.
out=$(run_status half_drafts)
assert_field "$(jq -r '.[0].backlog_signal' <<< "$out")"             ""                           "case 5a default threshold (80%) — no signal at 50% drafts"

# Lowered threshold to 50%: same fixture DOES fire drafts_blocked.
out=$(SCENARIO=half_drafts \
  PORTFOLIO_BACKLOG_DRAFT_RATIO_PCT=50 \
  ORCH_STATE_BASE="$TEST_TMP/state-half-50-$RANDOM" \
  bash "$SANITIZED_ROOT/scripts/portfolio_status.sh" "$TEST_TMP/configs/portfolio.config.sh" --json)
assert_field "$(jq -r '.[0].backlog_signal' <<< "$out")"             "drafts_blocked"             "case 5b drafts_blocked at threshold=50%"

# --- Case 6: universality — alias name does not affect signal. ------------

# Re-bind the same fixture under a totally different alias and project
# name. The signals must be identical to case 1.
cat > "$TEST_TMP/configs/foo.config.sh" <<'EOF'
PROJECT="some-other-project"
GH_REPO="example/some-other-project"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/tmp/gh"
AGENT_REPO_PREFIX="/tmp/foo-"
export AGENT_WORKDIR_TEMPLATE="/tmp/foo-%s"
EOF

cat > "$TEST_TMP/configs/portfolio2.config.sh" <<EOF
PORTFOLIO_NAME="backlog-test-2"
PORTFOLIO_PROJECTS=(
  "some-other-project|$TEST_TMP/configs/foo.config.sh"
)
PORTFOLIO_PRIORITIES=(
  "some-other-project=100"
)
EOF

out=$(SCENARIO=clean_unblocker \
  ORCH_STATE_BASE="$TEST_TMP/state-foo-$RANDOM" \
  bash "$SANITIZED_ROOT/scripts/portfolio_status.sh" "$TEST_TMP/configs/portfolio2.config.sh" --json)
assert_field "$(jq -r '.[0].backlog_signal' <<< "$out")"             "clean_unblocker_available"  "case 6 alias-independent signal"
assert_field "$(jq -r '.[0].counts.clean_unblocker_prs' <<< "$out")" "1"                          "case 6 clean_unblocker count"

printf 'ok - portfolio_status backlog escalation passes\n'
