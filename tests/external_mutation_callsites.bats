#!/usr/bin/env bats

# external_mutation_callsites.bats — Rule 11 tripwire.
#
# Scans `lib/` and `scripts/` for raw external GitHub mutation invocations
# (gh / run_gh / gh_retry against pr|issue {merge,comment,edit,review,ready,
# close,reopen,create}) and compares the per-(file, signature) count against
# the baseline at `tests/fixtures/external_mutation_callsite_baseline.tsv`.
#
# Contract:
#   - New (file, signature) pairs not in the baseline FAIL the test. The PR
#     author must either route the new call through external_pr_mutation_assert
#     (or external_pr_mutation_run, which classifies and asserts internally)
#     and add the call site to the baseline, or remove the raw call entirely.
#   - Higher counts for an existing (file, signature) pair FAIL the test —
#     same reason as above.
#   - Lower counts (raw call sites migrated to the gate) PASS without baseline
#     update; bumping the baseline is a follow-up cleanup.

load './helpers.bash'

setup() {
  setup_orch_test
  TK="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export TK
}

scan_current_callsites() {
  cd "$TK" || return 1
  grep -rEn '\b(gh|run_gh|gh_retry)[[:space:]]+(pr|issue)[[:space:]]+(merge|comment|edit|review|ready|close|reopen|create)\b' \
    lib/ scripts/ 2>/dev/null \
    | awk -F: '
      {
        line = $0;
        if (line ~ /dry_run_note/) next;
        # Skip the gate library itself (its docstring intentionally mentions the patterns).
        if ($1 == "lib/external_mutation_gate.sh") next;
        # Skip pure comment lines.
        if (line ~ /^[^:]+:[0-9]+:[[:space:]]*#/) next;
        match(line, /(gh|run_gh|gh_retry)[[:space:]]+(pr|issue)[[:space:]]+(merge|comment|edit|review|ready|close|reopen|create)/);
        sig = substr(line, RSTART, RLENGTH);
        gsub(/[[:space:]]+/, " ", sig);
        print $1 "\t" sig;
      }
    ' \
    | sort | uniq -c \
    | awk 'BEGIN{OFS="\t"}
      {
        cnt = $1;
        # Reconstruct file<TAB>sig: skip the leading count and whitespace,
        # keep the rest verbatim so the embedded tab survives.
        rest = $0;
        sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", rest);
        print cnt, rest;
      }'
}

@test "external_mutation_gate library exists and exposes the public surface" {
  local gate="$TK/lib/external_mutation_gate.sh"
  [ -f "$gate" ]
  for fn in external_pr_mutation_known_scopes \
            external_pr_mutation_scope_known \
            external_pr_mutation_authorized \
            external_pr_mutation_assert \
            external_pr_mutation_classify_gh \
            external_pr_mutation_classify_gh_args \
            external_pr_mutation_run \
            record_local_gate_evidence; do
    grep -q "^${fn}()" "$gate" || {
      echo "missing public function: $fn" >&2
      false
    }
  done
}

@test "audit_log.sh exposes audit_external_mutation for gate signal aggregation" {
  grep -q '^audit_external_mutation()' "$TK/lib/audit_log.sh"
}

@test "dispatch_ticket.sh sources the gate and asserts before its issue assignee mutation" {
  grep -q 'source "$TK/lib/external_mutation_gate.sh"' "$TK/scripts/dispatch_ticket.sh"
  # The assignee mutation must be preceded (in source order, no intervening
  # mutation) by external_pr_mutation_assert with scope issue_assignees.
  local section
  section=$(awk '/^assign_ticket_if_requested\(\)/,/^\}/' "$TK/scripts/dispatch_ticket.sh")
  [[ "$section" == *"external_pr_mutation_assert issue_assignees"* ]]
  # Sanity: the assert appears before the gh issue edit invocation in this function.
  local assert_line edit_line
  assert_line=$(printf '%s\n' "$section" | grep -n 'external_pr_mutation_assert issue_assignees' | head -1 | cut -d: -f1)
  edit_line=$(printf '%s\n' "$section" | grep -n 'gh issue edit' | tail -1 | cut -d: -f1)
  [ -n "$assert_line" ] && [ -n "$edit_line" ]
  [ "$assert_line" -lt "$edit_line" ]
}

@test "no new raw external-mutation call sites slip past the gate (#289)" {
  local baseline_file="$TK/tests/fixtures/external_mutation_callsite_baseline.tsv"
  [ -f "$baseline_file" ] || {
    echo "baseline missing: $baseline_file" >&2
    false
  }

  local current
  current=$(scan_current_callsites)

  # Build associative arrays from baseline (expected) and current (observed).
  declare -A expected observed
  while IFS=$'\t' read -r cnt file sig; do
    [ -n "$file" ] || continue
    expected["$file"$'\t'"$sig"]=$cnt
  done < "$baseline_file"

  while IFS=$'\t' read -r cnt file sig; do
    [ -n "$file" ] || continue
    observed["$file"$'\t'"$sig"]=$cnt
  done <<< "$current"

  local violations=()
  local key
  for key in "${!observed[@]}"; do
    local exp=${expected[$key]:-0}
    local obs=${observed[$key]}
    if [ "$obs" -gt "$exp" ]; then
      violations+=("UP   ${exp}->${obs}  ${key}")
    fi
  done

  if [ "${#violations[@]}" -gt 0 ]; then
    {
      printf 'Rule 11 tripwire: new or growing raw external-mutation call sites detected.\n'
      printf '  %s\n' "${violations[@]}"
      printf 'Wrap with external_pr_mutation_assert (or external_pr_mutation_run), then update %s.\n' \
        "tests/fixtures/external_mutation_callsite_baseline.tsv"
    } >&2
    false
  fi
}

@test "covers merge / comment / edit / label / assignee paths through the classifier" {
  local audit_log gate
  audit_log=$(toolkit_file lib/audit_log.sh)
  toolkit_file lib/log_bounds.sh >/dev/null
  toolkit_file lib/config_check.sh >/dev/null
  gate=$(toolkit_file lib/external_mutation_gate.sh)

  # The five operations called out in issue #289's "Validation or POC plan".
  declare -A expect=(
    ["pr merge"]=pr_merge
    ["pr comment"]=pr_comment
    ["pr edit"]=pr_edit
    ["pr edit-label"]=pr_labels
    ["pr edit-assignee"]=pr_assignees
  )

  # merge / comment / edit
  for pair in "pr merge" "pr comment" "pr edit"; do
    local topic=${pair% *}
    local action=${pair#* }
    run bash -lc "$(orch_env_exports)
      source '$audit_log'
      source '$gate'
      external_pr_mutation_classify_gh $topic $action
    "
    [ "$status" -eq 0 ]
    [ "$output" = "${expect[$pair]}" ]
  done

  # label / assignee (refined classifier)
  run bash -lc "$(orch_env_exports)
    source '$audit_log'
    source '$gate'
    external_pr_mutation_classify_gh_args pr edit 12 --repo o/r --add-label needs-review
  "
  [ "$status" -eq 0 ]
  [ "$output" = "pr_labels" ]

  run bash -lc "$(orch_env_exports)
    source '$audit_log'
    source '$gate'
    external_pr_mutation_classify_gh_args pr edit 12 --repo o/r --add-assignee me
  "
  [ "$status" -eq 0 ]
  [ "$output" = "pr_assignees" ]
}
