#!/usr/bin/env bash
# scripts/external_pr_policy_backfill.sh - one-time idempotent backfill that
# records the external-PR-mutation policy default for active project state
# directories.
#
# Older project state directories were created before ORDO encoded the
# policy that external PR mutations (PR comments, draft/ready toggles,
# labels, assignees, merge actions) default to audit-only/refused unless an
# operator authorizes them. This script writes a stable per-project marker
# that records the default policy so future incident review can reconcile
# whether a state directory predated the policy or attests to it.
#
# The script is intentionally narrow:
#
# - It writes one idempotent marker file per project under the project's
#   state directory (`<state-base>/<project>/external_pr_policy_initialized.json`).
# - It does not modify any git working directory.
# - It does not author audit lines into `/var/log/orch/<project>.log`; the
#   marker file is the canonical record.
# - It defaults to plan mode and refuses to write without `--apply`.
# - It honours `ORCH_DRY_RUN=1` and `--dry-run`, which keep the command
#   non-mutating even when `--apply` is supplied.
# - Re-running the command emits a stable `already-initialized` row per
#   project; no marker file is rewritten.

set -euo pipefail

TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=../lib/dry_run.sh
source "$TK/lib/dry_run.sh"

usage() {
  cat <<'EOF' >&2
usage:
  external_pr_policy_backfill.sh
    [--project <name> ...]
    [--scan-state-base]
    [--state-base <dir>]
    [--apply]
    [--dry-run]
    [--json|--tsv]

Records the external-PR-mutation policy default for active project state
directories. Writes one idempotent marker file per project at
`<state-base>/<project>/external_pr_policy_initialized.json`.

Defaults to plan mode. `--apply` is required to write. `--dry-run` or
`ORCH_DRY_RUN=1` keeps the command non-mutating even when `--apply` is
present.

`--state-base` overrides the per-project state root. When unset, the script
falls back to `ORCH_STATE_BASE` (matching `lib/audit_log.sh`) and finally to
`${XDG_DATA_HOME:-$HOME/.local/share}/orch-state`.

`--scan-state-base` discovers projects by listing immediate subdirectories
of the state base. `--project` arguments are merged with the discovered list
and de-duplicated.
EOF
}

require_jq() {
  command -v jq >/dev/null 2>&1 || {
    printf 'external_pr_policy_backfill: jq is required\n' >&2
    exit 2
  }
}

ARGS=()
while [[ "$#" -gt 0 ]]; do
  ARGS+=("$1")
  shift
done

dry_run_parse_args "${ARGS[@]}"
set -- "${DRY_RUN_ARGS[@]}"

require_jq

declare -a PROJECTS=()
SCAN=0
APPLY=0
FORMAT="json"
state_base=${EXTERNAL_PR_POLICY_BACKFILL_STATE_BASE:-${ORCH_STATE_BASE:-${XDG_DATA_HOME:-$HOME/.local/share}/orch-state}}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --project) PROJECTS+=("${2:?missing value for --project}"); shift 2 ;;
    --scan-state-base) SCAN=1; shift ;;
    --state-base) state_base=${2:?missing value for --state-base}; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --json) FORMAT="json"; shift ;;
    --tsv) FORMAT="tsv"; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      printf 'external_pr_policy_backfill: unknown arg: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

mode="plan"
if [[ "$APPLY" -eq 1 ]]; then
  if dry_run_enabled; then
    mode="dry-run"
  else
    mode="apply"
  fi
fi

generated_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

declare -a discovered=()
if [[ "$SCAN" -eq 1 && -d "$state_base" ]]; then
  while IFS= read -r entry; do
    discovered+=("$(basename "$entry")")
  done < <(find "$state_base" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort)
fi

declare -a all_projects=()
declare -A seen=()
for name in "${PROJECTS[@]}" "${discovered[@]}"; do
  [[ -n "$name" ]] || continue
  if [[ -z "${seen[$name]:-}" ]]; then
    all_projects+=("$name")
    seen[$name]=1
  fi
done

results_file=$(mktemp)
written_file=$(mktemp)
blockers_file=$(mktemp)
# shellcheck disable=SC2317
cleanup() {
  rm -f "$results_file" "$written_file" "$blockers_file"
}
trap cleanup EXIT

if [[ "${#all_projects[@]}" -eq 0 ]]; then
  printf 'no_projects_resolved\n' >> "$blockers_file"
fi

if [[ -e "$state_base" && ! -d "$state_base" ]]; then
  printf 'state_base_not_directory\n' >> "$blockers_file"
