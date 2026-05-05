# orchestrator-toolkit

Multi-project orchestration toolkit for the RBOK / Nomos / Realisons-WP / 42T agent fleets.

## Status

Rebuilt **2026-05-05** after the original copy at this same path was deleted (untracked, no git history). The recovery was partial: only `scripts/ci_watcher_daemon.sh` survived intact in process memory (`/proc/<pid>/fd/255`); the rest of the toolkit was reconstructed from:

- The recovered `ci_watcher_daemon.sh` source (variable list + sourcing chain)
- Audit log signatures preserved in `/var/log/orch/{nomos,rbok}.log` (event format, kvargs schema)
- State directory layout in `~/.local/share/orch-state/{nomos,rbok}/`
- The two surviving daemons (PID 4073362 rbok + 4073488 nomos) running via deleted file descriptor
- Direct hand-roll experience from the FSQ + NGW orchestration cycles (18 PRs shipped without the toolkit)

## Persistence policy — never lose this again

This toolkit MUST be preserved across:

1. **Git tracking** — committed to <https://github.com/RBOKproject/orchestrator-toolkit> (this repo). Every change goes through a PR / commit. Never `rm -rf` an untracked sibling here.
2. **Local immutable snapshots** — read-only `.tar.gz` archives at three independent paths:
   - `/root/repos/RBOK-orchestrator/.local-backups/orchestrator-toolkit-<utc-ts>.tar.gz`
   - `/root/.config/orch-toolkit-snapshots/<utc-ts>.tar.gz`
   - `/var/log/orch/orch-toolkit-snapshots/<utc-ts>.tar.gz`
   Each archive is paired with a `.sha256` sidecar. Mode `0444` so `rm -f` requires explicit force.
3. **Live process safety** — the running `ci_watcher_daemon.sh` keeps the original (or current) script open via `fd 255`. Recovery via `cat /proc/<pid>/fd/255` is always possible while at least one daemon is alive.

### Snapshot recipe

```bash
TS=$(date -u +%Y%m%dT%H%M%SZ)
TK=/root/repos/RBOK-orchestrator/orchestrator-toolkit
SNAP=orchestrator-toolkit-$TS.tar.gz

cd /root/repos/RBOK-orchestrator
tar -czf "/tmp/$SNAP" orchestrator-toolkit/

for dest in \
  /root/repos/RBOK-orchestrator/.local-backups \
  /root/.config/orch-toolkit-snapshots \
  /var/log/orch/orch-toolkit-snapshots; do
  mkdir -p "$dest"
  cp "/tmp/$SNAP" "$dest/"
  sha256sum "$dest/$SNAP" > "$dest/$SNAP.sha256"
  chmod 444 "$dest/$SNAP" "$dest/$SNAP.sha256"
done
rm "/tmp/$SNAP"
```

### Recovery from snapshot

```bash
# Pick any of the three paths; verify sha matches first
sha256sum -c /var/log/orch/orch-toolkit-snapshots/<file>.sha256

# Restore in place
mkdir -p /root/repos/RBOK-orchestrator
tar -xzf /var/log/orch/orch-toolkit-snapshots/<file>.tar.gz \
  -C /root/repos/RBOK-orchestrator/

# Or: clone fresh from GitHub
git clone https://github.com/RBOKproject/orchestrator-toolkit.git \
  /root/repos/RBOK-orchestrator/orchestrator-toolkit
```

### Recovery from a running daemon (last resort)

```bash
# Find the daemon
pgrep -af ci_watcher_daemon.sh

# Pull the script from /proc (works while the daemon is alive)
cat /proc/<PID>/fd/255 > /tmp/recovered-ci_watcher_daemon.sh
```

This works ONLY for `ci_watcher_daemon.sh`. The other scripts are not held open by any process — git + snapshots are the only durable backups.

## Layout

```
orchestrator-toolkit/
├── lib/
│   ├── audit_log.sh          # audit() + audit_action() + state_dir() + die()
│   ├── state_persist.sh      # state_file/persist/append/read/trim
│   ├── governance_check.sh   # branch protection / required checks / admin bypass policy
│   └── pr_merge.sh           # approve + squash merge with CI gate enforcement
├── examples/
│   ├── nomos.config.sh       # Nomos project (panes: claude/codex/copilot/cursor/gemini)
│   ├── rbok.config.sh        # RBOK project (panes: rbok-claude/...)
│   ├── realisons-wp.config.sh
│   └── 42t.config.sh
├── scripts/
│   ├── ci_watcher_daemon.sh  # long-running CI poller (recovered from /proc)
│   ├── audit_state.sh        # snapshot agents + branches + open PRs + backlog
│   ├── check_ci_health.sh    # default-branch CI gate
│   ├── smart_poll_agents.sh  # wait until trigger=4+4 or timeout=900s
│   ├── dispatch_ticket.sh    # tmux send-keys + paste-buffer to agent pane
│   ├── brief_agents.sh       # render dispatch md from template
│   ├── integrate_wave.sh     # fetch + rebase + sanity gates per agent branch
│   └── cycle.sh              # full pipeline wrapper (CI → dispatch → poll → integrate)
└── templates/
    ├── ticket_dispatch.md    # dispatch md template ({{key}} substitution)
    ├── agent_briefing.md     # per-agent identity + protocol
    └── orch_briefing.md      # per-project orchestrator briefing
```

## Bootstrap

```bash
TK=/root/repos/RBOK-orchestrator/orchestrator-toolkit
source $TK/examples/nomos.config.sh   # or rbok / realisons-wp / 42t
```

After sourcing the config, all `lib/*.sh` and `scripts/*.sh` can be invoked.

## Conventions

- **Audit log format**: `AUDIT LOG: <UTC ISO 8601> <event-keyword> <key1=value1> <key2=value2> ...`
- **Audit log destination**: `/var/log/orch/<project>.log`
- **State dir**: `~/.local/share/orch-state/<project>/` (override via `ORCH_STATE_BASE`)
- **Pane targeting**: `${AGENT_SESSION_PREFIX}<agent>` (Nomos prefix is empty, RBOK is `rbok-`)
- **Doctrine**: never `--admin` bypass on CI=`IN_PROGRESS`/`FAILURE`. Admin allowed ONLY on `BLOCKED`/`UNSTABLE` mergeStateStatus + CI=`success`.

## Doctrine cross-reference

The orchestrator's behavior signatures live in `/var/log/orch/<project>.log`. The PR merge policy was hardened during the RBOK-orchestrator AQ cycles after several `--admin` bypass incidents (see `2026-05-03T10:51:19Z AUDIT WARNING: PRs #2720 #2722 #2723 were merged via --admin bypass before checks completed. New rule: always wait for CI.`).
