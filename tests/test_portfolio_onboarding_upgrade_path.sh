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

configure_git() {
  local repo=${1:?usage: configure_git <repo>}
  local name=${2:?usage: configure_git <repo> <name> <email>}
  local email=${3:?usage: configure_git <repo> <name> <email>}

  git -C "$repo" config user.name "$name"
  git -C "$repo" config user.email "$email"
}

sha_file() {
  sha256sum "$1" | awk '{print $1}'
}

legacy_root="$TEST_TMP/pre-upgrade"
legacy_runtime="$legacy_root/runtime"
scoped_state="$legacy_runtime/state"
scoped_logs="$legacy_runtime/logs"
scoped_profiles="$legacy_runtime/profiles"
legacy_repos="$legacy_runtime/repos"
unscoped_state="$TEST_TMP/unscoped-state"
unscoped_logs="$TEST_TMP/unscoped-logs"

mkdir -p \
  "$legacy_repos" \
  "$scoped_state" \
  "$scoped_logs" \
  "$scoped_profiles" \
  "$TEST_TMP/configs" \
  "$TEST_TMP/home" \
  "$TEST_TMP/xdg"

remote_repo="$TEST_TMP/remote.git"
seed_repo="$TEST_TMP/seed"
git init -q --bare "$remote_repo"
git init -q "$seed_repo"
configure_git "$seed_repo" "Seed Repo" "seed@example.invalid"
printf 'v1\n' > "$seed_repo/file.txt"
git -C "$seed_repo" add file.txt
git -C "$seed_repo" commit -q -m 'initial'
git -C "$seed_repo" branch -M main
git -C "$seed_repo" remote add origin "$remote_repo"
git -C "$seed_repo" push -q -u origin main
git -C "$remote_repo" symbolic-ref HEAD refs/heads/main

claude_clone="$legacy_repos/claude"
gemini_clone="$legacy_repos/gemini"
git clone -q "$remote_repo" "$claude_clone"
git clone -q "$remote_repo" "$gemini_clone"

configure_git "$claude_clone" "Legacy Claude Identity" "legacy-claude@example.invalid"
configure_git "$gemini_clone" "Legacy Gemini Identity" "legacy-gemini@example.invalid"
printf 'local scratch\n' > "$gemini_clone/scratch.txt"

claude_head_before=$(git -C "$claude_clone" rev-parse HEAD)
gemini_head_before=$(git -C "$gemini_clone" rev-parse HEAD)
gemini_status_before=$(git -C "$gemini_clone" status --porcelain)

profile_file="$scoped_profiles/onboarding-profile.json"
state_file="$scoped_state/onboarding-state.json"
jq -nc \
  --arg state_base "$scoped_state" \
  --arg log_dir "$scoped_logs" \
  --arg profiles "$scoped_profiles" \
  '{
    schema_version:"ordo.guided_onboarding_profile.v1",
    project_metadata:{
      alias:"legacy-product",
      default_branch:"main",
      validation_mode:"dev",
      operator_class:"internal",
      agent_labels:["claude","gemini"]
    },
    runtime_root:{
      base:($state_base | sub("/state$"; "")),
      subdirs:{
        state:$state_base,
        logs:$log_dir,
        profiles:$profiles,
        cache:($state_base | sub("/state$"; "/cache")),
        repos:($state_base | sub("/state$"; "/repos")),
        launch:($state_base | sub("/state$"; "/launch")),
        audit:($state_base | sub("/state$"; "/audit")),
        orchestrator:($state_base | sub("/state$"; "/orchestrator"))
      }
    },
    generated_fleet:{agent_count:2},
    verification_input:{schema_version:"ordo.onboarding_verification.input.v1",expected_agent_count:2}
  }' > "$profile_file"
jq -nc \
  --arg profile "$profile_file" \
  '{
    schema_version:"ordo.guided_onboarding_state.v1",
    status:"applied",
    profile_path:$profile,
    last_profile:{schema_version:"ordo.guided_onboarding_profile.v1",agent_count:2},
    rerun:{reconfiguration_path:[]}
  }' > "$state_file"

profile_hash_before=$(sha_file "$profile_file")
state_hash_before=$(sha_file "$state_file")

product_config="$TEST_TMP/configs/legacy-product.config.sh"
cat > "$product_config" <<EOF
PROJECT="legacy-product"
GH_REPO=""
DEFAULT_BRANCH="main"
REPO_URL="$remote_repo"
export ORCH_STATE_BASE="$scoped_state"
export ORCH_LOG_DIR="$scoped_logs"
export AGENT_WORKDIR_TEMPLATE="$legacy_repos/%s"
AGENT_GIT_IDENTITY_NAME_TEMPLATE="Post249 Agent %s"
AGENT_GIT_IDENTITY_EMAIL_TEMPLATE="post249-%s@example.invalid"
AGENT_PANES=(
  "claude|legacy-claude:0.0|$claude_clone"
  "gemini|legacy-gemini:0.0|$gemini_clone"
)
EOF

