#!/usr/bin/env bash
# dispatch_workdir_preflight.sh — workdir/origin-vs-canonical preflight for
# direct (non-portfolio) dispatches.
#
# Issue #683: a fleet slot's `AGENT_WORKDIR` is one clone per slot. When the
# operator dispatches a project whose canonical clone differs from the fleet
# slot's actual `git remote get-url origin`, the brief lands in a
# wrong-remote pane and the worker has to refuse via the post-dispatch
# context-mismatch guard (PR #662 / fix/656). The portfolio/matrix path
# already refuses with `duplicate_clone_remote_mismatch`
# (`scripts/dispatch_ticket.sh` ~line 744) but the non-portfolio direct
# dispatch path has no such check. This helper closes that gap so a
# cross-project direct dispatch refuses BEFORE worktree creation, tmux
# respawn, and the brief paste — instead of pasting into a wrong-remote
# pane and waiting for the worker to declare a context mismatch.
#
# Public API:
#   dispatch_workdir_origin_preflight <agent> <ticket> <workdir>
#     Returns 0 when:
#       * mode is `off` (skipped — recorded for audit),
#       * the canonical clone URL is empty (no expectation to enforce),
#       * the workdir does not yet contain a `.git` (worktree_create or
#         operator provisioning will create the clone), or
#       * the workdir's origin canonicalizes to the same value as the
#         loaded project's canonical URL.
#     Returns 0 in `warn` mode even on mismatch (audit + stderr signal),
#     so operators can roll out enforcement gradually.
#     Returns ORCH_DISPATCH_WORKDIR_ORIGIN_MISMATCH_EXIT_CODE in `enforce`
#     mode on actual mismatch.
#
# Side-channel state for callers/tests (cleared on every call):
#   DISPATCH_WORKDIR_ORIGIN_GUARD_MODE  effective mode (enforce|warn|off)
#   DISPATCH_WORKDIR_ORIGIN_CANONICAL   canonical clone URL (empty when
#                                       no expectation could be derived)
#   DISPATCH_WORKDIR_ORIGIN_ACTUAL      origin URL on disk (or '<unset>')
#   DISPATCH_WORKDIR_ORIGIN_RESULT      one of: skipped|no_canonical|
#                                       workdir_missing|match|mismatch
#   DISPATCH_WORKDIR_ORIGIN_REMEDIATION human-readable remediation hint
#
# Configuration:
#   ORCH_DISPATCH_WORKDIR_ORIGIN_GUARD = enforce|warn|off (default enforce)
#   ORCH_DISPATCH_WORKDIR_ORIGIN_MISMATCH_EXIT_CODE (default 4 — same code
#       as the existing portfolio-mode `duplicate_clone_remote_mismatch`
#       refusal so dashboards group the two refusals under one operator
#       runbook).
#
# Sourcing contract: callers must have already loaded the project config
# (so GH_REPO/REPO_URL/GIT_REMOTE_URL are visible) and
# `lib/portfolio_config.sh` (provides
# `portfolio_canonical_clone_url_for_loaded_project`,
# `portfolio_workdir_origin_url`,
# `portfolio_workdir_origin_matches_canonical`). `lib/audit_log.sh` is
# optional — when absent the helper still works but does not record audit
# lines.

: "${ORCH_DISPATCH_WORKDIR_ORIGIN_GUARD:=enforce}"
: "${ORCH_DISPATCH_WORKDIR_ORIGIN_MISMATCH_EXIT_CODE:=4}"
# Issue #454: dirty-workdir safety guard. Default mode is `warn` so the
# guard rolls out as an audit-only signal first; deployments that have
# parked or cleaned their fleet can bump it to `enforce`. The exit code
# differs from the origin guard so dashboards can distinguish a
# cross-project mismatch (#683) from a dirty-clone refusal (#454).
: "${ORCH_DISPATCH_WORKDIR_SAFETY_GUARD:=warn}"
: "${ORCH_DISPATCH_WORKDIR_SAFETY_EXIT_CODE:=5}"

