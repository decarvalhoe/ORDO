#!/usr/bin/env bash
# host_assessment.sh - structured host capability assessment for ORDO onboarding.

if [[ -n "${ORDO_HOST_ASSESSMENT_LIB_LOADED:-}" ]]; then
  return 0
fi
ORDO_HOST_ASSESSMENT_LIB_LOADED=1

_ORDO_HOST_ASSESSMENT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/host_health.sh
source "$_ORDO_HOST_ASSESSMENT_LIB_DIR/host_health.sh"
# shellcheck source=lib/host_load_gate.sh
source "$_ORDO_HOST_ASSESSMENT_LIB_DIR/host_load_gate.sh"

: "${ORDO_HOST_ASSESSMENT_CPU_PER_AGENT:=2}"
: "${ORDO_HOST_ASSESSMENT_MEM_MB_PER_AGENT:=1536}"
: "${ORDO_HOST_ASSESSMENT_DISK_MB_PER_AGENT:=4096}"
: "${ORDO_HOST_ASSESSMENT_PROCESS_PER_AGENT:=40}"
: "${ORDO_HOST_ASSESSMENT_REPO_WARN_MB:=8192}"
: "${ORDO_HOST_ASSESSMENT_REPO_MAX_MB:=32768}"
: "${ORDO_HOST_ASSESSMENT_LOAD_WARN_RATIO:=0.80}"

host_assessment_truthy() {
  case "${1:-}" in
    1|yes|true|on|required) return 0 ;;
    *) return 1 ;;
  esac
}

