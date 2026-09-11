#!/usr/bin/env bash
# scripts/portfolio_repo_bind_plan.sh - non-mutating repo/project binding planner.
#
# Usage:
#   portfolio_repo_bind_plan.sh <portfolio-config> [--json|--tsv]
#       [--candidate alias|owner/repo[|branch[|workdir-template]]]
#       [--candidate owner/repo]
#       [--discover-owner OWNER]
#
# This script never writes configs, clones repos, or moves agents. It only
# proposes project -> repository bindings that must be confirmed by the
# operator before portfolio_session_start.sh can create missing clones.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/portfolio_config.sh"
# Forge access goes through the provider adapter (#818): owner discovery is
# `ordo_provider repo_list`, whatever the forge.
# shellcheck source=lib/ordo_provider_adapter.sh
source "$TK/lib/ordo_provider_adapter.sh"

PORTFOLIO_ARG=${1:?usage: portfolio_repo_bind_plan.sh <portfolio-config> [--json|--tsv] [--candidate ...] [--discover-owner OWNER]}
FORMAT="tsv"
shift

CLI_CANDIDATES=()
CLI_DISCOVERY_OWNERS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json)
      FORMAT="json"
      shift
      ;;
    --tsv)
      FORMAT="tsv"
      shift
      ;;
    --candidate)
      CLI_CANDIDATES+=("${2:?missing value for --candidate}")
      shift 2
      ;;
    --discover-owner)
      CLI_DISCOVERY_OWNERS+=("${2:?missing value for --discover-owner}")
      shift 2
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

load_portfolio_config "$PORTFOLIO_ARG"

: "${PORTFOLIO_REPO_DISCOVERY_LIMIT:=100}"

normalize() {
  tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+//g'
}

score_candidate() {
  local alias=$1 repo=$2 description=${3:-} explicit_alias=${4:-}
  local alias_norm repo_name repo_norm desc_norm explicit_norm
  alias_norm=$(printf '%s' "$alias" | normalize)
  repo_name=${repo##*/}
  repo_norm=$(printf '%s' "$repo_name" | normalize)
  desc_norm=$(printf '%s' "$description" | normalize)
  explicit_norm=$(printf '%s' "$explicit_alias" | normalize)

  if [[ -n "$explicit_norm" ]]; then
    if [[ "$explicit_norm" == "$alias_norm" ]]; then
      printf '100\n'
    else
      printf '0\n'
    fi
    return 0
  fi

  if [[ "$repo_norm" == "$alias_norm" ]]; then
    printf '95\n'
  elif [[ "$repo_norm" == *"$alias_norm"* || "$alias_norm" == *"$repo_norm"* ]]; then
    printf '75\n'
  elif [[ -n "$desc_norm" && "$desc_norm" == *"$alias_norm"* ]]; then
    printf '50\n'
  else
    printf '0\n'
  fi
}

# run_provider <op> [args]: ordo_provider with the portfolio's profile dir.
run_provider() {
  if [[ -n "${PORTFOLIO_GH_CONFIG_DIR:-}" ]]; then
    GH_CONFIG_DIR="$PORTFOLIO_GH_CONFIG_DIR" ordo_provider "$@"
  else
    ordo_provider "$@"
  fi
}

project_config_json() {
  local alias=${1:?usage: project_config_json <alias> <config>}
  local cfg=${2:?usage: project_config_json <alias> <config>}
  bash -c '
    set -euo pipefail
    alias=$1
    cfg=$2
    # shellcheck disable=SC1090
    source "$cfg"
    jq -nc \
      --arg alias "$alias" \
      --arg config "$cfg" \
      --arg project "${PROJECT:-$alias}" \
      --arg gh_repo "${GH_REPO:-}" \
      --arg default_branch "${DEFAULT_BRANCH:-main}" \
      --arg workdir_template "${AGENT_WORKDIR_TEMPLATE:-}" \
      --arg repo_prefix "${AGENT_REPO_PREFIX:-}" \
      "{
        alias:\$alias,
        config:\$config,
        project:\$project,
        gh_repo:\$gh_repo,
        default_branch:\$default_branch,
        workdir_template:\$workdir_template,
        repo_prefix:\$repo_prefix
      }"
  ' _ "$alias" "$cfg"
}

