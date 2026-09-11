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
  lib/ordo_provider_adapter.sh \
  lib/ordo_provider_adapter_github.sh \
  lib/ordo_provider_adapter_fake.sh \
  lib/ordo_contracts.sh \
  lib/external_mutation_gate.sh \
  lib/log_bounds.sh \
  lib/ci_external_blockers.sh \
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
  {"databaseId":25442507320,"name":"Deploy DEV Alerts","workflowName":"Deploy DEV Alerts","conclusion":"success","status":"completed","headSha":"fd0aee8ff2222222","createdAt":"2026-05-06T14:45:40Z","event":"push","url":"https://example.invalid/runs/25442507320"},
  {"databaseId":25442507326,"name":"Deploy DEV Alerts","workflowName":"Deploy DEV Alerts","conclusion":"failure","status":"completed","headSha":"fd0aee8ff2222222","createdAt":"2026-05-06T14:46:10Z","event":"push","url":"https://example.invalid/runs/25442507326"},
  {"databaseId":25442507327,"name":"Deploy DEV Health","workflowName":"Deploy DEV Health","conclusion":"success","status":"completed","headSha":"fd0aee8ff2222222","createdAt":"2026-05-06T14:46:12Z","event":"push","url":"https://example.invalid/runs/25442507327"}
]
JSON
        ;;
      prejob_metadata_drift)
        cat <<'JSON'
[
  {"databaseId":25442507332,"name":".github/workflows/stale.yml","workflowName":".github/workflows/stale.yml","conclusion":"failure","status":"completed","headSha":"fd0aee8ff5555555","createdAt":"2026-05-06T14:48:20Z","event":"push","url":"https://example.invalid/runs/25442507332"},
  {"databaseId":25442507333,"name":"Deploy DEV Health","workflowName":"Deploy DEV Health","conclusion":"success","status":"completed","headSha":"fd0aee8ff5555555","createdAt":"2026-05-06T14:48:21Z","event":"push","url":"https://example.invalid/runs/25442507333"}
]
JSON
        ;;
      external_billing_blocker)
        cat <<'JSON'
[
  {"databaseId":25634186704,"name":"Coverage Gate Enforcement","workflowName":"Coverage Gate Enforcement","conclusion":"failure","status":"completed","headSha":"fd0aee8ff6666666","createdAt":"2026-05-06T14:49:20Z","event":"pull_request","url":"https://example.invalid/runs/25634186704"},
  {"databaseId":25634186705,"name":"Deploy DEV Health","workflowName":"Deploy DEV Health","conclusion":"success","status":"completed","headSha":"fd0aee8ff6666666","createdAt":"2026-05-06T14:49:21Z","event":"push","url":"https://example.invalid/runs/25634186705"}
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
      stale_workflow_run_gate_payload)
        cat <<'JSON'
[
  {"databaseId":25607108841,"name":"Deploy DEV","workflowName":"Deploy DEV","conclusion":"failure","status":"completed","headSha":"a474632602a1c22a2434aa8beb2084f3ecec74e5","createdAt":"2026-05-09T12:00:00Z","event":"push","url":"https://example.invalid/runs/25607108841"},
  {"databaseId":25607117067,"name":"Deploy DEV","workflowName":"Deploy DEV","conclusion":null,"status":"in_progress","headSha":"b51cd8d3b81b08da279dd1850b0778c11d85f9ec","createdAt":"2026-05-09T12:06:00Z","event":"push","url":"https://example.invalid/runs/25607117067"},
  {"databaseId":25607495860,"name":"Deploy Health Gate","workflowName":"Deploy Health Gate","conclusion":"failure","status":"completed","headSha":"b51cd8d3b81b08da279dd1850b0778c11d85f9ec","createdAt":"2026-05-09T12:08:00Z","event":"workflow_run","url":"https://example.invalid/runs/25607495860"}
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
      latest_failure:25442507326)
        cat <<'JSON'
{
  "jobs": [
    {
      "databaseId": 887766,
      "name": "validate",
      "status": "completed",
      "conclusion": "failure"
    }
  ]
}
JSON
        ;;
      prejob_metadata_drift:25442507332)
        printf '{"jobs":[]}\n'
        ;;
      external_billing_blocker:25634186704)
        cat <<'JSON'
{
  "jobs": [
    {
      "databaseId": 75243474291,
      "name": "Coverage Gate Enforcement",
      "status": "completed",
      "conclusion": "failure",
      "steps": []
    }
  ]
}
JSON
        ;;
      stale_workflow_run_gate_payload:25607495860)
        if [[ " $* " == *" --log "* ]]; then
          cat <<'LOG'
