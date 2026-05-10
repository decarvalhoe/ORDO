#!/usr/bin/env bats

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  exec bats "$0" "$@"
fi

# Unit + integration coverage for `lib/runtime_freshness.sh` and the
# `scripts/runtime_freshness_preflight.sh` wrapper (#377).
#
# Acceptance scenarios from the issue:
#   - clean-behind runtime is fast-forwarded; old/new SHA logged
#   - dirty-tracked runtime is refused with a structured audit line
#   - ahead-only and diverged runtimes are refused (operator must
#     reconcile by hand — auto-FF must NOT clobber local commits)
#   - sidecar-only untracked files (.claude/, .cursor/, .DS_Store, …)
#     are tolerated and do NOT block the FF
#   - missing remote / not-a-git-repo paths are refused with a
#     dedicated classification token
#
# All tests use `ORCH_RUNTIME_FRESHNESS_NO_FETCH=1` and stage `origin/main`
# manually via paired local clones, so the suite is hermetic and offline.

load './helpers.bash'

setup() {
  setup_orch_test
  toolkit_file lib/log_bounds.sh >/dev/null
  toolkit_file lib/config_check.sh >/dev/null
  AUDIT_LOG_LIB=$(toolkit_file lib/audit_log.sh)
  RUNTIME_FRESHNESS_LIB=$(toolkit_file lib/runtime_freshness.sh)
  PREFLIGHT_SCRIPT=$(toolkit_file scripts/runtime_freshness_preflight.sh)

  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  LOCAL="$BATS_TEST_TMPDIR/local"
  PUSHER="$BATS_TEST_TMPDIR/pusher"

  git init --quiet --bare --initial-branch=main "$REMOTE"
  git -c init.defaultBranch=main clone --quiet "$REMOTE" "$LOCAL" 2>/dev/null
  (
    cd "$LOCAL"
    git config user.email "rt-fresh-test@example.com"
    git config user.name "Runtime Freshness Test"
    printf 'v1\n' > README.md
    git add README.md
    git commit --quiet -m "initial"
    git push --quiet origin main
  )
}

# Run a body inside a sub-shell with the runtime_freshness lib loaded and
# the audit pipeline wired to the per-test log dir. Skips the network
# fetch path so callers can manually stage `origin/main` through paired
# clones.
freshness_eval() {
  local body=${1:?usage: freshness_eval <bash-body>}
  bash -lc "$(orch_env_exports)
    export ORCH_RUNTIME_FRESHNESS_NO_FETCH=1
    unset ORCH_RUNTIME_FRESHNESS_SIDECAR_GLOBS
    source '$AUDIT_LOG_LIB'
    source '$RUNTIME_FRESHNESS_LIB'
    $body
  "
}

# Drive the wrapper script. PROJECT/ORCH_LOG_DIR are exported via
# orch_env_exports so the audit line lands in the per-test log.
preflight_run() {
  bash -lc "$(orch_env_exports)
    export ORCH_RUNTIME_FRESHNESS_NO_FETCH=1
    bash '$PREFLIGHT_SCRIPT' $*"
}

# Push a new commit through a side-clone so $LOCAL's `origin/main` ref
# advances without us calling `git fetch` (which the lib is told to
# skip). Used to set up `clean-behind` and `diverged` scenarios.
advance_remote_one_commit() {
  rm -rf "$PUSHER"
  git clone --quiet "$REMOTE" "$PUSHER" 2>/dev/null
  (
    cd "$PUSHER"
    git config user.email "rt-fresh-pusher@example.com"
    git config user.name "Runtime Freshness Pusher"
    printf 'v2\n' > REMOTE_NEW.md
    git add REMOTE_NEW.md
    git commit --quiet -m "remote-only commit"
    git push --quiet origin main
  )
  # Update $LOCAL's `origin/main` ref + bring the new commit objects in,
  # without going through the configured remote URL (the lib's
  # ORCH_RUNTIME_FRESHNESS_NO_FETCH=1 prevents it from doing this itself).
  # Fetching directly from the bare repo path advances refs/remotes/origin/main
  # AND fills the local object store atomically.
  git -C "$LOCAL" fetch --quiet "$REMOTE" \
    "+refs/heads/main:refs/remotes/origin/main"
}

