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
#  10 merge-hold engaged (kill-switch active or PR_MERGE_HOLD=1)
#  11 final pre-merge re-verify refused (head SHA changed, or rollup is no
#     longer all-green / not-applicable just before `gh pr merge`)
#  12 deploy gate refused or timed out after a deploy-triggering merge,
#     or the downstream critical-smoke gate (#654) refused or timed out
#     while waiting for the smoke workflow_run of the prior merge SHA
#
# Downstream smoke gate (#654):
#   - Opt-in via PR_MERGE_DEPLOY_GATE_SMOKE_WORKFLOW_NAME=<workflow name>.
#     When set, after Deploy DEV reports a safe conclusion for a merge SHA
#     on the deploy branch, pr_merge ALSO waits for the smoke workflow_run
#     for the SAME headSha to complete with a safe conclusion before
#     releasing the next merge attempt.
#   - Headed by `held_pr=` and `held_sha=` audit fields so dashboards can
#     name the PR that is paused, the SHA whose smoke is gating it, the
#     required workflow, and the observed run id/status/conclusion plus
#     the release condition.
#   - SAFE_CONCLUSIONS default to `success`; operators can opt into
#     accepting `skipped`/`neutral` per repo via
#     PR_MERGE_DEPLOY_GATE_SMOKE_SAFE_CONCLUSIONS when paths-filter skips
#     are legitimate for the smoke workflow.
#
# Refusal observability:
#   Every nonzero exit emits an audit line that includes the underlying forge
#   error (truncated) and a stable refusal category ("missing-required-check",
#   "review-required", "branch-protection", "draft", "conflict",
#   "permission-denied", "auto-merge-disallowed", "merge-method-disallowed",
#   "policy-refused", "unknown") so dashboards can group failures without
#   parsing free-form text.
#
# Forge access (#816):
#   - Every read and every mutation goes through the provider adapter
#     (`ordo_provider`, lib/ordo_provider_adapter.sh): the same script runs
#     on GitHub, Forgejo and GitLab. Enum values are projected back to the
#     upper-case vocabulary of the audit lines (state=CLOSED,
#     mergeStateStatus=DIRTY, checks=ci=FAILURE, ...).
#   - Mutations are gated by ORCH_EXTERNAL_PR_MUTATIONS like every adapter
#     mutation (scopes: pr_ready, pr_merge, pr_review, issue_comment,
#     issue_close, issue_labels; `all` covers them). A refused mutation is
#     audited with reason=policy-refused and never reaches the forge.
#   - Mutations are idempotent: keys are derived from the repo, the PR and
#     the head SHA (`pr_merge:<repo>#<n>:<sha>`), so a retry after a crash
#     replays the recorded receipt instead of merging twice.
#   - Closing-issue references come from the PR title/body keywords
#     (Closes/Fixes/Resolves #n) on every forge; GitHub sidebar-only links
#     are not visible through the neutral PR shape.
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
source "$TK/lib/ordo_provider_adapter.sh"

: "${GH_REPO:?}" "${GH_CONFIG_DIR:?}" "${DEFAULT_BRANCH:=main}"
: "${PR_MERGE_CI_INTERVAL_SEC:=30}" "${PR_MERGE_CI_TIMEOUT_SEC:=600}"
: "${PR_MERGE_GH_RETRY_MAX:=3}" "${PR_MERGE_GH_RETRY_BACKOFF_SEC:=5}"
: "${PR_MERGE_DISABLE_AUTO_ON_REFUSE:=1}"
: "${PR_MERGE_POST_CLEANUP:=1}"
# Risk-based no-check merge policy (#117). Off by default so existing
# behaviour is unchanged; opt in by setting PR_MERGE_NO_CHECK_POLICY=1
# in the per-project config that pr_merge consumes.
: "${PR_MERGE_NO_CHECK_POLICY:=0}"
# Merge hold / kill-switch (#370). When set to 1 (or when the autonomous
# PR ops kill-switch state file is present), refuse every merge attempt
# before any gh mutation. Dispatch / fix / rebase paths do not consult
# this variable, so operators can keep working while merges are paused.
: "${PR_MERGE_HOLD:=0}"
: "${PR_MERGE_DEPLOY_GATE:=auto}"
: "${PR_MERGE_DEPLOY_GATE_WORKFLOW_NAME:=Deploy DEV}"
: "${PR_MERGE_DEPLOY_GATE_RUN_LIMIT:=20}"
: "${PR_MERGE_DEPLOY_GATE_INTERVAL_SEC:=30}"
: "${PR_MERGE_DEPLOY_GATE_TIMEOUT_SEC:=900}"
: "${PR_MERGE_DEPLOY_GATE_SAFE_CONCLUSIONS:=success}"
# Downstream smoke gate (#654). After Deploy DEV completes successfully for
# a merge SHA on the deploy branch, also wait for the downstream critical
# smoke workflow_run for the SAME SHA before releasing the next merge.
# Empty workflow name disables the smoke gate (default) so repos without a
# critical smoke workflow keep the legacy single-workflow behaviour. When
# set, missing/pending/failed/skipped smoke runs hold the merge train.
: "${PR_MERGE_DEPLOY_GATE_SMOKE_WORKFLOW_NAME:=}"
: "${PR_MERGE_DEPLOY_GATE_SMOKE_INTERVAL_SEC:=}"
: "${PR_MERGE_DEPLOY_GATE_SMOKE_TIMEOUT_SEC:=}"
: "${PR_MERGE_DEPLOY_GATE_SMOKE_SAFE_CONCLUSIONS:=success}"
# GitFlow issue reconciliation (#116). When a PR merges into a non-default
# branch, GitHub will not auto-close closing issue references. Default to a
# validation gate comment so GitFlow projects can preserve evidence without
# prematurely closing work before promotion reaches the repository default.
: "${PR_MERGE_ISSUE_RECONCILE:=1}"
: "${PR_MERGE_ISSUE_RECONCILE_MODE:=gate}"
: "${PR_MERGE_ISSUE_RECONCILE_GATE_LABEL:=}"

