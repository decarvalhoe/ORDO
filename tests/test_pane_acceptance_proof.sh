#!/usr/bin/env bash
# tests/test_pane_acceptance_proof.sh — coverage for ORDO #573.
#
# `pane_acceptance_proof` MUST refuse to confirm an agent has accepted
# a ticket when the pane scrollback only shows a stale prior transcript
# (no brief filename, no current ticket reference). Live evidence
# (#573) showed RBOK-cursor / RBOK-gemini panes still on prior ORDO
# transcripts while the ledger marked them busy on RBOK tickets.
#
# Approach: stub `tmux capture-pane` to emit deterministic scrollback
# fixtures. Verify three reference cases:
#   1. Brief filename in scrollback → ACCEPT (reason=brief-filename).
#   2. Ticket number reference (no brief filename) → ACCEPT
#      (reason=ticket-reference).
#   3. Stale unrelated transcript → REFUSE
#      (reason=no-acceptance-evidence).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TEST_TMP/bin"

# Fixture controller: each test case writes a different scrollback to
# $TEST_TMP/scrollback.txt. The tmux stub `cat`s that file when called
# with `capture-pane`.
cat > "$TEST_TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"capture-pane"*)
    cat "$TEST_TMP/scrollback.txt" 2>/dev/null || true
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/tmux"

run_proof() {
  local agent=$1 ticket=$2 timeout=${3:-2} lines=${4:-50}
  # Prepend stub bin to PATH (preserve real PATH for dirname/cd/grep
  # used by tmux_helpers.sh itself).
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_TMUX_TIMEOUT_SEC=5 \
  ORCH_DISPATCH_ACCEPTANCE_TIMEOUT_SEC=$timeout \
  ORCH_DISPATCH_ACCEPTANCE_POLL_SEC=1 \
    bash -c "
      audit() { :; }
      # shellcheck source=/dev/null
      source '$ROOT/lib/tmux_helpers.sh'
      if pane_acceptance_proof 'fake-pane:0.0' '$agent' '$ticket' '$timeout' '$lines'; then
        printf 'ACCEPT reason=%s\n' \"\${PANE_ACCEPTANCE_PROOF_REASON:-unknown}\"
      else
        printf 'REFUSE reason=%s\n' \"\${PANE_ACCEPTANCE_PROOF_REASON:-unknown}\"
      fi
    "
}

# Case 1: brief filename in scrollback → ACCEPT
cat > "$TEST_TMP/scrollback.txt" <<'EOF'
[some prior output]
> Read /tmp/dispatch-claude-573.md and execute it end-to-end.
✻ Cogitating for 2s
EOF
out1=$(run_proof claude 573)
[[ "$out1" == "ACCEPT reason=brief-filename" ]] \
  || fail "case 1 expected ACCEPT brief-filename, got: $out1"

# Case 2: ticket number reference (no brief filename) → ACCEPT
cat > "$TEST_TMP/scrollback.txt" <<'EOF'
[live work]
gh issue view 3208 --repo RBOKproject/RBOK
title:  fix(client-onboarding): wire onboarding wizard
state:  OPEN
labels: priority:P1, frontend
EOF
out2=$(run_proof rbok-cursor 3208)
[[ "$out2" == "ACCEPT reason=ticket-reference" ]] \
  || fail "case 2 expected ACCEPT ticket-reference, got: $out2"

# Case 3: stale prior transcript with NO reference to current ticket
# → REFUSE
cat > "$TEST_TMP/scrollback.txt" <<'EOF'
[old ORDO work]
gh pr merge 451 --repo RBOKproject/ORDO --squash
PR #451 merged successfully
session total: 36 PRs merged
EOF
out3=$(run_proof rbok-cursor 3208 2)
[[ "$out3" == "REFUSE reason=no-acceptance-evidence" ]] \
  || fail "case 3 expected REFUSE no-acceptance-evidence, got: $out3"

# Case 4: word-boundary safety — `132080` must NOT match ticket 3208.
cat > "$TEST_TMP/scrollback.txt" <<'EOF'
processing batch 132080 of 200000 records...
EOF
out4=$(run_proof rbok-cursor 3208 2)
[[ "$out4" == "REFUSE reason=no-acceptance-evidence" ]] \
  || fail "case 4 expected REFUSE (word-boundary), got: $out4"

# Case 5: ticket boundary `#3208` and `(3208)` must MATCH.
cat > "$TEST_TMP/scrollback.txt" <<'EOF'
audit_log: assignment_promoted ticket=#3208 agent=rbok-cursor
EOF
out5=$(run_proof rbok-cursor 3208)
[[ "$out5" == "ACCEPT reason=ticket-reference" ]] \
  || fail "case 5 expected ACCEPT (#3208), got: $out5"

printf 'ok - pane_acceptance_proof accepts brief-filename / ticket-reference and refuses stale transcripts\n'
