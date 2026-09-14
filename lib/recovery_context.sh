#!/usr/bin/env bash
# recovery_context.sh — fresh recovery context proof for destructive
# agent-workdir actions (#362).
#
# Background: a heartbeat audit at 2026-05-08T13:44Z caught the
# orchestrator asking the operator to authorize an external
# `git rebase --abort` in another agent's workdir based on stale
# scrollback state. A fresh dirty-clone scan moments later showed no
# ORDO workdir actually had the conflict the prompt claimed; the
# destructive request was based on a 6-minute-old read.
#
# This library forces every destructive recovery code path to (a)
# capture a timestamped proof of the workdir's destructive state at
# decision time and (b) re-validate that proof before any external
# mutation. When the proof is older than `ORCH_RECOVERY_PROOF_MAX_AGE_SEC`
# or the live state no longer matches it, the recovery is refused with
# `RECOVERY_PROOF_STALE` and the operator is told to fall back to the
# non-destructive path (PR mergeability monitoring).
#
# Local clone state and GitHub PR mergeability are deliberately captured
# as separate fields so the proof can answer "do we still need a local
# destructive action?" without conflating it with "does the PR still
# fail to merge?". Per the issue: "Local clone state and GitHub PR
# mergeability are reported separately."
#
# Sourcing contract: callers must source `audit_log.sh` first (for
# `audit`, `state_dir`, `state_file`). `state_persist.sh` is sourced
# transitively by every dispatch script that writes to the state dir.
#
# Public API:
#   recovery_context_capture <workdir> [--agent <slug>] [--ticket <n>]
#                            [--pr <n>] [--reason <text>]
#     Captures a proof JSON to `<state_dir>/recovery/<sha>-<ts>.json`
#     and prints the path on stdout. Sets the side-channel state vars
#     RECOVERY_CONTEXT_PROOF_PATH, RECOVERY_CONTEXT_PROOF_TIMESTAMP and
#     RECOVERY_CONTEXT_PROOF_DESTRUCTIVE so callers do not have to
#     re-parse the file when emitting the audit line.
#
#   recovery_context_validate <proof-path> <workdir>
#     Returns 0 when the proof is still fresh AND the live state still
#     matches it. Returns 1 with side-channel state explaining the
#     drift. Side-channel:
#       RECOVERY_CONTEXT_VALIDATE_REASON   stale_age | state_drift |
#                                          ownership_drift |
#                                          proof_unreadable
#       RECOVERY_CONTEXT_VALIDATE_DETAIL   key=value details
#       RECOVERY_CONTEXT_VALIDATE_AGE_SEC  proof age in seconds
#
#   recovery_context_pr_status <pr-number> [<gh-repo>]
#     Echoes a one-line `pr_status mergeable=<bool> mergeStateStatus=<s>
#     state=<s> updatedAt=<ts>` so callers can include the PR view in the
#     proof or compare local-vs-remote independently. Best-effort: when
#     `gh` is unavailable or the PR cannot be read, prints
#     `pr_status mergeable=unknown mergeStateStatus=unknown state=unknown
#     updatedAt=`.
#
# Tunables:
#   ORCH_RECOVERY_PROOF_MAX_AGE_SEC     default 300 (5 minutes). Beyond
#                                       this the proof is considered stale
#                                       even if the state still matches.
#   ORCH_RECOVERY_PROOF_DIR             default `<state_dir>/recovery`.
#   ORCH_RECOVERY_PROOF_STALE_EXIT_CODE default 88. Distinct from 76
#                                       (post-dispatch live-cwd context
#                                       proof), 81 (pre-dispatch
#                                       routing-surface guard), 86
#                                       (ticket-scope mismatch) and 87
#                                       (capacity busy-claim refused) so
#                                       the audit dashboards can group
#                                       "destructive recovery refused"
#                                       separately.

# The provider adapter (#816) is loaded on first use: this file is sourced
# by dispatch_ticket.sh and friends, which must stay cheap to source.
_recovery_context_require_provider() {
  declare -F ordo_provider >/dev/null 2>&1 && return 0
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=lib/ordo_provider_adapter.sh
  source "$lib_dir/ordo_provider_adapter.sh"
}

: "${ORCH_RECOVERY_PROOF_MAX_AGE_SEC:=300}"
: "${ORCH_RECOVERY_PROOF_STALE_EXIT_CODE:=88}"

