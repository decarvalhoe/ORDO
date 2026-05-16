#!/usr/bin/env bash
# tests/test_nomos_profile_loading.sh — locks the loading contract for the
# NOMOS profile pair introduced by #681.
#
# The two files under test are:
#   * examples/nomos.config.sh                  — neutral worked example,
#                                                  resolved by `orch_loop.sh
#                                                  nomos` when no override is
#                                                  provided.
#   * profiles/nomos-live.config.example.sh     — non-canonical operator
#                                                  template copied to
#                                                  `/root/.config/ordo/nomos-
#                                                  live.config.sh`.
#
# Both files MUST source cleanly under `set -euo pipefail` from a clean shell
# and MUST define the variables `examples/ordo.config.sh` enforces on every
# loaded profile (PROJECT, GH_REPO, DEFAULT_BRANCH, GH_CONFIG_DIR,
# AGENT_REPO_PREFIX, AGENT_WORKDIR_TEMPLATE, plus a non-empty AGENT_PANES
# array). The live example additionally pins the NOMOS-specific values
# documented in the source ticket: PROJECT="nomos", GH_REPO="RBOKproject/NOMOS",
# DEFAULT_BRANCH="main", USE_WORKTREES=1, an ORCH_WORKTREES_DIR scoped to
# nomos, and an audit log under /var/log/orch.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

ok() {
  printf 'ok - %s\n' "$*"
}

require_file() {
  local path="$1"
  [[ -f "$ROOT/$path" ]] || fail "missing required file: $path"
}

require_file examples/nomos.config.sh
require_file profiles/nomos-live.config.example.sh

# --- bash syntax gates ------------------------------------------------------
# `bash -n` catches stray quoting / heredoc / array typos before any source
# attempt drags partial state into the calling shell.
timeout 10 bash -n "$ROOT/examples/nomos.config.sh" \
  || fail "examples/nomos.config.sh failed bash -n syntax check"
timeout 10 bash -n "$ROOT/profiles/nomos-live.config.example.sh" \
  || fail "profiles/nomos-live.config.example.sh failed bash -n syntax check"

ok "both NOMOS profile files pass bash -n"

# --- helper: source a profile in an isolated subshell and dump the required
#     variables in a parseable form so the parent shell can assert on them
#     without leaking state from the sourced script.
dump_profile() {
  local profile="$1"
  local out
  out=$(
    timeout 15 bash -c '
      set -euo pipefail
      # shellcheck disable=SC1090
      source "$1"
      printf "PROJECT=%s\n" "${PROJECT-}"
      printf "GH_REPO=%s\n" "${GH_REPO-}"
      printf "DEFAULT_BRANCH=%s\n" "${DEFAULT_BRANCH-}"
      printf "GH_CONFIG_DIR=%s\n" "${GH_CONFIG_DIR-}"
      printf "AGENT_REPO_PREFIX=%s\n" "${AGENT_REPO_PREFIX-}"
      printf "AGENT_WORKDIR_TEMPLATE=%s\n" "${AGENT_WORKDIR_TEMPLATE-}"
      printf "AGENT_PANES_LEN=%s\n" "${#AGENT_PANES[@]}"
      printf "AGENT_GH_LOGINS_LEN=%s\n" "${#AGENT_GH_LOGINS[@]}"
      printf "AGENT_GIT_IDENTITIES_LEN=%s\n" "${#AGENT_GIT_IDENTITIES[@]}"
      printf "USE_WORKTREES=%s\n" "${USE_WORKTREES-}"
      printf "ORCH_WORKTREES_DIR=%s\n" "${ORCH_WORKTREES_DIR-}"
      printf "AUDIT_LOG_FILE=%s\n" "${AUDIT_LOG_FILE-}"
    ' _ "$profile"
  ) || fail "sourcing $profile under set -euo pipefail failed"
  printf '%s\n' "$out"
}

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  [[ "$actual" == "$expected" ]] \
    || fail "$label: expected '$expected', got '$actual'"
}

assert_nonempty() {
  local label="$1" value="$2"
  [[ -n "$value" ]] || fail "$label must not be empty"
}

