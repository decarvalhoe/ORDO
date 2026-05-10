#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

# shellcheck source=../lib/portfolio_config.sh
source "$ROOT/lib/portfolio_config.sh"

workdir="$TEST_TMP/workdir"
git init -q "$workdir"

canonical="https://github.com/RBOKproject/RBOK.git"

assert_origin_matches() {
  local remote=${1:?usage: assert_origin_matches <remote-url>}
  git -C "$workdir" remote remove origin >/dev/null 2>&1 || true
  git -C "$workdir" remote add origin "$remote"

  portfolio_workdir_origin_matches_canonical "$workdir" "$canonical" \
    || fail "expected origin to match canonical: origin=$remote canonical=$canonical"
}

assert_origin_refused() {
  local remote=${1:?usage: assert_origin_refused <remote-url>}
  git -C "$workdir" remote remove origin >/dev/null 2>&1 || true
  git -C "$workdir" remote add origin "$remote"

  if portfolio_workdir_origin_matches_canonical "$workdir" "$canonical"; then
    fail "expected origin to be refused: origin=$remote canonical=$canonical"
  fi
}

assert_origin_matches "https://github.com/RBOKproject/RBOK.git"
assert_origin_matches "git@github.com:RBOKproject/RBOK.git"
assert_origin_matches "github-claude:RBOKproject/RBOK.git"
assert_origin_matches "github.com-claude:RBOKproject/RBOK.git"

assert_origin_refused "github-claude:RBOKproject/ORDO.git"
assert_origin_refused "git@github.com:OtherOrg/RBOK.git"
assert_origin_refused "gitlab.example:RBOKproject/RBOK.git"

printf 'ok - portfolio remote proof compares GitHub owner/repo identity\n'
