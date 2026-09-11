#!/usr/bin/env bats
# tests/ordo_no_direct_gh_scripts.bats — #816 guard: no direct `gh`
# invocation in scripts/*.sh outside the explicitly listed TODO sites.
#
# Every forge call of scripts/ goes through `ordo_provider <op>`
# (lib/ordo_provider_adapter.sh). The github backend is the only place that
# runs `gh`. The allowlist below names the call sites that still need an
# adapter op (each carries a `TODO(#816): needs op ...` comment in the
# script and is skipped on every non-GitHub provider adapter). The target
# is an empty allowlist: remove an entry once its op exists.

load './helpers.bash'

setup() {
  setup_orch_test
  TK="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export TK
}

# file<TAB>distinctive substring of the allowed line
read -r -d '' ORDO_DIRECT_GH_ALLOWLIST <<'EOF' || true
scripts/pr_block_signals.sh	gh api "repos/${GH_REPO}/branches/${branch}/protection"
scripts/pr_block_signals.sh	gh workflow list --repo "$GH_REPO" --all
scripts/check_ci_health.sh	gh api "repos/${GH_REPO}/check-runs/${job_id}/annotations"
scripts/check_ci_health.sh	gh run view "$run_id" --repo "$GH_REPO" --log 2>/dev/null
scripts/dispatch_plan.sh	env GH_CONFIG_DIR="$GH_CONFIG_DIR" gh "$@"
scripts/portfolio_repo_bind_plan.sh	GH_CONFIG_DIR="$PORTFOLIO_GH_CONFIG_DIR" gh "$@"
scripts/portfolio_repo_bind_plan.sh	    gh "$@"
EOF

# Prints "file<TAB>line-number<TAB>line" for every direct gh invocation.
# Text-only mentions (comments, dry-run notes, printf'ed hints, quoted
# command examples, audit strings) are not invocations and are skipped.
scan_direct_gh_invocations() {
  cd "$TK" || return 1
  grep -nE '(^|[^A-Za-z0-9_./-])gh[[:space:]]+(api|pr|issue|repo|run|auth|label|release|search|workflow|gist|extension|browse|project|secret|variable|status|config|alias|"\$@")' scripts/*.sh 2>/dev/null \
    | awk -F: '
      {
        file = $1; line = $2;
        text = substr($0, length(file) + length(line) + 3);
        stripped = text; sub(/^[[:space:]]+/, "", stripped);
        if (stripped ~ /^#/) next;                       # comment line
        if (text ~ /dry_run_note|dry_note/) next;         # dry-run notes
        if (text ~ /printf|echo /) next;                 # printed hints
        if (text ~ /`gh /) next;                          # quoted examples
        if (text ~ /="gh /) next;                         # template strings
        if (text ~ /audit "/) next;                       # audit lines
        # A gh token inside a double-quoted string is a message, not a
        # call (unless it is a command substitution inside the string).
        if (match(text, /(^|[^A-Za-z0-9_.\/-])gh[[:space:]]+/)) {
          before = substr(text, 1, RSTART);
          gsub(/\\"/, "", before);
          quotes = gsub(/"/, "\"", before);
          if (quotes % 2 == 1 && before !~ /\$\($/) next;
        }
        print file "\t" line "\t" text;
      }'
}

@test "scripts/*.sh invoke gh only at the listed TODO(#816) sites" {
  local found unexpected=0 stale=0 file line text key allowed matched
  found=$(scan_direct_gh_invocations)
  while IFS=$'\t' read -r file line text; do
    [ -n "$file" ] || continue
    matched=0
    while IFS=$'\t' read -r afile asub; do
      [ -n "$afile" ] || continue
      if [ "$afile" = "$file" ] && [[ "$text" == *"$asub"* ]]; then
        matched=1
        break
      fi
    done <<< "$ORDO_DIRECT_GH_ALLOWLIST"
    if [ "$matched" -eq 0 ]; then
      echo "direct gh invocation not routed through ordo_provider: $file:$line: $text" >&2
      unexpected=$((unexpected + 1))
    fi
  done <<< "$found"
  [ "$unexpected" -eq 0 ]
}

@test "every allowlisted TODO(#816) site still exists and carries its TODO marker (shrink the list when an op lands)" {
  local afile asub
  while IFS=$'\t' read -r afile asub; do
    [ -n "$afile" ] || continue
    grep -qF -- "$asub" "$TK/$afile" || {
      echo "allowlisted site no longer present, remove it from the list: $afile: $asub" >&2
      false
    }
    grep -q 'TODO(#816): needs' "$TK/$afile" || {
      echo "allowlisted file has no TODO(#816) marker: $afile" >&2
      false
    }
  done <<< "$ORDO_DIRECT_GH_ALLOWLIST"
}

@test "every script that talks to the forge sources lib/ordo_provider_adapter.sh" {
  local script
  for script in "$TK"/scripts/*.sh; do
    grep -q 'ordo_provider ' "$script" || continue
    grep -q 'source "\$TK/lib/ordo_provider_adapter.sh"' "$script" || {
      echo "$script calls ordo_provider without sourcing lib/ordo_provider_adapter.sh" >&2
      false
    }
  done
}
