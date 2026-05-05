#!/usr/bin/env bash
# install.sh — set up orch-toolkit on this machine.
# Idempotent. Safe to run multiple times.
#
# What it does:
#   1. Make all scripts executable.
#   2. Create $ORCH_LOG_DIR (default /var/log/orch).
#   3. Create per-project state dirs for each examples/*.config.sh.
#   4. Print a summary of detected projects + what to run next.

set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

echo "==> orch-toolkit installer (TK=$TK)"

# 1. Permissions
echo "[1/4] Making scripts executable..."
find "$TK/scripts" -type f -name '*.sh' -exec chmod +x {} \;
chmod +x "$TK/install.sh"

# 2. Log dir
LOG_DIR=/var/log/orch
echo "[2/4] Creating $LOG_DIR..."
mkdir -p "$LOG_DIR"

# 3. Per-project state dirs
echo "[3/4] Creating state dirs for known projects..."
for cfg in "$TK"/examples/*.config.sh; do
  [[ -f "$cfg" ]] || continue
  project=$(grep -E '^export PROJECT=' "$cfg" | head -1 | sed 's/.*=//')
  [[ -z "$project" ]] && continue
  state="${XDG_DATA_HOME:-/root/.local/share}/orch-state/$project"
  mkdir -p "$state"
  echo "    - $project -> $state"
done

# 4. Token file template
TOKENS=/root/.config/orch-tokens.env
if [[ ! -f "$TOKENS" ]]; then
  echo "[4/4] No $TOKENS found. Copy from examples/orch-tokens.env.example, fill it, chmod 600:"
  echo "    cp $TK/examples/orch-tokens.env.example $TOKENS"
  echo "    \$EDITOR $TOKENS"
  echo "    chmod 600 $TOKENS"
else
  perms=$(stat -c '%a' "$TOKENS")
  if [[ "$perms" != "600" ]]; then
    echo "[4/4] WARNING: $TOKENS exists but mode is $perms (expected 600). Fix with:"
    echo "    chmod 600 $TOKENS"
  else
    echo "[4/4] Token file $TOKENS present (mode 600) ✓"
  fi
fi

cat <<EOF

==> Install complete.
Next:
  1. Source a project config:    source $TK/examples/rbok.config.sh
  2. Snapshot state:              bash \$TK/scripts/audit_state.sh
  3. Dispatch a ticket:           bash \$TK/scripts/dispatch_ticket.sh claude 2947
  4. Run a full cycle:            bash \$TK/scripts/cycle.sh
  5. Start CI watcher daemon:
       tmux new-session -d -s rbok-ciwatch \\
         "bash \$TK/scripts/ci_watcher_daemon.sh rbok"
EOF
