#!/usr/bin/env bash
# install.sh - set up ORDO on this machine.
# Idempotent. Safe to run multiple times.
#
# What it does:
#   1. Make all scripts executable.
#   2. Create $ORCH_LOG_DIR (default /var/log/orch).
#   3. Create per-project state dirs for each examples/*.config.sh.
#   4. Print a summary of detected projects + what to run next.

set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

echo "==> ORDO installer (TK=$TK)"

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
  project=$(
    (
      unset PROJECT
      # shellcheck disable=SC1090
      source "$cfg" 2>/dev/null
      printf '%s' "${PROJECT:-}"
    )
  )
  [[ -z "$project" ]] && continue
  state="${XDG_DATA_HOME:-$HOME/.local/share}/orch-state/$project"
  mkdir -p "$state"
  echo "    - $project -> $state"
done

# 4. Token file template
TOKENS="${ORDO_TOKENS_FILE:-$HOME/.config/ordo-tokens.env}"
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
  1. Point at an external profile:
       export ORDO_PROJECT_PROFILE=/secure/operator/project.config.sh
  2. Source the neutral loader:
       source $TK/examples/ordo.config.sh
  3. Snapshot state:
       bash \$TK/scripts/audit_state.sh examples/ordo.config.sh
  4. Dispatch a dry-run ticket:
       bash \$TK/scripts/dispatch_ticket.sh examples/ordo.config.sh builder 2947 /tmp/dispatch-builder-2947.md --dry-run
  5. Start a watcher only from an operator-owned service/session profile.
EOF
