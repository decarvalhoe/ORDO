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

By default warnings are informational. With --refuse, critical metrics exit 7
so callers can fail closed before starting more probes.

Set HOST_HEALTH_CODEX_STARTUP_LOGS to a colon-separated list of pane/debug log
files to surface Codex plugin/MCP startup failures as readiness signals.
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
emit_codex_mcp_startup_failures

if [[ "$HOST_HEALTH_CRITICAL" -eq 1 ]]; then
  printf 'HOST_HEALTH summary=critical signals=%s\n' "$(IFS=,; printf '%s' "${HOST_HEALTH_SIGNALS[*]}")"
  [[ "$DO_REFUSE" -eq 1 ]] && exit 7
elif [[ "$HOST_HEALTH_WARNING" -eq 1 ]]; then
  printf 'HOST_HEALTH summary=warning signals=%s\n' "$(IFS=,; printf '%s' "${HOST_HEALTH_SIGNALS[*]}")"
else
  printf 'HOST_HEALTH summary=ok signals=\n'
fi

exit 0
