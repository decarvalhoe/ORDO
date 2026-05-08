#!/usr/bin/env bash
# lib/pr_merge.sh — approve + squash-merge a PR with CI gate enforcement.
#
# Usage: pr_merge.sh <project_short|config_path> <pr_number> [--no-admin-fallback]
#
# Surviving log signatures:
#   PR #N approve+merge attempt (--squash)
#   PR #N CI in_progress, wait 30s (X/600)
#   PR #N CI GATE FAILED — refusing merge. Checks: <list>
#   PR #N merged (--squash)
#   PR #N merged (--squash, admin-approved)
#   PR #N merged (--squash, no-check policy: scope=<kind>)
#   PR #N CI not-applicable (no-check policy: scope=<kind>) — proceeding
#   PR #N MERGE FAILED — manual intervention required
#   PR #N state=CLOSED mid-poll — abandoning poll
#   PR #N state=MERGED mid-poll — abandoning poll
#   PR #N mergeStateStatus=DIRTY (conflicting) mid-poll — abandoning poll
#   PR #N mergeable=CONFLICTING mid-poll — abandoning poll
#
# Doctrine:
#   - Wait CI up to PR_MERGE_CI_TIMEOUT_SEC, polling every PR_MERGE_CI_INTERVAL_SEC.
#   - Only merge when CI rollup status = "pass".
#   - If mergeStateStatus is BLOCKED on review only AND CI=success, fall back
#     to --admin (using PR_MERGE_ADMIN_TOKEN). Otherwise refuse.
#   - Never bypass when CI is IN_PROGRESS or FAILURE.
#
# Risk-based no-check merge policy (#117):
#   - Opt-in via PR_MERGE_NO_CHECK_POLICY=1 (default 0, off).
#   - When the PR's status check rollup is genuinely empty AND every changed
#     path matches the docs/workflow patterns
#     (PR_MERGE_NO_CHECK_DOCS_PATTERN, PR_MERGE_NO_CHECK_WORKFLOW_PATTERN),
#     the poll loop treats CI as "not-applicable" instead of "pending" and
#     proceeds straight to the squash-merge attempt. If branch protection
#     still requires a context that did not run, gh refuses with
#     "missing-required-check" — that refusal is classified as before, so we
#     never silently bypass a real required check; we only stop *waiting* for
#     one the upstream paths-filter intentionally skipped.
#   - The audit trail keeps "missing-required-check" (something we expected
#     never reported) distinct from "not-applicable" (no required check
#     should report for this scope), so dashboards can stop conflating them.
#
# Exit codes:
#   0 success
#   2 CI failed
#   3 CI timeout
#   4 merge failed without admin fallback
#   5 admin bypass denied
#   6 admin token missing
#   7 admin merge failed
#   8 PR closed or merged by another actor mid-poll
#   9 PR became conflicting mid-poll
#
# Refusal observability:
#   Every nonzero exit emits an audit line that includes the underlying gh
#   stderr (truncated) and a stable refusal category ("missing-required-check",
#   "review-required", "branch-protection", "draft", "conflict",
#   "permission-denied", "auto-merge-disallowed", "merge-method-disallowed",
#   "unknown") so dashboards can group failures without parsing free-form text.
set -o pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/dry_run.sh"
source "$TK/lib/config_resolver.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

