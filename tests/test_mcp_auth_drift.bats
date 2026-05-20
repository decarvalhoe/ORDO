#!/usr/bin/env bats
# tests/test_mcp_auth_drift.bats — coverage for ORDO #748.
#
# Codex TUI / pane logs on the fleet repeatedly surface two distinct
# symptoms of connector-directory auth drift:
#
#   1. `403 Forbidden` on
#      chatgpt.com/backend-api/connectors/directory/list?external_logos=true
#   2. `failed to load discoverable tool suggestions`
#
# `lib/mcp_permission_preflight.sh` MUST:
#   - detect both symptoms from a Codex TUI log;
#   - count distinct hits per symptom so an operator can gauge severity;
#   - emit one structured record per symptom from the classifier;
#   - default severity=warning (operator action, but not fleet-fatal);
#   - accept severity=blocking as an opt-in escalation that returns rc=1.
#
# `scripts/host_health_preflight.sh` MUST:
#   - read HOST_HEALTH_CODEX_CONNECTOR_LOGS (or fall back to
#     HOST_HEALTH_CODEX_STARTUP_LOGS) and emit a HOST_HEALTH metric line
#     plus a `codex_connector_directory_drift` signal so the same scan
#     that surfaces MCP startup failures also surfaces directory drift.
#   - escalate to status=critical when
#     HOST_HEALTH_CODEX_CONNECTOR_DIRECTORY_REQUIRED=1 is set.

load './helpers.bash'

setup() {
  setup_orch_test
  toolkit_file lib/mcp_permission_preflight.sh >/dev/null
  # shellcheck disable=SC1091 # sourcing sanitized copy
  source "$SANITIZED_TK/lib/mcp_permission_preflight.sh"

  cat > "$BATS_TEST_TMPDIR/codex-tui.log" <<'LOG'
2026-05-19T10:15:21Z INFO codex_tui: starting
2026-05-19T10:15:22Z ERROR codex_tui::connectors: 403 Forbidden on https://chatgpt.com/backend-api/connectors/directory/list?external_logos=true
2026-05-19T10:15:22Z WARN  codex_tui::connectors: failed to load discoverable tool suggestions
2026-05-19T10:15:55Z ERROR codex_tui::connectors: 403 Forbidden on https://chatgpt.com/backend-api/connectors/directory/list?external_logos=true
2026-05-19T10:16:05Z INFO  codex_tui: ready
LOG

  cat > "$BATS_TEST_TMPDIR/clean.log" <<'LOG'
2026-05-19T10:15:21Z INFO codex_tui: starting
2026-05-19T10:15:22Z INFO codex_tui: ready
LOG

  cat > "$BATS_TEST_TMPDIR/only-suggestions.log" <<'LOG'
2026-05-19T10:15:22Z WARN codex_tui::connectors: failed to load discoverable tool suggestions
LOG
}

@test "connector-directory drift: detects 403 and tool-suggestions symptoms" {
  run mcp_preflight_detect_connector_directory_drift "$BATS_TEST_TMPDIR/codex-tui.log"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "directory_list_403" ]
  [ "${lines[1]}" = "tool_suggestions" ]
}

@test "connector-directory drift: clean log produces no records" {
  run mcp_preflight_detect_connector_directory_drift "$BATS_TEST_TMPDIR/clean.log"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "connector-directory drift: missing log is a no-op" {
  run mcp_preflight_detect_connector_directory_drift "/no/such/log"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "connector-directory drift: counts distinct hits per symptom" {
  run mcp_preflight_count_connector_directory_drift "$BATS_TEST_TMPDIR/codex-tui.log"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "directory_list_403=2" ]
  [ "${lines[1]}" = "tool_suggestions=1" ]
}

@test "connector-directory drift: tool-suggestions only is still reported" {
  run mcp_preflight_count_connector_directory_drift "$BATS_TEST_TMPDIR/only-suggestions.log"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "tool_suggestions=1" ]
}

@test "classifier: default severity=warning, rc=0 (audit-only)" {
  run mcp_preflight_classify_connector_directory_log "$BATS_TEST_TMPDIR/codex-tui.log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"symptom=directory_list_403 severity=warning source=startup hits=2"* ]]
  [[ "$output" == *"symptom=tool_suggestions severity=warning source=startup hits=1"* ]]
  [[ "$output" == *"hint=codex_connector_reauth_or_disable_directory"* ]]
}

@test "classifier: severity=blocking opt-in returns rc=1" {
  run mcp_preflight_classify_connector_directory_log "$BATS_TEST_TMPDIR/codex-tui.log" blocking
  [ "$status" -eq 1 ]
  [[ "$output" == *"severity=blocking"* ]]
}