assert_array_min_len() {
  local label="$1" len="$2" min="$3"
  [[ "$len" =~ ^[0-9]+$ ]] || fail "$label length not numeric: '$len'"
  (( len >= min )) || fail "$label has $len entries, need at least $min"
}

read_field() {
  local dump="$1" key="$2"
  printf '%s\n' "$dump" | awk -F= -v k="$key" '$1==k{
    sub("^"k"=","");
    print
    exit
  }'
}

# --- examples/nomos.config.sh: shape only -----------------------------------
example_dump=$(dump_profile "$ROOT/examples/nomos.config.sh")

assert_nonempty PROJECT                "$(read_field "$example_dump" PROJECT)"
assert_nonempty GH_REPO                "$(read_field "$example_dump" GH_REPO)"
assert_nonempty DEFAULT_BRANCH         "$(read_field "$example_dump" DEFAULT_BRANCH)"
assert_nonempty GH_CONFIG_DIR          "$(read_field "$example_dump" GH_CONFIG_DIR)"
assert_nonempty AGENT_REPO_PREFIX      "$(read_field "$example_dump" AGENT_REPO_PREFIX)"
assert_nonempty AGENT_WORKDIR_TEMPLATE "$(read_field "$example_dump" AGENT_WORKDIR_TEMPLATE)"
assert_array_min_len AGENT_PANES \
  "$(read_field "$example_dump" AGENT_PANES_LEN)" 1

ok "examples/nomos.config.sh defines required profile shape"

# --- profiles/nomos-live.config.example.sh: NOMOS-specific contract ---------
live_dump=$(dump_profile "$ROOT/profiles/nomos-live.config.example.sh")

assert_eq PROJECT          "$(read_field "$live_dump" PROJECT)"          "nomos"
assert_eq GH_REPO          "$(read_field "$live_dump" GH_REPO)"          "RBOKproject/NOMOS"
assert_eq DEFAULT_BRANCH   "$(read_field "$live_dump" DEFAULT_BRANCH)"   "main"
assert_eq USE_WORKTREES    "$(read_field "$live_dump" USE_WORKTREES)"    "1"
assert_eq AUDIT_LOG_FILE   "$(read_field "$live_dump" AUDIT_LOG_FILE)"   "/var/log/orch/nomos.log"

assert_nonempty GH_CONFIG_DIR          "$(read_field "$live_dump" GH_CONFIG_DIR)"
assert_nonempty AGENT_REPO_PREFIX      "$(read_field "$live_dump" AGENT_REPO_PREFIX)"
assert_nonempty AGENT_WORKDIR_TEMPLATE "$(read_field "$live_dump" AGENT_WORKDIR_TEMPLATE)"
assert_nonempty ORCH_WORKTREES_DIR     "$(read_field "$live_dump" ORCH_WORKTREES_DIR)"

worktrees_dir="$(read_field "$live_dump" ORCH_WORKTREES_DIR)"
[[ "$worktrees_dir" == */nomos* ]] \
  || fail "ORCH_WORKTREES_DIR must be scoped to nomos, got '$worktrees_dir'"

# fleet-001..fleet-011 reuse from the source ticket's "Proposed action" point 1.
assert_array_min_len AGENT_PANES \
  "$(read_field "$live_dump" AGENT_PANES_LEN)" 11
assert_array_min_len AGENT_GH_LOGINS \
  "$(read_field "$live_dump" AGENT_GH_LOGINS_LEN)" 11
assert_array_min_len AGENT_GIT_IDENTITIES \
  "$(read_field "$live_dump" AGENT_GIT_IDENTITIES_LEN)" 11

ok "profiles/nomos-live.config.example.sh pins NOMOS values from #681"

# --- scope guard: neither file may pin to the dispatch's forbidden file -----
# The dispatch boundaries forbid touching cli/internal/app/app.go. A profile
# that referenced it as a hot spot would risk dragging dispatch attention
# back to that path; refuse here to keep the NOMOS profile self-contained.
for path in examples/nomos.config.sh profiles/nomos-live.config.example.sh; do
  if grep -q 'cli/internal/app/app\.go' "$ROOT/$path"; then
    fail "$path references forbidden file cli/internal/app/app.go"
  fi
done

ok "NOMOS profile pair stays clear of dispatch-forbidden paths"

printf '\n# all NOMOS profile loading checks passed\n'
