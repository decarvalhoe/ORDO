#!/usr/bin/env bash
# Emit provider-neutral ORDO agent status declarations.
set -euo pipefail

TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=lib/agent_status.sh
source "$TK/lib/agent_status.sh"

usage() {
  cat <<EOF >&2
usage: agent_status.sh declare --project <key> --agent <id> --target <issue|pr>
       --status <status> --reason <text> [options]

Statuses: $(agent_status_allowed_statuses)

Options:
  --workdir <path>              Workspace path, when available
  --workspace <id>              Non-path workspace identifier
  --branch <branch>             Git branch, auto-detected from --workdir when omitted
  --head <sha>                  Git HEAD, auto-detected from --workdir when omitted
  --dirty <count|state>         Dirty/worktree state, auto-detected from --workdir when omitted
  --timestamp <iso-utc>         Declaration timestamp, default now
  --evidence <path-or-url>      Optional evidence pointer
  --phase <text>                Optional current phase
  --activity-ts <iso-utc>       Optional last activity timestamp
  --progress-note <text>        Optional progress note
  --blocker-category <text>     Optional blocker category
  --operator-action <text>      Optional required operator action
  --validation-state <text>     Optional validation state
  --handoff-url <url>           Optional PR/issue handoff URL
  --dependency <text>           Optional dependency being waited on
  --permission-state <text>     Optional tool/permission prompt state
  --retry-count <n>             Optional retry count
  --next-action <text>          Optional next intended action
EOF
}

cmd=${1:-}
case "$cmd" in
  declare) shift ;;
  -h|--help|"")
    usage
    exit 0
    ;;
  *)
    printf 'unknown command: %s\n' "$cmd" >&2
    usage
    exit 2
    ;;
esac

project=""
agent_id=""
target=""
workdir=""
workspace_id=""
branch=""
head=""
dirty=""
status=""
reason=""
timestamp=""
evidence=""
phase=""
activity_ts=""
progress_note=""
blocker_category=""
operator_action=""
validation_state=""
handoff_url=""
dependency=""
permission_state=""
retry_count=""
next_action=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) project=${2:?missing value for --project}; shift 2 ;;
    --agent) agent_id=${2:?missing value for --agent}; shift 2 ;;
    --target) target=${2:?missing value for --target}; shift 2 ;;
    --workdir) workdir=${2:?missing value for --workdir}; shift 2 ;;
    --workspace) workspace_id=${2:?missing value for --workspace}; shift 2 ;;
    --branch) branch=${2:?missing value for --branch}; shift 2 ;;
    --head) head=${2:?missing value for --head}; shift 2 ;;
    --dirty) dirty=${2:?missing value for --dirty}; shift 2 ;;
    --status) status=${2:?missing value for --status}; shift 2 ;;
    --reason) reason=${2:?missing value for --reason}; shift 2 ;;
    --timestamp) timestamp=${2:?missing value for --timestamp}; shift 2 ;;
    --evidence) evidence=${2:?missing value for --evidence}; shift 2 ;;
    --phase) phase=${2:?missing value for --phase}; shift 2 ;;
    --activity-ts) activity_ts=${2:?missing value for --activity-ts}; shift 2 ;;
    --progress-note) progress_note=${2:?missing value for --progress-note}; shift 2 ;;
    --blocker-category) blocker_category=${2:?missing value for --blocker-category}; shift 2 ;;
    --operator-action) operator_action=${2:?missing value for --operator-action}; shift 2 ;;
    --validation-state) validation_state=${2:?missing value for --validation-state}; shift 2 ;;
    --handoff-url) handoff_url=${2:?missing value for --handoff-url}; shift 2 ;;
    --dependency) dependency=${2:?missing value for --dependency}; shift 2 ;;
    --permission-state) permission_state=${2:?missing value for --permission-state}; shift 2 ;;
    --retry-count) retry_count=${2:?missing value for --retry-count}; shift 2 ;;
    --next-action) next_action=${2:?missing value for --next-action}; shift 2 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown arg: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -n "$status" ]] && ! agent_status_known_status "$status"; then
  printf 'unknown status: %s (allowed: %s)\n' "$status" "$(agent_status_allowed_statuses)" >&2
  exit 2
