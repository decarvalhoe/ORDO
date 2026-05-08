#!/usr/bin/env bash
# runtime_freshness.sh — auto-fast-forward stale orchestrator runtime (#377).
#
# Before each orchestrator start / resume / monitor loop ORDO must verify
# that the active runtime checkout is a fresh sibling of `origin/<default>`.
# A stale runtime supervises the fleet using out-of-date scripts and docs;
# during the 2026-05-08 incident the runtime at
# `/root/rbokproject-fleet-20260508-clean/orchestrator/ORDO` was 34 commits
# behind `origin/main`, masking already-merged fixes around the monitor
# loop, dispatch policy, docs-impact, PR ops, and routing guards.
#
# This library is the single source of truth for the freshness preflight.
# It is sourced by `scripts/orch_loop.sh` at boot and may be invoked
# directly by an operator who wants the same gate before resuming a
# parked session.
#
# Inputs (env, all optional unless required):
#   ORCH_RUNTIME_FRESHNESS_PATH         — runtime checkout path. Defaults
#                                          to the toolkit root that loaded
#                                          this lib.
#   ORCH_RUNTIME_FRESHNESS_DEFAULT      — default branch name. Defaults
#                                          to `main`.
#   ORCH_RUNTIME_FRESHNESS_REMOTE       — remote name. Defaults to
#                                          `origin`.
#   ORCH_RUNTIME_FRESHNESS_FETCH_SEC    — fetch timeout, seconds. Default 30.
#   ORCH_RUNTIME_FRESHNESS_GIT_SEC      — per-git-command timeout. Default 5.
#   ORCH_RUNTIME_FRESHNESS_NO_FETCH     — when "1", skip the network fetch
#                                          (tests + offline operator runs).
#   ORCH_RUNTIME_FRESHNESS_SIDECAR_GLOBS — colon-separated globs that
#                                          identify sidecar/untracked files
#                                          to ignore. Default: known LLM /
#                                          IDE sidecars listed in
#                                          DEFAULT_SIDECAR_GLOBS below.
#
# Public API:
#   runtime_freshness_classify <path>        — echo classification token:
#                                              clean-uptodate | clean-behind
#                                              | dirty-tracked | ahead-only
#                                              | diverged | sidecar-only
#                                              | unknown | not-a-git-repo
#   runtime_freshness_action <path>          — echo {fast-forward|refuse|noop|skip}
#                                              given the classification.
#   runtime_freshness_assert <path> [<context>]
#                                            — full preflight: fetch,
#                                              classify, fast-forward when
#                                              clean-behind/sidecar-only,
#                                              refuse otherwise. Returns:
#                                                0  — runtime is fresh (or was
#                                                     fast-forwarded to fresh)
#                                                10 — refused: dirty tracked
#                                                11 — refused: ahead/diverged
#                                                12 — refused: not a git repo
#                                                13 — refused: fetch failed
#                                              Always emits a structured
#                                              audit line carrying old SHA,
#                                              new SHA, ahead/behind counts,
#                                              and the action taken. Caller
#                                              should treat any non-zero
#                                              exit as a blocker and log
#                                              the per-line `git status
#                                              --porcelain` evidence.
#   runtime_freshness_summary_line <path>    — one-line `runtime_sha=X
#                                              behind=N ahead=M classification=K
#                                              action=A` for the orchestrator
#                                              status report.

# Default sidecar globs — files & directories that are known operator-
# maintained scratch state (LLM sidecar, IDE workspace files, OS metadata)
# and therefore safe to ignore on the freshness check. Operators who want a
# different list set ORCH_RUNTIME_FRESHNESS_SIDECAR_GLOBS.
DEFAULT_SIDECAR_GLOBS=(
  '.claude/*'
  '.claude'
  '.cursor/*'
  '.cursor'
  '.aider/*'
  '.aider*'
  '.vscode/*'
  '.idea/*'
  '.DS_Store'
  '.envrc.local'
  '.tool-versions.local'
)

_runtime_freshness_default_path() {
  printf '%s\n' "${ORCH_RUNTIME_FRESHNESS_PATH:-${TK:-$(pwd)}}"
}

_runtime_freshness_default_branch() {
  printf '%s\n' "${ORCH_RUNTIME_FRESHNESS_DEFAULT:-${DEFAULT_BRANCH:-main}}"
}

