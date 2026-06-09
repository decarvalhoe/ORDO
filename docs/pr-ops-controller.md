# PR Operations Controller

`scripts/pr_ops_controller.sh` is the universal authorization gate for
PR-mutating actions. It implements the centralized / assist PR
operations contract and emits actionable machine-readable decisions
for live drains.

## Design

The controller is a **policy engine**, not a mutation engine. Given a
project config, an action, and a PR number, it returns a structured
JSON decision and a typed exit code. The caller decides whether to
proceed with the underlying `gh` / `git` mutation. This separation
keeps every mode auditable and reversible.

### Modes

The effective mode comes from the project / portfolio profile, with an
explicit session override available for operator runs:

| Mode          | Default | Source                   | Final mutations           |
| ------------- | ------- | ------------------------ | ------------------------- |
| `observe`     | yes     | `PR_OPS_MODE` in profile | always refused            |
| `assist`      |         | `PR_OPS_MODE` in profile | operator + gates required |
| `automerge`   |         | `PR_OPS_MODE` in profile | operator/automation + gates required |
| `centralized` |         | `PR_OPS_MODE` in profile | operator + gates required |
| `delegated`   |         | reserved (#361)          | refused by this PR        |
| `autonomous`  |         | reserved (#362)          | refused by this PR        |

The session-level `ORDO_PR_OPS_MODE` env var overrides the profile
setting for one run. There is no implicit promotion from `observe` to
any higher mode. Any non-`observe` mode must be listed in
`PR_OPS_MODE_ALLOWED`; otherwise the controller refuses with
`next_action=operator_authorization_required` and an escalation
payload instead of silently stopping the drain.

### Actions

| Class         | Actions                                                              |
| ------------- | -------------------------------------------------------------------- |
| **Final**     | `merge`, `ready-for-review`, `rerun`, `close`, `branch-delete`       |
| **Preparation** | `prepare-fix`, `evidence-record`, `comment-audit-only`, `report-status` |

Preparation actions are **always allowed**, in every mode, for every
actor. This is the explicit "centralized mode coexists with delegated
remediation" contract from issue #360 — agents can keep gathering
evidence and preparing fixes while only the operator owns the final
mutation.

### Actors

The controller distinguishes two actors:

- `operator` — the central orch pane, set via `ORDO_PR_OPS_ACTOR=operator`
  (typically by a wrapper script the operator runs locally).
- `automation` — controlled automation running under an explicit
  `automerge` profile.
- `agent` — anything else; this is the safe default.

There is no implicit promotion: an agent never silently becomes the
operator. The operator pane must export `ORDO_PR_OPS_ACTOR=operator`
(or pass `--actor operator` to the controller) explicitly.

### Required gates

Final actions require a list of gates to be satisfied. The list is
profile-driven:

```bash
# Project profile
PR_OPS_MODE="assist"
PR_OPS_MODE_ALLOWED="assist,automerge"
ORDO_PR_OPS_REQUIRED_GATES_MERGE=(ci review docs gxp)
ORDO_PR_OPS_REQUIRED_GATES_READY_FOR_REVIEW=(ci)
```

Defaults:

| Action             | Default required gates |
| ------------------ | ---------------------- |
| `merge`            | `ci`, `review`         |
| `ready-for-review` | `ci`                   |
| `rerun`            | (none)                 |
| `close`            | (none)                 |
| `branch-delete`    | (none)                 |

The caller is responsible for verifying the gates and passing the
result via `--gates ci,review,docs`. The controller compares the
caller-supplied passed list against the required list — any required
gate not in the passed list yields a refusal with exit code `91`.

### Operator override

When a portfolio explicitly enables it, the operator may bypass the
gate check via an `--override <reason>` flag:

```bash
PR_OPS_MODE="centralized"
PR_OPS_MODE_ALLOWED="centralized"
ORDO_PR_OPS_OVERRIDE_ENABLED=1
```

The override **must carry a reason string**. The reason is recorded
in the audit log and the optional ledger so a later review can
reconstruct exactly who bypassed which gate and why. Profiles that
do not set `ORDO_PR_OPS_OVERRIDE_ENABLED=1` reject every override
attempt with exit code `92`, regardless of the actor.

## Operator workflow

```bash
# 1. Operator pane: set actor identity once per session.
export ORDO_PR_OPS_ACTOR=operator

# 2. Verify gates (or compute them upstream and pass the result).
gh pr checks 42 --repo example/foo

# 3. Authorize the mutation.
bash scripts/pr_ops_controller.sh \
  examples/foo.config.sh \
  merge 42 \
  --gates ci,review \
  --ledger "$ORCH_STATE_BASE/foo/pr_ops_ledger.json"

# 4. Inspect the decision (echoed to stdout as one-line JSON).
#    {"action":"merge","mode":"centralized","actor":"operator",...,
#     "decision":"allowed","reason":"operator_authorized","pr":"42",...}

# 5. On allowed, perform the actual mutation (gh pr merge ...). The
#    controller never invokes gh itself — that stays explicit so a
#    forced exit between steps 4 and 5 leaves no half-finished state.
```

For an emergency hotfix that bypasses the gate check (allowed only
when the profile sets `ORDO_PR_OPS_OVERRIDE_ENABLED=1`):

```bash
export ORDO_PR_OPS_ACTOR=operator
bash scripts/pr_ops_controller.sh examples/foo.config.sh merge 42 \
  --override "hotfix-cve-2026-001" \
  --ledger "$ORCH_STATE_BASE/foo/pr_ops_ledger.json"
```

## Decision payload

Every invocation prints exactly one line of JSON to stdout:

```json
{
  "action": "merge",
  "mode": "centralized",
  "actor": "operator",
  "required_gates": ["ci", "review"],
  "passed_gates": ["ci", "review"],
  "override_reason": null,
  "decision": "allowed",
  "reason": "operator_authorized",
  "next_action": "merge_allowed",
  "policy": {
    "source": "profile:PR_OPS_MODE",
    "explicit": true,
    "allowed_modes": ["centralized"]
  },
  "escalation": null,
  "pr": "42",
  "project": "foo",
  "decided_at": "2026-05-08T13:50:12Z"
}
```

Refused decisions carry a non-null `escalation` object with
`kind=issue_blocker`, `expected_action`, refusal evidence, and a
controller-generated `dedupe_key` after project / PR augmentation. This
is the handoff surface the orchestrator can use to create or update a
single blocker issue for repeated policy refusals.

`next_action` is the machine-readable controller decision for the
caller. Current values include:

| `next_action` | Meaning |
| ------------- | ------- |
| `merge_allowed` | The controlled merge path may proceed. |
| `operator_authorization_required` | An operator must authorize policy or actor scope. |
| `checks_required` | Required check / CI gates are missing. |
| `review_required` | Required review gates are missing. |
| `gates_required` | A non-CI/non-review required gate is missing. |
| `continue_preparation` | A preparation action may continue. |

Reason codes are stable kebab strings:

| `decision` | `reason`                                  | Exit |
| ---------- | ----------------------------------------- | ---- |
| `allowed`  | `preparation_action`                      | 0    |
| `allowed`  | `operator_authorized`                     | 0    |
| `allowed`  | `automerge_authorized`                    | 0    |
| `allowed`  | `operator_override`                       | 0    |
| `refused`  | `unknown_action`                          | 2    |
| `refused`  | `observe_mode_refuses_final_mutation`     | 90   |
| `refused`  | `assist_mode_agent_actor`                 | 90   |
| `refused`  | `automerge_mode_agent_actor`              | 90   |
| `refused`  | `centralized_mode_agent_actor`            | 90   |
| `refused`  | `mode_not_authorized`                     | 90   |
| `refused`  | `mode_<delegated\|autonomous>_not_implemented_in_pr_360` | 90 |
| `refused`  | `missing_required_gate`                   | 91   |
| `refused`  | `override_disabled`                       | 92   |

Exit codes 90/91/92 are reserved for this controller and do not
overlap with the existing 75–79 ORDO operational refusal band or
the 80-line dispatch-matrix-gate codes; a follow-up will register
them in `docs/exit-codes.md`.

## Audit + ledger

Every decision emits an `AUDIT LOG` line via `lib/audit_log.sh`:

```text
AUDIT LOG: 2026-05-08T13:50:12Z PR_OPS_CONTROLLER project=foo
  action=merge pr=#42 mode=centralized actor=operator
  decision=allowed reason=operator_authorized
```

When `--ledger <path>` is supplied (or `ORDO_PR_OPS_LEDGER_PATH`
points to a path), the augmented decision payload is appended to a
JSON-array ledger so audit consumers see the full sequence of
authorizations across a wave.

## Universal contract

The controller is profile-driven by construction:

- no agent CLI vendor (Claude / codex / copilot / future) is named;
- no project name is hardcoded;
- the actor identity is supplied by the caller via env, never inferred;
- the gate list is per-project via bash arrays.

The bats fixture `tests/pr_ops_centralized.bats` covers unset,
observe, assist, centralized, and automerge profile decisions and
demonstrates that the same controller produces different decisions
based purely on profile contents.