Deploy Health Gate	validate	2026-05-09T12:08:12Z Deploy gate=failure sha=a474632602a1c22a2434aa8beb2084f3ecec74e5 run=25607108841
LOG
        else
          cat <<'JSON'
{
  "jobs": [
    {
      "databaseId": 665544,
      "name": "validate",
      "status": "completed",
      "conclusion": "failure"
    }
  ]
}
JSON
        fi
        ;;
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
  "api repos/example/repo/check-runs/75243474291/annotations")
    cat <<'JSON'
[
  {
    "path": "",
    "start_line": null,
    "annotation_level": "failure",
    "title": "Job was not started",
    "message": "The job was not started because recent account payments have failed or spending limit needs to be increased."
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
[[ "$SCENARIO_OUTPUT" != *"CI HEALTH PREJOB"* ]] || fail "normal job failure must not be classified as pre-job: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" != *"CI HEALTH METADATA_DRIFT"* ]] || fail "normal job failure must not be metadata drift: $SCENARIO_OUTPUT"

run_scenario pending_replaces_failure
[[ "$SCENARIO_STATUS" -eq 0 ]] || fail "pending newest signal should exit 0, got $SCENARIO_STATUS: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"CI HEALTH PENDING"* ]] || fail "missing pending output: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"relation=superseded-by-pending"* ]] || fail "missing superseded-by-pending relation: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" != *"CI HEALTH ALERT"* ]] || fail "pending newest signal must not alert: $SCENARIO_OUTPUT"

run_scenario stale_workflow_run_gate_payload
[[ "$SCENARIO_STATUS" -eq 0 ]] || fail "stale workflow_run gate payload should exit 0, got $SCENARIO_STATUS: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"CI HEALTH PENDING"* ]] || fail "missing current deploy pending output: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"Deploy DEV [in_progress]"* ]] || fail "missing current deploy pending detail: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"Deploy Health Gate [failure]"* ]] || fail "missing stale health gate warning detail: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"sha=a474632"* ]] || fail "missing payload sha evidence: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"relation=stale-payload-superseded-by-pending"* ]] || fail "missing stale-payload relation: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" != *"CI HEALTH ALERT"* ]] || fail "stale workflow_run gate payload must not alert: $SCENARIO_OUTPUT"

run_scenario green_warning_annotation
[[ "$SCENARIO_STATUS" -eq 0 ]] || fail "green warning scan should exit 0, got $SCENARIO_STATUS: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"CI HEALTH FINDING - successful workflow warnings"* ]] || fail "missing successful-run finding: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"toolkit-ci/validate [warning]"* ]] || fail "missing workflow/job warning context: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"location=.github:2"* ]] || fail "missing annotation location: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"Node.js 20 actions are deprecated"* ]] || fail "missing warning message: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"successful_run_warnings=1"* ]] || fail "missing warning count: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" != *"CI HEALTH ALERT"* ]] || fail "green warning finding must not alert: $SCENARIO_OUTPUT"

run_scenario prejob_metadata_drift
[[ "$SCENARIO_STATUS" -eq 2 ]] || fail "pre-job metadata drift should exit 2, got $SCENARIO_STATUS: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"CI HEALTH PREJOB - failures before job creation"* ]] || fail "missing pre-job section: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"CI HEALTH METADATA_DRIFT - path-like workflow metadata"* ]] || fail "missing metadata drift section: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *".github/workflows/stale.yml [failure]"* ]] || fail "missing workflow path context: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"jobs=0"* ]] || fail "missing zero-job evidence: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"prejob_failures=1 metadata_drifts=1"* ]] || fail "missing pre-job summary counts: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" != *"CI HEALTH ALERT"* ]] || fail "pre-job drift must not be reported as normal CI alert: $SCENARIO_OUTPUT"

run_scenario external_billing_blocker
[[ "$SCENARIO_STATUS" -eq 2 ]] || fail "external billing blocker should exit 2, got $SCENARIO_STATUS: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"CI HEALTH BLOCKED_EXTERNAL - GitHub Actions job-start blockers"* ]] || fail "missing external blocker section: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"Coverage Gate Enforcement [failure]"* ]] || fail "missing blocked workflow details: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"job=Coverage Gate Enforcement"* ]] || fail "missing blocked job evidence: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"reason=github_actions_billing_job_start"* ]] || fail "missing external blocker reason: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"spending limit needs to be increased"* ]] || fail "missing billing annotation evidence: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"status=blocked_external"* ]] || fail "missing blocked_external summary: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" == *"external_blockers=1"* ]] || fail "missing external blocker count: $SCENARIO_OUTPUT"
[[ "$SCENARIO_OUTPUT" != *"CI HEALTH ALERT"* ]] || fail "external blocker must not be reported as code-failed alert: $SCENARIO_OUTPUT"

printf 'ok - check_ci_health dedupes by latest workflow signal\n'
