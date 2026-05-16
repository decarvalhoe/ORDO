#!/usr/bin/env bash
# Issue #501: agent_pool_status must not attribute a mirrored foreign branch
# to a supervisor/integration mirror that also appears in AGENT_PANES.
# Ownership signals and capacity must reflect the supervisor mirror state,
# not the foreign branch checked out inside the mirror.
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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" \
  "$TEST_TMP/bin" "$TEST_TMP/repos"

for rel in \
  scripts/agent_pool_status.sh \
  scripts/agent_status.sh \
  lib/agent_status.sh \
  lib/agent_inventory.sh \
  lib/config_resolver.sh \
  lib/dispatch_capacity.sh \
  lib/process_safety.sh \
  lib/tmux_helpers.sh \
  lib/worktree_helpers.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/agent_pool_status.sh" \
  "$SANITIZED_ROOT/scripts/agent_status.sh"

make_repo() {
  local repo=$1
  local name=$2
  git init -q "$repo"
  git -C "$repo" config user.email "$name@example.invalid"
  git -C "$repo" config user.name "$name"
  printf 'ok\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m 'init'
  git -C "$repo" branch -M main
  git -C "$repo" remote add origin "$repo"
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
}

# Real worker that actually owns the branch.
worker_repo="$TEST_TMP/repos/worker"
# Supervisor/integration mirror — also listed in AGENT_PANES.
supervisor_repo="$TEST_TMP/repos/supervisor"
# Independent agent, on the default branch (available).
spare_repo="$TEST_TMP/repos/spare"

make_repo "$worker_repo" worker
make_repo "$supervisor_repo" supervisor
make_repo "$spare_repo" spare

# Put the worker on a feature branch.
git -C "$worker_repo" checkout -q -b feat/issue-500
printf 'work\n' > "$worker_repo/work.txt"
git -C "$worker_repo" add work.txt
git -C "$worker_repo" commit -q -m 'worker feature'

# Mirror the worker's branch into the supervisor repo to mimic the
# RBOK-claude integration-mirror scenario described in #501.
git -C "$supervisor_repo" checkout -q -b feat/issue-500
printf 'mirror\n' > "$supervisor_repo/mirror.txt"
git -C "$supervisor_repo" add mirror.txt
git -C "$supervisor_repo" commit -q -m 'supervisor mirror copy'

# Build a base config: PROJECT=ordo so assignment reconciliation runs,
# SUPERVISOR_REPO declares the mirror, AGENT_PANES lists worker, supervisor,
# spare.
cat > "$TEST_TMP/config.sh" <<EOF
PROJECT="ordo"
DEFAULT_BRANCH="main"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
SUPERVISOR_REPO="$supervisor_repo"
AGENT_PANES=(
  "worker-agent|worker-agent:0.0|$worker_repo"
  "supervisor-agent|supervisor-agent:0.0|$supervisor_repo"
  "spare-agent|spare-agent:0.0|$spare_repo"
)
EOF

# tmux stub: pretend each pane is alive in its assigned workdir.
cat > "$TEST_TMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  has-session) exit 0 ;;
  display-message)
    pane=""
    batched=0
    for arg in "$@"; do
      case "$arg" in
        *'#{pane_current_command}'*'#{pane_current_path}'*) batched=1 ;;
        worker-agent:0.0|supervisor-agent:0.0|spare-agent:0.0) pane=$arg ;;
      esac
    done
    case "$pane" in
      worker-agent:0.0) path="__WORKER_REPO__" ;;
      supervisor-agent:0.0) path="__SUPERVISOR_REPO__" ;;
      spare-agent:0.0) path="__SPARE_REPO__" ;;
      *) path="" ;;
    esac
    if [ "$batched" = "1" ]; then
      printf 'bash\037%s\n' "$path"
    else
      printf '%s\n' "$path"
    fi
    ;;
esac
EOF
sed -i \
  -e "s|__WORKER_REPO__|$worker_repo|g" \
  -e "s|__SUPERVISOR_REPO__|$supervisor_repo|g" \
  -e "s|__SPARE_REPO__|$spare_repo|g" \
  "$TEST_TMP/bin/tmux"
chmod +x "$TEST_TMP/bin/tmux"

# gh stub: no open PRs so capacity_class for the worker stays local_work.
cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '[]'
EOF
chmod +x "$TEST_TMP/bin/gh"

pool_json=$(
  PATH="$TEST_TMP/bin:$PATH" \
  BASH_ENV='' \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" \
    "$TEST_TMP/config.sh" --json
)

printf '%s' "$pool_json" | jq -e '
  def row($label): .[] | select(.label == $label);
  (row("worker-agent")
    | .branch == "feat/issue-500"
      and .capacity_class == "local_work"
      and ((.signals // []) | index("supervisor_mirror") | not))
  and
  (row("supervisor-agent")
    | .branch == ""
      and .head == ""
      and .capacity_class == "supervisor_mirror"
      and ((.signals // []) | index("supervisor_mirror")))
  and
  (row("spare-agent")
    | .branch == "main"
      and .capacity_class == "available"
      and ((.signals // []) | index("supervisor_mirror") | not))
' >/dev/null || fail "agent_pool_status should isolate supervisor mirror ownership: $pool_json"

# TSV: header still emitted, supervisor-agent row carries the signal and
# does not expose feat/issue-500 in the branch column.
pool_tsv=$(
  PATH="$TEST_TMP/bin:$PATH" \
  BASH_ENV='' \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" \
    "$TEST_TMP/config.sh" --tsv
)

printf '%s\n' "$pool_tsv" | head -1 | grep -q $'capacity_class\tbranch' \
  || fail "TSV header should include capacity_class and branch: $pool_tsv"
printf '%s\n' "$pool_tsv" | awk -F '\t' '$1 == "supervisor-agent"' \
  | grep -q 'supervisor_mirror' \
  || fail "TSV supervisor-agent row should surface supervisor_mirror signal: $pool_tsv"
printf '%s\n' "$pool_tsv" | awk -F '\t' '$1 == "supervisor-agent" { print $9 }' \
  | grep -q '^$' \
  || fail "TSV supervisor-agent row should keep branch empty (not foreign): $pool_tsv"

# Explicit mirror mapping: when the supervisor agent has an assignment that
# resolves to the mirror workdir, ownership is intentional and the mirror
# row should NOT be suppressed (no supervisor_mirror signal, branch flows).
mkdir -p "$TEST_TMP/state/ordo"
cat > "$TEST_TMP/state/ordo/assignments.json" <<JSON
{
  "supervisor-agent": {
    "ticket": "500",
    "issue": 500,
    "branch": "feat/issue-500",
    "workdir": "$supervisor_repo",
    "repo_root": "$supervisor_repo",
    "prompt_file": "/tmp/dispatch-supervisor-agent-500.md",
    "dispatched_at": "2026-05-10T00:00:00Z"
  }
}
JSON

mapped_json=$(
  PATH="$TEST_TMP/bin:$PATH" \
  BASH_ENV='' \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" \
    "$TEST_TMP/config.sh" --json
)

printf '%s' "$mapped_json" | jq -e '
  .[] | select(.label == "supervisor-agent")
  | .branch == "feat/issue-500"
    and .capacity_class != "supervisor_mirror"
    and ((.signals // []) | index("supervisor_mirror") | not)
' >/dev/null || fail "explicit mirror mapping should allow ownership: $mapped_json"

printf 'ok - agent_pool_status isolates supervisor mirror branch ownership\n'
