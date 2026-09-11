#!/usr/bin/env bats
# tests/ordo_no_direct_gh_lib.bats — #816/#818 guard: no direct `gh` invocation in
# lib/ outside the github provider backend.
#
# Every lib/ call site talks to the forge through `ordo_provider`
# (lib/ordo_provider_adapter.sh). Exactly two files may run gh, and both are
# infrastructure of the boundary, not call sites:
#   - lib/ordo_provider_adapter_github.sh: the github backend itself;
#   - lib/external_mutation_gate.sh: `command gh "$@"` in
#     external_pr_mutation_run, the gh-aware second gate the github backend
#     runs every mutation through (adapters.md, "Mutation policy" step 4).
#     It is excluded by the scanner for that reason (rationale: the gate
#     re-classifies the actual gh arguments before they leave the process;
#     moving it would remove the double gate, not a call site).
# The allowlist below is EMPTY since #818 added the last missing ops
# (branch_protection_get, check_annotations, pr_files_batch, pr_review); a
# new direct call anywhere fails this test. A temporary exception must be
# listed here with its count AND carry a `TODO(#<issue>)` marker guarded on
# `ordo_provider_adapter_name` in the file.

load './helpers.bash'

setup() {
  setup_orch_test
  TK="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export TK
}

# file<TAB>count of matching lines (empty: no exception)
read -r -d '' ORDO_DIRECT_GH_ALLOWLIST <<'ALLOW' || true
ALLOW

# Lines that invoke gh: `gh <topic>`, `command gh`, `gh "$@"`, `"$X_GH_BIN"`,
# or the retired wrappers gh_retry / run_gh. Comments and message strings
# (dry_run_note, printf, echo, audit) are not invocations.
scan_direct_gh() {
  cd "$TK" || return 1
  grep -nE '(^|[^A-Za-z0-9_./"'"'"'$-])(command[[:space:]]+)?gh[[:space:]]+(api|pr|issue|repo|run|auth|label|release|search|workflow|"\$@")|"\$\{?[A-Za-z_]*GH_BIN\}?"[[:space:]]|\bgh_retry\b|\brun_gh\b' lib/*.sh \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(dry_run_note|printf|echo|audit)[[:space:]]' \
    | grep -v '^lib/ordo_provider_adapter_github.sh:' \
    | grep -v '^lib/external_mutation_gate.sh:[0-9]*:[[:space:]]*command gh "\$@"$'
}

@test "no lib/ file outside the github backend and the gate invokes gh directly (#816, #818: allowlist empty)" {
  local offenders
  offenders=$(scan_direct_gh | awk -F: '{print $1}' | sort | uniq -c | awk '{print $2 "\t" $1}' | sort)
  local expected
  expected=$(printf '%s\n' "$ORDO_DIRECT_GH_ALLOWLIST" | sort)
  if [ "$offenders" != "$expected" ]; then
    echo "direct gh invocations in lib/ differ from the #816 allowlist" >&2
    echo "--- expected (file<TAB>count)" >&2
    echo "$expected" >&2
    echo "--- observed" >&2
    echo "$offenders" >&2
    echo "--- lines" >&2
    scan_direct_gh >&2
    false
  fi
}

@test "the allowlist is empty and no TODO(#816) marker or adapter-name guard survives in lib/ (#818)" {
  [ -z "$(printf '%s' "$ORDO_DIRECT_GH_ALLOWLIST" | tr -d '[:space:]')" ]
  ! grep -rn 'TODO(#816)' "$TK/lib" 2>/dev/null
  # The former guarded sites read through the adapter now, whatever the forge.
  local file
  for file in lib/ci_external_blockers.sh lib/governance_check.sh lib/gh_pr_files_batch.sh; do
    ! grep -q '"$(ordo_provider_adapter_name)" = "github"' "$TK/$file"
  done
  grep -q 'ordo_provider check_annotations' "$TK/lib/ci_external_blockers.sh"
  grep -q 'branch_protection_get' "$TK/lib/governance_check.sh"
  grep -q 'ordo_provider pr_files_batch' "$TK/lib/gh_pr_files_batch.sh"
  grep -q 'pr_review "\$PR"' "$TK/lib/pr_merge.sh"
}

@test "the github backend is the only lib/ file that runs gh for the provider ops (#816)" {
  # Sanity: the backend does invoke gh (the allowlist above is not vacuous).
  grep -qE 'run_with_timeout gh ' "$TK/lib/ordo_provider_adapter_github.sh"
  # The gate's single gh line is the one documented in adapters.md.
  [ "$(grep -c 'command gh "\$@"' "$TK/lib/external_mutation_gate.sh")" -eq 1 ]
}

@test "migrated libs source the provider adapter instead of gh helpers (#816)" {
  local file
  for file in lib/pr_merge.sh lib/governance_check.sh lib/ci_external_blockers.sh lib/env_diagnostics.sh \
              lib/autonomous_pr_ops.sh lib/blocker_issue_registry.sh lib/gh_pr_files_batch.sh; do
    grep -q 'ordo_provider_adapter.sh' "$TK/$file" || { echo "$file does not load the provider adapter" >&2; false; }
  done
  # Lazy loaders (sourced by many scripts) keep the same dependency.
  for file in lib/recovery_context.sh lib/github_identity.sh lib/gh_body_helpers.sh; do
    grep -q '_require_provider()' "$TK/$file" || { echo "$file lacks its lazy adapter loader" >&2; false; }
  done
  # Retired knobs must not come back (comments may still name them).
  ! grep -hE 'ORCH_GH_BIN|GH_BODY_HELPERS_GH_BIN|ORCH_GITHUB_IDENTITY_GH_BIN' "$TK"/lib/*.sh | grep -vqE '^[[:space:]]*#'
}
