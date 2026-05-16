#!/usr/bin/env bash
# scripts/portfolio_dispatch.sh — multi-product dispatch planner (#721).
#
# Walks every project in a portfolio config, asks each project's
# dispatch_plan for ready candidates, caps the per-project count at
# MAX_CONCURRENT_DISPATCHES, and either prints the resulting plan (the
# default — safe to use as a dry-run preview) or hands the assembled
# matrix to dispatch_wave under a single wave id with `--apply`.
#
# Usage:
#   portfolio_dispatch.sh <portfolio-config> <wave-id>
#     [--apply]            Hand the matrix to dispatch_wave instead of
#                          printing the plan only.
#     [--dry-run]          Forwarded to dispatch_wave (no real submit).
#     [--limit N]          Hard cap across all projects (defaults to
#                          PORTFOLIO_MAX_TOTAL_DISPATCHES or unlimited).
#     [--matrix-out PATH]  Where to write the assembled TSV matrix.
#                          Defaults to a tempfile printed on stdout.
#     [--json]             Emit the plan as JSON (default: TSV preview).
#
# Per-project capacity:
#   MAX_CONCURRENT_DISPATCHES (in each project's config) caps the rows
#   pulled from that project's dispatch_plan. The portfolio config can
#   override per project via PORTFOLIO_MAX_CONCURRENT_DISPATCHES, a bash
#   array of `project=N` entries (matches the existing
#   PORTFOLIO_PRIORITIES idiom). When neither value is set the project
#   defaults to PORTFOLIO_DEFAULT_MAX_CONCURRENT_DISPATCHES (1) so the
#   wave stays small unless the operator opts in.
#
# Brief rendering is intentionally NOT done here: a portfolio wave
# expects briefs to be staged ahead of time at
# /tmp/dispatch-<agent>-<ticket>.md (the canonical dispatch_ticket
# staging path). Missing briefs are surfaced in the plan with a
# `brief_missing` status and excluded from the matrix handed to
# dispatch_wave. This keeps the helper safe to run repeatedly as a
# preview before any briefs exist.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/dry_run.sh"
source "$TK/lib/config_resolver.sh"
source "$TK/lib/portfolio_config.sh"
source "$TK/lib/process_safety.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

PORTFOLIO_ARG=${1:?usage: portfolio_dispatch.sh <portfolio-config> <wave-id> [--apply] [--dry-run] [--limit N]}
WAVE_ID=${2:?usage: portfolio_dispatch.sh <portfolio-config> <wave-id> [--apply] [--dry-run] [--limit N]}
shift 2

APPLY=0
TOTAL_LIMIT=""
MATRIX_OUT=""
EMIT_JSON=0
PROJECT_FILTER=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --limit)
      TOTAL_LIMIT=${2:?missing value for --limit}
      shift
      ;;
    --limit=*) TOTAL_LIMIT=${1#--limit=} ;;
    --matrix-out)
      MATRIX_OUT=${2:?missing value for --matrix-out}
      shift
      ;;
    --matrix-out=*) MATRIX_OUT=${1#--matrix-out=} ;;
    --project)
      PROJECT_FILTER=${2:?missing value for --project}
      shift
      ;;
    --project=*) PROJECT_FILTER=${1#--project=} ;;
    --json) EMIT_JSON=1 ;;
    *)
      printf 'unknown arg: %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done

[[ "$WAVE_ID" =~ ^[A-Za-z0-9._-]+$ ]] || {
  printf 'invalid wave id: %s (allowed: [A-Za-z0-9._-])\n' "$WAVE_ID" >&2
  exit 2
}
if [[ -n "$TOTAL_LIMIT" ]] && ! [[ "$TOTAL_LIMIT" =~ ^[0-9]+$ ]]; then
  printf 'invalid --limit value: %s\n' "$TOTAL_LIMIT" >&2
  exit 2
fi

load_portfolio_config "$PORTFOLIO_ARG"

: "${PORTFOLIO_DEFAULT_MAX_CONCURRENT_DISPATCHES:=1}"

