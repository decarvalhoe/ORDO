#!/usr/bin/env bash
# lib/dispatch_capacity.sh — explicit dispatch-capacity classifier.
#
# Issue #278 is the finding: a real ORDO wave reserved agent slots based on
# stale scrollback assumptions (one "open PR" elsewhere, "orch is the
# supervisor") instead of structured reasons, leaving usable capacity idle
# while ready issues remained.
#
# This helper produces a single capacity class per configured agent so the
# dispatch matrix has a structured, reviewable row for every slot. It is pure
# (no I/O), so both agent_pool_status.sh and portfolio_status.sh can call it
# from existing data and tests can exercise it directly.
#
# Capacity classes (one primary class per agent):
#   reserved          AGENT_RESERVED_LABELS lists this label explicitly.
#                     `orch` is NEVER auto-reserved; the project profile must
#                     opt in.
#   dispatched        Workdir is on a non-default branch AND has an open PR
#                     in the configured project repo. Structured occupancy.
#   local_work        Clean clone on a non-default branch with no matching
#                     open PR — a structured signal of in-progress local work
#                     that does NOT count as dispatched and is NOT a
#                     reservation; orchestrators must investigate before
#                     dispatch.
#   dirty_clone       Clone has uncommitted changes; cannot dispatch safely.
#   switch_required   Clone is clean, but the tmux pane's current_path does
#                     not match the agent's expected ORDO workdir (clean pane
#                     in the wrong project). Remediable via
#                     agent_product_switch.sh.
#   pane_not_ready    Pane is not alive on the host (tmux session/window/pane
#                     missing or dead).
#   clone_missing     The agent's expected workdir is not a git checkout.
#   available         Clone clean on default branch, pane alive in expected
#                     workdir, no open PR — slot is dispatchable.
#
# Tuning hooks (project profile):
#   AGENT_RESERVED_LABELS  bash array of labels that should be treated as
#                          reserved for non-dispatch use (for example, an
#                          orchestration supervisor pane). Default: empty
#                          array. ORDO never auto-fills this from a label
#                          name.

# Emit the configured reserved labels, one per line. No output when the
# operator has not opted in.
dispatch_capacity_reserved_labels() {
  if declare -p AGENT_RESERVED_LABELS >/dev/null 2>&1 \
     && [ "${#AGENT_RESERVED_LABELS[@]}" -gt 0 ]; then
    printf '%s\n' "${AGENT_RESERVED_LABELS[@]}"
  fi
}

dispatch_capacity_is_reserved() {
  local label=${1:?usage: dispatch_capacity_is_reserved <label>}
  local entry
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    [ "$entry" = "$label" ] && return 0
  done < <(dispatch_capacity_reserved_labels)
  return 1
}

# Classify one agent's capacity. All inputs are passed by argument so the
# function is pure and trivially testable.
#   $1  label
#   $2  pane_alive (0 or 1)
#   $3  expected_workdir
#   $4  pane_workdir (current_path of the pane; may be empty when tmux
#       metadata is unavailable)
#   $5  branch
#   $6  default_branch
#   $7  dirty (count or empty; 0 means clean)
#   $8  pr (PR number for the agent's branch in the configured repo;
#       empty means no matching open PR)
#   $9  workdir_is_git (0 or 1) — whether the agent's expected workdir is a
#       git checkout
#
# Output: one capacity class on stdout.
dispatch_capacity_classify() {
  local label=${1:?usage: dispatch_capacity_classify <label> <alive> <expected_workdir> <pane_workdir> <branch> <default_branch> <dirty> <pr> <workdir_is_git>}
  local alive=${2:-0}
  local expected_workdir=${3:-}
  local pane_workdir=${4:-}
  local branch=${5:-}
  local default_branch=${6:-main}
  local dirty=${7:-0}
  local pr=${8:-}
  local workdir_is_git=${9:-1}

  if dispatch_capacity_is_reserved "$label"; then
    printf 'reserved\n'
    return 0
  fi
  if [ "$workdir_is_git" != "1" ]; then
    printf 'clone_missing\n'
    return 0
  fi
  if [ "${dirty:-0}" != "0" ]; then
    printf 'dirty_clone\n'
    return 0
  fi
  if [ -n "$pr" ] && [ -n "$branch" ] && [ "$branch" != "$default_branch" ]; then
    printf 'dispatched\n'
    return 0
  fi
  if [ -n "$branch" ] && [ "$branch" != "$default_branch" ]; then
    printf 'local_work\n'
    return 0
  fi
  if [ -n "$expected_workdir" ] && [ -n "$pane_workdir" ] \
     && [ "$pane_workdir" != "$expected_workdir" ]; then
    printf 'switch_required\n'
    return 0
  fi
  if [ "${alive:-0}" != "1" ]; then
    printf 'pane_not_ready\n'
    return 0
  fi
  printf 'available\n'
}

# Return a short human-friendly explanation for a capacity class. Used by
# downstream tooling when surfacing idle-capacity warnings.
dispatch_capacity_reason() {
  local class=${1:?usage: dispatch_capacity_reason <class>}
  case "$class" in
    reserved)
      printf 'reserved by AGENT_RESERVED_LABELS in the project profile\n' ;;
    dispatched)
      printf 'on a feature branch with an open PR in the configured repo\n' ;;
    local_work)
      printf 'on a feature branch with no matching open PR — investigate before dispatch\n' ;;
    dirty_clone)
      printf 'workdir has uncommitted changes; clean before dispatch\n' ;;
    switch_required)
      printf 'pane is in another project; remediate via agent_product_switch.sh\n' ;;
    pane_not_ready)
      printf 'tmux pane is not alive; revive the session/window/pane\n' ;;
    clone_missing)
      printf 'expected workdir is not a git checkout; provision the clone\n' ;;
    available)
      printf 'ready for dispatch\n' ;;
    *)
      printf 'unknown\n' ;;
  esac
}
