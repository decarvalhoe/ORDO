#!/usr/bin/env bash
# tests/test_collision_aware_decomposer.sh — pins the collision-aware
# dispatch decomposer (#771).
#
# Verifies:
#   - decompose_on_collision returns the three documented decisions
#     (no-collision / defer-collision / auto-split-needed) for the
#     respective fixture shapes from the issue body.
#   - When an auto-split is needed, two structured sub-issue payloads
#     are emitted (independent + colliding), with disjoint scope_files,
#     proper labels (auto-split-child / auto-split-followup, parent:#N,
#     blocked-on:open_pr:#PR or blocked-on:ticket:#T fallback), titles
#     that reference the parent, and bodies whose Acceptance Criteria
#     bullets are filtered to the child's scope (atomize-quality intent).
#   - Pure helpers (intersect / diff / union / colliding_claims) behave
#     deterministically on edge inputs (empty arrays, multi-agent claims).
#
# Run: timeout 120 bash tests/test_collision_aware_decomposer.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)

cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }

command -v jq >/dev/null 2>&1 || fail "jq is required to run this test"

# shellcheck source=../lib/collision_aware_decomposer.sh
source "$ROOT/lib/collision_aware_decomposer.sh"

# Pinned timestamp so sub-issue trailers are deterministic across runs.
export COLLISION_AWARE_NOW="2026-05-20T23:45:00Z"

# ---------------------------------------------------------------------------
# Case 1: pure helpers — union / intersect / diff on the canonical fixture.
# ---------------------------------------------------------------------------

claims_canonical=$(jq -cn '{
  "agent-A": {
    agent: "agent-A", ticket: "999", branch: "feat/issue-999",
    scope_files: ["a", "x", "y"],
    open_pr: "1234"
  }
}')

union=$(collision_aware_union_claim_files "$claims_canonical")
[ "$(jq -r '. | sort | join(",")' <<<"$union")" = "a,x,y" ] \
  || fail "union_claim_files canonical: got $union"

inter=$(collision_aware_intersect_arrays '["a","b","c"]' '["a","x","y"]')
[ "$(jq -r '. | sort | join(",")' <<<"$inter")" = "a" ] \
  || fail "intersect_arrays canonical: got $inter"

diff=$(collision_aware_diff_arrays '["a","b","c"]' '["a","x","y"]')
[ "$(jq -r '. | sort | join(",")' <<<"$diff")" = "b,c" ] \
  || fail "diff_arrays canonical: got $diff"

# Edge: empty inputs.
[ "$(collision_aware_union_claim_files '{}')" = "[]" ] \
  || fail "union_claim_files empty: got $(collision_aware_union_claim_files '{}')"
[ "$(collision_aware_intersect_arrays '[]' '[]')" = "[]" ] \
  || fail "intersect_arrays empty"
[ "$(collision_aware_diff_arrays '[]' '["a"]')" = "[]" ] \
  || fail "diff_arrays empty minuend"
[ "$(jq -r '. | sort | join(",")' <<<"$(collision_aware_diff_arrays '["a","b"]' '[]')")" = "a,b" ] \
  || fail "diff_arrays empty subtrahend"

# Multi-agent union dedupes across agents.
claims_multi=$(jq -cn '{
  "agent-A": {scope_files: ["a", "x"]},
  "agent-B": {scope_files: ["x", "z"]}
}')
union_multi=$(collision_aware_union_claim_files "$claims_multi")
[ "$(jq -r '. | sort | join(",")' <<<"$union_multi")" = "a,x,z" ] \
  || fail "union_claim_files multi-agent: got $union_multi"

pass "pure helpers (union/intersect/diff)"

# ---------------------------------------------------------------------------
# Case 2: no collision -> decision=no-collision, sub_issues=[].
# ---------------------------------------------------------------------------