recovery_context_proof_dir() {
  local dir
  if [[ -n "${ORCH_RECOVERY_PROOF_DIR:-}" ]]; then
    dir="$ORCH_RECOVERY_PROOF_DIR"
  elif declare -F state_dir >/dev/null 2>&1; then
    dir="$(state_dir)/recovery"
  else
    dir="${TMPDIR:-/tmp}/orch-recovery"
  fi
  mkdir -p "$dir" 2>/dev/null || true
  printf '%s\n' "$dir"
}

# Hash a workdir path to a stable short slug so the proof filename does
# not leak the full path into shell glob context.
_recovery_context_workdir_slug() {
  local workdir=${1:?usage: _recovery_context_workdir_slug <workdir>}
  local sum
  sum=$(printf '%s' "$workdir" | sha256sum 2>/dev/null | awk '{print $1}')
  printf '%s\n' "${sum:0:16}"
}

# Snapshot of the workdir's destructive-state surfaces at call time.
# Echoes a one-line key=value record so callers can compare two
# snapshots field-by-field without parsing JSON.
_recovery_context_snapshot_state() {
  local workdir=${1:?usage: _recovery_context_snapshot_state <workdir>}
  local branch="" head="" porcelain_hash="" unmerged_hash="" in_progress=""
  local porcelain_count=0 unmerged_count=0

  if [[ -d "$workdir/.git" ]]; then
    local git_dir
    git_dir=$(git -C "$workdir" rev-parse --absolute-git-dir 2>/dev/null || printf '%s/.git' "$workdir")
    if [[ -e "$git_dir/MERGE_HEAD" ]]; then
      in_progress="MERGE_HEAD"
    elif [[ -e "$git_dir/CHERRY_PICK_HEAD" ]]; then
      in_progress="CHERRY_PICK_HEAD"
    elif [[ -e "$git_dir/REVERT_HEAD" ]]; then
      in_progress="REVERT_HEAD"
    elif [[ -d "$git_dir/rebase-merge" ]]; then
      in_progress="rebase-merge"
    elif [[ -d "$git_dir/rebase-apply" ]]; then
      in_progress="rebase-apply"
    elif [[ -e "$git_dir/BISECT_LOG" ]]; then
      in_progress="BISECT_LOG"
    fi

    branch=$(git -C "$workdir" branch --show-current 2>/dev/null || true)
    head=$(git -C "$workdir" rev-parse --verify HEAD 2>/dev/null || true)

    local porcelain unmerged
    porcelain=$(git -C "$workdir" status --porcelain=v1 --branch 2>/dev/null || true)
    unmerged=$(git -C "$workdir" diff --name-only --diff-filter=U 2>/dev/null || true)
    if [[ -n "$porcelain" ]]; then
      porcelain_count=$(printf '%s\n' "$porcelain" | sed -n '/^[^#]/p' | wc -l | tr -d ' ')
      porcelain_hash=$(printf '%s' "$porcelain" | sha256sum | awk '{print $1}')
    fi
    if [[ -n "$unmerged" ]]; then
      unmerged_count=$(printf '%s\n' "$unmerged" | sed '/^$/d' | wc -l | tr -d ' ')
      unmerged_hash=$(printf '%s' "$unmerged" | sha256sum | awk '{print $1}')
    fi
  fi

  printf 'branch=%s head=%s porcelain_count=%s porcelain_hash=%s unmerged_count=%s unmerged_hash=%s in_progress=%s\n' \
    "${branch:-}" "${head:-}" "${porcelain_count:-0}" "${porcelain_hash:-}" \
    "${unmerged_count:-0}" "${unmerged_hash:-}" "${in_progress:-}"
}

# Look up the current assignment ownership for the agent in
# state_dir/assignments.json. Returns the assigned issue and workdir
# string so callers can detect ownership drift between proof capture
# and validation. Empty values when no assignment file or no jq.
_recovery_context_assignment_signature() {
  local agent=${1:-}
  local issue="" workdir=""
  if [[ -z "$agent" ]] || ! command -v jq >/dev/null 2>&1; then
    printf 'issue= workdir=\n'
    return 0
  fi
  if declare -F state_get >/dev/null 2>&1; then
    local raw
    raw=$(state_get assignments 2>/dev/null || printf '{}')
    issue=$(printf '%s' "$raw" | jq -r --arg a "$agent" '.[$a].issue // .[$a].ticket // ""' 2>/dev/null || true)
    workdir=$(printf '%s' "$raw" | jq -r --arg a "$agent" '.[$a].workdir // ""' 2>/dev/null || true)
  fi
  [[ "$issue" == "null" ]] && issue=""
  [[ "$workdir" == "null" ]] && workdir=""
  printf 'issue=%s workdir=%s\n' "${issue:-}" "${workdir:-}"
}

