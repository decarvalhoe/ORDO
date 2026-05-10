#!/usr/bin/env bash
# dispatch_router.sh — routing-surface consistency guard for dispatch.
#
# Issue #376: refuse a dispatch *before* the staged copy is written and
# before `tmux send-keys` runs when the prompt body, the staging
# filename, the pinned cwd, the target pane, and (best-effort) the
# pinned-workdir git identity disagree about which agent is being
# addressed.
#
# Background: in Wave-23 ORDO sent `/tmp/dispatch-rbok-cursor-301.md`
# to the `rbok-cursor:0.0` pane, but the body was addressed to
# `ordo agent: copilot` and pinned cwd
# `/root/.../repos/ordo/copilot`. The worker-side identity guard
# correctly refused, but only after the brief was already on the
# filesystem and on the pane. The orchestrator-side guard implemented
# here catches the same drift earlier so the brief never reaches a
# mismatched pane.
#
# Surfaces compared (issue #376 "required behavior"):
#   1. intended pane/session agent slug (resolved via agent_target)
#   2. dispatch filename slug (basename → `dispatch-<agent>-<ticket>.md`)
#   3. first-line body agent token (`# Dispatch … agent: <slug>` or the
#      PR-op variant `- Agent label: \`<slug>\``)
#   4. pinned cwd path component (first ``cd <abs-path>`` in the body)
#   5. expected git identity for the pinned workdir, when both the
#      workdir's `git config user.name` and `resolve_agent_github_login`
#      resolve.
#
# The worker-side identity refusal (CLAUDE.md "Identity" section) is the
# documented last-resort safety net and stays unchanged.
#
# Public API:
#   dispatch_router_assert_consistency AGENT TICKET PANE_TARGET \
#                                      PROMPT_FILE WORKDIR
#     Returns 0 on consistent routing. Returns 1 on mismatch and emits a
#     structured audit line `DISPATCH ROUTE_MISMATCH …` plus a one-line
#     stderr message of the form
#     `DISPATCH_ROUTE_MISMATCH: agent=… mismatched_fields=… …`.
#     Side-channel state for callers (do not unset between sourcing and
#     read; cleared on each call):
#       DISPATCH_ROUTER_REASON           short slug
#       DISPATCH_ROUTER_FIELDS           comma-joined mismatched fields
#       DISPATCH_ROUTER_FILENAME_AGENT   parsed from basename(prompt)
#       DISPATCH_ROUTER_BODY_AGENT       parsed from prompt body
#       DISPATCH_ROUTER_BODY_CWD         first `cd <abs-path>` in body
#       DISPATCH_ROUTER_EXPECTED_PANE    agent_target(agent)
#       DISPATCH_ROUTER_PANE             input pane target
#       DISPATCH_ROUTER_WORKDIR          input workdir
#       DISPATCH_ROUTER_WORKDIR_IDENTITY git user.name on workdir, ''
#                                        when not set or unreadable.
#       DISPATCH_ROUTER_EXPECTED_LOGIN   resolve_agent_github_login,
#                                        '' when unresolved.
#       DISPATCH_ROUTER_EXPECTED_GIT_IDENTITY configured git user.name,
#                                        '' when unresolved.
#
# Sourcing contract: dispatch_router.sh expects audit_log.sh to be
# sourced before it (for `audit`). It does not source any other lib —
# callers that want pane/inventory introspection must source those
# helpers themselves so the guard stays cheap to use from tests.

: "${ORCH_DISPATCH_ROUTER_BODY_SCAN_LINES:=80}"
: "${ORCH_DISPATCH_ROUTER_AUDIT_PREFIX:=DISPATCH ROUTE_MISMATCH}"

# Exit code reserved for the orchestrator-side routing-surface guard.
# Distinct from 76 (post-dispatch live-cwd context proof, #112), 77
# (pre-dispatch readiness handshake, #123), 78 (heavy-validator opt-in /
# identity guard), 79 (dispatch not consumed) and 80 (external-PR
# mutation gate). 81 is reserved here so dashboards can group live route
# refusals separately from those.
: "${ORCH_DISPATCH_ROUTE_MISMATCH_EXIT_CODE:=81}"

