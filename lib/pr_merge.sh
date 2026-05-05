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
#
# Doctrine:
#   - Wait CI up to PR_MERGE_CI_TIMEOUT_SEC, polling every PR_MERGE_CI_INTERVAL_SEC.
#   - Only merge when CI rollup status = "pass".
#   - If mergeStateStatus is BLOCKED on review only AND CI=success, fall back
#     to --admin (using PR_MERGE_ADMIN_TOKEN). Otherwise refuse.
#   - Never bypass when CI is IN_PROGRESS or FAILURE.
set -o pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

CFG_ARG=${1:?usage: pr_merge.sh <project> <pr#> [--no-admin-fallback]}
PR=${2:?}
ADMIN_FALLBACK=1
[ "${3:-}" = "--no-admin-fallback" ] && ADMIN_FALLBACK=0

case "$CFG_ARG" in
  wp|realisons-wp)   CFG="$TK/examples/realisons-wp.config.sh" ;;
  nomos)             CFG="$TK/examples/nomos.config.sh" ;;
  rbok)              CFG="$TK/examples/rbok.config.sh" ;;
  42t|42-training)   CFG="$TK/examples/42t.config.sh" ;;
  *)                 CFG="$CFG_ARG" ;;
esac
[ -f "$CFG" ] || { echo "config not found: $CFG" >&2; exit 1; }
source "$CFG"

source "$TK/lib/audit_log.sh"
source "$TK/lib/governance_check.sh"

: "${GH_REPO:?}" "${GH_CONFIG_DIR:?}" "${DEFAULT_BRANCH:=main}"
: "${PR_MERGE_CI_INTERVAL_SEC:=30}" "${PR_MERGE_CI_TIMEOUT_SEC:=600}"

audit "PR #${PR} approve+merge attempt (--squash)"

# Step 1: poll CI up to timeout.
elapsed=0
status="pending"
while [ "$elapsed" -lt "$PR_MERGE_CI_TIMEOUT_SEC" ]; do
  status=$(gov_pr_check_status "$GH_REPO" "$PR")
  case "$status" in
    pass) break ;;
    fail)
      checks=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh pr view "$PR" --repo "$GH_REPO" \
                --json statusCheckRollup 2>/dev/null \
                | jq -r '.statusCheckRollup[]? | "\(.name)=\(.conclusion // .status)"' \
                | tr '\n' ',' | sed 's/,$//')
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
  audit "PR #${PR} CI TIMEOUT after ${elapsed}s — refusing merge"
  exit 3
fi

# Step 2: try plain squash merge first.
if GH_CONFIG_DIR="$GH_CONFIG_DIR" gh pr merge "$PR" --repo "$GH_REPO" --squash --auto 2>/dev/null; then
  audit "PR #${PR} merged (--squash)"
  exit 0
fi

# Step 3: read mergeStateStatus to decide if admin bypass is appropriate.
merge_state=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh pr view "$PR" --repo "$GH_REPO" \
               --json mergeStateStatus 2>/dev/null | jq -r '.mergeStateStatus // "UNKNOWN"')

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

GH_TOKEN="$APPROVE_TOKEN" gh pr review "$PR" --repo "$GH_REPO" --approve \
  --body "Orchestrator review — CI green, branch-protection bypass." 2>&1 | tail -3 || true

if GH_TOKEN="$APPROVE_TOKEN" gh pr merge "$PR" --repo "$GH_REPO" --squash --admin 2>/dev/null; then
  audit "PR #${PR} merged (--squash, admin-approved)"
  exit 0
fi

audit "PR #${PR} MERGE FAILED — admin merge rejected (state: $merge_state)"
exit 7
