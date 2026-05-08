#!/usr/bin/env bash
# lib/docs_impact_gate.sh — classification, declaration parsing, and
# decision helpers for the documentation impact gate (#260).
#
# Provides:
#   docs_gate_classify_path <path>          — echo classification category
#   docs_gate_classify_stream               — filter: read newline-separated
#                                              paths on stdin, emit
#                                              "<category>\t<path>" lines
#   docs_gate_summarize_stream              — filter: read classified stream
#                                              on stdin, emit "<category>=<n>"
#                                              lines sorted by category
#   docs_gate_summary_has <summary> <cat>   — exit 0 if summary contains a
#                                              non-zero count for category
#   docs_gate_parse_declaration             — filter: read declaration text
#                                              on stdin, emit normalized
#                                              "outcome=<value>" /
#                                              "note=<value>" /
#                                              "followup=<value>" lines
#   docs_gate_decide <summary> <decl>       — echo decision token:
#                                              pass | warn | block
#   docs_gate_decision_reason <decision>    — echo human-readable reason
#                                              for the most recent decide call
#                                              (via DOCS_GATE_LAST_REASON)
#   docs_gate_render_evidence ...           — emit markdown evidence block
#
# Doctrine:
#   - Path classification is conservative. The first matching pattern wins.
#     An unrecognized path is treated as `internal`. Internal-only changes
#     never hard-block; they auto-pass.
#   - The gate hard-blocks only when at least one path touches a tracked
#     "user-visible surface" category AND the change neither updated docs
#     nor supplied a valid declaration.
#   - Patterns are exposed as DOCS_GATE_*_PATTERN env vars so downstream
#     projects can extend the gate without modifying the library.
#   - The library has no side effects, no I/O on disk, no network. It is
#     safe to source from CI, tests, and other scripts.

set -o pipefail

# Pattern defaults are POSIX extended regex anchored at the start of a
# repo-relative path. Order is documented in docs_gate_classify_path.
: "${DOCS_GATE_DOCS_PATTERN:=^(docs/|README\\.md$|PRODUCT\\.md$|CHANGELOG\\.md$)}"
: "${DOCS_GATE_INSTALL_PATTERN:=^(install\\.sh|scripts/repository_bootstrap\\.sh)$}"
: "${DOCS_GATE_ONBOARDING_PATTERN:=^(scripts/(guided_onboarding|onboarding_verification|fleet_provisioning|fleet_sizing|host_assessment|project_meta_context|project_scaffold)\\.sh|lib/(host_assessment|fleet_sizing|fleet_provisioning)\\.sh)$}"
: "${DOCS_GATE_DISPATCH_PATTERN:=^scripts/(dispatch_|preempt_|brief_|integrate_wave|orch_|cycle).*\\.sh$}"
: "${DOCS_GATE_INTEGRATION_PATTERN:=^(scripts/(pr_merge|post_merge_cleanup|check_ci_health|ci_autofix|gh_actions_optimize|pr_block_signals|pr_merge_wave)|lib/(pr_merge|governance_check))\\.sh$}"
: "${DOCS_GATE_PROFILE_PATTERN:=^(profiles/|examples/projects/|examples/.*\\.config\\.sh$)}"
: "${DOCS_GATE_WORKFLOW_PATTERN:=^\\.github/(workflows|ISSUE_TEMPLATE|PULL_REQUEST_TEMPLATE)/}"
: "${DOCS_GATE_CLI_PATTERN:=^scripts/.*\\.sh$}"
: "${DOCS_GATE_LIB_PATTERN:=^lib/.*\\.sh$}"
: "${DOCS_GATE_TESTS_PATTERN:=^tests/}"

# Categories that mark a path as a tracked user-visible surface, in the
# order they are reported. Internal/docs/tests are intentionally excluded.
DOCS_GATE_SURFACE_CATEGORIES=(
  installation
  onboarding
  dispatch
  integration
  profile
  workflow
  cli
  lib
)

DOCS_GATE_VALID_OUTCOMES=(docs-updated no-docs-needed follow-up blocked)

# Mutated by docs_gate_decide so callers can fetch a one-line reason.
# shellcheck disable=SC2034  # consumed by callers after sourcing
DOCS_GATE_LAST_REASON=""