# Parse `dispatch-<agent>-<ticket>.md`. CI-autofix historically passes a
# source prompt named `dispatch-<agent>-autofix-pr-<pr>.md`; accept that
# route-safe form too because dispatch_ticket stages the accepted prompt
# under the canonical `dispatch-<agent>-<ticket>.md` path immediately
# after this guard. Echoes the agent slug; returns 1 when the filename
# does not parse so callers can distinguish "no agent claim" from a real
# mismatch.
dispatch_router_filename_agent() {
  local prompt_file=${1:?usage: dispatch_router_filename_agent <prompt-file>}
  local base=${prompt_file##*/}
  base=${base%.md}
  case "$base" in
    dispatch-*-*) ;;
    *) return 1 ;;
  esac
  local rest=${base#dispatch-}
  if [[ "$rest" =~ ^(.+)-autofix-pr-[0-9]+$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  # Strip the trailing `-<ticket>` suffix. Tickets are decimal here, but
  # operator-supplied prompts in tests sometimes use alphanumeric ticket
  # ids — accept any non-dash suffix to stay forward-compatible.
  if ! [[ "$rest" =~ -[A-Za-z0-9]+$ ]]; then
    return 1
  fi
  printf '%s\n' "${rest%-*}"
}

# Echo the first agent token claimed by the prompt body. Two formats are
# recognized — the canonical/ticket templates' H1
# `# Dispatch … agent: <slug>` and the PR-op templates'
# `- Agent label: \`<slug>\`` line. Returns 1 when neither is present so
# the caller can record `body_agent=none` instead of an empty match.
dispatch_router_body_agent() {
  local prompt_file=${1:?usage: dispatch_router_body_agent <prompt-file>}
  local lines=${2:-$ORCH_DISPATCH_ROUTER_BODY_SCAN_LINES}
  local match
  match=$(awk -v limit="$lines" '
    NR > limit { exit }
    {
      if (match($0, /^#[[:space:]]*[Dd]ispatch[^\n]*[Aa]gent:[[:space:]]*[^[:space:]]+/)) {
        line=$0
        sub(/^.*[Aa]gent:[[:space:]]*/, "", line)
        sub(/[[:space:]].*$/, "", line)
        print line
        exit
      }
      if (match($0, /^-[[:space:]]*[Aa]gent[[:space:]]+label:[[:space:]]*`[^`]+`/)) {
        line=$0
        sub(/^.*[Aa]gent[[:space:]]+label:[[:space:]]*`/, "", line)
        sub(/`.*$/, "", line)
        print line
        exit
      }
    }
  ' "$prompt_file" 2>/dev/null)
  [[ -n "$match" ]] || return 1
  printf '%s\n' "$match"
}

# Echo the first absolute-path `cd <path>` reference in the body. The
# canonical template emits ``- `cd {{repo}}` `` and operator-authored
# briefs emit ``- Cwd: `cd /root/...` ``; both forms wrap the path in
# backticks. We accept either backtick-wrapped or bare forms but only
# absolute paths so we never key off relative `cd subdir` lines.
dispatch_router_body_cwd() {
  local prompt_file=${1:?usage: dispatch_router_body_cwd <prompt-file>}
  local lines=${2:-$ORCH_DISPATCH_ROUTER_BODY_SCAN_LINES}
  local match
  match=$(awk -v limit="$lines" '
    NR > limit { exit }
    {
      if (match($0, /`cd[[:space:]]+\/[^`]+`/)) {
        seg=substr($0, RSTART, RLENGTH)
        gsub(/`/, "", seg)
        sub(/^cd[[:space:]]+/, "", seg)
        sub(/[[:space:]].*$/, "", seg)
        print seg
        exit
      }
      if (match($0, /(^|[^A-Za-z0-9_])cd[[:space:]]+\/[A-Za-z0-9_./-]+/)) {
        seg=substr($0, RSTART, RLENGTH)
        sub(/^[^/]*\//, "/", seg)
        sub(/[[:space:]].*$/, "", seg)
        print seg
        exit
      }
    }
  ' "$prompt_file" 2>/dev/null)
  [[ -n "$match" ]] || return 1
  # Trim a single trailing slash for stable equality against
  # `agent_repo_root` output.
  printf '%s\n' "${match%/}"
}

# Echo `git -C $workdir config user.name`, or empty string when the
# workdir is not a git repo or the value is unset. Never errors.
dispatch_router_workdir_identity() {
  local workdir=${1:-}
  [[ -n "$workdir" && -d "$workdir/.git" ]] || return 0
  git -C "$workdir" config user.name 2>/dev/null || true
}

# Echo the configured git user.name for an agent, when a profile has one.
# This intentionally stays independent from the GitHub login mapping:
# AGENT_GH_LOGINS is for assignees/API identity, while AGENT_GIT_IDENTITIES
# and AGENT_GIT_IDENTITY_NAME_TEMPLATE describe commit display names.
dispatch_router_expected_git_identity() {
  local agent=${1:?usage: dispatch_router_expected_git_identity <agent>}
  local entry entry_agent entry_name entry_extra

  if declare -F agent_git_identity >/dev/null 2>&1; then
    local identity_output identity_status=0
    identity_output=$(agent_git_identity "$agent") || identity_status=$?
    if [[ "$identity_status" -eq 0 ]]; then
      printf '%s\n' "$identity_output" | sed -n '1p'
      return 0
    fi
  fi

  if [[ -n "${AGENT_GIT_IDENTITIES+x}" && "${#AGENT_GIT_IDENTITIES[@]}" -gt 0 ]]; then
    for entry in "${AGENT_GIT_IDENTITIES[@]}"; do
      IFS='|' read -r entry_agent entry_name _ entry_extra <<< "$entry"
      [[ -z "$entry_extra" ]] || continue
      if [[ "$entry_agent" == "$agent" && -n "$entry_name" ]]; then
        printf '%s\n' "$entry_name"
        return 0
      fi
    done
  fi

  if [[ -n "${AGENT_GIT_IDENTITY_NAME_TEMPLATE:-}" ]]; then
    # shellcheck disable=SC2059
    printf "$AGENT_GIT_IDENTITY_NAME_TEMPLATE" "$agent"
    printf '\n'
    return 0
  fi

  return 1
}

# Resolve the orchestrator-recorded expected pane for an agent. Falls
# back to the legacy `${AGENT_SESSION_PREFIX}${agent}:${WIN}` synthesis
# when no inventory helper is available so the guard still works in the
# brief_agents shell-test sandbox.
dispatch_router_expected_pane() {
  local agent=${1:?usage: dispatch_router_expected_pane <agent>}
  if declare -F agent_target >/dev/null 2>&1; then
    agent_target "$agent"
    return 0
  fi
  printf '%s%s:%s\n' "${AGENT_SESSION_PREFIX:-}" "$agent" "${AGENT_WINDOW_INDEX:-0}"
}

dispatch_router_assert_consistency() {
  local agent=${1:?usage: dispatch_router_assert_consistency <agent> <ticket> <pane> <prompt-file> <workdir>}
  local ticket=${2:?usage: dispatch_router_assert_consistency <agent> <ticket> <pane> <prompt-file> <workdir>}
  local pane=${3:?usage: dispatch_router_assert_consistency <agent> <ticket> <pane> <prompt-file> <workdir>}
  local prompt_file=${4:?usage: dispatch_router_assert_consistency <agent> <ticket> <pane> <prompt-file> <workdir>}
  local workdir=${5:?usage: dispatch_router_assert_consistency <agent> <ticket> <pane> <prompt-file> <workdir>}

  ticket=${ticket#\#}

  # Reset side-channel state on every call so a previous mismatch does
  # not bleed into the next dispatch's audit line.
  # shellcheck disable=SC2034
  DISPATCH_ROUTER_REASON=""
  # shellcheck disable=SC2034
  DISPATCH_ROUTER_FIELDS=""
  # shellcheck disable=SC2034
  DISPATCH_ROUTER_FILENAME_AGENT=""
  # shellcheck disable=SC2034
  DISPATCH_ROUTER_BODY_AGENT=""
  # shellcheck disable=SC2034
  DISPATCH_ROUTER_BODY_CWD=""
  # shellcheck disable=SC2034
  DISPATCH_ROUTER_EXPECTED_PANE=""
  # shellcheck disable=SC2034
  DISPATCH_ROUTER_PANE="$pane"
  # shellcheck disable=SC2034
  DISPATCH_ROUTER_WORKDIR="$workdir"
  # shellcheck disable=SC2034
  DISPATCH_ROUTER_WORKDIR_IDENTITY=""
  # shellcheck disable=SC2034
  DISPATCH_ROUTER_EXPECTED_LOGIN=""
  # shellcheck disable=SC2034
  DISPATCH_ROUTER_EXPECTED_GIT_IDENTITY=""

  if [[ ! -f "$prompt_file" ]]; then
    DISPATCH_ROUTER_REASON="prompt_missing"
    DISPATCH_ROUTER_FIELDS="prompt_file"
    if declare -F audit >/dev/null 2>&1; then
      audit "$ORCH_DISPATCH_ROUTER_AUDIT_PREFIX agent=${agent} ticket=#${ticket} pane=${pane} workdir=${workdir} prompt=${prompt_file##*/} mismatched_fields=prompt_file reason=prompt_missing"
    fi
    printf 'DISPATCH_ROUTE_MISMATCH: agent=%s ticket=#%s reason=prompt_missing prompt=%s\n' \
      "$agent" "$ticket" "$prompt_file" >&2
    return 1
  fi

  # Initialize locals explicitly — some surfaces have no claim and the
  # callers run with `set -u`, so a `local var` without an assignment
  # would trip the unbound-variable check on the first read below.
  local filename_agent="" body_agent="" body_cwd="" expected_pane=""
  local workdir_identity="" expected_login="" expected_git_identity=""
  filename_agent=$(dispatch_router_filename_agent "$prompt_file" 2>/dev/null || true)
  body_agent=$(dispatch_router_body_agent "$prompt_file" 2>/dev/null || true)
  body_cwd=$(dispatch_router_body_cwd "$prompt_file" 2>/dev/null || true)
  expected_pane=$(dispatch_router_expected_pane "$agent" 2>/dev/null || true)
  workdir_identity=$(dispatch_router_workdir_identity "$workdir" 2>/dev/null || true)
  if declare -F resolve_agent_github_login >/dev/null 2>&1; then
    expected_login=$(resolve_agent_github_login "$agent" 2>/dev/null || true)
  fi
  expected_git_identity=$(dispatch_router_expected_git_identity "$agent" 2>/dev/null || true)

  # shellcheck disable=SC2034
  DISPATCH_ROUTER_FILENAME_AGENT="$filename_agent"
  # shellcheck disable=SC2034
  DISPATCH_ROUTER_BODY_AGENT="$body_agent"
  # shellcheck disable=SC2034
  DISPATCH_ROUTER_BODY_CWD="$body_cwd"
  # shellcheck disable=SC2034
  DISPATCH_ROUTER_EXPECTED_PANE="$expected_pane"
  # shellcheck disable=SC2034
  DISPATCH_ROUTER_WORKDIR_IDENTITY="$workdir_identity"
  # shellcheck disable=SC2034
  DISPATCH_ROUTER_EXPECTED_LOGIN="$expected_login"
  # shellcheck disable=SC2034
  DISPATCH_ROUTER_EXPECTED_GIT_IDENTITY="$expected_git_identity"

  local -a mismatched=()
  local -a details=()

  # Filename slug — strict when present. The dispatcher writes its own
  # filename downstream, but operator-supplied paths can carry another
  # agent's slug; that is the live Wave-23 incident this guard catches.
  if [[ -n "$filename_agent" && "$filename_agent" != "$agent" ]]; then
    mismatched+=("filename_agent")
    details+=("filename_agent=${filename_agent}")
  fi

  # First-line body agent token. PR-op briefs use `Agent label:` so the
  # token may legitimately be missing for non-canonical templates; a
  # missing claim is recorded but is not a mismatch on its own.
  if [[ -n "$body_agent" && "$body_agent" != "$agent" ]]; then
    mismatched+=("body_agent")
    details+=("body_agent=${body_agent}")
  fi

  # Pinned cwd path component. We compare the rendered absolute path
  # with the orchestrator's own resolution of the agent's repo root.
  # Equality is the strict case; subpath matches are acceptable so a
  # brief that pins a sub-directory under the repo (e.g. for a
  # docs-only ticket) still validates.
  if [[ -n "$body_cwd" && -n "$workdir" ]]; then
    local norm_body norm_workdir
    norm_body=${body_cwd%/}
    norm_workdir=${workdir%/}
    if [[ "$norm_body" != "$norm_workdir" ]] \
      && [[ "$norm_body" != "$norm_workdir"/* ]]; then
      mismatched+=("pinned_cwd")
      details+=("pinned_cwd=${body_cwd}")
    fi
  fi

  # Pane / session slug. The dispatcher always resolves the pane via
  # `agent_target` itself, so this is a self-check that catches a
  # divergence between the declared agent and the resolved pane
  # (mostly: stale `AGENT_PANES` re-mapped a label to another fleet's
  # pane).
  if [[ -n "$expected_pane" && -n "$pane" && "$expected_pane" != "$pane" ]]; then
    mismatched+=("pane_target")
    details+=("expected_pane=${expected_pane}")
  fi

  # Pinned-workdir git identity (best-effort). A configured git display
  # name is authoritative for commit identity; GitHub login is only the
  # fallback when no display name is configured.
  if [[ -n "$workdir_identity" && -n "$expected_git_identity" ]]; then
    if [[ "$workdir_identity" != "$expected_git_identity" ]]; then
      mismatched+=("workdir_identity")
      details+=("workdir_identity=${workdir_identity} expected_git_identity=${expected_git_identity} expected_login=${expected_login:-none}")
    fi
  elif [[ -n "$workdir_identity" && -n "$expected_login" \
        && "$expected_login" != "$agent" \
        && "$workdir_identity" != "$expected_login" ]] \
        && ! [[ "${workdir_identity,,}" == *"${expected_login,,}"* ]]; then
    mismatched+=("workdir_identity")
    details+=("workdir_identity=${workdir_identity} expected_login=${expected_login}")
  fi

  if [[ "${#mismatched[@]}" -eq 0 ]]; then
    if declare -F audit >/dev/null 2>&1; then
      audit "DISPATCH ROUTE_OK agent=${agent} ticket=#${ticket} pane=${pane} workdir=${workdir} prompt=${prompt_file##*/} filename_agent=${filename_agent:-none} body_agent=${body_agent:-none} body_cwd=${body_cwd:-none} workdir_identity=${workdir_identity:-none} expected_login=${expected_login:-none} expected_git_identity=${expected_git_identity:-none}"
    fi
    return 0
  fi

  local field_csv
  local IFS=,
  field_csv="${mismatched[*]}"
  unset IFS
  # shellcheck disable=SC2034
  DISPATCH_ROUTER_FIELDS="$field_csv"
  # shellcheck disable=SC2034
  DISPATCH_ROUTER_REASON="route_mismatch_refused"

  local detail_text
  detail_text="${details[*]}"

  if declare -F audit >/dev/null 2>&1; then
    audit "$ORCH_DISPATCH_ROUTER_AUDIT_PREFIX agent=${agent} ticket=#${ticket} pane=${pane} workdir=${workdir} prompt=${prompt_file##*/} mismatched_fields=${field_csv} filename_agent=${filename_agent:-none} body_agent=${body_agent:-none} body_cwd=${body_cwd:-none} expected_pane=${expected_pane:-none} workdir_identity=${workdir_identity:-none} expected_login=${expected_login:-none} expected_git_identity=${expected_git_identity:-none} reason=route_mismatch_refused"
  fi
  printf 'DISPATCH_ROUTE_MISMATCH: agent=%s ticket=#%s pane=%s workdir=%s prompt=%s mismatched_fields=%s %s\n' \
    "$agent" "$ticket" "$pane" "$workdir" "${prompt_file##*/}" "$field_csv" "$detail_text" >&2

  return 1
}
