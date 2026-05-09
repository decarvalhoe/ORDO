# Issue #387 — 2026-05-08 fleet outage findings & local monitor shutdown handoff

## Purpose

Issue #387 is a session-handoff record: it captures the durable findings
from the 2026-05-08 ORDO/RBOKproject fleet recovery session before the
local Codex monitor was stopped (operator-reported quota near
exhaustion). This runbook is the in-repo, append-only home for those
findings so future recovery sessions can resume from durable evidence
instead of re-deriving the state from scrollback.

The findings themselves are durable in three places: the GitHub issue
body (#387), this runbook (the in-repo CAPA capture per
`docs/orchestrator-injected-rules.md` rule 9), and the linked tracking
issues that own remediation. A finding is considered closed only when
its tracking issue and its associated PR have both landed and been
verified.

## Stop condition recorded for this session

The local Codex audit monitor was stopped at the end of the session
because the operator reported the Codex quota was nearly exhausted.
Future recovery MUST continue from the durable issues and GitHub /
ORDO evidence listed below — never from local scrollback that was
present during the stopped session.

## Confirmed completed actions

- ORDO PR #385 was created, validated, and merged. It fixed the
  root dispatch blocker where `jq --arg label` misclassified valid
  portfolio preflight rows as `not_found`. It also added strict
  same-PR dispatch re-entry for clean non-default branches when the
  current branch has an open PR matching the dispatched ticket and
  status is `local_work_branch` or `branch_needs_rebase`.
- The remote orchestrator runtime was fast-forwarded to
  `origin/main` at `7db93a3` after #385 merged.
- The orchestrator resumed and started same-PR dispatch attempts
  through the ORDO matrix path, not via local direct dispatch.

## Findings (CAPA-shape)

### F1 — Control-plane rate limit aborts dispatch waves

- **Severity:** P0
- **Evidence:** during the post-#385 wave, the control-plane
  returned `claude-opus-4-7 is temporarily unavailable, so auto
  mode cannot determine the safety of Bash right now` and `API
  Error: Server is temporarily limiting requests (not your usage
  limit) · Rate limited`.
- **Impact:** one failed/denied interactive Bash tool call cancelled
  sibling dispatch calls. The orchestrator initially stopped until
  externally nudged. The class of failure is a transient
  control-plane outage and must NOT be confused with an ORDO-side
  dispatch refusal.
- **Required behavior:** dispatch fanout must classify control-plane
  rate-limit / quota / safety-mode signals as transient and apply
  serial bounded retry with explicit audit, never as terminal
  refusal. Sibling dispatch calls in the same wave must not be
  cancelled by one such transient.
- **Durable tracking:** #327 (promoted P0 with this evidence). The
  existing PR #340 targets #327 and must be checked / rebased
  before relying on it.

### F2 — `CONTEXT_PROOF_OK` is not dispatch-consumption proof

- **Severity:** P0
- **Evidence:** after dispatch retries the orchestrator claimed all
  agents were working, but pane captures showed multiple agents at
  prompt, stopped after provider-rate-limit messages, or finished /
  waiting rather than actively processing.
- **Impact:** ORDO can over-report active capacity and miss agents
  that need redispatch / unblock.
- **Required behavior:** post-dispatch state must classify each
  pane as exactly one of: `consumed/active`, `completed`,
  `idle-not-consumed`, `provider-rate-limited`,
  `permission-prompt`, or `blocked`. The orchestrator must
  redispatch / alert when the state is anything other than
  `consumed/active` or `completed`.
- **Durable tracking:** #386 (live-cwd separator bug + consumed-
  state proof), #327 (fanout resilience), #348 / #349 / #350
  (prompt / blocker alerting and unblock loop).

### F3 — Batched tmux separator parsing breaks live pane cwd proof

- **Severity:** P0
- **Evidence:** raw tmux bytes from a rbok pane showed `63 6c 61 75
  64 65 5c 30 33 37 2f ...` — the literal escape sequence `\037`
  rather than the raw ASCII US byte `0x1f`. `tmux_pane_values_batch`
  parsed the literal text as the `command` field and left
  `live_pane_cwd` empty, which prevented `live_cwd_match` from being
  computed.
- **Impact:** fleet readiness and context / capacity reports can be
  false or incomplete because pane sanitation evidence is missing.
- **Required behavior:** the batched-read helper must accept both
  the raw `0x1f` byte AND the literal `\037` text emitted by the
  live tmux server, and the corresponding test fixtures must cover
  both shapes.
- **Durable tracking:** #386 (P0).

### F4 — Agent state after the recovery wave was mixed, not universally active

- **Severity:** P0
- **Evidence:** an independent pane / status sample showed:
  - some agents had made progress and reported PRs mergeable or
    rebased;
  - some panes were at prompt after provider-rate-limit messages;
  - some PRs remained `DIRTY` / conflicting or `UNSTABLE` /
    CI-failed;
  - ORDO status still showed many `needs-rebase`, `merge-conflict`,
    `ci-failed`, or pending states.
- **Impact:** narrative claims like "11/11 agents working" were not
  backed by per-pane consumed-state evidence and current PR status,
  so capacity reports were optimistic and operator triage decisions
  were unreliable.
- **Required behavior:** the orchestrator must NOT use blanket
  narrative statements about agent activity unless they are backed
  by live per-pane consumed-state evidence (F2's classification)
  AND current PR status read from `gh pr view`. Capacity
  reconciliation reports (rule 13) and busy-claim gates (rule 12)
  are the structured surface that supersedes the narrative.
- **Durable tracking:** #386, #327, #283 (false capacity reports),
  #379 (idle backlog dispatch).

## Tracking matrix

| Finding | Severity | Tracking issue(s) | Tracking PR(s) |
| --- | --- | --- | --- |
| F1 — control-plane rate limit aborts wave | P0 | #327 | #340 (verify / rebase) |
| F2 — context-proof is not consumption proof | P0 | #386, #327, #348, #349, #350 | (per tracking issue) |
| F3 — batched tmux separator parsing | P0 | #386 | (per tracking issue) |
| F4 — mixed post-recovery agent state | P0 | #386, #327, #283, #379 | (per tracking issue) |

## Resumption checklist for the next recovery session

When ORDO recovery resumes, the next session MUST:

1. Read this runbook AND the linked tracking issues before
   reasoning about the previous outage.
2. Verify each tracking issue is open or merged with its closing
   commit reachable from `origin/main`. Do not treat a finding as
   closed unless both the issue and its remediation PR have landed.
3. Re-run `scripts/portfolio_status.sh <portfolio-config> --json`
   and confirm the `capacity_report` block (rule 12) and the
   `capacity_reconciliation` matrix (rule 13) before any narrative
   claim about agent activity.
4. Confirm tmux pane state per F2's six-state classification before
   deciding whether to redispatch any agent.
5. Treat any control-plane rate-limit / safety-mode signal in the
   audit log as transient (F1) — never as an ORDO refusal — and
   apply serial bounded retry rather than abandoning the wave.

## Related rules and runbooks

- `docs/orchestrator-injected-rules.md` rule 9 — Production CAPA
  and self-improvement capture (the umbrella requirement that
  produced this runbook).
- `docs/orchestrator-injected-rules.md` rule 12 / 13 — capacity
  reporting and reconciliation surfaces that supersede narrative
  claims about agent activity.
- `docs/runbooks/issue-370-merge-policy-remediation.md` and
  `docs/runbooks/issue-374-safe-post-merge-cleanup-recovery.md` —
  prior recovery runbooks; this one follows the same shape.
