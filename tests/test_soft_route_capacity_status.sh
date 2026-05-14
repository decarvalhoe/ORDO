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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/bin" "$TEST_TMP/repos"

for rel in \
  scripts/agent_pool_status.sh \
  lib/agent_inventory.sh \
  lib/config_resolver.sh \
  lib/dispatch_capacity.sh \
  lib/process_safety.sh \
  lib/tmux_helpers.sh \
  lib/worktree_helpers.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/agent_pool_status.sh"

assigned_repo="$TEST_TMP/repos/assigned"
git init -q "$assigned_repo"
git -C "$assigned_repo" config user.email test@example.invalid
git -C "$assigned_repo" config user.name "Soft Route Test"
printf 'ok\n' > "$assigned_repo/file.txt"
git -C "$assigned_repo" add file.txt
git -C "$assigned_repo" commit -q -m 'init'
git -C "$assigned_repo" branch -M main
git -C "$assigned_repo" remote add origin "$assigned_repo"
git -C "$assigned_repo" update-ref refs/remotes/origin/main HEAD

configured_root="$TEST_TMP/repos/configured"
mkdir -p "$configured_root"
live_soft_cwd="$TEST_TMP/ORDO-worktrees/RBOK-cursor/feat-issue-658"
mkdir -p "$live_soft_cwd"

cat > "$TEST_TMP/config.sh" <<EOF
PROJECT="ordo"
DEFAULT_BRANCH="main"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
AGENT_PANES=(
  "RBOK-cursor|rbok-cursor:0.0|$configured_root"
)
EOF

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
chmod +x "$TEST_TMP/bin/gh"

cat > "$TEST_TMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list-panes) printf 'rbok-cursor:0.0\n'; exit 0 ;;
  has-session) exit 0 ;;
  display-message)
    fmt=""
    batched=0
    for arg in "$@"; do
      case "$arg" in
        *'#{pane_current_command}'*'#{pane_current_path}'*) batched=1 ;;
        '#{pane_current_path}'|'#{pane_current_command}') fmt=$arg ;;
      esac
    done
    if [ "$batched" = "1" ]; then
      printf 'node\037%s\n' "${FAKE_LIVE_CWD:-}"
    elif [ "$fmt" = '#{pane_current_path}' ]; then
      printf '%s\n' "${FAKE_LIVE_CWD:-}"
    elif [ "$fmt" = '#{pane_current_command}' ]; then
      printf 'node\n'
    fi
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

run_status() {
  local state_base=$1
  PATH="$TEST_TMP/bin:$PATH" \
  BASH_ENV='' \
  FAKE_LIVE_CWD="$live_soft_cwd" \
  ORCH_STATE_BASE="$state_base" \
  ORCH_PROCESS_BUDGET_WARN_PROCS=999999 \
  ORCH_PROCESS_BUDGET_MAX_PROCS=999999 \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" "$TEST_TMP/config.sh" --json
}

prompt_ok="$TEST_TMP/prompt-ok.md"
cat > "$prompt_ok" <<EOF
Read the issue and start by cd-ing to this assigned ORDO workdir:
$assigned_repo
EOF

state_soft="$TEST_TMP/state-soft"
mkdir -p "$state_soft/ordo"
cat > "$state_soft/ordo/assignments.json" <<JSON
{
  "RBOK-cursor": {
    "ticket": "658",
    "issue": 658,
    "branch": "fix/658-soft-route-assignment-status",
    "workdir": "$assigned_repo",
    "repo_root": "$configured_root",
    "prompt_file": "$prompt_ok",
    "route_mode": "soft",
    "context_proof_route": "soft-routed",
    "context_proof_live_workdir": "$live_soft_cwd"
  }
}
JSON

soft_json=$(run_status "$state_soft")
printf '%s' "$soft_json" \
  | jq -e --arg assigned "$assigned_repo" --arg live "$live_soft_cwd" '
      .[0].assigned_workdir == $assigned
      and .[0].live_pane_cwd == $live
      and .[0].live_cwd_match == "0"
      and .[0].capacity_class == "local_work"
      and (.[0].signals | index("soft_routed_active"))
      and ((.[0].signals | index("live_cwd_mismatch")) | not)
    ' >/dev/null \
  || fail "soft-routed assignment should be active without live_cwd_mismatch: $soft_json"

prompt_missing_workdir="$TEST_TMP/prompt-missing-workdir.md"
cat > "$prompt_missing_workdir" <<'EOF'
This prompt intentionally omits the assigned workdir.
EOF

state_missing_prompt="$TEST_TMP/state-missing-prompt"
mkdir -p "$state_missing_prompt/ordo"
cat > "$state_missing_prompt/ordo/assignments.json" <<JSON
{
  "RBOK-cursor": {
    "ticket": "658",
    "issue": 658,
    "branch": "fix/658-soft-route-assignment-status",
    "workdir": "$assigned_repo",
    "repo_root": "$configured_root",
    "prompt_file": "$prompt_missing_workdir",
    "route_mode": "soft",
    "context_proof_route": "soft-routed",
    "context_proof_live_workdir": "$live_soft_cwd"
  }
}
JSON

missing_prompt_json=$(run_status "$state_missing_prompt")
printf '%s' "$missing_prompt_json" \
  | jq -e '
      .[0].capacity_class == "switch_required"
      and (.[0].signals | index("live_cwd_mismatch"))
      and ((.[0].signals | index("soft_routed_active")) | not)
    ' >/dev/null \
  || fail "soft-route metadata without prompt workdir evidence should remain a cwd mismatch: $missing_prompt_json"

state_no_proof="$TEST_TMP/state-no-proof"
mkdir -p "$state_no_proof/ordo"
cat > "$state_no_proof/ordo/assignments.json" <<JSON
{
  "RBOK-cursor": {
    "ticket": "658",
    "issue": 658,
    "branch": "fix/658-soft-route-assignment-status",
    "workdir": "$assigned_repo",
    "repo_root": "$configured_root",
    "prompt_file": "$prompt_ok"
  }
}
JSON

no_proof_json=$(run_status "$state_no_proof")
printf '%s' "$no_proof_json" \
  | jq -e '
      .[0].capacity_class == "switch_required"
      and (.[0].signals | index("live_cwd_mismatch"))
      and ((.[0].signals | index("soft_routed_active")) | not)
    ' >/dev/null \
  || fail "assignment without soft-route proof should remain a cwd mismatch: $no_proof_json"

printf 'ok - soft route capacity status\n'