CFG_ARG=${1:?usage: pr_merge.sh <project> <pr#> [--no-admin-fallback] [--dry-run]}
PR=${2:?}
ADMIN_FALLBACK=1
[ "${3:-}" = "--no-admin-fallback" ] && ADMIN_FALLBACK=0

load_project_config "$CFG_ARG"

source "$TK/lib/audit_log.sh"
source "$TK/lib/governance_check.sh"
source "$TK/lib/gh_body_helpers.sh"

: "${GH_REPO:?}" "${GH_CONFIG_DIR:?}" "${DEFAULT_BRANCH:=main}"
: "${PR_MERGE_CI_INTERVAL_SEC:=30}" "${PR_MERGE_CI_TIMEOUT_SEC:=600}"
: "${PR_MERGE_GH_RETRY_MAX:=3}" "${PR_MERGE_GH_RETRY_BACKOFF_SEC:=5}"
: "${PR_MERGE_DISABLE_AUTO_ON_REFUSE:=1}"
# Risk-based no-check merge policy (#117). Off by default so existing
# behaviour is unchanged; opt in by setting PR_MERGE_NO_CHECK_POLICY=1
# in the per-project config that pr_merge consumes.
: "${PR_MERGE_NO_CHECK_POLICY:=0}"
# GitFlow issue reconciliation (#116). When a PR merges into a non-default
# branch, GitHub will not auto-close closing issue references. Default to a
# validation gate comment so GitFlow projects can preserve evidence without
# prematurely closing work before promotion reaches the repository default.
: "${PR_MERGE_ISSUE_RECONCILE:=1}"
: "${PR_MERGE_ISSUE_RECONCILE_MODE:=gate}"
: "${PR_MERGE_ISSUE_RECONCILE_GATE_LABEL:=}"

# gh_retry: run a gh command, retry on transient 5xx/network errors with
# exponential backoff. Up to PR_MERGE_GH_RETRY_MAX attempts. The script
# writes captured stdout to fd 1 on success; on final failure it writes
# captured stderr to fd 2 and returns the underlying gh exit code, so
# callers can `2>/dev/null` if they only care about exit-code branching.
gh_retry() {
  local attempt=0 backoff="$PR_MERGE_GH_RETRY_BACKOFF_SEC" out rc
  while :; do
    attempt=$((attempt + 1))
    out=$("$@" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
      printf '%s\n' "$out"
      return 0
    fi
    if printf '%s' "$out" | grep -qE '5[0-9][0-9] (Gateway Timeout|Bad Gateway|Service Unavailable|Internal Server Error)|connection reset|i/o timeout|TLS handshake timeout|EOF|net/http'; then
      if [ "$attempt" -lt "$PR_MERGE_GH_RETRY_MAX" ]; then
        audit "gh transient error (attempt ${attempt}/${PR_MERGE_GH_RETRY_MAX}, retry in ${backoff}s)"
        sleep "$backoff"
        backoff=$((backoff * 2))
        continue
      fi
    fi
    printf '%s\n' "$out" >&2
    return "$rc"
  done
}

disable_auto_merge_if_enabled() {
  local pr=${1:?usage: disable_auto_merge_if_enabled <pr>}
  [ "${PR_MERGE_DISABLE_AUTO_ON_REFUSE}" = "1" ] || return 0

  local auto_state
  auto_state=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh pr view "$pr" --repo "$GH_REPO" \
    --json autoMergeRequest 2>/dev/null | jq -r '.autoMergeRequest // empty' 2>/dev/null || true)
  [ -n "$auto_state" ] || return 0

  if GH_CONFIG_DIR="$GH_CONFIG_DIR" gh_retry gh pr merge "$pr" --repo "$GH_REPO" --disable-auto >/dev/null 2>&1; then
    audit "PR #${pr} auto-merge disabled before refusal"
  else
    audit "PR #${pr} auto-merge disable failed before refusal"
  fi
}

# classify_merge_refusal: map a gh CLI error message to a stable refusal
# category, so audit consumers can group "missing required check" vs
# "review required" vs "branch protection" without parsing free-form text.
classify_merge_refusal() {
  local raw=${1:-}
  local msg
  msg=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  case "$msg" in
    *"required status check"*|*"all checks have failed"*|*"checks must pass"*)
      printf 'missing-required-check' ;;
    *"approving review"*|*"review required"*|*"changes requested"*|*"required reviewer"*)
      printf 'review-required' ;;
    *"branch protection"*|*"base branch policy"*|*"protected branch"*|*"protection rule"*)
      printf 'branch-protection' ;;
    *"still a draft"*|*"is a draft"*)
      printf 'draft' ;;
    *"merge conflict"*|*"merge cannot be cleanly created"*|*"conflicting"*|*"is dirty"*)
      printf 'conflict' ;;
    *"not authorized"*|*"not accessible"*|*"forbidden"*|*"403"*|*"insufficient permissions"*)
      printf 'permission-denied' ;;
    *"auto-merge is not allowed"*|*"auto-merge is disabled"*)
      printf 'auto-merge-disallowed' ;;
    *"linear history"*|*"merge commits not allowed"*|*"squash merging is disabled"*|*"squash merge is disabled"*)
      printf 'merge-method-disallowed' ;;
    "")
      printf 'unknown' ;;
    *)
      printf 'unknown' ;;
  esac
}