recovery_context_pr_status() {
  local pr=${1:-}
  local repo=${2:-${GH_REPO:-}}
  local mergeable="unknown" merge_state="unknown" state="unknown" updated_at=""

  # Forge access through the provider adapter (#816). The normalised
  # lower-case enums are projected back to the upper-case values this line
  # always reported (MERGEABLE/CONFLICTING/UNKNOWN, CLEAN/DIRTY/..., OPEN/...).
  if [[ -n "$pr" && -n "$repo" ]] && command -v jq >/dev/null 2>&1 && _recovery_context_require_provider; then
    local raw
    if raw=$(GH_CONFIG_DIR="${GH_CONFIG_DIR:-}" ordo_provider pr_get "$pr" --repo "$repo" 2>/dev/null); then
      mergeable=$(printf '%s' "$raw" | jq -r '(.mergeable // "unknown") | ascii_upcase')
      merge_state=$(printf '%s' "$raw" | jq -r '(.merge_state // "unknown") | ascii_upcase')
      state=$(printf '%s' "$raw" | jq -r '(.state // "unknown") | ascii_upcase')
      updated_at=$(printf '%s' "$raw" | jq -r '.updated_at // ""')
    fi
  fi
  printf 'pr_status mergeable=%s mergeStateStatus=%s state=%s updatedAt=%s\n' \
    "$mergeable" "$merge_state" "$state" "${updated_at:-}"
}