# --- Sidecar matcher ------------------------------------------------------

@test "path_is_sidecar matches default LLM/IDE/OS scratch paths" {
  for relpath in \
      ".claude/state.json" \
      ".claude" \
      ".cursor/agent.log" \
      ".vscode/settings.json" \
      ".idea/workspace.xml" \
      ".DS_Store" \
      ".envrc.local"; do
    run freshness_eval "runtime_freshness_path_is_sidecar '$relpath'"
    [ "$status" -eq 0 ] || {
      echo "expected '$relpath' to match sidecar globs"
      return 1
    }
  done
}

# #372 — agent runtime locks are sidecar, not product source.
@test "path_is_sidecar matches agent runtime lock files (#372)" {
  for relpath in \
      ".claude/scheduled_tasks.lock" \
      ".claude/sessions/abc.lock" \
      ".cursor/agent.lock"; do
    run freshness_eval "runtime_freshness_path_is_sidecar '$relpath'"
    [ "$status" -eq 0 ] || {
      echo "expected '$relpath' to match sidecar globs (#372)"
      return 1
    }
  done
}

@test "path_is_sidecar refuses ordinary tracked-shaped paths" {
  for relpath in \
      "lib/runtime_freshness.sh" \
      "scripts/orch_loop.sh" \
      "src/feature.py" \
      "README.md"; do
    run freshness_eval "runtime_freshness_path_is_sidecar '$relpath'"
    [ "$status" -ne 0 ] || {
      echo "expected '$relpath' NOT to match sidecar globs"
      return 1
    }
  done
}

@test "ORCH_RUNTIME_FRESHNESS_SIDECAR_GLOBS overrides the default list" {
  run bash -lc "$(orch_env_exports)
    export ORCH_RUNTIME_FRESHNESS_SIDECAR_GLOBS='custom/*:.work'
    source '$RUNTIME_FRESHNESS_LIB'
    runtime_freshness_path_is_sidecar 'custom/foo.txt' && echo CUSTOM_HIT
    runtime_freshness_path_is_sidecar '.claude/state.json' || echo CLAUDE_MISS
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"CUSTOM_HIT"* ]]
  [[ "$output" == *"CLAUDE_MISS"* ]]
}

# --- count_dirt parser ----------------------------------------------------

@test "count_dirt distinguishes tracked dirt from untracked sidecar" {
  run freshness_eval "
    porcelain=\$(printf '%s\n' \\
      ' M lib/runtime_freshness.sh' \\
      '?? .claude/state.json' \\
      '?? new_feature.py')
    runtime_freshness_count_dirt \"\$porcelain\"
  "
  [ "$status" -eq 0 ]
  # 1 tracked-modified, 1 untracked non-sidecar (new_feature.py),
  # 1 untracked sidecar (.claude/state.json) — third column added in #372 so
  # the classifier can split sidecar-only dirtiness from product changes.
  [ "$output" = $'1\t1\t1' ]
}

@test "count_dirt counts agent runtime locks as untracked-sidecar (#372)" {
  run freshness_eval "
    porcelain=\$(printf '%s\n' \\
      '?? .claude/scheduled_tasks.lock' \\
      '?? .claude/sessions/abc.lock')
    runtime_freshness_count_dirt \"\$porcelain\"
  "
  [ "$status" -eq 0 ]
  # 0 tracked, 0 untracked-non-sidecar, 2 untracked-sidecar.
  [ "$output" = $'0\t0\t2' ]
}