# truncate_stderr: collapse a captured stderr blob to a single line capped at
# ~500 chars so audit lines remain greppable without losing the gh hint.
truncate_stderr() {
  local raw=${1:-}
  [ -n "$raw" ] || { printf 'no stderr captured'; return 0; }
  printf '%s' "$raw" | tr '\n\r\t' '   ' | tr -s ' ' | cut -c1-500
}

pr_merge_repo_default_branch() {
  GH_CONFIG_DIR="$GH_CONFIG_DIR" gh repo view "$GH_REPO" --json defaultBranchRef 2>/dev/null \
    | jq -r '.defaultBranchRef.name // empty' 2>/dev/null
}

pr_merge_issue_refs_from_meta() {
  local meta=${1:?usage: pr_merge_issue_refs_from_meta <pr-meta-json>}
  {
    printf '%s' "$meta" | jq -r '.closingIssuesReferences[]?.number // empty' 2>/dev/null || true
    printf '%s' "$meta" | jq -r '(.title // "") + "\n" + (.body // "")' 2>/dev/null \
      | grep -Ei '\b(close[sd]?|fix(e[sd])?|resolve[sd]?)\b' \
      | grep -Eo '#[0-9]+' \
      | tr -d '#' || true
  } | awk 'NF && !seen[$0]++'
}

pr_merge_issue_reconcile_body() {
  local mode=${1:?usage: pr_merge_issue_reconcile_body <mode> <issue> <pr-meta-json> <repo-default>}
  local issue=${2:?usage: pr_merge_issue_reconcile_body <mode> <issue> <pr-meta-json> <repo-default>}
  local meta=${3:?usage: pr_merge_issue_reconcile_body <mode> <issue> <pr-meta-json> <repo-default>}
  local repo_default=${4:?usage: pr_merge_issue_reconcile_body <mode> <issue> <pr-meta-json> <repo-default>}
  local pr_number pr_url base_ref merged_at merge_commit title

  pr_number=$(printf '%s' "$meta" | jq -r '.number // "'"$PR"'"')
  pr_url=$(printf '%s' "$meta" | jq -r '.url // ""')
  base_ref=$(printf '%s' "$meta" | jq -r '.baseRefName // ""')
  merged_at=$(printf '%s' "$meta" | jq -r '.mergedAt // ""')
  merge_commit=$(printf '%s' "$meta" | jq -r '.mergeCommit.oid // ""')
  title=$(printf '%s' "$meta" | jq -r '.title // ""')

  cat <<EOF
ORDO post-merge issue reconciliation for #${issue}.

Evidence:
- PR: #${pr_number} ${pr_url}
- PR title: ${title}
- Merged into: ${base_ref}
- Repository default branch: ${repo_default}
- Merged at: ${merged_at:-unknown}
- Merge commit: ${merge_commit:-unknown}

Outcome:
EOF
  if [ "$mode" = "close" ]; then
    cat <<'EOF'
- Closing this issue because the configured ORDO reconciliation mode is `close` and the merge evidence above records the completed PR.
EOF
  else
    cat <<'EOF'
- Validation gate recorded. The PR merged into a non-default branch, so this issue remains open until promotion or operator validation confirms the change on the repository default branch.
EOF
  fi
}

