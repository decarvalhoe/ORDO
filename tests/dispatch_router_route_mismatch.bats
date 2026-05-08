#!/usr/bin/env bats
# tests/dispatch_router_route_mismatch.bats — coverage for ORDO #376.
#
# `lib/dispatch_router.sh` MUST refuse a dispatch before the staged
# brief is written and before tmux send-keys runs when any of the
# routing surfaces (pane agent, filename slug, body agent token,
# pinned cwd, workdir git identity) disagree about which agent the
# brief is addressed to.
#
# The fixtures below model the live Wave-23 incident referenced in the
# issue: a brief named `dispatch-rbok-cursor-301.md` whose body is
# addressed to `ordo agent: copilot` and pins
# `/root/.../repos/ordo/copilot` was sent to `rbok-cursor:0.0`. The
# guard catches each routing surface in isolation so a single drift
# does not slip through with the others.

load './helpers.bash'

setup() {
  setup_orch_test

  toolkit_file lib/dispatch_router.sh >/dev/null
  toolkit_file lib/audit_log.sh >/dev/null
  toolkit_file lib/log_bounds.sh >/dev/null
  toolkit_file lib/config_check.sh >/dev/null

  # Source order matters: audit_log.sh requires PROJECT/ORCH_LOG_DIR set
  # in the helper. dispatch_router.sh has no other dependencies.
  # shellcheck disable=SC1090,SC1091
  source "$SANITIZED_TK/lib/audit_log.sh"
  # shellcheck disable=SC1090,SC1091
  source "$SANITIZED_TK/lib/dispatch_router.sh"

  # Stub `agent_target` so the guard can compute an expected pane
  # without sourcing the full inventory stack.
  agent_target() {
    printf '%s:0.0\n' "$1"
  }
  export -f agent_target

  WORK_BASE="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK_BASE/rbok-cursor" "$WORK_BASE/copilot" "$BATS_TEST_TMPDIR/prompts"

  # Real git config so the workdir-side identity check has a value to
  # compare against (it stays best-effort: when no expected_login
  # resolves, the guard records the workdir identity but skips the
  # comparison).
  git -C "$WORK_BASE/rbok-cursor" init -q
  git -C "$WORK_BASE/rbok-cursor" config user.name "RBOKCLIcursor"
  git -C "$WORK_BASE/rbok-cursor" config user.email "rbok-cursor@example.invalid"
  git -C "$WORK_BASE/copilot" init -q
  git -C "$WORK_BASE/copilot" config user.name "RBOKCLIcopilot"
  git -C "$WORK_BASE/copilot" config user.email "copilot@example.invalid"
}