# #507 — git may collapse an untracked sidecar directory to `?? .claude/`
# instead of listing `.claude/<file>`. Treat the collapsed directory as the
# same sidecar class as the literal `.claude` entry, but keep ordinary
# collapsed directories visible as non-sidecar dirt.
@test "count_dirt counts collapsed sidecar directories as untracked-sidecar (#507)" {
  run bash -lc "$(orch_env_exports)
    export ORCH_RUNTIME_FRESHNESS_SIDECAR_GLOBS='.claude:.cursor'
    source '$RUNTIME_FRESHNESS_LIB'
    porcelain=\$(printf '%s\n' \\
      '?? .claude/' \\
      '?? .cursor/' \\
      '?? product-cache/')
    runtime_freshness_count_dirt \"\$porcelain\"
  "
  [ "$status" -eq 0 ]
  # 0 tracked, 1 untracked non-sidecar (product-cache/),
  # 2 collapsed untracked sidecar directories.
  [ "$output" = $'0\t1\t2' ]
}

# --- classify matrix ------------------------------------------------------

@test "classify clean-uptodate when local matches remote and no dirt" {
  run freshness_eval "runtime_freshness_classify '$LOCAL'"
  [ "$status" -eq 0 ]
  [ "$output" = "clean-uptodate" ]
}

@test "classify clean-behind when remote moves and working tree is clean" {
  advance_remote_one_commit
  run freshness_eval "runtime_freshness_classify '$LOCAL'"
  [ "$status" -eq 0 ]
  [ "$output" = "clean-behind" ]
}

@test "classify dirty-tracked when a tracked file is modified" {
  printf 'dirty\n' >> "$LOCAL/README.md"
  run freshness_eval "runtime_freshness_classify '$LOCAL'"
  [ "$status" -eq 0 ]
  [ "$output" = "dirty-tracked" ]
}

@test "classify ahead-only when local has unpushed commits" {
  (
    cd "$LOCAL"
    printf 'local-only\n' > LOCAL_ONLY.md
    git add LOCAL_ONLY.md
    git commit --quiet -m "local-only commit"
  )
  run freshness_eval "runtime_freshness_classify '$LOCAL'"
  [ "$status" -eq 0 ]
  [ "$output" = "ahead-only" ]
}

@test "classify diverged when local and remote both have unique commits" {
  advance_remote_one_commit
  (
    cd "$LOCAL"
    printf 'local-only\n' > LOCAL_ONLY.md
    git add LOCAL_ONLY.md
    git commit --quiet -m "local-only commit"
  )
  run freshness_eval "runtime_freshness_classify '$LOCAL'"
  [ "$status" -eq 0 ]
  [ "$output" = "diverged" ]
}

@test "classify sidecar-dirty when local is up-to-date but has untracked sidecars (#372)" {
  mkdir -p "$LOCAL/.claude"
  printf 'state\n' > "$LOCAL/.claude/state.json"
  run freshness_eval "runtime_freshness_classify '$LOCAL'"
  [ "$status" -eq 0 ]
  # Sidecar untracked files surface as `sidecar-dirty` so dispatch readiness
  # reports can distinguish agent runtime metadata from a clean checkout
  # (#372). Action stays `noop`, but the audit ledger captures the state.
  [ "$output" = "sidecar-dirty" ]
}

# #372 — the canonical fixture: a `.claude/scheduled_tasks.lock` file dropped
# into the worktree by the agent runtime must classify as sidecar-dirty, NOT
# dirty-tracked. This is the exact path observed in the incident report.
@test "classify sidecar-dirty when only .claude/scheduled_tasks.lock is present (#372)" {
  mkdir -p "$LOCAL/.claude"
  cat > "$LOCAL/.claude/scheduled_tasks.lock" <<'LOCK_EOF'
{"session_id":"sess-372","pid":12345,"start_ts":"2026-05-08T20:00:00Z","acquired_ts":"2026-05-08T20:00:01Z"}
LOCK_EOF
  run freshness_eval "runtime_freshness_classify '$LOCAL'"
  [ "$status" -eq 0 ]
  [ "$output" = "sidecar-dirty" ]
}

