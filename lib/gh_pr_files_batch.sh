#!/usr/bin/env bash
# lib/gh_pr_files_batch.sh - batched PR file retrieval (#293, #818).
#
# Replaces N per-PR file reads with ONE `ordo_provider pr_files_batch` call
# that returns the changed-files set for every requested PR (the github
# backend answers with one GraphQL round trip per chunk of
# GH_PR_FILES_BATCH_MAX_PRS numbers; the REST backends read each pr once).
# Intended for hotspot preflights (#271 / PR #288) and any other multi-PR
# scan that would otherwise scale linearly with open PR count and tip
# rate-limited installations into throttling.
#
# Public API:
#   gh_pr_files_batch_fetch <repo> <pr#> [<pr#> ...]
#     Emits TSV lines `<pr_number>\t<path>` on stdout, sorted by PR
#     number then path. Returns 0 on success (including empty input).
#     Returns 1 on provider or jq failure with a single-line
#     `gh_pr_files_batch: <error>` on stderr so the caller can fall back
#     to the per-PR loop. Returns 2 on argument-validation error.
#
# Env knobs (caller-tunable, all optional):
#   GH_CONFIG_DIR              profile dir of the forge CLI; inherited.
#   GH_PR_FILES_BATCH_LIMIT    max files per PR (default 100).
#   GH_PR_FILES_BATCH_MAX_PRS  max PRs per batch call (default 25);
#                              larger inputs are auto-chunked.
#   GH_PR_FILES_BATCH_TIMEOUT  seconds for each provider call (default 15).
#
# Compatibility fallback (issue #293, "retain current path as fallback"):
#
#   if files=$(gh_pr_files_batch_fetch "$repo" "${prs[@]}"); then
#     printf '%s\n' "$files"
#   else
#     for n in "${prs[@]}"; do
#       ordo_provider pr_files "$n" --repo "$repo" \
#         | jq -r --argjson n "$n" '.files[] | "\($n)\t\(.path)"'
#     done
#   fi

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
  _gh_pr_files_batch_split_repo "$repo" >/dev/null || return 2

  local limit=${GH_PR_FILES_BATCH_LIMIT}
  local max=${GH_PR_FILES_BATCH_MAX_PRS}
  [[ "$limit" =~ ^[0-9]+$ ]] && [ "$limit" -gt 0 ] || limit=100
  [[ "$max"   =~ ^[0-9]+$ ]] && [ "$max"   -gt 0 ] || max=25

  local numbers out err
  numbers=$(printf '%s,' "$@")
  numbers=${numbers%,}
  err=$(mktemp)
  if ! out=$(ORDO_PROVIDER_BATCH_FILES_LIMIT="$limit" ORDO_PROVIDER_BATCH_MAX_PRS="$max" \
             ORDO_PROVIDER_TIMEOUT_SEC="$GH_PR_FILES_BATCH_TIMEOUT" \
             ordo_provider pr_files_batch "$numbers" --repo "$repo" 2> "$err"); then
    local msg
    msg=$(jq -r '.error.message // empty' "$err" 2>/dev/null | head -c 400 | tr '\n' ' ')
    [ -n "$msg" ] || msg=$(head -c 400 "$err" 2>/dev/null | tr '\n' ' ')
    rm -f "$err"
    printf 'gh_pr_files_batch: provider pr_files_batch failed (prs=%s): %s\n' "$*" "${msg:-unknown error}" >&2
    return 1
  fi
  rm -f "$err"

  local jq_out jq_err_file
  jq_err_file=$(mktemp)
  if ! jq_out=$(printf '%s' "$out" | jq -r '.items[]? | .number as $n | (.files // [])[] | "\($n)\t\(.path)"' 2> "$jq_err_file"); then
    local jq_err
    jq_err=$(head -c 400 "$jq_err_file" 2>/dev/null | tr '\n' ' ')
    rm -f "$jq_err_file"
    printf 'gh_pr_files_batch: jq parse failed: %s\n' "$jq_err" >&2
    return 1
  fi
  rm -f "$jq_err_file"

  if [ -n "$jq_out" ]; then
    printf '%s\n' "$jq_out" | sort -t "$(printf '\t')" -k1,1n -k2,2
  fi
}
