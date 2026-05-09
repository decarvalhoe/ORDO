#!/usr/bin/env bash
# tests/test_sixsigma_project_module.sh — assert the ORDO Six Sigma
# architecture (#237) is documented at the two levels, and that the
# approval boundary is preserved by the published Six Sigma docs.
#
# Scope (atomic to #237):
#   - README.md must reference both Level 1 (ORDO standard) and Level 2
#     (opt-in project DMAIC module).
#   - docs/sixsigma-autoupgrade.md must self-identify as Level 1.
#   - docs/sixsigma/README.md must exist, define Level 2 as opt-in and
#     disabled-by-default, and document the shared approval boundary.
#   - The Six Sigma docs must not contain language that grants an automatic
#     approval / release / waiver / validation / phase-completion claim.
#
# This test reads the published docs only; it does not run any Six Sigma
# CLI and does not require ORDO state. It is intentionally cheap so it can
# be part of every shell-test run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

# detect_real_repo_root: when run_shell_tests.sh / run_bats.sh sanitize the
# toolkit into a temporary mirror, README.md, PRODUCT.md, and docs/ are
# intentionally not mirrored (see docs/dispatch-planning.md, "Aggregate vs
# Isolated Bats Runs"). Tests that assert against those files must detect
# the sanitized-mirror context and skip rather than fail. The companion
# bats helper is in tests/docs_generator_smoke.bats; this is the .sh
# equivalent for shell tests run through scripts/run_shell_tests.sh.
detect_real_repo_root() {
  local candidate="${ORCH_TOOLKIT_ROOT:-$ROOT}"
  if [[ -n "$candidate" && -f "$candidate/README.md" && -d "$candidate/docs" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

if ! repo=$(detect_real_repo_root); then
  printf 'ok - sixsigma project module docs check skipped in sanitized-mirror context (#237)\n'
  exit 0
fi

readme="$repo/README.md"
level1_doc="$repo/docs/sixsigma-autoupgrade.md"
level2_doc="$repo/docs/sixsigma/README.md"

for f in "$readme" "$level1_doc" "$level2_doc"; do
  [[ -f "$f" ]] || fail "expected $f to exist"
done

# --- README references both levels ----------------------------------------

grep -Eq 'Level 1.*ORDO standard' "$readme" \
  || fail "README must define Level 1 as ORDO standard"
grep -Eq 'Level 2.*([Oo]pt-in|DMAIC)' "$readme" \
  || fail "README must define Level 2 as opt-in / DMAIC"
grep -qF 'docs/sixsigma/README.md' "$readme" \
  || fail "README must link to docs/sixsigma/README.md"
grep -qF 'docs/sixsigma-autoupgrade.md' "$readme" \
  || fail "README must link to docs/sixsigma-autoupgrade.md"

# --- Level 1 doc self-identifies as Level 1 -------------------------------

grep -Eq 'Level 1' "$level1_doc" \
  || fail "Level 1 doc must declare itself as Level 1"
grep -Eiq '(mandatory|standard)' "$level1_doc" \
  || fail "Level 1 doc must state that Level 1 is mandatory / standard"
grep -qF 'docs/sixsigma/README.md' "$level1_doc" \
  || fail "Level 1 doc must point to the Level 2 architecture page"

# --- Level 2 doc defines opt-in module + approval boundary ----------------

grep -Eq 'Level 2' "$level2_doc" \
  || fail "Level 2 doc must declare itself as Level 2"
grep -Eiq '[Oo]pt-in' "$level2_doc" \
  || fail "Level 2 doc must mark the project DMAIC module as opt-in"
grep -Eiq 'disabled by default' "$level2_doc" \
  || fail "Level 2 doc must state that the module is disabled by default"
grep -Eq 'DMAIC' "$level2_doc" \
  || fail "Level 2 doc must reference DMAIC"
grep -Eiq 'approval boundary' "$level2_doc" \
  || fail "Level 2 doc must document the approval boundary"

# --- Approval boundary: no automatic approval/release/waiver/validation ---
# The Six Sigma docs may quote the words RELEASED, APPROVED, WAIVED,
# VALIDATED, or PHASE COMPLETE only in negated / NOT-prefixed contexts
# (for example "NOT RELEASED"). They must never assert one of these as the
# operative status of generated Six Sigma evidence. The regex below catches
# the affirmative form: the keyword at start-of-token, optionally preceded
# by markdown/punctuation, and not preceded by "NOT ", "not ", or "no ".

approval_violation() {
  local doc=$1
  # The affirmative operative-status claim is always rendered as an
  # ALL-CAPS keyword (RELEASED, APPROVED, WAIVED, VALIDATED, PHASE
  # COMPLETE). Any occurrence on a line that does not contain a negation
  # token scoping it ("NOT", "must not", "never", "cannot", "without",
  # "refuse" / "refused" / "refuses", or the documented "must not appear"
  # phrase used to forbid the keyword itself) is a violation.
  awk '
    /(RELEASED|APPROVED|WAIVED|VALIDATED|PHASE COMPLETE|PHASE-COMPLETE)/ {
      line = $0
      if (line ~ /NOT |must not|never|cannot|without|refuse[sd]?|disabled by default/) next
      print NR ": " $0
    }
  ' "$doc"
}

for doc in "$level1_doc" "$level2_doc"; do
  hits=$(approval_violation "$doc" || true)
  if [[ -n "$hits" ]]; then
    printf 'approval-boundary violation in %s:\n%s\n' "$doc" "$hits" >&2
    fail "approval boundary breach in $(basename "$doc"); see stderr"
  fi
done

# --- Neutrality: Six Sigma docs must not embed live-topology identifiers --
# Catch obvious provider/repo/host/account/path leaks. The list mirrors
# the existing csv_dev_mode test's neutrality expectation.

neutrality_violation() {
  local doc=$1
  grep -nE '://|@[A-Za-z0-9_.-]+\.[A-Za-z]{2,}|[0-9]{1,3}(\.[0-9]{1,3}){3}' "$doc" || true
}

for doc in "$level1_doc" "$level2_doc"; do
  hits=$(neutrality_violation "$doc")
  if [[ -n "$hits" ]]; then
    printf 'neutrality violation in %s:\n%s\n' "$doc" "$hits" >&2
    fail "neutrality breach in $(basename "$doc"); see stderr"
  fi
done

printf 'ok - sixsigma project module docs honor Level 1/Level 2 split and approval boundary\n'
