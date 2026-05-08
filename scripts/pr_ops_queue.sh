#!/usr/bin/env bash
# scripts/pr_ops_queue.sh — derive a portfolio PR operations queue from
# live blockers (#358, parent epic #357). Read-only: never mutates a PR,
# never sends keys.
#
# Three input modes (exactly one required):
#
#   --portfolio <portfolio-config>
#     Walk every project in the portfolio. For each project, run
#     scripts/pr_block_signals.sh --json and classify every PR.
#
#   --project <project-config>
#     Single-project mode. Same classifier, no portfolio iteration.
#
#   --input <file>
#     Offline mode. Read a JSON snapshot of pr_block_signals output.
#     Two snapshot shapes are accepted:
#       - flat array: an array of PR records produced by
#         pr_block_signals.sh --json. Project metadata must be supplied
#         via --project-meta or --project-meta-file.
#       - portfolio-grouped: an object array
#         [{"alias":"...","project_meta":{...},"prs":[...]}, ...]
#     Use "-" to read from stdin.
#
# Output (default --json): a single JSON array of candidate records,
# sorted by priority (high first) then last_update_age_sec (oldest
# first), then PR number ascending. Schema: `ordo.pr_ops_queue.v1`
# (documented in docs/orchestrator-injected-rules.md).
#
# Stale-cache refusal: when --input is used, the snapshot file's mtime
# is compared against PR_OPS_QUEUE_MAX_AGE_SEC (default 300). A snapshot
# older than that exits 4 with `pr_ops_queue_stale: ...` on stderr,
# unless --allow-stale is passed.
#
# Project policy: each candidate carries a `project_policy` field. The
# default is `observe`; a project profile can override by exporting
# PR_OPS_QUEUE_POLICY (or by setting the `policy` key in the
# project_meta JSON). The classifier never enforces the policy — it
# only records it for the future #357 mode dispatcher.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=lib/pr_ops_queue.sh
source "$TK/lib/pr_ops_queue.sh"
# shellcheck source=lib/portfolio_config.sh
source "$TK/lib/portfolio_config.sh"

usage() {
  cat <<'EOF' >&2
usage:
  pr_ops_queue.sh --portfolio <portfolio-config> [--allow-stale] [--json]
  pr_ops_queue.sh --project   <project-config>   [--allow-stale] [--json]
  pr_ops_queue.sh --input     <file|->           --project-meta <json>|--project-meta-file <file>
                                                 [--max-age-sec N] [--allow-stale] [--json]

Read-only PR operations queue classifier (#358). Output is a JSON array
of candidate records on stdout (default --json) or a TSV summary with
--tsv.
EOF
}

PORTFOLIO_ARG=""
PROJECT_ARG=""
INPUT_ARG=""
PROJECT_META_INLINE=""
PROJECT_META_FILE=""
ALLOW_STALE=0
FORMAT="json"
MAX_AGE_SEC=${PR_OPS_QUEUE_MAX_AGE_SEC:-300}

if ! command -v jq >/dev/null 2>&1; then
  printf 'pr_ops_queue.sh: jq is required\n' >&2
  exit 3
fi

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --portfolio) PORTFOLIO_ARG=${2:?missing value for --portfolio}; shift 2 ;;
    --portfolio=*) PORTFOLIO_ARG=${1#--portfolio=}; shift ;;
    --project) PROJECT_ARG=${2:?missing value for --project}; shift 2 ;;
    --project=*) PROJECT_ARG=${1#--project=}; shift ;;
    --input) INPUT_ARG=${2:?missing value for --input}; shift 2 ;;
    --input=*) INPUT_ARG=${1#--input=}; shift ;;
    --project-meta) PROJECT_META_INLINE=${2:?missing value for --project-meta}; shift 2 ;;
    --project-meta=*) PROJECT_META_INLINE=${1#--project-meta=}; shift ;;
    --project-meta-file) PROJECT_META_FILE=${2:?missing value for --project-meta-file}; shift 2 ;;
    --project-meta-file=*) PROJECT_META_FILE=${1#--project-meta-file=}; shift ;;
    --max-age-sec) MAX_AGE_SEC=${2:?missing value for --max-age-sec}; shift 2 ;;
    --max-age-sec=*) MAX_AGE_SEC=${1#--max-age-sec=}; shift ;;
    --allow-stale) ALLOW_STALE=1; shift ;;
    --json) FORMAT="json"; shift ;;
    --tsv) FORMAT="tsv"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'pr_ops_queue.sh: unknown arg: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
