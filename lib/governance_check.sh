#!/usr/bin/env bash
# lib/governance_check.sh — branch protection / CODEOWNERS / required-checks
# reasoning, sourced by pr_merge.sh and cycle.sh.
#
# Provides:
#   gov_required_checks <repo>            — echo space-separated context names
#   gov_branch_protected <repo> <branch>  — exit 0 if protected, 1 otherwise
#   gov_pr_review_required <repo> <branch> — exit 0 if approving review needed
#   gov_pr_head_oid <repo> <pr>           — echo current head SHA (full oid)
#   gov_pr_check_status <repo> <pr>       — print state summary (pass/fail/pending)
#   gov_pr_check_evidence <repo> <pr>     — print head_sha + check evidence
#                                            line: "<sha>|<status>|<names>"
#                                            where names = "name=conclusion;..."
#   gov_admin_bypass_allowed <pr_check_summary> — exit 0 if --admin merge is OK
#   gov_pr_changed_paths <repo> <pr>      — echo newline-separated changed paths
#   gov_pr_scope_kind <repo> <pr>         — one of:
#                                             docs-only | workflow-only |
#                                             docs-and-workflow | code | empty
#   gov_pr_no_check_allowed <repo> <pr>   — exit 0 if path-filtered scope
#                                            qualifies for the risk-based
#                                            no-check merge policy (#117)
#
# Doctrine (from FSQ + NGW + AQ cycle audit logs):
#   - Never --admin bypass when CI is IN_PROGRESS.
#   - Never --admin bypass when ANY required check has CONCLUSION!=success.
#   - --admin is allowed ONLY when the only block is "approving review required"
#     AND every required status check has CONCLUSION=success.
#
# Risk-based no-check policy (#117):
#   - For docs-only / .github/workflows-only PRs, required CI is often
#     skipped by upstream `paths:` filters. The poll loop in pr_merge would
#     otherwise time out waiting for a check that will never report.
#   - gov_pr_no_check_allowed answers "is this PR's scope safe to merge
#     without a CI rollup?" — yes if every changed path matches the
#     configured docs/workflow patterns. The actual merge is still
#     adjudicated by GitHub: if branch protection requires a context that
#     was not produced, gh refuses with "missing-required-check" and
#     pr_merge classifies that refusal — so we never silently bypass a
#     real required check, we only stop *waiting* for one that will not
#     come.
#
# Forge access (#816): every read goes through the provider adapter
# (`ordo_provider`, lib/ordo_provider_adapter.sh) so the same helpers work on
# GitHub, Forgejo and GitLab. The check vocabulary is projected back to the
# upper-case GitHub-style values this file always reasoned about
# (COMPLETED/IN_PROGRESS, SUCCESS/FAILURE, CLEAN/BLOCKED/...) so callers and
# audit lines are unchanged. Commit statuses (`kind=status`) now count as
# checks like check runs do — on Forgejo every check is a commit status.
set -o pipefail

_GOVERNANCE_CHECK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ordo_provider_adapter.sh
source "$_GOVERNANCE_CHECK_LIB_DIR/ordo_provider_adapter.sh"

# gov_provider <op> [args...]: one adapter read, errors silenced (callers
# treat an empty result as "unknown", exactly as they treated a gh failure).
gov_provider() {
  GH_CONFIG_DIR="${GH_CONFIG_DIR:-}" ordo_provider "$@" 2>/dev/null
}

# gov_pr_checks_lines <repo> <pr>: "<STATUS>|<CONCLUSION>|<name>" per check,
# upper-cased like the statusCheckRollup entries this file always parsed.
gov_pr_checks_lines() {
  local repo="${1:?}" pr="${2:?}"
  gov_provider checks_get "$pr" --repo "$repo" \
    | jq -r '.checks[]? | "\(.status // "" | ascii_upcase)|\(.conclusion // "" | ascii_upcase)|\(.name // "")"' 2>/dev/null
}

: "${PR_MERGE_NO_CHECK_DOCS_PATTERN:=^docs/}"
: "${PR_MERGE_NO_CHECK_WORKFLOW_PATTERN:=^\\.github/workflows/}"

# Branch-protection helpers. The provider adapter has no branch-protection
# op yet, so these three helpers still read the GitHub REST API through gh
# when the github adapter is active and answer "unknown" (empty / not
# protected / no review required) on every other forge.
# TODO(#816): needs op repo_branch_protection in the provider adapter
# (Forgejo: GET /repos/{o}/{r}/branch_protections/{b}; GitLab:
# GET /projects/:id/protected_branches/:name) — then drop the gh calls.
_gov_branch_protection_available() {
  [ "$(ordo_provider_adapter_name)" = "github" ] && command -v gh >/dev/null 2>&1
}

