#!/usr/bin/env bash
# Issue #721: scope-claim ledger lifecycle.
#
# When dispatch_ticket promotes an assignment the brief's `Fichiers
# autorises` block is captured in $(state_dir)/scope_claims.json. While
# the claim is live:
#   - dispatch_plan must emit a `conflict-with:#<ticket>` signal AND a
#     `conflict_with: [<ticket>]` JSON field for any open issue whose
#     declared scope_files overlap the claim.
#   - brief_agents must pre-inject the claimed scope_files into a
#     sibling brief's forbidden_files block.
# When post_merge_cleanup clears the assignment after a PR merge the
# claim is released and the conflict signal disappears on the next plan
# run.
#
# The lib helpers in dispatch_capacity.sh are the contract the three
# scripts share, so we exercise them directly to keep the test
# hermetic, then verify the three integration touch points via narrow
# fixture-driven flows.

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

export ORCH_STATE_BASE="$TEST_TMP/state"
export ORCH_LOG_DIR="$TEST_TMP/logs"
mkdir -p "$ORCH_STATE_BASE" "$ORCH_LOG_DIR"

# Minimal stand-in for state_dir() so we can drive dispatch_capacity.sh
# helpers without sourcing the full audit_log.sh chain.
state_dir() {
  local d="$ORCH_STATE_BASE/$PROJECT"
  mkdir -p "$d"
  printf '%s' "$d"
}

PROJECT="scope-claims-test"
# shellcheck source=../lib/dispatch_capacity.sh
source "$ROOT/lib/dispatch_capacity.sh"

# ---------------------------------------------------------------------------
# 1) Record / list / release lifecycle.
# ---------------------------------------------------------------------------

dispatch_capacity_scope_claims_record agent-001 100 $'scripts/foo.sh\nlib/foo.sh'
dispatch_capacity_scope_claims_record agent-002 200 'docs/foo.md'

ledger="$(dispatch_capacity_scope_claims_path)"
[[ -s "$ledger" ]] || fail "ledger not written: $ledger"

jq -e '
  (.["100"].agent == "agent-001")
  and (.["100"].scope_files | length == 2)
  and (.["100"].scope_files | index("scripts/foo.sh"))
  and (.["100"].scope_files | index("lib/foo.sh"))
  and (.["200"].agent == "agent-002")
  and (.["200"].scope_files == ["docs/foo.md"])
' "$ledger" >/dev/null \
  || fail "ledger content wrong: $(cat "$ledger")"

active_files=$(dispatch_capacity_scope_claims_active_files | sort)
expected="docs/foo.md
lib/foo.sh
scripts/foo.sh"
[[ "$active_files" == "$expected" ]] \
  || fail "active files mismatch — got: $active_files"

# Skip own ticket when computing forbidden-files for an in-flight brief.
own_excluded=$(dispatch_capacity_scope_claims_active_files 100 | sort)
[[ "$own_excluded" == "docs/foo.md" ]] \
  || fail "own-ticket exclusion failed: $own_excluded"

# Empty scope is a silent no-op — record nothing, leave the ledger
# untouched.
dispatch_capacity_scope_claims_record agent-003 300 '   '
jq -e '. | has("300") | not' "$ledger" >/dev/null \
  || fail "empty scope_files should not create a claim row"

# Conflict detection: an issue whose scope_files overlap an active
# claim must list every overlapping ticket and skip self-overlap.
conflicts=$(dispatch_capacity_scope_claims_conflicting_tickets \
  $'scripts/foo.sh\ndocs/foo.md' 999 | paste -sd, -)
[[ "$conflicts" == "100,200" ]] \
  || fail "conflict tickets mismatch — got: $conflicts"

# Glob overlap: a wildcard in the candidate scope must collide with a
# matching claim path.
glob_conflicts=$(dispatch_capacity_scope_claims_conflicting_tickets \
  'lib/*.sh' 555 | paste -sd, -)
[[ "$glob_conflicts" == "100" ]] \
  || fail "glob conflict mismatch — got: $glob_conflicts"

# Directory-prefix overlap: an issue claiming `scripts/` should be
# flagged as conflicting with the literal `scripts/foo.sh` claim.
dir_conflicts=$(dispatch_capacity_scope_claims_conflicting_tickets \
  'scripts/' 777 | paste -sd, -)
[[ "$dir_conflicts" == "100" ]] \
  || fail "directory-prefix conflict mismatch — got: $dir_conflicts"

# Self-claim must NOT appear in the conflict list — re-rendering the
# same ticket's brief should never collide with its own claim.
self_check=$(dispatch_capacity_scope_claims_conflicting_tickets \
  'scripts/foo.sh' 100 | paste -sd, -)
[[ -z "$self_check" ]] \
  || fail "self-claim leaked into conflict list — got: $self_check"

# Release-by-ticket clears the row; remaining claims are untouched.
dispatch_capacity_scope_claims_release_by_ticket 100
jq -e '. | has("100") | not' "$ledger" >/dev/null \
  || fail "ticket 100 was not released from ledger"
jq -e '.["200"].agent == "agent-002"' "$ledger" >/dev/null \
  || fail "ticket 200 was lost when releasing ticket 100"

# Released claim must no longer drive a conflict signal.
post_release=$(dispatch_capacity_scope_claims_conflicting_tickets \
  'scripts/foo.sh' 999 | paste -sd, -)
[[ -z "$post_release" ]] \
  || fail "released claim still triggers a conflict — got: $post_release"

# Releasing an unknown ticket is a silent no-op.
dispatch_capacity_scope_claims_release_by_ticket 999