# pr_merge_provider <op> [args...]: one provider-adapter read; stderr is
# dropped (callers treat an empty payload as "unknown", as they did a gh
# failure).
pr_merge_provider() {
  GH_CONFIG_DIR="$GH_CONFIG_DIR" ordo_provider "$@" 2>/dev/null
}

# provider_retry <op> [args...]: run one provider-adapter call, retrying on
# transient failures (details.retryable=true in the adapter's error object)
# with exponential backoff, up to PR_MERGE_GH_RETRY_MAX attempts. On success
# the payload/receipt goes to fd 1; on final failure the error message
# (which embeds the forge's own refusal text) goes to fd 2 and the adapter's
# exit code is returned, so callers can `2>&1 >/dev/null` and classify the
# refusal as before.
provider_retry() {
  local attempt=0 backoff="$PR_MERGE_GH_RETRY_BACKOFF_SEC" out err err_file rc
  while :; do
    attempt=$((attempt + 1))
    rc=0
    err_file=$(mktemp)
    out=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" ordo_provider "$@" 2> "$err_file") || rc=$?
    err=$(cat "$err_file")
    rm -f "$err_file"
    if [ "$rc" -eq 0 ]; then
      printf '%s\n' "$out"
      return 0
    fi
    if printf '%s' "$err" | jq -e '.error.details.retryable == true' >/dev/null 2>&1; then
      if [ "$attempt" -lt "$PR_MERGE_GH_RETRY_MAX" ]; then
        audit "provider transient error (attempt ${attempt}/${PR_MERGE_GH_RETRY_MAX}, retry in ${backoff}s)"
        sleep "$backoff"
        backoff=$((backoff * 2))
        continue
      fi
    fi
    local message
    message=$(printf '%s' "$err" | jq -r '.error.message // empty' 2>/dev/null)
    printf '%s\n' "${message:-$err}" >&2
    return "$rc"
  done
}

disable_auto_merge_if_enabled() {
  local pr=${1:?usage: disable_auto_merge_if_enabled <pr>}
  [ "${PR_MERGE_DISABLE_AUTO_ON_REFUSE}" = "1" ] || return 0

  local pr_json auto_state head
  pr_json=$(pr_merge_provider pr_get "$pr" --repo "$GH_REPO" || true)
  auto_state=$(printf '%s' "$pr_json" | jq -r 'select(.auto_merge == true) | "enabled"' 2>/dev/null || true)
  [ -n "$auto_state" ] || return 0
  head=$(printf '%s' "$pr_json" | jq -r '.head.sha // "unknown"' 2>/dev/null)

  if provider_retry pr_merge "$pr" --repo "$GH_REPO" --disable-auto \
       --idempotency-key "pr_merge.disable_auto:${GH_REPO}#${pr}:${head}" >/dev/null 2>&1; then
    audit "PR #${pr} auto-merge disabled before refusal"
  else
    audit "PR #${pr} auto-merge disable failed before refusal"
  fi
}

# classify_merge_refusal: map a forge/adapter error message to a stable refusal
# category, so audit consumers can group "missing required check" vs
# "review required" vs "branch protection" without parsing free-form text.
classify_merge_refusal() {
  local raw=${1:-}
  local msg
  msg=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  case "$msg" in
    *"refused by the external mutation policy"*|*"external_pr_mutation_refused"*|*"policy_refused"*)
      printf 'policy-refused' ;;
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

pr_merge_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