_runtime_freshness_remote() {
  printf '%s\n' "${ORCH_RUNTIME_FRESHNESS_REMOTE:-origin}"
}

_runtime_freshness_sidecar_globs() {
  if [[ -n "${ORCH_RUNTIME_FRESHNESS_SIDECAR_GLOBS:-}" ]]; then
    printf '%s\n' "$ORCH_RUNTIME_FRESHNESS_SIDECAR_GLOBS" | tr ':' '\n'
    return 0
  fi
  printf '%s\n' "${DEFAULT_SIDECAR_GLOBS[@]}"
}

# Match a single relative path against the sidecar glob list. Returns 0
# when the path is recognized as a sidecar (and therefore safe to ignore
# on freshness checks), 1 otherwise. Pure shell — no fnmatch dependency.
runtime_freshness_path_is_sidecar() {
  local rel=${1:?usage: runtime_freshness_path_is_sidecar <relpath>}
  local glob
  while IFS= read -r glob; do
    [[ -n "$glob" ]] || continue
    # shellcheck disable=SC2053 # we want glob matching, not literal compare
    if [[ "$rel" == $glob ]]; then
      return 0
    fi
  done < <(_runtime_freshness_sidecar_globs)
  return 1
}

# Parse `git status --porcelain` output. Echoes two counts on stdout:
#   <tracked-dirty>\t<untracked-non-sidecar>
# Tracked-dirty is anything whose first two characters are NOT `??`.
# Untracked-non-sidecar is `??` lines whose path is NOT in the sidecar
# allowlist. Sidecar untracked files are silently ignored.
runtime_freshness_count_dirt() {
  local porcelain=${1-}
  local tracked=0 untracked_non_sidecar=0
  local line code path_rel
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    code=${line:0:2}
    # Porcelain v1 separator after the 2-char status is a single space.
    path_rel=${line:3}
    # Strip surrounding quotes if present (paths with special chars).
    path_rel=${path_rel#\"}
    path_rel=${path_rel%\"}
    if [[ "$code" == "??" ]]; then
      if runtime_freshness_path_is_sidecar "$path_rel"; then
        continue
      fi
      untracked_non_sidecar=$((untracked_non_sidecar + 1))
    else
      tracked=$((tracked + 1))
    fi
  done <<< "$porcelain"
  printf '%s\t%s\n' "$tracked" "$untracked_non_sidecar"
}

# Echo current HEAD SHA, then ahead/behind counts vs <remote>/<branch>.
# Output:
#   <sha>\t<ahead>\t<behind>
# Returns non-zero (and prints unknown markers) when the rev-list call
# fails (e.g., the remote ref has not been fetched yet).
_runtime_freshness_head_and_counts() {
  local path=$1 remote=$2 branch=$3
  local sha ahead_behind ahead behind
  local timeout_sec=${ORCH_RUNTIME_FRESHNESS_GIT_SEC:-5}
  if ! sha=$(timeout "$timeout_sec" git -C "$path" rev-parse HEAD 2>/dev/null); then
    printf 'unknown\t0\t0\n'
    return 1
  fi
  if ! ahead_behind=$(timeout "$timeout_sec" git -C "$path" rev-list \
        --left-right --count "HEAD...${remote}/${branch}" 2>/dev/null); then
    printf '%s\t0\t0\n' "$sha"
    return 1
  fi
  ahead=${ahead_behind%%$'\t'*}
  behind=${ahead_behind##*$'\t'}
  printf '%s\t%s\t%s\n' "$sha" "${ahead:-0}" "${behind:-0}"
}

# Classify the runtime checkout. Pure (no mutation, no fetch). Output:
#   one of  clean-uptodate | clean-behind | dirty-tracked | ahead-only
#           | diverged | sidecar-only | unknown | not-a-git-repo
# Sidecar-only means: there is no tracked dirt, but there ARE untracked
# files that are NOT in the sidecar allowlist. We treat that as a state
# distinct from clean-uptodate so the audit ledger captures it, and so
# operators who want to enforce a stricter "absolutely no untracked
# anything" policy can branch on the token.
runtime_freshness_classify() {
  local path=${1:-$(_runtime_freshness_default_path)}
  local branch remote porcelain dirt tracked untracked_non_sidecar
  local sha ahead behind hac

  if [[ ! -d "$path/.git" ]]; then
    printf 'not-a-git-repo\n'
    return 0
  fi

  branch=$(_runtime_freshness_default_branch)
  remote=$(_runtime_freshness_remote)

  porcelain=$(timeout "${ORCH_RUNTIME_FRESHNESS_GIT_SEC:-5}" \
              git -C "$path" status --porcelain 2>/dev/null || true)
  dirt=$(runtime_freshness_count_dirt "$porcelain")
  tracked=${dirt%%$'\t'*}
  untracked_non_sidecar=${dirt##*$'\t'}

  hac=$(_runtime_freshness_head_and_counts "$path" "$remote" "$branch") || true
  sha=$(printf '%s' "$hac" | cut -f1)
  ahead=$(printf '%s' "$hac" | cut -f2)
  behind=$(printf '%s' "$hac" | cut -f3)

  if [[ "$sha" == "unknown" ]]; then
    printf 'unknown\n'
    return 0
  fi

  if [[ "${tracked:-0}" -gt 0 ]]; then
    printf 'dirty-tracked\n'
    return 0
  fi

  if [[ "${ahead:-0}" -gt 0 && "${behind:-0}" -gt 0 ]]; then
    printf 'diverged\n'
    return 0
  fi
  if [[ "${ahead:-0}" -gt 0 ]]; then
    printf 'ahead-only\n'
    return 0
  fi
  if [[ "${behind:-0}" -gt 0 ]]; then
    printf 'clean-behind\n'
    return 0
  fi

  if [[ "${untracked_non_sidecar:-0}" -gt 0 ]]; then
    printf 'sidecar-only\n'
    return 0
  fi

  printf 'clean-uptodate\n'
}

# Map a classification token to the action the preflight should take.
runtime_freshness_action() {
  local classification=${1:?usage: runtime_freshness_action <classification>}
  case "$classification" in
    clean-uptodate)  printf 'noop\n' ;;
    clean-behind)    printf 'fast-forward\n' ;;
    sidecar-only)    printf 'noop\n' ;;
    dirty-tracked)   printf 'refuse\n' ;;
    ahead-only)      printf 'refuse\n' ;;
    diverged)        printf 'refuse\n' ;;
    not-a-git-repo)  printf 'refuse\n' ;;
    unknown)         printf 'skip\n' ;;
    *)               printf 'skip\n' ;;
  esac
}