# ---------------------------------------------------------------------------
# 2) dispatch_plan integration: with a live claim the planner must emit
#    `conflict-with:#<ticket>` on the conflicting ready issue's signals
#    list AND surface the conflicting ticket number in JSON output.
# ---------------------------------------------------------------------------

dispatch_capacity_scope_claims_record agent-001 100 'lib/foo.sh'

SANITIZED_ROOT="$TEST_TMP/toolkit"
mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/bin" "$TEST_TMP/logs"

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/dispatch_plan.sh

chmod +x "$SANITIZED_ROOT/scripts/dispatch_plan.sh"

cat > "$TEST_TMP/plan.config.sh" <<EOF
PROJECT="$PROJECT"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
EOF

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"label list"* )
    cat <<'JSON'
[
  {"name":"priority:P1"},
  {"name":"priority:P2"}
]
JSON
    ;;
  *"pr list"* )
    printf '%s\n' '[]'
    ;;
  *"issue list"* )
    cat <<'JSON'
[
  {"number":601,"title":"Sibling needing lib/foo.sh","labels":[{"name":"priority:P1"}],"assignees":[],"body":"Scope files:\n- lib/foo.sh\n- lib/bar.sh","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/601"},
  {"number":602,"title":"Unrelated work","labels":[{"name":"priority:P2"}],"assignees":[],"body":"Scope files:\n- docs/unrelated.md","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/602"}
]
JSON
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

plan_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/plan.config.sh" --json
)

jq -e '
  (map(select(.issue == 601 and (.signals | index("conflict-with:#100")) and (.signals | index("scope-claim-conflict")) and (.conflict_with | index(100)))) | length == 1)
  and (map(select(.issue == 602 and ((.signals // []) | index("conflict-with:#100") | not) and ((.conflict_with // []) | length == 0))) | length == 1)
' <<<"$plan_output" >/dev/null \
  || fail "dispatch_plan did not emit conflict_with for ticket 601: $plan_output"

# Strip claim — the conflict signal must vanish.
dispatch_capacity_scope_claims_release_by_ticket 100

plan_output_released=$(
  PATH="$TEST_TMP/bin:$PATH" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/plan.config.sh" --json
)
jq -e '
  all(.[]; ((.signals // []) | index("scope-claim-conflict") | not))
  and all(.[]; ((.conflict_with // []) | length) == 0)
' <<<"$plan_output_released" >/dev/null \
  || fail "released claim should drop all conflict signals: $plan_output_released"

# ---------------------------------------------------------------------------
# 3) brief_agents integration: when an in-flight sibling claim exists,
#    its scope_files must show up in the rendered brief's
#    `Fichiers interdits` block — without the current ticket's own
#    claim leaking in.
# ---------------------------------------------------------------------------

dispatch_capacity_scope_claims_record agent-001 800 'lib/sibling.sh'

BRIEF_ROOT="$TEST_TMP/brief-toolkit"
mkdir -p "$BRIEF_ROOT"
sanitize_toolkit_copy "$BRIEF_ROOT" \
  scripts/brief_agents.sh \
  templates/dispatch-canonical.md.tpl

chmod +x "$BRIEF_ROOT/scripts/brief_agents.sh"

cat > "$TEST_TMP/brief.config.sh" <<EOF
PROJECT="$PROJECT"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
SUPERVISOR_REPO="orchestrator"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
EOF

brief_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  bash "$BRIEF_ROOT/scripts/brief_agents.sh" \
    "$TEST_TMP/brief.config.sh" claude 801 \
    "scope_files=docs/new.md" \
    "summary=Add docs for ticket 801" \
    "branch_slug=feat/ticket-801" \
    "ticket_title=ticket 801"
)

grep -F "lib/sibling.sh" <<<"$brief_output" >/dev/null \
  || fail "sibling scope_files not injected into forbidden_files: $brief_output"

# Self-ticket pre-existing claim (re-render of the same ticket) must NOT
# inject its own scope into forbidden_files.
dispatch_capacity_scope_claims_record agent-claude 801 'docs/new.md'
brief_self_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  bash "$BRIEF_ROOT/scripts/brief_agents.sh" \
    "$TEST_TMP/brief.config.sh" claude 801 \
    "scope_files=docs/new.md" \
    "summary=Add docs for ticket 801" \
    "branch_slug=feat/ticket-801" \
    "ticket_title=ticket 801"
)
# Extract the forbidden_files block (between `Fichiers interdits` and
# the next `- Interdictions absolues` marker) to verify the OWN claim
# was excluded — `docs/new.md` would otherwise appear in the forbidden
# block as a self-conflict.
forbidden_block=$(awk '
  /- Fichiers interdits:/ { in_block = 1; next }
  /- Interdictions absolues:/ { in_block = 0 }
  in_block { print }
' <<<"$brief_self_output")
if grep -F "docs/new.md" <<<"$forbidden_block" >/dev/null; then
  fail "self-ticket scope leaked into forbidden_files block: $forbidden_block"
fi

# Opt-out: ORCH_BRIEF_INJECT_SCOPE_CLAIMS=0 must suppress the injection
# entirely.
brief_optout=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_BRIEF_INJECT_SCOPE_CLAIMS=0 \
  bash "$BRIEF_ROOT/scripts/brief_agents.sh" \
    "$TEST_TMP/brief.config.sh" claude 801 \
    "scope_files=docs/new.md" \
    "summary=Add docs for ticket 801" \
    "branch_slug=feat/ticket-801" \
    "ticket_title=ticket 801"
)
if grep -F "lib/sibling.sh" <<<"$brief_optout" >/dev/null; then
  fail "opt-out should suppress claim injection: $brief_optout"
fi

printf 'ok - dispatch scope-claim ledger writes, releases, and surfaces conflicts end-to-end\n'
