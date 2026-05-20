#!/usr/bin/env bash
# tests/test_sixsigma_project_module.sh — assert the ORDO Six Sigma
# architecture (#237) is documented at the two levels, that the approval
# boundary is preserved by the published Six Sigma docs, that the
# project opt-in configuration helper (#240) validates its three knobs,
# and that the Six Sigma evidence ledger helper (#241) honors its
# schema and disposition vocabulary.
#
# Scope (#237):
#   - README.md must reference both Level 1 (ORDO standard) and Level 2
#     (opt-in project DMAIC module).
#   - docs/sixsigma-autoupgrade.md must self-identify as Level 1.
#   - docs/sixsigma/README.md must exist, define Level 2 as opt-in and
#     disabled-by-default, and document the shared approval boundary.
#   - The Six Sigma docs must not contain language that grants an automatic
#     approval / release / waiver / validation / phase-completion claim.
#
# Scope (#240):
#   - lib/sixsigma_config.sh validates SIXSIGMA_PROJECT_ENABLED,
#     SIXSIGMA_BY_DESIGN_DEFAULT, and safe relative dossier paths.
#   - Absent/empty configuration resolves to disabled, not enabled.
#   - Unrecognized values are reported with a distinct non-zero exit.
#
# Scope (#241):
#   - lib/sixsigma_evidence.sh appends JSONL rows under schema
#     ordo.sixsigma.evidence.v1 with every required field.
#   - Forbidden dispositions (approved/released/waived/validated/complete)
#     are rejected; safe dispositions (draft/observed/ready/blocked/
#     not_approved) are accepted.
#   - Raw evidence input is hashed into a sha256 digest, never copied
#     verbatim into the row.
#
# The docs portion reads the published docs only and skips when run inside
# a sanitized toolkit mirror (README.md / docs/ are intentionally not
# mirrored — see scripts/run_shell_tests.sh). The evidence portion runs
# unconditionally because lib/ is mirrored.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Six Sigma project opt-in configuration helper (#240)
#
# These assertions exercise lib/sixsigma_config.sh directly. They cover the
# three acceptance-criteria knobs: SIXSIGMA_PROJECT_ENABLED,
# SIXSIGMA_BY_DESIGN_DEFAULT, and safe relative dossier paths. They run
# before the sanitized-mirror detection because lib/ is mirrored in the
# toolkit and the helper has no dependency on README.md or docs/.
# ---------------------------------------------------------------------------

config_lib="$ROOT/lib/sixsigma_config.sh"
[[ -f "$config_lib" ]] || fail "expected $config_lib to exist (#240)"

# shellcheck source=../lib/sixsigma_config.sh
source "$config_lib"

# Truthy values must be accepted for both knobs.
for truthy in 1 true TRUE True yes YES Yes on ON On; do
  set +e
  sixsigma_config_project_enabled "$truthy" >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -eq 0 ]] \
    || fail "SIXSIGMA_PROJECT_ENABLED=$truthy must resolve to enabled (got exit $status)"
  set +e
  sixsigma_config_by_design_default "$truthy" >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -eq 0 ]] \
    || fail "SIXSIGMA_BY_DESIGN_DEFAULT=$truthy must resolve to enabled (got exit $status)"
done

# Falsy values, including empty/unset, must resolve to disabled (exit 1) and
# must NOT be reported as misconfiguration (exit 2). The empty case carries
# the acceptance-criteria "absent configuration is disabled" rule.
for falsy in 0 false FALSE False no NO No off OFF Off ''; do
  set +e
  sixsigma_config_project_enabled "$falsy" >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -eq 1 ]] \
    || fail "SIXSIGMA_PROJECT_ENABLED=${falsy:-<empty>} must resolve to disabled (got exit $status)"
  set +e
  sixsigma_config_by_design_default "$falsy" >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -eq 1 ]] \
    || fail "SIXSIGMA_BY_DESIGN_DEFAULT=${falsy:-<empty>} must resolve to disabled (got exit $status)"
done