issue_no_collision=$(jq -cn '{
  number: 800,
  title: "feat(x): no collision example",
  body: "## Allowed files (operator-scope)\n\nscope_files=foo bar\n\n## Acceptance Criteria\n\n- [ ] foo: covered\n- [ ] bar: covered\n",
  scope_files: ["foo", "bar"],
  labels: [{name: "theme:queue-starvation"}, {name: "priority-2"}]
}')

claims_unrelated=$(jq -cn '{
  "agent-A": {agent: "agent-A", ticket: "777", branch: "feat/issue-777", scope_files: ["unrelated/path.sh"], open_pr: "5555"}
}')

out_no_collision=$(decompose_on_collision "$issue_no_collision" "$claims_unrelated")
[ "$(jq -r '.decision' <<<"$out_no_collision")" = "no-collision" ] \
  || fail "no-collision decision wrong: got $(jq -r '.decision' <<<"$out_no_collision")"
[ "$(jq -r '.sub_issues | length' <<<"$out_no_collision")" = "0" ] \
  || fail "no-collision should emit no sub_issues"
[ "$(jq -r '.colliding_files | length' <<<"$out_no_collision")" = "0" ] \
  || fail "no-collision colliding_files must be empty"
[ "$(jq -r '.independent_files | sort | join(",")' <<<"$out_no_collision")" = "bar,foo" ] \
  || fail "no-collision independent_files must equal scope_files"

pass "decision: no-collision (sub_issues empty, fallback to direct dispatch)"

# ---------------------------------------------------------------------------
# Case 3: full collision -> decision=defer-collision, sub_issues=[].
# ---------------------------------------------------------------------------

issue_full_collision=$(jq -cn '{
  number: 801,
  title: "feat(x): full collision example",
  body: "## Allowed files\n\nscope_files=foo bar\n",
  scope_files: ["foo", "bar"],
  labels: []
}')

claims_full=$(jq -cn '{
  "agent-A": {agent: "agent-A", ticket: "999", branch: "feat/issue-999", scope_files: ["foo", "bar", "baz"], open_pr: "1234"}
}')

out_full=$(decompose_on_collision "$issue_full_collision" "$claims_full")
[ "$(jq -r '.decision' <<<"$out_full")" = "defer-collision" ] \
  || fail "defer-collision decision wrong: got $(jq -r '.decision' <<<"$out_full")"
[ "$(jq -r '.sub_issues | length' <<<"$out_full")" = "0" ] \
  || fail "defer-collision should emit no sub_issues"
[ "$(jq -r '.independent_files | length' <<<"$out_full")" = "0" ] \
  || fail "defer-collision independent_files must be empty"
[ "$(jq -r '.colliding_files | sort | join(",")' <<<"$out_full")" = "bar,foo" ] \
  || fail "defer-collision colliding_files must equal scope_files"

pass "decision: defer-collision (sub_issues empty, fallback to current defer behavior)"

# ---------------------------------------------------------------------------
# Case 4: canonical mixed split (the fixture from the issue body).
# Issue scope=[a,b,c], active claim=[a,x,y] -> independent=[b,c], colliding=[a].
# Emits 2 sub-issues with proper labels + parent ref.
# ---------------------------------------------------------------------------

issue_canonical_body='## Finding

Two-agent collision scenario.

## Allowed files (operator-scope)

scope_files=a b c

## Acceptance Criteria

- [ ] a: file-a is updated end-to-end
- [ ] b: file-b is updated end-to-end
- [ ] c: file-c is updated end-to-end
- [ ] general bullet without file reference must be dropped from filtered children
'

issue_canonical=$(jq -cn --arg body "$issue_canonical_body" '{
  number: 771,
  title: "feat(supervisor): collision-aware dispatch decomposer",
  body: $body,
  scope_files: ["a", "b", "c"],
  labels: [
    {name: "theme:queue-starvation"},
    {name: "priority-2"},
    {name: "needs-atomization"}
  ],
  url: "https://example.test/issues/771"
}')