@test "classifier: clean log emits nothing and rc=0" {
  run mcp_preflight_classify_connector_directory_log "$BATS_TEST_TMPDIR/clean.log"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "classifier: missing log is a no-op with rc=0" {
  run mcp_preflight_classify_connector_directory_log "/no/such/log" blocking
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "host_health_preflight surfaces directory drift as warning signal" {
  mkdir -p "$BATS_TEST_TMPDIR/log/journal"
  : > "$BATS_TEST_TMPDIR/log/wtmp"
  : > "$BATS_TEST_TMPDIR/empty-sessions.txt"

  cat > "$BATS_TEST_TMPDIR/drift.log" <<'LOG'
ERROR codex_tui::connectors: 403 Forbidden on https://chatgpt.com/backend-api/connectors/directory/list?external_logos=true
WARN  codex_tui::connectors: failed to load discoverable tool suggestions
LOG

  output=$(
    TK="$TK" \
    HOST_HEALTH_LOG_DIR="$BATS_TEST_TMPDIR/missing-log-dir" \
    HOST_HEALTH_SESSION_COUNT_FILE="$BATS_TEST_TMPDIR/empty-sessions.txt" \
    HOST_HEALTH_CODEX_CONNECTOR_LOGS="$BATS_TEST_TMPDIR/drift.log" \
    HOST_HEALTH_VAR_LOG_PCT=1 \
    HOST_HEALTH_WTMP_WARN_MB=10 \
    HOST_HEALTH_WTMP_MAX_MB=20 \
    HOST_HEALTH_JOURNAL_WARN_MB=10 \
    HOST_HEALTH_JOURNAL_MAX_MB=20 \
    HOST_HEALTH_VAR_LOG_WARN_MB=10 \
    HOST_HEALTH_VAR_LOG_MAX_MB=20 \
    HOST_HEALTH_VAR_LOG_WARN_PCT=80 \
    HOST_HEALTH_VAR_LOG_MAX_PCT=90 \
    HOST_HEALTH_SESSION_WARN=10 \
    HOST_HEALTH_SESSION_MAX=20 \
      bash "$TK/scripts/host_health_preflight.sh"
  )

  [[ "$output" == *"status=warning metric=codex_connector_directory_drift value=2"* ]]
  [[ "$output" == *"symptoms=directory_list_403:1,tool_suggestions:1"* ]]
  [[ "$output" == *"hint=codex_connector_reauth_or_disable_directory"* ]]
  [[ "$output" == *"codex_connector_directory_drift"* ]]
  [[ "$output" == *"HOST_HEALTH summary=warning"* ]]
}

@test "host_health_preflight escalates to critical when directory probe is required" {
  mkdir -p "$BATS_TEST_TMPDIR/log/journal"
  : > "$BATS_TEST_TMPDIR/log/wtmp"
  : > "$BATS_TEST_TMPDIR/empty-sessions.txt"

  cat > "$BATS_TEST_TMPDIR/drift.log" <<'LOG'
ERROR codex_tui::connectors: 403 Forbidden on https://chatgpt.com/backend-api/connectors/directory/list?external_logos=true
LOG

  set +e
  output=$(
    TK="$TK" \
    HOST_HEALTH_LOG_DIR="$BATS_TEST_TMPDIR/missing-log-dir" \
    HOST_HEALTH_SESSION_COUNT_FILE="$BATS_TEST_TMPDIR/empty-sessions.txt" \
    HOST_HEALTH_CODEX_CONNECTOR_LOGS="$BATS_TEST_TMPDIR/drift.log" \
    HOST_HEALTH_CODEX_CONNECTOR_DIRECTORY_REQUIRED=1 \
    HOST_HEALTH_VAR_LOG_PCT=1 \
    HOST_HEALTH_WTMP_WARN_MB=10 \
    HOST_HEALTH_WTMP_MAX_MB=20 \
    HOST_HEALTH_JOURNAL_WARN_MB=10 \
    HOST_HEALTH_JOURNAL_MAX_MB=20 \
    HOST_HEALTH_VAR_LOG_WARN_MB=10 \
    HOST_HEALTH_VAR_LOG_MAX_MB=20 \
    HOST_HEALTH_VAR_LOG_WARN_PCT=80 \
    HOST_HEALTH_VAR_LOG_MAX_PCT=90 \
    HOST_HEALTH_SESSION_WARN=10 \
    HOST_HEALTH_SESSION_MAX=20 \
      bash "$TK/scripts/host_health_preflight.sh" --refuse
  )
  rc=$?
  set -e

  [ "$rc" -eq 7 ]
  [[ "$output" == *"status=critical metric=codex_connector_directory_drift"* ]]
  [[ "$output" == *"HOST_HEALTH summary=critical"* ]]
  [[ "$output" == *"codex_connector_directory_drift"* ]]
}

@test "host_health_preflight reuses HOST_HEALTH_CODEX_STARTUP_LOGS when connector log var is unset" {
  : > "$BATS_TEST_TMPDIR/empty-sessions.txt"

  cat > "$BATS_TEST_TMPDIR/shared.log" <<'LOG'
The cloudflare-api MCP server is not logged in. Run codex mcp login cloudflare-api.
ERROR codex_tui::connectors: 403 Forbidden on https://chatgpt.com/backend-api/connectors/directory/list
LOG

  output=$(
    TK="$TK" \
    HOST_HEALTH_LOG_DIR="$BATS_TEST_TMPDIR/missing-log-dir" \
    HOST_HEALTH_SESSION_COUNT_FILE="$BATS_TEST_TMPDIR/empty-sessions.txt" \
    HOST_HEALTH_CODEX_STARTUP_LOGS="$BATS_TEST_TMPDIR/shared.log" \
    HOST_HEALTH_VAR_LOG_PCT=1 \
    HOST_HEALTH_WTMP_WARN_MB=10 \
    HOST_HEALTH_WTMP_MAX_MB=20 \
    HOST_HEALTH_JOURNAL_WARN_MB=10 \
    HOST_HEALTH_JOURNAL_MAX_MB=20 \
    HOST_HEALTH_VAR_LOG_WARN_MB=10 \
    HOST_HEALTH_VAR_LOG_MAX_MB=20 \
    HOST_HEALTH_VAR_LOG_WARN_PCT=80 \
    HOST_HEALTH_VAR_LOG_MAX_PCT=90 \
    HOST_HEALTH_SESSION_WARN=10 \
    HOST_HEALTH_SESSION_MAX=20 \
      bash "$TK/scripts/host_health_preflight.sh"
  )

  [[ "$output" == *"metric=codex_mcp_startup_failures"* ]]
  [[ "$output" == *"metric=codex_connector_directory_drift"* ]]
  [[ "$output" == *"mcp_unavailable:cloudflare-api"* ]]
  [[ "$output" == *"codex_connector_directory_drift"* ]]
}
