#!/usr/bin/env bash
# tests/test_dispatch_trust_dialog.sh — coverage for ORDO #705.
#
# When `dispatch_ticket.sh` respawns an agent pane at a workdir that
# Claude Code has not previously trusted, the CLI restarts with a
# "Do you trust the contents of this directory?" modal. The
# orchestrator's `paste-buffer + send-keys Enter` is consumed by the
# modal — the brief is never read, but the post-dispatch
# `pane_acceptance_proof` only knows to refuse with the generic
# `no-acceptance-evidence` reason because the brief filename never
# appears in scrollback.
#
# This test exercises the `dispatch_trust_dialog_present` helper
# (`lib/dispatch_trust_guard.sh`) plus its integration into
# `scripts/dispatch_ticket.sh`:
#
#   1. Trust-prompt scrollback → helper returns 0 with signal=trust-prompt.
#   2. Numbered-choice-only scrollback → helper returns 0 with
#      signal=trust-choice (covers panes that scrolled the question off
#      but still show `1. Yes, continue / 2. No, quit`).
#   3. Stale unrelated scrollback → helper returns 1, no signal.
#   4. Empty pane capture → helper returns 1.
#   5. dispatch_ticket.sh sources the new guard lib and references it.
#   6. End-to-end classification: simulate the acceptance-proof failure
#      path with the trust modal present and confirm the dispatched
#      classification logic promotes the reason to `trust-dialog`.

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

# Fixture controller: each case writes a scrollback file the tmux stub
# emits when called with `capture-pane`. Other tmux subcommands return
# empty 0 so `capture_pane` (lib/tmux_helpers.sh) is exercised verbatim.
# Use /bin/sh so the stub doesn't re-read bashrc — under tmux, the
# operator's bashrc calls `tmux display-message` which would recurse
# back through this stub (when bash starts to interpret a `#!/usr/bin/env
# bash` stub) and exhaust the timeout.
cat > "$TEST_TMP/bin/tmux" <<EOF
#!/bin/sh
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

run_trust_guard() {
  local lines=${1:-40}
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_TMUX_TIMEOUT_SEC=5 \
    bash -c "
      audit() { :; }
      # shellcheck source=/dev/null
      source '$ROOT/lib/tmux_helpers.sh'
      # shellcheck source=/dev/null
      source '$ROOT/lib/dispatch_trust_guard.sh'
      if dispatch_trust_dialog_present 'fake-pane:0.0' '$lines'; then
        printf 'PRESENT signal=%s\n' \"\${DISPATCH_TRUST_DIALOG_SIGNAL:-unknown}\"
      else
        printf 'ABSENT signal=%s\n' \"\${DISPATCH_TRUST_DIALOG_SIGNAL:-}\"
      fi
    "
}

# --- Case 1: trust prompt question line present ------------------------------
cat > "$TEST_TMP/scrollback.txt" <<'EOF'
> You are in /root/repos/fleet-worktrees/rbok/agent-009

  Do you trust the contents of this directory? Working with untrusted contents
  comes with higher risk of prompt injection. Trusting the directory allows
  project-local config, hooks, and exec policies to load.

  1. Yes, continue
  2. No, quit
EOF
out1=$(run_trust_guard)
[[ "$out1" == "PRESENT signal=trust-prompt" ]] \
  || fail "case 1 expected PRESENT trust-prompt, got: $out1"

# --- Case 2: only numbered choice visible (question scrolled off) ------------
cat > "$TEST_TMP/scrollback.txt" <<'EOF'
[scrollback truncated]
› 1. Yes, continue
  2. No, quit

  Press enter to continue
EOF
out2=$(run_trust_guard)
[[ "$out2" == "PRESENT signal=trust-choice" ]] \
  || fail "case 2 expected PRESENT trust-choice, got: $out2"

# --- Case 3: stale unrelated transcript -> ABSENT ----------------------------
cat > "$TEST_TMP/scrollback.txt" <<'EOF'
gh pr merge 451 --repo RBOKproject/ORDO --squash
PR #451 merged successfully
session total: 36 PRs merged
EOF
out3=$(run_trust_guard)
[[ "$out3" == "ABSENT signal=" ]] \
  || fail "case 3 expected ABSENT (no signal), got: $out3"

# --- Case 4: empty pane capture -> ABSENT ------------------------------------
: > "$TEST_TMP/scrollback.txt"
out4=$(run_trust_guard)
[[ "$out4" == "ABSENT signal=" ]] \
  || fail "case 4 expected ABSENT on empty capture, got: $out4"

# --- Case 5: dispatch_ticket.sh wires the new guard --------------------------
grep -q 'lib/dispatch_trust_guard.sh' "$ROOT/scripts/dispatch_ticket.sh" \
  || fail "case 5 expected dispatch_ticket.sh to source lib/dispatch_trust_guard.sh"
grep -q 'dispatch_trust_dialog_present' "$ROOT/scripts/dispatch_ticket.sh" \
  || fail "case 5 expected dispatch_ticket.sh to call dispatch_trust_dialog_present"
grep -q 'trust_dialog_blocking' "$ROOT/scripts/dispatch_ticket.sh" \
  || fail "case 5 expected dispatch_ticket.sh to surface trust_dialog_blocking status"

# --- Case 6: classification path promotes reason to trust-dialog -------------
# Mirror the dispatch_ticket.sh acceptance-proof failure block: when the
# acceptance helper returns non-zero AND the trust guard detects the
# modal, the effective `proof_reason` is `trust-dialog`. This is the
# exact code path the dispatcher takes — keeping the assertion close to
# the live wording catches reason-rename regressions.
cat > "$TEST_TMP/scrollback.txt" <<'EOF'
  Do you trust the contents of this directory?
  1. Yes, continue
  2. No, quit
EOF
classification=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_TMUX_TIMEOUT_SEC=5 \
  ORCH_DISPATCH_ACCEPTANCE_TIMEOUT_SEC=1 \
  ORCH_DISPATCH_ACCEPTANCE_POLL_SEC=1 \
    bash -c "
      audit() { :; }
      # shellcheck source=/dev/null
      source '$ROOT/lib/tmux_helpers.sh'
      # shellcheck source=/dev/null
      source '$ROOT/lib/dispatch_trust_guard.sh'
      if pane_acceptance_proof 'fake-pane:0.0' 'agent-009' '682' 1 30; then
        printf 'UNEXPECTED_OK\n'
        exit 0
      fi
      proof_reason=\${PANE_ACCEPTANCE_PROOF_REASON:-no-acceptance-evidence}
      if dispatch_trust_dialog_present 'fake-pane:0.0'; then
        proof_reason=trust-dialog
      fi
      printf 'reason=%s signal=%s\n' \"\$proof_reason\" \"\${DISPATCH_TRUST_DIALOG_SIGNAL:-}\"
    "
)
[[ "$classification" == "reason=trust-dialog signal=trust-prompt" ]] \
  || fail "case 6 expected classification 'reason=trust-dialog signal=trust-prompt', got: $classification"

printf 'ok - dispatch_trust_dialog_present detects Claude Code trust modal and dispatch_ticket promotes reason to trust-dialog\n'