docs_gate_classify_path() {
  local path="${1:?usage: docs_gate_classify_path <path>}"

  if [[ -z "$path" ]]; then
    printf 'internal\n'
    return 0
  fi

  if printf '%s' "$path" | grep -Eq "$DOCS_GATE_DOCS_PATTERN"; then
    printf 'docs\n'
    return 0
  fi
  if printf '%s' "$path" | grep -Eq "$DOCS_GATE_INSTALL_PATTERN"; then
    printf 'installation\n'
    return 0
  fi
  if printf '%s' "$path" | grep -Eq "$DOCS_GATE_ONBOARDING_PATTERN"; then
    printf 'onboarding\n'
    return 0
  fi
  if printf '%s' "$path" | grep -Eq "$DOCS_GATE_DISPATCH_PATTERN"; then
    printf 'dispatch\n'
    return 0
  fi
  if printf '%s' "$path" | grep -Eq "$DOCS_GATE_INTEGRATION_PATTERN"; then
    printf 'integration\n'
    return 0
  fi
  if printf '%s' "$path" | grep -Eq "$DOCS_GATE_PROFILE_PATTERN"; then
    printf 'profile\n'
    return 0
  fi
  if printf '%s' "$path" | grep -Eq "$DOCS_GATE_WORKFLOW_PATTERN"; then
    printf 'workflow\n'
    return 0
  fi
  if printf '%s' "$path" | grep -Eq "$DOCS_GATE_TESTS_PATTERN"; then
    printf 'tests\n'
    return 0
  fi
  if printf '%s' "$path" | grep -Eq "$DOCS_GATE_CLI_PATTERN"; then
    printf 'cli\n'
    return 0
  fi
  if printf '%s' "$path" | grep -Eq "$DOCS_GATE_LIB_PATTERN"; then
    printf 'lib\n'
    return 0
  fi
  printf 'internal\n'
}

docs_gate_classify_stream() {
  local line category
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    category=$(docs_gate_classify_path "$line")
    printf '%s\t%s\n' "$category" "$line"
  done
}

docs_gate_summarize_stream() {
  awk -F '\t' '
    NF >= 1 && $1 != "" { count[$1]++ }
    END {
      n = 0
      for (k in count) { keys[n++] = k }
      # bubble sort keeps deps minimal and result deterministic
      for (i = 0; i < n; i++) {
        for (j = i + 1; j < n; j++) {
          if (keys[j] < keys[i]) {
            tmp = keys[i]; keys[i] = keys[j]; keys[j] = tmp
          }
        }
      }
      for (i = 0; i < n; i++) {
        printf "%s=%d\n", keys[i], count[keys[i]]
      }
    }
  '
}

docs_gate_summary_has() {
  local summary="${1?usage: docs_gate_summary_has <summary> <category>}"
  local category="${2:?usage: docs_gate_summary_has <summary> <category>}"
  local count
  count=$(printf '%s\n' "$summary" \
    | awk -F '=' -v cat="$category" '$1 == cat { print $2; exit }')
  [[ -n "$count" && "$count" != "0" ]]
}

docs_gate_summary_touches_surface() {
  local summary="${1?usage: docs_gate_summary_touches_surface <summary>}"
  local cat
  for cat in "${DOCS_GATE_SURFACE_CATEGORIES[@]}"; do
    if docs_gate_summary_has "$summary" "$cat"; then
      return 0
    fi
  done
  return 1
}

# Parse a free-form declaration block. Recognized lines (case-insensitive on
# the trailer name, anchored at line start, leading whitespace trimmed):
#
#   Docs-Impact: <outcome>
#   Docs-Impact-Note: <text>            (rationale for no-docs-needed)
#   Docs-Impact-Followup: <ref>         (e.g. #123 or RBOKproject/ORDO#123)
#
# Output is a normalized stream of "<key>=<value>" lines. Keys that did not
# appear in the input are omitted. Unknown trailers are ignored.
docs_gate_parse_declaration() {
  awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function lower(s) {
      result = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c >= "A" && c <= "Z") {
          c = sprintf("%c", index("ABCDEFGHIJKLMNOPQRSTUVWXYZ", c) + 96)
        }
        result = result c
      }
      return result
    }
    BEGIN { outcome = ""; note = ""; followup = "" }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      pos = index(line, ":")
      if (pos == 0) next
      key = lower(substr(line, 1, pos - 1))
      val = trim(substr(line, pos + 1))
      if (key == "docs-impact") outcome = val
      else if (key == "docs-impact-note") note = val
      else if (key == "docs-impact-rationale") { if (note == "") note = val }
      else if (key == "docs-impact-followup") followup = val
    }
    END {
      if (outcome != "") printf "outcome=%s\n", outcome
      if (note != "") printf "note=%s\n", note
      if (followup != "") printf "followup=%s\n", followup
    }
  '
}

docs_gate_declaration_field() {
  local declaration="${1-}"
  local key="${2:?usage: docs_gate_declaration_field <decl> <key>}"
  printf '%s\n' "$declaration" \
    | awk -F '=' -v key="$key" '$1 == key { sub(/^[^=]+=/, ""); print; exit }'
}

docs_gate_outcome_is_valid() {
  local outcome="${1-}"
  local valid
  for valid in "${DOCS_GATE_VALID_OUTCOMES[@]}"; do
    if [[ "$outcome" == "$valid" ]]; then
      return 0
    fi
  done
  return 1
}

