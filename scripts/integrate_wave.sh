#!/usr/bin/env bash
# scripts/integrate_wave.sh — fetch agent feature branches, rebase onto
# the default branch, run sanity gates, push, open PR.
#
# Usage: integrate_wave.sh <project_short|config_path> <wave_label> [agent1 agent2 ...]
#
# Surviving log signatures:
#   INTEGRATE start project=<id> wave=<label>
#   INTEGRATE end wave=<label> ok=<n> conflicts=<n> failed=<n> head=<sha>
#
# Behavior:
#   For each agent listed (default: all agents in $AGENTS):
#     1. Detect agent's feature branch (current HEAD if !=DEFAULT_BRANCH).
#     2. If on supervisor flow: fetch into supervisor as agent-<name>/<branch>.
#        else: fetch into the orch's local working repo.
#     3. Create local tracking branch.
#     4. Rebase on DEFAULT_BRANCH.
#     5. On conflict: log + skip + tag for manual review (does NOT auto-resolve).
#     6. Run sanity gates (project-specific via $WAVE_SANITY_CMD).
#     7. Push to shared bare (supervisor mode) OR origin (direct mode).
#     8. Optionally open PR via gh pr create + body template.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/dry_run.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

CFG_ARG=${1:?usage: integrate_wave.sh <project> <wave_label> [agents...] [--dry-run]}
WAVE=${2:?missing wave label}
shift 2
case "$CFG_ARG" in
  wp|realisons-wp)   CFG="$TK/examples/realisons-wp.config.sh" ;;
  nomos)             CFG="$TK/examples/nomos.config.sh" ;;
  rbok)              CFG="$TK/examples/rbok.config.sh" ;;
  42t|42-training)   CFG="$TK/examples/42t.config.sh" ;;
  *)                 CFG="$CFG_ARG" ;;
esac
[ -f "$CFG" ] || { echo "config not found: $CFG" >&2; exit 1; }
source "$CFG"

source "$TK/lib/audit_log.sh"
source "$TK/lib/state_persist.sh"

: "${DEFAULT_BRANCH:=main}" "${AGENT_REPO_PREFIX:?}"

audit "INTEGRATE start project=$PROJECT wave=$WAVE"

# Choose which agents to integrate.
declare -a TARGETS
if [ "$#" -gt 0 ]; then
  TARGETS=("$@")
else
  TARGETS=("${AGENTS[@]}")
fi

# Working repo for integration. Prefer supervisor; fall back to first agent
# clone (rebase-only, no push).
WORK_REPO="${SUPERVISOR_REPO:-${AGENT_REPO_PREFIX}${AGENTS[0]}}"
[ -d "$WORK_REPO/.git" ] || { audit "INTEGRATE ERROR work repo missing: $WORK_REPO"; exit 1; }

# Refresh DEFAULT_BRANCH from origin (or shared bare) into the work repo.
if dry_run_enabled; then
  dry_run_note "git -C $WORK_REPO fetch --quiet origin $DEFAULT_BRANCH"
  dry_run_note "git -C $WORK_REPO fetch --quiet origin"
  dry_run_note "git -C $WORK_REPO fetch origin ${DEFAULT_BRANCH}:${DEFAULT_BRANCH}"
else
  git -C "$WORK_REPO" fetch --quiet origin "$DEFAULT_BRANCH" 2>/dev/null \
    || git -C "$WORK_REPO" fetch --quiet origin 2>/dev/null \
    || true
  git -C "$WORK_REPO" fetch origin "${DEFAULT_BRANCH}:${DEFAULT_BRANCH}" 2>/dev/null || true
fi

ok=0
conflicts=0
failed=0
declare -a OK_BRANCHES

