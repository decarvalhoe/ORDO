#!/usr/bin/env bash
# lib/gh_pr_files_batch.sh - batched GitHub PR file retrieval (#293).
#
# Replaces N `gh pr view <n> --json files` calls with a single
# `gh api graphql` query that returns the changed-files set for every
# requested PR in one round trip. Intended for hotspot preflights (#271 /
# PR #288) and any other multi-PR scan that would otherwise scale
# linearly with open PR count and tip rate-limited GitHub installations
# into throttling.
#
# Public API:
#   gh_pr_files_batch_fetch <repo> <pr#> [<pr#> ...]
#     Emits TSV lines `<pr_number>\t<path>` on stdout, sorted by PR
#     number then path. Returns 0 on success (including empty input).
#     Returns 1 on GraphQL or jq failure with a single-line
#     `gh_pr_files_batch: <error>` on stderr so the caller can fall back
#     to the per-PR loop. Returns 2 on argument-validation error.
#
# Env knobs (caller-tunable, all optional):
#   GH_CONFIG_DIR              required by gh; inherited from the caller.
#   GH_PR_FILES_BATCH_LIMIT    max files per PR (default 100, the
#                              GraphQL `first:` cap).
#   GH_PR_FILES_BATCH_MAX_PRS  max PRs per batch call (default 25);
#                              larger inputs are auto-chunked into
#                              multiple GraphQL calls.
#   GH_PR_FILES_BATCH_TIMEOUT  seconds for each gh api graphql call
#                              (default 15). Wrapped via
#                              `orch_run_timeout` when
#                              `lib/process_safety.sh` is sourced.
#
# Compatibility fallback (issue #293, "retain current path as fallback"):
#
#   if files=$(gh_pr_files_batch_fetch "$repo" "${prs[@]}"); then
#     printf '%s\n' "$files"
#   else
#     for n in "${prs[@]}"; do
#       gh pr view "$n" --repo "$repo" --json files \
#         | jq -r --argjson n "$n" '.files[] | "\($n)\t\(.path)"'
#     done
#   fi

# Forge access (#816): on every forge but GitHub, and when gh is absent, the
# files are read through the provider adapter (`ordo_provider pr_files`, one
# read per PR) with the same TSV output. On GitHub the batched GraphQL call
# is kept because it is the whole point of this helper (#293: one round trip
# instead of N on rate-limited installations).
# TODO(#816): needs a batched read op (pr_files for several numbers) in the
# provider adapter — then drop the gh api graphql call below.

_GH_PR_FILES_BATCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ordo_provider_adapter.sh
source "$_GH_PR_FILES_BATCH_LIB_DIR/ordo_provider_adapter.sh"

: "${GH_PR_FILES_BATCH_LIMIT:=100}"
: "${GH_PR_FILES_BATCH_MAX_PRS:=25}"
: "${GH_PR_FILES_BATCH_TIMEOUT:=15}"