@test "classify scheduled_tasks lock remains sidecar-dirty under custom sidecar globs (#556)" {
  mkdir -p "$LOCAL/.claude"
  cat > "$LOCAL/.claude/scheduled_tasks.lock" <<'LOCK_EOF'
{"session_id":"sess-556","pid":12345,"start_ts":"2026-05-10T04:47:12Z","acquired_ts":"2026-05-10T04:47:13Z"}
LOCK_EOF

  run bash -lc "$(orch_env_exports)
    export ORCH_RUNTIME_FRESHNESS_NO_FETCH=1
    export ORCH_RUNTIME_FRESHNESS_SIDECAR_GLOBS='custom/*:.work'
    source '$AUDIT_LOG_LIB'
    source '$RUNTIME_FRESHNESS_LIB'
    runtime_freshness_classify '$LOCAL'
  "
  [ "$status" -eq 0 ]
  [ "$output" = "sidecar-dirty" ]
}

@test "classify sidecar-only when untracked file is NOT in the sidecar list" {
  printf 'forensic\n' > "$LOCAL/forensic_dump.txt"
  run freshness_eval "runtime_freshness_classify '$LOCAL'"
  [ "$status" -eq 0 ]
  [ "$output" = "sidecar-only" ]
}

@test "classify not-a-git-repo when path has no .git directory" {
  run freshness_eval "runtime_freshness_classify '$BATS_TEST_TMPDIR'"
  [ "$status" -eq 0 ]
  [ "$output" = "not-a-git-repo" ]
}

# --- action mapping -------------------------------------------------------

@test "action mapping covers every classification token" {
  run freshness_eval '
    for tok in clean-uptodate clean-behind sidecar-only sidecar-dirty \
               dirty-tracked ahead-only diverged \
               not-a-git-repo unknown bogus; do
      printf "%s=%s\n" "$tok" "$(runtime_freshness_action "$tok")"
    done
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean-uptodate=noop"* ]]
  [[ "$output" == *"clean-behind=fast-forward"* ]]
  [[ "$output" == *"sidecar-only=noop"* ]]
  [[ "$output" == *"sidecar-dirty=noop"* ]]
  [[ "$output" == *"dirty-tracked=refuse"* ]]
  [[ "$output" == *"ahead-only=refuse"* ]]
  [[ "$output" == *"diverged=refuse"* ]]
  [[ "$output" == *"not-a-git-repo=refuse"* ]]
  [[ "$output" == *"unknown=skip"* ]]
  [[ "$output" == *"bogus=skip"* ]]
}

# --- assert: full preflight ----------------------------------------------

@test "assert fast-forwards a clean-behind runtime and logs old/new SHA" {
  advance_remote_one_commit
  local old_sha new_sha_expected
  old_sha=$(git -C "$LOCAL" rev-parse HEAD)
  new_sha_expected=$(git -C "$LOCAL" rev-parse refs/remotes/origin/main)

  run freshness_eval "runtime_freshness_assert '$LOCAL' 'test_assert'"
  [ "$status" -eq 0 ]

  local moved_to
  moved_to=$(git -C "$LOCAL" rev-parse HEAD)
  [ "$moved_to" = "$new_sha_expected" ]
  [ "$moved_to" != "$old_sha" ]

  grep -q "RUNTIME_FRESHNESS context=test_assert action=fast-forwarded" \
    "$ORCH_LOG_DIR/$PROJECT.log"
  grep -q "old_sha=$old_sha"          "$ORCH_LOG_DIR/$PROJECT.log"
  grep -q "new_sha=$new_sha_expected" "$ORCH_LOG_DIR/$PROJECT.log"
  grep -q "behind=1"                  "$ORCH_LOG_DIR/$PROJECT.log"
}