host_assessment_uint_or_default() {
  local value=${1:-}
  local fallback=${2:?usage: host_assessment_uint_or_default <value> <fallback>}
  if [[ "$value" =~ ^[0-9]+$ ]] && [[ "$value" -gt 0 ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

host_assessment_cpu_count() {
  if [[ "${ORDO_HOST_ASSESSMENT_CPU_COUNT:-}" =~ ^[0-9]+$ ]] \
    && [[ "$ORDO_HOST_ASSESSMENT_CPU_COUNT" -gt 0 ]]; then
    printf '%s\n' "$ORDO_HOST_ASSESSMENT_CPU_COUNT"
    return 0
  fi
  _orch_host_gate_cpu_count
}

host_assessment_mem_total_mb() {
  if [[ "${ORDO_HOST_ASSESSMENT_MEM_TOTAL_MB:-}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$ORDO_HOST_ASSESSMENT_MEM_TOTAL_MB"
    return 0
  fi
  if [[ -r /proc/meminfo ]]; then
    awk '/^MemTotal:/ {printf "%d\n", int($2 / 1024); found=1} END {exit(found ? 0 : 1)}' \
      /proc/meminfo 2>/dev/null && return 0
  fi
  if command -v sysctl >/dev/null 2>&1; then
    local bytes
    bytes=$(sysctl -n hw.memsize 2>/dev/null || true)
    if [[ "$bytes" =~ ^[0-9]+$ ]] && [[ "$bytes" -gt 0 ]]; then
      awk -v bytes="$bytes" 'BEGIN {printf "%d\n", int(bytes / 1024 / 1024)}'
      return 0
    fi
  fi
  printf 'unknown\n'
}

host_assessment_mem_available_mb() {
  if [[ "${ORDO_HOST_ASSESSMENT_MEM_AVAILABLE_MB:-}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$ORDO_HOST_ASSESSMENT_MEM_AVAILABLE_MB"
    return 0
  fi
  if [[ -r /proc/meminfo ]]; then
    awk '/^MemAvailable:/ {printf "%d\n", int($2 / 1024); found=1} END {exit(found ? 0 : 1)}' \
      /proc/meminfo 2>/dev/null && return 0
  fi
  host_assessment_mem_total_mb
}

host_assessment_load_avg() {
  if [[ "${ORDO_HOST_ASSESSMENT_LOAD_AVG:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s\n' "$ORDO_HOST_ASSESSMENT_LOAD_AVG"
    return 0
  fi
  local load_file=${ORCH_HOST_GATE_LOADAVG_FILE:-}
  if [[ -n "$load_file" && -r "$load_file" ]]; then
    awk 'NR == 1 {print $1}' "$load_file"
    return 0
  fi
  if [[ -r /proc/loadavg ]]; then
    awk 'NR == 1 {print $1}' /proc/loadavg
    return 0
  fi
  printf 'unknown\n'
}

host_assessment_float_ge() {
  local lhs=${1:?usage: host_assessment_float_ge <lhs> <rhs>}
  local rhs=${2:?usage: host_assessment_float_ge <lhs> <rhs>}
  awk -v lhs="$lhs" -v rhs="$rhs" 'BEGIN { exit !((lhs + 0) >= (rhs + 0)) }'
}

host_assessment_status_by_warn_max() {
  local value=${1:?usage: host_assessment_status_by_warn_max <value> <warn> <max>}
  local warn=${2:?usage: host_assessment_status_by_warn_max <value> <warn> <max>}
  local max=${3:?usage: host_assessment_status_by_warn_max <value> <warn> <max>}
  if ! [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf 'unknown\n'
  elif [[ "$max" =~ ^[0-9]+([.][0-9]+)?$ ]] && host_assessment_float_ge "$value" "$max"; then
    printf 'critical\n'
  elif [[ "$warn" =~ ^[0-9]+([.][0-9]+)?$ ]] && host_assessment_float_ge "$value" "$warn"; then
    printf 'warning\n'
  else
    printf 'ok\n'
  fi
}

host_assessment_fork_latency_ms() {
  if [[ "${ORDO_HOST_ASSESSMENT_FORK_LATENCY_MS:-}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$ORDO_HOST_ASSESSMENT_FORK_LATENCY_MS"
    return 0
  fi
  if [[ "${ORCH_HOST_GATE_FORK_LATENCY_MS:-}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$ORCH_HOST_GATE_FORK_LATENCY_MS"
    return 0
  fi
  orch_fork_latency_ms 2>/dev/null || printf 'unknown\n'
}

host_assessment_df_values() {
  local path=${1:-.}
  local df_file=${ORDO_HOST_ASSESSMENT_DF_FILE:-${ORCH_HOST_GATE_DF_FILE:-}}
  if [[ -n "$df_file" ]]; then
    [[ -r "$df_file" ]] || {
      printf 'unknown unknown unknown unknown\n'
      return 0
    }
    awk 'NR > 1 && NF >= 5 {pct=$5; gsub("%", "", pct); print $2, $3, $4, pct; exit}' \
      "$df_file"
    return 0
  fi
  host_health_run_timeout "$HOST_HEALTH_TIMEOUT_SEC" df -Pm -- "$path" 2>/dev/null \
    | awk 'NR == 2 {pct=$5; gsub("%", "", pct); print $2, $3, $4, pct; exit}' \
    || printf 'unknown unknown unknown unknown\n'
}

host_assessment_repo_mb() {
  local repo_root=${1:-.}
  if [[ -n "${ORDO_HOST_ASSESSMENT_REPO_MB:-}" ]] \
    && [[ "$ORDO_HOST_ASSESSMENT_REPO_MB" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$ORDO_HOST_ASSESSMENT_REPO_MB"
    return 0
  fi
  host_health_du_mb "$repo_root" 2>/dev/null || printf 'unknown\n'
}

host_assessment_process_count() {
  if [[ "${ORDO_HOST_ASSESSMENT_PROCESS_COUNT:-}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$ORDO_HOST_ASSESSMENT_PROCESS_COUNT"
    return 0
  fi
  if [[ -n "${ORCH_HOST_GATE_PS_FILE:-}" && -r "$ORCH_HOST_GATE_PS_FILE" ]]; then
    awk 'NF {count++} END {print count + 0}' "$ORCH_HOST_GATE_PS_FILE"
    return 0
  fi
  host_health_run_timeout "$HOST_HEALTH_TIMEOUT_SEC" ps -e -o pid= 2>/dev/null \
    | awk 'NF {count++} END {print count + 0}' \
    || printf 'unknown\n'
}

host_assessment_process_limit() {
  if [[ -n "${ORDO_HOST_ASSESSMENT_PROCESS_LIMIT:-}" ]]; then
    printf '%s\n' "$ORDO_HOST_ASSESSMENT_PROCESS_LIMIT"
    return 0
  fi
  local limit
  limit=$(ulimit -u 2>/dev/null || true)
  [[ -n "$limit" ]] && printf '%s\n' "$limit" || printf 'unknown\n'
}

host_assessment_execution_context_json() {
  local class=${ORDO_HOST_ASSESSMENT_EXECUTION_CONTEXT:-}
  local -a signals=()

  if [[ -z "$class" ]]; then
    if [[ -n "${SSH_CONNECTION:-${SSH_CLIENT:-}}" ]]; then
      class="remote_shell"
      signals+=("remote_shell_env")
    elif [[ -f /.dockerenv ]]; then
      class="container"
      signals+=("container_marker")
    elif grep -Eqa '(container|docker|kubepods)' /proc/1/cgroup 2>/dev/null; then
      class="container"
      signals+=("container_cgroup")
    else
      class="local_shell"
    fi
  else
    signals+=("configured")
  fi

  printf '%s\n' "${signals[@]}" \
    | jq -R . \
    | jq -cs --arg class "$class" '{
        class:$class,
        signals: map(select(length > 0)),
        remote_constraint: ($class == "remote_shell"),
        local_constraint: ($class == "local_shell")
      }'
}

host_assessment_terminal_multiplexer_json() {
  local required=false configured=false available=null status="not_configured"
  local cmd=${ORDO_HOST_ASSESSMENT_MULTIPLEXER_CMD:-}

  if host_assessment_truthy "${ORDO_HOST_ASSESSMENT_MULTIPLEXER_REQUIRED:-0}"; then
    required=true
  fi
  if [[ -n "$cmd" ]]; then
    configured=true
    if command -v "$cmd" >/dev/null 2>&1; then
      available=true
      status="available"
    else
      available=false
      if [[ "$required" == "true" ]]; then
        status="critical"
      else
        status="unavailable_optional"
      fi
    fi
  elif [[ "$required" == "true" ]]; then
    available=false
    status="critical"
  fi

  jq -nc \
    --argjson required "$required" \
    --argjson configured "$configured" \
    --argjson available "$available" \
    --arg status "$status" \
    '{
      required:$required,
      configured:$configured,
      available:$available,
      status:$status,
      topology_required:$required,
      note:"terminal_multiplexer_is_optional_unless_configured_required"
    }'
}

host_assessment_component_status_json() {
  local cpu_count mem_total mem_available load_avg load_max load_warn fork_ms fork_max fork_warn
  local disk_size disk_used disk_available disk_used_pct repo_mb process_count process_limit
  local session_count health_status cpu_per_agent mem_per_agent disk_per_agent process_per_agent
  local repo_warn repo_max
  local repo_root=${1:-.}

  cpu_per_agent=$(host_assessment_uint_or_default "$ORDO_HOST_ASSESSMENT_CPU_PER_AGENT" 2)
  mem_per_agent=$(host_assessment_uint_or_default "$ORDO_HOST_ASSESSMENT_MEM_MB_PER_AGENT" 1536)
  disk_per_agent=$(host_assessment_uint_or_default "$ORDO_HOST_ASSESSMENT_DISK_MB_PER_AGENT" 4096)
  process_per_agent=$(host_assessment_uint_or_default "$ORDO_HOST_ASSESSMENT_PROCESS_PER_AGENT" 40)
  repo_warn=$(host_assessment_uint_or_default "$ORDO_HOST_ASSESSMENT_REPO_WARN_MB" 8192)
  repo_max=$(host_assessment_uint_or_default "$ORDO_HOST_ASSESSMENT_REPO_MAX_MB" 32768)

  cpu_count=$(host_assessment_cpu_count)
  mem_total=$(host_assessment_mem_total_mb)
  mem_available=$(host_assessment_mem_available_mb)
  load_avg=$(host_assessment_load_avg)
  if [[ "${ORCH_HOST_GATE_LOAD_AVG_MAX:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    load_max=$ORCH_HOST_GATE_LOAD_AVG_MAX
  else
    load_max=$(awk -v cpus="$cpu_count" -v per="$ORCH_HOST_GATE_LOAD_PER_CPU_MAX" \
      'BEGIN {printf "%.2f\n", (cpus + 0) * (per + 0)}')
  fi
  load_warn=$(awk -v max="$load_max" -v ratio="$ORDO_HOST_ASSESSMENT_LOAD_WARN_RATIO" \
    'BEGIN {printf "%.2f\n", (max + 0) * (ratio + 0)}')

  fork_ms=$(host_assessment_fork_latency_ms)
  fork_max=$ORCH_HOST_GATE_FORK_LATENCY_MAX_MS
  fork_warn=$(awk -v max="$fork_max" 'BEGIN {printf "%d\n", int((max + 0) * 0.80)}')

  read -r disk_size disk_used disk_available disk_used_pct < <(host_assessment_df_values "$repo_root")
  repo_mb=$(host_assessment_repo_mb "$repo_root")
  process_count=$(host_assessment_process_count)
  process_limit=$(host_assessment_process_limit)
  session_count=$(host_health_session_count)
  health_status=$(host_health_classify_metric "$session_count" "$HOST_HEALTH_SESSION_WARN" "$HOST_HEALTH_SESSION_MAX")

  jq -nc \
    --arg cpu_count "$cpu_count" \
    --arg cpu_per_agent "$cpu_per_agent" \
    --arg mem_total "$mem_total" \
    --arg mem_available "$mem_available" \
    --arg mem_per_agent "$mem_per_agent" \
    --arg disk_size "$disk_size" \
    --arg disk_used "$disk_used" \
    --arg disk_available "$disk_available" \
    --arg disk_used_pct "$disk_used_pct" \
    --arg disk_per_agent "$disk_per_agent" \
    --arg load_avg "$load_avg" \
    --arg load_warn "$load_warn" \
    --arg load_max "$load_max" \
    --arg fork_ms "$fork_ms" \
    --arg fork_warn "$fork_warn" \
    --arg fork_max "$fork_max" \
    --arg repo_mb "$repo_mb" \
    --arg repo_warn "$repo_warn" \
    --arg repo_max "$repo_max" \
    --arg process_count "$process_count" \
    --arg process_limit "$process_limit" \
    --arg process_per_agent "$process_per_agent" \
    --arg session_count "$session_count" \
    --arg session_warn "$HOST_HEALTH_SESSION_WARN" \
    --arg session_max "$HOST_HEALTH_SESSION_MAX" \
    --arg health_status "$health_status" \
    '
      def num($v): if ($v | test("^[0-9]+$")) then ($v | tonumber) else null end;
      def fnum($v): if ($v | test("^[0-9]+([.][0-9]+)?$")) then ($v | tonumber) else null end;
      def cap($value; $per): if ($value != null and $per != null and $per > 0) then (($value / $per) | floor) else null end;
      def status_warn_max($value; $warn; $max):
        if $value == null then "unknown"
        elif ($max != null and $value >= $max) then "critical"
        elif ($warn != null and $value >= $warn) then "warning"
        else "ok" end;
      def process_status($count; $limit):
        if $count == null then "unknown"
        elif $limit == null then "ok"
        elif $count >= $limit then "critical"
        elif $count >= ($limit * 0.80) then "warning"
        else "ok" end;
      def process_capacity($count; $limit; $per):
        if $limit == null then null
        elif ($count != null and $per != null and $per > 0) then ([((($limit - $count) / $per) | floor), 0] | max)
        else null end;
      {
        cpu:{
          count:num($cpu_count),
          per_agent:num($cpu_per_agent),
          capacity_agents:cap(num($cpu_count); num($cpu_per_agent)),
          status:(if num($cpu_count) == null then "unknown" else "ok" end)
        },
        memory:{
          total_mb:num($mem_total),
          available_mb:num($mem_available),
          per_agent_mb:num($mem_per_agent),
          capacity_agents:cap(num($mem_available); num($mem_per_agent)),
          status:(if num($mem_available) == null then "unknown" elif num($mem_available) < num($mem_per_agent) then "critical" elif num($mem_available) < (num($mem_per_agent) * 2) then "warning" else "ok" end)
        },
        disk:{
          size_mb:num($disk_size),
          used_mb:num($disk_used),
          available_mb:num($disk_available),
          used_pct:num($disk_used_pct),
          per_agent_mb:num($disk_per_agent),
          capacity_agents:cap(num($disk_available); num($disk_per_agent)),
          status:status_warn_max(num($disk_used_pct); 80; 90)
        },
        load:{
          one_min:fnum($load_avg),
          warning_threshold:fnum($load_warn),
          critical_threshold:fnum($load_max),
          status:status_warn_max(fnum($load_avg); fnum($load_warn); fnum($load_max))
        },
        fork_latency:{
          ms:num($fork_ms),
          warning_threshold_ms:num($fork_warn),
          critical_threshold_ms:num($fork_max),
          status:status_warn_max(num($fork_ms); num($fork_warn); num($fork_max))
        },
        process_limits:{
          process_count:num($process_count),
          process_limit:(if ($process_limit == "unlimited") then null else num($process_limit) end),
          process_limit_class:(if ($process_limit == "unlimited") then "unlimited" elif num($process_limit) == null then "unknown" else "bounded" end),
          per_agent:num($process_per_agent),
          headroom:(if ($process_limit == "unlimited" or num($process_limit) == null or num($process_count) == null) then null else (num($process_limit) - num($process_count)) end),
          capacity_agents:process_capacity(num($process_count); (if $process_limit == "unlimited" then null else num($process_limit) end); num($process_per_agent)),
          status:process_status(num($process_count); (if $process_limit == "unlimited" then null else num($process_limit) end))
        },
        repo_footprint:{
          measured:true,
          size_mb:num($repo_mb),
          warning_threshold_mb:num($repo_warn),
          critical_threshold_mb:num($repo_max),
          path_redacted:true,
          status:status_warn_max(num($repo_mb); num($repo_warn); num($repo_max))
        },
        host_sessions:{
          count:num($session_count),
          warning_threshold:num($session_warn),
          critical_threshold:num($session_max),
          status:$health_status
        }
      }
    '
}

host_assessment_report_json() {
  local requested=${1:-1}
  local repo_root=${2:-.}
  requested=$(host_assessment_uint_or_default "$requested" 1)

  local components execution_context terminal_multiplexer
  components=$(host_assessment_component_status_json "$repo_root")
  execution_context=$(host_assessment_execution_context_json)
  terminal_multiplexer=$(host_assessment_terminal_multiplexer_json)

  jq -nc \
    --argjson requested "$requested" \
    --argjson components "$components" \
    --argjson execution_context "$execution_context" \
    --argjson terminal_multiplexer "$terminal_multiplexer" \
    --arg cpu_per_agent "$ORDO_HOST_ASSESSMENT_CPU_PER_AGENT" \
    --arg mem_per_agent "$ORDO_HOST_ASSESSMENT_MEM_MB_PER_AGENT" \
    --arg disk_per_agent "$ORDO_HOST_ASSESSMENT_DISK_MB_PER_AGENT" \
    --arg process_per_agent "$ORDO_HOST_ASSESSMENT_PROCESS_PER_AGENT" \
    '
      def dimension_capacity:
        {
          cpu:$components.cpu.capacity_agents,
          memory:$components.memory.capacity_agents,
          disk:$components.disk.capacity_agents,
          process_limits:$components.process_limits.capacity_agents
        };
      def known_caps: ([dimension_capacity[]] | map(select(. != null)));
      def estimated_capacity: if (known_caps | length) > 0 then (known_caps | min) else null end;
      def status_list:
        [
          $components.cpu.status,
          $components.memory.status,
          $components.disk.status,
          $components.load.status,
          $components.fork_latency.status,
          $components.process_limits.status,
          $components.repo_footprint.status,
          $components.host_sessions.status,
          $terminal_multiplexer.status
        ];
      def worst_status:
        if any(status_list[]; . == "critical") then "critical"
        elif any(status_list[]; . == "warning" or . == "unknown" or . == "unavailable_optional") then "warning"
        else "ok" end;
      def bottlenecks:
        [
          (if $components.cpu.capacity_agents != null and $components.cpu.capacity_agents < $requested then "cpu_capacity" else empty end),
          (if $components.memory.capacity_agents != null and $components.memory.capacity_agents < $requested then "memory_capacity" else empty end),
          (if $components.disk.capacity_agents != null and $components.disk.capacity_agents < $requested then "disk_capacity" else empty end),
          (if $components.process_limits.capacity_agents != null and $components.process_limits.capacity_agents < $requested then "process_limit_capacity" else empty end),
          (if $components.load.status != "ok" then "load_pressure" else empty end),
          (if $components.fork_latency.status != "ok" then "fork_latency" else empty end),
          (if $components.repo_footprint.status != "ok" then "repo_footprint" else empty end),
          (if $components.host_sessions.status != "ok" then "host_session_pressure" else empty end),
          (if $terminal_multiplexer.status == "critical" then "terminal_multiplexer_required_unavailable" else empty end)
        ] | unique;
      def undersized: estimated_capacity != null and estimated_capacity < $requested;
      def decision:
        if worst_status == "critical" or undersized then
          if $execution_context.class == "local_shell" then "use_remote_host" else "use_another_prepared_node" end
        else "keep_current_machine" end;
      def suitability:
        if worst_status == "critical" then "degraded"
        elif undersized then "undersized"
        elif worst_status == "warning" then "usable_with_warnings"
        else "suitable" end;
      {
        schema_version:"ordo.host_assessment.v1",
        assessment_type:"host_capability",
        requested_fleet:{agents:$requested},
        capacity:{
          estimated_agents:estimated_capacity,
          dimensions:dimension_capacity,
          sizing_basis:{
            cpu_per_agent:($cpu_per_agent | tonumber? // null),
            memory_mb_per_agent:($mem_per_agent | tonumber? // null),
            disk_mb_per_agent:($disk_per_agent | tonumber? // null),
            process_slots_per_agent:($process_per_agent | tonumber? // null)
          }
        },
        capabilities:($components + {
          execution_context:$execution_context,
          terminal_multiplexer:$terminal_multiplexer
        }),
        environment_recommendation:{
          decision:decision,
          suitability:suitability,
          bottlenecks:bottlenecks,
          explanation:(
            if decision == "keep_current_machine" and suitability == "suitable" then
              "Current machine meets the requested fleet foundation thresholds."
            elif decision == "keep_current_machine" then
              "Current machine can be used, but warnings should be reviewed before increasing fleet size."
            elif decision == "use_remote_host" then
              "Current local machine is undersized or degraded for the requested fleet; use a prepared remote host."
            else
              "Current execution environment is undersized or degraded; use another prepared node."
            end
          ),
          tradeoffs:(
            if decision == "keep_current_machine" then
              ["lowest_setup_cost","capacity_should_be_rechecked_before_scaling"]
            elif decision == "use_remote_host" then
              ["more_capacity_headroom","requires_remote_access_and_evidence_capture"]
            else
              ["avoids_current_environment_constraints","requires_prepared_node_and_evidence_capture"]
            end
          )
        }
      }
    '
}
