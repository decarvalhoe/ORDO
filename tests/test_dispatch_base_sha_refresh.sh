#!/usr/bin/env bash
# tests/test_dispatch_base_sha_refresh.sh — coverage for ORDO #465.
#
# `scripts/dispatch_ticket.sh` MUST compare a staged brief's pinned base
# SHA against the current `origin/<default_branch>` head before the
# brief lands in the agent pane. During a merge wave, several PRs can
# advance the default branch between brief render and brief submit,
# leaving the agent to fork off a SHA that is now older than reality;
# silently dispatching the stale brief later rolls back recent merges.
#
# This regression test exercises six representative cases against a
# real bare-repo origin and a real clone workdir:
#
#   1. fresh brief (pinned == current)            -> BASE_FRESH, exit 0
#   2. stale brief + clean unstarted worktree     -> BASE_STALE_REFRESH, exit 81
#   3. stale brief + dirty (uncommitted) worktree -> REFUSED stale_base_dirty, 82
#   4. stale brief + committed worktree (HEAD beyond origin/main)
#                                                 -> REFUSED stale_base_dirty, 82
#   5. stale brief + REFUSE_STALE_BASE=0 opt-out  -> CHECK skipped opt_out, exit 0
#   6. brief without an "accepted immutable base" line
#                                                 -> CHECK skipped no_pinned_base, exit 0

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() {
  rm -rf "$TEST_TMP"
  rm -f \
    /tmp/dispatch-claude-46501.md \
    /tmp/dispatch-claude-46502.md \
    /tmp/dispatch-claude-46503.md \
    /tmp/dispatch-claude-46504.md \
    /tmp/dispatch-claude-46505.md \
    /tmp/dispatch-claude-46506.md
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/logs" "$TEST_TMP/repos" \
  "$TEST_TMP/state"

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/brief_agents.sh \
  scripts/dispatch_ticket.sh \
  templates/dispatch-canonical.md.tpl

chmod +x "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$SANITIZED_ROOT/scripts/dispatch_ticket.sh"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="dispatch-base-refresh-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
REPO_URL="$TEST_TMP/origin.git"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
SUPERVISOR_REPO=""
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
USE_WORKTREES="\${USE_WORKTREES:-0}"
ORCH_WORKTREES_DIR="\${ORCH_WORKTREES_DIR:-$TEST_TMP/agent-worktrees}"
# Legacy fixture predates #573's post-dispatch acceptance gate; the
# freshness check fires before that gate is reachable, so we disable it
# here for the cases that must reach dispatch success (1, 5, 6).
export REQUIRE_ACCEPTANCE_PROOF="\${REQUIRE_ACCEPTANCE_PROOF:-0}"
EOF

# tmux stub: record everything and report a fixed claude pane state for
# the readiness handshake. The freshness check runs before tmux paste,
# so the dispatch never actually reaches the buffer paste in dry-run.
cat > "$TEST_TMP/bin/tmux" <<EOF
#!/bin/sh
set -eu
printf '%s\n' "\$*" >> "$TEST_TMP/logs/tmux.log"
case "\${1:-}" in
  has-session) exit 0 ;;
  list-panes)  exit 0 ;;
  capture-pane) printf 'working on dispatch\n'; exit 0 ;;
  display-message) printf 'claude\n'; exit 0 ;;
esac
exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

# gh stub: PR not present, issue always open.
cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  pr)
    case "${2:-}" in
      list) printf '[]\n'; exit 0 ;;
      view) printf '{}\n'; exit 1 ;;
    esac
    ;;
  issue)
    case "${2:-}" in
      view) printf '{"state":"OPEN","closedAt":""}\n'; exit 0 ;;
    esac
    ;;
esac
exit 0
EOF
chmod +x "$TEST_TMP/bin/gh"

