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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/bin" "$TEST_TMP/logs" "$TEST_TMP/state"

for rel in \
  scripts/check_ci_health.sh \
  lib/audit_log.sh \
  lib/log_bounds.sh \
  lib/config_check.sh \
  lib/config_resolver.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/check_ci_health.sh"

cat > "$TEST_TMP/config.sh" <<EOF
PROJECT="ci-health-test"
DEFAULT_BRANCH="main"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/work/%s"
ORCH_LOG_DIR="$TEST_TMP/logs"
ORCH_STATE_BASE="$TEST_TMP/state"
EOF

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "run list")
    case "${CI_HEALTH_SCENARIO:-}" in
      healed_failure)
        cat <<'JSON'
[
  {"databaseId":25442507323,"name":"Deploy DEV Alerts","conclusion":"failure","status":"completed","headSha":"fd0aee8ff1111111","createdAt":"2026-05-06T14:45:48Z"},
  {"databaseId":25442507324,"name":"Deploy DEV Alerts","conclusion":"success","status":"completed","headSha":"fd0aee8ff1111111","createdAt":"2026-05-06T14:46:01Z"},
  {"databaseId":25442507325,"name":"Deploy DEV Health","conclusion":"success","status":"completed","headSha":"fd0aee8ff1111111","createdAt":"2026-05-06T14:46:05Z"}
]
JSON
        ;;
      latest_failure)
        cat <<'JSON'
[
  {"databaseId":25442507320,"name":"Deploy DEV Alerts","conclusion":"success","status":"completed","headSha":"fd0aee8ff2222222","createdAt":"2026-05-06T14:45:40Z"},
  {"databaseId":25442507326,"name":"Deploy DEV Alerts","conclusion":"failure","status":"completed","headSha":"fd0aee8ff2222222","createdAt":"2026-05-06T14:46:10Z"},
  {"databaseId":25442507327,"name":"Deploy DEV Health","conclusion":"success","status":"completed","headSha":"fd0aee8ff2222222","createdAt":"2026-05-06T14:46:12Z"}
]
JSON
        ;;
      pending_replaces_failure)
        cat <<'JSON'
[
  {"databaseId":25442507328,"name":"Deploy DEV","conclusion":"failure","status":"completed","headSha":"fd0aee8ff3333333","createdAt":"2026-05-06T14:45:48Z"},
  {"databaseId":25442507329,"name":"Deploy DEV","conclusion":null,"status":"in_progress","headSha":"fd0aee8ff3333333","createdAt":"2026-05-06T14:46:20Z"},
  {"databaseId":25442507330,"name":"Deploy DEV Alerts","conclusion":"success","status":"completed","headSha":"fd0aee8ff3333333","createdAt":"2026-05-06T14:46:21Z"}
]
JSON
        ;;
      green_warning_annotation)
        cat <<'JSON'
[
  {"databaseId":25442507331,"name":"toolkit-ci","conclusion":"success","status":"completed","headSha":"fd0aee8ff4444444","createdAt":"2026-05-06T14:47:20Z"}
]
JSON
        ;;
      *)
        printf 'unknown CI_HEALTH_SCENARIO=%s\n' "${CI_HEALTH_SCENARIO:-}" >&2
        exit 1
        ;;
    esac
    ;;
  "run view")
    case "${CI_HEALTH_SCENARIO:-}:${3:-}" in
      green_warning_annotation:25442507331)
        cat <<'JSON'
{
  "jobs": [
    {
      "databaseId": 998877,
      "name": "validate",
      "status": "completed",
      "conclusion": "success"
    }
  ]
}
JSON
        ;;
      *)
        printf '{"jobs":[]}\n'
        ;;
    esac
    ;;
  "api repos/example/repo/check-runs/998877/annotations")
    cat <<'JSON'
[
  {
    "path": ".github",
    "start_line": 2,
    "annotation_level": "warning",
    "title": "",
    "message": "Node.js 20 actions are deprecated. Actions will be forced to run with Node.js 24 by default starting June 2nd, 2026."
  },
  {
    "path": "README.md",
    "start_line": 1,
    "annotation_level": "notice",
    "title": "Informational",
    "message": "This notice is not part of the warning scan."
  }
]
JSON
    ;;
  *)
    printf 'unexpected gh invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

SCENARIO_STATUS=
SCENARIO_OUTPUT=
run_scenario() {
  local scenario=${1:?usage: run_scenario <scenario>}
  set +e
  SCENARIO_OUTPUT=$(
    PATH="$TEST_TMP/bin:$PATH" \
    CI_HEALTH_SCENARIO="$scenario" \
    bash "$SANITIZED_ROOT/scripts/check_ci_health.sh" "$TEST_TMP/config.sh" 8 2>&1
  )
  SCENARIO_STATUS=$?
  set -e
}

run_scenario healed_failure
[[ "$SCENARIO_STATUS" -eq 0 ]] || fail "healed failure should exit 0, got $SCENARIO_STATUS: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"CI HEALTH WARN"* ]] || fail "missing superseded warning: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"relation=healed"* ]] || fail "missing healed relation: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"CI HEALTH OK"* ]] || fail "missing OK status: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" != *"CI HEALTH ALERT"* ]] || fail "healed failure must not alert: $SCENARIO_OUTPUT"

run_scenario latest_failure
[[ "$SCENARIO_STATUS" -eq 2 ]] || fail "latest failure should exit 2, got $SCENARIO_STATUS: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"CI HEALTH ALERT"* ]] || fail "missing alert output: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"Deploy DEV Alerts [failure]"* ]] || fail "missing failing workflow details: $SCENARIO_OUTPUT"

run_scenario pending_replaces_failure
[[ "$SCENARIO_STATUS" -eq 0 ]] || fail "pending newest signal should exit 0, got $SCENARIO_STATUS: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"CI HEALTH PENDING"* ]] || fail "missing pending output: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"relation=superseded-by-pending"* ]] || fail "missing superseded-by-pending relation: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" != *"CI HEALTH ALERT"* ]] || fail "pending newest signal must not alert: $SCENARIO_OUTPUT"

run_scenario green_warning_annotation
[[ "$SCENARIO_STATUS" -eq 0 ]] || fail "green warning scan should exit 0, got $SCENARIO_STATUS: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"CI HEALTH FINDING - successful workflow warnings"* ]] || fail "missing successful-run finding: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"toolkit-ci/validate [warning]"* ]] || fail "missing workflow/job warning context: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"location=.github:2"* ]] || fail "missing annotation location: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"Node.js 20 actions are deprecated"* ]] || fail "missing warning message: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"successful_run_warnings=1"* ]] || fail "missing warning count: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" != *"CI HEALTH ALERT"* ]] || fail "green warning finding must not alert: $SCENARIO_OUTPUT"

printf 'ok - check_ci_health dedupes by latest workflow signal\n'
