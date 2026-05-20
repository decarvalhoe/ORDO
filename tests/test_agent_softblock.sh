#!/usr/bin/env bash
# tests/test_agent_softblock.sh — unit coverage for lib/agent_softblock.sh.
#
# Issue #757: a soft-blocked agent (pane carries operator-handoff language)
# must classify as `soft_blocked`; a pane that shows recent git activity
# must classify as `working`; everything else falls back to `idle`. The
# helper feeds the orch_loop rebalance step, so the classifier is the
# unit-test surface; the cycle-level rebalance behaviour is covered by
# tests/test_orch_loop_softblock_rebalance.sh.
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

# Sanitize the lib into a CRLF-free copy so the test runs identically on
# Windows-line-ending hosts (matches the convention used by other tests).
SANITIZED="$TEST_TMP/agent_softblock.sh"
tr -d '\r' < "$ROOT/lib/agent_softblock.sh" > "$SANITIZED"
# shellcheck source=../lib/agent_softblock.sh
source "$SANITIZED"

# --- classifier: empty body falls back to idle -----------------------------
class=$(classify_agent_pane_body "")
[ "$class" = "idle" ] || fail "empty body should classify idle, got: $class"

# --- classifier: soft-block default vocabulary wins ------------------------
softblock_body=$(cat <<'PANE'
$ git status
On branch feat/issue-240
Changes not staged for commit:
  modified: lib/sixsigma_config.sh

Current worktree state: clean tree on feat/issue-240 at 578fd2e plus the uncommitted SC2034 fix in lib/sixsigma_config.sh. Nothing pushed. No PR opened. Recommendation for the dispatcher: the docs/sixsigma/README.md neutrality breach needs to be resolved on main...
$
PANE
)
class=$(classify_agent_pane_body "$softblock_body")
[ "$class" = "soft_blocked" ] || fail "Recommendation-for-the-dispatcher must classify soft_blocked, got: $class"

# --- classifier: explicit blocker vocabulary -------------------------------
class=$(classify_agent_pane_body "blocker: docs/sixsigma/README.md has //urls that fail neutrality")
[ "$class" = "soft_blocked" ] || fail "'blocker:' line must classify soft_blocked, got: $class"

# --- classifier: out-of-scope vocabulary -----------------------------------
class=$(classify_agent_pane_body "I cannot modify docs/sixsigma/README.md — that is out of scope for this ticket.")
[ "$class" = "soft_blocked" ] || fail "'out of scope' line must classify soft_blocked, got: $class"

# --- classifier: soft-block wins over stale 'working' line in the same body
mixed_body=$(cat <<'PANE'
[feat/issue-240 578fd2e] feat(240): SC2034 fix
 1 file changed, 1 insertion(+), 1 deletion(-)
... later ...
Recommendation for the dispatcher: please fix docs/sixsigma/README.md first.
PANE
)
class=$(classify_agent_pane_body "$mixed_body")
[ "$class" = "soft_blocked" ] || fail "soft-block must dominate a same-body 'working' line, got: $class"

# --- classifier: working detected on a recent commit line ------------------
working_body=$(cat <<'PANE'
[feat/issue-757 e90df21] feat(757): add agent_softblock lib
 2 files changed, 12 insertions(+)
$
PANE
)
class=$(classify_agent_pane_body "$working_body")
[ "$class" = "working" ] || fail "recent commit must classify working, got: $class"

# --- classifier: working detected on 'git push' output ---------------------
push_body=$(cat <<'PANE'
$ git push origin HEAD
To https://github.com/example/repo.git
   1234abc..5678def  feat/issue-757 -> feat/issue-757
$
PANE
)
class=$(classify_agent_pane_body "$push_body")
[ "$class" = "working" ] || fail "git push output must classify working, got: $class"

# --- classifier: idle prompt with no signals -------------------------------
idle_body=$(cat <<'PANE'
$
$
$ pwd
/root/repos/fleet-worktrees/ordo/agent-005/feat-issue-757
$
PANE
)
class=$(classify_agent_pane_body "$idle_body")
[ "$class" = "idle" ] || fail "idle prompt body must classify idle, got: $class"