# Seed origin.git with main @ SHA_OLD.
git init --bare "$TEST_TMP/origin.git" >/dev/null
git init "$TEST_TMP/seed" >/dev/null
git -C "$TEST_TMP/seed" config user.name "Base Refresh Seed"
git -C "$TEST_TMP/seed" config user.email "seed@test.local"
git -C "$TEST_TMP/seed" checkout -b main >/dev/null
printf 'seed\n' > "$TEST_TMP/seed/README.md"
git -C "$TEST_TMP/seed" add README.md
git -C "$TEST_TMP/seed" commit -m "seed" >/dev/null
git -C "$TEST_TMP/seed" remote add origin "$TEST_TMP/origin.git"
git -C "$TEST_TMP/seed" push -u origin main >/dev/null
SHA_OLD=$(git -C "$TEST_TMP/seed" rev-parse HEAD)

# Clone origin -> AGENT_WORKDIR. The clone's HEAD == origin/main == SHA_OLD.
git clone "$TEST_TMP/origin.git" "$TEST_TMP/repos/claude" >/dev/null 2>&1
git -C "$TEST_TMP/repos/claude" checkout main >/dev/null
git -C "$TEST_TMP/repos/claude" config user.name "Dispatch Claude"
git -C "$TEST_TMP/repos/claude" config user.email "claude@test.local"

# Capture origin/main snapshot post-clone — equals SHA_OLD until we
# advance the bare repo below.
post_clone_origin=$(git -C "$TEST_TMP/repos/claude" rev-parse origin/main)
[[ "$post_clone_origin" = "$SHA_OLD" ]] \
  || fail "fixture invariant — origin/main after clone should equal SHA_OLD"

# Generate the canonical fresh brief: pinned base = SHA_OLD = current.
fresh_prompt="$TEST_TMP/fresh.md"
PATH="$TEST_TMP/bin:$PATH" \
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/test.config.sh" claude 46501 \
  base_sha="$SHA_OLD" \
  summary="Base SHA freshness regression coverage" \
  validation="bash tests.sh" > "$fresh_prompt"

grep -Fq "accepted immutable base: \`origin/main\` at \`$SHA_OLD\`" "$fresh_prompt" \
  || fail "brief_agents must render canonical 'accepted immutable base ... at <sha>' line"

# Shared dispatch invocation. --dry-run keeps the test offline (no
# actual tmux paste, no GitHub assignment), but the freshness check
# itself runs unconditionally and operates on the real workdir.
run_dispatch() {
  local cfg=$1 ticket=$2 prompt=$3
  shift 3
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  REQUIRE_ACCEPTANCE_PROOF=0 \
  env "$@" \
    bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" \
      "$cfg" claude "$ticket" "$prompt" --dry-run
}

audit_log="$TEST_TMP/logs/dispatch-base-refresh-test.log"

# -----------------------------------------------------------------------
# Case 1: pinned base equals current origin/main -> BASE_FRESH, exit 0.
# -----------------------------------------------------------------------
: > "$audit_log" 2>/dev/null || true
set +e
out1=$(run_dispatch "$TEST_TMP/test.config.sh" 46501 "$fresh_prompt" 2>&1)
rc1=$?
set -e

[[ "$rc1" -eq 0 ]] \
  || fail "case 1 (fresh) — expected exit 0, got $rc1: $out1"

grep -Fq "DISPATCH BASE_FRESH agent=claude ticket=#46501 pinned=$SHA_OLD current=$SHA_OLD" \
  "$audit_log" \
  || fail "case 1 — expected 'DISPATCH BASE_FRESH ... pinned=$SHA_OLD current=$SHA_OLD' in audit log, got: $(cat "$audit_log" 2>/dev/null || true)"