for a in "${TARGETS[@]}"; do
  agent_repo="${AGENT_REPO_PREFIX}${a}"
  if [ ! -d "$agent_repo/.git" ]; then
    audit "INTEGRATE skip $a — repo missing"
    failed=$((failed+1))
    continue
  fi

  branch=$(git -C "$agent_repo" branch --show-current 2>/dev/null) || branch=""
  if [ -z "$branch" ] || [ "$branch" = "$DEFAULT_BRANCH" ]; then
    audit "INTEGRATE skip $a — not on a feature branch (current=$branch)"
    continue
  fi

  # Add agent remote if missing, fetch its branch.
  remote_name="agent-${a}"
  if dry_run_enabled; then
    if ! git -C "$WORK_REPO" remote get-url "$remote_name" >/dev/null 2>&1; then
      dry_run_note "git -C $WORK_REPO remote add $remote_name $agent_repo"
    fi
    dry_run_note "git -C $WORK_REPO fetch $remote_name $branch"
    dry_run_note "git -C $WORK_REPO branch -f $branch ${remote_name}/${branch}"
    dry_run_note "git -C $WORK_REPO checkout $branch"
    dry_run_note "git -C $WORK_REPO rebase $DEFAULT_BRANCH"
    audit "INTEGRATE rebase OK $a:$branch on $DEFAULT_BRANCH"
    OK_BRANCHES+=("$a:$branch")
    ok=$((ok+1))
  else
    if ! git -C "$WORK_REPO" remote get-url "$remote_name" >/dev/null 2>&1; then
      git -C "$WORK_REPO" remote add "$remote_name" "$agent_repo"
    fi
    git -C "$WORK_REPO" fetch "$remote_name" "$branch" 2>/dev/null || {
      audit "INTEGRATE FAIL $a:$branch — fetch error"
      failed=$((failed+1))
      continue
    }

    # Create or fast-forward local tracking branch.
    git -C "$WORK_REPO" branch -f "$branch" "${remote_name}/${branch}" 2>/dev/null || true
    git -C "$WORK_REPO" checkout "$branch" 2>/dev/null

    # Rebase on DEFAULT_BRANCH.
    if git -C "$WORK_REPO" rebase "$DEFAULT_BRANCH" 2>&1 | tail -5; then
      audit "INTEGRATE rebase OK $a:$branch on $DEFAULT_BRANCH"
      OK_BRANCHES+=("$a:$branch")
      ok=$((ok+1))
    else
      git -C "$WORK_REPO" rebase --abort 2>/dev/null || true
      audit "INTEGRATE CONFLICT $a:$branch — manual rebase needed"
      conflicts=$((conflicts+1))
    fi
  fi
done

# Optional sanity gate (project-defined). When $WAVE_SANITY_CMD is set,
# run it from $WORK_REPO; failure marks the wave as needing manual review
# but does not undo the rebases.
if [ -n "${WAVE_SANITY_CMD:-}" ]; then
  audit "INTEGRATE sanity start cmd=$WAVE_SANITY_CMD"
  if dry_run_enabled; then
    dry_run_note "cd $WORK_REPO && bash -c $WAVE_SANITY_CMD"
  else
    ( cd "$WORK_REPO" && bash -c "$WAVE_SANITY_CMD" ) >&2 || {
      audit "INTEGRATE sanity FAIL cmd=$WAVE_SANITY_CMD"
      failed=$((failed+1))
    }
  fi
fi

head=$(git -C "$WORK_REPO" rev-parse --short "$DEFAULT_BRANCH" 2>/dev/null || echo "?")
audit "INTEGRATE end wave=$WAVE ok=$ok conflicts=$conflicts failed=$failed head=$head"

# Persist the wave snapshot for the orch state index.
if dry_run_enabled; then
  dry_run_note "write $(state_dir)/wave-${WAVE}.yaml"
else
  {
    printf 'wave: %s\n' "$WAVE"
    printf 'project: %s\n' "$PROJECT"
    printf 'default_branch: %s\n' "$DEFAULT_BRANCH"
    printf 'head: %s\n' "$head"
    printf 'ok: %s\n' "$ok"
    printf 'conflicts: %s\n' "$conflicts"
    printf 'failed: %s\n' "$failed"
    printf 'branches:\n'
    for b in "${OK_BRANCHES[@]}"; do printf '  - %s\n' "$b"; done
  } > "$(state_dir)/wave-${WAVE}.yaml"
fi

# Exit code: 0 if at least one branch integrated cleanly and no failures;
# else 1 so the caller (cycle.sh) can decide whether to halt.
if [ "$failed" -eq 0 ] && [ "$conflicts" -eq 0 ] && [ "$ok" -ge 1 ]; then
  exit 0
fi
exit 1