gov_required_checks() {
  local repo="${1:?}" branch="${2:-main}"
  _gov_branch_protection_available || return 0
  # TODO(#816): direct gh call — no adapter op for branch protection yet.
  GH_CONFIG_DIR="${GH_CONFIG_DIR:-}" gh api "repos/${repo}/branches/${branch}/protection" 2>/dev/null \
    | jq -r '.required_status_checks.contexts[]?' 2>/dev/null \
    | tr '\n' ' '
}

gov_branch_protected() {
  local repo="${1:?}" branch="${2:-main}"
  _gov_branch_protection_available || return 1
  local p
  # TODO(#816): direct gh call — no adapter op for branch protection yet.
  p=$(GH_CONFIG_DIR="${GH_CONFIG_DIR:-}" gh api "repos/${repo}/branches/${branch}" 2>/dev/null \
       | jq -r '.protected // false' 2>/dev/null)
  [ "$p" = "true" ]
}

gov_pr_review_required() {
  local repo="${1:?}" branch="${2:-main}"
  _gov_branch_protection_available || return 1
  local n
  # TODO(#816): direct gh call — no adapter op for branch protection yet.
  n=$(GH_CONFIG_DIR="${GH_CONFIG_DIR:-}" gh api "repos/${repo}/branches/${branch}/protection" 2>/dev/null \
       | jq -r '.required_pull_request_reviews.required_approving_review_count // 0' 2>/dev/null)
  [ "${n:-0}" -ge 1 ]
}

# gov_pr_rollup_is_empty: return 0 when the PR has zero status checks of any
# kind reported. Empty rollup is the load-bearing signal for the no-check
# policy: a paths-filtered CI workflow that did not run reports nothing, so
# the rollup is `[]`. A *running* check would show up as PENDING/IN_PROGRESS
# and we still want to wait. Network errors and missing PRs also return an
# empty result; the caller treats that conservatively (no policy fire).
gov_pr_rollup_is_empty() {
  local repo="${1:?}" pr="${2:?}"
  local count
  count=$(gov_provider checks_get "$pr" --repo "$repo" \
            | jq -r '.checks | length // 0' 2>/dev/null)
  [ "${count:-0}" = "0" ]
}

# gov_pr_head_oid: echo the PR's current head commit SHA (full oid). Empty on
# error so callers can treat it as "unknown" — never silently substitute a
# stale value. Used by pr_merge to tie the gate decision to the exact commit
# we are about to merge (#370): the rollup at the moment of `gh pr merge`
# must be for THIS sha, not a previous run.
gov_pr_head_oid() {
  local repo="${1:?}" pr="${2:?}"
  gov_provider pr_get "$pr" --repo "$repo" \
    | jq -r '.head.sha // empty' 2>/dev/null
}

# gov_pr_check_evidence: emit one line of pipe-separated evidence pinned to
# the PR's current head SHA. Format:
#
#   <head_sha>|<status>|<name=conclusion;name=conclusion;...>
#
# Status is one of pass | fail | pending | empty (NEW: empty is reported
# distinctly from pending so callers can require explicit no-check policy
# evidence rather than silently treating an empty rollup as "wait then
# proceed"). The names field captures every check the rollup reported, so
# the merge audit line documents what the gate evaluated. Used by pr_merge
# (#370) for the final pre-merge re-verify and the merge audit signature.
gov_pr_check_evidence() {
  local repo="${1:?}" pr="${2:?}"
  local meta head rollup status names
  meta=$(gov_provider checks_get "$pr" --repo "$repo")
  head=$(printf '%s' "$meta" | jq -r '.sha // empty' 2>/dev/null)
  rollup=$(printf '%s' "$meta" \
            | jq -r '.checks[]? | "\(.status // "" | ascii_upcase)|\(.conclusion // "" | ascii_upcase)|\(.name // "")"' 2>/dev/null)
  names=$(printf '%s' "$meta" \
            | jq -r '[.checks[]? | "\(.name // "?")=\((.conclusion // .status // "?") | ascii_upcase)"] | join(";")' 2>/dev/null)

  if [ -z "$rollup" ]; then
    status='empty'
  else
    local has_pending=0 has_fail=0 s c n
    while IFS='|' read -r s c n; do
      [ -z "$s$c$n" ] && continue
      case "$s" in
        QUEUED|IN_PROGRESS|REQUESTED|WAITING|PENDING) has_pending=1 ;;
      esac
      case "$c" in
        FAILURE|TIMED_OUT|CANCELLED|ACTION_REQUIRED|STARTUP_FAILURE) has_fail=1 ;;
      esac
    done <<<"$rollup"
    if [ "$has_fail" -eq 1 ]; then
      status='fail'
    elif [ "$has_pending" -eq 1 ]; then
      status='pending'
    else
      status='pass'
    fi
  fi
  printf '%s|%s|%s\n' "${head:-unknown}" "$status" "${names:-none}"
}

