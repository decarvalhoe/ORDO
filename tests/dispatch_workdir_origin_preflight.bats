#!/usr/bin/env bats
# tests/dispatch_workdir_origin_preflight.bats — coverage for ORDO #683.
#
# `lib/dispatch_workdir_preflight.sh` MUST refuse a direct (non-portfolio)
# dispatch when the agent's pinned workdir is a clone of a different project
# than the loaded project's canonical clone URL. Without this guard, an
# operator dispatching e.g. an `rbok` or `realisons-wordpress` ticket into a
# fleet slot whose `AGENT_WORKDIR` is an `RBOKproject/ORDO` clone would
# silently respawn the pane in a wrong-remote workdir and leave the worker to
# refuse the brief via the post-dispatch context-mismatch guard.
#
# The fixtures below mirror the live cluster cause documented in #683:
#   * fleet-006 → rbok#3681: workdir is an ORDO clone, project=rbok
#   * fleet-001 → realisons-wordpress#645: same shape
# The guard runs before worktree creation and tmux respawn, so a refusal
# blocks the brief from reaching the wrong pane in the first place.

load './helpers.bash'

setup() {
  setup_orch_test

  toolkit_file lib/dispatch_workdir_preflight.sh >/dev/null
  toolkit_file lib/portfolio_config.sh >/dev/null
  toolkit_file lib/config_resolver.sh >/dev/null
  toolkit_file lib/audit_log.sh >/dev/null
  toolkit_file lib/log_bounds.sh >/dev/null
  toolkit_file lib/config_check.sh >/dev/null

  # Source order matters: portfolio_config.sh provides the canonical-URL
  # helpers the preflight calls; audit_log.sh provides `audit`.
  # shellcheck disable=SC1090,SC1091
  source "$SANITIZED_TK/lib/audit_log.sh"
  # shellcheck disable=SC1090,SC1091
  source "$SANITIZED_TK/lib/portfolio_config.sh"
  # shellcheck disable=SC1090,SC1091
  source "$SANITIZED_TK/lib/dispatch_workdir_preflight.sh"

  WORK_BASE="$BATS_TEST_TMPDIR/clones"
  mkdir -p "$WORK_BASE/ordo-clone" "$WORK_BASE/rbok-clone"

  # Initialise two clones with distinct origin URLs that mirror the live
  # incident: an ORDO clone (the wrong slot for an RBOK dispatch) and an
  # RBOK clone (the right slot).
  git -C "$WORK_BASE/ordo-clone" init -q
  git -C "$WORK_BASE/ordo-clone" remote add origin \
    https://github.com/RBOKproject/ORDO.git
  git -C "$WORK_BASE/rbok-clone" init -q
  git -C "$WORK_BASE/rbok-clone" remote add origin \
    https://github.com/RBOKproject/RBOK.git

  # Reset guard mode to enforce so prior tests' `off`/`warn` overrides do
  # not bleed across files in the same bats run.
  unset ORCH_DISPATCH_WORKDIR_ORIGIN_GUARD
}

# Run the preflight in-shell so callers can inspect the side-channel
# DISPATCH_WORKDIR_ORIGIN_* state. `bats run` would launch a subshell and
# the variables would be cleared by the time the assertions run.
assert_preflight() {
  # assert_preflight <expected-status> <args...>
  local expected=$1
  shift
  local rc=0
  local stderr_file
  stderr_file="$BATS_TEST_TMPDIR/preflight.stderr.$$"
  : > "$stderr_file"
  dispatch_workdir_origin_preflight "$@" 2>"$stderr_file" || rc=$?
  PREFLIGHT_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
  [ "$rc" -eq "$expected" ] || {
    printf 'expected status=%s got=%s args=%s stderr=%s\n' \
      "$expected" "$rc" "$*" "$PREFLIGHT_STDERR" >&2
    return 1
  }
}