dispatch_workdir_origin_preflight() {
  local agent=${1:?usage: dispatch_workdir_origin_preflight <agent> <ticket> <workdir>}
  local ticket=${2:?usage: dispatch_workdir_origin_preflight <agent> <ticket> <workdir>}
  local workdir=${3:?usage: dispatch_workdir_origin_preflight <agent> <ticket> <workdir>}

  ticket=${ticket#\#}

  local mode=${ORCH_DISPATCH_WORKDIR_ORIGIN_GUARD:-enforce}
  case "$mode" in
    enforce|warn|off) ;;
    1|yes|true|on)    mode=enforce ;;
    0|no|false)       mode=off ;;
    *) mode=enforce ;;
  esac

  # shellcheck disable=SC2034
  DISPATCH_WORKDIR_ORIGIN_GUARD_MODE="$mode"
  # shellcheck disable=SC2034
  DISPATCH_WORKDIR_ORIGIN_CANONICAL=""
  # shellcheck disable=SC2034
  DISPATCH_WORKDIR_ORIGIN_ACTUAL=""
  # shellcheck disable=SC2034
  DISPATCH_WORKDIR_ORIGIN_RESULT=""
  # shellcheck disable=SC2034
  DISPATCH_WORKDIR_ORIGIN_REMEDIATION=""

  if [[ "$mode" == "off" ]]; then
    DISPATCH_WORKDIR_ORIGIN_RESULT="skipped"
    if declare -F audit >/dev/null 2>&1; then
      audit "DISPATCH WORKDIR_ORIGIN_GUARD skipped agent=${agent} ticket=#${ticket} workdir=${workdir} mode=${mode}"
    fi
    return 0
  fi

  local canonical_url=""
  if declare -F portfolio_canonical_clone_url_for_loaded_project >/dev/null 2>&1; then
    canonical_url=$(portfolio_canonical_clone_url_for_loaded_project 2>/dev/null || true)
  fi
  if [[ -z "$canonical_url" ]]; then
    DISPATCH_WORKDIR_ORIGIN_RESULT="no_canonical"
    if declare -F audit >/dev/null 2>&1; then
      audit "DISPATCH WORKDIR_ORIGIN_GUARD no_canonical agent=${agent} ticket=#${ticket} workdir=${workdir} mode=${mode}"
    fi
    return 0
  fi
  # shellcheck disable=SC2034
  DISPATCH_WORKDIR_ORIGIN_CANONICAL="$canonical_url"

  # `-e` (exists) rather than `-d` (is a directory): a `git worktree add`
  # workdir stores `.git` as a gitlink **file** (`gitdir: <path>`), not a
  # directory. Requiring `-d` here silently classified every worktree-shaped
  # slot as `workdir_missing` (#702), making fleet capacity invisible. The
  # downstream `portfolio_workdir_origin_url` call uses `git -C` semantics
  # which already handles both shapes — only this up-front probe was wrong.
  if [[ ! -e "$workdir/.git" ]]; then
    DISPATCH_WORKDIR_ORIGIN_RESULT="workdir_missing"
    if declare -F audit >/dev/null 2>&1; then
      audit "DISPATCH WORKDIR_ORIGIN_GUARD workdir_missing agent=${agent} ticket=#${ticket} workdir=${workdir} canonical=${canonical_url} mode=${mode}"
    fi
    return 0
  fi

  local actual_origin=""
  if declare -F portfolio_workdir_origin_url >/dev/null 2>&1; then
    actual_origin=$(portfolio_workdir_origin_url "$workdir" 2>/dev/null || true)
  fi
  # shellcheck disable=SC2034
  DISPATCH_WORKDIR_ORIGIN_ACTUAL="${actual_origin:-<unset>}"

  # A workdir with no `origin` remote is an unknown, not a mismatch.
  # Production fleet slots are always cloned (so they always have origin),
  # but synthetic test fixtures sometimes `git init` a workdir without one;
  # treating that as a mismatch would surface false positives. Defer to
  # downstream guards (worktree_create / pane context proof) instead.
  if [[ -z "$actual_origin" ]]; then
    DISPATCH_WORKDIR_ORIGIN_RESULT="no_origin"
    if declare -F audit >/dev/null 2>&1; then
      audit "DISPATCH WORKDIR_ORIGIN_GUARD no_origin agent=${agent} ticket=#${ticket} workdir=${workdir} canonical=${canonical_url} mode=${mode}"
    fi
    return 0
  fi

  if declare -F portfolio_workdir_origin_matches_canonical >/dev/null 2>&1 \
    && portfolio_workdir_origin_matches_canonical "$workdir" "$canonical_url"; then
    DISPATCH_WORKDIR_ORIGIN_RESULT="match"
    if declare -F audit >/dev/null 2>&1; then
      audit "DISPATCH WORKDIR_ORIGIN_GUARD ok agent=${agent} ticket=#${ticket} workdir=${workdir} origin=${actual_origin} canonical=${canonical_url} mode=${mode}"
    fi
    return 0
  fi

  # shellcheck disable=SC2034
  DISPATCH_WORKDIR_ORIGIN_RESULT="mismatch"
  local remediation
  remediation="provision a clone of ${canonical_url} at a project-specific path (e.g. /root/repos/fleet-worktrees/<project>/${agent}) and re-point AGENT_WORKDIR_TEMPLATE for this profile, or dispatch from a slot whose origin already matches"
  # shellcheck disable=SC2034
  DISPATCH_WORKDIR_ORIGIN_REMEDIATION="$remediation"

  if [[ "$mode" == "warn" ]]; then
    if declare -F audit >/dev/null 2>&1; then
      audit "DISPATCH WORKDIR_ORIGIN_GUARD warn agent=${agent} ticket=#${ticket} workdir=${workdir} origin=${actual_origin:-<unset>} canonical=${canonical_url} mode=${mode} remediation=${remediation}"
    fi
    printf 'DISPATCH_WORKDIR_ORIGIN_GUARD warn: agent=%s ticket=#%s workdir=%s origin=%s canonical=%s — %s\n' \
      "$agent" "$ticket" "$workdir" "${actual_origin:-<unset>}" "$canonical_url" "$remediation" >&2
    return 0
  fi

  if declare -F audit >/dev/null 2>&1; then
    audit "DISPATCH REFUSED reason=workdir_origin_mismatch agent=${agent} ticket=#${ticket} workdir=${workdir} origin=${actual_origin:-<unset>} canonical=${canonical_url} mode=${mode} remediation=${remediation}"
  fi
  printf 'dispatch refused: cross-project workdir mismatch — agent=%s ticket=#%s workdir=%s origin=%s canonical=%s\n  remediation: %s\n' \
    "$agent" "$ticket" "$workdir" "${actual_origin:-<unset>}" "$canonical_url" "$remediation" >&2
  return "$ORCH_DISPATCH_WORKDIR_ORIGIN_MISMATCH_EXIT_CODE"
}