@test "assert is a noop on clean-uptodate runtime, audit logs the SHA" {
  local sha
  sha=$(git -C "$LOCAL" rev-parse HEAD)
  run freshness_eval "runtime_freshness_assert '$LOCAL' 'test_assert'"
  [ "$status" -eq 0 ]
  grep -q "RUNTIME_FRESHNESS context=test_assert action=noop classification=clean-uptodate" \
    "$ORCH_LOG_DIR/$PROJECT.log"
  grep -q "sha=$sha" "$ORCH_LOG_DIR/$PROJECT.log"
}

@test "assert refuses dirty-tracked with exit 10 and reason field" {
  printf 'dirty\n' >> "$LOCAL/README.md"
  run freshness_eval "runtime_freshness_assert '$LOCAL' 'test_assert'"
  [ "$status" -eq 10 ]
  grep -q "RUNTIME_FRESHNESS context=test_assert action=refuse classification=dirty-tracked" \
    "$ORCH_LOG_DIR/$PROJECT.log"
  grep -q "reason=tracked-dirt-blocks-auto-update" "$ORCH_LOG_DIR/$PROJECT.log"
}

@test "assert refuses ahead-only with exit 11" {
  (
    cd "$LOCAL"
    printf 'local\n' > LOCAL_ONLY.md
    git add LOCAL_ONLY.md
    git commit --quiet -m "local-only commit"
  )
  run freshness_eval "runtime_freshness_assert '$LOCAL' 'test_assert'"
  [ "$status" -eq 11 ]
  grep -q "RUNTIME_FRESHNESS context=test_assert action=refuse classification=ahead-only" \
    "$ORCH_LOG_DIR/$PROJECT.log"
  grep -q "reason=local-ahead-of-origin" "$ORCH_LOG_DIR/$PROJECT.log"
}

@test "assert refuses diverged with exit 11" {
  advance_remote_one_commit
  (
    cd "$LOCAL"
    printf 'local\n' > LOCAL_ONLY.md
    git add LOCAL_ONLY.md
    git commit --quiet -m "local-only commit"
  )
  run freshness_eval "runtime_freshness_assert '$LOCAL' 'test_assert'"
  [ "$status" -eq 11 ]
  grep -q "RUNTIME_FRESHNESS context=test_assert action=refuse classification=diverged" \
    "$ORCH_LOG_DIR/$PROJECT.log"
  grep -q "reason=local-diverged-from-origin" "$ORCH_LOG_DIR/$PROJECT.log"
}

@test "assert refuses not-a-git-repo with exit 12" {
  run freshness_eval "runtime_freshness_assert '$BATS_TEST_TMPDIR' 'test_assert'"
  [ "$status" -eq 12 ]
  grep -q "RUNTIME_FRESHNESS context=test_assert action=refuse classification=not-a-git-repo" \
    "$ORCH_LOG_DIR/$PROJECT.log"
}

@test "assert tolerates sidecar-dirty untracked files with remediation hint (#372)" {
  mkdir -p "$LOCAL/.claude"
  printf 'state\n' > "$LOCAL/.claude/state.json"
  run freshness_eval "runtime_freshness_assert '$LOCAL' 'test_assert'"
  [ "$status" -eq 0 ]
  # The audit line MUST surface sidecar-dirty (not clean-uptodate) and carry
  # the externalize-agent-sidecar-paths remediation hint so an operator
  # reviewing the ledger sees the explicit pointer back to the agent config
  # field that keeps these files OUT of product worktrees (#372).
  grep -q "RUNTIME_FRESHNESS context=test_assert action=noop classification=sidecar-dirty" \
    "$ORCH_LOG_DIR/$PROJECT.log"
  grep -q "remediation=externalize-agent-sidecar-paths" \
    "$ORCH_LOG_DIR/$PROJECT.log"
}