_gh_pr_files_batch_split_repo() {
  local repo=$1
  case "$repo" in
    */*) printf '%s\n' "$repo" ;;
    *)
      printf 'gh_pr_files_batch: invalid repo (expected owner/name): %s\n' "$repo" >&2
      return 2
      ;;
  esac
}

_gh_pr_files_batch_graphql_available() {
  [ "$(ordo_provider_adapter_name)" = "github" ] && command -v gh >/dev/null 2>&1
}

# _gh_pr_files_batch_fetch_via_provider <repo> <pr#>...
#   Forge-neutral path: one `pr_files` read per PR through the adapter.
_gh_pr_files_batch_fetch_via_provider() {
  local repo=$1
  shift
  local pr rows="" out err
  for pr in "$@"; do
    err=$(mktemp)
    if ! out=$(ordo_provider pr_files "$pr" --repo "$repo" 2> "$err"); then
      local msg
      msg=$(jq -r '.error.message // empty' "$err" 2>/dev/null | head -c 400 | tr '\n' ' ')
      rm -f "$err"
      printf 'gh_pr_files_batch: provider pr_files failed (pr=%s): %s\n' "$pr" "${msg:-unknown error}" >&2
      return 1
    fi
    rm -f "$err"
    rows+=$(printf '%s' "$out" | jq -r --argjson n "$pr" '.files[]? | "\($n)\t\(.path)"')$'\n'
  done
  rows=$(printf '%s' "$rows" | sed '/^$/d')
  if [ -n "$rows" ]; then
    printf '%s\n' "$rows" | sort -t "$(printf '\t')" -k1,1n -k2,2
  fi
}

_gh_pr_files_batch_run_gh() {
  # TODO(#816): direct gh call — the only GitHub-specific batched read left.
  if declare -F orch_run_timeout >/dev/null 2>&1; then
    orch_run_timeout "$GH_PR_FILES_BATCH_TIMEOUT" gh "$@"
  elif command -v timeout >/dev/null 2>&1; then
    timeout "$GH_PR_FILES_BATCH_TIMEOUT" gh "$@"
  else
    gh "$@"
  fi
}

_gh_pr_files_batch_emit_query() {
  local owner=$1 name=$2 limit=$3
  shift 3
  local pr aliases=""
  for pr in "$@"; do
    aliases+=$(printf '  pr_%s: pullRequest(number: %s) { number files(first: %s) { nodes { path } } }\n' \
      "$pr" "$pr" "$limit")
  done
  printf 'query {\n  repository(owner: "%s", name: "%s") {\n%s  }\n}\n' \
    "$owner" "$name" "$aliases"
}

gh_pr_files_batch_fetch() {
  local repo=${1:?usage: gh_pr_files_batch_fetch <repo> <pr#> [<pr#> ...]}
  shift
  if [ "$#" -eq 0 ]; then
    return 0
  fi
  local pr
  for pr in "$@"; do
    if ! [[ "$pr" =~ ^[0-9]+$ ]]; then
      printf 'gh_pr_files_batch: invalid PR number: %s\n' "$pr" >&2
      return 2
    fi
  done

  local owner_repo
  owner_repo=$(_gh_pr_files_batch_split_repo "$repo") || return 2
  local owner=${owner_repo%%/*}
  local name=${owner_repo#*/}

  if ! _gh_pr_files_batch_graphql_available; then
    _gh_pr_files_batch_fetch_via_provider "$repo" "$@"
    return $?
  fi

  local response_dir tmp_query
  response_dir=$(mktemp -d)
  tmp_query=$(mktemp)
  # shellcheck disable=SC2064 # expand response_dir/tmp_query at trap-set time.
  trap "rm -rf '$response_dir' '$tmp_query'" RETURN

  local limit=${GH_PR_FILES_BATCH_LIMIT}
  local max=${GH_PR_FILES_BATCH_MAX_PRS}
  [[ "$limit" =~ ^[0-9]+$ ]] && [ "$limit" -gt 0 ] || limit=100
  [[ "$max"   =~ ^[0-9]+$ ]] && [ "$max"   -gt 0 ] || max=25

  local -a chunk=()
  local idx=0
  local err_payload
  flush_chunk() {
    if [ "${#chunk[@]}" -eq 0 ]; then
      return 0
    fi
    _gh_pr_files_batch_emit_query "$owner" "$name" "$limit" "${chunk[@]}" > "$tmp_query"
    local response_file="$response_dir/r_${idx}.json"
    local err_file="$response_dir/err_${idx}.txt"
    if ! _gh_pr_files_batch_run_gh api graphql -f query=@"$tmp_query" \
         > "$response_file" 2> "$err_file"; then
      err_payload=$(head -c 400 "$err_file" 2>/dev/null | tr '\n' ' ')
      printf 'gh_pr_files_batch: gh api graphql failed (chunk=%s prs=%s): %s\n' \
        "$idx" "${chunk[*]}" "$err_payload" >&2
      return 1
    fi
    idx=$((idx + 1))
    chunk=()
  }

  for pr in "$@"; do
    chunk+=("$pr")
    if [ "${#chunk[@]}" -ge "$max" ]; then
      flush_chunk || return 1
    fi
  done
  flush_chunk || return 1

  local jq_out jq_err
  if ! jq_out=$(jq -r '
    .data.repository
    | to_entries[]
    | select(.value != null)
    | .value as $pr
    | ($pr.files.nodes // [])[]
    | "\($pr.number)\t\(.path)"
  ' "$response_dir"/r_*.json 2> "$response_dir/jq_err.txt"); then
    jq_err=$(head -c 400 "$response_dir/jq_err.txt" 2>/dev/null | tr '\n' ' ')
    printf 'gh_pr_files_batch: jq parse failed: %s\n' "$jq_err" >&2
    return 1
  fi

  if [ -n "$jq_out" ]; then
    printf '%s\n' "$jq_out" | sort -t "$(printf '\t')" -k1,1n -k2,2
  fi
}
