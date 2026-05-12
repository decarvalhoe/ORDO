#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TEST_TMP/logs" "$TEST_TMP/repos" "$TEST_TMP/gh"

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/brief_agents.sh \
  scripts/dispatch_ticket.sh \
  templates/dispatch-canonical.md.tpl

chmod +x "$SANITIZED_ROOT/scripts/brief_agents.sh" "$SANITIZED_ROOT/scripts/dispatch_ticket.sh"

git init --bare --initial-branch=main "$TEST_TMP/origin.git" >/dev/null
git init --initial-branch=main "$TEST_TMP/seed" >/dev/null
git -C "$TEST_TMP/seed" config user.name "Profile Preflight"
git -C "$TEST_TMP/seed" config user.email "profile-preflight@test.local"
printf 'seed\n' > "$TEST_TMP/seed/README.md"
git -C "$TEST_TMP/seed" add README.md
git -C "$TEST_TMP/seed" commit -m "seed" >/dev/null
git -C "$TEST_TMP/seed" remote add origin "$TEST_TMP/origin.git"
git -C "$TEST_TMP/seed" push -u origin main >/dev/null 2>&1

git clone "$TEST_TMP/origin.git" "$TEST_TMP/repos/gemini" >/dev/null 2>&1
git -C "$TEST_TMP/repos/gemini" checkout main >/dev/null 2>&1
git -C "$TEST_TMP/repos/gemini" config user.name "Unmapped Worker"
git -C "$TEST_TMP/repos/gemini" config user.email "unmapped@test.local"

git clone "$TEST_TMP/origin.git" "$TEST_TMP/supervisor" >/dev/null 2>&1
git -C "$TEST_TMP/supervisor" checkout main >/dev/null 2>&1
base_sha=$(git -C "$TEST_TMP/repos/gemini" rev-parse origin/main)

cat > "$TEST_TMP/live-unknown.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="dispatch-profile"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
SUPERVISOR_REPO="$TEST_TMP/supervisor"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
USE_WORKTREES=0
export REQUIRE_ACCEPTANCE_PROOF="\${REQUIRE_ACCEPTANCE_PROOF:-0}"
EOF

set +e
unknown_output=$(
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
    "$TEST_TMP/live-unknown.config.sh" gemini 656 \
    summary="Live profile preflight" validation="none" 2>&1
)
unknown_status=$?
set -e

[[ "$unknown_status" -ne 0 ]] \
  || fail "unknown live profile scope should refuse brief rendering"
[[ "$unknown_output" == *"PROFILE_PREFLIGHT_REFUSED"* ]] \
  || fail "unknown scope refusal should name profile preflight, got: $unknown_output"
[[ "$unknown_output" == *"reason=scope_unknown"* ]] \
  || fail "unknown scope refusal should surface scope_unknown, got: $unknown_output"

authorized_prompt="$TEST_TMP/authorized.md"
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/live-unknown.config.sh" gemini 657 \
  --allow-unknown-scope \
  base_remote=origin base_ref=origin/main base_sha="$base_sha" \
  summary="Authorized unknown scope" validation="none" \
  > "$authorized_prompt"

grep -Fq '`git fetch origin`' "$authorized_prompt" \
  || fail "authorized prompt should use explicit origin remote"
grep -R "PROFILE_PREFLIGHT_AUTHORIZED" "$TEST_TMP/logs" >/dev/null \
  || fail "unknown-scope authorization should be audit logged"

cat > "$TEST_TMP/bad-base.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="dispatch-profile"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
SUPERVISOR_REPO="$TEST_TMP/not-a-remote"
ORCH_SCOPE_IN_SCOPE_PROJECTS="dispatch-profile"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
USE_WORKTREES=0
export REQUIRE_ACCEPTANCE_PROOF="\${REQUIRE_ACCEPTANCE_PROOF:-0}"
EOF
mkdir -p "$TEST_TMP/not-a-remote"

set +e
base_output=$(
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
    "$TEST_TMP/bad-base.config.sh" gemini 658 \
    summary="Invalid base remote" validation="none" 2>&1
)
base_status=$?
set -e

[[ "$base_status" -ne 0 ]] \
  || fail "filesystem SUPERVISOR_REPO should refuse when it cannot resolve to a remote"
[[ "$base_output" == *"reason=base_remote_filesystem_path"* ]] \
  || fail "base refusal should identify filesystem base_remote, got: $base_output"

cat > "$TEST_TMP/identity.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="dispatch-profile"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
SUPERVISOR_REPO="origin"
ORCH_SCOPE_IN_SCOPE_PROJECTS="dispatch-profile"
AGENT_GH_LOGINS=(
  "gemini|rbok-agent-gemini"
)
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
USE_WORKTREES=0
export REQUIRE_ACCEPTANCE_PROOF="\${REQUIRE_ACCEPTANCE_PROOF:-0}"
EOF

identity_prompt="$TEST_TMP/dispatch-gemini-659.md"
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/identity.config.sh" gemini 659 \
  base_sha="$base_sha" summary="Missing git identity" validation="none" \
  > "$identity_prompt"

set +e
identity_output=$(
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_CONTEXT_PROOF=0 \
  ORCH_CONTEXT_PROOF_WAIT_SEC=0 \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" \
    "$TEST_TMP/identity.config.sh" gemini 659 "$identity_prompt" --dry-run 2>&1
)
identity_status=$?
set -e

[[ "$identity_status" -ne 0 ]] \
  || fail "dispatch should refuse missing agent git identity before route mismatch"
[[ "$identity_output" == *"DISPATCH_PROFILE_PREFLIGHT_REFUSED"* ]] \
  || fail "missing git identity should be a profile preflight refusal, got: $identity_output"
[[ "$identity_output" == *"reason=missing_agent_git_identity"* ]] \
  || fail "missing git identity refusal should name the reason, got: $identity_output"
[[ "$identity_output" != *"DISPATCH_ROUTE_MISMATCH"* ]] \
  || fail "missing identity should not surface as route mismatch, got: $identity_output"

printf 'ok - live profile dispatch preflight refuses unsafe profile drift\n'
