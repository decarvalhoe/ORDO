#!/usr/bin/env bats
# tests/ordo_no_direct_gh_scripts.bats — #816/#818 guard: no direct `gh`
# invocation in scripts/*.sh, full stop.
#
# Every forge call of scripts/ goes through `ordo_provider <op>`
# (lib/ordo_provider_adapter.sh). The github backend is the only place that
# runs `gh`. The allowlist below is EMPTY since #818 added the last missing
# ops (label_list, repo_list, workflow_list, branch_protection_get,
# check_annotations, run_get --with log); it stays as the place to register
# a temporary exception, which must carry a `TODO(#<issue>): needs op`
# marker in the script and disappear with that issue.

load './helpers.bash'

setup() {
  setup_orch_test
  TK="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export TK
}

# file<TAB>distinctive substring of the allowed line (empty: no exception)
read -r -d '' ORDO_DIRECT_GH_ALLOWLIST <<'EOF' || true
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

@test "no scripts/*.sh invokes gh directly (#816, #818: allowlist empty)" {
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

@test "the allowlist is empty and no TODO(#816) marker survives in scripts/ or lib/ (#818)" {
  [ -z "$(printf '%s' "$ORDO_DIRECT_GH_ALLOWLIST" | tr -d '[:space:]')" ]
  local afile asub
  while IFS=$'\t' read -r afile asub; do
    [ -n "$afile" ] || continue
    grep -qF -- "$asub" "$TK/$afile" || {
      echo "allowlisted site no longer present, remove it from the list: $afile: $asub" >&2
      false
    }
    grep -q 'TODO(#[0-9]*): needs' "$TK/$afile" || {
      echo "allowlisted file has no TODO marker: $afile" >&2
      false
    }
  done <<< "$ORDO_DIRECT_GH_ALLOWLIST"
  ! grep -rn 'TODO(#816)' "$TK/scripts" "$TK/lib" 2>/dev/null
}

@test "the inline _provider_backend_available helper is gone: scripts call ordo_provider_backend_available (#818)" {
  ! grep -ln '^_provider_backend_available()' "$TK"/scripts/*.sh
  local script
  for script in agent_product_switch.sh brief_agents.sh agent_pool_status.sh dispatch_ticket.sh smart_poll_agents.sh; do
    grep -q 'ordo_provider_backend_available' "$TK/scripts/$script" || { echo "$script does not call ordo_provider_backend_available" >&2; false; }
  done
  grep -q '^ordo_provider_backend_available()' "$TK/lib/ordo_provider_adapter.sh"
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