# Returns "pass" | "fail" | "pending" based on PR's full status check rollup.
gov_pr_check_status() {
  local repo="${1:?}" pr="${2:?}"
  local rollup
  rollup=$(gov_pr_checks_lines "$repo" "$pr")

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
    pass|not-applicable) ;;       # ok, continue
    fail|pending) return 1 ;;
  esac
  case "$merge_state" in
    BLOCKED|UNSTABLE) return 0 ;;     # only block is review -> bypass OK
    BEHIND)           return 1 ;;     # base moved -> require update first
    CLEAN|HAS_HOOKS)  return 0 ;;     # already mergeable; bypass redundant but allowed
    *)                return 1 ;;
  esac
}

# gov_pr_changed_paths: list every file path touched by the PR, one per line.
# Echoes nothing if the forge is unreachable or the API returns no files.
gov_pr_changed_paths() {
  local repo="${1:?}" pr="${2:?}"
  gov_provider pr_files "$pr" --repo "$repo" \
    | jq -r '.files[]?.path // empty' 2>/dev/null
}

# gov_pr_scope_kind: classify a PR's blast radius from its changed paths.
#   docs-only          — every path matches PR_MERGE_NO_CHECK_DOCS_PATTERN
#   workflow-only      — every path matches PR_MERGE_NO_CHECK_WORKFLOW_PATTERN
#   docs-and-workflow  — every path matches docs OR workflow pattern (mixed)
#   code               — at least one path matches neither pattern
#   empty              — no paths reported (PR not loaded, network error, etc.)
#
# The classification is conservative: a single non-matching path drops the PR
# straight to `code`, which keeps the existing "wait for CI" behaviour as the
# default. Callers who want to authorise a no-check merge inspect the kind
# directly via gov_pr_no_check_allowed.
gov_pr_scope_kind() {
  local repo="${1:?}" pr="${2:?}"
  local paths total=0 docs=0 workflows=0 other=0
  paths=$(gov_pr_changed_paths "$repo" "$pr")
  if [ -z "$paths" ]; then
    printf 'empty'
    return 0
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    total=$((total + 1))
    if printf '%s' "$path" | grep -Eq "$PR_MERGE_NO_CHECK_WORKFLOW_PATTERN"; then
      workflows=$((workflows + 1))
    elif printf '%s' "$path" | grep -Eq "$PR_MERGE_NO_CHECK_DOCS_PATTERN"; then
      docs=$((docs + 1))
    else
      other=$((other + 1))
    fi
  done <<<"$paths"

  if [ "$total" -eq 0 ]; then
    printf 'empty'
  elif [ "$other" -gt 0 ]; then
    printf 'code'
  elif [ "$docs" -eq "$total" ]; then
    printf 'docs-only'
  elif [ "$workflows" -eq "$total" ]; then
    printf 'workflow-only'
  else
    printf 'docs-and-workflow'
  fi
}

# gov_pr_no_check_allowed: exit 0 when the risk-based no-check merge policy
# applies to this PR. The decision is intentionally narrow:
#
#   1. The scope kind must be docs-only, workflow-only, or docs-and-workflow.
#      Anything else (including `code` and `empty`) returns 1 so pr_merge
#      keeps the current "wait for CI" guarantee.
#   2. We do NOT inspect branch protection here. If branch protection still
#      requires a context that this PR did not produce, the subsequent
#      `gh pr merge --squash` will refuse with
#      "Required status check ... is expected" — pr_merge already classifies
#      that refusal as `missing-required-check`. The policy therefore never
#      silently bypasses a real required check; it only stops *waiting* for
#      one that the upstream paths-filter intentionally did not run.
gov_pr_no_check_allowed() {
  local repo="${1:?}" pr="${2:?}"
  local kind
  kind=$(gov_pr_scope_kind "$repo" "$pr")
  case "$kind" in
    docs-only|workflow-only|docs-and-workflow) return 0 ;;
    *) return 1 ;;
  esac
}
