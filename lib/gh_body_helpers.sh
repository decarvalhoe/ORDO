#!/usr/bin/env bash
# lib/gh_body_helpers.sh — shell-safe markdown body helpers (issue/PR bodies).
#
# Doctrine:
#   - Markdown bodies must always reach the forge via a body FILE, never via
#     --body "$VAR". Bodies that contain backticks, $(...), single or
#     double quotes, or newlines round-trip incorrectly when they
#     traverse a shell argv level (variable expansion, eval-like
#     wrappers, multi-line concatenation, history expansion, etc.).
#   - Helpers in this file write the body to a per-call mktemp file
#     and hand it to the provider adapter as --body-file <path>. Callers
#     stream the body via stdin so it never participates in shell argv
#     parsing.
#   - This file is sourced. Do NOT execute it directly.
#
# Forge access (#816): the helpers keep their gh-flavoured argument shape
# (`issue comment <n> [--repo R]`, `issue create --title T [--label L]...`,
# `pr create --title T --head H [--base B]`, `pr comment <n>`, `pr review <n>
# --approve|--comment|--request-changes`) but execute through the provider
# adapter (lib/ordo_provider_adapter.sh): dedicated ops when one exists
# (issue_comment, issue_create, pr_create), the gated `mutate` escape hatch
# otherwise. Consequences, identical on every forge:
#   - the mutation is gated by ORCH_EXTERNAL_PR_MUTATIONS (audit-only by
#     default; a refusal exits 3 with a policy_refused error object);
#   - the mutation is idempotent: the key is ORDO_PROVIDER_IDEMPOTENCY_KEY
#     when set, else gh_body:<op>:<repo>#<subject>:<sha256(body)[0:16]> so a
#     retry of the same comment/body never posts twice;
#   - stdout is the created/commented URL (result.url) like gh printed it,
#     or the backend stdout for `mutate`.
#
# Public functions:
#   gh_body_write_tempfile [tag]
#     Read stdin, write to a fresh mktemp file, echo the path on
#     stdout. Optional [tag] sets the template prefix (default:
#     gh_body). Caller is responsible for removing the file when not
#     using gh_body_with_file.
#   gh_body_with_file <topic> <action> [args...]
#     Read body from stdin, run the matching provider op with
#     --body-file <tmp>, remove the tempfile, return the adapter's exit code.
#   gh_issue_comment_body_file <issue> [extra-args...]
#   gh_pr_comment_body_file <pr> [extra-args...]
#   gh_pr_review_body_file <pr> [extra-args...]
#   gh_issue_create_body_file [extra-args...]
#   gh_pr_create_body_file [extra-args...]
#     Convenience wrappers around gh_body_with_file.
#
# Configuration:
#   ORDO_PROVIDER_IDEMPOTENCY_KEY  explicit idempotency key for the next call
#   ORDO_PROVIDER_ADAPTER / ORDO_FORGE_REPO (GH_REPO)  see the adapter

set -o pipefail

_GH_BODY_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_GH_BODY_HELPERS_DIR/github_identity.sh" ]]; then
  # shellcheck source=lib/github_identity.sh
  source "$_GH_BODY_HELPERS_DIR/github_identity.sh"
fi

# The provider adapter is loaded on first use so that sourcing this file
# stays cheap for scripts that never post a body.
_gh_body_require_provider() {
  declare -F ordo_provider >/dev/null 2>&1 && return 0
  # shellcheck source=lib/ordo_provider_adapter.sh
  source "$_GH_BODY_HELPERS_DIR/ordo_provider_adapter.sh"
}

# _gh_body_key <op> <repo> <subject> <body-file>
_gh_body_key() {
  local op=${1:?} repo=${2:-} subject=${3:-} body_file=${4:?}
  if [[ -n "${ORDO_PROVIDER_IDEMPOTENCY_KEY:-}" ]]; then
    printf '%s\n' "$ORDO_PROVIDER_IDEMPOTENCY_KEY"
    return 0
  fi
  local digest
  digest=$(sha256sum < "$body_file" | cut -c1-16)
  printf 'gh_body:%s:%s#%s:%s\n' "$op" "${repo:-${ORDO_FORGE_REPO:-${GH_REPO:-}}}" "$subject" "$digest"
}

gh_body_write_tempfile() {
  local tag="${1:-gh_body}"
  local dir="${TMPDIR:-/tmp}"
  local f
  f=$(mktemp "${dir}/${tag}.XXXXXX") || return 1
  if ! cat > "$f"; then
    rm -f "$f"
    return 1
  fi
  printf '%s\n' "$f"
}