pr_merge_deploy_gate_branch_enabled() {
  local branch=${1:?usage: pr_merge_deploy_gate_branch_enabled <branch>}
  local mode=${PR_MERGE_DEPLOY_GATE:-auto}
  local branches=${PR_MERGE_DEPLOY_GATE_BRANCHES:-}
  local candidate

  case "$mode" in
    0|false|FALSE|no|NO|off|OFF) return 1 ;;
  esac

  if [ -z "$branches" ]; then
    if pr_merge_truthy "$mode"; then
      branches="$DEFAULT_BRANCH"
    else
      # Auto mode is deliberately narrow: common GitFlow deploy branches get
      # serialized without forcing non-deploying main-only repos to wait.
      branches="develop"
    fi
  fi

  for candidate in $(printf '%s' "$branches" | tr ',' ' '); do
    case "$candidate" in
      "*"|"$branch") return 0 ;;
    esac
  done
  return 1
}

pr_merge_deploy_gate_safe_conclusion() {
  local conclusion=${1:-}
  local candidate
  for candidate in $(printf '%s' "$PR_MERGE_DEPLOY_GATE_SAFE_CONCLUSIONS" | tr ',' ' '); do
    [ "$conclusion" = "$candidate" ] && return 0
  done
  return 1
}

pr_merge_smoke_gate_safe_conclusion() {
  local conclusion=${1:-}
  local candidate
  for candidate in $(printf '%s' "$PR_MERGE_DEPLOY_GATE_SMOKE_SAFE_CONCLUSIONS" | tr ',' ' '); do
    [ "$conclusion" = "$candidate" ] && return 0
  done
  return 1
}

