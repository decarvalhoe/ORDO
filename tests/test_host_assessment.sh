#!/usr/bin/env bash
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

repo_root="$TEST_TMP/workdir"
log_dir="$TEST_TMP/log"
mkdir -p "$repo_root" "$log_dir"
printf 'content\n' > "$repo_root/file.txt"
: > "$TEST_TMP/sessions.txt"

good_df="$TEST_TMP/good.df"
cat > "$good_df" <<'EOF'
Filesystem     1M-blocks Used Available Use% Mounted on
fixturefs         100000 2000     98000   2% /
EOF

good_json=$(
  ORDO_HOST_ASSESSMENT_CPU_COUNT=8 \
  ORDO_HOST_ASSESSMENT_MEM_TOTAL_MB=32768 \
  ORDO_HOST_ASSESSMENT_MEM_AVAILABLE_MB=24576 \
  ORDO_HOST_ASSESSMENT_LOAD_AVG=1.00 \
  ORDO_HOST_ASSESSMENT_DF_FILE="$good_df" \
  ORDO_HOST_ASSESSMENT_PROCESS_LIMIT=2000 \
  ORDO_HOST_ASSESSMENT_PROCESS_COUNT=100 \
  ORDO_HOST_ASSESSMENT_FORK_LATENCY_MS=20 \
  ORDO_HOST_ASSESSMENT_EXECUTION_CONTEXT=local_shell \
  ORDO_HOST_ASSESSMENT_REPO_MB=25 \
  HOST_HEALTH_LOG_DIR="$log_dir" \
  HOST_HEALTH_SESSION_COUNT_FILE="$TEST_TMP/sessions.txt" \
  HOST_HEALTH_SESSION_WARN=50 \
  HOST_HEALTH_SESSION_MAX=100 \
    bash "$ROOT/scripts/host_assessment.sh" --requested-agents 3 --repo-root "$repo_root" --json
)

jq -e '
  .schema_version == "ordo.host_assessment.v1"
  and .requested_fleet.agents == 3
  and .environment_recommendation.decision == "keep_current_machine"
  and .environment_recommendation.suitability == "suitable"
  and .capacity.estimated_agents >= 3
  and .capabilities.terminal_multiplexer.required == false
  and .capabilities.terminal_multiplexer.topology_required == false
  and .capabilities.repo_footprint.path_redacted == true
' <<< "$good_json" >/dev/null \
  || fail "expected suitable structured report: $good_json"

if grep -Fq "$repo_root" <<< "$good_json"; then
  fail "structured output must not expose the raw repo path: $good_json"
fi

bad_df="$TEST_TMP/bad.df"
cat > "$bad_df" <<'EOF'
Filesystem     1M-blocks Used Available Use% Mounted on
fixturefs           3000 2800       200  94% /
EOF
printf '1 alpha\n2 beta\n3 gamma\n' > "$TEST_TMP/busy-sessions.txt"

bad_json=$(
  ORDO_HOST_ASSESSMENT_CPU_COUNT=2 \
  ORDO_HOST_ASSESSMENT_MEM_TOTAL_MB=2048 \
  ORDO_HOST_ASSESSMENT_MEM_AVAILABLE_MB=1024 \
  ORDO_HOST_ASSESSMENT_LOAD_AVG=9.00 \
  ORDO_HOST_ASSESSMENT_DF_FILE="$bad_df" \
  ORDO_HOST_ASSESSMENT_PROCESS_LIMIT=160 \
  ORDO_HOST_ASSESSMENT_PROCESS_COUNT=145 \
  ORDO_HOST_ASSESSMENT_FORK_LATENCY_MS=900 \
  ORDO_HOST_ASSESSMENT_EXECUTION_CONTEXT=local_shell \
  ORDO_HOST_ASSESSMENT_REPO_MB=50000 \
  HOST_HEALTH_LOG_DIR="$log_dir" \
  HOST_HEALTH_SESSION_COUNT_FILE="$TEST_TMP/busy-sessions.txt" \
  HOST_HEALTH_SESSION_WARN=1 \
  HOST_HEALTH_SESSION_MAX=2 \
    bash "$ROOT/scripts/host_assessment.sh" \
      --requested-agents 4 \
      --repo-root "$repo_root" \
      --require-terminal-multiplexer \
      --multiplexer-cmd "$TEST_TMP/missing-multiplexer" \
      --json
)

jq -e '
  .environment_recommendation.decision == "use_remote_host"
  and .environment_recommendation.suitability == "degraded"
  and (.environment_recommendation.bottlenecks | index("memory_capacity"))
  and (.environment_recommendation.bottlenecks | index("disk_capacity"))
  and (.environment_recommendation.bottlenecks | index("process_limit_capacity"))
  and (.environment_recommendation.bottlenecks | index("terminal_multiplexer_required_unavailable"))
  and .capabilities.terminal_multiplexer.required == true
  and .capabilities.terminal_multiplexer.status == "critical"
' <<< "$bad_json" >/dev/null \
  || fail "expected degraded local recommendation: $bad_json"

remote_json=$(
  ORDO_HOST_ASSESSMENT_CPU_COUNT=1 \
  ORDO_HOST_ASSESSMENT_MEM_TOTAL_MB=1024 \
  ORDO_HOST_ASSESSMENT_MEM_AVAILABLE_MB=512 \
  ORDO_HOST_ASSESSMENT_LOAD_AVG=1.00 \
  ORDO_HOST_ASSESSMENT_DF_FILE="$bad_df" \
  ORDO_HOST_ASSESSMENT_PROCESS_LIMIT=80 \
  ORDO_HOST_ASSESSMENT_PROCESS_COUNT=79 \
  ORDO_HOST_ASSESSMENT_FORK_LATENCY_MS=10 \
  ORDO_HOST_ASSESSMENT_EXECUTION_CONTEXT=remote_shell \
  ORDO_HOST_ASSESSMENT_REPO_MB=10 \
  HOST_HEALTH_LOG_DIR="$log_dir" \
  HOST_HEALTH_SESSION_COUNT_FILE="$TEST_TMP/sessions.txt" \
    bash "$ROOT/scripts/host_assessment.sh" --requested-agents 2 --repo-root "$repo_root" --json
)

jq -e '
  .capabilities.execution_context.class == "remote_shell"
  and .environment_recommendation.decision == "use_another_prepared_node"
' <<< "$remote_json" >/dev/null \
  || fail "expected remote constrained recommendation: $remote_json"

text_output=$(
  ORDO_HOST_ASSESSMENT_CPU_COUNT=8 \
  ORDO_HOST_ASSESSMENT_MEM_TOTAL_MB=32768 \
  ORDO_HOST_ASSESSMENT_MEM_AVAILABLE_MB=24576 \
  ORDO_HOST_ASSESSMENT_LOAD_AVG=1.00 \
  ORDO_HOST_ASSESSMENT_DF_FILE="$good_df" \
  ORDO_HOST_ASSESSMENT_PROCESS_LIMIT=2000 \
  ORDO_HOST_ASSESSMENT_PROCESS_COUNT=100 \
  ORDO_HOST_ASSESSMENT_FORK_LATENCY_MS=20 \
  ORDO_HOST_ASSESSMENT_REPO_MB=25 \
    bash "$ROOT/scripts/host_assessment.sh" --requested-agents 3 --repo-root "$repo_root" --text
)

[[ "$text_output" == *"Recommendation: keep_current_machine"* ]] \
  || fail "expected text recommendation: $text_output"

printf 'ok - host assessment emits structured capacity and environment recommendations\n'