pr_merge_reconcile_issues() {
  local pr=${1:?usage: pr_merge_reconcile_issues <pr>}
  [ "$PR_MERGE_ISSUE_RECONCILE" = "1" ] || return 0

  local mode=$PR_MERGE_ISSUE_RECONCILE_MODE
  case "$mode" in
    gate|close) ;;
    off|0|false|no) return 0 ;;
    *)
      audit "PR #${pr} issue_reconcile skipped invalid mode=${mode}"
      return 0
      ;;
  esac

  local meta repo_default base_ref issues issue comment_rc close_rc label_rc
  meta=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh pr view "$pr" --repo "$GH_REPO" \
    --json number,title,body,url,baseRefName,mergedAt,mergeCommit,closingIssuesReferences 2>/dev/null || true)
  [ -n "$meta" ] || {
    audit "PR #${pr} issue_reconcile skipped reason=missing-pr-meta"
    return 0
  }

  base_ref=$(printf '%s' "$meta" | jq -r '.baseRefName // empty')
  repo_default=$(pr_merge_repo_default_branch || true)
  repo_default=${repo_default:-$DEFAULT_BRANCH}

  if [ -z "$base_ref" ] || [ "$base_ref" = "$repo_default" ]; then
    audit "PR #${pr} issue_reconcile skipped base=${base_ref:-unknown} default=${repo_default} reason=default-branch-merge"
    return 0
  fi

  issues=$(pr_merge_issue_refs_from_meta "$meta")
  if [ -z "$issues" ]; then
    audit "PR #${pr} issue_reconcile none base=${base_ref} default=${repo_default}"
    return 0
  fi

  while IFS= read -r issue; do
    [ -n "$issue" ] || continue
    comment_rc=0
    pr_merge_issue_reconcile_body "$mode" "$issue" "$meta" "$repo_default" \
      | GH_CONFIG_DIR="$GH_CONFIG_DIR" gh_issue_comment_body_file "$issue" --repo "$GH_REPO" >/dev/null 2>&1 \
      || comment_rc=$?
    if [ "$comment_rc" -ne 0 ]; then
      audit "PR #${pr} issue_reconcile comment_failed issue=#${issue} mode=${mode} rc=${comment_rc}"
      continue
    fi

    if [ "$mode" = "close" ]; then
      close_rc=0
      if declare -F orch_github_identity_guard >/dev/null 2>&1; then
        orch_github_identity_guard "" "pr_merge:issue_close" || close_rc=$?
      fi
      if [ "$close_rc" -eq 0 ]; then
        GH_CONFIG_DIR="$GH_CONFIG_DIR" gh issue close "$issue" --repo "$GH_REPO" --reason completed >/dev/null 2>&1 || close_rc=$?
      fi
      if [ "$close_rc" -eq 0 ]; then
        audit "PR #${pr} issue_reconcile closed issue=#${issue} base=${base_ref} default=${repo_default}"
      else
        audit "PR #${pr} issue_reconcile close_failed issue=#${issue} base=${base_ref} default=${repo_default} rc=${close_rc}"
      fi
    else
      if [ -n "$PR_MERGE_ISSUE_RECONCILE_GATE_LABEL" ]; then
        label_rc=0
        if declare -F orch_github_identity_guard >/dev/null 2>&1; then
          orch_github_identity_guard "" "pr_merge:issue_gate_label" || label_rc=$?
        fi
        if [ "$label_rc" -eq 0 ]; then
          GH_CONFIG_DIR="$GH_CONFIG_DIR" gh issue edit "$issue" --repo "$GH_REPO" \
            --add-label "$PR_MERGE_ISSUE_RECONCILE_GATE_LABEL" >/dev/null 2>&1 || label_rc=$?
        fi
        [ "$label_rc" -eq 0 ] \
          || audit "PR #${pr} issue_reconcile gate_label_failed issue=#${issue} label=${PR_MERGE_ISSUE_RECONCILE_GATE_LABEL} rc=${label_rc}"
      fi
      audit "PR #${pr} issue_reconcile validation_gate issue=#${issue} base=${base_ref} default=${repo_default}"
    fi
  done <<< "$issues"
}

audit "PR #${PR} approve+merge attempt (--squash)"