# pr_merge_latest_workflow_run: return the most recent workflow run for
# the given workflow name on the given branch as a TSV row of
# `databaseId|status|conclusion|headSha|createdAt|url`. Optional filters:
#   min_created_at — only consider runs created at or after this ISO date.
#   head_sha       — only consider runs whose headSha matches this value
#                    (used by the smoke gate to correlate the smoke run
#                    with the exact merge SHA the deploy validated, #654).
# Returns exit 2 when the adapter produces no run list so the caller can
# distinguish "forge failed / repo lacks workflow runs" from "no runs match".
pr_merge_latest_workflow_run() {
  local branch=${1:?usage: pr_merge_latest_workflow_run <branch> <workflow-name> [min-created-at] [head-sha]}
  local workflow_name=${2:?usage: pr_merge_latest_workflow_run <branch> <workflow-name> [min-created-at] [head-sha]}
  local min_created_at=${3:-}
  local head_sha=${4:-}
  local runs

  runs=$(pr_merge_provider run_list \
    --repo "$GH_REPO" \
    --branch "$branch" \
    --limit "$PR_MERGE_DEPLOY_GATE_RUN_LIMIT" \
    | jq -c '.items' 2>/dev/null || true)

  if ! printf '%s' "$runs" | jq -e 'type == "array"' >/dev/null 2>&1; then
    return 2
  fi

  printf '%s' "$runs" | jq -r \
    --arg workflow_name "$workflow_name" \
    --arg min_created_at "$min_created_at" \
    --arg head_sha "$head_sha" '
      map(select((.name // "") == $workflow_name or (.workflow // "") == $workflow_name))
      | if $min_created_at != "" then
          map(select((.created_at // "") >= $min_created_at))
        else
          .
        end
      | if $head_sha != "" then
          map(select((.head_sha // "") == $head_sha))
        else
          .
        end
      | sort_by(.created_at, .id)
      | last // empty
      | select(. != null)
      | [
          (.id | tostring),
          (.status // ""),
          (.conclusion // "-"),
          (.head_sha // ""),
          (.created_at // ""),
          (.url // "-")
        ]
      | @tsv
    ' 2>/dev/null
}

# pr_merge_latest_deploy_run kept as a thin wrapper for backwards
# compatibility — callers that only need the configured Deploy DEV
# workflow lookup continue to work unchanged.
pr_merge_latest_deploy_run() {
  local branch=${1:?usage: pr_merge_latest_deploy_run <branch> [min-created-at]}
  local min_created_at=${2:-}
  pr_merge_latest_workflow_run "$branch" "$PR_MERGE_DEPLOY_GATE_WORKFLOW_NAME" "$min_created_at" ""
}

pr_merge_wait_deploy_gate() {
  local phase=${1:?usage: pr_merge_wait_deploy_gate <phase> <branch> [min-created-at]}
  local branch=${2:?usage: pr_merge_wait_deploy_gate <phase> <branch> [min-created-at]}
  local min_created_at=${3:-}

  pr_merge_deploy_gate_branch_enabled "$branch" || return 0

  if dry_run_enabled; then
    dry_run_note "PR #${PR} would wait for ${PR_MERGE_DEPLOY_GATE_WORKFLOW_NAME} on ${branch} (${phase})"
    if [ -n "${PR_MERGE_DEPLOY_GATE_SMOKE_WORKFLOW_NAME:-}" ]; then
      dry_run_note "PR #${PR} would wait for ${PR_MERGE_DEPLOY_GATE_SMOKE_WORKFLOW_NAME} on ${branch} for held merge SHA (${phase})"
    fi
    return 0
  fi

  local elapsed=0 interval timeout row rc run_id status conclusion sha created_at url
  interval=$PR_MERGE_DEPLOY_GATE_INTERVAL_SEC
  timeout=$PR_MERGE_DEPLOY_GATE_TIMEOUT_SEC
  case "$interval" in ''|*[!0-9]*|0) interval=1 ;; esac
  case "$timeout" in ''|*[!0-9]*) timeout=0 ;; esac

  while [ "$elapsed" -le "$timeout" ]; do
    rc=0
    row=$(pr_merge_latest_deploy_run "$branch" "$min_created_at") || rc=$?
    case "$rc" in
      0) ;;
      2)
        audit "PR #${PR} deploy gate skipped (${phase}) — unable to read ${PR_MERGE_DEPLOY_GATE_WORKFLOW_NAME} runs on ${branch}"
        return 0
        ;;
      *)
        row=""
        ;;
    esac

    if [ -n "$row" ]; then
      IFS=$'\t' read -r run_id status conclusion sha created_at url <<<"$row"
      if [ "$status" = "completed" ] && pr_merge_deploy_gate_safe_conclusion "$conclusion"; then
        audit "PR #${PR} deploy gate complete (${phase}) workflow=\"${PR_MERGE_DEPLOY_GATE_WORKFLOW_NAME}\" branch=${branch} run=${run_id} conclusion=${conclusion} sha=${sha:0:12} created=${created_at}"
        pr_merge_wait_smoke_gate "$phase" "$branch" "$sha" || return $?
        return 0
      fi
      if [ "$status" = "completed" ]; then
        audit "PR #${PR} deploy gate FAILED (${phase}) workflow=\"${PR_MERGE_DEPLOY_GATE_WORKFLOW_NAME}\" branch=${branch} run=${run_id} conclusion=${conclusion} sha=${sha:0:12} created=${created_at} url=${url}"
        return 12
      fi
      audit "PR #${PR} deploy gate pending (${phase}) workflow=\"${PR_MERGE_DEPLOY_GATE_WORKFLOW_NAME}\" branch=${branch} run=${run_id} status=${status:-unknown} sha=${sha:0:12} wait ${interval}s (${elapsed}/${timeout})"
    else
      if [ "$phase" = "pre-merge" ]; then
        audit "PR #${PR} deploy gate no current run (${phase}) workflow=\"${PR_MERGE_DEPLOY_GATE_WORKFLOW_NAME}\" branch=${branch} — proceeding"
        return 0
      fi
      audit "PR #${PR} deploy gate waiting for run (${phase}) workflow=\"${PR_MERGE_DEPLOY_GATE_WORKFLOW_NAME}\" branch=${branch} since=${min_created_at:-unknown} wait ${interval}s (${elapsed}/${timeout})"
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  audit "PR #${PR} deploy gate TIMEOUT (${phase}) workflow=\"${PR_MERGE_DEPLOY_GATE_WORKFLOW_NAME}\" branch=${branch} after=${elapsed}s"
  return 12
}

# pr_merge_wait_smoke_gate (#654): after Deploy DEV passes for a merge SHA,
# wait for the downstream critical smoke workflow_run on the SAME headSha
# before releasing the next merge. Returns 0 when the smoke workflow gate
# is disabled (default) or when the latest smoke run for that SHA reports
# a safe conclusion. Returns 12 when the smoke run is failed/skipped on the
# correlated SHA, when no smoke run ever appears for the SHA within
# PR_MERGE_DEPLOY_GATE_SMOKE_TIMEOUT_SEC, or when only smoke runs for a
# different SHA exist (which indicates the merge train moved on while the
# critical smoke was still pending).
pr_merge_wait_smoke_gate() {
  local phase=${1:?usage: pr_merge_wait_smoke_gate <phase> <branch> <head-sha>}
  local branch=${2:?usage: pr_merge_wait_smoke_gate <phase> <branch> <head-sha>}
  local head_sha=${3:-}
  local workflow_name=${PR_MERGE_DEPLOY_GATE_SMOKE_WORKFLOW_NAME:-}

  [ -n "$workflow_name" ] || return 0

  if [ -z "$head_sha" ]; then
    audit "PR #${PR} smoke gate skipped (${phase}) — no held_sha available for workflow=\"${workflow_name}\" on ${branch}"
    return 0
  fi

  local interval=${PR_MERGE_DEPLOY_GATE_SMOKE_INTERVAL_SEC:-$PR_MERGE_DEPLOY_GATE_INTERVAL_SEC}
  local timeout=${PR_MERGE_DEPLOY_GATE_SMOKE_TIMEOUT_SEC:-$PR_MERGE_DEPLOY_GATE_TIMEOUT_SEC}
  case "$interval" in ''|*[!0-9]*|0) interval=1 ;; esac
  case "$timeout" in ''|*[!0-9]*) timeout=0 ;; esac

  local elapsed=0 row rc run_id status conclusion sha created_at url
  while [ "$elapsed" -le "$timeout" ]; do
    rc=0
    row=$(pr_merge_latest_workflow_run "$branch" "$workflow_name" "" "$head_sha") || rc=$?
    case "$rc" in
      0) ;;
      2)
        audit "PR #${PR} smoke gate skipped (${phase}) — unable to read ${workflow_name} runs on ${branch} held_pr=#${PR} held_sha=${head_sha:0:12}"
        return 0
        ;;
      *)
        row=""
        ;;
    esac

    if [ -n "$row" ]; then
      IFS=$'\t' read -r run_id status conclusion sha created_at url <<<"$row"
      if [ "$status" = "completed" ] && pr_merge_smoke_gate_safe_conclusion "$conclusion"; then
        audit "PR #${PR} smoke gate complete (${phase}) workflow=\"${workflow_name}\" branch=${branch} held_pr=#${PR} held_sha=${sha:0:12} run=${run_id} status=${status} conclusion=${conclusion} created=${created_at} release=safe-conclusion"
        return 0
      fi
      if [ "$status" = "completed" ]; then
        audit "PR #${PR} smoke gate FAILED (${phase}) workflow=\"${workflow_name}\" branch=${branch} held_pr=#${PR} held_sha=${sha:0:12} run=${run_id} status=${status} conclusion=${conclusion} created=${created_at} url=${url} release=blocker"
        return 12
      fi
      audit "PR #${PR} smoke gate pending (${phase}) workflow=\"${workflow_name}\" branch=${branch} held_pr=#${PR} held_sha=${sha:0:12} run=${run_id} status=${status:-unknown} conclusion=${conclusion} wait ${interval}s (${elapsed}/${timeout})"
    else
      audit "PR #${PR} smoke gate waiting for run (${phase}) workflow=\"${workflow_name}\" branch=${branch} held_pr=#${PR} held_sha=${head_sha:0:12} wait ${interval}s (${elapsed}/${timeout})"
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  audit "PR #${PR} smoke gate TIMEOUT (${phase}) workflow=\"${workflow_name}\" branch=${branch} held_pr=#${PR} held_sha=${head_sha:0:12} after=${elapsed}s release=blocker"
  return 12
}

pr_merge_repo_default_branch() {
  pr_merge_provider repo_get --repo "$GH_REPO" \
    | jq -r '.default_branch // empty' 2>/dev/null
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
  # The neutral PR shape, projected onto the legacy meta fields this
  # reconciliation always consumed. Closing references come from the
  # title/body keywords (pr_merge_issue_refs_from_meta); no forge-specific
  # sidebar links.
  meta=$(pr_merge_provider pr_get "$pr" --repo "$GH_REPO" \
    | jq -c '{number: .number, title: (.title // ""), body: (.body // ""), url: (.url // ""),
              baseRefName: (.base.ref // ""), mergedAt: (.merged_at // ""),
              mergeCommit: (if (.merge_commit // "") != "" then {oid: .merge_commit} else null end),
              closingIssuesReferences: []}' 2>/dev/null || true)
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

  local merge_commit key_suffix body_file
  merge_commit=$(printf '%s' "$meta" | jq -r '.mergeCommit.oid // empty')
  key_suffix="pr${pr}:${merge_commit:-unknown}"

  while IFS= read -r issue; do
    [ -n "$issue" ] || continue
    comment_rc=0
    body_file=$(pr_merge_issue_reconcile_body "$mode" "$issue" "$meta" "$repo_default" \
      | gh_body_write_tempfile "pr_merge_reconcile") || comment_rc=$?
    if [ "$comment_rc" -eq 0 ]; then
      provider_retry issue_comment "$issue" --repo "$GH_REPO" --body-file "$body_file" \
        --idempotency-key "issue_comment.reconcile:${GH_REPO}#${issue}:${key_suffix}" >/dev/null 2>&1 \
        || comment_rc=$?
      rm -f "$body_file"
    fi
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
        provider_retry issue_edit "$issue" --repo "$GH_REPO" --state closed --reason completed \
          --idempotency-key "issue_close.reconcile:${GH_REPO}#${issue}:${key_suffix}" >/dev/null 2>&1 || close_rc=$?
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
          provider_retry issue_labels "$issue" --repo "$GH_REPO" \
            --add "$PR_MERGE_ISSUE_RECONCILE_GATE_LABEL" \
            --idempotency-key "issue_labels.reconcile:${GH_REPO}#${issue}:${key_suffix}:${PR_MERGE_ISSUE_RECONCILE_GATE_LABEL}" \
            >/dev/null 2>&1 || label_rc=$?
        fi
        [ "$label_rc" -eq 0 ] \
          || audit "PR #${pr} issue_reconcile gate_label_failed issue=#${issue} label=${PR_MERGE_ISSUE_RECONCILE_GATE_LABEL} rc=${label_rc}"
      fi
      audit "PR #${pr} issue_reconcile validation_gate issue=#${issue} base=${base_ref} default=${repo_default}"
    fi
  done <<< "$issues"
}

run_post_merge_cleanup() {
  [ "${PR_MERGE_POST_CLEANUP}" = "1" ] || return 0
  [ -x "$TK/scripts/post_merge_cleanup.sh" ] || {
    audit "PR #${PR} post-merge cleanup skipped — helper unavailable"
    return 0
  }

  local cleanup_rc
  local -a cleanup_args=("$CFG_ARG" "$PR" --tsv --assume-merged)
  if [ -n "${POST_MERGE_HEAD_BRANCH:-}" ]; then
    cleanup_args+=(--merged-branch "$POST_MERGE_HEAD_BRANCH")
  fi
  set +e
  bash "$TK/scripts/post_merge_cleanup.sh" "${cleanup_args[@]}" >&2
  cleanup_rc=$?
  set -e
  if [ "$cleanup_rc" -ne 0 ]; then
    audit "PR #${PR} post-merge cleanup warning rc=${cleanup_rc}"
  fi
}

audit "PR #${PR} approve+merge attempt (--squash)"

# Merge-hold / kill-switch (#370). Refuse before any gh mutation when:
#   * PR_MERGE_HOLD=1, OR
#   * the autonomous-pr-ops kill-switch file is present.
# This pauses merges only — dispatch / fix / rebase callers never source
# this script, so they keep working. The audit line names the source of
# the hold so operators can locate the release path.
pr_merge_hold_active() {
  case "${PR_MERGE_HOLD:-0}" in
    1|true|TRUE|yes|YES|on|ON)
      printf 'PR_MERGE_HOLD=%s' "${PR_MERGE_HOLD}"
      return 0
      ;;
  esac
  if declare -F auto_pr_ops_kill_switch_active >/dev/null 2>&1; then
    if auto_pr_ops_kill_switch_active; then
      printf 'kill-switch=%s' "$(auto_pr_ops_kill_switch_path 2>/dev/null || printf 'unknown')"
      return 0
    fi
  elif [ -f "$TK/lib/autonomous_pr_ops.sh" ]; then
    # shellcheck source=lib/autonomous_pr_ops.sh
    . "$TK/lib/autonomous_pr_ops.sh"
    if declare -F auto_pr_ops_kill_switch_active >/dev/null 2>&1 \
       && auto_pr_ops_kill_switch_active; then
      printf 'kill-switch=%s' "$(auto_pr_ops_kill_switch_path 2>/dev/null || printf 'unknown')"
      return 0
    fi
  fi
  return 1
}
if hold_reason=$(pr_merge_hold_active); then
  audit "PR #${PR} MERGE HELD — refusing merge (source=${hold_reason})"
  exit 10
fi

# Capture the PR's head SHA up front so every gate (poll loop, final
# re-verify, audit lines) can pin its decision to the exact commit we
# intend to merge (#370). An empty oid means gh failed; downstream code
# treats that as a refusal because we cannot prove the rollup belongs to
# the head we are about to merge.
INITIAL_HEAD_OID=$(gov_pr_head_oid "$GH_REPO" "$PR")
if [ -n "$INITIAL_HEAD_OID" ]; then
  audit "PR #${PR} head SHA captured oid=${INITIAL_HEAD_OID:0:12}"
else
  audit "PR #${PR} head SHA unavailable — proceeding cautiously"
fi

# Risk-based no-check policy (#117): if the operator opted in and the PR's
# scope is path-filtered (docs-only / .github/workflows-only / mixed of the
# two), latch this fact early so the poll loop and the dry-run branch can
# substitute "not-applicable" for "pending" once the rollup is confirmed
# empty. The latch is computed once to avoid repeated pr_files round-trips
# inside the poll loop.
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
# Otherwise the later squash merge returns
# "Pull Request is still a draft (mergePullRequest)" and the script
# silently escalates to admin fallback (which also fails — --admin
# bypasses branch protection, not draft state).
is_draft=$(pr_merge_provider pr_get "$PR" --repo "$GH_REPO" | jq -r '.draft // false')
if [ "$is_draft" = "true" ]; then
  if dry_run_enabled; then
    dry_run_note "PR #${PR} is draft — would call gh pr ready $PR"
  else
    # `audit_log.sh` enables `set -e`, so capture the rc explicitly via
    # `|| rc=$?` rather than `cmd; rc=$?` — the latter would exit on failure
    # and we would never reach the audit line that surfaces the gh stderr.
    ready_rc=0
    ready_err=$(provider_retry pr_ready "$PR" --repo "$GH_REPO" \
      --idempotency-key "pr_ready:${GH_REPO}#${PR}:${INITIAL_HEAD_OID:-unknown}" 2>&1 >/dev/null) || ready_rc=$?
    if [ "$ready_rc" -eq 0 ]; then
      audit "PR #${PR} marked ready (was draft)"
    else
      audit "PR #${PR} ready FAILED — refusing merge (reason=draft, rc=${ready_rc}): $(truncate_stderr "$ready_err")"
      exit 4
    fi
  fi
fi

if dry_run_enabled; then
  meta=$(pr_merge_provider pr_get "$PR" --repo "$GH_REPO")
  pr_state=$(printf '%s' "$meta" | jq -r '(.state // "unknown") | ascii_upcase')
  merge_state=$(printf '%s' "$meta" | jq -r '(.merge_state // "unknown") | ascii_upcase')
  mergeable=$(printf '%s' "$meta" | jq -r '(.mergeable // "unknown") | ascii_upcase')

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
      checks=$(pr_merge_provider checks_get "$PR" --repo "$GH_REPO" \
                | jq -r '.checks[]? | "\(.name)=\((.conclusion // .status) | ascii_upcase)"' \
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
    pr_merge_wait_deploy_gate "pre-merge" "$DEFAULT_BRANCH" "" || exit $?
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
  meta=$(pr_merge_provider pr_get "$PR" --repo "$GH_REPO")
  pr_state=$(printf '%s' "$meta" | jq -r '(.state // "unknown") | ascii_upcase')
  merge_state_poll=$(printf '%s' "$meta" | jq -r '(.merge_state // "unknown") | ascii_upcase')
  mergeable_poll=$(printf '%s' "$meta" | jq -r '(.mergeable // "unknown") | ascii_upcase')

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
      checks=$(pr_merge_provider checks_get "$PR" --repo "$GH_REPO" \
                | jq -r '.checks[]? | "\(.name)=\((.conclusion // .status) | ascii_upcase)"' \
                | tr '\n' ',' | sed 's/,$//')
      disable_auto_merge_if_enabled "$PR"
      audit "PR #${PR} CI GATE FAILED — refusing merge (head=${INITIAL_HEAD_OID:0:12} checks=${checks} reason=ci-fail)"
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
  audit "PR #${PR} CI TIMEOUT after ${elapsed}s — refusing merge (head=${INITIAL_HEAD_OID:0:12} reason=ci-timeout)"
  exit 3
fi

# Read mergeability before any mutating step so dry-run can exit cleanly.
merge_meta=$(pr_merge_provider pr_get "$PR" --repo "$GH_REPO")
merge_state=$(printf '%s' "$merge_meta" | jq -r '(.merge_state // "unknown") | ascii_upcase')
POST_MERGE_HEAD_BRANCH=$(printf '%s' "$merge_meta" | jq -r '.head.ref // ""')

# Final pre-merge re-verify (#370). Between the poll loop and the actual
# merge call, the PR head can change (a fresh push) or the rollup
# can flip to FAILURE (a long-running check completing in the gap). The
# poll-loop status is therefore necessary but not sufficient: re-read the
# evidence right now, pinned to the head SHA we captured up front, and
# refuse if it is not all-green or an explicitly authorised
# not-applicable. ORDO policy wins over forge branch protection — the forge
# may accept the merge, but pr_merge will not request it.
final_evidence=$(gov_pr_check_evidence "$GH_REPO" "$PR")
final_head=${final_evidence%%|*}
rest=${final_evidence#*|}
final_status=${rest%%|*}
final_names=${rest#*|}

if [ -n "$INITIAL_HEAD_OID" ] && [ -n "$final_head" ] \
   && [ "$final_head" != "unknown" ] && [ "$final_head" != "$INITIAL_HEAD_OID" ]; then
  disable_auto_merge_if_enabled "$PR"
  audit "PR #${PR} HEAD SHA CHANGED mid-merge — refusing merge (was=${INITIAL_HEAD_OID:0:12} now=${final_head:0:12} checks=${final_names})"
  exit 11
fi

case "$final_status" in
  pass) ;;
  empty)
    if [ "$NO_CHECK_POLICY_ELIGIBLE" -eq 1 ]; then
      audit "PR #${PR} CI not-applicable evidence (head=${final_head:0:12} scope=${NO_CHECK_POLICY_SCOPE} checks=none) — proceeding"
      status="not-applicable"
    else
      disable_auto_merge_if_enabled "$PR"
      audit "PR #${PR} POLICY GATE REFUSED — empty rollup without no-check policy (head=${final_head:0:12} checks=none reason=missing-evidence)"
      exit 11
    fi
    ;;
  fail|pending|*)
    disable_auto_merge_if_enabled "$PR"
    audit "PR #${PR} POLICY GATE REFUSED — fresh evidence is ${final_status} (head=${final_head:0:12} checks=${final_names} reason=stale-poll-result)"
    exit 11
    ;;
esac

pr_merge_wait_deploy_gate "pre-merge" "$DEFAULT_BRANCH" "" || exit $?

# Step 2: try plain squash merge first (with transient-error retry).
# Deliberately avoid `--auto`: deferred auto-merge can fire after the CI
# surface changes, which defeats the fresh gate this script just evaluated.
# `|| merge_rc=$?` keeps the captured stderr available for the audit lines
# below — without it, `set -e` (from audit_log.sh) would exit before we
# could surface the underlying refusal reason.
merge_started_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
merge_rc=0
merge_err=$(provider_retry pr_merge "$PR" --repo "$GH_REPO" --method squash \
  --idempotency-key "pr_merge:${GH_REPO}#${PR}:${final_head:-unknown}" 2>&1 >/dev/null) || merge_rc=$?
if [ "$merge_rc" -eq 0 ]; then
  if [ "$status" = "not-applicable" ]; then
    audit "PR #${PR} merged (--squash, no-check policy: scope=${NO_CHECK_POLICY_SCOPE} head=${final_head:0:12} checks=${final_names})"
  else
    audit "PR #${PR} merged (--squash, head=${final_head:0:12} checks=${final_names})"
  fi
  pr_merge_reconcile_issues "$PR"
  run_post_merge_cleanup
  pr_merge_wait_deploy_gate "post-merge" "$DEFAULT_BRANCH" "$merge_started_at" || exit $?
  exit 0
fi

merge_reason=$(classify_merge_refusal "$merge_err")
merge_err_short=$(truncate_stderr "$merge_err")

# The external mutation policy refused the merge (ORCH_EXTERNAL_PR_MUTATIONS
# does not include pr_merge): nothing reached the forge and no fallback can
# help — surface the scope the operator must authorise.
if [ "$merge_reason" = "policy-refused" ]; then
  audit "PR #${PR} MERGE REFUSED — external mutation policy (scope=pr_merge state=${merge_state} reason=${merge_reason} rc=${merge_rc}) authorize via ORCH_EXTERNAL_PR_MUTATIONS: ${merge_err_short}"
  exit 4
fi

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

# The approval has no dedicated adapter op yet: the gated `mutate` escape
# hatch carries the native review arguments (gh-shaped on the github backend).
# TODO(#816): needs op pr_review (approve|request_changes|comment) in the
# provider adapter for a forge-neutral admin fallback.
approve_rc=0
approve_err=$(GH_TOKEN="$APPROVE_TOKEN" provider_retry mutate --scope pr_review --repo "$GH_REPO" \
  --idempotency-key "pr_review.approve:${GH_REPO}#${PR}:${final_head:-unknown}" \
  -- pr review "$PR" --repo "$GH_REPO" --approve \
  --body "Orchestrator review — CI green, branch-protection bypass." 2>&1 >/dev/null) || approve_rc=$?
if [ "$approve_rc" -ne 0 ]; then
  audit "PR #${PR} admin approve rc=${approve_rc} (continuing to admin merge): $(truncate_stderr "$approve_err")"
fi

admin_rc=0
merge_started_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
admin_err=$(GH_TOKEN="$APPROVE_TOKEN" provider_retry pr_merge "$PR" --repo "$GH_REPO" --method squash --admin \
  --idempotency-key "pr_merge.admin:${GH_REPO}#${PR}:${final_head:-unknown}" 2>&1 >/dev/null) || admin_rc=$?
if [ "$admin_rc" -eq 0 ]; then
  audit "PR #${PR} merged (--squash, admin-approved, head=${final_head:0:12} checks=${final_names})"
  pr_merge_reconcile_issues "$PR"
  run_post_merge_cleanup
  pr_merge_wait_deploy_gate "post-merge" "$DEFAULT_BRANCH" "$merge_started_at" || exit $?
  exit 0
fi

admin_reason=$(classify_merge_refusal "$admin_err")
audit "PR #${PR} MERGE FAILED — admin merge rejected (state=${merge_state} reason=${admin_reason} rc=${admin_rc}): $(truncate_stderr "$admin_err")"
exit 7
