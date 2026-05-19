#!/usr/bin/env bash
# Issue #723: closure_acceptance_gate library unit tests.
#
# Covers the four classifier outcomes (pass, operator-override,
# scaffold-declared, refused) plus two negative-shape cases:
#   - source issue has no DoD bullets at all (pass, gate disabled)
#   - acceptance block exists but lacks artifact markers (refused)
#
# The fixtures are loosely modelled on the PR #775 audit table: each
# scenario captures one of the failure patterns the gate must distinguish.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/closure_acceptance.sh
source "$ROOT/lib/closure_acceptance.sh"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local got=$1
  local want=$2
  local label=$3
  [[ "$got" == "$want" ]] || fail "$label: want '$want', got '$got'"
}

# Shared source-issue body with a UAT-style DoD section.
uat_issue_body=$(cat <<'EOF'
## Summary

Hard-gate test failing on develop; ship the fix and prove it.

## Acceptance Criteria

- [ ] Hard-gate test re-runs clean against the merged commit.
- [ ] Widget renders on every V2 surface listed in the audit.

## Out of scope

- Reopening the prior closures.
EOF
)

routine_issue_body=$(cat <<'EOF'
## Summary

Routine cleanup with no UAT checklist.

## Notes

No DoD enumerated.
EOF
)

# 1. PASS: fenced acceptance block with artifact pointers covering both DoD
# bullets.
pass_pr_body=$(cat <<'EOF'
Closes #800

```acceptance
- Hard-gate test pass — artifact: run-id:hg-2026-05-19-a91
- Widget renders — evidence: https://audit.test/v2-surfaces/2026-05-19/screens.html
```
EOF
)
got=$(closure_acceptance_classify "$pass_pr_body" "$uat_issue_body" 800)
assert_eq "$got" "pass" "pass case"

# 2. OPERATOR-OVERRIDE: explicit operator-authorized close trailer.
override_pr_body=$(cat <<'EOF'
Closes #801 (operator-authorized: @ops-lead deploy-window-cover-2026-05-19)

Body is otherwise empty.
EOF
)
got=$(closure_acceptance_classify "$override_pr_body" "$uat_issue_body" 801)
assert_eq "$got" "operator-override" "operator-override case"

# Cross-issue trailers must not be honoured for a different issue number.
mismatch=$(closure_acceptance_classify "$override_pr_body" "$uat_issue_body" 802)
[[ "$mismatch" != "operator-override" ]] \
  || fail "operator-override must be scoped to the matching issue number"

# 3. SCAFFOLD-DECLARED: PR declares scaffold-only and points at a follow-up
# issue; closing the parent must be refused (treated as a non-close outcome).
scaffold_pr_body=$(cat <<'EOF'
Closes #803

Acceptance: scaffold-only; live-validation tracked in #999.
EOF
)
got=$(closure_acceptance_classify "$scaffold_pr_body" "$uat_issue_body" 803)
assert_eq "$got" "scaffold-declared:#999" "scaffold-declared case"

# 4. REFUSED: DoD bullets present but no acceptance block, no override, no
# scaffold declaration. This is the lazy-validation pattern from PR #775.
lazy_pr_body=$(cat <<'EOF'
Closes #804

Adds the implementation. No proof block.
EOF
)
got=$(closure_acceptance_classify "$lazy_pr_body" "$uat_issue_body" 804)
assert_eq "$got" "refused" "refused (missing acceptance proof) case"

# 5. NO-DOD pass-through: source issue has no UAT DoD section; the gate must
# not block routine cleanup closures.
got=$(closure_acceptance_classify "$lazy_pr_body" "$routine_issue_body" 805)
assert_eq "$got" "pass" "pass when source issue has no DoD bullets"

# 6. Refused when block exists but lacks any artifact markers.
empty_block_pr_body=$(cat <<'EOF'
Closes #806

```acceptance
- did the thing
- also did the other thing
```
EOF
)
got=$(closure_acceptance_classify "$empty_block_pr_body" "$uat_issue_body" 806)
assert_eq "$got" "refused" "refused when block has no artifact markers"

# Decision-helper contract: should_close is true iff outcome is pass or
# operator-override; everything else must be refused.
closure_acceptance_should_close "pass" \
  || fail "should_close must accept pass"
closure_acceptance_should_close "operator-override" \
  || fail "should_close must accept operator-override"
! closure_acceptance_should_close "refused" \
  || fail "should_close must refuse refused"
! closure_acceptance_should_close "scaffold-declared:#999" \
  || fail "should_close must refuse scaffold-declared (parent close)"
! closure_acceptance_should_close "unknown" \
  || fail "should_close must refuse unknown outcomes"

# Refusal-reason tokens are stable strings the audit row can rely on.
assert_eq "$(closure_acceptance_refusal_reason "refused")" \
  "missing-acceptance-proof" "refusal_reason: refused"
assert_eq "$(closure_acceptance_refusal_reason "scaffold-declared:#999")" \
  "scaffold-declared follow_up=#999" "refusal_reason: scaffold-declared"
assert_eq "$(closure_acceptance_refusal_reason "operator-override")" \
  "operator-override" "refusal_reason: operator-override"
assert_eq "$(closure_acceptance_refusal_reason "pass")" \
  "pass" "refusal_reason: pass"

printf 'ok - closure_acceptance gate classifies pass/override/scaffold/refused\n'
