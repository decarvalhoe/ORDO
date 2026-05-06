#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/configs" "$TEST_TMP/repos"

for rel in \
  scripts/portfolio_session_start.sh \
  lib/agent_inventory.sh \
  lib/config_resolver.sh \
  lib/dry_run.sh \
  lib/portfolio_config.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/portfolio_session_start.sh"

configure_git() {
  local repo=$1
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name "Portfolio Session Test"
}

remote_repo="$TEST_TMP/remote.git"
seed_repo="$TEST_TMP/seed"
git init -q --bare "$remote_repo"
git init -q "$seed_repo"
configure_git "$seed_repo"
printf 'v1\n' > "$seed_repo/file.txt"
git -C "$seed_repo" add file.txt
git -C "$seed_repo" commit -q -m 'initial'
git -C "$seed_repo" branch -M main
git -C "$seed_repo" remote add origin "$remote_repo"
git -C "$seed_repo" push -q -u origin main
git -C "$remote_repo" symbolic-ref HEAD refs/heads/main

behind_clone="$TEST_TMP/repos/behind"
git clone -q "$remote_repo" "$behind_clone"
configure_git "$behind_clone"

printf 'v2\n' > "$seed_repo/file.txt"
git -C "$seed_repo" add file.txt
git -C "$seed_repo" commit -q -m 'update'
git -C "$seed_repo" push -q origin main

ready_clone="$TEST_TMP/repos/ready"
dirty_clone="$TEST_TMP/repos/dirty"
missing_clone="$TEST_TMP/repos/missing"
git clone -q "$remote_repo" "$ready_clone"
git clone -q "$remote_repo" "$dirty_clone"
configure_git "$ready_clone"
configure_git "$dirty_clone"
printf 'dirty\n' > "$dirty_clone/dirty.txt"

cat > "$TEST_TMP/configs/product.config.sh" <<EOF
PROJECT="product"
GH_REPO=""
DEFAULT_BRANCH="main"
REPO_URL="$remote_repo"
AGENT_PANES=(
  "ready|product-ready:0.0|$ready_clone"
  "behind|product-behind:0.0|$behind_clone"
  "dirty|product-dirty:0.0|$dirty_clone"
  "missing|product-missing:0.0|$missing_clone"
)
EOF

cat > "$TEST_TMP/configs/portfolio.config.sh" <<EOF
PORTFOLIO_NAME="test"
PORTFOLIO_PROJECTS=(
  "product|$TEST_TMP/configs/product.config.sh"
)
EOF

json_output=$(
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/portfolio_session_start.sh" "$TEST_TMP/configs/portfolio.config.sh" --json
)
printf '%s\n' "$json_output" | jq -e '.[] | select(.label == "ready" and .status == "ready")' >/dev/null \
  || fail "ready clone should be ready: $json_output"
printf '%s\n' "$json_output" | jq -e '.[] | select(.label == "behind" and .status == "behind_default" and .behind == 1)' >/dev/null \
  || fail "behind clone should be detected: $json_output"
printf '%s\n' "$json_output" | jq -e '.[] | select(.label == "dirty" and .status == "dirty_worktree")' >/dev/null \
  || fail "dirty clone should be detected: $json_output"
printf '%s\n' "$json_output" | jq -e '.[] | select(.label == "missing" and .status == "missing_clone")' >/dev/null \
  || fail "missing clone should be detected: $json_output"
[[ -s "$TEST_TMP/state/_portfolio/session_start.json" ]] || fail "session start should persist latest report"

dry_err="$TEST_TMP/dry.err"
dry_json=$(
  ORCH_STATE_BASE="$TEST_TMP/dry-state" \
  bash "$SANITIZED_ROOT/scripts/portfolio_session_start.sh" "$TEST_TMP/configs/portfolio.config.sh" --json --apply --dry-run 2>"$dry_err"
)
printf '%s\n' "$dry_json" | jq -e '.[] | select(.label == "missing" and .applied == "clone")' >/dev/null \
  || fail "dry-run apply should report clone action: $dry_json"
grep -q 'DRY-RUN: git clone' "$dry_err" || fail "dry-run should print clone remediation"
[[ ! -e "$missing_clone" ]] || fail "dry-run should not create missing clone"
[[ ! -e "$TEST_TMP/dry-state/_portfolio/session_start.json" ]] || fail "dry-run should not persist session report"

apply_json=$(
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/portfolio_session_start.sh" "$TEST_TMP/configs/portfolio.config.sh" --json --apply
)
printf '%s\n' "$apply_json" | jq -e '.[] | select(.label == "missing" and .status == "ready" and .applied == "clone")' >/dev/null \
  || fail "apply should clone missing workdir: $apply_json"
printf '%s\n' "$apply_json" | jq -e '.[] | select(.label == "behind" and .status == "ready" and (.applied | contains("pull-ff-only")))' >/dev/null \
  || fail "apply should fast-forward behind clone: $apply_json"
[[ -d "$missing_clone/.git" ]] || fail "apply should create missing clone"
git -C "$behind_clone" merge-base --is-ancestor origin/main HEAD \
  || fail "behind clone should be fast-forwarded"

printf 'ok - portfolio_session_start audits and remediates clone readiness\n'