# Advance origin/main: push a new commit so the bare repo's main moves
# from SHA_OLD to SHA_NEW. The local AGENT_WORKDIR ref pointers are
# stale on purpose — the freshness check is responsible for running
# `git fetch` itself.
printf 'merge wave commit\n' >> "$TEST_TMP/seed/README.md"
git -C "$TEST_TMP/seed" add README.md
git -C "$TEST_TMP/seed" commit -m "merge wave advance" >/dev/null
git -C "$TEST_TMP/seed" push origin main >/dev/null
SHA_NEW=$(git -C "$TEST_TMP/seed" rev-parse HEAD)
[[ "$SHA_NEW" != "$SHA_OLD" ]] \
  || fail "fixture invariant — SHA_NEW must differ from SHA_OLD after merge-wave advance"

# Sanity: pre-fetch ref in the workdir is still SHA_OLD. The dispatch
# script must do its own fetch to see SHA_NEW.
pre_fetch_origin=$(git -C "$TEST_TMP/repos/claude" rev-parse origin/main)
[[ "$pre_fetch_origin" = "$SHA_OLD" ]] \
  || fail "fixture invariant — origin/main in workdir should still be SHA_OLD before dispatch fetches"

# -----------------------------------------------------------------------
# Case 2: pinned=SHA_OLD, current=SHA_NEW, worktree clean + HEAD ancestor
# of origin/main -> DISPATCH BASE_STALE_REFRESH + exit 81.
# -----------------------------------------------------------------------
: > "$audit_log"
set +e
out2=$(run_dispatch "$TEST_TMP/test.config.sh" 46502 "$fresh_prompt" 2>&1)
rc2=$?
set -e

[[ "$rc2" -eq 81 ]] \
  || fail "case 2 (stale + clean) — expected exit 81, got $rc2: $out2"

grep -Eq "DISPATCH BASE_STALE_REFRESH agent=claude ticket=#46502 .* old=$SHA_OLD new=$SHA_NEW worktree=clean_unstarted action=regenerate-brief" \
  "$audit_log" \
  || fail "case 2 — expected BASE_STALE_REFRESH audit with old=$SHA_OLD new=$SHA_NEW, got: $(cat "$audit_log")"

[[ "$out2" == *"brief must be regenerated"* ]] \
  || fail "case 2 — stderr should explain the refresh requirement, got: $out2"

# -----------------------------------------------------------------------
# Case 3: pinned=SHA_OLD, current=SHA_NEW, worktree dirty -> REFUSED
# stale_base_dirty + exit 82.
# -----------------------------------------------------------------------
printf 'uncommitted edit\n' > "$TEST_TMP/repos/claude/dirty.txt"
[[ -s "$TEST_TMP/repos/claude/dirty.txt" ]] || fail "fixture — could not create dirty file"

: > "$audit_log"
set +e
out3=$(run_dispatch "$TEST_TMP/test.config.sh" 46503 "$fresh_prompt" 2>&1)
rc3=$?
set -e

[[ "$rc3" -eq 82 ]] \
  || fail "case 3 (stale + dirty) — expected exit 82, got $rc3: $out3"

grep -Eq "DISPATCH REFUSED reason=stale_base_dirty agent=claude ticket=#46503 .* old=$SHA_OLD new=$SHA_NEW dirty=[1-9][0-9]* ahead=0 action=operator-required" \
  "$audit_log" \
  || fail "case 3 — expected REFUSED stale_base_dirty audit with dirty>0 ahead=0, got: $(cat "$audit_log")"

# Cleanup before case 4.
rm -f "$TEST_TMP/repos/claude/dirty.txt"
git -C "$TEST_TMP/repos/claude" status --porcelain | grep -q . \
  && fail "fixture — workdir should be clean before case 4"

# -----------------------------------------------------------------------
# Case 4: pinned=SHA_OLD, current=SHA_NEW, worktree committed beyond
# origin/main -> REFUSED stale_base_dirty + exit 82.
# -----------------------------------------------------------------------
# Pre-fetch so the workdir actually has SHA_NEW as origin/main; we want
# HEAD to be ahead of origin/main (committed ahead), not just unaware
# of origin's advance.
git -C "$TEST_TMP/repos/claude" fetch origin main >/dev/null 2>&1
git -C "$TEST_TMP/repos/claude" reset --hard origin/main >/dev/null 2>&1
printf 'local agent work\n' >> "$TEST_TMP/repos/claude/README.md"
git -C "$TEST_TMP/repos/claude" add README.md
git -C "$TEST_TMP/repos/claude" commit -m "local agent work" >/dev/null