# Risk-based no-check policy (#117): if the operator opted in and the PR's
# scope is path-filtered (docs-only / .github/workflows-only / mixed of the
# two), latch this fact early so the poll loop and the dry-run branch can
# substitute "not-applicable" for "pending" once the rollup is confirmed
# empty. The latch is computed once to avoid repeated `gh pr view --json files`
# round-trips inside the poll loop.
NO_CHECK_POLICY_ELIGIBLE=0
NO_CHECK_POLICY_SCOPE=""
if [ "${PR_MERGE_NO_CHECK_POLICY}" = "1" ]; then
  if NO_CHECK_POLICY_SCOPE=$(gov_pr_scope_kind "$GH_REPO" "$PR" 2>/dev/null) \
     && gov_pr_no_check_allowed "$GH_REPO" "$PR" >/dev/null 2>&1; then
    NO_CHECK_POLICY_ELIGIBLE=1
    audit "PR #${PR} no-check policy eligible (scope=${NO_CHECK_POLICY_SCOPE})"
  fi
fi

# Step 0: if the PR is still a draft, mark it ready for review.
# Otherwise the later `gh pr merge --squash` returns
# "Pull Request is still a draft (mergePullRequest)" and the script
# silently escalates to admin fallback (which also fails — --admin
# bypasses branch protection, not draft state).
is_draft=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh pr view "$PR" --repo "$GH_REPO" \
             --json isDraft 2>/dev/null | jq -r '.isDraft // false')
if [ "$is_draft" = "true" ]; then
  if dry_run_enabled; then
    dry_run_note "PR #${PR} is draft — would call gh pr ready $PR"
  else
    # `audit_log.sh` enables `set -e`, so capture the rc explicitly via
    # `|| rc=$?` rather than `cmd; rc=$?` — the latter would exit on failure
    # and we would never reach the audit line that surfaces the gh stderr.
    ready_rc=0
    ready_err=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh_retry gh pr ready "$PR" --repo "$GH_REPO" 2>&1 >/dev/null) || ready_rc=$?
    if [ "$ready_rc" -eq 0 ]; then
      audit "PR #${PR} marked ready (was draft)"
    else
      audit "PR #${PR} ready FAILED — refusing merge (reason=draft, rc=${ready_rc}): $(truncate_stderr "$ready_err")"
      exit 4
    fi
  fi
fi

if dry_run_enabled; then
  meta=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh pr view "$PR" --repo "$GH_REPO" \
           --json state,mergeStateStatus,mergeable 2>/dev/null)
  pr_state=$(printf '%s' "$meta" | jq -r '.state // "UNKNOWN"')
  merge_state=$(printf '%s' "$meta" | jq -r '.mergeStateStatus // "UNKNOWN"')
  mergeable=$(printf '%s' "$meta" | jq -r '.mergeable // "UNKNOWN"')

  case "$pr_state" in
    CLOSED|MERGED)
      dry_run_note "PR #${PR} state=${pr_state} — would abandon merge poll"
      exit 0
      ;;
  esac

  case "$merge_state" in
    DIRTY)
      dry_run_note "PR #${PR} mergeStateStatus=DIRTY — would abandon merge poll"
      exit 0
      ;;
  esac

  case "$mergeable" in
    CONFLICTING)
      dry_run_note "PR #${PR} mergeable=CONFLICTING — would abandon merge poll"
      exit 0
      ;;
  esac

  status=$(gov_pr_check_status "$GH_REPO" "$PR")
  if [ "$status" = "pending" ] && [ "$NO_CHECK_POLICY_ELIGIBLE" -eq 1 ] \
     && gov_pr_rollup_is_empty "$GH_REPO" "$PR"; then
    dry_run_note "PR #${PR} CI not-applicable (no-check policy: scope=${NO_CHECK_POLICY_SCOPE}) — would proceed"
    status="not-applicable"
  fi
  case "$status" in
    fail)
      checks=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh pr view "$PR" --repo "$GH_REPO" \
                --json statusCheckRollup 2>/dev/null \
                | jq -r '.statusCheckRollup[]? | "\(.name)=\(.conclusion // .status)"' \
                | tr '\n' ',' | sed 's/,$//')
      dry_run_note "PR #${PR} CI gate failed — would refuse merge. Checks: ${checks}"
      exit 0
      ;;
    pending)
      dry_run_note "PR #${PR} CI status=${status} — would wait instead of merging"
      exit 0
      ;;
    pass|not-applicable)
      ;;
    *)
      dry_run_note "PR #${PR} CI status=${status} — would require manual check before merging"
      exit 0
      ;;
  esac

  if [[ "$merge_state" == "CLEAN" || "$merge_state" == "HAS_HOOKS" ]]; then
    dry_run_note "gh pr merge $PR --repo $GH_REPO --squash"
    exit 0
  fi

  if [ "$ADMIN_FALLBACK" -eq 0 ]; then
    dry_run_note "PR #${PR} merge blocked (state=${merge_state}) — would require manual intervention"
    exit 0
  fi

  if ! gov_admin_bypass_allowed "$status" "$merge_state"; then
    dry_run_note "PR #${PR} admin bypass denied (status=${status} state=${merge_state})"
    exit 0
  fi

  APPROVE_TOKEN="${PR_MERGE_ADMIN_TOKEN:-}"
  if [ -z "$APPROVE_TOKEN" ]; then
    dry_run_note "PR #${PR} admin fallback would require PR_MERGE_ADMIN_TOKEN"
    exit 0
  fi

  dry_run_note "gh pr review $PR --repo $GH_REPO --approve"
  dry_run_note "gh pr merge $PR --repo $GH_REPO --squash --admin"
  exit 0
