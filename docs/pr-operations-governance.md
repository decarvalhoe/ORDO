# PR Operations Governance — epic #357

ORDO supports explicit, profile-driven **PR operations modes** so
the orchestrator and the fleet can split merge/fix-CI/readiness work
along an auditable contract instead of via ad-hoc operator narration.
This document is the umbrella reference for the modes and live policy
names that the #357 PR-operations work implements and that
`docs/orchestrator-injected-rules.md` rule 12 mandates.

The governance contract is intentionally short: the modes name *who*
may finalize a PR mutation, *under what gates*, and *with what
evidence*. The "what" of remediation — running `gh pr ready`, fixing a
broken test, rebasing a branch — is unchanged. The modes only govern
authorization.

## Modes at a glance

| Mode          | Final mutations           | Agents may prepare? | Profile gate                     | Default |
| ------------- | ------------------------- | ------------------- | -------------------------------- | ------- |
| `observe`     | always refused            | yes                 | always available                 | yes     |
| `assist`      | operator + required gates | yes                 | `PR_OPS_MODE_ALLOWED` includes it | no      |
| `automerge`   | operator/automation + required gates | yes       | `PR_OPS_MODE_ALLOWED` includes it | no      |
| `centralized` | operator + required gates | yes                 | `PR_OPS_MODE_ALLOWED` includes it | no      |
| `delegated`   | dispatched fleet agent (one PR per agent), audit-only mutation scope | yes | `PR_OPS_MODE_ALLOWED` includes it | no |
| `autonomous`  | runner with profile-gated merge authority | yes | `AUTO_PR_OPS_ENABLED=1` + every gate green | no |

Final mutations are: `merge`, `ready-for-review`, `rerun`, `close`,
`branch-delete`. Preparation actions — `prepare-fix`,
`evidence-record`, `comment-audit-only`, `report-status` — are
**always allowed** in every mode for every actor. Agents do not lose
the ability to gather evidence or stage patches when the mode tightens.

Mode resolution comes from the project / portfolio profile, never from
chat. The order is:

1. `ORDO_PR_OPS_MODE` (per-session env override; for tests and
   one-off operator runs)
2. `PR_OPS_MODE` in the project profile
3. `observe` (the safe default)

A non-`observe` mode also requires the profile to opt in via
`PR_OPS_MODE_ALLOWED` (a comma list), so a stricter profile cannot be
silently downgraded by a session env. The autonomous runner adds its
own gates (`AUTO_PR_OPS_ENABLED=1`, kill switch released, all profile
gates green) on top of that.

Live profiles use `observe`, `assist`, and `automerge` as the
operator-facing policy names. `centralized` remains accepted for
backward-compatible controller callers and has the same authorization
semantics as `assist`.

## How the modes compose

```text
              +---------------------+
              | scripts/pr_block_   |     read-only PR / CI snapshot
              | signals.sh          |     (no mutation, no narration)
              +----------+----------+
                         |
                         v
              +---------------------+     classifier — turns each PR
              | scripts/pr_ops_     |     blocker into one of:
              | queue.sh (#358)     |     fix_ci, resolve_conflict,
              +----------+----------+     refresh_branch, mark_ready_…,
                         |                review_required,
                         v                merge_candidate,
              +---------------------+     hold_unknown_state,
              | mode dispatcher     |     hold_policy_blocked
              | (PR_OPS_MODE)       |
              +---+------+------+---+
                  |      |      |
       observe    | dele-| auto-| centralized
                  | gated| nomous|
                  v      v      v
           +-----+ +-----+ +-----+ +----------+
           | no- | | dis-| | mer-| | pr_ops_  |
           | op  | | pat-| | ger | | control- |
           +-----+ | ch_ | | (361| | ler.sh   |
                  | pr_ | | )    | | (360)    |
                  | ops.| |      | +----------+
                  | sh  | |      |
                  | (359| |      |
                  | )   | |      |
                  +-----+ +-----+
```

