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

# Emit issue numbers currently held by agents in the local ORDO ledger
# (`$(state_dir)/assignments.json`), one per line, deduplicated and sorted.
# Used by dispatch_plan to flag locally-assigned issues in the ready queue so
# operators do not duplicate-dispatch work that is already live in another
# agent. Issue #499.
#
# Skips parked entries (`parked: true`) and rows without an issue/ticket
# number. Silent when jq is unavailable, when `state_dir` is not defined, or
# when the ledger file is absent or empty — the caller should treat empty
# output as "no local assignments visible".
dispatch_capacity_local_assigned_issues() {
  local ledger
  command -v jq >/dev/null 2>&1 || return 0
  declare -F state_dir >/dev/null 2>&1 || return 0
  ledger="$(state_dir)/assignments.json"
  [ -s "$ledger" ] || return 0
  jq -r '
    to_entries[]
    | select((.value.parked // false) != true)
    | (.value.issue // .value.ticket // empty)
    | tostring
    | select(test("^[0-9]+$"))
  ' "$ledger" 2>/dev/null | sort -n -u || true
}

# In-flight scope-claim ledger (#721 sub-A).
#
# When `dispatch_ticket.sh` promotes an assignment it appends a per-agent
# row to `<state_dir>/assignments_scope_claims.json` carrying the
# resolved `scope_files`, `forbidden_files`, branch, and `claimed_at`
# timestamp parsed out of the canonical brief. Downstream planners and
# brief renderers consult the same ledger to surface scope conflicts
# before two agents are pointed at the same file. The row is released
# by `post_merge_cleanup.sh` after the matching PR merges.
#
# The helpers below are pure jq/state-file plumbing: callers pass in
# fully resolved values and the lock-protected JSON update is done here
# so dispatch_ticket / post_merge_cleanup / dispatch_plan / brief_agents
# stay consistent. All helpers no-op silently when `jq` or the
# `state_dir` helper from audit_log.sh is unavailable, matching the
# fail-soft convention used by `dispatch_capacity_local_assigned_issues`
# in sanitized test sandboxes.

dispatch_capacity_scope_claim_path() {
  command -v jq >/dev/null 2>&1 || return 1
  declare -F state_dir >/dev/null 2>&1 || return 1
  printf '%s/%s' "$(state_dir)" "assignments_scope_claims.json"
}

# Parse a `- Fichiers <marker>:` block out of a rendered canonical brief.
# Emits one path per line, stripped of leading whitespace, with blank
# lines and `- ` bullet starters skipped. Stops at the next top-level
# `- ` bullet so adjacent blocks (autorises / interdits / absolues) do
# not bleed into each other.
dispatch_capacity_extract_scope_block() {
  local prompt_file=${1:?usage: dispatch_capacity_extract_scope_block <prompt-file> <marker>}
  local marker=${2:?usage: dispatch_capacity_extract_scope_block <prompt-file> <marker>}
  [ -f "$prompt_file" ] || return 0
  awk -v marker="$marker" '
    BEGIN { in_block = 0 }
    {
      header = "^-[[:space:]]+" marker "[[:space:]]*:[[:space:]]*$"
      if ($0 ~ header) {
        in_block = 1
        next
      }
      if (in_block == 1) {
        if ($0 ~ /^-[[:space:]]+[^[:space:]]/) {
          in_block = 0
          next
        }
        if ($0 ~ /^[[:space:]]*$/) { next }
        sub(/^[[:space:]]+/, "")
        print
      }
    }
  ' "$prompt_file"
}

dispatch_capacity_write_scope_claim() {
  local agent=${1:?usage: dispatch_capacity_write_scope_claim <agent> <ticket> <branch> <scope_files_text> <forbidden_files_text> <claimed_at>}
  local ticket=${2:?usage: dispatch_capacity_write_scope_claim <agent> <ticket> <branch> <scope_files_text> <forbidden_files_text> <claimed_at>}
  local branch=${3:-}
  local scope_files_text=${4:-}
  local forbidden_files_text=${5:-}
  local claimed_at=${6:-}
  local target lock tmp scope_array_json forbidden_array_json
  target=$(dispatch_capacity_scope_claim_path) || return 1
  lock="${target}.lock"
  tmp="${target}.tmp.$$"
  mkdir -p "$(dirname "$target")"
  scope_array_json=$(printf '%s' "$scope_files_text" \
    | awk 'NF { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print }' \
    | jq -R . | jq -s 'unique_by(.) | map(select(length > 0))')
  forbidden_array_json=$(printf '%s' "$forbidden_files_text" \
    | awk 'NF { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print }' \
    | jq -R . | jq -s 'unique_by(.) | map(select(length > 0))')
  (
    flock 9
    if [ -s "$target" ]; then
      jq \
        --arg agent "$agent" \
        --arg ticket "$ticket" \
        --arg branch "$branch" \
        --argjson scope_files "$scope_array_json" \
        --argjson forbidden_files "$forbidden_array_json" \
        --arg claimed_at "$claimed_at" \
        '.[$agent] = {agent:$agent, ticket:$ticket, branch:$branch, scope_files:$scope_files, forbidden_files:$forbidden_files, claimed_at:$claimed_at}' \
        "$target" > "$tmp"
    else
      printf '{}\n' | jq \
        --arg agent "$agent" \
        --arg ticket "$ticket" \
        --arg branch "$branch" \
        --argjson scope_files "$scope_array_json" \
        --argjson forbidden_files "$forbidden_array_json" \
        --arg claimed_at "$claimed_at" \
        '.[$agent] = {agent:$agent, ticket:$ticket, branch:$branch, scope_files:$scope_files, forbidden_files:$forbidden_files, claimed_at:$claimed_at}' \
        > "$tmp"
    fi
    mv "$tmp" "$target"
  ) 9>"$lock"
}

dispatch_capacity_release_scope_claim() {
  local agent=${1:?usage: dispatch_capacity_release_scope_claim <agent>}
  local target lock tmp
  target=$(dispatch_capacity_scope_claim_path) || return 0
  [ -s "$target" ] || return 0
  lock="${target}.lock"
  tmp="${target}.tmp.$$"
  (
    flock 9
    jq --arg agent "$agent" 'del(.[$agent])' "$target" > "$tmp"
    mv "$tmp" "$target"
  ) 9>"$lock"
}

# Emit the entire claim ledger as compact JSON. Empty object when the
# ledger is missing or jq/state_dir are unavailable.
dispatch_capacity_scope_claims_json() {
  local target
  if ! target=$(dispatch_capacity_scope_claim_path 2>/dev/null); then
    printf '{}\n'
    return 0
  fi
  if [ -s "$target" ]; then
    cat "$target"
  else
    printf '{}\n'
  fi
}

# Emit the union of scope_files across all in-flight claims, optionally
# excluding a single agent's own claim. One path per line, deduplicated
# and sorted. Empty output when the ledger is empty.
dispatch_capacity_scope_claim_files() {
  local exclude_agent=${1:-}
  command -v jq >/dev/null 2>&1 || return 0
  dispatch_capacity_scope_claims_json | jq -r \
    --arg exclude "$exclude_agent" '
      [ to_entries[]
        | select(($exclude == "") or (.key != $exclude))
        | (.value.scope_files // [])[]
      ]
      | unique
      | .[]
    ' 2>/dev/null || true
}

# Emit the tickets currently holding the named scope file, one per line.
# Used by dispatch_plan to attribute conflicts back to their owning
# in-flight ticket numbers.
dispatch_capacity_scope_claim_tickets_for_file() {
  local path=${1:?usage: dispatch_capacity_scope_claim_tickets_for_file <path>}
  command -v jq >/dev/null 2>&1 || return 0
  dispatch_capacity_scope_claims_json | jq -r \
    --arg path "$path" '
      [ to_entries[]
        | select((.value.scope_files // []) | index($path))
        | (.value.ticket // empty)
      ]
      | unique
      | .[]
    ' 2>/dev/null || true
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

# Issue #454: fleet-aware dispatch readiness. Operators were manually joining
# `agent_pool_status.sh` (dirty signals) with `dispatch_plan.sh --ready-only`
# (ready queue) to decide whether a high-priority ticket could safely land on
# any agent. The helpers below close that gap by exposing a single
# `dispatchable` answer per capacity class plus a structured `blocked_reason`
# string. They are pure and side-effect free so dispatch_plan, agent_pool_status,
# portfolio_status, and tests can all share the same vocabulary.
#
# Returns 0 (true) when the capacity class is safe to receive a new dispatch
# (only `available` qualifies — `dispatched` and `local_work` are explicitly
# excluded so a supervisor does not double-book an agent whose pane is already
# carrying work in flight). Returns 1 otherwise. The function intentionally
# does NOT print anything; callers decide whether to surface the reason.
dispatch_capacity_class_dispatchable() {
  local class=${1:?usage: dispatch_capacity_class_dispatchable <class>}
  case "$class" in
    available) return 0 ;;
    *) return 1 ;;
  esac
}

# Emit a short, single-line blocker token suitable for inclusion in signals
# CSVs (no spaces). For `dirty_clone` callers may pass the signals CSV as $2
# so the `dirty_after_pr` sub-state is preserved — it is the most common
# remediation path (PR merged but the workdir still carries stray artifacts).
# Returns no output for `available` so callers can treat empty-output as
# dispatchable.
dispatch_capacity_blocked_reason() {
  local class=${1:?usage: dispatch_capacity_blocked_reason <class> [signals_csv]}
  local signals=${2:-}
  case "$class" in
    available) return 0 ;;
    dirty_clone)
      case ",${signals}," in
        *,dirty_after_pr,*) printf 'dirty_after_pr\n'; return 0 ;;
      esac
      printf 'dirty_clone\n'
      ;;
    dispatched|local_work|reserved|switch_required|pane_not_ready|clone_missing|supervisor_mirror|identity_mismatch)
      printf '%s\n' "$class" ;;
    '')
      printf 'unknown\n' ;;
    *)
      printf '%s\n' "$class" ;;
  esac
}