# Map a classification token to a short refusal reason for the audit log.
_runtime_freshness_refusal_code() {
  local classification=${1-}
  case "$classification" in
    dirty-tracked)  printf 'tracked-dirt-blocks-auto-update\n' ;;
    ahead-only)     printf 'local-ahead-of-origin\n' ;;
    diverged)       printf 'local-diverged-from-origin\n' ;;
    not-a-git-repo) printf 'runtime-path-is-not-a-git-repo\n' ;;
    *)              printf 'unspecified\n' ;;
  esac
}

# Map a classification token to an exit code per the docstring contract.
_runtime_freshness_exit_code() {
  local classification=${1-}
  case "$classification" in
    clean-uptodate|clean-behind|sidecar-only) printf '0\n' ;;
    dirty-tracked)                             printf '10\n' ;;
    ahead-only|diverged)                       printf '11\n' ;;
    not-a-git-repo)                            printf '12\n' ;;
    *)                                         printf '0\n' ;;
  esac
}

# Run the fetch step (skipped when ORCH_RUNTIME_FRESHNESS_NO_FETCH=1 or
# the path is not a git repo). Returns 0 on success, 13 on failure (a
# distinct exit code from the classification refusals so callers can
# differentiate "network problem" from "local state problem").
_runtime_freshness_fetch() {
  local path=$1 remote=$2 branch=$3
  case "${ORCH_RUNTIME_FRESHNESS_NO_FETCH:-0}" in
    1|true|yes|on) return 0 ;;
  esac
  [[ -d "$path/.git" ]] || return 0
  local fetch_timeout=${ORCH_RUNTIME_FRESHNESS_FETCH_SEC:-30}
  if timeout "$fetch_timeout" git -C "$path" fetch \
       "$remote" "+refs/heads/${branch}:refs/remotes/${remote}/${branch}" \
       >/dev/null 2>&1; then
    return 0
  fi
  return 13
}