fi

# Step 1: poll CI up to timeout.
elapsed=0
status="pending"
while [ "$elapsed" -lt "$PR_MERGE_CI_TIMEOUT_SEC" ]; do
  meta=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh pr view "$PR" --repo "$GH_REPO" \
           --json state,mergeStateStatus,mergeable 2>/dev/null)
  pr_state=$(printf '%s' "$meta" | jq -r '.state // "UNKNOWN"')
  merge_state_poll=$(printf '%s' "$meta" | jq -r '.mergeStateStatus // "UNKNOWN"')
  mergeable_poll=$(printf '%s' "$meta" | jq -r '.mergeable // "UNKNOWN"')

  case "$pr_state" in
    CLOSED|MERGED)
      audit "PR #${PR} state=${pr_state} mid-poll — abandoning poll"
      exit 8
      ;;
  esac

  case "$merge_state_poll" in
    DIRTY)
      audit "PR #${PR} mergeStateStatus=DIRTY (conflicting) mid-poll — abandoning poll"
      exit 9
      ;;
  esac

  case "$mergeable_poll" in
    CONFLICTING)
      audit "PR #${PR} mergeable=CONFLICTING mid-poll — abandoning poll"
      exit 9
      ;;
  esac

  status=$(gov_pr_check_status "$GH_REPO" "$PR")
  # Risk-based no-check policy (#117): if the rollup is empty AND the PR's
  # scope is path-filtered, treat CI as not-applicable instead of pending.
  # `gov_pr_check_status` returns "pending" for both "checks running" and
  # "no checks reported"; the explicit empty-rollup probe disambiguates so
  # we keep waiting whenever a check might still arrive.
  if [ "$status" = "pending" ] && [ "$NO_CHECK_POLICY_ELIGIBLE" -eq 1 ] \
     && gov_pr_rollup_is_empty "$GH_REPO" "$PR"; then
    audit "PR #${PR} CI not-applicable (no-check policy: scope=${NO_CHECK_POLICY_SCOPE}) — proceeding"
    status="not-applicable"
  fi
  case "$status" in
    pass|not-applicable) break ;;
    fail)
      checks=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh pr view "$PR" --repo "$GH_REPO" \
                --json statusCheckRollup 2>/dev/null \
                | jq -r '.statusCheckRollup[]? | "\(.name)=\(.conclusion // .status)"' \
                | tr '\n' ',' | sed 's/,$//')
      disable_auto_merge_if_enabled "$PR"
      audit "PR #${PR} CI GATE FAILED — refusing merge. Checks: ${checks}"
      exit 2
      ;;
    pending|*)
      audit "PR #${PR} CI in_progress, wait ${PR_MERGE_CI_INTERVAL_SEC}s (${elapsed}/${PR_MERGE_CI_TIMEOUT_SEC})"
      sleep "$PR_MERGE_CI_INTERVAL_SEC"
      elapsed=$((elapsed + PR_MERGE_CI_INTERVAL_SEC))
      ;;
  esac