: > "$audit_log"
set +e
out4=$(run_dispatch "$TEST_TMP/test.config.sh" 46504 "$fresh_prompt" 2>&1)
rc4=$?
set -e

[[ "$rc4" -eq 82 ]] \
  || fail "case 4 (stale + committed) — expected exit 82, got $rc4: $out4"

grep -Eq "DISPATCH REFUSED reason=stale_base_dirty agent=claude ticket=#46504 .* old=$SHA_OLD new=$SHA_NEW dirty=0 ahead=[1-9][0-9]* action=operator-required" \
  "$audit_log" \
  || fail "case 4 — expected REFUSED stale_base_dirty audit with dirty=0 ahead>0, got: $(cat "$audit_log")"

# Reset workdir back to origin/main for the remaining cases.
git -C "$TEST_TMP/repos/claude" reset --hard origin/main >/dev/null 2>&1

# -----------------------------------------------------------------------
# Case 5: stale brief + REFUSE_STALE_BASE=0 opt-out -> CHECK skipped
# reason=opt_out, dispatch proceeds (exit 0).
# -----------------------------------------------------------------------
: > "$audit_log"
set +e
out5=$(run_dispatch "$TEST_TMP/test.config.sh" 46505 "$fresh_prompt" REFUSE_STALE_BASE=0 2>&1)
rc5=$?
set -e

[[ "$rc5" -eq 0 ]] \
  || fail "case 5 (opt-out) — expected exit 0, got $rc5: $out5"

grep -Fq "DISPATCH BASE_FRESHNESS_CHECK skipped agent=claude ticket=#46505 reason=opt_out" \
  "$audit_log" \
  || fail "case 5 — expected BASE_FRESHNESS_CHECK skipped reason=opt_out, got: $(cat "$audit_log")"

if grep -q "DISPATCH BASE_STALE_REFRESH" "$audit_log"; then
  fail "case 5 — opt-out must NOT emit BASE_STALE_REFRESH: $(cat "$audit_log")"
fi

# -----------------------------------------------------------------------
# Case 6: brief without "accepted immutable base" line -> CHECK skipped
# reason=no_pinned_base, dispatch proceeds (exit 0). The brief still
# carries a base SHA elsewhere (the renderer writes it in multiple
# places), so we strip the canonical phrase entirely and bypass canonical
# prompt validation.
# -----------------------------------------------------------------------
no_pin_prompt="$TEST_TMP/no-pin.md"
# Strip every line that mentions the canonical phrase, in either case.
grep -iv 'accepted immutable base' "$fresh_prompt" > "$no_pin_prompt"
if grep -iq 'accepted immutable base' "$no_pin_prompt"; then
  fail "fixture — no-pin brief still mentions 'accepted immutable base'"
fi

: > "$audit_log"
set +e
out6=$(PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  REQUIRE_ACCEPTANCE_PROOF=0 \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" \
    "$TEST_TMP/test.config.sh" claude 46506 "$no_pin_prompt" \
    --no-validate --dry-run 2>&1)
rc6=$?
set -e

[[ "$rc6" -eq 0 ]] \
  || fail "case 6 (no pinned base) — expected exit 0, got $rc6: $out6"

grep -Fq "DISPATCH BASE_FRESHNESS_CHECK skipped agent=claude ticket=#46506 reason=no_pinned_base" \
  "$audit_log" \
  || fail "case 6 — expected BASE_FRESHNESS_CHECK skipped reason=no_pinned_base, got: $(cat "$audit_log")"

printf 'ok - dispatch_ticket refreshes-or-refuses stale pinned bases before brief delivery\n'