@test "AC#683-1 cross-project workdir refuses dispatch (rbok dispatch into ORDO clone)" {
  # Cluster cause from #683: fleet-006 → rbok#3681, workdir is an ORDO
  # clone. Pre-guard the worker would only refuse post-respawn; the
  # preflight must refuse first so the brief never reaches the pane.
  GH_REPO="RBOKproject/RBOK"

  assert_preflight 4 \
    agent-006 3681 "$WORK_BASE/ordo-clone"

  [ "${DISPATCH_WORKDIR_ORIGIN_RESULT}" = "mismatch" ]
  [ "${DISPATCH_WORKDIR_ORIGIN_GUARD_MODE}" = "enforce" ]
  [[ "${DISPATCH_WORKDIR_ORIGIN_CANONICAL}" == *"RBOK"* ]]
  [[ "${DISPATCH_WORKDIR_ORIGIN_ACTUAL}" == *"ORDO"* ]]
  [[ "${PREFLIGHT_STDERR}" == *"cross-project workdir mismatch"* ]]
  [[ "${PREFLIGHT_STDERR}" == *"agent-006"* ]]
  [[ "${PREFLIGHT_STDERR}" == *"remediation:"* ]]

  log="$ORCH_LOG_DIR/$PROJECT.log"
  [ -s "$log" ]
  grep -q 'DISPATCH REFUSED reason=workdir_origin_mismatch agent=agent-006' "$log"
  grep -q 'mode=enforce' "$log"
}

@test "matching workdir origin allows dispatch (rbok dispatch into rbok clone)" {
  # Healthy path: the slot is provisioned with the right project's clone.
  # The guard records a positive `ok` audit line so dashboards can prove
  # the surface was checked, not skipped.
  GH_REPO="RBOKproject/RBOK"

  assert_preflight 0 \
    agent-005 3712 "$WORK_BASE/rbok-clone"

  [ "${DISPATCH_WORKDIR_ORIGIN_RESULT}" = "match" ]
  [ "${DISPATCH_WORKDIR_ORIGIN_GUARD_MODE}" = "enforce" ]

  log="$ORCH_LOG_DIR/$PROJECT.log"
  grep -q 'DISPATCH WORKDIR_ORIGIN_GUARD ok agent=agent-005 ticket=#3712' "$log"
}

@test "ordo dispatch into ordo clone allows dispatch (no false positive)" {
  # Default ORDO dispatches today land on slots whose AGENT_WORKDIR is an
  # ORDO clone. The guard MUST NOT regress that path.
  GH_REPO="RBOKproject/ORDO"

  assert_preflight 0 \
    agent-010 683 "$WORK_BASE/ordo-clone"

  [ "${DISPATCH_WORKDIR_ORIGIN_RESULT}" = "match" ]
}

@test "ssh- vs https-form origin is canonicalised (no false positive)" {
  # Many fleet clones were initially set up via SSH (`git@github.com:.../`),
  # while the canonical URL derived from GH_REPO is HTTPS. The guard must
  # treat the two forms as equivalent so existing slots do not all start
  # refusing on day one of enforcement.
  GH_REPO="RBOKproject/ORDO"
  git -C "$WORK_BASE/ordo-clone" remote set-url origin \
    git@github.com:RBOKproject/ORDO.git

  assert_preflight 0 \
    agent-010 683 "$WORK_BASE/ordo-clone"

  [ "${DISPATCH_WORKDIR_ORIGIN_RESULT}" = "match" ]
}

@test "warn mode records mismatch but does not refuse" {
  # Roll-out switch: operators can run audit-only first to find affected
  # slots before flipping to enforce.
  GH_REPO="RBOKproject/RBOK"
  ORCH_DISPATCH_WORKDIR_ORIGIN_GUARD=warn

  assert_preflight 0 \
    agent-006 3681 "$WORK_BASE/ordo-clone"

  [ "${DISPATCH_WORKDIR_ORIGIN_RESULT}" = "mismatch" ]
  [ "${DISPATCH_WORKDIR_ORIGIN_GUARD_MODE}" = "warn" ]
  [[ "${PREFLIGHT_STDERR}" == *"DISPATCH_WORKDIR_ORIGIN_GUARD warn"* ]]

  log="$ORCH_LOG_DIR/$PROJECT.log"
  grep -q 'DISPATCH WORKDIR_ORIGIN_GUARD warn agent=agent-006' "$log"
  ! grep -q 'DISPATCH REFUSED reason=workdir_origin_mismatch' "$log"
}

@test "off mode skips the check entirely (audit records skipped)" {
  GH_REPO="RBOKproject/RBOK"
  ORCH_DISPATCH_WORKDIR_ORIGIN_GUARD=off

  assert_preflight 0 \
    agent-006 3681 "$WORK_BASE/ordo-clone"

  [ "${DISPATCH_WORKDIR_ORIGIN_RESULT}" = "skipped" ]
  [ "${DISPATCH_WORKDIR_ORIGIN_GUARD_MODE}" = "off" ]

  log="$ORCH_LOG_DIR/$PROJECT.log"
  grep -q 'DISPATCH WORKDIR_ORIGIN_GUARD skipped agent=agent-006' "$log"
}

