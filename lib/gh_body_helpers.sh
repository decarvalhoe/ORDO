#!/usr/bin/env bash
# lib/gh_body_helpers.sh — shell-safe markdown body helpers for the gh CLI.
#
# Doctrine:
#   - Markdown bodies must always reach gh via --body-file, never via
#     --body "$VAR". Bodies that contain backticks, $(...), single or
#     double quotes, or newlines round-trip incorrectly when they
#     traverse a shell argv level (variable expansion, eval-like
#     wrappers, multi-line concatenation, history expansion, etc.).
#   - Helpers in this file write the body to a per-call mktemp file
#     and invoke gh with --body-file <path>. Callers stream the body
#     via stdin so it never participates in shell argv parsing.
#   - This file is sourced. Do NOT execute it directly.
#
# Public functions:
#   gh_body_write_tempfile [tag]
#     Read stdin, write to a fresh mktemp file, echo the path on
#     stdout. Optional [tag] sets the template prefix (default:
#     gh_body). Caller is responsible for removing the file when not
#     using gh_body_with_file.
#   gh_body_with_file <gh-args...>
#     Read body from stdin, run "gh <gh-args> --body-file <tmp>",
#     remove the tempfile, return gh's exit code. The --body-file
#     flag is appended to the argv so callers stay free of body text.
#   gh_issue_comment_body_file <issue> [extra-args...]
#   gh_pr_comment_body_file <pr> [extra-args...]
#   gh_pr_review_body_file <pr> [extra-args...]
#   gh_issue_create_body_file [extra-args...]
#   gh_pr_create_body_file [extra-args...]
#     Convenience wrappers around gh_body_with_file.
#
# Configuration:
#   GH_BODY_HELPERS_GH_BIN  Path or name of gh binary (default: gh).

set -o pipefail

: "${GH_BODY_HELPERS_GH_BIN:=gh}"

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
  if [ "$#" -lt 1 ]; then
    printf 'gh_body_with_file: missing gh subcommand args\n' >&2
    return 2
  fi
  local body_file
  body_file=$(gh_body_write_tempfile "gh_body") || return 1
  local rc=0
  "$GH_BODY_HELPERS_GH_BIN" "$@" --body-file "$body_file" || rc=$?
  rm -f "$body_file"
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
