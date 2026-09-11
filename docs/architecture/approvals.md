# ORDO approval-safe actions

Audience: operator, developer. Category: developer docs / API reference.

`lib/ordo_approval.sh` (issue #812, epic #806) makes an external mutation
something a human grants once, for one action of one run, and that
deterministic code re-authorizes **immediately before** executing it. It
persists typed approval records in the journal, bridges the authorization to
the provider adapter with the approval's idempotency key, and records every
verdict as a `policy_decision` event. Traces come from
[tracing.md](tracing.md).

No model ever grants, executes or widens a policy. Live autonomous mutation
stays **off by default**: the provider adapter still asserts
`ORCH_EXTERNAL_PR_MUTATIONS` (`lib/external_mutation_gate.sh`), and an approval
never bypasses it — it adds a second, per-action, human gate on top.

## Where things live

| Path | Content |
| --- | --- |
| `lib/ordo_approval.sh` | The library: requests, grant/deny, sweep, the authorization bridge, policy version, principal allow-list. |
| `scripts/ordo_approve.sh` | Operator entry point (`request grant deny get list sweep authorize-and-run policy-version`); `ordo approve` routes here. |
| `lib/ordo_trace.sh` | Spans emitted by the bridge (`approval`, `policy`, `provider`). |
| `$(state_dir)/ordo-journal.sqlite` | Approval rows and every event below (see [journal.md](journal.md)). |
| `$(state_dir)/ordo-provider-idempotency.jsonl` | The provider ledger the bridge relies on for replay (see [adapters.md](adapters.md)). |
| `$(state_dir)/traces/<trace_id>.jsonl` | One trace per run (`trace_id = sha256(run_id)[0:32]`). |
| `tests/ordo_approval.bats` | 16 tests: request, decisions, model refusal, expiry, every bridge refusal, happy path, replay, gate authority, the operator script. |

## Lifecycle

An approval is a contract `approval` object ([contracts.md](contracts.md)):
`run_id`, `action`, `principal`, `policy_version`, `state`, `idempotency_key`,
`expires_at`, then `decided_at`, `decided_by`, `reason`, `result` once decided.

```
pending ──grant (operator|system)──▶ granted ──authorize_and_run──▶ consumed
   │                                    │
   ├──deny (operator|system|agent)──▶ denied
   └──sweep / expires_at reached─────▶ expired ◀────────────────────┘ (granted, past expires_at)
```

| Step | Function | Journal events | Notes |
| --- | --- | --- | --- |
| Request | `ordo_approval_request <run_id> <action> --principal P --idempotency-key K [--policy-version V] [--ttl S] [--payload JSON] [--actor JSON]` | `approval.requested`, `approval_bridge.requested` | The run must exist and not be terminal (4 / 5). `--policy-version` defaults to the current one; `--ttl` to `ORDO_APPROVAL_DEFAULT_TTL` (3600 s). `--payload` is redacted then pinned; `payload.args` (array) binds the exact provider arguments. |
| Grant | `ordo_approval_grant <approval_id> [--by ACTOR] [--reason R]` | `policy.decided` (allow), `approval.granted` | ACTOR must be of type `operator` or `system`; `model` and `agent` are refused with exit 3 and a deny decision. Refused when the policy version drifted since the request. An approval past `expires_at` is marked expired (exit 5). |
| Deny | `ordo_approval_deny <approval_id> [--by ACTOR] [--reason R]` | `approval.denied` | `operator`, `system` or `agent` (an agent may withdraw its own request); `model` is refused. |
| Sweep | `ordo_approval_sweep [--run-id R]` | `approval.expired` per approval | Pending and granted approvals with `expires_at <= now` become expired. Nothing sweeps automatically: run it from the supervisor loop or before `authorize_and_run`. The bridge and `grant` also expire what they touch. |
| Execute | `ordo_approval_authorize_and_run <approval_id> [--actor JSON] -- <provider op> [args...]` | `policy.decided`, `approval.consumed`, `approval_bridge.executed` | See the checklist below. |
| Inspect | `ordo_approval_get <approval_id>`, `ordo_approval_list <run_id> [--state S]` | — | Both merge the pinned `payload` into the object. |

`ACTOR` is a JSON actor object, `type:id`, or a bare id (an operator). Without
`--by`/`--actor` the actor is `ORDO_ACTOR`, else operator
`${ORDO_OPERATOR:-$USER}`.

## Re-authorization checklist (the bridge)

`ordo_approval_authorize_and_run` runs these checks in order, immediately
before execution, every time. The first failure records a `policy_decision`
with `decision=deny` and one reason, ends the trace spans in error and exits 3
(`policy_refused`, `details.reason` names the check):

| # | Check | `details.reason` |
| --- | --- | --- |
| 0 | The executing actor is `operator`, `system` or `agent` — never `model`. | `actor_type_not_allowed` |
| d | The run has a journal state and it is not terminal (unknown = fail-closed). | `run_unknown`, `run_terminal` |
| a | The approval is `granted`. | `approval_not_granted`, `approval_denied`, `approval_expired`, `approval_consumed` |
| a | `expires_at` is still in the future **now** (otherwise it is marked expired first). | `approval_expired` |
| b | `policy_version` equals `ordo_approval_policy_version` **now**. | `policy_version_drift` |
| e | The provider op is the approved action (`pr.merge` ≡ `pr_merge`) and is a mutating op; pinned `payload.args` equal the given arguments. | `action_mismatch`, `op_not_mutating`, `payload_mismatch` |
| c | The principal is allowed for the action (see below). | `principal_not_allowed` |

When every check passes the bridge records `policy.decided` with
`decision=allow` and reasons
`[actor_type_allowed, run_active, approval_granted, not_expired, policy_version_match, action_bound, principal_allowed]`,
then executes `ordo_provider <op> <args> --idempotency-key <approval key>`.
Passing your own `--idempotency-key` to the bridge is a usage error (exit 2).

A consumed approval that already holds a result short-circuits before the
checklist: the recorded receipt is printed with `details.replayed=true`,
nothing is re-checked, nothing is executed. Replay is a read.

## Idempotency and the mutation receipt

- Every mutation launched through the bridge carries the approval's
  `idempotency_key` — the same key the provider ledger deduplicates on. The
  key is chosen at request time (e.g. `merge-<repo>-<pr>`), never by the bridge.
- The approval is consumed **after** the receipt, in the same logical step:
  `approval.consumed` with `result = receipt` (redacted), then the mutation
  event `approval_bridge.executed` (`mutation=true`, `idempotency_key=K`). A
  receipt the provider replayed from its ledger (`details.replayed=true`, e.g.
  after a crash between mutation and consumption) consumes the approval too.
- A provider failure (including the gate refusing the scope, exit 3 from
  module `provider_adapter`) leaves the approval `granted`, journals
  `approval_bridge.execution_failed` with the redacted error, and returns the
  provider's exit code. The operator can scope the gate and run it again.
- `tests/ordo_approval.bats` proves the fake adapter's `mutations.jsonl` holds
  exactly one line after two `authorize_and_run` calls, and still one after a
  ledger hit.

## Policy version

`ordo_approval_policy_version` prints `ORDO_POLICY_VERSION` when set.
Otherwise it hashes what changes the verdict — `ORCH_EXTERNAL_PR_MUTATIONS`,
`ORDO_APPROVAL_PRINCIPALS`, the provider adapter name and the known gate
scopes — into `gate-<16 hex>`. Any edit to the mutation policy after a request
therefore refuses the grant, and any edit after the grant refuses execution.
Pin `ORDO_POLICY_VERSION` (for instance to a reviewed policy file's version)
when operators change the environment deliberately and want approvals to
survive.

## Principals and actors

`ORDO_APPROVAL_PRINCIPALS` is a comma-separated allow-list of
`principal[=action|action…]` entries; a bare principal allows every action;
`*` matches any principal:

```bash
export ORDO_APPROVAL_PRINCIPALS="eric=pr.merge|pr.ready,yan,*=issue.comment"
```

With an **empty** list the gate semantics decide: the provider op's mutation
scope (e.g. `pr_merge`) must be authorised in `ORCH_EXTERNAL_PR_MUTATIONS`.
The principal is who was asked to decide and is recorded on the approval; the
actor is who calls the function (`decided_by` on grant/deny/consume). Rules:

| Actor type | request | grant | deny | execute |
| --- | --- | --- | --- | --- |
| operator | yes | yes | yes | yes |
| system | yes | yes | yes | yes |
| agent | yes | **no** (exit 3) | yes | yes |
| model | yes | **no** (exit 3) | **no** (exit 3) | **no** (exit 3) |

Every refusal by actor type is journaled as a `policy_decision` deny with
reason `actor_type_not_allowed`.

## Enabling one scoped action (operator runbook)

Nothing mutates until an operator does all of the following, and each step is
narrow on purpose:

```bash
# 1. Scope the mutation gate to exactly the action (never "all").
export ORCH_EXTERNAL_PR_MUTATIONS="pr_merge"
# 2. Name who may approve what.
export ORDO_APPROVAL_PRINCIPALS="eric=pr.merge"
# 3. Ask for the approval from the run (an agent or the supervisor does this).
bash scripts/ordo_approve.sh myproj request run_<id> pr.merge --principal eric \
  --idempotency-key merge-acme-widgets-42 --ttl 900 \
  --payload '{"args":["42","--method","squash"]}'
# 4. Grant it (the CLI form; --by defaults to $USER as an operator).
ordo approve myproj approval_<id> --by eric --reason "CI green, reviewed"
# 5. Execute through the bridge — re-authorized now, idempotent, journaled, traced.
bash scripts/ordo_approve.sh myproj authorize-and-run approval_<id> --json -- pr_merge 42 --method squash
```

`ordo approve --list myproj run_<id>` shows the approvals of a run;
`ordo approve --deny myproj approval_<id> --reason "…"` denies one;
`bash scripts/ordo_approve.sh myproj sweep` expires stale ones. Unset
`ORCH_EXTERNAL_PR_MUTATIONS` afterwards; granted approvals then refuse at the
gate (exit 3 from the provider adapter) without consuming.

## Errors and exit codes

One JSON line on stderr, module `approval` (`journal` / `provider_adapter` /
`contracts` when the failure comes from those layers):

| Exit | `error.code` | When |
| --- | --- | --- |
| 2 | `usage`, `bad_argument` | Missing `--principal`/`--idempotency-key`, malformed id or actor, `--idempotency-key` passed to the bridge, no op after `--`. |
| 3 | `policy_refused` | Any checklist failure or actor-type refusal (`details.reason`, `details.policy_decision_id`); the gate refusing the scope (module `provider_adapter`). |
| 4 | `not_found` | Unknown approval; unknown run at request time (module `journal`). |
| 5 | `invalid_state`, `conflict`, `invalid_json` | Grant/deny on a non-pending approval, expired at grant, terminal run at request, duplicate idempotency key (module `journal`), non-object payload. |
| 6 | `provider_not_available` | The selected provider adapter is a stub (module `provider_adapter`). |

## Interaction with the scheduler (#810) and the evaluation harness (#813)

- A run parked in `approval_required` by `ordo_scheduler_require_approval`
  holds no lease; the approval is requested against that run id, and the
  operator resumes it (`ordo resume`) once the bridge consumed the approval.
  The bridge refuses terminal runs, so cancelling a run also voids its
  approvals at execution time (sweep them for tidiness).
- `ORDO_JOURNAL_NOW` pins the clock for both modules; the fake provider adapter
  (`ORDO_PROVIDER_ADAPTER=fake`, `ORDO_FAKE_ADAPTER_DIR`) makes the whole
  request → grant → execute path runnable with no forge.