fi

emit_marker_payload() {
  local project=$1
  jq -n \
    --arg policy "external_pr_mutations" \
    --arg default "audit-only-refused-unless-authorized" \
    --arg initialized_at "$generated_at" \
    --arg source_finding "external-pr-mutation-policy-backfill" \
    --arg project "$project" \
    --argjson issue 291 \
    --argjson version 1 \
    '{
      policy:$policy,
      default:$default,
      initialized_at:$initialized_at,
      source_finding:$source_finding,
      issue:$issue,
      project:$project,
      scope:[
        "pr_comment",
        "draft_state_change",
        "label_change",
        "assignee_change",
        "review_request",
        "merge_action"
      ],
      version:$version
    }'
}

mkdir -p "$state_base"

for project in "${all_projects[@]}"; do
  project_dir="$state_base/$project"
  marker="$project_dir/external_pr_policy_initialized.json"
  if [[ -f "$marker" ]]; then
    status="already-initialized"
    initialized_at=$(jq -r '.initialized_at // ""' "$marker" 2>/dev/null || true)
    jq -nc \
      --arg project "$project" \
      --arg status "$status" \
      --arg marker "$marker" \
      --arg initialized_at "$initialized_at" \
      '{project:$project,status:$status,marker:$marker,initialized_at:(if $initialized_at == "" then null else $initialized_at end)}' >> "$results_file"
    continue
  fi

  if [[ "$mode" == "apply" ]]; then
    mkdir -p "$project_dir"
    payload=$(emit_marker_payload "$project")
    printf '%s\n' "$payload" > "$marker"
    status="initialized"
    printf '%s\n' "$marker" >> "$written_file"
  else
    status="would-initialize"
  fi

  jq -nc \
    --arg project "$project" \
    --arg status "$status" \
    --arg marker "$marker" \
    --arg initialized_at "$generated_at" \
    '{project:$project,status:$status,marker:$marker,initialized_at:(if $status == "initialized" then $initialized_at else null end)}' >> "$results_file"
done

results_json=$(jq -s '.' "$results_file")
written_json=$(jq -R -s 'split("\n") | map(select(length > 0))' "$written_file")
blockers_json=$(jq -R -s 'split("\n") | map(select(length > 0)) | unique' "$blockers_file")

initialized_count=$(jq '[.[] | select(.status == "initialized")] | length' <<< "$results_json")
already_count=$(jq '[.[] | select(.status == "already-initialized")] | length' <<< "$results_json")
would_count=$(jq '[.[] | select(.status == "would-initialize")] | length' <<< "$results_json")

emit_status() {
  local hard_blockers
  hard_blockers=$(jq -r 'length' <<< "$blockers_json")
  if [[ "$hard_blockers" -gt 0 ]]; then
    printf 'blocked\n'
    return 0
  fi
  printf '%s\n' "$mode"
}

status=$(emit_status)

if [[ "$FORMAT" == "json" ]]; then
  jq -n \
    --arg status "$status" \
    --arg mode "$mode" \
    --arg state_base "$state_base" \
    --arg generated_at "$generated_at" \
    --argjson scan "$SCAN" \
    --argjson initialized "$initialized_count" \
    --argjson already_initialized "$already_count" \
    --argjson would_initialize "$would_count" \
    --argjson results "$results_json" \
    --argjson written "$written_json" \
    --argjson blockers "$blockers_json" \
    '{
      status:$status,
      mode:$mode,
      state_base:$state_base,
      generated_at:$generated_at,
      scan_state_base:($scan==1),
      counts:{
        initialized:$initialized,
        already_initialized:$already_initialized,
        would_initialize:$would_initialize,
        total:($initialized+$already_initialized+$would_initialize)
      },
      results:$results,
      written_files:$written,
      blockers:$blockers
    }'
else
  printf 'status\t%s\n' "$status"
  printf 'mode\t%s\n' "$mode"
  printf 'state_base\t%s\n' "$state_base"
  printf 'scan_state_base\t%s\n' "$SCAN"
  jq -r '.[] | "result\t\(.project)\t\(.status)\t\(.marker)"' <<< "$results_json"
  jq -r '.[] | "written\t" + .' <<< "$written_json"
  jq -r '.[] | "blocker\t" + .' <<< "$blockers_json"
fi

if [[ "$status" == "blocked" ]]; then
  exit "${EXTERNAL_PR_POLICY_BACKFILL_REFUSAL_EXIT_CODE:-78}"
fi