@test "missing canonical URL is a no-op (no GH_REPO configured)" {
  # Some legacy profiles do not set GH_REPO/REPO_URL/GIT_REMOTE_URL. The
  # guard cannot derive a canonical clone URL without them, so it must
  # pass without refusing — operators see no behavior change until they
  # populate the canonical surface.
  unset GH_REPO REPO_URL GIT_REMOTE_URL

  assert_preflight 0 \
    agent-010 683 "$WORK_BASE/ordo-clone"

  [ "${DISPATCH_WORKDIR_ORIGIN_RESULT}" = "no_canonical" ]
  [ -z "${DISPATCH_WORKDIR_ORIGIN_CANONICAL}" ]
}

@test "non-git workdir is a no-op (worktree_create will provision)" {
  # The slot path may not yet contain a `.git` (fresh provisioning, lazy
  # clone, etc.). The guard must defer to the downstream `worktree_create`
  # / operator-driven provisioning, not refuse on a not-yet-cloned slot.
  GH_REPO="RBOKproject/RBOK"

  assert_preflight 0 \
    agent-fresh 3681 "$BATS_TEST_TMPDIR/clones/not-yet-cloned"

  [ "${DISPATCH_WORKDIR_ORIGIN_RESULT}" = "workdir_missing" ]
}

@test "AC#702 worktree (.git is a gitlink file) is no longer workdir_missing" {
  # Cluster cause from #702: fleet-011 is a `git worktree add` of
  # `/root/repos/ORDO-orchestrator`, so its `.git` is a gitlink file, not a
  # directory. The pre-fix `-d "$workdir/.git"` test silently classified
  # every worktree-shaped slot as `workdir_missing`, making fleet capacity
  # invisible. The guard must accept both clone shapes.
  #
  # Acceptance criterion #702.1 (verbatim): "A worktree at <workdir> with
  # .git as a gitlink file passes dispatch_workdir_origin_preflight
  # (no longer classified as workdir_missing)."
  #
  # Note: the downstream `portfolio_workdir_origin_url` in
  # `lib/portfolio_config.sh` has its own `-d` guard, so the result settles
  # at `no_origin` rather than `match` — that file is out of scope for
  # this ticket and is captured as opportunity_finding in the dispatch
  # report.
  GH_REPO="RBOKproject/ORDO"

  git -C "$WORK_BASE/ordo-clone" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m initial
  git -C "$WORK_BASE/ordo-clone" worktree add -q \
    "$WORK_BASE/ordo-worktree" -b worktree-702

  # Sanity: the worktree's `.git` is a regular file (gitlink), not a dir.
  [ -f "$WORK_BASE/ordo-worktree/.git" ]
  [ ! -d "$WORK_BASE/ordo-worktree/.git" ]

  assert_preflight 0 \
    agent-011 696 "$WORK_BASE/ordo-worktree"

  [ "${DISPATCH_WORKDIR_ORIGIN_RESULT}" != "workdir_missing" ]
  [ "${DISPATCH_WORKDIR_ORIGIN_GUARD_MODE}" = "enforce" ]

  log="$ORCH_LOG_DIR/$PROJECT.log"
  [ -s "$log" ]
  ! grep -q 'DISPATCH WORKDIR_ORIGIN_GUARD workdir_missing agent=agent-011' "$log"
}

@test "git workdir without origin remote is a no-op (defers to downstream guards)" {
  # Synthetic test fixtures sometimes `git init` a workdir without
  # configuring an `origin` remote. Production fleet slots are always
  # cloned (so they always have origin), so a missing origin is an
  # unknown — not a mismatch. The guard must defer rather than refuse,
  # otherwise existing test_dispatch_ticket fixtures whose workdir was
  # `git init`-ed without a remote would all start refusing.
  GH_REPO="RBOKproject/RBOK"
  mkdir -p "$WORK_BASE/no-origin"
  git -C "$WORK_BASE/no-origin" init -q

  assert_preflight 0 \
    agent-fresh 3681 "$WORK_BASE/no-origin"

  [ "${DISPATCH_WORKDIR_ORIGIN_RESULT}" = "no_origin" ]
}