portfolio_max_concurrent_for_project() {
  local project=${1:?usage: portfolio_max_concurrent_for_project <project>}
  local entry name value
  if declare -p PORTFOLIO_MAX_CONCURRENT_DISPATCHES >/dev/null 2>&1; then
    for entry in "${PORTFOLIO_MAX_CONCURRENT_DISPATCHES[@]}"; do
      if [[ "$entry" == *"="* ]]; then
        IFS='=' read -r name value <<<"$entry"
      else
        IFS='|' read -r name value _ <<<"$entry"
      fi
      if [[ "$name" == "$project" ]] && [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$value"
        return 0
      fi
    done
  fi
  printf ''
}

# Resolve dispatch_plan binary; respect override for tests.
DISPATCH_PLAN_BIN="${ORCH_PORTFOLIO_DISPATCH_PLAN_BIN:-$TK/scripts/dispatch_plan.sh}"
DISPATCH_WAVE_BIN="${ORCH_PORTFOLIO_DISPATCH_WAVE_BIN:-$TK/scripts/dispatch_wave.sh}"
DISPATCH_PLAN_TIMEOUT_SEC="${ORCH_PORTFOLIO_PLAN_TIMEOUT_SEC:-45}"
BRIEF_STAGING_DIR="${ORCH_DISPATCH_STAGING_DIR:-/tmp}"

declare -a portfolio_rows=()
declare -a portfolio_blockers=()
declare -A project_caps=()
declare -A project_counts=()
total_selected=0

emit_warn() {
  printf 'portfolio_dispatch: %s\n' "$*" >&2
}

# Read per-project MAX_CONCURRENT_DISPATCHES by sourcing the project
# config in a subshell. The portfolio-level override (when present) wins.
read_project_max_concurrent() {
  local project_cfg=${1:?usage: read_project_max_concurrent <project-cfg>}
  bash -c '
    set -euo pipefail
    # shellcheck disable=SC1090
    source "$1"
    printf "%s\n" "${MAX_CONCURRENT_DISPATCHES:-}"
  ' _ "$project_cfg" 2>/dev/null || printf ''
}

while IFS='|' read -r project project_cfg; do
  [[ -n "$project" && -n "$project_cfg" ]] || continue
  if [[ -n "$PROJECT_FILTER" && "$PROJECT_FILTER" != "$project" ]]; then
    continue
  fi

  if [[ ! -f "$project_cfg" ]]; then
    portfolio_blockers+=("project=$project reason=missing_config path=$project_cfg")
    continue
  fi

  cap=$(portfolio_max_concurrent_for_project "$project" || true)
  if [[ -z "$cap" ]]; then
    cap=$(read_project_max_concurrent "$project_cfg" || true)
  fi
  if [[ -z "$cap" ]]; then
    cap="$PORTFOLIO_DEFAULT_MAX_CONCURRENT_DISPATCHES"
  fi
  if ! [[ "$cap" =~ ^[0-9]+$ ]]; then
    portfolio_blockers+=("project=$project reason=invalid_max_concurrent value=$cap")
    continue
  fi
  project_caps[$project]="$cap"
  project_counts[$project]=0

  if [[ "$cap" -eq 0 ]]; then
    portfolio_rows+=("$project	<paused>	<paused>	$project_cfg	cap=0 status=paused")
    continue
  fi

  plan_stderr=$(mktemp)
  plan_json=$(orch_run_timeout "$DISPATCH_PLAN_TIMEOUT_SEC" \
    bash "$DISPATCH_PLAN_BIN" "$project_cfg" --ready-only --json \
    2>"$plan_stderr" || true)
  plan_stderr_tail=$(tail -c 1500 "$plan_stderr" 2>/dev/null | tr '\t\r\n' '   ')
  rm -f "$plan_stderr"

  if [[ -z "$plan_json" ]]; then
    portfolio_blockers+=("project=$project reason=dispatch_plan_no_output detail=$plan_stderr_tail")
    continue
  fi

  selected=0
  while IFS=$'\t' read -r ticket agent_hint signals; do
    [[ -n "$ticket" ]] || continue
    if (( selected >= cap )); then break; fi
    if [[ -n "$TOTAL_LIMIT" ]] && (( total_selected >= TOTAL_LIMIT )); then break; fi
    agent=${agent_hint:-${PORTFOLIO_DEFAULT_AGENT:-claude}}
    prompt_file="$BRIEF_STAGING_DIR/dispatch-${agent}-${ticket}.md"
    status="ready"
    detail=""
    if [[ ! -f "$prompt_file" ]]; then
      status="brief_missing"
      detail="prompt=$prompt_file"
    fi
    portfolio_rows+=("$project	$agent	$ticket	$project_cfg	prompt=$prompt_file status=$status signals=$signals $detail")
    if [[ "$status" == "ready" ]]; then
      selected=$((selected + 1))
      total_selected=$((total_selected + 1))
    fi
  done < <(jq -r '
    .[]
    | select(.status == "ready")
    | select(((.local_assigned // false) | not))
    | select(((.conflict_with // []) | length) == 0)
    | [
        (.issue | tostring),
        (.agent_hint // ""),
        ((.signals // []) | join(","))
      ]
    | @tsv
  ' <<<"$plan_json" 2>/dev/null || true)

  project_counts[$project]=$selected
done < <(portfolio_project_entries)

emit_plan_tsv() {
  printf 'project\tagent\tticket\tproject_config\tdetail\n'
  local row
  for row in "${portfolio_rows[@]:-}"; do
    [[ -n "$row" ]] || continue
    printf '%s\n' "$row"
  done
  if [[ "${#portfolio_blockers[@]}" -gt 0 ]]; then
    local blocker
    for blocker in "${portfolio_blockers[@]}"; do
      printf '#blocker\t%s\n' "$blocker"
    done
  fi
}

emit_plan_json() {
  local row project agent ticket cfg detail
  local -a project_list=()
  local seen=""
  for row in "${portfolio_rows[@]:-}"; do
    [[ -n "$row" ]] || continue
    IFS=$'\t' read -r project agent ticket cfg detail <<<"$row"
    case ",$seen," in
      *",$project,"*) ;;
      *) project_list+=("$project"); seen="$seen,$project" ;;
    esac
  done
  {
    printf '{\n  "wave_id": %s,\n' "$(jq -nR --arg v "$WAVE_ID" '$v')"
    printf '  "portfolio_config": %s,\n' "$(jq -nR --arg v "$PORTFOLIO_ARG" '$v')"
    printf '  "projects": {\n'
    local first_project=1 project_key
    for project_key in "${project_list[@]:-}"; do
      if (( first_project == 0 )); then printf ',\n'; fi
      first_project=0
      printf '    %s: {\n' "$(jq -nR --arg v "$project_key" '$v')"
      printf '      "max_concurrent": %s,\n' "${project_caps[$project_key]:-0}"
      printf '      "selected": %s,\n' "${project_counts[$project_key]:-0}"
      printf '      "rows": [\n'
      local first_row=1
      for row in "${portfolio_rows[@]:-}"; do
        IFS=$'\t' read -r project agent ticket cfg detail <<<"$row"
        [[ "$project" == "$project_key" ]] || continue
        if (( first_row == 0 )); then printf ',\n'; fi
        first_row=0
        jq -nc \
          --arg agent "$agent" \
          --arg ticket "$ticket" \
          --arg cfg "$cfg" \
          --arg detail "$detail" \
          '{agent:$agent, ticket:$ticket, project_config:$cfg, detail:$detail}' \
          | sed 's/^/        /'
      done
      printf '\n      ]\n    }'
    done
    printf '\n  },\n'
    printf '  "blockers": '
    if [[ "${#portfolio_blockers[@]}" -gt 0 ]]; then
      printf '%s\n' "$(printf '%s\n' "${portfolio_blockers[@]}" | jq -R . | jq -s .)"
    else
      printf '[]\n'
    fi
    printf '}\n'
  }
}

if [[ -n "$MATRIX_OUT" ]]; then
  matrix_path="$MATRIX_OUT"
else
  matrix_path=$(mktemp)
fi

{
  printf '# portfolio_dispatch wave=%s portfolio=%s\n' "$WAVE_ID" "$PORTFOLIO_ARG"
  for row in "${portfolio_rows[@]:-}"; do
    [[ -n "$row" ]] || continue
    IFS=$'\t' read -r project agent ticket cfg detail <<<"$row"
    case "$detail" in
      *status=ready*)
        prompt_path=${detail#*prompt=}
        prompt_path=${prompt_path%% *}
        printf '%s\t%s\t%s\t%s\n' "$agent" "$ticket" "$prompt_path" "$cfg"
        ;;
    esac
  done
} > "$matrix_path"

if [[ "$EMIT_JSON" -eq 1 ]]; then
  emit_plan_json
else
  emit_plan_tsv
fi
printf 'matrix=%s\n' "$matrix_path" >&2

if [[ "$APPLY" -ne 1 ]]; then
  exit 0
fi

if ! grep -q '^[^#]' "$matrix_path" 2>/dev/null; then
  emit_warn "no ready rows to dispatch — matrix is empty (wave=$WAVE_ID)"
  exit 0
fi

dispatch_wave_args=("$WAVE_ID" "$matrix_path")
if dry_run_enabled; then
  dispatch_wave_args+=("--dry-run")
fi
bash "$DISPATCH_WAVE_BIN" "${dispatch_wave_args[@]}"