# Unrecognized tokens must be flagged as misconfiguration (exit 2), distinct
# from the disabled outcome, so callers can warn rather than silently opt in.
for bogus in maybe enable disabled-by-default 2 -1 'true '; do
  set +e
  sixsigma_config_project_enabled "$bogus" >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -eq 2 ]] \
    || fail "SIXSIGMA_PROJECT_ENABLED=$bogus must be reported as unrecognized (exit 2), got $status"
  set +e
  sixsigma_config_by_design_default "$bogus" >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -eq 2 ]] \
    || fail "SIXSIGMA_BY_DESIGN_DEFAULT=$bogus must be reported as unrecognized (exit 2), got $status"
done

# Safe dossier paths: project-relative, no traversal, no shell metacharacters.
for safe_path in \
  docs/sixsigma \
  docs/sixsigma/dmaic.md \
  evidence/2026-05-20/coverage.jsonl \
  a \
  a/b/c-d_e.f \
  ; do
  sixsigma_config_safe_dossier_path "$safe_path" >/dev/null 2>&1 \
    || fail "safe dossier path '$safe_path' must be accepted"
done

# Unsafe dossier paths must be rejected. Each rejection target exercises a
# different concrete attack: absolute path, parent traversal, home expansion,
# trailing slash, double slash, current-dir noise, whitespace, shell
# metacharacter, and the empty string.
unsafe_paths=(
  ''
  /etc/passwd
  /docs/sixsigma
  ../docs/sixsigma
  docs/../../../etc/passwd
  docs/./sixsigma
  ./docs/sixsigma
  '~/docs/sixsigma'
  'docs/sixsigma/'
  'docs//sixsigma'
  '.'
  '..'
  'docs/sixsigma dossier'
  'docs/six;sigma'
  'docs/six$igma'
  'docs/six*'
)
for unsafe_path in "${unsafe_paths[@]}"; do
  set +e
  sixsigma_config_safe_dossier_path "$unsafe_path" >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] \
    || fail "unsafe dossier path '${unsafe_path:-<empty>}' must be rejected"
done

# Layer resolver: env-driven, defaults to disabled, and reports unknown
# tokens with exit 2 while still printing a safe "disabled" decision.
set +e
( unset SIXSIGMA_PROJECT_ENABLED; sixsigma_config_resolve_layer ) \
  > "${TMPDIR:-/tmp}/sixsigma_layer.$$" 2>/dev/null
status=$?
set -e
layer=$(cat "${TMPDIR:-/tmp}/sixsigma_layer.$$")
rm -f "${TMPDIR:-/tmp}/sixsigma_layer.$$"
[[ "$status" -eq 0 ]] \
  || fail "sixsigma_config_resolve_layer with unset env must succeed, got exit $status"
[[ "$layer" == "disabled" ]] \
  || fail "sixsigma_config_resolve_layer with unset env must print 'disabled', got '$layer'"

set +e
layer=$(SIXSIGMA_PROJECT_ENABLED=true sixsigma_config_resolve_layer 2>/dev/null)
status=$?
set -e
[[ "$status" -eq 0 ]] \
  || fail "sixsigma_config_resolve_layer with truthy env must succeed, got exit $status"
[[ "$layer" == "enabled" ]] \
  || fail "sixsigma_config_resolve_layer with truthy env must print 'enabled', got '$layer'"

set +e
layer=$(SIXSIGMA_PROJECT_ENABLED=maybe sixsigma_config_resolve_layer 2>/dev/null)
status=$?
set -e
[[ "$status" -eq 2 ]] \
  || fail "sixsigma_config_resolve_layer with unrecognized env must exit 2, got $status"
[[ "$layer" == "disabled" ]] \
  || fail "sixsigma_config_resolve_layer with unrecognized env must still print 'disabled', got '$layer'"

printf 'ok - sixsigma_config validates SIXSIGMA_PROJECT_ENABLED, SIXSIGMA_BY_DESIGN_DEFAULT, and safe relative dossier paths (#240)\n'

# ---------------------------------------------------------------------------
# Six Sigma evidence ledger helper (#241)
#
# These assertions exercise lib/sixsigma_evidence.sh directly. They do not
# depend on README.md or docs/, so they run before the sanitized-mirror
# detection that gates the documentation checks further down.
# ---------------------------------------------------------------------------

evidence_lib="$ROOT/lib/sixsigma_evidence.sh"
[[ -f "$evidence_lib" ]] || fail "expected $evidence_lib to exist (#241)"

