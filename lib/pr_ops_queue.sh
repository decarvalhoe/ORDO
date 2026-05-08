#!/usr/bin/env bash
# lib/pr_ops_queue.sh — read-only PR operations queue classifier (#358,
# parent epic #357).
#
# Sourced by scripts/pr_ops_queue.sh. Pure-bash classifier: takes a single
# pr_block_signals record and project metadata, returns a queue candidate
# in the stable schema `ordo.pr_ops_queue.v1`.
#
# Design contract:
#   - Read-only. The lib never calls gh, never mutates a PR, never sends
#     keys.
#   - Universal. No project-name, repo-name, or agent-name hardcoding.
#     The candidate type is derived only from the signals + mergeability
#     + review state + draft flag, not from the project alias.
#   - Schema is stable so #357's future mode dispatcher (observe /
#     centralized / delegated / autonomous) can consume the queue
#     without recomputing classification.
#   - jq is required for output assembly (matches the rest of the
#     toolkit).

# Candidate types and their dispatch priority. Higher priority wins when
# a PR matches several types.
#
# resolve_conflict        > fix_ci > refresh_branch >
# mark_ready_candidate    > review_required > merge_candidate >
# hold_unknown_state      > hold_policy_blocked
#
# Rationale for the ordering:
#   - resolve_conflict tops because it blocks every downstream action.
#   - fix_ci is the next-most-actionable because reruns / fixes are
#     mechanical and unblock the merge gate.
#   - refresh_branch (rebase / pr-behind) is similarly mechanical.
#   - mark_ready_candidate is the cheap operator action when the only
#     blocker is the draft flag and CI is green.
#   - review_required and merge_candidate sit in the "waiting for human"
#     band; review must happen before merge.
#   - hold_unknown_state and hold_policy_blocked are non-actionable
#     today; the queue surfaces them so the operator can see what is
#     parked.
pr_ops_queue_priority_for_candidate() {
  case "${1:-}" in
    resolve_conflict)      printf '90\n' ;;
    fix_ci)                printf '80\n' ;;
    refresh_branch)        printf '70\n' ;;
    mark_ready_candidate)  printf '60\n' ;;
    review_required)       printf '50\n' ;;
    merge_candidate)       printf '40\n' ;;
    hold_unknown_state)    printf '20\n' ;;
    hold_policy_blocked)   printf '10\n' ;;
    *)                     printf '0\n' ;;
  esac
}

# Helper: does the signals JSON array contain a given signal?
pr_ops_queue_has_signal() {
  local signals_json=${1:-'[]'}
  local needle=${2:?usage: pr_ops_queue_has_signal <signals-json> <signal>}
  jq -e --arg s "$needle" 'any(.[]?; . == $s)' >/dev/null 2>&1 <<< "$signals_json"
}