* The **queue** (#358, `lib/pr_ops_queue.sh` / `scripts/pr_ops_queue.sh`)
  is read-only and refuses stale cached state when a live refresh is
  required. Every downstream mode consumes the same `ordo.pr_ops_queue.v1`
  shape so classification logic never duplicates.
* **`observe` mode** stops at the queue. The classification table is
  printed; no tasks are emitted; no PR is mutated. This is the
  default and also the operator's "what's the wave look like?" view.
* **`assist` / `centralized` mode** (#360,
  `scripts/pr_ops_controller.sh`) lets fleet agents stage
  `prepare-fix` / `evidence-record` patches via `dispatch_pr_ops.sh`
  BUT routes every final mutation through a controller that authorizes
  only `actor=operator` AND every required gate satisfied. The
  controller is a **policy engine, not a mutation engine** — it
  returns a structured JSON decision, `next_action`, escalation
  payload, and typed exit code; the operator pane runs the actual
  `gh` / `git` mutation.
* **`automerge` mode** uses the same controller contract for live
  drains that have explicitly opted in to automatic merge authority.
  It authorizes `actor=operator` or `actor=automation` only when every
  required gate has been supplied by the caller.
* **`delegated` mode** (#359, `scripts/dispatch_pr_ops.sh`) renders
  one PR-op task per available agent through universal templates
  under `templates/pr_op_*.md.tpl`, each declaring its
  `external-pr-mutations` scope (`audit_evidence` for fix_ci /
  resolve_conflict; `audit_evidence,pr_state` for
  mark_ready_candidate). Agents never merge from a delegated task —
  merge authority remains the operator's even in delegated mode.
* **`autonomous` mode** (#361, `scripts/autonomous_pr_ops.sh`) is the
  only mode that can call `gh pr merge` without an operator in the
  loop. It is opt-in via `AUTO_PR_OPS_ENABLED=1`, has a kill switch,
  and refuses on **any** unknown / pending / failed gate.

## What every mode guarantees

Regardless of which mode a profile selects, the following invariants
hold structurally (enforced by `lib/pr_ops_mode.sh`,
`lib/pr_ops_queue.sh`, `lib/pr_ops_tasks.sh`, and the four scripts
above):

1. **One PR per agent per wave.** `dispatch_pr_ops.sh` tracks
   `AGENT_ASSIGNED` and refuses a second task for the same agent
   with `blocker:duplicate-assignment`. The orchestrator must not
   bypass this with parallel `dispatch_ticket.sh` calls; the
   conflict-storm finding from #357 was caused by exactly that.
2. **Bounded mutation scope.** Every rendered task declares its
   `external-pr-mutations` scope explicitly. The dispatcher's
   external-PR-mutation gate (rule 11 in
   `docs/orchestrator-injected-rules.md`) refuses a prompt that
   widens the scope beyond what the mode allows.
3. **Refuse on uncertainty.** Dirty agent clones, missing branch,
   `mergeable=UNKNOWN`, missing `PR_OPS_MODE_ALLOWED`, and
   coordination-surface hotspot conflicts all produce blockers, not
   assignments. The autonomous runner extends this to "any check
   not strictly `success`" and "any review state not strictly
   `APPROVED` when reviews are required".
4. **Universal templates.** Task prompts are agent-CLI-neutral and
   project-name-neutral. Any project-specific or model-specific text
   in a rendered prompt is a finding under rule 9 of the injected
   rules and should be re-rendered from the canonical template.
5. **Evidence chain.** Every mode emits a structured audit line:
    * Queue: `PR_OPS_QUEUE classified pr=#<n> type=<…> …`
    * Dispatcher: `PR_OPS DISPATCH agent=<a> ticket=#<n> mode=<…>`
    * Controller: `PR_OPS_CONTROLLER decision=<allowed|refused> reason=<kebab>`
    * Autonomous: `AUTO_PR_OPS evaluate pr=#<n> verdict=<…>`
   The wave summary line `PR_OPS WAVE summary configured=<N> dispatched=<n> refused=<n>` is the durable
   evidence the orchestrator's CAPA records cite — never a chat
   narrative.
6. **Actionable refusal.** Controller refusals include
   `next_action` (`operator_authorization_required`, `checks_required`,
   `review_required`, etc.) plus a dedupable `escalation` payload so an
   active drain creates or updates one blocker instead of stopping on
   an opaque observe refusal.

## Choosing a mode for a profile

```bash
# observe (default) — no opt-in needed
PR_OPS_MODE="observe"

# assist — agents prepare, operator merges
PR_OPS_MODE="assist"
PR_OPS_MODE_ALLOWED="assist"
ORDO_PR_OPS_REQUIRED_GATES_MERGE=(ci review docs)
ORDO_PR_OPS_REQUIRED_GATES_READY_FOR_REVIEW=(ci)

# automerge — controlled automation may merge when gates pass
PR_OPS_MODE="automerge"
PR_OPS_MODE_ALLOWED="assist,automerge"
ORDO_PR_OPS_REQUIRED_GATES_MERGE=(ci review docs)

# centralized — agents prepare, operator merges
PR_OPS_MODE="centralized"
PR_OPS_MODE_ALLOWED="centralized"
ORDO_PR_OPS_REQUIRED_GATES_MERGE=(ci review docs)
ORDO_PR_OPS_REQUIRED_GATES_READY_FOR_REVIEW=(ci)

# delegated — fleet remediates one PR per agent
PR_OPS_MODE="delegated"
PR_OPS_MODE_ALLOWED="centralized,delegated"

# autonomous — opt-in, profile-gated
PR_OPS_MODE="autonomous"
PR_OPS_MODE_ALLOWED="centralized,delegated,autonomous"
AUTO_PR_OPS_ENABLED=1
AUTO_PR_OPS_MODE="live"          # or "dry-run"
AUTO_PR_OPS_MERGE_STRATEGY="squash"
```

A profile may list more modes in `PR_OPS_MODE_ALLOWED` than its
default `PR_OPS_MODE`. The `ORDO_PR_OPS_MODE` env override can then
escalate within the allowlist; it cannot escalate beyond it.

## Negative invariants (guaranteed refusals)

* No mode merges a PR with `mergeable=UNKNOWN` or pending CI checks.
* No mode merges a PR whose required reviews are missing under the
  profile's policy.
* No mode upgrades from a chat prompt — autonomous mode requires
  `AUTO_PR_OPS_ENABLED=1` in the profile *plus* the kill switch
  released, and automerge mode requires `PR_OPS_MODE_ALLOWED` plus
  explicit gates from the caller.
* Agents never gain `pr_merge` scope through any rendered task; the
  external-PR-mutation gate refuses any widened scope.
* A profile that omits `PR_OPS_MODE_ALLOWED` cannot run any mode
  except `observe` regardless of `PR_OPS_MODE` or `ORDO_PR_OPS_MODE`.

## Running the modes

```bash
# Observe the queue
bash scripts/pr_ops_queue.sh <project-config> --json

# Assist/centralized: ask the controller whether the operator can merge PR 42
ORDO_PR_OPS_ACTOR=operator bash scripts/pr_ops_controller.sh \
  <project-config> merge 42 --gates ci,review

# Automerge: controlled automation may proceed only after all gates are passed
ORDO_PR_OPS_ACTOR=automation bash scripts/pr_ops_controller.sh \
  <project-config> merge 42 --gates ci,review,docs

# Delegated: render one task per available agent (dry-run by default)
bash scripts/dispatch_pr_ops.sh <project-config> --mode delegated --json
bash scripts/dispatch_pr_ops.sh <project-config> --mode delegated --apply

# Autonomous: evaluate gates for one PR, then optionally apply
bash scripts/autonomous_pr_ops.sh <project-config> evaluate 42
AUTO_PR_OPS_ENABLED=1 AUTO_PR_OPS_MODE=live bash scripts/autonomous_pr_ops.sh \
  <project-config> apply 42
```

Every mode supports `--dry-run` (or its equivalent default) so the
operator can preview the decision JSON before any mutation.

## Cross-mode test coverage

Per-mode test coverage already exists under `tests/`:

| Mode | Test file |
| --- | --- |
| Queue (#358) | `tests/test_pr_ops_queue.sh` |
| Delegated (#359) | `tests/test_dispatch_pr_ops.sh` |
| Centralized / assist / automerge (#360/#789) | `tests/pr_ops_centralized.bats` |
| Autonomous (#361) | `tests/autonomous_pr_ops.bats` |

The umbrella governance contract — the structural invariants in
"What every mode guarantees" above — is exercised by
`tests/test_pr_operations_governance.bats`.

## Related rules

* `docs/orchestrator-injected-rules.md` rule 11 — external PR
  mutation authority gate (refuses any agent-side merge request).
* `docs/orchestrator-injected-rules.md` rule 12 — PR operations modes
  (the per-mode behavioural contract).
* `docs/pr-ops-controller.md` — deeper-dive on the centralized mode.
