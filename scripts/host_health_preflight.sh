#!/usr/bin/env bash
# host_health_preflight.sh - bounded warning gate for host log/session storms.

set -euo pipefail

TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

usage() {
  cat <<EOF >&2
usage: host_health_preflight.sh [--refuse]

Reports bounded host-health metrics for login/session storms:
  - wtmp accounting size
  - system journal size
  - /var/log size and filesystem usage
  - systemd login session count
  - optional Codex startup/MCP failures from explicit log files
  - optional ORDO/Codex log surfaces against the log-retention policy
    (set HOST_HEALTH_INCLUDE_LOG_RETENTION=1 to enable)

By default warnings are informational. With --refuse, critical metrics exit 7
so callers can fail closed before starting more probes.

Set HOST_HEALTH_CODEX_STARTUP_LOGS to a colon-separated list of pane/debug log
files to surface Codex plugin/MCP startup failures as readiness signals.

Set HOST_HEALTH_CODEX_CONNECTOR_LOGS (also colon-separated) to point at Codex
TUI / pane logs that should be scanned for connector-directory auth drift
(repeated 403 on backend-api/connectors/directory/list and "failed to load
discoverable tool suggestions"). When unset, HOST_HEALTH_CODEX_STARTUP_LOGS is
reused. Set HOST_HEALTH_CODEX_CONNECTOR_DIRECTORY_REQUIRED=1 to escalate the
metric from warning to critical when drift is present.
EOF
}

DO_REFUSE=0
for arg in "$@"; do
  case "$arg" in
    --refuse)
      DO_REFUSE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown arg: $arg" >&2
      usage
      exit 2
      ;;
  esac
done

# shellcheck source=lib/host_health.sh
source "$TK/lib/host_health.sh"
# shellcheck source=lib/mcp_permission_preflight.sh
source "$TK/lib/mcp_permission_preflight.sh"
# shellcheck source=lib/log_retention.sh
source "$TK/lib/log_retention.sh"

declare -a HOST_HEALTH_SIGNALS=()
HOST_HEALTH_CRITICAL=0
HOST_HEALTH_WARNING=0