# Emit a short operator-facing remediation hint for a blocked capacity class.
# `dirty_clone` callers may pass the signals CSV as $2 so `dirty_after_pr` —
# the cluster cause from #454 — gets pointed at post_merge_cleanup.sh rather
# than the generic stash/commit hint. Returns no output for `available`.
dispatch_capacity_remediation_for_class() {
  local class=${1:?usage: dispatch_capacity_remediation_for_class <class> [signals_csv]}
  local signals=${2:-}
  case "$class" in
    available) return 0 ;;
    dirty_clone)
      case ",${signals}," in
        *,dirty_after_pr,*)
          printf 'uncommitted artifacts remain after PR merge — run scripts/post_merge_cleanup.sh in the workdir, or git restore -SW . then re-check before dispatch\n'
          return 0 ;;
      esac
      printf 'commit or stash uncommitted changes in the workdir, or park the agent before dispatch\n'
      ;;
    dispatched)
      printf 'agent already carries an open PR — wait for merge or pick a different slot\n' ;;
    local_work)
      printf 'agent has uncommitted local work without a PR — investigate or park before dispatch\n' ;;
    reserved)
      printf 'agent is reserved by AGENT_RESERVED_LABELS — choose a non-reserved slot\n' ;;
    switch_required)
      printf 'pane is in another project — run scripts/agent_product_switch.sh before dispatch\n' ;;
    pane_not_ready)
      printf 'tmux pane is not alive — revive the session/window/pane before dispatch\n' ;;
    clone_missing)
      printf 'expected workdir is not a git checkout — provision the clone before dispatch\n' ;;
    supervisor_mirror)
      printf 'workdir is a supervisor mirror, not an owned agent slot — do not dispatch here\n' ;;
    identity_mismatch)
      printf 'observed git identity differs from expected — repair user.name/user.email before dispatch\n' ;;
    *)
      printf 'capacity class is not dispatchable — investigate before sending work\n' ;;
  esac
}