# Issue #454: dirty-workdir safety preflight.
#
# Symptom captured in the source ticket: `agent_pool_status.sh` reports
# `dirty,dirty_after_pr` for several fleet slots while `dispatch_plan.sh
# --ready-only` still emits P0/P1 candidates. A supervisor has to join
# those two signals manually before dispatch; without this guard a
# high-priority ticket can land on an unsafe clone where the worker
# either clobbers uncommitted local work or carries leftover artifacts
# from a previous merge into the new branch.
#
# This helper closes that gap by refusing (or warning) BEFORE the brief
# is pasted. It is a sibling of `dispatch_workdir_origin_preflight` —
# the same enforce|warn|off rollout shape — but covers a different
# failure class (clean clone in the wrong project vs. dirty clone in
# the right project) and uses a distinct exit code so dashboards can
# distinguish the two refusals.
#
# Public API:
#   dispatch_workdir_safety_preflight <agent> <ticket> <workdir>
#     Returns 0 when:
#       * mode is `off` (skipped — recorded for audit),
#       * the workdir is not yet a git checkout (worktree_create or
#         operator provisioning will populate it later — the dirty
#         signal cannot apply yet), or
#       * `git status --porcelain` is empty (clean workdir).
#     Returns 0 in `warn` mode even on dirty workdir (audit + stderr
#     signal) so operators can roll out enforcement gradually.
#     Returns ORCH_DISPATCH_WORKDIR_SAFETY_EXIT_CODE in `enforce` mode
#     on dirty workdir.
#
# Optional 4th argument: `signals_csv` — when the caller already has
# the agent_pool_status.sh signal list (e.g. `dirty,dirty_after_pr`)
# it can pass it in so the `dirty_after_pr` remediation is surfaced
# without re-running git plumbing here.
#
# Side-channel state for callers/tests (cleared on every call):
#   DISPATCH_WORKDIR_SAFETY_GUARD_MODE  effective mode (enforce|warn|off)
#   DISPATCH_WORKDIR_SAFETY_RESULT      one of: skipped|workdir_missing|
#                                       clean|dirty_clone|dirty_after_pr
#   DISPATCH_WORKDIR_SAFETY_REMEDIATION human-readable remediation hint
#   DISPATCH_WORKDIR_SAFETY_DIRTY_COUNT count of porcelain lines (or 0)
#
# Configuration:
#   ORCH_DISPATCH_WORKDIR_SAFETY_GUARD = enforce|warn|off (default warn)
#   ORCH_DISPATCH_WORKDIR_SAFETY_EXIT_CODE (default 5)
dispatch_workdir_safety_preflight() {
  local agent=${1:?usage: dispatch_workdir_safety_preflight <agent> <ticket> <workdir> [signals_csv]}
  local ticket=${2:?usage: dispatch_workdir_safety_preflight <agent> <ticket> <workdir> [signals_csv]}
  local workdir=${3:?usage: dispatch_workdir_safety_preflight <agent> <ticket> <workdir> [signals_csv]}
  local signals_csv=${4:-}

  ticket=${ticket#\#}

  local mode=${ORCH_DISPATCH_WORKDIR_SAFETY_GUARD:-warn}
  case "$mode" in
    enforce|warn|off) ;;
    1|yes|true|on)    mode=enforce ;;
    0|no|false)       mode=off ;;
    *) mode=warn ;;
  esac

  # shellcheck disable=SC2034
  DISPATCH_WORKDIR_SAFETY_GUARD_MODE="$mode"
  # shellcheck disable=SC2034
  DISPATCH_WORKDIR_SAFETY_RESULT=""
  # shellcheck disable=SC2034
  DISPATCH_WORKDIR_SAFETY_REMEDIATION=""
  # shellcheck disable=SC2034
  DISPATCH_WORKDIR_SAFETY_DIRTY_COUNT=0

  if [[ "$mode" == "off" ]]; then
    DISPATCH_WORKDIR_SAFETY_RESULT="skipped"
    if declare -F audit >/dev/null 2>&1; then
      audit "DISPATCH WORKDIR_SAFETY_GUARD skipped agent=${agent} ticket=#${ticket} workdir=${workdir} mode=${mode}"
    fi
    return 0
  fi

  # `-e` (exists) rather than `-d`: a `git worktree add` workdir stores
  # `.git` as a gitlink file, not a directory. Mirrors the origin guard
  # decision in this same file.
  if [[ ! -e "$workdir/.git" ]]; then
    DISPATCH_WORKDIR_SAFETY_RESULT="workdir_missing"
    if declare -F audit >/dev/null 2>&1; then
      audit "DISPATCH WORKDIR_SAFETY_GUARD workdir_missing agent=${agent} ticket=#${ticket} workdir=${workdir} mode=${mode}"
    fi
    return 0
  fi

  local porcelain
  porcelain=$(git -C "$workdir" status --porcelain 2>/dev/null || true)
  local dirty_count=0
  if [[ -n "$porcelain" ]]; then
    dirty_count=$(printf '%s\n' "$porcelain" | grep -c .)
  fi
  # shellcheck disable=SC2034
  DISPATCH_WORKDIR_SAFETY_DIRTY_COUNT="$dirty_count"

  if [[ "$dirty_count" -eq 0 ]]; then
    DISPATCH_WORKDIR_SAFETY_RESULT="clean"
    if declare -F audit >/dev/null 2>&1; then
      audit "DISPATCH WORKDIR_SAFETY_GUARD ok agent=${agent} ticket=#${ticket} workdir=${workdir} mode=${mode} dirty=0"
    fi
    return 0
  fi

  local result="dirty_clone"
  case ",${signals_csv}," in
    *,dirty_after_pr,*) result="dirty_after_pr" ;;
  esac
  # shellcheck disable=SC2034
  DISPATCH_WORKDIR_SAFETY_RESULT="$result"

  local remediation
  if declare -F dispatch_capacity_remediation_for_class >/dev/null 2>&1; then
    if [[ "$result" == "dirty_after_pr" ]]; then
      remediation=$(dispatch_capacity_remediation_for_class dirty_clone "dirty,dirty_after_pr")
    else
      remediation=$(dispatch_capacity_remediation_for_class dirty_clone "")
    fi
  fi
  if [[ -z "$remediation" ]]; then
    if [[ "$result" == "dirty_after_pr" ]]; then
      remediation="uncommitted artifacts remain after PR merge — run scripts/post_merge_cleanup.sh in the workdir before dispatch"
    else
      remediation="commit or stash uncommitted changes in the workdir before dispatch"
    fi
  fi
  # shellcheck disable=SC2034
  DISPATCH_WORKDIR_SAFETY_REMEDIATION="$remediation"

  if [[ "$mode" == "warn" ]]; then
    if declare -F audit >/dev/null 2>&1; then
      audit "DISPATCH WORKDIR_SAFETY_GUARD warn agent=${agent} ticket=#${ticket} workdir=${workdir} result=${result} dirty=${dirty_count} mode=${mode} remediation=${remediation}"
    fi
    printf 'DISPATCH_WORKDIR_SAFETY_GUARD warn: agent=%s ticket=#%s workdir=%s result=%s dirty=%s — %s\n' \
      "$agent" "$ticket" "$workdir" "$result" "$dirty_count" "$remediation" >&2
    return 0
  fi

  if declare -F audit >/dev/null 2>&1; then
    audit "DISPATCH REFUSED reason=workdir_${result} agent=${agent} ticket=#${ticket} workdir=${workdir} dirty=${dirty_count} mode=${mode} remediation=${remediation}"
  fi
  printf 'dispatch refused: workdir %s — agent=%s ticket=#%s workdir=%s dirty=%s\n  remediation: %s\n' \
    "$result" "$agent" "$ticket" "$workdir" "$dirty_count" "$remediation" >&2
  return "$ORCH_DISPATCH_WORKDIR_SAFETY_EXIT_CODE"
}
