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

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/repository_bootstrap.sh \
  scripts/repository_platform_readiness.sh
chmod +x "$SANITIZED_ROOT/scripts/repository_bootstrap.sh" \
  "$SANITIZED_ROOT/scripts/repository_platform_readiness.sh"

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/configs"

cat > "$TEST_TMP/bin/platform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$PLATFORM_LOG"

if [[ "${1:-} ${2:-}" == "identity current" ]]; then
  printf '%s\n' "identity-one"
  exit 0
fi

if [[ "${1:-} ${2:-}" == "repository metadata" ]]; then
  if [[ "${PLATFORM_DISCOVERY_FAIL:-0}" == "1" ]]; then
    printf '%s\n' "repository discovery unavailable" >&2
    exit 5
  fi
  if [[ -f "${PLATFORM_CREATED_FILE:?}" || "${PLATFORM_EXISTING:-0}" == "1" ]]; then
    jq -nc \
      --arg remote_url "${PLATFORM_REMOTE_URL:?}" \
      --arg permission "${PLATFORM_PERMISSION:-write}" \
      '{exists:true,repository:"target-repository",permission:$permission,default_branch:"main",remote_url:$remote_url}'
  else
    printf '%s\n' '{"exists":false,"repository":"target-repository"}'
  fi
  exit 0
fi

if [[ "${1:-} ${2:-}" == "repository create" ]]; then
  touch "${PLATFORM_CREATED_FILE:?}"
  jq -nc \
    --arg remote_url "${PLATFORM_REMOTE_URL:?}" \
    '{created:true,repository:"target-repository",remote_url:$remote_url}'
  exit 0
fi

if [[ "${1:-} ${2:-}" == "repository default-branch" ]]; then
  printf '%s\n' '{}'
  exit 0
fi

if [[ "${1:-} ${2:-}" == "ci status-check" ]]; then
  printf '%s\n' '[]'
  exit 0
fi

if [[ "${1:-} ${2:-}" == "pull-request review-check" ]]; then
  printf '%s\n' '{}'
  exit 0
fi

if [[ "${1:-} ${2:-}" == "issue assignment-check" ]]; then
  printf '%s\n' '{}'
  exit 0
fi

printf 'unexpected platform invocation: %s\n' "$*" >&2
exit 9
EOF
chmod +x "$TEST_TMP/bin/platform"

write_config() {
  local config=$1 workdir=$2 remote_url=$3 output=$4
  cat > "$config" <<EOF
#!/usr/bin/env bash
PROJECT="repository-bootstrap-test"
DEFAULT_BRANCH="main"
REPOSITORY_PLATFORM_REPOSITORY="target-repository"
REPOSITORY_PLATFORM_CLI_BIN="$TEST_TMP/bin/platform"
ORCH_EXPECTED_REPOSITORY_PLATFORM_IDENTITY="identity-one"
REPOSITORY_BOOTSTRAP_WORKDIR="$workdir"
REPOSITORY_BOOTSTRAP_REMOTE_URL="$remote_url"
REPOSITORY_BOOTSTRAP_CONFIG_OUTPUT="$output"
EOF
}

new_config="$TEST_TMP/configs/new.config.sh"
new_workdir="$TEST_TMP/workdirs/new"
new_remote="$TEST_TMP/remotes/new.git"
new_output="$TEST_TMP/generated/new.config.sh"
write_config "$new_config" "$new_workdir" "$new_remote" "$new_output"

export PLATFORM_LOG="$TEST_TMP/platform.log"
export PLATFORM_REMOTE_URL="$new_remote"
export PLATFORM_CREATED_FILE="$TEST_TMP/platform-created"

plan_json=$(
  bash "$SANITIZED_ROOT/scripts/repository_bootstrap.sh" "$new_config" --json
)
jq -e '
  .status == "plan" and
  .mode == "plan" and
  .repository_case == "new" and
  .safe_to_apply == true and
  (.actions | map(select(.name == "create_repository" and .mutating == true)) | length == 1) and
  (.applied | length == 0) and
  (.baseline_config | contains("REPOSITORY_PLATFORM_REPOSITORY=target-repository"))
' <<< "$plan_json" >/dev/null \
  || fail "plan should report safe non-mutating bootstrap: $plan_json"
[[ ! -e "$PLATFORM_CREATED_FILE" ]] || fail "plan must not create repository"
[[ ! -e "$new_workdir" ]] || fail "plan must not create workdir"
[[ ! -e "$new_output" ]] || fail "plan must not write baseline config"

dry_json=$(
  bash "$SANITIZED_ROOT/scripts/repository_bootstrap.sh" "$new_config" --apply --dry-run --json
)
jq -e '.status == "dry-run" and .mode == "dry-run" and (.applied | length == 0)' \
  <<< "$dry_json" >/dev/null \
  || fail "explicit dry-run should remain non-mutating: $dry_json"
[[ ! -e "$PLATFORM_CREATED_FILE" ]] || fail "dry-run must not create repository"
[[ ! -e "$new_workdir" ]] || fail "dry-run must not create workdir"

apply_json=$(
  bash "$SANITIZED_ROOT/scripts/repository_bootstrap.sh" "$new_config" --apply --json
)
jq -e '
  .status == "ready" and
  .mode == "apply" and
  .repository_case == "new" and
  .readiness.status == "ready" and
  (.applied | map(select(.name == "create_repository" and .status == "applied")) | length == 1) and
  (.applied | map(select(.name == "init_git" and .status == "applied")) | length == 1) and
  (.applied | map(select(.name == "verify_repository_readiness" and .status == "passed")) | length == 1) and
  (.blockers | length == 0)