# Classify a single pr_block_signals record into a queue candidate.
#
# Inputs:
#   $1  pr_record_json   — one element from pr_block_signals.sh --json output.
#                          Required keys: pr, branch, head, agent,
#                          merge_state, mergeable, review, ci_fail,
#                          ci_pending, base_current, signals.
#                          Optional keys (used when present):
#                            base_branch, ci_total, updated_at,
#                            body_text, head_full.
#   $2  project_meta_json — JSON object with: alias, project, repo,
#                          default_branch, config, policy.
#   $3  generated_at     — ISO-8601 timestamp inserted as detected_at
#                          on the candidate record.
#
# Output: one line of JSON with the schema `ordo.pr_ops_queue.v1`.
pr_ops_queue_classify() {
  local pr_record=${1:?usage: pr_ops_queue_classify <pr-record-json> <project-meta-json> <generated-at>}
  local project_meta=${2:?usage: pr_ops_queue_classify <pr-record-json> <project-meta-json> <generated-at>}
  local generated_at=${3:?usage: pr_ops_queue_classify <pr-record-json> <project-meta-json> <generated-at>}

  command -v jq >/dev/null 2>&1 || {
    printf 'pr_ops_queue_classify: jq is required\n' >&2
    return 2
  }

  local pr_number branch head agent merge_state mergeable review
  local ci_fail ci_pending ci_total base_current is_draft
  local signals_json updated_at body_text base_branch
  pr_number=$(jq -r '.pr // ""' <<< "$pr_record")
  branch=$(jq -r '.branch // ""' <<< "$pr_record")
  head=$(jq -r '.head // ""' <<< "$pr_record")
  agent=$(jq -r '.agent // ""' <<< "$pr_record")
  merge_state=$(jq -r '.merge_state // ""' <<< "$pr_record")
  mergeable=$(jq -r '.mergeable // ""' <<< "$pr_record")
  review=$(jq -r '.review // ""' <<< "$pr_record")
  ci_fail=$(jq -r '.ci_fail // 0' <<< "$pr_record")
  ci_pending=$(jq -r '.ci_pending // 0' <<< "$pr_record")
  ci_total=$(jq -r '.ci_total // ((.ci_fail // 0) + (.ci_pending // 0))' <<< "$pr_record")
  base_current=$(jq -r '.base_current // ""' <<< "$pr_record")
  is_draft=$(jq -r '(.is_draft // false) | tostring' <<< "$pr_record")
  signals_json=$(jq -c '.signals // []' <<< "$pr_record")
  updated_at=$(jq -r '.updated_at // ""' <<< "$pr_record")
  body_text=$(jq -r '.body_text // ""' <<< "$pr_record")
  base_branch=$(jq -r '.base_branch // ""' <<< "$pr_record")
  if [[ -z "$base_branch" ]]; then
    base_branch=$(jq -r '.default_branch // "main"' <<< "$project_meta")
  fi

  # is_draft is also expressible via signals (the "draft" entry). When
  # not present in the record, fall back to the signal.
  if [[ "$is_draft" != "true" && "$is_draft" != "false" ]]; then
    if pr_ops_queue_has_signal "$signals_json" "draft"; then
      is_draft="true"
    else
      is_draft="false"
    fi
  fi

  # Candidate selection. Highest priority match wins; rationale tracks
  # which observed signal drove the choice.
  local candidate="" rationale=""

  if pr_ops_queue_has_signal "$signals_json" "merge-conflict"; then
    candidate="resolve_conflict"
    rationale="merge-conflict signal observed (mergeable=${mergeable:-unknown}, merge_state=${merge_state:-unknown})"
  elif pr_ops_queue_has_signal "$signals_json" "ci-failed"; then
    candidate="fix_ci"
    rationale="ci-failed signal observed (failing=${ci_fail})"
  elif pr_ops_queue_has_signal "$signals_json" "needs-rebase" \
    || pr_ops_queue_has_signal "$signals_json" "pr-behind" \
    || pr_ops_queue_has_signal "$signals_json" "remote-rebased-local-stale"; then
    candidate="refresh_branch"
    rationale="branch is behind base (base_current=${base_current:-unknown})"
  elif [[ "$is_draft" == "true" ]] \
    && pr_ops_queue_has_signal "$signals_json" "ci-pass" \
    && ! pr_ops_queue_has_signal "$signals_json" "ci-failed" \
    && ! pr_ops_queue_has_signal "$signals_json" "ci-pending" \
    && ! pr_ops_queue_has_signal "$signals_json" "review-required" \
    && ! pr_ops_queue_has_signal "$signals_json" "changes-requested"; then
    candidate="mark_ready_candidate"
    rationale="draft with ci-pass and no other blockers — promote to ready"
  elif pr_ops_queue_has_signal "$signals_json" "review-required" \
    || pr_ops_queue_has_signal "$signals_json" "changes-requested"; then
    candidate="review_required"
    rationale="review_decision=${review:-unknown}; awaiting human review"
  elif pr_ops_queue_has_signal "$signals_json" "merge-ready"; then
    candidate="merge_candidate"
    rationale="merge-ready signal observed; gated merge eligible"
  elif pr_ops_queue_has_signal "$signals_json" "mergeable-unknown" \
    || pr_ops_queue_has_signal "$signals_json" "merge-state-unknown" \
    || pr_ops_queue_has_signal "$signals_json" "checks-missing"; then
    candidate="hold_unknown_state"
    rationale="state could not be determined (mergeable=${mergeable:-unknown}, merge_state=${merge_state:-unknown}, ci_total=${ci_total})"
  elif pr_ops_queue_has_signal "$signals_json" "deploy-gate-external-wait" \
    || pr_ops_queue_has_signal "$signals_json" "auto-merge-armed" \
    || pr_ops_queue_has_signal "$signals_json" "merge-blocked"; then
    candidate="hold_policy_blocked"
    rationale="policy or external gate blocking merge (signals=${signals_json})"
  elif pr_ops_queue_has_signal "$signals_json" "ci-pending"; then
    # CI still running and no other blockers — treat as policy-blocked
    # waiting on the CI gate.
    candidate="hold_policy_blocked"
    rationale="ci-pending observed (pending=${ci_pending}); waiting on CI gate"
  else
    candidate="hold_unknown_state"
    rationale="no recognized signal class; recheck pr_block_signals input"
  fi

  local priority
  priority=$(pr_ops_queue_priority_for_candidate "$candidate")

  # Compute last_update_age_sec from updated_at if present.
  local last_update_age_sec=""
  if [[ -n "$updated_at" ]]; then
    local now_epoch updated_epoch
    now_epoch=$(date -u +%s)
    if updated_epoch=$(date -u -d "$updated_at" +%s 2>/dev/null) \
      || updated_epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$updated_at" +%s 2>/dev/null); then
      last_update_age_sec=$((now_epoch - updated_epoch))
    fi
  fi

  # Try to extract a linked issue number from the body. Standard markers:
  # "Closes #123", "Fixes #123", "Refs #123", "Refs: #123", "Resolves #123".
  # Returns the first match; classifier consumers may scan body_text for
  # additional refs if needed.
  local linked_issue=""
  if [[ -n "$body_text" ]]; then
    linked_issue=$(printf '%s' "$body_text" \
      | grep -Eio '(closes|fixes|refs|resolves|relates to)[: ]*#[0-9]+' \
      | head -n 1 \
      | grep -Eo '[0-9]+' \
      | head -n 1)
  fi

  jq -nc \
    --arg schema "ordo.pr_ops_queue.v1" \
    --arg generated_at "$generated_at" \
    --argjson project_meta "$project_meta" \
    --arg pr "$pr_number" \
    --arg branch "$branch" \
    --arg base_branch "$base_branch" \
    --arg head "$head" \
    --arg agent "$agent" \
    --arg candidate "$candidate" \
    --arg priority "$priority" \
    --arg merge_state "$merge_state" \
    --arg mergeable "$mergeable" \
    --arg review "$review" \
    --arg ci_fail "$ci_fail" \
    --arg ci_pending "$ci_pending" \
    --arg ci_total "$ci_total" \
    --arg base_current "$base_current" \
    --arg is_draft "$is_draft" \
    --argjson signals "$signals_json" \
    --arg updated_at "$updated_at" \
    --arg last_update_age_sec "$last_update_age_sec" \
    --arg linked_issue "$linked_issue" \
    --arg rationale "$rationale" \
    '{
       schema: $schema,
       generated_at: $generated_at,
       alias: ($project_meta.alias // ""),
       project: ($project_meta.project // ($project_meta.alias // "")),
       repo: ($project_meta.repo // ""),
       pr: ($pr | tonumber? // $pr),
       branch: $branch,
       base_branch: $base_branch,
       head: $head,
       agent: (if $agent == "" then null else $agent end),
       candidate: $candidate,
       priority: ($priority | tonumber),
       mergeable: $mergeable,
       merge_state: $merge_state,
       review_decision: $review,
       ci_summary: {
         total: ($ci_total | tonumber? // 0),
         failed: ($ci_fail | tonumber? // 0),
         pending: ($ci_pending | tonumber? // 0),
         passed: ((($ci_total | tonumber? // 0)) - (($ci_fail | tonumber? // 0)) - (($ci_pending | tonumber? // 0)))
       },
       signals: $signals,
       is_draft: ($is_draft == "true"),
       updated_at: (if $updated_at == "" then null else $updated_at end),
       last_update_age_sec: (if $last_update_age_sec == "" then null else ($last_update_age_sec | tonumber) end),
       linked_issue: (if $linked_issue == "" then null else ($linked_issue | tonumber) end),
       project_policy: ($project_meta.policy // "observe"),
       rationale: $rationale
     }'
}

# List the canonical candidate types in priority order. Useful for tests
# and for documentation generators.
pr_ops_queue_candidate_types() {
  cat <<'EOF'
resolve_conflict
fix_ci
refresh_branch
mark_ready_candidate
review_required
merge_candidate
hold_unknown_state
hold_policy_blocked
EOF
}