candidate_json() {
  local entry=${1:?usage: candidate_json <entry> <source>}
  local source=${2:?usage: candidate_json <entry> <source>}
  local alias="" repo="" branch="" template="" extra=""

  if [[ "$entry" == *"|"* ]]; then
    IFS='|' read -r alias repo branch template extra <<< "$entry"
  else
    repo=$entry
  fi
  if [[ -n "$extra" || -z "$repo" ]]; then
    printf 'candidate malformed (need owner/repo or alias|owner/repo[|branch[|workdir-template]]): %s\n' "$entry" >&2
    return 2
  fi
  jq -nc \
    --arg alias "$alias" \
    --arg repo "$repo" \
    --arg branch "$branch" \
    --arg template "$template" \
    --arg source "$source" \
    --arg description "" \
    "{
      explicit_alias:\$alias,
      repo:\$repo,
      default_branch:\$branch,
      workdir_template:\$template,
      source:\$source,
      description:\$description,
      url:(if \$repo == \"\" then \"\" else \"https://github.com/\" + \$repo end)
    }"
}

discovered_candidates_json() {
  local owner=$1
  # ordo_provider repo_list (#818): the owner's repositories on the forge.
  run_provider repo_list --owner "$owner" --limit "$PORTFOLIO_REPO_DISCOVERY_LIMIT" 2>/dev/null \
    | jq -c '.items[]? | {
        explicit_alias:"",
        repo:.full_name,
        default_branch:(.default_branch // ""),
        workdir_template:"",
        source:"discovered",
        description:(.description // ""),
        url:(.url // "")
      }'
}

projects_file=$(mktemp)
candidates_file=$(mktemp)
rows_file=$(mktemp)
cleanup() {
  rm -f "$projects_file" "$candidates_file" "$rows_file"
}
trap cleanup EXIT

while IFS='|' read -r alias cfg; do
  project_config_json "$alias" "$cfg" >> "$projects_file"
done < <(portfolio_project_entries)

if [[ -n "${PORTFOLIO_REPO_CANDIDATES+x}" && "${#PORTFOLIO_REPO_CANDIDATES[@]}" -gt 0 ]]; then
  for entry in "${PORTFOLIO_REPO_CANDIDATES[@]}"; do
    candidate_json "$entry" "user_config" >> "$candidates_file"
  done
fi
if [ "${#CLI_CANDIDATES[@]}" -gt 0 ]; then
  for entry in "${CLI_CANDIDATES[@]}"; do
    candidate_json "$entry" "user_cli" >> "$candidates_file"
  done
fi

if [[ -n "${PORTFOLIO_DISCOVERY_OWNERS+x}" && "${#PORTFOLIO_DISCOVERY_OWNERS[@]}" -gt 0 ]]; then
  for owner in "${PORTFOLIO_DISCOVERY_OWNERS[@]}"; do
    discovered_candidates_json "$owner" >> "$candidates_file"
  done
fi
if [ "${#CLI_DISCOVERY_OWNERS[@]}" -gt 0 ]; then
  for owner in "${CLI_DISCOVERY_OWNERS[@]}"; do
    discovered_candidates_json "$owner" >> "$candidates_file"
  done
fi

while IFS= read -r project_json; do
  alias=$(printf '%s' "$project_json" | jq -r '.alias')
  project=$(printf '%s' "$project_json" | jq -r '.project')
  cfg=$(printf '%s' "$project_json" | jq -r '.config')
  existing_repo=$(printf '%s' "$project_json" | jq -r '.gh_repo')
  existing_branch=$(printf '%s' "$project_json" | jq -r '.default_branch')
  existing_template=$(printf '%s' "$project_json" | jq -r '.workdir_template')
  existing_prefix=$(printf '%s' "$project_json" | jq -r '.repo_prefix')

  if [[ -n "$existing_repo" ]]; then
    jq -nc \
      --arg alias "$alias" \
      --arg project "$project" \
      --arg config "$cfg" \
      --arg repo "$existing_repo" \
      --arg branch "$existing_branch" \
      --arg template "$existing_template" \
      --arg prefix "$existing_prefix" \
      '{
        alias:$alias,
        project:$project,
        config:$config,
        status:"confirmed_existing",
        confirmation_required:false,
        source:"project_config",
        score:100,
        existing_repo:$repo,
        candidate_repo:$repo,
        default_branch:$branch,
        workdir_template:$template,
        repo_prefix:$prefix,
        config_snippet:null
      }' >> "$rows_file"
  fi

  matched=0
  if [[ -s "$candidates_file" ]]; then
    while IFS= read -r candidate; do
      candidate_repo=$(printf '%s' "$candidate" | jq -r '.repo')
      candidate_alias=$(printf '%s' "$candidate" | jq -r '.explicit_alias')
      candidate_desc=$(printf '%s' "$candidate" | jq -r '.description')
      candidate_branch=$(printf '%s' "$candidate" | jq -r '.default_branch')
      candidate_template=$(printf '%s' "$candidate" | jq -r '.workdir_template')
      candidate_source=$(printf '%s' "$candidate" | jq -r '.source')
      if [[ -n "$existing_repo" ]]; then
        existing_norm=$(printf '%s' "$existing_repo" | normalize)
        candidate_norm=$(printf '%s' "$candidate_repo" | normalize)
        if [[ "$existing_norm" == "$candidate_norm" ]]; then
          continue
        fi
      fi
      score=$(score_candidate "$alias" "$candidate_repo" "$candidate_desc" "$candidate_alias")
      if [[ "$score" -le 0 ]]; then
        continue
      fi
      matched=1
      [[ -n "$candidate_branch" ]] || candidate_branch="$existing_branch"
      snippet=$(printf 'PROJECT=%q\nGH_REPO=%q\nDEFAULT_BRANCH=%q\n' \
        "$project" "$candidate_repo" "$candidate_branch")
      if [[ -n "$candidate_template" ]]; then
        snippet+=$(printf 'export AGENT_WORKDIR_TEMPLATE=%q\n' "$candidate_template")
      fi
      jq -nc \
        --arg alias "$alias" \
        --arg project "$project" \
        --arg config "$cfg" \
        --arg source "$candidate_source" \
        --arg existing_repo "$existing_repo" \
        --arg candidate_repo "$candidate_repo" \
        --arg branch "$candidate_branch" \
        --arg template "$candidate_template" \
        --arg snippet "$snippet" \
        --argjson score "$score" \
        '{
          alias:$alias,
          project:$project,
          config:$config,
          status:"needs_confirmation",
          confirmation_required:true,
          source:$source,
          score:$score,
          existing_repo:$existing_repo,
          candidate_repo:$candidate_repo,
          default_branch:$branch,
          workdir_template:$template,
          repo_prefix:"",
          config_snippet:$snippet
        }' >> "$rows_file"
    done < "$candidates_file"
  fi

  if [[ -z "$existing_repo" && "$matched" -eq 0 ]]; then
    jq -nc \
      --arg alias "$alias" \
      --arg project "$project" \
      --arg config "$cfg" \
      '{
        alias:$alias,
        project:$project,
        config:$config,
        status:"unbound_no_candidate",
        confirmation_required:true,
        source:"none",
        score:0,
        existing_repo:"",
        candidate_repo:"",
        default_branch:"",
        workdir_template:"",
        repo_prefix:"",
        config_snippet:null
      }' >> "$rows_file"
  fi
done < "$projects_file"

json_report=$(jq -s 'sort_by(.alias, -(.score), .candidate_repo)' "$rows_file")

if [[ "$FORMAT" == "json" ]]; then
  printf '%s\n' "$json_report"
else
  printf 'alias\tproject\tstatus\tconfirmation_required\tsource\tscore\texisting_repo\tcandidate_repo\tdefault_branch\tworkdir_template\tconfig_snippet\n'
  printf '%s\n' "$json_report" | jq -r '.[] | [
    .alias,
    .project,
    .status,
    .confirmation_required,
    .source,
    .score,
    .existing_repo,
    .candidate_repo,
    .default_branch,
    .workdir_template,
    (.config_snippet // "")
  ] | @tsv'
fi