recovery_context_capture() {
  local workdir=""
  local agent="" ticket="" pr="" reason=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --agent)  agent=${2:?--agent requires a value};  shift 2 ;;
      --ticket) ticket=${2:?--ticket requires a value}; shift 2 ;;
      --pr)     pr=${2:?--pr requires a value};         shift 2 ;;
      --reason) reason=${2:?--reason requires a value}; shift 2 ;;
      --) shift; break ;;
      -*)
        printf 'recovery_context_capture: unknown flag %s\n' "$1" >&2
        return 2
        ;;
      *)
        if [[ -z "$workdir" ]]; then
          workdir=$1
          shift
        else
          printf 'recovery_context_capture: unexpected positional %s\n' "$1" >&2
          return 2
        fi
        ;;
    esac
  done
  [[ -n "$workdir" ]] || {
    printf 'usage: recovery_context_capture <workdir> [--agent SLUG] [--ticket N] [--pr N] [--reason TEXT]\n' >&2
    return 2
  }

  local ts ts_file proof_dir proof_path slug state_line assignment_line pr_line
  ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  ts_file=$(date -u +'%Y%m%dT%H%M%SZ')
  proof_dir=$(recovery_context_proof_dir)
  slug=$(_recovery_context_workdir_slug "$workdir")
  proof_path="$proof_dir/${slug}-${ts_file}.json"

  state_line=$(_recovery_context_snapshot_state "$workdir")
  assignment_line=$(_recovery_context_assignment_signature "$agent")
  pr_line=$(recovery_context_pr_status "$pr")

  # Parse the key=value lines back into individual fields. Using awk so
  # the JSON encoder handles every value the same way regardless of how
  # many keys end up empty.
  local f_branch f_head f_porc_count f_porc_hash f_unm_count f_unm_hash f_in_progress
  local a_issue a_workdir
  local p_mergeable p_state p_status p_updated
  # shellcheck disable=SC2086
  eval "$(printf '%s' "$state_line" | sed -E 's/([a-z_]+)=([^[:space:]]*)/local f_\1="\2";/g; s/^/local _=/' | head -1)" 2>/dev/null || true
  # Re-parse robustly via awk → keep simple:
  f_branch=$(printf '%s' "$state_line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^branch=/){sub(/^branch=/,"",$i); print $i; exit}}')
  f_head=$(printf '%s' "$state_line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^head=/){sub(/^head=/,"",$i); print $i; exit}}')
  f_porc_count=$(printf '%s' "$state_line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^porcelain_count=/){sub(/^porcelain_count=/,"",$i); print $i; exit}}')
  f_porc_hash=$(printf '%s' "$state_line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^porcelain_hash=/){sub(/^porcelain_hash=/,"",$i); print $i; exit}}')
  f_unm_count=$(printf '%s' "$state_line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^unmerged_count=/){sub(/^unmerged_count=/,"",$i); print $i; exit}}')
  f_unm_hash=$(printf '%s' "$state_line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^unmerged_hash=/){sub(/^unmerged_hash=/,"",$i); print $i; exit}}')
  f_in_progress=$(printf '%s' "$state_line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^in_progress=/){sub(/^in_progress=/,"",$i); print $i; exit}}')
  a_issue=$(printf '%s' "$assignment_line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^issue=/){sub(/^issue=/,"",$i); print $i; exit}}')
  a_workdir=$(printf '%s' "$assignment_line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^workdir=/){sub(/^workdir=/,"",$i); print $i; exit}}')
  p_mergeable=$(printf '%s' "$pr_line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^mergeable=/){sub(/^mergeable=/,"",$i); print $i; exit}}')
  p_status=$(printf '%s' "$pr_line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^mergeStateStatus=/){sub(/^mergeStateStatus=/,"",$i); print $i; exit}}')
  p_state=$(printf '%s' "$pr_line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^state=/){sub(/^state=/,"",$i); print $i; exit}}')
  p_updated=$(printf '%s' "$pr_line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^updatedAt=/){sub(/^updatedAt=/,"",$i); print $i; exit}}')

  local destructive=0
  if [[ -n "$f_in_progress" ]] || [[ "${f_porc_count:-0}" != "0" ]] || [[ "${f_unm_count:-0}" != "0" ]]; then
    destructive=1
  fi

  # Re-collect the raw porcelain + unmerged lists for the proof file so
  # the operator inspecting the proof can see exactly what state ORDO
  # observed (the hashes alone are not enough for forensics).
  local porcelain_raw="" unmerged_raw=""
  if [[ -d "$workdir/.git" ]]; then
    porcelain_raw=$(git -C "$workdir" status --porcelain=v1 --branch 2>/dev/null || true)
    unmerged_raw=$(git -C "$workdir" diff --name-only --diff-filter=U 2>/dev/null || true)
  fi

  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg ts "$ts" \
      --arg max_age "$ORCH_RECOVERY_PROOF_MAX_AGE_SEC" \
      --arg workdir "$workdir" \
      --arg agent "$agent" \
      --arg ticket "$ticket" \
      --arg pr "$pr" \
      --arg reason "$reason" \
      --arg branch "$f_branch" \
      --arg head "$f_head" \
      --arg porc_count "$f_porc_count" \
      --arg porc_hash "$f_porc_hash" \
      --arg porc_raw "$porcelain_raw" \
      --arg unm_count "$f_unm_count" \
      --arg unm_hash "$f_unm_hash" \
      --arg unm_raw "$unmerged_raw" \
      --arg in_progress "$f_in_progress" \
      --arg destructive "$destructive" \
      --arg a_issue "$a_issue" \
      --arg a_workdir "$a_workdir" \
      --arg p_mergeable "$p_mergeable" \
      --arg p_status "$p_status" \
      --arg p_state "$p_state" \
      --arg p_updated "$p_updated" \
      '{
        timestamp: $ts,
        max_age_sec: ($max_age|tonumber? // 300),
        workdir: $workdir,
        agent: (if $agent == "" then null else $agent end),
        ticket: (if $ticket == "" then null else $ticket end),
        pr: (if $pr == "" then null else $pr end),
        reason: (if $reason == "" then null else $reason end),
        local_state: {
          branch: $branch,
          head: $head,
          porcelain_count: ($porc_count|tonumber? // 0),
          porcelain_hash: $porc_hash,
          porcelain: $porc_raw,
          unmerged_count: ($unm_count|tonumber? // 0),
          unmerged_hash: $unm_hash,
          unmerged: $unm_raw,
          in_progress: $in_progress
        },
        agent_ownership: {
          assigned_issue: $a_issue,
          assigned_workdir: $a_workdir
        },
        pr_status: {
          mergeable: $p_mergeable,
          mergeStateStatus: $p_status,
          state: $p_state,
          updatedAt: $p_updated
        },
        destructive: ($destructive == "1"),
        commands: [
          "git -C $WORKDIR rev-parse --absolute-git-dir",
          "git -C $WORKDIR branch --show-current",
          "git -C $WORKDIR rev-parse --verify HEAD",
          "git -C $WORKDIR status --porcelain=v1 --branch",
          "git -C $WORKDIR diff --name-only --diff-filter=U",
          "ordo_provider pr_get $PR --repo $GH_REPO"
        ]
      }' > "$proof_path"
  else
    # Degraded fallback: jq is not installed. We still write a parseable
    # one-line key=value file so the validator can read it without jq.
    printf 'timestamp=%s max_age_sec=%s workdir=%s agent=%s ticket=%s pr=%s branch=%s head=%s porcelain_count=%s porcelain_hash=%s unmerged_count=%s unmerged_hash=%s in_progress=%s destructive=%s a_issue=%s a_workdir=%s p_mergeable=%s p_status=%s p_state=%s p_updated=%s\n' \
      "$ts" "$ORCH_RECOVERY_PROOF_MAX_AGE_SEC" "$workdir" "$agent" "$ticket" "$pr" \
      "$f_branch" "$f_head" "$f_porc_count" "$f_porc_hash" \
      "$f_unm_count" "$f_unm_hash" "$f_in_progress" "$destructive" \
      "$a_issue" "$a_workdir" "$p_mergeable" "$p_status" "$p_state" "$p_updated" \
      > "$proof_path"
  fi

  # shellcheck disable=SC2034 # consumed by callers after sourcing
  RECOVERY_CONTEXT_PROOF_PATH="$proof_path"
  # shellcheck disable=SC2034
  RECOVERY_CONTEXT_PROOF_TIMESTAMP="$ts"
  # shellcheck disable=SC2034
  RECOVERY_CONTEXT_PROOF_DESTRUCTIVE="$destructive"
  # shellcheck disable=SC2034
  RECOVERY_CONTEXT_PROOF_BRANCH="$f_branch"
  # shellcheck disable=SC2034
  RECOVERY_CONTEXT_PROOF_HEAD="$f_head"
  # shellcheck disable=SC2034
  RECOVERY_CONTEXT_PROOF_PORCELAIN_COUNT="${f_porc_count:-0}"
  # shellcheck disable=SC2034
  RECOVERY_CONTEXT_PROOF_UNMERGED_COUNT="${f_unm_count:-0}"
  # shellcheck disable=SC2034
  RECOVERY_CONTEXT_PROOF_IN_PROGRESS="$f_in_progress"
  # shellcheck disable=SC2034
  RECOVERY_CONTEXT_PROOF_PR_MERGE_STATE="$p_status"

  if declare -F audit >/dev/null 2>&1; then
    audit "RECOVERY_CONTEXT_PROOF captured agent=${agent:-none} ticket=${ticket:-none} pr=${pr:-none} workdir=${workdir} branch=${f_branch:-} head=${f_head:-} porcelain_count=${f_porc_count:-0} unmerged_count=${f_unm_count:-0} in_progress=${f_in_progress:-none} pr_mergeStateStatus=${p_status:-unknown} destructive=${destructive} proof=${proof_path}"
  fi

  printf '%s\n' "$proof_path"
}

# Emit a JSON value for the named field of a proof file, falling back to
# the key=value degraded format when jq is unavailable. Intentionally
# narrow — only used by the validator below.
_recovery_context_proof_field() {
  local proof=${1:?usage: _recovery_context_proof_field <proof> <field-jq-path> <degraded-key>}
  local jq_path=$2
  local degraded_key=$3
  if command -v jq >/dev/null 2>&1; then
    local val
    val=$(jq -r "$jq_path" "$proof" 2>/dev/null)
    [[ "$val" == "null" ]] && val=""
    printf '%s\n' "$val"
    return 0
  fi
  awk -v key="$degraded_key" '{
    for (i = 1; i <= NF; i++) {
      if ($i ~ "^" key "=") {
        sub("^" key "=", "", $i)
        print $i
        exit
      }
    }
  }' "$proof"
}

recovery_context_validate() {
  local proof=${1:?usage: recovery_context_validate <proof-path> <workdir>}
  local workdir=${2:?usage: recovery_context_validate <proof-path> <workdir>}

  # shellcheck disable=SC2034
  RECOVERY_CONTEXT_VALIDATE_REASON=""
  # shellcheck disable=SC2034
  RECOVERY_CONTEXT_VALIDATE_DETAIL=""
  # shellcheck disable=SC2034
  RECOVERY_CONTEXT_VALIDATE_AGE_SEC=""

  if [[ ! -s "$proof" ]]; then
    # shellcheck disable=SC2034
    RECOVERY_CONTEXT_VALIDATE_REASON="proof_unreadable"
    # shellcheck disable=SC2034
    RECOVERY_CONTEXT_VALIDATE_DETAIL="proof=${proof} not found or empty"
    return 1
  fi

  local proof_ts max_age proof_workdir proof_agent
  local proof_branch proof_head proof_porc_hash proof_unm_hash proof_in_progress
  local proof_a_issue proof_a_workdir
  proof_ts=$(_recovery_context_proof_field "$proof" '.timestamp // ""' timestamp)
  max_age=$(_recovery_context_proof_field "$proof" '.max_age_sec // 300' max_age_sec)
  proof_workdir=$(_recovery_context_proof_field "$proof" '.workdir // ""' workdir)
  proof_agent=$(_recovery_context_proof_field "$proof" '.agent // ""' agent)
  proof_branch=$(_recovery_context_proof_field "$proof" '.local_state.branch // ""' branch)
  proof_head=$(_recovery_context_proof_field "$proof" '.local_state.head // ""' head)
  proof_porc_hash=$(_recovery_context_proof_field "$proof" '.local_state.porcelain_hash // ""' porcelain_hash)
  proof_unm_hash=$(_recovery_context_proof_field "$proof" '.local_state.unmerged_hash // ""' unmerged_hash)
  proof_in_progress=$(_recovery_context_proof_field "$proof" '.local_state.in_progress // ""' in_progress)
  proof_a_issue=$(_recovery_context_proof_field "$proof" '.agent_ownership.assigned_issue // ""' a_issue)
  proof_a_workdir=$(_recovery_context_proof_field "$proof" '.agent_ownership.assigned_workdir // ""' a_workdir)

  # Workdir parity — a proof for /repos/copilot must not be applied to
  # /repos/cursor even if both are dirty. This is the same Wave-23 leak
  # pattern as #376, refused on the recovery surface.
  if [[ "${proof_workdir%/}" != "${workdir%/}" ]]; then
    # shellcheck disable=SC2034
    RECOVERY_CONTEXT_VALIDATE_REASON="workdir_mismatch"
    # shellcheck disable=SC2034
    RECOVERY_CONTEXT_VALIDATE_DETAIL="proof_workdir=${proof_workdir} live_workdir=${workdir}"
    return 1
  fi

  # Stale-by-age check. We use `date -d` when available; otherwise we
  # accept the proof on the cautious side (no clock available means the
  # validator cannot prove staleness, so it falls through to the
  # state-drift check which is the stronger signal anyway).
  local now_ts age=0
  now_ts=$(date -u +%s)
  if [[ -n "$proof_ts" ]] && command -v date >/dev/null 2>&1; then
    local proof_epoch
    proof_epoch=$(date -u -d "$proof_ts" +%s 2>/dev/null || true)
    if [[ -n "$proof_epoch" ]]; then
      age=$((now_ts - proof_epoch))
    fi
  fi
  # shellcheck disable=SC2034
  RECOVERY_CONTEXT_VALIDATE_AGE_SEC="$age"
  if [[ "$age" -gt "${max_age:-$ORCH_RECOVERY_PROOF_MAX_AGE_SEC}" ]]; then
    # shellcheck disable=SC2034
    RECOVERY_CONTEXT_VALIDATE_REASON="stale_age"
    # shellcheck disable=SC2034
    RECOVERY_CONTEXT_VALIDATE_DETAIL="age_sec=${age} max_age_sec=${max_age:-$ORCH_RECOVERY_PROOF_MAX_AGE_SEC} proof_ts=${proof_ts}"
    return 1
  fi

  # Live state re-snapshot. Compares the same field set as the
  # capture so a workdir that "fixed itself" between proof and request
  # is detected (the canonical AC-1 stale dirty case).
  local live_line live_branch live_head live_porc_hash live_unm_hash live_in_progress
  live_line=$(_recovery_context_snapshot_state "$workdir")
  live_branch=$(printf '%s' "$live_line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^branch=/){sub(/^branch=/,"",$i); print $i; exit}}')
  live_head=$(printf '%s' "$live_line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^head=/){sub(/^head=/,"",$i); print $i; exit}}')
  live_porc_hash=$(printf '%s' "$live_line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^porcelain_hash=/){sub(/^porcelain_hash=/,"",$i); print $i; exit}}')
  live_unm_hash=$(printf '%s' "$live_line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^unmerged_hash=/){sub(/^unmerged_hash=/,"",$i); print $i; exit}}')
  live_in_progress=$(printf '%s' "$live_line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^in_progress=/){sub(/^in_progress=/,"",$i); print $i; exit}}')

  local -a drifted=()
  [[ "$live_branch"      != "$proof_branch"      ]] && drifted+=("branch:${proof_branch}->${live_branch}")
  [[ "$live_head"        != "$proof_head"        ]] && drifted+=("head:${proof_head:0:8}->${live_head:0:8}")
  [[ "$live_porc_hash"   != "$proof_porc_hash"   ]] && drifted+=("porcelain_hash")
  [[ "$live_unm_hash"    != "$proof_unm_hash"    ]] && drifted+=("unmerged_hash")
  [[ "$live_in_progress" != "$proof_in_progress" ]] && drifted+=("in_progress:${proof_in_progress:-none}->${live_in_progress:-none}")

  if [[ "${#drifted[@]}" -gt 0 ]]; then
    local IFS=,
    # shellcheck disable=SC2034
    RECOVERY_CONTEXT_VALIDATE_REASON="state_drift"
    # shellcheck disable=SC2034
    RECOVERY_CONTEXT_VALIDATE_DETAIL="drifted=${drifted[*]}"
    unset IFS
    return 1
  fi

  # Ownership drift — assignments.json was rewritten between proof
  # capture and validation (e.g. an operator preempted the agent).
  local live_assign_line live_a_issue live_a_workdir
  live_assign_line=$(_recovery_context_assignment_signature "$proof_agent")
  live_a_issue=$(printf '%s' "$live_assign_line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^issue=/){sub(/^issue=/,"",$i); print $i; exit}}')
  live_a_workdir=$(printf '%s' "$live_assign_line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^workdir=/){sub(/^workdir=/,"",$i); print $i; exit}}')

  if [[ "$live_a_issue"   != "$proof_a_issue"   ]] \
     || [[ "$live_a_workdir" != "$proof_a_workdir" ]]; then
    # shellcheck disable=SC2034
    RECOVERY_CONTEXT_VALIDATE_REASON="ownership_drift"
    # shellcheck disable=SC2034
    RECOVERY_CONTEXT_VALIDATE_DETAIL="proof_issue=${proof_a_issue:-none} live_issue=${live_a_issue:-none} proof_workdir=${proof_a_workdir:-none} live_workdir=${live_a_workdir:-none}"
    return 1
  fi

  return 0
}

# Convenience wrapper used by destructive code paths. Returns the
# `ORCH_RECOVERY_PROOF_STALE_EXIT_CODE` exit code on stale/invalid
# proof so callers can `exit "$rc"` directly without remembering the
# specific number.
recovery_context_assert_fresh() {
  local proof=${1:-}
  local workdir=${2:-}
  if recovery_context_validate "$proof" "$workdir"; then
    if declare -F audit >/dev/null 2>&1; then
      audit "RECOVERY_CONTEXT_PROOF validated proof=${proof} workdir=${workdir} age_sec=${RECOVERY_CONTEXT_VALIDATE_AGE_SEC:-0}"
    fi
    return 0
  fi
  if declare -F audit >/dev/null 2>&1; then
    audit "RECOVERY_PROOF_STALE proof=${proof} workdir=${workdir} reason=${RECOVERY_CONTEXT_VALIDATE_REASON:-unknown} detail=${RECOVERY_CONTEXT_VALIDATE_DETAIL:-} age_sec=${RECOVERY_CONTEXT_VALIDATE_AGE_SEC:-0}"
  fi
  printf 'RECOVERY_PROOF_STALE: proof=%s workdir=%s reason=%s %s\n' \
    "$proof" "$workdir" \
    "${RECOVERY_CONTEXT_VALIDATE_REASON:-unknown}" \
    "${RECOVERY_CONTEXT_VALIDATE_DETAIL:-}" >&2
  return "$ORCH_RECOVERY_PROOF_STALE_EXIT_CODE"
}