out_canonical=$(decompose_on_collision "$issue_canonical" "$claims_canonical")

[ "$(jq -r '.decision' <<<"$out_canonical")" = "auto-split-needed" ] \
  || fail "canonical decision wrong: got $(jq -r '.decision' <<<"$out_canonical")"
[ "$(jq -r '.independent_files | sort | join(",")' <<<"$out_canonical")" = "b,c" ] \
  || fail "canonical independent_files != [b,c]: got $(jq -c '.independent_files' <<<"$out_canonical")"
[ "$(jq -r '.colliding_files | join(",")' <<<"$out_canonical")" = "a" ] \
  || fail "canonical colliding_files != [a]: got $(jq -c '.colliding_files' <<<"$out_canonical")"
[ "$(jq -r '.sub_issues | length' <<<"$out_canonical")" = "2" ] \
  || fail "canonical must emit exactly 2 sub_issues"

# Disjoint scope guarantees (non-duplicate atomize intent).
indep_scope=$(jq -c '.sub_issues[] | select(.kind=="independent") | .scope_files' <<<"$out_canonical")
coll_scope=$(jq -c '.sub_issues[] | select(.kind=="colliding") | .scope_files' <<<"$out_canonical")
[ "$indep_scope" = '["b","c"]' ] || fail "independent sub_issue scope_files != [b,c]: got $indep_scope"
[ "$coll_scope" = '["a"]' ] || fail "colliding sub_issue scope_files != [a]: got $coll_scope"
overlap=$(jq -cn --argjson a "$indep_scope" --argjson b "$coll_scope" '$a | map(select(. as $x | $b | index($x)))')
[ "$overlap" = "[]" ] || fail "independent + colliding scope must be disjoint: overlap=$overlap"

# Titles reference the parent and the kind. The em-dash separator is the
# rendered form expected by the dispatch brief renderer (UTF-8 safe).
indep_title=$(jq -r '.sub_issues[] | select(.kind=="independent") | .title' <<<"$out_canonical")
coll_title=$(jq -r '.sub_issues[] | select(.kind=="colliding") | .title' <<<"$out_canonical")
case "$indep_title" in
  *"independent module (auto-split from #771 for parallel dispatch)"*) ;;
  *) fail "independent title format unexpected: $indep_title" ;;
esac
case "$coll_title" in
  *"colliding follow-up (auto-split from #771, blocked on PR #1234)"*) ;;
  *) fail "colliding title format unexpected: $coll_title" ;;
esac

# Labels: theme:* and priority-* inherited; auto-split-* + parent:#N added;
# blocked-on:open_pr:#1234 only on colliding child.
indep_labels=$(jq -c '.sub_issues[] | select(.kind=="independent") | .labels' <<<"$out_canonical")
coll_labels=$(jq -c '.sub_issues[] | select(.kind=="colliding") | .labels' <<<"$out_canonical")

for required in "theme:queue-starvation" "priority-2" "auto-split-child" "parent:#771"; do
  jq -e --arg l "$required" 'index($l)' <<<"$indep_labels" >/dev/null \
    || fail "independent labels missing $required: got $indep_labels"
done
jq -e 'index("auto-split-followup") and index("parent:#771") and index("blocked-on:open_pr:#1234")' <<<"$coll_labels" >/dev/null \
  || fail "colliding labels missing auto-split-followup/parent/blocked-on: got $coll_labels"
# 'needs-atomization' is not theme:* / priority-* and must NOT be inherited.
jq -e 'index("needs-atomization") | not' <<<"$indep_labels" >/dev/null \
  || fail "independent labels must not inherit non-theme/priority labels: got $indep_labels"

# Bodies: Acceptance Criteria filtered to the child's files; parent
# filiation trailer present; "Parent: #771" appears verbatim.
indep_body=$(jq -r '.sub_issues[] | select(.kind=="independent") | .body' <<<"$out_canonical")
coll_body=$(jq -r '.sub_issues[] | select(.kind=="colliding") | .body' <<<"$out_canonical")

