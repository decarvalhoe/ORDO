#!/usr/bin/env bash
# scripts/pr_merge_wave.sh — merge all PRs of a wave (matching a branch regex)
# in a sequential, CI-gated, alembic-aware order.
#
# Usage:
#   pr_merge_wave.sh <project_short|config_path> <wave_label> <branch_regex> [--no-admin-fallback]
#
# Examples:
#   pr_merge_wave.sh rbok wave1 '^feat/api-ns-0[2-6]'
#   pr_merge_wave.sh rbok wave3 '^feat/api-ns-1[1-3]' --no-admin-fallback
#
# Behavior:
#   1. Lists open PRs against DEFAULT_BRANCH whose headRefName matches the regex.
#   2. Sorts by PR number ascending (stable, predictable order).
#   3. For each PR:
#        a. If PR is BEHIND (default branch moved since base) → skip with WARN
#           (caller must trigger a rebase on the agent's clone, then re-run).
#        b. If PR has alembic migrations and there's already an open PR with a
#           migration earlier in the queue → WARN (multiple heads risk).
#        c. Calls pr_merge.sh for the PR (CI gate + admin fallback).
#        d. After merge, sleeps PR_MERGE_WAVE_INTER_PR_SLEEP (default 30s) so
#           develop deploy + status webhooks settle.
#   4. Emits final summary.
#
# Surviving log signatures:
#   WAVE_MERGE start project=<id> wave=<label> regex=<re> matched=<N>
#   WAVE_MERGE step #<pr> branch=<br> action=<merge|skip-behind|skip-alembic|fail>
#   WAVE_MERGE end wave=<label> ok=<n> skipped=<n> failed=<n>
#
# Exit codes:
#   0 — all matched PRs merged OR cleanly skipped (no failures)
#   1 — at least one merge failed
#   2 — config / args error
set -o pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/dry_run.sh"
source "$TK/lib/config_resolver.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

CFG_ARG=${1:?usage: pr_merge_wave.sh <project> <wave_label> <branch_regex> [--no-admin-fallback] [--dry-run]}
WAVE=${2:?missing wave label}
REGEX=${3:?missing branch regex}
shift 3

EXTRA_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-admin-fallback) EXTRA_ARGS+=("$1") ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

load_project_config "$CFG_ARG"

source "$TK/lib/audit_log.sh"

: "${GH_REPO:?}" "${GH_CONFIG_DIR:?}" "${DEFAULT_BRANCH:=main}"
: "${PR_MERGE_WAVE_INTER_PR_SLEEP:=30}"

# 1. Find PRs.
matched=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh pr list \
  --repo "$GH_REPO" \
  --base "$DEFAULT_BRANCH" \
  --state open \
  --json number,headRefName,mergeable,mergeStateStatus,title \
  --limit 50 2>/dev/null \
  | jq -r --arg re "$REGEX" '
      .[] | select(.headRefName | test($re))
      | "\(.number)|\(.headRefName)|\(.mergeable)|\(.mergeStateStatus)|\(.title)"' 2>/dev/null \
  | sort -n -t'|' -k1)

count=$(printf '%s' "$matched" | grep -c . || true)
audit "WAVE_MERGE start project=$PROJECT wave=$WAVE regex=${REGEX} matched=${count}"

if [ "$count" -eq 0 ]; then
  audit "WAVE_MERGE end wave=$WAVE ok=0 skipped=0 failed=0 (no matching PRs)"
  exit 0
fi

ok=0
skipped=0
failed=0
declare -a SKIP_REASONS=()

# 2. Helper: detect alembic migration in a PR (looks for changed files under */migrations/versions/).
pr_has_alembic_migration() {
  local pr="$1"
  GH_CONFIG_DIR="$GH_CONFIG_DIR" gh pr view "$pr" --repo "$GH_REPO" \
    --json files 2>/dev/null \
    | jq -r '.files[]?.path' 2>/dev/null \
    | grep -qE '(^|/)migrations/versions/.*\.py$|(^|/)alembic/versions/.*\.py$'
}

# 3. Iterate, merge, settle.
seen_alembic_pr=""
while IFS='|' read -r pr branch mergeable merge_state title; do
  [ -z "$pr" ] && continue

  audit "WAVE_MERGE step #${pr} branch=${branch} mergeable=${mergeable} state=${merge_state} title=\"$title\""

  # 3a. Skip BEHIND — agent must rebase first.
  if [ "$merge_state" = "BEHIND" ]; then
    audit "WAVE_MERGE step #${pr} action=skip-behind — agent must rebase + push"
    SKIP_REASONS+=("#${pr} BEHIND (rebase needed on ${branch})")
    skipped=$((skipped+1))
    continue
  fi

  # 3b. Alembic head coordination — at most one PR with migration per merge wave.
  if pr_has_alembic_migration "$pr"; then
    if [ -n "$seen_alembic_pr" ]; then
      audit "WAVE_MERGE step #${pr} action=skip-alembic — PR #${seen_alembic_pr} already has migration this wave (multiple heads risk)"
      SKIP_REASONS+=("#${pr} alembic conflict with #${seen_alembic_pr} (defer to next wave)")
      skipped=$((skipped+1))
      continue
    fi
    seen_alembic_pr="$pr"
    audit "WAVE_MERGE step #${pr} alembic-migration detected — proceeding (sole migration this wave)"
  fi

  # 3c. Delegate to pr_merge.sh (handles CI gate + admin fallback).
  child_args=("$CFG_ARG" "$pr" "${EXTRA_ARGS[@]}")
  if dry_run_enabled; then
    child_args+=(--dry-run)
  fi

  if bash "$TK/lib/pr_merge.sh" "${child_args[@]}"; then
    audit "WAVE_MERGE step #${pr} action=merge OK"
    ok=$((ok+1))
  else
    rc=$?
    audit "WAVE_MERGE step #${pr} action=fail rc=$rc"
    failed=$((failed+1))
  fi

  # 3d. Settle: let CI redeploy + webhook status propagate before next merge.
  if [ "$ok$failed" != "0$failed" ]; then
    if dry_run_enabled; then
      dry_run_note "sleep $PR_MERGE_WAVE_INTER_PR_SLEEP"
    else
      sleep "$PR_MERGE_WAVE_INTER_PR_SLEEP"
    fi
  fi
done <<<"$matched"

audit "WAVE_MERGE end wave=$WAVE ok=$ok skipped=$skipped failed=$failed"
if [ ${#SKIP_REASONS[@]} -gt 0 ]; then
  audit "WAVE_MERGE skipped reasons:"
  for r in "${SKIP_REASONS[@]}"; do
    audit "  - $r"
  done
fi

[ "$failed" -eq 0 ] || exit 1
exit 0