portfolio_config="$TEST_TMP/configs/legacy-portfolio.config.sh"
cat > "$portfolio_config" <<EOF
PORTFOLIO_NAME="legacy-upgrade"
export ORCH_STATE_BASE="$scoped_state"
export ORCH_LOG_DIR="$scoped_logs"
PORTFOLIO_PROJECTS=(
  "legacy-product|$product_config"
)
PORTFOLIO_PRIORITIES=(
  "legacy-product=100"
)
PORTFOLIO_FLEET_AGENTS=(
  "claude|legacy-claude:0.0"
  "gemini|legacy-gemini:0.0"
)
EOF

[[ ! -e "$scoped_state/_portfolio" ]] \
  || fail "pre-upgrade fixture should not already have post-#249 portfolio state"

resolved_scope=$(
  bash -c '
    set -euo pipefail
    root=$1
    config=$2
    # shellcheck disable=SC1090
    source "$root/lib/portfolio_config.sh"
    load_portfolio_config "$config"
    printf "%s\n%s\n" "$ORCH_STATE_BASE" "$ORCH_LOG_DIR"
  ' _ "$ROOT" "$portfolio_config"
)
[[ "$resolved_scope" == "$scoped_state"$'\n'"$scoped_logs" ]] \
  || fail "portfolio config should preserve scoped state/log dirs, got: $resolved_scope"

upgrade_json=$(
  HOME="$TEST_TMP/home" \
  XDG_DATA_HOME="$TEST_TMP/xdg" \
  ORCH_STATE_BASE="$unscoped_state" \
  ORCH_LOG_DIR="$unscoped_logs" \
  bash "$ROOT/scripts/portfolio_session_start.sh" "$portfolio_config" --json --apply
)

jq -e '
  map(select(.alias == "legacy-product")) as $rows
  | ($rows | length) == 2
  and ($rows | map(select(.label == "claude"
      and .status == "ready"
      and .ready == 1
      and .identity_name == "Legacy Claude Identity"
      and .identity_email == "legacy-claude@example.invalid"
      and .target_identity_name == "Post249 Agent claude"
      and .target_identity_email == "post249-claude@example.invalid")) | length) == 1
  and ($rows | map(select(.label == "gemini"
      and .status == "dirty_worktree"
      and .ready == 0
      and .identity_name == "Legacy Gemini Identity"
      and .identity_email == "legacy-gemini@example.invalid")) | length) == 1
' <<< "$upgrade_json" >/dev/null \
  || fail "session start should preserve legacy identities while auditing upgraded portfolio: $upgrade_json"

[[ -s "$scoped_state/_portfolio/session_start.json" ]] \
  || fail "session_start.json should be written under scoped ORCH_STATE_BASE"
[[ -s "$scoped_state/_portfolio/clean_plan.json" ]] \
  || fail "clean_plan.json should be written under scoped ORCH_STATE_BASE"
[[ ! -e "$unscoped_state/_portfolio/session_start.json" ]] \
  || fail "session_start.json leaked to caller ORCH_STATE_BASE"
[[ ! -e "$TEST_TMP/xdg/orch-state/_portfolio/session_start.json" ]] \
  || fail "session_start.json leaked to XDG fallback state"

jq -e '.schema_version == "ordo.guided_onboarding_profile.v1"' "$profile_file" >/dev/null \
  || fail "saved onboarding profile should remain loadable"
jq -e '.schema_version == "ordo.guided_onboarding_state.v1"' "$state_file" >/dev/null \
  || fail "saved onboarding state should remain loadable"
[[ "$(sha_file "$profile_file")" == "$profile_hash_before" ]] \
  || fail "saved onboarding profile should not be rewritten by portfolio session start"
[[ "$(sha_file "$state_file")" == "$state_hash_before" ]] \
  || fail "saved onboarding state should not be rewritten by portfolio session start"

[[ "$(git -C "$claude_clone" config --local user.name)" == "Legacy Claude Identity" ]] \
  || fail "claude local git user.name should be preserved"
[[ "$(git -C "$claude_clone" config --local user.email)" == "legacy-claude@example.invalid" ]] \
  || fail "claude local git user.email should be preserved"
[[ "$(git -C "$gemini_clone" config --local user.name)" == "Legacy Gemini Identity" ]] \
  || fail "gemini local git user.name should be preserved"
[[ "$(git -C "$gemini_clone" config --local user.email)" == "legacy-gemini@example.invalid" ]] \
  || fail "gemini local git user.email should be preserved"
[[ "$(git -C "$claude_clone" rev-parse HEAD)" == "$claude_head_before" ]] \
  || fail "claude workdir HEAD should not change during upgrade preflight"
[[ "$(git -C "$gemini_clone" rev-parse HEAD)" == "$gemini_head_before" ]] \
  || fail "gemini workdir HEAD should not change during upgrade preflight"
[[ "$(git -C "$gemini_clone" status --porcelain)" == "$gemini_status_before" ]] \
  || fail "dirty workdir contents should not be cleaned or staged"
[[ -f "$gemini_clone/scratch.txt" ]] \
  || fail "dirty workdir sentinel file should be preserved"

printf 'ok - portfolio onboarding upgrade path preserves identities, scoped state, saved onboarding state, and workdirs (#433)\n'
