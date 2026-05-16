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

# Scope-claim ledger (#721).
#
# A scope claim is written when dispatch_ticket promotes an assignment and
# released when post_merge_cleanup clears that assignment after a PR merge.
# The claim carries the brief's `Fichiers autorises` list so dispatch_plan
# can flag in-flight overlaps before another agent is dispatched, and so
# brief_agents can pre-inject active scope_files from sibling tickets as
# forbidden_files in the next brief. Per-project: the ledger lives under
# `$(state_dir)/scope_claims.json` and is keyed by ticket number.
#
# Ledger shape:
#   {
#     "<ticket>": {
#       "agent": "<label>",
#       "scope_files": ["path1", "path2", ...],
#       "created_at": "<iso8601>"
#     },
#     ...
#   }
dispatch_capacity_scope_claims_path() {
  declare -F state_dir >/dev/null 2>&1 || return 1
  printf '%s/scope_claims.json\n' "$(state_dir)"
}

# Normalise a scope_files block (multi-line, comma-, or whitespace-separated)
# into one path per line, stripped of leading markers (`-`, `*`), inline
# comments, surrounding whitespace, and duplicates. Empty input → empty
# output.
dispatch_capacity_scope_files_normalize() {
  local raw=${1-}
  [ -n "$raw" ] || return 0
  printf '%s\n' "$raw" \
    | tr ',' '\n' \
    | awk '
        {
          line = $0
          sub(/^[[:space:]]*[-*][[:space:]]*/, "", line)
          sub(/[[:space:]]+#.*$/, "", line)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
          if (length(line) > 0) print line
        }
      ' \
    | awk 'NF && !seen[$0]++'
}

# Upsert a claim row. Silent no-ops when jq is missing, state_dir is
# unavailable, or the scope_files list is empty (an audit-only or
# empty-scope dispatch has nothing to claim).
dispatch_capacity_scope_claims_record() {
  local agent=${1:?usage: dispatch_capacity_scope_claims_record <agent> <ticket> <scope_files>}
  local ticket=${2:?usage: dispatch_capacity_scope_claims_record <agent> <ticket> <scope_files>}
  local raw_scope=${3-}
  local ledger files_json created_at tmp
  command -v jq >/dev/null 2>&1 || return 0
  ledger=$(dispatch_capacity_scope_claims_path 2>/dev/null) || return 0
  [ -n "$ledger" ] || return 0
  files_json=$(dispatch_capacity_scope_files_normalize "$raw_scope" \
    | jq -R . | jq -s 'map(select(length > 0))')
  if [ -z "$files_json" ] || [ "$(printf '%s' "$files_json" | jq 'length')" = "0" ]; then
    return 0
  fi
  created_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  mkdir -p "$(dirname "$ledger")"
  tmp="${ledger}.tmp.$$"
  if [ -s "$ledger" ]; then
    jq \
      --arg ticket "$ticket" \
      --arg agent "$agent" \
      --argjson files "$files_json" \
      --arg created_at "$created_at" \
      '.[$ticket] = {agent:$agent, scope_files:$files, created_at:$created_at}' \
      "$ledger" > "$tmp"
  else
    jq -n \
      --arg ticket "$ticket" \
      --arg agent "$agent" \
      --argjson files "$files_json" \
      --arg created_at "$created_at" \
      '{($ticket): {agent:$agent, scope_files:$files, created_at:$created_at}}' \
      > "$tmp"
  fi
  mv "$tmp" "$ledger"
}

# Release a claim by ticket number. Silent when the ledger is missing or
# the ticket is not currently claimed.
dispatch_capacity_scope_claims_release_by_ticket() {
  local ticket=${1:?usage: dispatch_capacity_scope_claims_release_by_ticket <ticket>}
  local ledger tmp
  command -v jq >/dev/null 2>&1 || return 0
  ledger=$(dispatch_capacity_scope_claims_path 2>/dev/null) || return 0
  [ -n "$ledger" ] && [ -s "$ledger" ] || return 0
  tmp="${ledger}.tmp.$$"
  jq --arg ticket "$ticket" 'del(.[$ticket])' "$ledger" > "$tmp"
  mv "$tmp" "$ledger"
}

# Emit one `<ticket>\t<file>` row per active claim. Optional first
# argument is a ticket to skip (so a brief renderer can exclude its own
# claim when computing in-flight forbidden_files). Silent when the
# ledger is missing or empty.
dispatch_capacity_scope_claims_active_rows() {
  local skip_ticket=${1-}
  local ledger
  command -v jq >/dev/null 2>&1 || return 0
  ledger=$(dispatch_capacity_scope_claims_path 2>/dev/null) || return 0
  [ -n "$ledger" ] && [ -s "$ledger" ] || return 0
  jq -r --arg skip "$skip_ticket" '
    to_entries[]
    | select(.key != $skip)
    | . as $row
    | (.value.scope_files // [])[]
    | "\($row.key)\t\(.)"
  ' "$ledger" 2>/dev/null
}

# Emit deduplicated active scope_files (paths only), excluding the
# optional `<skip-ticket>` claim. Silent when the ledger is missing.
dispatch_capacity_scope_claims_active_files() {
  dispatch_capacity_scope_claims_active_rows "$@" \
    | awk -F'\t' 'NF==2 && $2 != "" && !seen[$2]++ { print $2 }'
}

# Given a comma- or newline-separated scope_files list, emit the
# `<ticket>` numbers from active claims whose scope_files overlap. Glob
# matching is intentionally permissive — directory prefixes, `*` globs,
# and exact paths all conflict. Output is sorted-unique numeric tickets.
dispatch_capacity_scope_claims_conflicting_tickets() {
  local candidate_scope=${1-}
  local skip_ticket=${2-}
  local ledger candidate_files
  [ -n "$candidate_scope" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  ledger=$(dispatch_capacity_scope_claims_path 2>/dev/null) || return 0
  [ -n "$ledger" ] && [ -s "$ledger" ] || return 0
  candidate_files=$(dispatch_capacity_scope_files_normalize "$candidate_scope")
  [ -n "$candidate_files" ] || return 0

  local active_rows
  active_rows=$(dispatch_capacity_scope_claims_active_rows "$skip_ticket")
  [ -n "$active_rows" ] || return 0

  awk -v candidate="$candidate_files" '
    function overlap(a, b,    al, bl) {
      if (a == "" || b == "") return 0
      if (a == b) return 1
      al = length(a); bl = length(b)
      if (substr(a, al) == "/" && substr(b, 1, al) == a) return 1
      if (substr(b, bl) == "/" && substr(a, 1, bl) == b) return 1
      if (index(a, "*") || index(a, "?") || index(a, "[")) {
        gsub(/[.+(){}^$|]/, "\\\\&", a); gsub(/\*/, ".*", a); gsub(/\?/, ".", a)
        if (b ~ ("^" a "$")) return 1
      }
      if (index(b, "*") || index(b, "?") || index(b, "[")) {
        gsub(/[.+(){}^$|]/, "\\\\&", b); gsub(/\*/, ".*", b); gsub(/\?/, ".", b)
        if (a ~ ("^" b "$")) return 1
      }
      if (substr(a, 1, length(b) + 1) == b "/") return 1
      if (substr(b, 1, length(a) + 1) == a "/") return 1
      return 0
    }
    BEGIN { n = split(candidate, cand, "\n") }
    NF == 2 {
      ticket = $1; file = $2
      for (i = 1; i <= n; i++) {
        if (overlap(cand[i], file)) {
          if (!seen[ticket]++) print ticket
          break
        }
      }
    }
  ' FS='\t' <<< "$active_rows" \
    | awk 'NF' | sort -n -u
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