write_canonical_brief() {
  # write_canonical_brief <path> <agent> <repo>
  local path=$1 agent=$2 repo=$3
  cat > "$path" <<EOF
# Dispatch — ordo agent: ${agent}
# P0 issue #301 → branch \`fix/301-something\`

## Objectif

Implementer la fix pour ORDO issue #301.

## Regles

- Cwd: \`cd ${repo}\` AVANT, \`pwd\` post-cd

## Format de sortie attendu
## Tools / sources autorises
## Boundaries / interdictions
## Definition of Done verifiable
## Preuves attendues
EOF
}

# Run the guard in-shell so callers can inspect the side-channel
# DISPATCH_ROUTER_* state. `bats run` would launch a subshell and the
# variables would be cleared by the time the assertions run.
assert_router() {
  # assert_router <expected-status> <args...>
  local expected=$1
  shift
  local rc=0
  local stderr_file
  stderr_file="$BATS_TEST_TMPDIR/router.stderr.$$"
  : > "$stderr_file"
  dispatch_router_assert_consistency "$@" 2>"$stderr_file" || rc=$?
  ROUTER_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
  [ "$rc" -eq "$expected" ] || {
    printf 'expected status=%s got=%s args=%s stderr=%s\n' \
      "$expected" "$rc" "$*" "$ROUTER_STDERR" >&2
    return 1
  }
}

@test "valid dispatch passes the routing-surface guard" {
  prompt="$BATS_TEST_TMPDIR/prompts/dispatch-rbok-cursor-301.md"
  write_canonical_brief "$prompt" "rbok-cursor" "$WORK_BASE/rbok-cursor"

  assert_router 0 \
    rbok-cursor 301 "rbok-cursor:0.0" "$prompt" "$WORK_BASE/rbok-cursor"

  # The audit log must record a positive ROUTE_OK line so portfolio
  # dashboards can prove the surfaces matched.
  log="$ORCH_LOG_DIR/$PROJECT.log"
  [ -s "$log" ]
  grep -q 'DISPATCH ROUTE_OK agent=rbok-cursor ticket=#301' "$log"
}

@test "AC#376-1 cross-agent filename + body fails before write/send" {
  # Wave-23 fingerprint: filename names rbok-cursor, body addresses
  # copilot. Before this guard the brief reached the rbok-cursor pane
  # and only the worker-side identity check refused the work.
  prompt="$BATS_TEST_TMPDIR/prompts/dispatch-rbok-cursor-301.md"
  write_canonical_brief "$prompt" "copilot" "$WORK_BASE/copilot"

  assert_router 1 \
    rbok-cursor 301 "rbok-cursor:0.0" "$prompt" "$WORK_BASE/rbok-cursor"

  # The dispatcher's intended agent is rbok-cursor: filename agent
  # parses to rbok-cursor and matches, but body agent and pinned cwd
  # both name copilot. Both surfaces must surface in the audit line so
  # the operator can re-route the brief without guessing which field
  # drifted.
  [ "${DISPATCH_ROUTER_FILENAME_AGENT}" = "rbok-cursor" ]
  [ "${DISPATCH_ROUTER_BODY_AGENT}" = "copilot" ]
  [[ "${DISPATCH_ROUTER_BODY_CWD}" == */copilot ]]
  [[ "${DISPATCH_ROUTER_FIELDS}" == *"body_agent"* ]]
  [[ "${DISPATCH_ROUTER_FIELDS}" == *"pinned_cwd"* ]]
  [[ "${ROUTER_STDERR}" == *"DISPATCH_ROUTE_MISMATCH"* ]]
  [[ "${ROUTER_STDERR}" == *"mismatched_fields="* ]]

  log="$ORCH_LOG_DIR/$PROJECT.log"
  grep -q 'DISPATCH ROUTE_MISMATCH agent=rbok-cursor' "$log"
  grep -q 'reason=route_mismatch_refused' "$log"
}

@test "AC#376-2 mismatched cwd alone fails before write/send" {
  # Filename and body header both name rbok-cursor but the operator
  # accidentally pinned the copilot workdir in the Cwd line. The brief
  # would still rebase under the wrong worktree if dispatched.
  prompt="$BATS_TEST_TMPDIR/prompts/dispatch-rbok-cursor-302.md"
  write_canonical_brief "$prompt" "rbok-cursor" "$WORK_BASE/copilot"

  assert_router 1 \
    rbok-cursor 302 "rbok-cursor:0.0" "$prompt" "$WORK_BASE/rbok-cursor"
  [ "${DISPATCH_ROUTER_BODY_AGENT}" = "rbok-cursor" ]
  [[ "${DISPATCH_ROUTER_BODY_CWD}" == */copilot ]]
  [[ "${DISPATCH_ROUTER_FIELDS}" == *"pinned_cwd"* ]]
  [[ "${DISPATCH_ROUTER_FIELDS}" != *"filename_agent"* ]]
  [[ "${DISPATCH_ROUTER_FIELDS}" != *"body_agent"* ]]
}

@test "AC#376-3 valid dispatch records a context proof and audit line" {
  # AC mirror of the issue's "valid dispatch still succeeds and
  # records the same context proof as today" — equivalent here is
  # "guard logs ROUTE_OK with all four parsed surfaces so dashboards
  # can prove the dispatch was checked, not skipped".
  prompt="$BATS_TEST_TMPDIR/prompts/dispatch-rbok-cursor-303.md"
  write_canonical_brief "$prompt" "rbok-cursor" "$WORK_BASE/rbok-cursor"

  assert_router 0 \
    rbok-cursor 303 "rbok-cursor:0.0" "$prompt" "$WORK_BASE/rbok-cursor"

  log="$ORCH_LOG_DIR/$PROJECT.log"
  grep -q 'filename_agent=rbok-cursor' "$log"
  grep -q 'body_agent=rbok-cursor' "$log"
  grep -q "body_cwd=$WORK_BASE/rbok-cursor" "$log"
}

@test "filename slug agent disagrees with intended pane" {
  # Filename pretends to address rbok-cursor but the dispatcher
  # intended copilot. The guard should refuse because the operator
  # would re-issue under the wrong slug.
  prompt="$BATS_TEST_TMPDIR/prompts/dispatch-rbok-cursor-304.md"
  write_canonical_brief "$prompt" "copilot" "$WORK_BASE/copilot"

  assert_router 1 \
    copilot 304 "copilot:0.0" "$prompt" "$WORK_BASE/copilot"
  [ "${DISPATCH_ROUTER_FILENAME_AGENT}" = "rbok-cursor" ]
  [[ "${DISPATCH_ROUTER_FIELDS}" == *"filename_agent"* ]]
}

@test "non-canonical filename is treated as no-claim, body still checked" {
  # Operator ad-hoc prompts (like the live brief at
  # /tmp/dispatch-rbok-cursor-376.md when reused across agents) often
  # name files without the dispatch- prefix. The guard must not refuse
  # purely on a missing filename slug, but must still enforce the body
  # surface.
  prompt="$BATS_TEST_TMPDIR/prompts/operator-brief.md"
  write_canonical_brief "$prompt" "copilot" "$WORK_BASE/copilot"

  assert_router 1 \
    rbok-cursor 305 "rbok-cursor:0.0" "$prompt" "$WORK_BASE/rbok-cursor"
  [ -z "${DISPATCH_ROUTER_FILENAME_AGENT}" ]
  [[ "${DISPATCH_ROUTER_FIELDS}" == *"body_agent"* ]]
  [[ "${DISPATCH_ROUTER_FIELDS}" == *"pinned_cwd"* ]]
}

@test "missing prompt file refuses with a structured signal" {
  assert_router 1 \
    rbok-cursor 306 "rbok-cursor:0.0" \
    "$BATS_TEST_TMPDIR/prompts/does-not-exist.md" \
    "$WORK_BASE/rbok-cursor"
  [ "${DISPATCH_ROUTER_REASON}" = "prompt_missing" ]
  [[ "${ROUTER_STDERR}" == *"prompt_missing"* ]]
}

@test "PR-op style brief (Agent label) is honored as body_agent surface" {
  # PR-op templates use `- Agent label: \`X\`` instead of an H1 agent
  # token. The guard must recognise that surface so PR-op briefs are
  # not silently exempted from the routing check.
  prompt="$BATS_TEST_TMPDIR/prompts/dispatch-rbok-cursor-307.md"
  cat > "$prompt" <<EOF
# Dispatch — PR ops: fix CI

- pr-ops-task: fix_ci

## Context

- PR: https://example.invalid/pr/12
- Agent label: \`copilot\` (worktree: \`$WORK_BASE/copilot\`)
EOF

  assert_router 1 \
    rbok-cursor 307 "rbok-cursor:0.0" "$prompt" "$WORK_BASE/rbok-cursor"
  [ "${DISPATCH_ROUTER_BODY_AGENT}" = "copilot" ]
  [[ "${DISPATCH_ROUTER_FIELDS}" == *"body_agent"* ]]
}

@test "expected_login mismatch with workdir identity refuses" {
  # When the orchestrator can resolve an expected gh login for the
  # agent and the workdir's git user.name names a different agent, the
  # routing guard treats it as a routing surface drift. We stub the
  # resolver inline so the guard takes the strict branch.
  resolve_agent_github_login() {
    case "$1" in
      rbok-cursor) printf 'cursor\n' ;;
      copilot)     printf 'copilot\n' ;;
    esac
  }
  export -f resolve_agent_github_login

  prompt="$BATS_TEST_TMPDIR/prompts/dispatch-rbok-cursor-308.md"
  write_canonical_brief "$prompt" "rbok-cursor" "$WORK_BASE/rbok-cursor"
  # Workdir's user.name claims copilot — the routing fingerprint of the
  # Wave-23 leak: brief and filename look fine, but the workdir is
  # already claimed by the wrong agent.
  git -C "$WORK_BASE/rbok-cursor" config user.name "RBOKCLIcopilot"

  assert_router 1 \
    rbok-cursor 308 "rbok-cursor:0.0" "$prompt" "$WORK_BASE/rbok-cursor"
  [ "${DISPATCH_ROUTER_WORKDIR_IDENTITY}" = "RBOKCLIcopilot" ]
  [ "${DISPATCH_ROUTER_EXPECTED_LOGIN}" = "cursor" ]
  [[ "${DISPATCH_ROUTER_FIELDS}" == *"workdir_identity"* ]]
}

@test "expected_login substring match accepts RBOKCLI<login> style" {
  # The fleet's standard convention is `RBOKCLI<login>` for
  # git user.name vs. <login> for the gh login. The guard must accept
  # the substring relation so day-to-day dispatches do not all refuse.
  resolve_agent_github_login() {
    case "$1" in
      rbok-cursor) printf 'cursor\n' ;;
    esac
  }
  export -f resolve_agent_github_login

  prompt="$BATS_TEST_TMPDIR/prompts/dispatch-rbok-cursor-309.md"
  write_canonical_brief "$prompt" "rbok-cursor" "$WORK_BASE/rbok-cursor"

  assert_router 0 \
    rbok-cursor 309 "rbok-cursor:0.0" "$prompt" "$WORK_BASE/rbok-cursor"
  [ "${DISPATCH_ROUTER_WORKDIR_IDENTITY}" = "RBOKCLIcursor" ]
  [ "${DISPATCH_ROUTER_EXPECTED_LOGIN}" = "cursor" ]
}