fi

missing=()
[[ -n "$project" ]] || missing+=(--project)
[[ -n "$agent_id" ]] || missing+=(--agent)
[[ -n "$target" ]] || missing+=(--target)
[[ -n "$status" ]] || missing+=(--status)
[[ -n "$reason" ]] || missing+=(--reason)
if [[ "${#missing[@]}" -gt 0 ]]; then
  printf 'missing required arguments: %s\n' "${missing[*]}" >&2
  exit 2
fi

[[ -n "$timestamp" ]] || timestamp=$(agent_status_now_iso)
[[ -n "$workdir" ]] || workdir=${PWD:-}

if [[ -n "$workdir" && -e "$workdir/.git" ]]; then
  [[ -n "$branch" ]] || branch=$(git -C "$workdir" branch --show-current 2>/dev/null || true)
  [[ -n "$head" ]] || head=$(git -C "$workdir" rev-parse HEAD 2>/dev/null || true)
  if [[ -z "$dirty" ]]; then
    dirty=$(git -C "$workdir" status --porcelain 2>/dev/null | wc -l | tr -d ' ' || true)
  fi
fi

continuation=false
case "$status" in
  done|handoff_ready) continuation=true ;;
esac

record=$(
  jq -nc \
    --arg project "$project" \
    --arg agent_id "$agent_id" \
    --arg target "$target" \
    --arg workdir "$workdir" \
    --arg workspace_id "$workspace_id" \
    --arg branch "$branch" \
    --arg head "$head" \
    --arg dirty "$dirty" \
    --arg status "$status" \
    --arg reason "$reason" \
    --arg timestamp "$timestamp" \
    --arg evidence "$evidence" \
    --arg phase "$phase" \
    --arg activity_ts "$activity_ts" \
    --arg progress_note "$progress_note" \
    --arg blocker_category "$blocker_category" \
    --arg operator_action "$operator_action" \
    --arg validation_state "$validation_state" \
    --arg handoff_url "$handoff_url" \
    --arg dependency "$dependency" \
    --arg permission_state "$permission_state" \
    --arg retry_count "$retry_count" \
    --arg next_action "$next_action" \
    --argjson continuation "$continuation" '
      def blank_to_null: if . == "" then null else . end;
      def compact_object: with_entries(select(.value != null and .value != ""));
      {
        schema_version: 1,
        project: $project,
        agent_id: $agent_id,
        target: $target,
        workspace: {
          workdir: ($workdir | blank_to_null),
          id: ($workspace_id | blank_to_null)
        } | compact_object,
        git: {
          branch: ($branch | blank_to_null),
          head: ($head | blank_to_null),
          dirty: ($dirty | blank_to_null)
        } | compact_object,
        status: $status,
        reason: $reason,
        timestamp: $timestamp,
        evidence: ($evidence | blank_to_null),
        optional: {
          phase: ($phase | blank_to_null),
          last_activity_ts: ($activity_ts | blank_to_null),
          progress_note: ($progress_note | blank_to_null),
          blocker_category: ($blocker_category | blank_to_null),
          required_operator_action: ($operator_action | blank_to_null),
          validation_state: ($validation_state | blank_to_null),
          handoff_url: ($handoff_url | blank_to_null),
          dependency: ($dependency | blank_to_null),
          permission_state: ($permission_state | blank_to_null),
          retry_count: (($retry_count | tonumber?) // null),
          next_action: ($next_action | blank_to_null)
        } | compact_object,
        continuation_signal: {
          queued: $continuation,
          mode: (if $continuation then "local_state_wake" else "none" end),
          durable_queue: "agent-status/events.jsonl"
        }
      }
      | if (.workspace | length) == 0 then del(.workspace) else . end
      | if (.git | length) == 0 then del(.git) else . end
      | if (.optional | length) == 0 then del(.optional) else . end
      | if .evidence == null then del(.evidence) else . end
    '
)

agent_status_write_record "$project" "$agent_id" "$status" "$record"
printf '%s\n' "$record"