' <<< "$apply_json" >/dev/null \
  || fail "apply should create and verify greenfield repository bootstrap: $apply_json"
[[ -f "$PLATFORM_CREATED_FILE" ]] || fail "apply should create repository through adapter"
[[ -d "$new_workdir/.git" ]] || fail "apply should initialize local git repository"
[[ "$(git -C "$new_workdir" symbolic-ref --short HEAD)" == "main" ]] \
  || fail "apply should set default branch locally"
[[ "$(git -C "$new_workdir" remote get-url origin)" == "$new_remote" ]] \
  || fail "apply should configure remote URL"
grep -q 'REPOSITORY_BOOTSTRAP_WORKDIR=' "$new_output" \
  || fail "apply should write baseline config"
grep -q 'repository create target-repository' "$PLATFORM_LOG" \
  || fail "apply should call repository create"

existing_config="$TEST_TMP/configs/existing.config.sh"
existing_workdir="$TEST_TMP/workdirs/existing"
existing_remote="$TEST_TMP/remotes/existing.git"
existing_output="$TEST_TMP/generated/existing.config.sh"
mkdir -p "$existing_workdir"
git init -q "$existing_workdir"
git -C "$existing_workdir" symbolic-ref HEAD refs/heads/main
git -C "$existing_workdir" remote add origin "$existing_remote"
write_config "$existing_config" "$existing_workdir" "$existing_remote" "$existing_output"
: > "$PLATFORM_LOG"
existing_json=$(
  PLATFORM_EXISTING=1 PLATFORM_REMOTE_URL="$existing_remote" PLATFORM_CREATED_FILE="$TEST_TMP/existing-created" \
  bash "$SANITIZED_ROOT/scripts/repository_bootstrap.sh" "$existing_config" --apply --json
)
jq -e '
  .status == "ready" and
  .repository_case == "existing" and
  (.applied | map(select(.name == "configure_remote" and .status == "already_ready")) | length == 1)
' <<< "$existing_json" >/dev/null \
  || fail "existing repository bootstrap should reuse ready repository: $existing_json"
if grep -q 'repository create target-repository' "$PLATFORM_LOG"; then
  fail "existing repository path must not create a repository"
fi

readonly_config="$TEST_TMP/configs/readonly.config.sh"
readonly_workdir="$TEST_TMP/workdirs/readonly"
readonly_remote="$TEST_TMP/remotes/readonly.git"
readonly_output="$TEST_TMP/generated/readonly.config.sh"
mkdir -p "$readonly_workdir"
git init -q "$readonly_workdir"
git -C "$readonly_workdir" symbolic-ref HEAD refs/heads/main
git -C "$readonly_workdir" remote add origin "$readonly_remote"
write_config "$readonly_config" "$readonly_workdir" "$readonly_remote" "$readonly_output"
: > "$PLATFORM_LOG"
set +e
readonly_json=$(
  PLATFORM_EXISTING=1 PLATFORM_PERMISSION=read PLATFORM_REMOTE_URL="$readonly_remote" PLATFORM_CREATED_FILE="$TEST_TMP/readonly-created" \
  bash "$SANITIZED_ROOT/scripts/repository_bootstrap.sh" "$readonly_config" --apply --json
)
readonly_status=$?
set -e
[[ "$readonly_status" -eq 78 ]] \
  || fail "read-only existing repository should refuse apply, got $readonly_status: $readonly_json"
jq -e '.status == "blocked" and (.blockers | index("repository_write_permission_missing"))' \
  <<< "$readonly_json" >/dev/null \
  || fail "read-only repository should report write-permission blocker: $readonly_json"
if grep -q 'repository default-branch target-repository' "$PLATFORM_LOG"; then
  fail "read-only refusal must occur before default-branch mutation"
fi

blocked_config="$TEST_TMP/configs/blocked.config.sh"
blocked_workdir="$TEST_TMP/workdirs/blocked"
blocked_remote="$TEST_TMP/remotes/blocked.git"
blocked_output="$TEST_TMP/generated/blocked.config.sh"
mkdir -p "$blocked_workdir"
printf '%s\n' "local content" > "$blocked_workdir/file.txt"
write_config "$blocked_config" "$blocked_workdir" "$blocked_remote" "$blocked_output"
: > "$PLATFORM_LOG"
set +e
blocked_json=$(
  PLATFORM_REMOTE_URL="$blocked_remote" PLATFORM_CREATED_FILE="$TEST_TMP/blocked-created" \
  bash "$SANITIZED_ROOT/scripts/repository_bootstrap.sh" "$blocked_config" --apply --json
)
blocked_status=$?
set -e
[[ "$blocked_status" -eq 78 ]] \
  || fail "unsafe non-git workdir should refuse apply, got $blocked_status: $blocked_json"
jq -e '.status == "blocked" and (.blockers | index("workdir_not_empty"))' \
  <<< "$blocked_json" >/dev/null \
  || fail "unsafe workdir refusal should report blocker: $blocked_json"
[[ ! -f "$TEST_TMP/blocked-created" ]] || fail "refused apply must not create repository"
if grep -q 'repository create target-repository' "$PLATFORM_LOG"; then
  fail "refused apply must not call repository create"
fi

printf 'ok - repository bootstrap plans, applies, verifies, and refuses unsafe workdirs\n'