gh_body_with_file() {
  if [ "$#" -lt 2 ]; then
    printf 'gh_body_with_file: missing <topic> <action> args\n' >&2
    return 2
  fi
  if declare -F orch_github_identity_guard >/dev/null 2>&1; then
    orch_github_identity_guard "" "gh_body_with_file:${1:-gh}" || return $?
  fi
  _gh_body_require_provider || return 1
  local topic=$1 action=$2
  shift 2
  local body_file
  body_file=$(gh_body_write_tempfile "gh_body") || return 1

  # Parse the gh-shaped arguments once: number (first bare positional),
  # --repo, and the create-specific fields; everything is also kept verbatim
  # for the `mutate` passthrough.
  local number="" repo="" title="" head="" base="" milestone="" draft=0
  local -a labels=() assignees=() gh_body_native=("$@")
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo|-R) repo=${2:-}; shift 2 ;;
      --title) title=${2:-}; shift 2 ;;
      --head) head=${2:-}; shift 2 ;;
      --base) base=${2:-}; shift 2 ;;
      --milestone) milestone=${2:-}; shift 2 ;;
      --label) labels+=("${2:-}"); shift 2 ;;
      --assignee) assignees+=("${2:-}"); shift 2 ;;
      --draft) draft=1; shift ;;
      --body|--body-file) shift 2 ;;
      --*) shift ;;
      *) [ -n "$number" ] || number=$1; shift ;;
    esac
  done

  local -a op=()
  local op_name="" subject="" l
  case "$topic $action" in
    "issue comment")
      op_name=issue_comment; subject=$number
      op=(issue_comment "$number")
      ;;
    "issue create")
      op_name=issue_create; subject=$(printf '%s' "$title" | sha256sum | cut -c1-16)
      op=(issue_create --title "$title")
      for l in "${labels[@]}"; do op+=(--label "$l"); done
      for l in "${assignees[@]}"; do op+=(--assignee "$l"); done
      [ -n "$milestone" ] && op+=(--milestone "$milestone")
      ;;
    "pr create")
      op_name=pr_create; subject=$head
      op=(pr_create --title "$title" --head "$head")
      [ -n "$base" ] && op+=(--base "$base")
      [ "$draft" -eq 1 ] && op+=(--draft)
      for l in "${labels[@]}"; do op+=(--label "$l"); done
      for l in "${assignees[@]}"; do op+=(--assignee "$l"); done
      ;;
    *)
      # No dedicated op (pr comment, pr review, ...): the gated escape hatch
      # with the native argument shape, classified like every gh mutation.
      local scope
      if ! scope=$(external_pr_mutation_classify_gh_args "$topic" "$action" "${gh_body_native[@]}" 2>/dev/null) || [ -z "$scope" ]; then
        printf 'gh_body_with_file: %s %s is not a known mutation\n' "$topic" "$action" >&2
        rm -f "$body_file"
        return 2
      fi
      op_name="mutate.${scope}"; subject=$number
      op=(mutate --scope "$scope")
      ;;
  esac
  local key
  key=$(_gh_body_key "$op_name" "$repo" "$subject" "$body_file")
  # Generic flags (key, repo, body) go before the `--` of the mutate escape
  # hatch; the native argument shape travels after it.
  local -a common=(--idempotency-key "$key")
  [ -n "$repo" ] && common+=(--repo "$repo")
  if [ "${op[0]}" = mutate ]; then
    common+=(-- "$topic" "$action" "${gh_body_native[@]}" --body-file "$body_file")
  else
    common+=(--body-file "$body_file")
  fi

  local receipt rc=0
  receipt=$(ordo_provider "${op[@]}" "${common[@]}") || rc=$?
  rm -f "$body_file"
  if [ "$rc" -eq 0 ]; then
    # Same stdout contract as gh: the URL of what was created/commented.
    printf '%s' "$receipt" | jq -r '.result.url // .result.stdout // empty' 2>/dev/null
  fi
  return "$rc"
}

gh_issue_comment_body_file() {
  local issue=${1:?usage: gh_issue_comment_body_file <issue> [extra-args]}
  shift
  gh_body_with_file issue comment "$issue" "$@"
}

gh_pr_comment_body_file() {
  local pr=${1:?usage: gh_pr_comment_body_file <pr> [extra-args]}
  shift
  gh_body_with_file pr comment "$pr" "$@"
}

gh_pr_review_body_file() {
  local pr=${1:?usage: gh_pr_review_body_file <pr> [extra-args]}
  shift
  gh_body_with_file pr review "$pr" "$@"
}

gh_issue_create_body_file() {
  gh_body_with_file issue create "$@"
}

gh_pr_create_body_file() {
  gh_body_with_file pr create "$@"
}
