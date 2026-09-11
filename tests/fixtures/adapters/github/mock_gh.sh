#!/usr/bin/env bash
# tests/fixtures/adapters/github/mock_gh.sh — fake `gh` for the provider
# adapter tests (#811). Installed as `gh` on PATH by the bats suites.
#
# Serves the raw payload fixtures next to it, records every invocation
# (one line per call, args joined by spaces) into $GH_MOCK_LOG, and honours
# a failure injection file $GH_MOCK_FAIL_FILE whose first line is the exit
# code and remaining lines are the stderr text.
#
# Env: GH_MOCK_FIXTURES (dir, default: this file's dir), GH_MOCK_LOG,
#      GH_MOCK_FAIL_FILE, GH_MOCK_AUTH_FAIL=1 (auth status exits 1).
set -u
FIX="${GH_MOCK_FIXTURES:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
[[ -n "${GH_MOCK_LOG:-}" ]] && printf '%s\n' "$*" >> "$GH_MOCK_LOG"

if [[ -n "${GH_MOCK_FAIL_FILE:-}" && -f "$GH_MOCK_FAIL_FILE" ]]; then
  rc=$(head -n 1 "$GH_MOCK_FAIL_FILE")
  tail -n +2 "$GH_MOCK_FAIL_FILE" >&2
  exit "${rc:-1}"
fi

topic=${1:-}; action=${2:-}; shift 2 2>/dev/null || true
number="" limit="" state="" base="" branch="" json="" log_failed=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit) limit=$2; shift 2 ;;
    --state|--status) state=$2; shift 2 ;;
    --base) base=$2; shift 2 ;;
    --branch) branch=$2; shift 2 ;;
    --json) json=$2; shift 2 ;;
    --log-failed) log_failed=1; shift ;;
    --repo|-R|--label|--assignee|--author|--search|--milestone|--commit|--workflow|--head|--title|--body|--body-file|--reason|--comment|--add-label|--remove-label|--add-assignee|--remove-assignee) shift 2 ;;
    -*) shift ;;
    *) [[ -z "$number" ]] && number=$1; shift ;;
  esac
done

# Like gh, only the fields requested with --json are returned.
project() {
  jq -c --arg f "$json" '
    def pick: . as $o | if $f == "" then $o else ($f | split(",") | map({key: ., value: $o[.]}) | from_entries) end;
    if type == "array" then map(pick) else pick end'
}

serve_list() {
  local file=$1 st_field=${2:-state}
  jq -c --arg state "$state" --arg base "$base" --arg branch "$branch" --arg limit "${limit:-30}" --arg f "$st_field" '
    map(select(
      ($state == "" or $state == "all" or (.[$f] | ascii_downcase) == ($state | ascii_downcase))
      and ($base == "" or .baseRefName == $base)
      and ($branch == "" or .headBranch == $branch)))
    | .[:($limit | tonumber)]' "$file" | project
}

case "$topic $action" in
  "auth status")
    if [[ "${GH_MOCK_AUTH_FAIL:-0}" = 1 ]]; then
      printf 'You are not logged into any GitHub hosts. To log in, run: gh auth login\n' >&2
      exit 1
    fi
    cat "$FIX/auth_status.txt" ;;
  "repo view") project < "$FIX/repo_view.json" ;;
  "issue view")
    if [[ -f "$FIX/issue_view_${number}.json" ]]; then project < "$FIX/issue_view_${number}.json"
    else printf 'GraphQL: Could not resolve to an Issue with the number of %s. (repository.issue)\n' "$number" >&2; exit 1; fi ;;
  "issue list") serve_list "$FIX/issue_list.json" ;;
  "pr view")
    if [[ -f "$FIX/pr_view_${number}.json" ]]; then project < "$FIX/pr_view_${number}.json"
    else printf 'GraphQL: Could not resolve to a PullRequest with the number of %s. (repository.pullRequest)\n' "$number" >&2; exit 1; fi ;;
  "pr list") serve_list "$FIX/pr_list.json" ;;
  "run list") serve_list "$FIX/run_list.json" status ;;
  "run view")
    if [[ "$log_failed" -eq 1 ]]; then
      [[ -f "$FIX/run_log_failed_${number}.txt" ]] && cat "$FIX/run_log_failed_${number}.txt"; exit 0
    fi
    if [[ -f "$FIX/run_view_${number}.json" ]]; then project < "$FIX/run_view_${number}.json"
    else printf 'could not find any workflow run with id %s\n' "$number" >&2; exit 1; fi ;;
  "issue create") printf 'https://github.com/acme/widgets/issues/1001\n' ;;
  "issue comment") printf 'https://github.com/acme/widgets/issues/%s#issuecomment-99\n' "$number" ;;
  "issue edit") printf 'https://github.com/acme/widgets/issues/%s\n' "$number" ;;
  "issue close"|"issue reopen") printf '✓ Issue #%s\n' "$number" ;;
  "pr create") printf 'https://github.com/acme/widgets/pull/1002\n' ;;
  "pr edit") printf 'https://github.com/acme/widgets/pull/%s\n' "$number" ;;
  "pr ready"|"pr merge"|"pr review"|"pr close"|"pr reopen"|"pr comment") : ;;
  *) printf 'mock gh: unsupported invocation: %s %s\n' "$topic" "$action" >&2; exit 1 ;;
esac
