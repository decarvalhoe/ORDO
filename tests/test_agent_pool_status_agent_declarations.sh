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
chmod +x "$SANITIZED_ROOT/scripts/agent_pool_status.sh" "$SANITIZED_ROOT/scripts/agent_status.sh"

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

fresh_repo="$TEST_TMP/repos/fresh"
stale_repo="$TEST_TMP/repos/stale"
missing_repo="$TEST_TMP/repos/missing"
dirty_stale_repo="$TEST_TMP/repos/dirty-stale"
make_repo "$fresh_repo" fresh
make_repo "$stale_repo" stale
make_repo "$missing_repo" missing
make_repo "$dirty_stale_repo" dirty-stale
printf 'dirty\n' >> "$dirty_stale_repo/file.txt"

cat > "$TEST_TMP/config.sh" <<EOF
PROJECT="ordo"
DEFAULT_BRANCH="main"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
AGENT_STATUS_STALE_AFTER_SEC=60
AGENT_PANES=(
  "codex/agent:1|codex-agent:0.0|$fresh_repo"
  "stale-agent|stale-agent:0.0|$stale_repo"
  "missing-agent|missing-agent:0.0|$missing_repo"
  "dirty-stale-agent|dirty-stale-agent:0.0|$dirty_stale_repo"
)
EOF

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
        codex-agent:0.0|stale-agent:0.0|missing-agent:0.0|dirty-stale-agent:0.0) pane=$arg ;;
      esac
    done
    case "$pane" in
      codex-agent:0.0) path="__FRESH_REPO__" ;;
      stale-agent:0.0) path="__STALE_REPO__" ;;
      missing-agent:0.0) path="__MISSING_REPO__" ;;
      dirty-stale-agent:0.0) path="__DIRTY_STALE_REPO__" ;;
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
  -e "s|__FRESH_REPO__|$fresh_repo|g" \
  -e "s|__STALE_REPO__|$stale_repo|g" \
  -e "s|__MISSING_REPO__|$missing_repo|g" \
  -e "s|__DIRTY_STALE_REPO__|$dirty_stale_repo|g" \
  "$TEST_TMP/bin/tmux"
chmod +x "$TEST_TMP/bin/tmux"

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '[]'
EOF
chmod +x "$TEST_TMP/bin/gh"

ORCH_STATE_BASE="$TEST_TMP/state" \
bash "$SANITIZED_ROOT/scripts/agent_status.sh" declare \
  --project ordo \
  --agent 'codex/agent:1' \
  --target issue:638 \
  --workdir "$fresh_repo" \
  --status working \
  --reason 'implementing declaration contract' \
  --timestamp '2026-05-11T08:00:30Z' \
  --activity-ts '2026-05-11T08:00:30Z' \
  --phase implementation \
  --validation-state pending \
  --next-action 'run focused tests' >/dev/null

ORCH_STATE_BASE="$TEST_TMP/state" \
bash "$SANITIZED_ROOT/scripts/agent_status.sh" declare \
  --project ordo \
  --agent stale-agent \
  --target issue:638 \
  --workdir "$stale_repo" \
  --status blocked \
  --reason 'waiting for operator answer' \
  --timestamp '2026-05-11T07:55:00Z' \
  --blocker-category operator \
  --operator-action 'confirm scope' >/dev/null

ORCH_STATE_BASE="$TEST_TMP/state" \
bash "$SANITIZED_ROOT/scripts/agent_status.sh" declare \
  --project ordo \
  --agent dirty-stale-agent \
  --target issue:638 \
  --workdir "$dirty_stale_repo" \
  --status blocked \
  --reason 'waiting for operator answer' \
  --timestamp '2026-05-11T07:55:00Z' \
  --blocker-category operator \
  --operator-action 'confirm scope' >/dev/null

pool_json=$(
  PATH="$TEST_TMP/bin:$PATH" \
  BASH_ENV='' \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  AGENT_STATUS_NOW_EPOCH=1778486460 \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" "$TEST_TMP/config.sh" --json
)

printf '%s' "$pool_json" \
  | jq -e '
      def row($agent_label): .[] | select(.label == $agent_label);
      (row("codex/agent:1")
        | .declaration.state == "fresh"
          and .declaration.status == "working"
          and .declaration.reason == "implementing declaration contract"
          and .declaration.target == "issue:638"
          and .declaration.age_sec == 30
          and .declaration.optional.phase == "implementation"
          and .declaration.optional.validation_state == "pending"
          and .declaration.required_action == "")
      and
      (row("stale-agent")
        | .declaration.state == "stale"
          and .declaration.status == "blocked"
          and .dispatchable == true
          and .declaration.age_sec == 360
          and .declaration.optional.blocker_category == "operator"
          and .declaration.optional.required_operator_action == "confirm scope"
          and (.signals | index("agent-declaration-stale"))
          and ((.blocking_signals // []) | index("agent-declaration-stale") | not)
          and ((.blocking_signals // []) | index("agent-declaration-blocked") | not)
          and ((.informational_signals // []) | index("agent-declaration-stale"))
          and ((.informational_signals // []) | index("agent-declaration-blocked"))
          and .declaration.required_action == "refresh declaration or inspect agent")
      and
      (row("missing-agent")
        | .declaration.state == "missing"
          and .declaration.status == ""
          and .dispatchable == true
          and (.signals | index("agent-declaration-missing"))
          and ((.blocking_signals // []) | index("agent-declaration-missing") | not)
          and ((.informational_signals // []) | index("agent-declaration-missing"))
          and .declaration.required_action == "agent should emit status declaration")
      and
      (row("dirty-stale-agent")
        | .declaration.state == "stale"
          and .declaration.status == "blocked"
          and .dispatchable == false
          and .capacity_class == "dirty_clone"
          and (.signals | index("dirty"))
          and (.signals | index("agent-declaration-stale"))
          and ((.blocking_signals // []) | index("dirty"))
          and ((.blocking_signals // []) | index("agent-declaration-stale"))
          and ((.blocking_signals // []) | index("agent-declaration-blocked"))
          and ((.informational_signals // []) | index("agent-declaration-stale") | not))
    ' >/dev/null \
  || fail "agent_pool_status should consume fresh/stale/missing declarations: $pool_json"

pool_tsv=$(
  PATH="$TEST_TMP/bin:$PATH" \
  BASH_ENV='' \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  AGENT_STATUS_NOW_EPOCH=1778486460 \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" "$TEST_TMP/config.sh" --tsv
)

printf '%s\n' "$pool_tsv" | head -1 | grep -q $'declared_status\tdeclaration_state\tdeclaration_age_sec' \
  || fail "TSV header should expose declaration columns: $pool_tsv"
printf '%s\n' "$pool_tsv" | head -1 | grep -q $'blocking_signals\tinformational_signals' \
  || fail "TSV header should expose signal severity columns: $pool_tsv"
printf '%s\n' "$pool_tsv" | grep '^stale-agent\b' | grep -q 'agent-declaration-stale' \
  || fail "TSV stale row should surface stale declaration signal: $pool_tsv"

printf 'ok - agent_pool_status consumes provider-neutral agent declarations\n'