done

mode_count=0
[[ -n "$PORTFOLIO_ARG" ]] && mode_count=$((mode_count + 1))
[[ -n "$PROJECT_ARG"   ]] && mode_count=$((mode_count + 1))
[[ -n "$INPUT_ARG"     ]] && mode_count=$((mode_count + 1))
if [[ "$mode_count" -ne 1 ]]; then
  printf 'pr_ops_queue.sh: exactly one of --portfolio / --project / --input is required\n' >&2
  usage
  exit 2
fi

GENERATED_AT=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

# Build a project_meta JSON object from a project config path. Sources
# the config in a subshell to avoid leaking variables into the parent
# shell.
project_meta_from_config() {
  local cfg=${1:?usage: project_meta_from_config <config-path>}
  local alias_in=${2:-}
  local resolved
  resolved=$(bash -c '
    set -euo pipefail
    cfg=$1
    # shellcheck disable=SC1090
    source "$cfg"
    jq -nc \
      --arg project "${PROJECT:-}" \
      --arg repo "${GH_REPO:-}" \
      --arg default_branch "${DEFAULT_BRANCH:-main}" \
      --arg config "$cfg" \
      --arg policy "${PR_OPS_QUEUE_POLICY:-observe}" \
      "{project:\$project,repo:\$repo,default_branch:\$default_branch,config:\$config,policy:\$policy}"
  ' _ "$cfg")
  jq -c --arg alias "$alias_in" '. + {alias: ($alias | if . == "" then (.project // "") else . end)}' <<< "$resolved"
}

# Run pr_block_signals.sh for one project config and return its JSON.
run_pr_block_signals() {
  local cfg=${1:?usage: run_pr_block_signals <config>}
  bash "$TK/scripts/pr_block_signals.sh" "$cfg" --json 2>/dev/null
}

# Read a file or stdin.
read_input_source() {
  local source=$1
  if [[ "$source" == "-" ]]; then
    cat
  else
    [[ -e "$source" ]] || {
      printf 'pr_ops_queue.sh: input not found: %s\n' "$source" >&2
      exit 2
    }
    cat -- "$source"
  fi
}

# Stale-cache check for --input mode. Live modes (--portfolio,
# --project) read fresh data from gh and never trip the staleness
# refusal.
check_input_freshness() {
  local source=$1
  [[ "$source" != "-" ]] || return 0  # stdin has no mtime
  local now mtime age
  now=$(date +%s)
  if mtime=$(stat -c %Y "$source" 2>/dev/null) \
    || mtime=$(stat -f %m "$source" 2>/dev/null); then
    age=$((now - mtime))
    if (( age > MAX_AGE_SEC )); then
      if [[ "$ALLOW_STALE" -eq 1 ]]; then
        printf 'pr_ops_queue_stale_warn: input=%s age_sec=%s max_age_sec=%s allowed_via=--allow-stale\n' \
          "$source" "$age" "$MAX_AGE_SEC" >&2
      else
        printf 'pr_ops_queue_stale: input=%s age_sec=%s max_age_sec=%s; pass --allow-stale or refresh the snapshot\n' \
          "$source" "$age" "$MAX_AGE_SEC" >&2
        exit 4
      fi
    fi
  fi
}

# Classify every PR record in a JSON array against a single project
# meta object. Emits one JSON line per PR.
classify_array() {
  local prs_json=$1
  local project_meta=$2
  local count
  count=$(jq -r 'length' <<< "$prs_json")
  local i=0
  while [[ "$i" -lt "$count" ]]; do
    local record
    record=$(jq -c --argjson i "$i" '.[$i]' <<< "$prs_json")
    pr_ops_queue_classify "$record" "$project_meta" "$GENERATED_AT" || return 1
    i=$((i + 1))
  done
}

ALL_RECORDS=()

if [[ -n "$PORTFOLIO_ARG" ]]; then
  load_portfolio_config "$PORTFOLIO_ARG"
  while IFS='|' read -r alias cfg; do
    [[ -n "$alias" && -n "$cfg" ]] || continue
    project_meta=$(project_meta_from_config "$cfg" "$alias")
    prs_json=$(run_pr_block_signals "$cfg" || printf '[]')
    if ! jq -e 'type == "array"' <<< "$prs_json" >/dev/null 2>&1; then
      prs_json='[]'
    fi
    while IFS= read -r record; do
      [[ -n "$record" ]] || continue
      ALL_RECORDS+=("$record")
    done < <(classify_array "$prs_json" "$project_meta")
  done < <(portfolio_project_entries)

elif [[ -n "$PROJECT_ARG" ]]; then
  project_meta=$(project_meta_from_config "$PROJECT_ARG" "")
  prs_json=$(run_pr_block_signals "$PROJECT_ARG" || printf '[]')
  if ! jq -e 'type == "array"' <<< "$prs_json" >/dev/null 2>&1; then
    prs_json='[]'
  fi
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    ALL_RECORDS+=("$record")
  done < <(classify_array "$prs_json" "$project_meta")

elif [[ -n "$INPUT_ARG" ]]; then
  check_input_freshness "$INPUT_ARG"
  raw=$(read_input_source "$INPUT_ARG")
  # Detect snapshot shape.
  if jq -e 'type == "array" and (length == 0 or (.[0] | type == "object" and has("prs")))' \
      >/dev/null 2>&1 <<< "$raw"; then
    # Portfolio-grouped snapshot.
    bundle_count=$(jq -r 'length' <<< "$raw")
    j=0
    while [[ "$j" -lt "$bundle_count" ]]; do
      bundle=$(jq -c --argjson j "$j" '.[$j]' <<< "$raw")
      prs=$(jq -c '.prs // []' <<< "$bundle")
      project_meta=$(jq -c '.project_meta // {}' <<< "$bundle")
      while IFS= read -r record; do
        [[ -n "$record" ]] || continue
        ALL_RECORDS+=("$record")
      done < <(classify_array "$prs" "$project_meta")
      j=$((j + 1))
    done
  else
    # Flat array shape — caller must supply project meta.
    if [[ -n "$PROJECT_META_FILE" ]]; then
      project_meta=$(cat -- "$PROJECT_META_FILE")
    elif [[ -n "$PROJECT_META_INLINE" ]]; then
      project_meta=$PROJECT_META_INLINE
    else
      printf 'pr_ops_queue.sh: --input flat-array shape requires --project-meta or --project-meta-file\n' >&2
      exit 2
    fi
    if ! jq -e 'type == "object"' <<< "$project_meta" >/dev/null 2>&1; then
      printf 'pr_ops_queue.sh: project_meta must be a JSON object\n' >&2
      exit 2
    fi
    while IFS= read -r record; do
      [[ -n "$record" ]] || continue
      ALL_RECORDS+=("$record")
    done < <(classify_array "$raw" "$project_meta")
  fi
fi

# Sort by priority desc, then last_update_age_sec desc (oldest first
# inside same priority), then pr asc.
SORTED=$(printf '%s\n' "${ALL_RECORDS[@]:-}" \
  | jq -s 'sort_by([-(.priority // 0), -((.last_update_age_sec // 0)), (.pr // 0)])')

if [[ "$FORMAT" == "json" ]]; then
  printf '%s\n' "$SORTED"
else
  printf 'alias\tproject\trepo\tpr\tcandidate\tpriority\tmergeable\tmerge_state\treview\tci_failed\tci_pending\tci_total\tbase_current\tdraft\tagent\tpolicy\tlast_update_age_sec\trationale\n'
  printf '%s\n' "$SORTED" | jq -r '
    .[] | [
      .alias, .project, .repo, .pr, .candidate, .priority,
      .mergeable, .merge_state, .review_decision,
      .ci_summary.failed, .ci_summary.pending, .ci_summary.total,
      .base_current, (.is_draft|tostring), (.agent // ""),
      .project_policy, (.last_update_age_sec // ""), .rationale
    ] | @tsv'
fi
