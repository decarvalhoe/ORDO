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

: "${GH_REPO:?}" "${GH_CONFIG_DIR:?}" "${DEFAULT_BRANCH:=main}"
: "${PR_MERGE_CI_INTERVAL_SEC:=30}" "${PR_MERGE_CI_TIMEOUT_SEC:=600}"
: "${PR_MERGE_GH_RETRY_MAX:=3}" "${PR_MERGE_GH_RETRY_BACKOFF_SEC:=5}"
: "${PR_MERGE_DISABLE_AUTO_ON_REFUSE:=1}"

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

audit "PR #${PR} approve+merge attempt (--squash)"

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
    if gh_retry gh pr ready "$PR" --repo "$GH_REPO" >/dev/null 2>&1; then
      audit "PR #${PR} marked ready (was draft)"
    else
      audit "PR #${PR} ready FAILED — refusing merge (still draft)"
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
    pass)
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
  case "$status" in
    pass) break ;;
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

if [ "$status" != "pass" ]; then
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
if GH_CONFIG_DIR="$GH_CONFIG_DIR" gh_retry gh pr merge "$PR" --repo "$GH_REPO" --squash >/dev/null 2>&1; then
  audit "PR #${PR} merged (--squash)"
  exit 0
fi

# Step 3: read mergeStateStatus to decide if admin bypass is appropriate.
if [ "$ADMIN_FALLBACK" -eq 0 ]; then
  audit "PR #${PR} MERGE FAILED — manual intervention required (state: $merge_state)"
  exit 4
fi

if ! gov_admin_bypass_allowed "$status" "$merge_state"; then
  audit "PR #${PR} MERGE FAILED — admin bypass DENIED (status=$status state=$merge_state)"
  exit 5
fi

# Step 4: admin approve + admin merge.
APPROVE_TOKEN="${PR_MERGE_ADMIN_TOKEN:-}"
if [ -z "$APPROVE_TOKEN" ]; then
  audit "PR #${PR} admin fallback skipped — no PR_MERGE_ADMIN_TOKEN set"
  exit 6
fi

GH_TOKEN="$APPROVE_TOKEN" gh_retry gh pr review "$PR" --repo "$GH_REPO" --approve \
  --body "Orchestrator review — CI green, branch-protection bypass." 2>&1 | tail -3 || true

if GH_TOKEN="$APPROVE_TOKEN" gh_retry gh pr merge "$PR" --repo "$GH_REPO" --squash --admin >/dev/null 2>&1; then
  audit "PR #${PR} merged (--squash, admin-approved)"
  exit 0
fi

audit "PR #${PR} MERGE FAILED — admin merge rejected (state: $merge_state)"
exit 7
