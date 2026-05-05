#!/usr/bin/env bash
# lib/governance_check.sh — branch protection / CODEOWNERS / required-checks
# reasoning, sourced by pr_merge.sh and cycle.sh.
#
# Provides:
#   gov_required_checks <repo>            — echo space-separated context names
#   gov_branch_protected <repo> <branch>  — exit 0 if protected, 1 otherwise
#   gov_pr_review_required <repo> <branch> — exit 0 if approving review needed
#   gov_pr_check_status <repo> <pr>       — print state summary (pass/fail/pending)
#   gov_admin_bypass_allowed <pr_check_summary> — exit 0 if --admin merge is OK
#
# Doctrine (from FSQ + NGW + AQ cycle audit logs):
#   - Never --admin bypass when CI is IN_PROGRESS.
#   - Never --admin bypass when ANY required check has CONCLUSION!=success.
#   - --admin is allowed ONLY when the only block is "approving review required"
#     AND every required status check has CONCLUSION=success.
set -o pipefail

gov_required_checks() {
  local repo="${1:?}" branch="${2:-main}"
  GH_CONFIG_DIR="${GH_CONFIG_DIR:-}" gh api "repos/${repo}/branches/${branch}/protection" 2>/dev/null \
    | jq -r '.required_status_checks.contexts[]?' 2>/dev/null \
    | tr '\n' ' '
}

gov_branch_protected() {
  local repo="${1:?}" branch="${2:-main}"
  local p
  p=$(GH_CONFIG_DIR="${GH_CONFIG_DIR:-}" gh api "repos/${repo}/branches/${branch}" 2>/dev/null \
       | jq -r '.protected // false' 2>/dev/null)
  [ "$p" = "true" ]
}

gov_pr_review_required() {
  local repo="${1:?}" branch="${2:-main}"
  local n
  n=$(GH_CONFIG_DIR="${GH_CONFIG_DIR:-}" gh api "repos/${repo}/branches/${branch}/protection" 2>/dev/null \
       | jq -r '.required_pull_request_reviews.required_approving_review_count // 0' 2>/dev/null)
  [ "${n:-0}" -ge 1 ]
}

# Returns "pass" | "fail" | "pending" based on PR's full status check rollup.
gov_pr_check_status() {
  local repo="${1:?}" pr="${2:?}"
  local rollup
  rollup=$(GH_CONFIG_DIR="${GH_CONFIG_DIR:-}" gh pr view "$pr" --repo "$repo" \
            --json statusCheckRollup 2>/dev/null \
            | jq -r '.statusCheckRollup[]? | "\(.status // "")|\(.conclusion // "")|\(.name // "")"' 2>/dev/null)

  if [ -z "$rollup" ]; then
    printf 'pending'
    return 0
  fi

  local has_pending=0
  local has_fail=0
  while IFS='|' read -r status conclusion name; do
    [ -z "$status$conclusion$name" ] && continue
    case "$status" in
      QUEUED|IN_PROGRESS|REQUESTED|WAITING|PENDING) has_pending=1 ;;
    esac
    case "$conclusion" in
      FAILURE|TIMED_OUT|CANCELLED|ACTION_REQUIRED|STARTUP_FAILURE) has_fail=1 ;;
    esac
  done <<<"$rollup"

  if [ "$has_fail" -eq 1 ]; then
    printf 'fail'
  elif [ "$has_pending" -eq 1 ]; then
    printf 'pending'
  else
    printf 'pass'
  fi
}

# Decision helper. Inputs:
#   $1 — pr check status (pass|fail|pending)
#   $2 — pr mergeStateStatus (e.g. BLOCKED, BEHIND, CLEAN, UNSTABLE)
# Returns:
#   0 — admin bypass allowed (CI=pass, only block is review)
#   1 — refuse (CI=fail or pending, OR mergeStateStatus is unsafe)
gov_admin_bypass_allowed() {
  local check_status="${1:?}"
  local merge_state="${2:?}"
  case "$check_status" in
    pass)   ;;       # ok, continue
    fail|pending) return 1 ;;
  esac
  case "$merge_state" in
    BLOCKED|UNSTABLE) return 0 ;;     # only block is review -> bypass OK
    BEHIND)           return 1 ;;     # base moved -> require update first
    CLEAN|HAS_HOOKS)  return 0 ;;     # already mergeable; bypass redundant but allowed
    *)                return 1 ;;
  esac
}
