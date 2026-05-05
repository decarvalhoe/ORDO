# Worktree migration

`I1` adds optional per-ticket git worktrees for agent execution. The goal is to
keep each dispatch on its own branch-scoped filesystem path without changing
default behavior for existing fleets.

## What changes

With `USE_WORKTREES=1`:

- `dispatch_ticket.sh` creates a worktree under
  `${ORCH_WORKTREES_DIR}/${agent}/feat-issue-<ticket>`
- the agent pane is respawned in that path before the dispatch prompt is sent
- `assignments.json` stores the effective `workdir`
- `recover.sh` recreates panes in the recorded worktree
- `integrate_wave.sh` reads the active workdir from assignment state when
  available
- `orch_loop.sh` prunes stale, unassigned worktrees on boot

With the flag unset or `0`, behavior stays on the existing per-agent repo path
from `AGENT_WORKDIR_TEMPLATE`.

## Rollout

1. Leave the default behavior in place.

```bash
export USE_WORKTREES=0
```

2. Pick a root directory for per-ticket worktrees.

```bash
export ORCH_WORKTREES_DIR="/root/repos/orch-worktrees"
```

3. Enable the feature for one project first.

```bash
export USE_WORKTREES=1
source examples/rbok.config.sh
```

4. Dispatch one ticket and confirm:

```bash
bash scripts/dispatch_ticket.sh rbok claude 1234 /tmp/dispatch-claude-1234.md
git -C "$(printf "$AGENT_WORKDIR_TEMPLATE" claude)" worktree list
cat "$(state_dir)/assignments.json"
```

5. Verify the pane points at the worktree path and the branch looks like
   `feat/issue-1234`.

## Rollback

1. Stop creating new worktrees.

```bash
export USE_WORKTREES=0
```

2. Let active tickets finish or re-dispatch them onto the base repo path.

3. Remove stale worktrees.

```bash
source examples/rbok.config.sh
source lib/audit_log.sh
source lib/state_persist.sh
source lib/worktree_helpers.sh
worktree_cleanup_stale
```

4. If you need to force-remove a single path:

```bash
source examples/rbok.config.sh
source lib/audit_log.sh
source lib/state_persist.sh
source lib/worktree_helpers.sh
worktree_remove "/root/repos/orch-worktrees/claude/feat-issue-1234"
```

## Notes

- The feature is additive. No config change is required unless you enable it.
- The assignment state becomes the source of truth for the active agent
  workdir.
- Existing prompt files remain staged in `/tmp/dispatch-<agent>-<ticket>.md`.
