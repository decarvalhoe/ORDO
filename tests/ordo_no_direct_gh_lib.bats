#!/usr/bin/env bats
# tests/ordo_no_direct_gh_lib.bats — #816 guard: no direct `gh` invocation in
# lib/ outside the github provider backend.
#
# Every lib/ call site talks to the forge through `ordo_provider`
# (lib/ordo_provider_adapter.sh). The only file allowed to run gh is
# lib/ordo_provider_adapter_github.sh, plus:
#   - lib/external_mutation_gate.sh: `command gh "$@"` in
#     external_pr_mutation_run, the gh-aware second gate the github backend
#     runs every mutation through (adapters.md, "Mutation policy" step 4);
#   - the TODO(#816) sites listed below: reads for which the adapter has no
#     op yet, each guarded so non-github adapters degrade to "unknown".
# The counts are pinned: a new direct call anywhere fails this test; a
# migrated TODO site must be removed from the allowlist (lower counts fail
# too, on purpose — keep the list honest).

load './helpers.bash'

setup() {
  setup_orch_test
  TK="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export TK
}

# file<TAB>count of matching lines
read -r -d '' ORDO_DIRECT_GH_ALLOWLIST <<'ALLOW' || true
lib/external_mutation_gate.sh	1
lib/ci_external_blockers.sh	1
lib/governance_check.sh	3
lib/gh_pr_files_batch.sh	3
ALLOW

# Lines that invoke gh: `gh <topic>`, `command gh`, `gh "$@"`, `"$X_GH_BIN"`,
# or the retired wrappers gh_retry / run_gh. Comments and message strings
# (dry_run_note, printf, echo, audit) are not invocations.
scan_direct_gh() {
  cd "$TK" || return 1
  grep -nE '(^|[^A-Za-z0-9_./"'"'"'$-])(command[[:space:]]+)?gh[[:space:]]+(api|pr|issue|repo|run|auth|label|release|search|workflow|"\$@")|"\$\{?[A-Za-z_]*GH_BIN\}?"[[:space:]]|\bgh_retry\b|\brun_gh\b' lib/*.sh \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(dry_run_note|printf|echo|audit)[[:space:]]' \
    | grep -v '^lib/ordo_provider_adapter_github.sh:'
}

@test "no lib/ file outside the github backend invokes gh directly (#816)" {
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

@test "every allowlisted TODO site is marked TODO(#816) and guarded by the adapter name (#816)" {
  local file
  for file in lib/ci_external_blockers.sh lib/governance_check.sh lib/gh_pr_files_batch.sh; do
    grep -q 'TODO(#816)' "$TK/$file" || { echo "missing TODO(#816) marker in $file" >&2; false; }
    grep -q 'ordo_provider_adapter_name' "$TK/$file" || { echo "$file must guard its gh fallback on the active adapter" >&2; false; }
  done
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