codex_mcp_clean_name() {
  local raw=${1:-}
  raw=${raw#"${raw%%[![:space:]]*}"}
  raw=${raw%"${raw##*[![:space:]]}"}
  raw=${raw%%[[:space:]]*}
  raw=${raw//[^[:alnum:]_.-]/}
  [[ -n "$raw" ]] || raw=unknown
  printf '%s\n' "$raw"
}

codex_mcp_required() {
  local wanted=${1:?usage: codex_mcp_required <name>}
  local normalized required
  normalized=${HOST_HEALTH_REQUIRED_MCP_SERVERS:-}
  normalized=${normalized//,/ }
  for required in $normalized; do
    [[ "$required" == "$wanted" ]] && return 0
  done
  return 1
}

emit_codex_mcp_startup_failures() {
  local log_list=${HOST_HEALTH_CODEX_STARTUP_LOGS:-}
  [[ -n "$log_list" ]] || return 0

  local log_file line failed raw name status signal_list
  local -a failed_servers=()
  local -A seen=()
  local required_count=0

  while IFS= read -r log_file; do
    [[ -n "$log_file" && -f "$log_file" && -r "$log_file" ]] || continue
    while IFS= read -r line; do
      case "$line" in
        *" MCP server is not logged in."*)
          raw=${line%% MCP server is not logged in.*}
          raw=${raw##* }
          name=$(codex_mcp_clean_name "$raw")
          ;;
        *"MCP startup incomplete (failed:"*)
          failed=${line#*MCP startup incomplete (failed:}
          failed=${failed%%)*}
          failed=${failed//,/ }
          for raw in $failed; do
            name=$(codex_mcp_clean_name "$raw")
            if [[ -z "${seen[$name]:-}" ]]; then
              seen[$name]=1
              failed_servers+=("$name")
              codex_mcp_required "$name" && required_count=$((required_count + 1))
            fi
          done
          continue
          ;;
        *)
          continue
          ;;
      esac

      if [[ -z "${seen[$name]:-}" ]]; then
        seen[$name]=1
        failed_servers+=("$name")
        codex_mcp_required "$name" && required_count=$((required_count + 1))
      fi
    done < "$log_file"
  done < <(tr ':' '\n' <<< "$log_list")

  [[ "${#failed_servers[@]}" -gt 0 ]] || return 0

  status=warning
  if [[ "$required_count" -gt 0 ]]; then
    status=critical
    HOST_HEALTH_CRITICAL=1
  else
    HOST_HEALTH_WARNING=1
  fi

  signal_list=""
  for name in "${failed_servers[@]}"; do
    HOST_HEALTH_SIGNALS+=("mcp_unavailable:${name}")
    if [[ -n "$signal_list" ]]; then
      signal_list="${signal_list},mcp_unavailable:${name}"
    else
      signal_list="mcp_unavailable:${name}"
    fi
  done

  printf 'HOST_HEALTH status=%s metric=codex_mcp_startup_failures value=%s unit=count required=%s hint=%s signals=%s\n' \
    "$status" "${#failed_servers[@]}" "$required_count" \
    "codex_mcp_login_or_disable_non_required_plugins" "$signal_list"
}

emit_codex_connector_directory_drift() {
  local log_list=${HOST_HEALTH_CODEX_CONNECTOR_LOGS:-${HOST_HEALTH_CODEX_STARTUP_LOGS:-}}
  [[ -n "$log_list" ]] || return 0

  local log_file record symptom hits total=0
  local -A counts=()
  local -a symptoms=()

  while IFS= read -r log_file; do
    [[ -n "$log_file" && -f "$log_file" && -r "$log_file" ]] || continue
    while IFS= read -r record; do
      [[ -n "$record" ]] || continue
      symptom=${record%%=*}
      hits=${record#*=}
      if [[ -z "${counts[$symptom]:-}" ]]; then
        counts[$symptom]=0
        symptoms+=("$symptom")
      fi
      counts[$symptom]=$(( counts[$symptom] + hits ))
      total=$(( total + hits ))
    done < <(mcp_preflight_count_connector_directory_drift "$log_file")
  done < <(tr ':' '\n' <<< "$log_list")

  [[ "$total" -gt 0 ]] || return 0

  local status=warning
  if [[ "${HOST_HEALTH_CODEX_CONNECTOR_DIRECTORY_REQUIRED:-0}" == "1" ]]; then
    status=critical
    HOST_HEALTH_CRITICAL=1
  else
    HOST_HEALTH_WARNING=1
  fi

  local symptom_list=""
  for symptom in "${symptoms[@]}"; do
    if [[ -n "$symptom_list" ]]; then
      symptom_list="${symptom_list},${symptom}:${counts[$symptom]}"
    else
      symptom_list="${symptom}:${counts[$symptom]}"
    fi
  done

  HOST_HEALTH_SIGNALS+=("codex_connector_directory_drift")

  printf 'HOST_HEALTH status=%s metric=codex_connector_directory_drift value=%s unit=count symptoms=%s hint=%s signals=codex_connector_directory_drift\n' \
    "$status" "$total" "$symptom_list" \
    "codex_connector_reauth_or_disable_directory"
}

emit_metric() {
  local metric=${1:?usage: emit_metric <metric> <value> <warn> <max> <unit> <hint>}
  local value=${2:?usage: emit_metric <metric> <value> <warn> <max> <unit> <hint>}
  local warn=${3:?usage: emit_metric <metric> <value> <warn> <max> <unit> <hint>}
  local max=${4:?usage: emit_metric <metric> <value> <warn> <max> <unit> <hint>}
  local unit=${5:?usage: emit_metric <metric> <value> <warn> <max> <unit> <hint>}
  local hint=${6:?usage: emit_metric <metric> <value> <warn> <max> <unit> <hint>}
  local status

  status=$(host_health_classify_metric "$value" "$warn" "$max")
  printf 'HOST_HEALTH status=%s metric=%s value=%s unit=%s warn=%s max=%s hint=%s\n' \
    "$status" "$metric" "$value" "$unit" "$warn" "$max" "$hint"

  case "$status" in
    critical)
      HOST_HEALTH_CRITICAL=1
      HOST_HEALTH_SIGNALS+=("${metric}_critical")
      ;;
    warning)
      HOST_HEALTH_WARNING=1
      HOST_HEALTH_SIGNALS+=("${metric}_warning")
      ;;
    unknown)
      HOST_HEALTH_WARNING=1
      HOST_HEALTH_SIGNALS+=("${metric}_unknown")
      ;;
  esac
}