done

if [ "$status" != "pass" ] && [ "$status" != "not-applicable" ]; then
  disable_auto_merge_if_enabled "$PR"
  audit "PR #${PR} CI TIMEOUT after ${elapsed}s — refusing merge"
  exit 3
fi

# Read mergeability before any mutating step so dry-run can exit cleanly.
merge_state=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh pr view "$PR" --repo "$GH_REPO" \
               --json mergeStateStatus 2>/dev/null | jq -r '.mergeStateStatus // "UNKNOWN"')

# Step 2: try plain squash merge first (with transient-error retry).
# Deliberately avoid `--auto`: deferred auto-merge can fire after the CI
# surface changes, which defeats the fresh gate this script just evaluated.
# `|| merge_rc=$?` keeps the captured stderr available for the audit lines
# below — without it, `set -e` (from audit_log.sh) would exit before we
# could surface the underlying refusal reason.
merge_rc=0
merge_err=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh_retry gh pr merge "$PR" --repo "$GH_REPO" --squash 2>&1 >/dev/null) || merge_rc=$?
if [ "$merge_rc" -eq 0 ]; then
  if [ "$status" = "not-applicable" ]; then
    audit "PR #${PR} merged (--squash, no-check policy: scope=${NO_CHECK_POLICY_SCOPE})"
  else
    audit "PR #${PR} merged (--squash)"
  fi
  pr_merge_reconcile_issues "$PR"
  exit 0
fi

merge_reason=$(classify_merge_refusal "$merge_err")
merge_err_short=$(truncate_stderr "$merge_err")

# Step 3: read mergeStateStatus to decide if admin bypass is appropriate.
if [ "$ADMIN_FALLBACK" -eq 0 ]; then
  audit "PR #${PR} MERGE FAILED — manual intervention required (state=${merge_state} reason=${merge_reason} rc=${merge_rc}): ${merge_err_short}"
  exit 4
fi

if ! gov_admin_bypass_allowed "$status" "$merge_state"; then
  audit "PR #${PR} MERGE FAILED — admin bypass DENIED (status=${status} state=${merge_state} reason=${merge_reason}): ${merge_err_short}"
  exit 5
fi

# Step 4: admin approve + admin merge.
APPROVE_TOKEN="${PR_MERGE_ADMIN_TOKEN:-}"
if [ -z "$APPROVE_TOKEN" ]; then
  audit "PR #${PR} admin fallback skipped — no PR_MERGE_ADMIN_TOKEN set (state=${merge_state} reason=${merge_reason}): ${merge_err_short}"
  exit 6
fi

approve_rc=0
approve_err=$(GH_TOKEN="$APPROVE_TOKEN" gh_retry gh pr review "$PR" --repo "$GH_REPO" --approve \
  --body "Orchestrator review — CI green, branch-protection bypass." 2>&1 >/dev/null) || approve_rc=$?
if [ "$approve_rc" -ne 0 ]; then
  audit "PR #${PR} admin approve rc=${approve_rc} (continuing to admin merge): $(truncate_stderr "$approve_err")"
fi

admin_rc=0
admin_err=$(GH_TOKEN="$APPROVE_TOKEN" gh_retry gh pr merge "$PR" --repo "$GH_REPO" --squash --admin 2>&1 >/dev/null) || admin_rc=$?
if [ "$admin_rc" -eq 0 ]; then
  audit "PR #${PR} merged (--squash, admin-approved)"
  pr_merge_reconcile_issues "$PR"
  exit 0
fi

admin_reason=$(classify_merge_refusal "$admin_err")
audit "PR #${PR} MERGE FAILED — admin merge rejected (state=${merge_state} reason=${admin_reason} rc=${admin_rc}): $(truncate_stderr "$admin_err")"
exit 7
