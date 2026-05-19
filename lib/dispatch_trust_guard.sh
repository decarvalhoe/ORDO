#!/usr/bin/env bash
# dispatch_trust_guard.sh — detect Claude Code trust modal in the dispatched
# pane so acceptance-proof failures classify a stolen brief instead of the
# generic `no-acceptance-evidence` reason.
#
# Issue #705: when `dispatch_ticket.sh` respawns the agent pane at a workdir
# that Claude Code has not previously trusted, the CLI restarts with a
# "Do you trust the contents of this directory?" modal. The orchestrator's
# `paste-buffer + send-keys Enter` sequence is consumed by the modal — the
# brief is never read, but the `ACCEPTANCE_PROOF` brief-filename heuristic
# in `pane_acceptance_proof` (`lib/tmux_helpers.sh`) still fires its
# `no-acceptance-evidence` refusal without surfacing the real cause.
#
# This guard is the second-pass classifier: when acceptance proof has
# already returned non-zero, call `dispatch_trust_dialog_present` to test
# whether the trust modal text is visible in the recent pane scrollback.
# The dispatcher promotes a positive hit into a stronger refusal reason
# (`trust-dialog`, status `trust_dialog_blocking`) so capacity reports
# show the real blocker and the operator can react with the documented
# remediation (run `claude --dangerously-skip-permissions` or pre-approve
# the directory).
#
# Public API:
#   dispatch_trust_dialog_present TARGET [LINES]
#     Returns 0 when the trust modal text matches in the last LINES of
#     scrollback captured from TARGET. Returns 1 otherwise (no evidence
#     OR pane capture failed). The helper relies on `capture_pane` from
#     `lib/tmux_helpers.sh`; callers must source that lib first.
#
# Side-channel state for callers/tests (cleared on every call):
#   DISPATCH_TRUST_DIALOG_SIGNAL  matched marker label (`trust-prompt`,
#                                 `trust-choice`) or '' on no match.
#
# Configuration (env overrides, all optional):
#   ORCH_DISPATCH_TRUST_DIALOG_LINES         scrollback line budget; default 40.
#   ORCH_DISPATCH_TRUST_DIALOG_PROMPT_PATTERN  ERE for the trust prompt
#                                              question; default matches
#                                              "Do you trust the contents of
#                                              this directory".
#   ORCH_DISPATCH_TRUST_DIALOG_YES_PATTERN     ERE matched against the
#                                              captured scrollback; both
#                                              this and the NO pattern
#                                              must hit for `trust-choice`
#                                              classification. Default
#                                              matches `Yes, continue` or
#                                              `Yes, proceed`.
#   ORCH_DISPATCH_TRUST_DIALOG_NO_PATTERN      ERE for the negative
#                                              choice. Default matches
#                                              `No, quit`.
#
# Sourcing contract: this lib uses `capture_pane` from
# `lib/tmux_helpers.sh`. It does not source any other lib so it stays
# cheap to use from tests that stub tmux directly.

dispatch_trust_dialog_present() {
  local target=${1:?usage: dispatch_trust_dialog_present <target> [lines]}
  local lines=${2:-${ORCH_DISPATCH_TRUST_DIALOG_LINES:-40}}
  DISPATCH_TRUST_DIALOG_SIGNAL=""

  local capture
  capture=$(capture_pane "$target" "$lines" 2>/dev/null || printf '')
  [ -n "$capture" ] || return 1

  local prompt_pattern=${ORCH_DISPATCH_TRUST_DIALOG_PROMPT_PATTERN:-'Do you trust the contents of this directory'}
  local yes_pattern=${ORCH_DISPATCH_TRUST_DIALOG_YES_PATTERN:-'Yes,[[:space:]]+(continue|proceed)'}
  local no_pattern=${ORCH_DISPATCH_TRUST_DIALOG_NO_PATTERN:-'No,[[:space:]]+quit'}

  if grep -qE "$prompt_pattern" <<< "$capture"; then
    DISPATCH_TRUST_DIALOG_SIGNAL="trust-prompt"
    return 0
  fi
  # The numbered-choice row may have scrolled the prompt question off
  # screen but still pins the pane on the modal. Require BOTH the
  # accept and refuse rows so unrelated transcripts that happen to say
  # "Yes" or "No" do not false-positive.
  if grep -qE "$yes_pattern" <<< "$capture" \
    && grep -qE "$no_pattern" <<< "$capture"; then
    DISPATCH_TRUST_DIALOG_SIGNAL="trust-choice"
    return 0
  fi
  return 1
}