emit_metric "wtmp_mb" "$(host_health_wtmp_mb)" \
  "$HOST_HEALTH_WTMP_WARN_MB" "$HOST_HEALTH_WTMP_MAX_MB" "MiB" "rotate_wtmp_after_evidence"
emit_metric "journal_mb" "$(host_health_journal_mb)" \
  "$HOST_HEALTH_JOURNAL_WARN_MB" "$HOST_HEALTH_JOURNAL_MAX_MB" "MiB" "journal_vacuum_after_evidence"
emit_metric "var_log_mb" "$(host_health_var_log_mb)" \
  "$HOST_HEALTH_VAR_LOG_WARN_MB" "$HOST_HEALTH_VAR_LOG_MAX_MB" "MiB" "rotate_or_vacuum_logs"
emit_metric "var_log_pct" "$(host_health_var_log_pct)" \
  "$HOST_HEALTH_VAR_LOG_WARN_PCT" "$HOST_HEALTH_VAR_LOG_MAX_PCT" "percent" "free_var_log_space"
emit_metric "host_sessions" "$(host_health_session_count)" \
  "$HOST_HEALTH_SESSION_WARN" "$HOST_HEALTH_SESSION_MAX" "count" "batch_or_persist_remote_probes"

emit_log_retention_metric() {
  # Surfaces ORDO/Codex local log surfaces against the same retention
  # thresholds enforced by scripts/log_retention.sh (#747, parent #636).
  # The hint points operators at the remediation script rather than
  # ad-hoc trimming.
  local label=${1:?usage: emit_log_retention_metric <label> <path> <kind>}
  local path=${2:?}
  local kind=${3:?}
  local value warn max
  case "$kind" in
    dir)
      value=$(log_retention_dir_mb "$path")
      warn=$LOG_RETENTION_DIR_WARN_MB
      max=$LOG_RETENTION_DIR_MAX_MB
      ;;
    sqlite)
      if [[ -f "$path" ]]; then
        local bytes
        bytes=$(log_retention_file_bytes "$path")
        value=$(( bytes / 1024 / 1024 ))
      else
        value=0
      fi
      warn=$LOG_RETENTION_SQLITE_MAX_MB
      max=$LOG_RETENTION_SQLITE_VACUUM_MB
      ;;
    *)
      return 0
      ;;
  esac
  emit_metric "$label" "$value" "$warn" "$max" "MiB" \
    "run_scripts_log_retention_sh_apply"
}

# Opt-in: enables the ORDO/Codex log retention metric block. Default off
# so the existing host_health preflight contract remains unchanged for
# callers that did not subscribe to #747 — operators who want the new
# preflight warning set HOST_HEALTH_INCLUDE_LOG_RETENTION=1.
: "${HOST_HEALTH_INCLUDE_LOG_RETENTION:=0}"
if [[ "$HOST_HEALTH_INCLUDE_LOG_RETENTION" == "1" ]]; then
  emit_log_retention_metric "orch_log_mb" "$LOG_RETENTION_ORCH_DIR" dir
  emit_log_retention_metric "codex_log_mb" "$LOG_RETENTION_CODEX_LOG_DIR" dir
  emit_log_retention_metric "codex_sqlite_mb" "$LOG_RETENTION_CODEX_SQLITE" sqlite
fi

emit_codex_mcp_startup_failures
emit_codex_connector_directory_drift

if [[ "$HOST_HEALTH_CRITICAL" -eq 1 ]]; then
  printf 'HOST_HEALTH summary=critical signals=%s\n' "$(IFS=,; printf '%s' "${HOST_HEALTH_SIGNALS[*]}")"
  [[ "$DO_REFUSE" -eq 1 ]] && exit 7
elif [[ "$HOST_HEALTH_WARNING" -eq 1 ]]; then
  printf 'HOST_HEALTH summary=warning signals=%s\n' "$(IFS=,; printf '%s' "${HOST_HEALTH_SIGNALS[*]}")"
else
  printf 'HOST_HEALTH summary=ok signals=\n'
fi

exit 0