# Emit the audit line via `audit "..."` when that helper is loaded
# (lib/audit_log.sh is the canonical source). Falls back to printf so the
# preflight remains useful even when run by an operator outside the
# audit-loaded context (test fixtures, ad-hoc shells).
_runtime_freshness_audit() {
  local message=$1
  if declare -F audit >/dev/null 2>&1; then
    audit "$message"
  else
    printf 'AUDIT LOG: %s %s\n' \
      "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$message"
  fi
}

# Full preflight + auto-fast-forward + audit emission. See docstring.
runtime_freshness_assert() {
  local path=${1:-$(_runtime_freshness_default_path)}
  local context=${2:-runtime_freshness}
  local branch remote
  branch=$(_runtime_freshness_default_branch)
  remote=$(_runtime_freshness_remote)

  if [[ ! -d "$path/.git" ]]; then
    _runtime_freshness_audit \
      "RUNTIME_FRESHNESS context=${context} action=refuse classification=not-a-git-repo path=${path}"
    return 12
  fi

  if ! _runtime_freshness_fetch "$path" "$remote" "$branch"; then
    _runtime_freshness_audit \
      "RUNTIME_FRESHNESS context=${context} action=refuse classification=fetch-failed path=${path} remote=${remote} branch=${branch}"
    return 13
  fi

  local classification action old_sha new_sha ahead behind hac
  classification=$(runtime_freshness_classify "$path")
  action=$(runtime_freshness_action "$classification")
  hac=$(_runtime_freshness_head_and_counts "$path" "$remote" "$branch") || true
  old_sha=$(printf '%s' "$hac" | cut -f1)
  ahead=$(printf '%s' "$hac" | cut -f2)
  behind=$(printf '%s' "$hac" | cut -f3)
  new_sha="$old_sha"

  case "$action" in
    fast-forward)
      if timeout "${ORCH_RUNTIME_FRESHNESS_GIT_SEC:-5}" \
           git -C "$path" merge --ff-only \
           "${remote}/${branch}" >/dev/null 2>&1; then
        new_sha=$(timeout "${ORCH_RUNTIME_FRESHNESS_GIT_SEC:-5}" \
                  git -C "$path" rev-parse HEAD 2>/dev/null || printf '%s' "$old_sha")
        _runtime_freshness_audit \
          "RUNTIME_FRESHNESS context=${context} action=fast-forwarded classification=${classification} path=${path} old_sha=${old_sha} new_sha=${new_sha} behind=${behind} ahead=${ahead}"
        return 0
      fi
      _runtime_freshness_audit \
        "RUNTIME_FRESHNESS context=${context} action=refuse classification=fast-forward-failed path=${path} old_sha=${old_sha} behind=${behind} ahead=${ahead}"
      return 11
      ;;
    noop)
      _runtime_freshness_audit \
        "RUNTIME_FRESHNESS context=${context} action=noop classification=${classification} path=${path} sha=${old_sha} behind=${behind} ahead=${ahead}"
      return 0
      ;;
    refuse)
      local reason
      reason=$(_runtime_freshness_refusal_code "$classification")
      _runtime_freshness_audit \
        "RUNTIME_FRESHNESS context=${context} action=refuse classification=${classification} reason=${reason} path=${path} sha=${old_sha} behind=${behind} ahead=${ahead}"
      return "$(_runtime_freshness_exit_code "$classification")"
      ;;
    skip|*)
      _runtime_freshness_audit \
        "RUNTIME_FRESHNESS context=${context} action=skip classification=${classification} path=${path}"
      return 0
      ;;
  esac
}

# One-line summary suitable for the orchestrator status report. Pure: no
# mutation, no fetch.
runtime_freshness_summary_line() {
  local path=${1:-$(_runtime_freshness_default_path)}
  local branch remote classification action hac sha ahead behind
  branch=$(_runtime_freshness_default_branch)
  remote=$(_runtime_freshness_remote)
  classification=$(runtime_freshness_classify "$path")
  action=$(runtime_freshness_action "$classification")
  hac=$(_runtime_freshness_head_and_counts "$path" "$remote" "$branch") || true
  sha=$(printf '%s' "$hac" | cut -f1)
  ahead=$(printf '%s' "$hac" | cut -f2)
  behind=$(printf '%s' "$hac" | cut -f3)
  printf 'runtime_sha=%s behind=%s ahead=%s classification=%s action=%s\n' \
    "${sha:-unknown}" "${behind:-0}" "${ahead:-0}" "$classification" "$action"
}