grep -q "Parent: #771" <<<"$indep_body" || fail "independent body missing 'Parent: #771' trailer"
grep -q "Parent: #771" <<<"$coll_body" || fail "colliding body missing 'Parent: #771' trailer"
grep -q "Auto-split: 2026-05-20T23:45:00Z" <<<"$indep_body" || fail "independent body missing pinned Auto-split timestamp"

# Independent body must keep bullets for files b and c, drop bullet for a
# and the general bullet that does not reference any in-scope file.
grep -q 'file-b is updated end-to-end' <<<"$indep_body" \
  || fail "independent body must keep AC bullet for file b"
grep -q 'file-c is updated end-to-end' <<<"$indep_body" \
  || fail "independent body must keep AC bullet for file c"
grep -q 'file-a is updated end-to-end' <<<"$indep_body" \
  && fail "independent body must NOT carry AC bullet for file a"
grep -q 'general bullet without file reference' <<<"$indep_body" \
  && fail "independent body must drop AC bullets that reference no in-scope file"

# Colliding body keeps the file-a bullet only.
grep -q 'file-a is updated end-to-end' <<<"$coll_body" \
  || fail "colliding body must keep AC bullet for file a"
grep -q 'file-b is updated end-to-end' <<<"$coll_body" \
  && fail "colliding body must NOT carry AC bullet for file b"

# Rewritten scope_files line points at the child subset.
grep -q '^scope_files=b c$' <<<"$indep_body" \
  || fail "independent body must rewrite scope_files= to 'b c': got body=\n$indep_body"
grep -q '^scope_files=a$' <<<"$coll_body" \
  || fail "colliding body must rewrite scope_files= to 'a': got body=\n$coll_body"

# colliding_claims envelope surfaces the conflicting agent + shared_files
# and propagates open_pr verbatim.
[ "$(jq -r '.colliding_claims[0].agent' <<<"$out_canonical")" = "agent-A" ] \
  || fail "colliding_claims[0].agent != agent-A"
[ "$(jq -r '.colliding_claims[0].shared_files | sort | join(",")' <<<"$out_canonical")" = "a" ] \
  || fail "colliding_claims[0].shared_files != [a]"
[ "$(jq -r '.colliding_claims[0].open_pr' <<<"$out_canonical")" = "1234" ] \
  || fail "colliding_claims[0].open_pr != 1234"

# sub_issues[colliding].blocked_on must surface both open_pr and tickets.
[ "$(jq -r '.sub_issues[] | select(.kind=="colliding") | .blocked_on.open_pr' <<<"$out_canonical")" = "1234" ] \
  || fail "colliding sub_issue blocked_on.open_pr missing"
[ "$(jq -r '.sub_issues[] | select(.kind=="colliding") | .blocked_on.tickets | join(",")' <<<"$out_canonical")" = "999" ] \
  || fail "colliding sub_issue blocked_on.tickets must contain owning ticket 999"

pass "decision: auto-split-needed (canonical fixture: scope=[a,b,c] vs claim=[a,x,y])"

# ---------------------------------------------------------------------------
# Case 5: fallback when claim has no open_pr -> use blocked-on:ticket:#N
# and include the ticket in the colliding sub-issue title.
# ---------------------------------------------------------------------------

claims_no_pr=$(jq -cn '{
  "agent-B": {agent: "agent-B", ticket: "555", branch: "feat/issue-555", scope_files: ["a"]}
}')

out_no_pr=$(decompose_on_collision "$issue_canonical" "$claims_no_pr")
[ "$(jq -r '.decision' <<<"$out_no_pr")" = "auto-split-needed" ] \
  || fail "no-pr fallback: expected auto-split-needed"

