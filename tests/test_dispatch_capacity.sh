#!/usr/bin/env bash
# tests/test_dispatch_capacity.sh — covers lib/dispatch_capacity.sh classifier,
# AGENT_RESERVED_LABELS opt-in (no auto-reservation of `orch`), and
# scripts/portfolio_status.sh capacity_reconciliation aggregation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$SANITIZED_ROOT/examples" "$TEST_TMP/configs"

for rel in \
  scripts/portfolio_status.sh \
  lib/capacity_report.sh \
  lib/config_resolver.sh \
  lib/dispatch_capacity.sh \
  lib/lane_registry.sh \
  lib/portfolio_config.sh \
  lib/process_safety.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/portfolio_status.sh"

# -----------------------------------------------------------------------------
# Unit coverage for lib/dispatch_capacity.sh
# -----------------------------------------------------------------------------
# shellcheck disable=SC1091 # sourcing sanitized copy
source "$SANITIZED_ROOT/lib/dispatch_capacity.sh"

# `orch` must NOT be auto-reserved when AGENT_RESERVED_LABELS is unset/empty.
unset AGENT_RESERVED_LABELS || true
class=$(dispatch_capacity_classify orch 1 /work/ordo-orch /work/ordo-orch main main 0 "" 1)
[ "$class" = "available" ] || fail "orch must be available when AGENT_RESERVED_LABELS is unset (got: $class)"

AGENT_RESERVED_LABELS=()
class=$(dispatch_capacity_classify orch 1 /work/ordo-orch /work/ordo-orch main main 0 "" 1)
[ "$class" = "available" ] || fail "orch must be available when AGENT_RESERVED_LABELS is empty (got: $class)"
unset AGENT_RESERVED_LABELS

# Explicit opt-in via AGENT_RESERVED_LABELS surfaces `reserved`.
AGENT_RESERVED_LABELS=(orch supervisor)
class=$(dispatch_capacity_classify orch 1 /work/ordo-orch /work/ordo-orch main main 0 "" 1)
[ "$class" = "reserved" ] || fail "orch must be reserved when AGENT_RESERVED_LABELS=(orch ...) (got: $class)"
class=$(dispatch_capacity_classify supervisor 1 /work/ordo-sup /work/ordo-sup main main 0 "" 1)
[ "$class" = "reserved" ] || fail "supervisor must be reserved when AGENT_RESERVED_LABELS lists it (got: $class)"
class=$(dispatch_capacity_classify gemini 1 /work/ordo-gemini /work/ordo-gemini main main 0 "" 1)
[ "$class" = "available" ] || fail "non-listed labels stay available even when others are reserved (got: $class)"
unset AGENT_RESERVED_LABELS

# clone_missing wins when the workdir is not a git checkout.
class=$(dispatch_capacity_classify foo 1 /work/foo /work/foo main main 0 "" 0)
[ "$class" = "clone_missing" ] || fail "non-git workdir must classify as clone_missing (got: $class)"

# dirty_clone wins over switch_required.
class=$(dispatch_capacity_classify foo 1 /work/foo /work/other main main 3 "" 1)
[ "$class" = "dirty_clone" ] || fail "dirty workdir must classify as dirty_clone (got: $class)"

# dispatched: clean clone, feature branch, has PR.
class=$(dispatch_capacity_classify foo 1 /work/foo /work/foo feature/xyz main 0 123 1)
[ "$class" = "dispatched" ] || fail "feature branch + open PR must classify as dispatched (got: $class)"

# An open PR alone does NOT make a slot reserved — the wave-1 finding.
# When pr is empty and branch is default, the agent must be available.
class=$(dispatch_capacity_classify foo 1 /work/foo /work/foo main main 0 "" 1)
[ "$class" = "available" ] || fail "main branch + no PR must classify as available (got: $class)"

# Local work (clean clone, feature branch, no PR) is its own class — neither
# reserved nor available.
class=$(dispatch_capacity_classify foo 1 /work/foo /work/foo wip/local main 0 "" 1)
[ "$class" = "local_work" ] || fail "feature branch + no PR must classify as local_work (got: $class)"

# switch_required: clean clone on default branch, pane in a different workdir.
class=$(dispatch_capacity_classify foo 1 /work/ordo-foo /work/praxis-foo main main 0 "" 1)
[ "$class" = "switch_required" ] || fail "pane in another project must classify as switch_required (got: $class)"

# pane_not_ready: clone clean, pane reported dead.
class=$(dispatch_capacity_classify foo 0 /work/foo "" main main 0 "" 1)
[ "$class" = "pane_not_ready" ] || fail "alive=0 must classify as pane_not_ready (got: $class)"

