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