coll_labels_no_pr=$(jq -c '.sub_issues[] | select(.kind=="colliding") | .labels' <<<"$out_no_pr")
jq -e 'index("blocked-on:ticket:#555")' <<<"$coll_labels_no_pr" >/dev/null \
  || fail "no-pr fallback: colliding labels must include blocked-on:ticket:#555, got $coll_labels_no_pr"
jq -e '[.[] | select(startswith("blocked-on:open_pr:"))] | length == 0' <<<"$coll_labels_no_pr" >/dev/null \
  || fail "no-pr fallback: colliding labels must not invent a blocked-on:open_pr entry, got $coll_labels_no_pr"

coll_title_no_pr=$(jq -r '.sub_issues[] | select(.kind=="colliding") | .title' <<<"$out_no_pr")
case "$coll_title_no_pr" in
  *"blocked on #555"*) ;;
  *) fail "no-pr fallback: colliding title must reference owning ticket, got $coll_title_no_pr" ;;
esac

pass "fallback: blocked-on:ticket:#N when claim has no open_pr"

# ---------------------------------------------------------------------------
# Case 6: multi-agent collision -- two in-flight agents each touching a
# different file in the parent scope. Both must surface in colliding_claims
# and the colliding sub-issue must list both owning tickets.
# ---------------------------------------------------------------------------

claims_multi_collide=$(jq -cn '{
  "agent-A": {agent: "agent-A", ticket: "100", branch: "feat/issue-100", scope_files: ["a"], open_pr: "1010"},
  "agent-B": {agent: "agent-B", ticket: "200", branch: "feat/issue-200", scope_files: ["b"]}
}')

issue_multi=$(jq -cn '{
  number: 802,
  title: "feat(x): multi-agent collision",
  body: "## Allowed files\n\nscope_files=a b c\n\n## Acceptance Criteria\n\n- [ ] a, b, c addressed\n",
  scope_files: ["a", "b", "c"],
  labels: [{name: "theme:queue-starvation"}]
}')

out_multi=$(decompose_on_collision "$issue_multi" "$claims_multi_collide")
[ "$(jq -r '.decision' <<<"$out_multi")" = "auto-split-needed" ] \
  || fail "multi-agent: expected auto-split-needed"
[ "$(jq -r '.independent_files | join(",")' <<<"$out_multi")" = "c" ] \
  || fail "multi-agent independent_files != [c]"
[ "$(jq -r '.colliding_files | sort | join(",")' <<<"$out_multi")" = "a,b" ] \
  || fail "multi-agent colliding_files != [a,b]"
[ "$(jq -r '.colliding_claims | length' <<<"$out_multi")" = "2" ] \
  || fail "multi-agent colliding_claims must surface both agents"

coll_tickets_multi=$(jq -r '.sub_issues[] | select(.kind=="colliding") | .blocked_on.tickets | sort | join(",")' <<<"$out_multi")
[ "$coll_tickets_multi" = "100,200" ] \
  || fail "multi-agent colliding sub_issue blocked_on.tickets must list both owning tickets, got $coll_tickets_multi"

pass "multi-agent: colliding_claims surfaces every conflicting in-flight ticket"

# ---------------------------------------------------------------------------
# Case 7: defensive — missing scope_files in parent yields no-collision.
# (Caller is expected to validate the parent has scope_files before
# invoking the decomposer; we just confirm the function does not crash
# and emits the documented decision shape.)
# ---------------------------------------------------------------------------

issue_no_scope=$(jq -cn '{number: 900, title: "no scope", body: "(empty)", scope_files: []}')
out_no_scope=$(decompose_on_collision "$issue_no_scope" "$claims_canonical")
[ "$(jq -r '.decision' <<<"$out_no_scope")" = "no-collision" ] \
  || fail "empty-scope parent must yield no-collision decision"
[ "$(jq -r '.sub_issues | length' <<<"$out_no_scope")" = "0" ] \
  || fail "empty-scope parent must emit no sub_issues"

pass "defensive: empty parent scope yields no-collision"

printf '\nALL TESTS PASS\n'
