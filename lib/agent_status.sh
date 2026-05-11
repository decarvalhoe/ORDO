#!/usr/bin/env bash
# Provider-neutral agent status declaration helpers.
#
# The declaration path is local state by design: agents append JSONL records and
# atomically update a latest-status file under ORCH_STATE_BASE. Capacity views
# can batch-read those files without SSH, pane capture, or long-lived watchers.

AGENT_STATUS_KNOWN_STATUSES=(
  "accepted"
  "working"
  "blocked"
  "waiting_for_operator"
  "validating"
  "finalizing"
  "done"
  "no_progress"
  "handoff_ready"
)

agent_status_known_status() {
  local status=${1:?usage: agent_status_known_status <status>}
  local known
  for known in "${AGENT_STATUS_KNOWN_STATUSES[@]}"; do
    [[ "$status" == "$known" ]] && return 0
  done
  return 1
}

agent_status_allowed_statuses() {
  local IFS=','
  printf '%s\n' "${AGENT_STATUS_KNOWN_STATUSES[*]}"
}

agent_status_state_base() {
  printf '%s\n' "${ORCH_STATE_BASE:-${XDG_DATA_HOME:-/root/.local/share}/orch-state}"
}

agent_status_project_dir() {
  local project=${1:?usage: agent_status_project_dir <project>}
  local root
  root="$(agent_status_state_base)/$project/agent-status"
  mkdir -p "$root/latest"
  printf '%s\n' "$root"
}

agent_status_key() {
  local raw=${1:?usage: agent_status_key <agent-id>}
  local sanitized hash
  sanitized=$(printf '%s' "$raw" | tr -c 'A-Za-z0-9_.@-' '_' | sed -E 's/_+/_/g; s/^_//; s/_$//')
  [[ -n "$sanitized" ]] || sanitized="agent"
  hash=$(printf '%s' "$raw" | sha256sum | cut -c1-10)
  printf '%s-%s\n' "${sanitized:0:72}" "$hash"
}

agent_status_latest_file() {
  local project=${1:?usage: agent_status_latest_file <project> <agent-id>}
  local agent_id=${2:?usage: agent_status_latest_file <project> <agent-id>}
  local root
  root=$(agent_status_project_dir "$project")
  printf '%s/latest/%s.json\n' "$root" "$(agent_status_key "$agent_id")"
}

agent_status_now_iso() {
  date -u +'%Y-%m-%dT%H:%M:%SZ'
}

agent_status_now_epoch() {
  if [[ -n "${AGENT_STATUS_NOW_EPOCH:-}" ]]; then
    printf '%s\n' "$AGENT_STATUS_NOW_EPOCH"
  else
    date -u +%s
  fi
}

agent_status_epoch_from_iso() {
  local timestamp=${1:?usage: agent_status_epoch_from_iso <timestamp>}
  date -u -d "$timestamp" +%s
}

agent_status_age_sec() {
  local timestamp=${1:?usage: agent_status_age_sec <timestamp> [now-epoch]}
  local now=${2:-}
  local then_epoch
  then_epoch=$(agent_status_epoch_from_iso "$timestamp") || return 1
  [[ -n "$now" ]] || now=$(agent_status_now_epoch)
  printf '%s\n' "$((now - then_epoch))"
}

agent_status_read_latest() {
  local project=${1:?usage: agent_status_read_latest <project> <agent-id>}
  local agent_id=${2:?usage: agent_status_read_latest <project> <agent-id>}
  local latest
  latest=$(agent_status_latest_file "$project" "$agent_id")
  [[ -f "$latest" ]] || return 1
  jq -c . "$latest"
}

agent_status_pending_event_count() {
  local project=${1:?usage: agent_status_pending_event_count <project> <agent-id>}
  local agent_id=${2:?usage: agent_status_pending_event_count <project> <agent-id>}
  local root events
  root=$(agent_status_project_dir "$project")
  events="$root/events.jsonl"
  [[ -f "$events" ]] || {
    printf '0\n'
    return 0
  }
  jq -c --arg agent_id "$agent_id" \
    'select(.agent_id == $agent_id and (.continuation_signal.queued == true))' \
    "$events" 2>/dev/null | wc -l | tr -d ' '
}

agent_status_loop_pids() {
  local project=${1:?usage: agent_status_loop_pids <project>}
  local proc_dir=${ORCH_PROC_DIR:-/proc}
  local self=$$
  local pid_dir pid arg base i
  local -a argv

  for pid_dir in "$proc_dir"/[0-9]*; do
    [[ -e "$pid_dir" ]] || continue
    pid=${pid_dir##*/}
    [[ "$pid" == "$self" ]] && continue
    [[ -r "$pid_dir/cmdline" ]] || continue
    if ! mapfile -d '' -t argv < "$pid_dir/cmdline" 2>/dev/null; then
      continue
    fi
    [[ ${#argv[@]} -ge 2 ]] || continue
    for ((i = 0; i < ${#argv[@]} - 1; i++)); do
      arg=${argv[i]}
      base=${arg##*/}
      if [[ "$base" == "orch_loop.sh" && "${argv[i+1]}" == "$project" ]]; then
        printf '%s\n' "$pid"
        break
      fi
    done
  done
}

agent_status_signal_loop() {
  local project=${1:?usage: agent_status_signal_loop <project>}
  local pid count=0

  [[ "${AGENT_STATUS_WAKE_SIGNAL:-1}" != "0" ]] || {
    printf '0\n'
    return 0
  }

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    if kill -USR2 "$pid" 2>/dev/null; then
      count=$((count + 1))
    fi
  done < <(agent_status_loop_pids "$project")

  printf '%s\n' "$count"
}

agent_status_write_record() {
  local project=${1:?usage: agent_status_write_record <project> <agent-id> <status> <record-json>}
  local agent_id=${2:?usage: agent_status_write_record <project> <agent-id> <status> <record-json>}
  local status=${3:?usage: agent_status_write_record <project> <agent-id> <status> <record-json>}
  local record=${4:?usage: agent_status_write_record <project> <agent-id> <status> <record-json>}
  local root latest latest_dir tmp timestamp state_base

  root=$(agent_status_project_dir "$project")
  latest=$(agent_status_latest_file "$project" "$agent_id")
  latest_dir=$(dirname "$latest")
  tmp=$(mktemp "$latest_dir/.tmp.$(agent_status_key "$agent_id").XXXXXX")
  printf '%s\n' "$record" > "$tmp"
  mv "$tmp" "$latest"
  printf '%s\n' "$record" >> "$root/declarations.jsonl"

  case "$status" in
    done|handoff_ready)
      local signaled
      printf '%s\n' "$record" >> "$root/events.jsonl"
      timestamp=$(printf '%s' "$record" | jq -r '.timestamp // ""')
      printf '%s\t%s\t%s\n' "$timestamp" "$agent_id" "$status" > "$root/wake.pending"
      state_base=$(agent_status_state_base)
      mkdir -p "$state_base/$project"
      printf '%s\t%s\t%s\n' "$timestamp" "$agent_id" "$status" > "$state_base/$project/orch.run_now"
      signaled=$(agent_status_signal_loop "$project" 2>/dev/null || printf '0')
      printf '%s\t%s\t%s\t%s\n' "$timestamp" "$agent_id" "$status" "$signaled" > "$root/wake.signal"
      ;;
  esac
}