# #372 — the regression fixture: dropping `.claude/scheduled_tasks.lock`
# into a worktree must NOT be mistaken for product source changes (no
# `dirty-tracked`, no refusal), and the lock file must remain untracked
# (never staged, never committed) after the preflight runs.
@test "assert keeps .claude/scheduled_tasks.lock out of product changes (#372)" {
  mkdir -p "$LOCAL/.claude"
  cat > "$LOCAL/.claude/scheduled_tasks.lock" <<'LOCK_EOF'
{"session_id":"sess-372","pid":12345,"start_ts":"2026-05-08T20:00:00Z","acquired_ts":"2026-05-08T20:00:01Z"}
LOCK_EOF

  run freshness_eval "runtime_freshness_assert '$LOCAL' 'test_372'"
  [ "$status" -eq 0 ]
  grep -q "RUNTIME_FRESHNESS context=test_372 action=noop classification=sidecar-dirty" \
    "$ORCH_LOG_DIR/$PROJECT.log"
  ! grep -q "classification=dirty-tracked" "$ORCH_LOG_DIR/$PROJECT.log"

  # The lock file must be untracked (??) — git must not see it as a
  # modification of any tracked product file, and `git ls-files` must not
  # return it (it was never added to the index by the preflight).
  porcelain_status=$(git -C "$LOCAL" status --porcelain -- '.claude/scheduled_tasks.lock')
  [[ "$porcelain_status" =~ ^\?\?[[:space:]] ]]

  tracked_listing=$(git -C "$LOCAL" ls-files -- '.claude/scheduled_tasks.lock')
  [ -z "$tracked_listing" ]

  # Confirm the staged tree is clean — a `git diff --cached` over the lock
  # path must be empty, proving the preflight never committed it.
  staged=$(git -C "$LOCAL" diff --cached --name-only -- '.claude/scheduled_tasks.lock')
  [ -z "$staged" ]
}

@test "assert fast-forwards a clean-behind runtime that has only sidecar untracked" {
  advance_remote_one_commit
  mkdir -p "$LOCAL/.claude"
  printf 'state\n' > "$LOCAL/.claude/state.json"
  run freshness_eval "runtime_freshness_assert '$LOCAL' 'test_assert'"
  [ "$status" -eq 0 ]
  grep -q "RUNTIME_FRESHNESS context=test_assert action=fast-forwarded" \
    "$ORCH_LOG_DIR/$PROJECT.log"
}

# --- summary line ---------------------------------------------------------

@test "summary_line emits the canonical key=value shape" {
  advance_remote_one_commit
  run freshness_eval "runtime_freshness_summary_line '$LOCAL'"
  [ "$status" -eq 0 ]
  [[ "$output" == "runtime_sha="* ]]
  [[ "$output" == *"behind=1"* ]]
  [[ "$output" == *"ahead=0"* ]]
  [[ "$output" == *"classification=clean-behind"* ]]
  [[ "$output" == *"action=fast-forward"* ]]
}

# --- wrapper script -------------------------------------------------------

@test "wrapper script propagates exit 0 on clean-uptodate" {
  run preflight_run "--path '$LOCAL' --no-fetch --context wrapper_test"
  [ "$status" -eq 0 ]
  grep -q "RUNTIME_FRESHNESS context=wrapper_test action=noop classification=clean-uptodate" \
    "$ORCH_LOG_DIR/$PROJECT.log"
}

@test "wrapper script propagates exit 10 on dirty-tracked" {
  printf 'dirty\n' >> "$LOCAL/README.md"
  run preflight_run "--path '$LOCAL' --no-fetch --context wrapper_test"
  [ "$status" -eq 10 ]
  grep -q "classification=dirty-tracked" "$ORCH_LOG_DIR/$PROJECT.log"
}

@test "wrapper script --summary prints the summary and exits 0" {
  run preflight_run "--path '$LOCAL' --no-fetch --summary"
  [ "$status" -eq 0 ]
  [[ "$output" == "runtime_sha="* ]]
  [[ "$output" == *"classification=clean-uptodate"* ]]
}

@test "wrapper script rejects unknown args" {
  run preflight_run "--bogus"
  [ "$status" -eq 2 ]
}

@test "wrapper script accepts positional path" {
  run preflight_run "'$LOCAL' --no-fetch"
  [ "$status" -eq 0 ]
}