# Reason strings exist for every class in the canonical list.
for cls in reserved dispatched local_work dirty_clone switch_required pane_not_ready clone_missing available; do
  reason=$(dispatch_capacity_reason "$cls")
  [ -n "$reason" ] || fail "missing reason for capacity class: $cls"
done

# -----------------------------------------------------------------------------
# Integration coverage for portfolio_status.sh capacity_reconciliation
# -----------------------------------------------------------------------------
# Reproduces the wave-1 ORDO finding: 11 configured agents, 8 dispatched
# elsewhere, copilot+orch+gemini-style available, cursor pane in praxis.
cat > "$SANITIZED_ROOT/scripts/agent_pool_status.sh" <<'EOF'
#!/usr/bin/env bash
cfg=$1
case "$cfg" in
  *ordo* )
    cat <<'JSON'
[
  {"label":"claude","pane":"claude:0.0","workdir":"/root/repos/ordo/claude","pane_workdir":"/root/repos/ordo/claude","capacity_class":"dispatched","branch":"feature/250","dirty":"0","pr":"270","signals":[]},
  {"label":"codex","pane":"codex:0.0","workdir":"/root/repos/ordo/codex","pane_workdir":"/root/repos/ordo/codex","capacity_class":"dispatched","branch":"docs/258","dirty":"0","pr":"269","signals":[]},
  {"label":"copilot","pane":"copilot:0.0","workdir":"/root/repos/ordo/copilot","pane_workdir":"/root/repos/ordo/copilot","capacity_class":"available","branch":"main","dirty":"0","pr":"","signals":[]},
  {"label":"cursor","pane":"cursor:0.0","workdir":"/root/repos/ordo/cursor","pane_workdir":"/root/repos/praxis/cursor","capacity_class":"switch_required","branch":"main","dirty":"0","pr":"","signals":[]},
  {"label":"gemini","pane":"gemini:0.0","workdir":"/root/repos/ordo/gemini","pane_workdir":"/root/repos/ordo/gemini","capacity_class":"dispatched","branch":"docs/259","dirty":"0","pr":"272","signals":[]},
  {"label":"orch","pane":"orch:0.0","workdir":"/root/repos/ordo/orch","pane_workdir":"/root/repos/ordo/orch","capacity_class":"available","branch":"main","dirty":"0","pr":"","signals":[]},
  {"label":"rbok-claude","pane":"rbok-claude:0.0","workdir":"/root/repos/ordo/rbok-claude","pane_workdir":"/root/repos/ordo/rbok-claude","capacity_class":"available","branch":"main","dirty":"0","pr":"","signals":[]},
  {"label":"rbok-codex","pane":"rbok-codex:0.0","workdir":"/root/repos/ordo/rbok-codex","pane_workdir":"/root/repos/ordo/rbok-codex","capacity_class":"dispatched","branch":"feature/abc","dirty":"0","pr":"291","signals":[]},
  {"label":"rbok-copilot","pane":"rbok-copilot:0.0","workdir":"/root/repos/ordo/rbok-copilot","pane_workdir":"/root/repos/ordo/rbok-copilot","capacity_class":"dirty_clone","branch":"feature/wip","dirty":"4","pr":"","signals":["dirty"]},
  {"label":"rbok-cursor","pane":"rbok-cursor:0.0","workdir":"/root/repos/ordo/rbok-cursor","pane_workdir":"","capacity_class":"pane_not_ready","branch":"main","dirty":"0","pr":"","signals":[]},
  {"label":"rbok-gemini","pane":"rbok-gemini:0.0","workdir":"/root/repos/ordo/rbok-gemini","pane_workdir":"/root/repos/ordo/rbok-gemini","capacity_class":"dispatched","branch":"feature/def","dirty":"0","pr":"292","signals":[]}
]
JSON
    ;;
esac
EOF
chmod +x "$SANITIZED_ROOT/scripts/agent_pool_status.sh"

cat > "$SANITIZED_ROOT/scripts/pr_block_signals.sh" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
chmod +x "$SANITIZED_ROOT/scripts/pr_block_signals.sh"

cat > "$TEST_TMP/configs/ordo.config.sh" <<'EOF'
PROJECT="ordo"
GH_REPO="example/ordo"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/tmp/gh"
AGENT_REPO_PREFIX="/root/repos/ordo/"
export AGENT_WORKDIR_TEMPLATE="/root/repos/ordo/%s"
EOF