# --- patterns: ORCH_SOFTBLOCK_PATTERNS overrides vocabulary ----------------
ORCH_SOFTBLOCK_PATTERNS=$'custom-blocker-tag\nfleet-handoff-marker'
custom_body="fleet-handoff-marker: needs operator decision on README"
class=$(classify_agent_pane_body "$custom_body")
[ "$class" = "soft_blocked" ] || fail "custom ORCH_SOFTBLOCK_PATTERNS must drive classification, got: $class"

# When the default vocabulary is replaced, the default phrases no longer match.
class=$(classify_agent_pane_body "Recommendation for the dispatcher: fix the README")
[ "$class" = "idle" ] || fail "with custom patterns, default vocabulary must no longer match, got: $class"
unset ORCH_SOFTBLOCK_PATTERNS

# --- patterns: pipe-separated env list parses correctly --------------------
ORCH_SOFTBLOCK_PATTERNS='alpha-block|beta-block'
class=$(classify_agent_pane_body "alpha-block triggered upstream")
[ "$class" = "soft_blocked" ] || fail "pipe-separated env patterns must classify soft_blocked, got: $class"
class=$(classify_agent_pane_body "no marker in this pane")
[ "$class" = "idle" ] || fail "non-matching body must classify idle even with pipe-separated env, got: $class"
unset ORCH_SOFTBLOCK_PATTERNS

# --- classify_agent_pane <file> reads from disk ----------------------------
fixture="$TEST_TMP/soft_blocked.pane"
printf '%s\n' "$softblock_body" > "$fixture"
class=$(classify_agent_pane "$fixture")
[ "$class" = "soft_blocked" ] || fail "classify_agent_pane <file> must classify the file body, got: $class"

# --- excerpt helper returns the matching line -----------------------------
excerpt=$(agent_softblock_match_excerpt "$softblock_body")
case "$excerpt" in
  *"Recommendation for the dispatcher"*) : ;;
  *) fail "excerpt should carry the matching line, got: $excerpt" ;;
esac

# --- intervention queue: file is created with header on first append ------
queue="$TEST_TMP/intervention_queue.md"
agent_softblock_append_intervention "$queue" agent-007 240 "blocker: README" "dispatch fix to agent-001"
grep -q '^# ORDO intervention queue$' "$queue" || fail "queue must carry the canonical header on first write"
grep -q '^| timestamp | agent | ticket | blocker_excerpt | recommended_action |$' "$queue" \
  || fail "queue must declare the markdown table header"
last_row=$(grep -E '^\| 20' "$queue" | tail -n1)
case "$last_row" in
  *"| agent-007 |"*) : ;;
  *) fail "queue row must include the agent column, got: $last_row" ;;
esac
case "$last_row" in
  *"| 240 |"*) : ;;
  *) fail "queue row must include the ticket column, got: $last_row" ;;
esac
case "$last_row" in
  *"blocker: README"*) : ;;
  *) fail "queue row must include the blocker excerpt, got: $last_row" ;;
esac

# Second append must NOT re-emit the header.
agent_softblock_append_intervention "$queue" agent-008 268 "out of scope" "release agent-008"
header_count=$(grep -c '^# ORDO intervention queue$' "$queue")
[ "$header_count" -eq 1 ] || fail "queue header must remain unique across appends, count=$header_count"
row_count=$(grep -cE '^\| 20[0-9][0-9]-' "$queue")
[ "$row_count" -eq 2 ] || fail "queue must accumulate two data rows after two appends, got: $row_count"

# --- pipe characters in excerpts must not break the markdown table --------
agent_softblock_append_intervention "$queue" agent-009 999 "weird | pipe | excerpt" "remediate"
last_row=$(tail -n1 "$queue")
case "$last_row" in
  *"weird / pipe / excerpt"*) : ;;
  *) fail "pipe characters in excerpts must be sanitized, got: $last_row" ;;
esac

printf 'ok - lib/agent_softblock.sh classifier + intervention queue\n'