# docs_gate_decide <summary> <declaration>
#
# Prints "<decision>\t<reason>" on stdout (single line). DOCS_GATE_LAST_REASON
# is also set for callers that source the library and call decide directly
# in the same shell.
#
# Decisions:
#   pass  — gate is satisfied (internal-only, docs-updated, accepted
#           declaration)
#   warn  — declaration is missing on a surface change but docs were
#           updated in the same change; emits a soft warning so reviewers
#           still see the impact note.
#   block — surface is touched, docs were not updated, no valid
#           declaration was supplied.
docs_gate_decide() {
  local summary="${1-}"
  local declaration="${2-}"
  local outcome note followup
  outcome=$(docs_gate_declaration_field "$declaration" outcome)
  note=$(docs_gate_declaration_field "$declaration" note)
  followup=$(docs_gate_declaration_field "$declaration" followup)

  DOCS_GATE_LAST_REASON=""
  local decision=""

  if ! docs_gate_summary_touches_surface "$summary"; then
    decision=pass
    DOCS_GATE_LAST_REASON="no user-visible surface touched; docs declaration not required"
  else
    local docs_touched=0
    if docs_gate_summary_has "$summary" docs; then
      docs_touched=1
    fi

    if [[ -z "$outcome" ]]; then
      if [[ "$docs_touched" -eq 1 ]]; then
        decision=warn
        DOCS_GATE_LAST_REASON="surface touched and docs/ updated in same change but no explicit Docs-Impact declaration; treating as docs-updated with warning"
      else
        decision=block
        DOCS_GATE_LAST_REASON="surface touched without docs update and no Docs-Impact declaration"
      fi
    elif ! docs_gate_outcome_is_valid "$outcome"; then
      decision=block
      DOCS_GATE_LAST_REASON="Docs-Impact outcome '$outcome' is not one of: ${DOCS_GATE_VALID_OUTCOMES[*]}"
    else
      case "$outcome" in
        docs-updated)
          if [[ "$docs_touched" -eq 1 ]]; then
            decision=pass
            DOCS_GATE_LAST_REASON="declaration outcome=docs-updated and docs/ touched"
          else
            decision=warn
            DOCS_GATE_LAST_REASON="declaration outcome=docs-updated but no docs path detected in change"
          fi
          ;;
        no-docs-needed)
          if [[ -z "$note" ]]; then
            decision=block
            DOCS_GATE_LAST_REASON="outcome=no-docs-needed requires Docs-Impact-Note rationale"
          else
            decision=pass
            DOCS_GATE_LAST_REASON="declaration outcome=no-docs-needed with rationale recorded"
          fi
          ;;
        follow-up)
          if [[ -z "$followup" ]]; then
            decision=block
            DOCS_GATE_LAST_REASON="outcome=follow-up requires Docs-Impact-Followup issue reference"
          else
            decision=pass
            DOCS_GATE_LAST_REASON="declaration outcome=follow-up referencing $followup"
          fi
          ;;
        blocked)
          decision=block
          DOCS_GATE_LAST_REASON="declaration outcome=blocked; contributor explicitly flagged docs gap"
          ;;
      esac
    fi
  fi

  printf '%s\t%s\n' "$decision" "$DOCS_GATE_LAST_REASON"
}

docs_gate_render_evidence() {
  local decision="${1:?usage: docs_gate_render_evidence <decision> <reason> <summary> <declaration> [paths_file]}"
  local reason="${2-}"
  local summary="${3-}"
  local declaration="${4-}"
  local paths_file="${5-}"

  printf '## Documentation Impact Gate Evidence\n\n'
  # shellcheck disable=SC2016 # backticks here are literal markdown, not command substitution
  printf -- '- Decision: `%s`\n' "$decision"
  printf -- '- Reason: %s\n' "${reason:-unspecified}"
  printf -- '- Generated: %s\n\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

  printf '### Path classification summary\n\n'
  if [[ -z "$summary" ]]; then
    printf '_(no paths classified)_\n\n'
  else
    printf '| Category | Count |\n| --- | --- |\n'
    printf '%s\n' "$summary" \
      | awk -F '=' 'NF == 2 { printf "| %s | %s |\n", $1, $2 }'
    printf '\n'
  fi

  printf '### Declaration\n\n'
  if [[ -z "$declaration" ]]; then
    printf '_(no declaration supplied)_\n\n'
  else
    # shellcheck disable=SC2016 # backticks here are literal markdown fence, not command substitution
    printf '```\n%s\n```\n\n' "$declaration"
  fi

  if [[ -n "$paths_file" && -s "$paths_file" ]]; then
    printf '### Classified paths\n\n'
    printf '| Path | Category |\n| --- | --- |\n'
    while IFS=$'\t' read -r category path; do
      [[ -n "$category" ]] || continue
      # shellcheck disable=SC2016 # backticks here are literal markdown, not command substitution
      printf '| `%s` | %s |\n' "$path" "$category"
    done <"$paths_file"
    printf '\n'
  fi
}