cat > "$TEST_TMP/configs/portfolio.config.sh" <<EOF
PORTFOLIO_NAME="wave-1"
PORTFOLIO_PROJECTS=(
  "ordo|$TEST_TMP/configs/ordo.config.sh"
)
PORTFOLIO_PRIORITIES=(
  "ordo=100"
)
EOF

output=$(ORCH_STATE_BASE="$TEST_TMP/state-json" bash "$SANITIZED_ROOT/scripts/portfolio_status.sh" "$TEST_TMP/configs/portfolio.config.sh" --json)

# capacity_reconciliation block: 11 configured = 6 dispatched + 3 available + 1 switch_required + 1 dirty_clone + 1 pane_not_ready (recompute below — actual wave fixture above)
configured=$(printf '%s' "$output" | jq -r '.[0].capacity_reconciliation.configured')
[ "$configured" = "11" ] || fail "capacity_reconciliation.configured must be 11 (got: $configured)"

available=$(printf '%s' "$output" | jq -r '.[0].capacity_reconciliation.available')
[ "$available" = "3" ] || fail "capacity_reconciliation.available must be 3 (got: $available)"

dispatched=$(printf '%s' "$output" | jq -r '.[0].capacity_reconciliation.dispatched')
[ "$dispatched" = "5" ] || fail "capacity_reconciliation.dispatched must be 5 (got: $dispatched)"

switch_required=$(printf '%s' "$output" | jq -r '.[0].capacity_reconciliation.switch_required')
[ "$switch_required" = "1" ] || fail "capacity_reconciliation.switch_required must be 1 (got: $switch_required)"

dirty_clone=$(printf '%s' "$output" | jq -r '.[0].capacity_reconciliation.dirty_clone')
[ "$dirty_clone" = "1" ] || fail "capacity_reconciliation.dirty_clone must be 1 (got: $dirty_clone)"

pane_not_ready=$(printf '%s' "$output" | jq -r '.[0].capacity_reconciliation.pane_not_ready')
[ "$pane_not_ready" = "1" ] || fail "capacity_reconciliation.pane_not_ready must be 1 (got: $pane_not_ready)"

reserved=$(printf '%s' "$output" | jq -r '.[0].capacity_reconciliation.reserved')
[ "$reserved" = "0" ] || fail "wave-1 fixture has no auto-reservations; reserved must be 0 (got: $reserved)"

# Capacity counts must equal the configured agent count: every slot is
# accounted for in exactly one class.
total=$(printf '%s' "$output" | jq -r '
  [.[0].capacity_reconciliation.available,
   .[0].capacity_reconciliation.dispatched,
   .[0].capacity_reconciliation.reserved,
   .[0].capacity_reconciliation.switch_required,
   .[0].capacity_reconciliation.dirty_clone,
   .[0].capacity_reconciliation.pane_not_ready,
   .[0].capacity_reconciliation.clone_missing,
   .[0].capacity_reconciliation.local_work] | add')
[ "$total" = "11" ] || fail "capacity classes must sum to configured count (got: $total)"

# Available labels must include `orch` (the wave-1 finding: orch was wrongly
# auto-reserved before; here the matrix correctly surfaces it as available).
orch_available=$(printf '%s' "$output" | jq -r '.[0].capacity_reconciliation.available_labels | index("orch") != null')
[ "$orch_available" = "true" ] || fail "orch must appear as available in the matrix (got: $orch_available)"

copilot_available=$(printf '%s' "$output" | jq -r '.[0].capacity_reconciliation.available_labels | index("copilot") != null')
[ "$copilot_available" = "true" ] || fail "copilot must appear as available in the matrix (got: $copilot_available)"

cursor_switch=$(printf '%s' "$output" | jq -r '.[0].capacity_reconciliation.switch_required_labels | index("cursor") != null')
[ "$cursor_switch" = "true" ] || fail "cursor must appear as switch_required in the matrix (got: $cursor_switch)"

# TSV must surface the new capacity columns.
tsv=$(ORCH_STATE_BASE="$TEST_TMP/state-tsv" bash "$SANITIZED_ROOT/scripts/portfolio_status.sh" "$TEST_TMP/configs/portfolio.config.sh" --tsv)
header=$(printf '%s' "$tsv" | head -1)
case "$header" in
  *cap_configured*cap_available*cap_dispatched*cap_reserved*cap_switch_required*) ;;
  *) fail "TSV header missing capacity columns: $header" ;;
esac
row=$(printf '%s' "$tsv" | sed -n '2p')
case "$row" in
  *$'\t'11$'\t'3$'\t'5$'\t'0$'\t'1$'\t'*) ;;
  *) fail "TSV row missing expected capacity counts: $row" ;;
esac

printf 'ok - test_dispatch_capacity\n'