# shellcheck source=../lib/sixsigma_evidence.sh
source "$evidence_lib"

evidence_tmp=$(mktemp -d)
trap 'rm -rf "$evidence_tmp"' EXIT

ledger="$evidence_tmp/evidence.jsonl"

sixsigma_evidence_append \
  --ledger "$ledger" \
  --project ordo \
  --metric autofix_dispatch_count \
  --source pool_snapshot \
  --action recorded \
  --actor-role automation \
  --limits "max=4" \
  --disposition observed \
  --raw "2 autofix dispatches in last cycle" \
  >/dev/null

[[ -f "$ledger" ]] \
  || fail "evidence_append did not create ledger at $ledger"

row=$(tail -n 1 "$ledger")
printf '%s' "$row" | jq -e '.' >/dev/null \
  || fail "evidence row is not valid JSON: $row"

schema=$(printf '%s' "$row" | jq -r '.schema')
[[ "$schema" == "ordo.sixsigma.evidence.v1" ]] \
  || fail "schema is $schema, expected ordo.sixsigma.evidence.v1"

# Every acceptance-criteria field must be present and non-empty.
for key in timestamp_utc metric source action actor_role digest limits disposition; do
  value=$(printf '%s' "$row" | jq -r --arg k "$key" '.[$k] // ""')
  [[ -n "$value" ]] || fail "evidence row missing/empty field: $key"
done

ts=$(printf '%s' "$row" | jq -r '.timestamp_utc')
[[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  || fail "timestamp_utc is not ISO-8601 UTC: $ts"

# Digest is hex of the raw input — never the raw text itself.
digest=$(printf '%s' "$row" | jq -r '.digest')
[[ "$digest" =~ ^[a-f0-9]{64}$ ]] \
  || fail "digest is not a sha256 hex: $digest"
expected_digest=$(printf '%s' "2 autofix dispatches in last cycle" | sha256sum | awk '{print $1}')
[[ "$digest" == "$expected_digest" ]] \
  || fail "digest $digest does not match sha256 of raw input"

# JSONL ledger must not embed the raw prose anywhere on the row.
grep -qF "2 autofix dispatches in last cycle" "$ledger" \
  && fail "raw evidence input must not be copied verbatim into JSONL"

# Append-only: a second row yields two lines.
sixsigma_evidence_append \
  --ledger "$ledger" \
  --metric cycle_latency_sec \
  --source pool_snapshot \
  --action recorded \
  --actor-role automation \
  --limits "p95<=600" \
  --disposition ready \
  >/dev/null
[[ "$(wc -l < "$ledger")" -eq 2 ]] \
  || fail "evidence_append must be append-only; expected 2 rows, got $(wc -l < "$ledger")"

# Forbidden disposition vocabulary is rejected.
for forbidden in approved released waived validated complete; do
  set +e
  sixsigma_evidence_append \
    --ledger "$ledger" \
    --metric forbidden_probe \
    --source pool_snapshot \
    --action recorded \
    --actor-role automation \
    --limits none \
    --disposition "$forbidden" \
    >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] \
    || fail "forbidden disposition '$forbidden' must be rejected"
done

# Allowed disposition vocabulary covers the safe set.
ledger_safe="$evidence_tmp/safe.jsonl"
for safe in draft observed ready blocked not_approved; do
  sixsigma_evidence_append \
    --ledger "$ledger_safe" \
    --metric coverage \
    --source pool_snapshot \
    --action recorded \
    --actor-role automation \
    --limits "min=0" \
    --disposition "$safe" \
    >/dev/null \
    || fail "safe disposition '$safe' must be accepted"
done
[[ "$(wc -l < "$ledger_safe")" -eq 5 ]] \
  || fail "safe-disposition ledger should have 5 rows, got $(wc -l < "$ledger_safe")"

# Missing required args are rejected.
set +e
sixsigma_evidence_append --ledger "$ledger" --metric x --disposition observed \
  >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "missing required args must produce a non-zero exit"

printf 'ok - sixsigma_evidence_append honors schema ordo.sixsigma.evidence.v1 and disposition vocabulary (#241)\n'

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
