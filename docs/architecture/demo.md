# Zero-credential local demo

Audience: user, developer, operator. Category: usage / developer docs
(see [README.md → 3. Usage](README.md#3-usage)).

Epic [#806](https://github.com/decarvalhoe/ORDO/issues/806), child
[#814](https://github.com/decarvalhoe/ORDO/issues/814). This page walks a
newcomer through the agentic control plane on a fresh clone with **no forge
account, no token, no tmux and no network**: only `bash`, `jq` and `python3`
(its stdlib `sqlite3` module backs the journal). Every command below was
executed as written and its output pasted (trimmed where noted);
`tests/docs_demo_path.bats` re-runs them non-interactively and asserts the
key outputs, so this page cannot drift from the code.

Two halves:

1. **The evaluation demo** — `scripts/ordo_eval.sh` replays scripted
   scenarios in a fake world and scores the trajectories. Nothing to
   configure.
2. **The live journal** — the same modules driven by hand through
   `scripts/ordo_scheduler.sh`, `scripts/ordo_approve.sh` and the `ordo`
   CLI against a demo profile whose forge and runtime are fakes, so you can
   inspect the journal, see a refused mutation next to an approved one, and
   read a trace export.

Ids (`run_…`, `approval_…`, trace ids) and wall-clock timestamps differ on
your machine; the pinned-clock timestamps, states, counts and exit codes do
not.

## 0. Prerequisites

```bash
cd <ordo-checkout>
bash --version | head -1 && jq --version && python3 -c 'import sqlite3, sys; print("python", sys.version.split()[0], "sqlite", sqlite3.sqlite_version)'
```

```
GNU bash, version 5.2.37(1)-release (x86_64-pc-linux-gnu)
jq-1.7
python 3.13.5 sqlite 3.46.1
```

`gh`, `curl`, `ssh` and `tmux` may be absent; the evaluation sandbox even
puts guard stubs first on `PATH` that refuse them and fails the run closed
(exit 3) if anything tries.

## 1. The evaluation demo

### 1.1 List the scenarios

```bash
bash scripts/ordo_eval.sh list
```

```
<TK>/tests/fixtures/eval/demo/blocked_run.json
<TK>/tests/fixtures/eval/demo/budget_exhausted.json
<TK>/tests/fixtures/eval/demo/issue_triage.json
<TK>/tests/fixtures/eval/demo/pr_merge_approval.json
<TK>/tests/fixtures/eval/failures/approval_expiry.json
<TK>/tests/fixtures/eval/failures/duplicate_delivery.json
<TK>/tests/fixtures/eval/failures/network_timeout.json
<TK>/tests/fixtures/eval/failures/process_crash.json
<TK>/tests/fixtures/eval/failures/provider_outage.json
<TK>/tests/fixtures/eval/failures/stale_lease.json
```

Four demo scenarios (the baseline workload) and six failure injections
(`<TK>` is your checkout path). What each one proves is tabulated in
[evaluation.md → Scenarios](evaluation.md#scenarios).

### 1.2 Run the demo workload against the committed baseline

```bash
bash scripts/ordo_eval.sh demo
```

```
baseline check: PASS (0 regression(s))
  blocked_run: ok
  budget_exhausted: ok
  issue_triage: ok
  pr_merge_approval: ok
```

About 13 s on a laptop. Each scenario ran in its own sandbox (fake
provider, fake runtime, pinned clock), was scored on the six dimensions
(completion, policy compliance, evidence completeness, cost, latency,
duplicate-side-effect resistance) and compared with
`tests/fixtures/eval/demo/baseline.json`. Exit 1 with a diff on any
regression.

### 1.3 Keep one trajectory and read it

```bash
export DEMO=$(mktemp -d)
bash scripts/ordo_eval.sh run tests/fixtures/eval/demo/pr_merge_approval.json --out "$DEMO/traj"
```

```
trajectory: <DEMO>/traj (20 steps, clock 2026-09-11T10:00:00Z -> 2026-09-11T10:04:00Z)
scenario pr_merge_approval: PASS
  completion: pass
  cost: pass
  duplicate_side_effects: pass
  evidence_completeness: pass
  latency: pass
  policy_compliance: pass
  metrics: mutations=1 unapproved=0 refused=0 repeated_keys=0 deliveries=1 events=27 spans=8 elapsed=240s tokens=1500 attempts=1
```

The trajectory directory is the whole story of the run, normalised so two
runs are byte-identical ([evaluation.md → Trajectory directory](evaluation.md#trajectory-directory)):

```bash
ls "$DEMO/traj"
```

```
approvals.jsonl  artifacts.jsonl  events.jsonl  evidence  idmap.json  leases.jsonl  ledger.jsonl
mutations.jsonl  runs.json  runtime_events.jsonl  scenario.json  steps.jsonl  summary.json  traces.jsonl
```

**The journal** — every event of the run, in `run_seq` order, with the
actor type that produced it:

```bash
jq -r '[.run_seq, .type, .actor.type] | @tsv' "$DEMO/traj/events.jsonl"
```

```
1	run.created	operator
2	lease.acquired	agent
3	run.leased	agent
4	run.started	agent
5	attempt.started	agent
6	provider.read	agent
7	provider.read	agent
8	provider.read	agent
9	lease.renewed	agent
10	run.budget	agent
11	artifact.recorded	agent
12	lease.released	agent
13	run.approval_required	agent
14	approval.requested	agent
15	approval_bridge.requested	agent
16	policy.decided	operator
17	approval.granted	operator
18	policy.decided	operator
19	approval.consumed	operator
20	approval_bridge.executed	operator
21	lease.acquired	operator
22	run.resumed	operator
23	provider.read	agent
24	lease.renewed	agent
25	run.budget	agent
26	lease.released	agent
27	run.succeeded	agent
```

Read it against [state-machine.md](state-machine.md): the agent parks the
run (`lease.released`, `run.approval_required` — no worker slot held), an
**operator** decides (`policy.decided`, `approval.granted`), the bridge
re-decides right before executing (`policy.decided` again) and journals the
mutation (`approval_bridge.executed`), then the run is resumed and completes.

**The projection** — the state folded from those events:

```bash
jq -c '.[] | {state, terminal, transitions: [.transitions[] | "\(.from)->\(.to)"], tokens_used: .budgets.tokens_used}' "$DEMO/traj/runs.json"
```

```
{"state":"succeeded","terminal":true,"transitions":["queued->leased","leased->running","running->approval_required","approval_required->running","running->succeeded"],"tokens_used":1500}
```

**The side effect** — exactly one mutation reached the (fake) forge, and
the idempotency ledger holds its receipt:

```bash
cat "$DEMO/traj/mutations.jsonl"
jq -c '{idempotency_key, op, replayed: .receipt.details.replayed}' "$DEMO/traj/ledger.jsonl"
```

```
{"ts":"2026-09-11T10:03:30Z","op":"pr_merge","adapter":"fake","repo":"acme/widgets","idempotency_key":"merge-acme-widgets-12","scope":"pr_merge","number":12,"result":{"number":12,"merged":true,"action":"merged","method":"squash","admin":false}}
{"idempotency_key":"merge-acme-widgets-12","op":"pr_merge","replayed":false}
```

**The trace** — the folded spans of the run (`traces.jsonl`; the OTLP
export is shown in the live half below):

```bash
jq -r '[.name, .kind, .status.code] | @tsv' "$DEMO/traj/traces.jsonl"
```

```
runtime.start	tool	OK
provider.pr_get	provider	OK
provider.checks_get	provider	OK
provider.review_list	provider	OK
approval.authorize	approval	OK
policy.reauthorize	policy	OK
provider.pr_merge	provider	OK
provider.pr_get	provider	OK
```

### 1.4 A refused mutation next to an approved one

`approval_expiry` grants an approval with a 600 s TTL, advances the clock
601 s and tries to execute:

```bash
bash scripts/ordo_eval.sh run tests/fixtures/eval/failures/approval_expiry.json --out "$DEMO/expiry"
jq -c 'select(.op == "execute") | {op, rc, idempotency_key, error: .error.error.code, reason: .error.error.details.reason}' "$DEMO/expiry/steps.jsonl"
wc -l < "$DEMO/expiry/mutations.jsonl"
jq -c 'select(.type == "policy.decided") | {run_seq, decision: .payload.decision, reasons: .payload.reasons}' "$DEMO/expiry/events.jsonl"
```

```
trajectory: <DEMO>/expiry (9 steps, clock 2026-09-11T10:00:00Z -> 2026-09-11T10:10:01Z)
scenario approval_expiry: PASS
  ...
  metrics: mutations=0 unapproved=0 refused=1 repeated_keys=0 deliveries=1 events=13 spans=2 elapsed=601s tokens=0 attempts=1
{"op":"execute","rc":3,"idempotency_key":"merge-acme-widgets-12","error":"policy_refused","reason":"approval_expired"}
0
{"run_seq":10,"decision":"allow","reasons":["actor_type_allowed","approval_pending","policy_version_match"]}
{"run_seq":13,"decision":"deny","reasons":["approval_expired"]}
```

The scenario *passes* because refusing is the expected behaviour: exit 3,
zero mutations, and the deny is journaled as a `policy_decision`. Compare
with `pr_merge_approval` above (`refused=0`, `mutations=1`): same approval
key, same op — the only difference is that the bridge found the grant still
valid when it re-checked.

`duplicate_delivery` shows the other half of replay safety — three
deliveries of one approved mutation, one execution:

```bash
bash scripts/ordo_eval.sh run tests/fixtures/eval/failures/duplicate_delivery.json --out "$DEMO/dup" --json \
  | jq -c '{pass: .score.pass, m: (.score.metrics | {mutations_executed, deliveries, replayed_deliveries, repeated_keys})}'
```

```
{"pass":true,"m":{"mutations_executed":1,"deliveries":3,"replayed_deliveries":2,"repeated_keys":0}}
```

### 1.5 Score a trajectory on its own

```bash
bash scripts/ordo_eval.sh score "$DEMO/traj" tests/fixtures/eval/demo/pr_merge_approval.expected.json
```

```
scenario pr_merge_approval: PASS
  completion: pass
  ...
  metrics: mutations=1 unapproved=0 refused=0 repeated_keys=0 deliveries=1 events=27 spans=8 elapsed=240s tokens=1500 attempts=1
```

## 2. The live journal, by hand

`examples/demo/demo.config.sh` is a project profile whose forge and runtime
are the fake adapters and whose state lives under `ORDO_DEMO_DIR`. It is a
demo profile, not a template for a live one (that is
`examples/ordo.config.sh` plus an external `ORDO_PROJECT_PROFILE`).

### 2.1 Seed the fake forge and pin the clock

```bash
export ORDO_DEMO_DIR=$(mktemp -d)
cp -r tests/fixtures/adapters/fake "$ORDO_DEMO_DIR/fake"     # repo acme/widgets, PRs #12-#16, issue #7
export ORDO_JOURNAL_NOW=2026-09-11T10:00:00Z                  # optional: pins every journal timestamp
CFG=examples/demo/demo.config.sh
```

### 2.2 Enqueue a run and let the scheduler pick it

```bash
bash scripts/ordo_scheduler.sh $CFG enqueue --title "Merge PR 12 once CI is green" --ticket 'acme/widgets#12' --json
```

```
AUDIT LOG: 2026-09-11T17:40:30Z SCHEDULER ENQUEUED run=run_f451590ccad679e8c7f469a4 priority=100 ticket=acme/widgets#12
{"run_id":"run_f451590ccad679e8c7f469a4","state":"queued","title":"Merge PR 12 once CI is green","ticket_ref":"acme/widgets#12","priority":100,"not_before":null,"expires_at":null,"budgets":{"max_attempts":4,"max_seconds":14400,"max_tokens":5000000,"max_turns":200,"max_tool_calls":2000,"max_cost":0,"attempts_used":0,...,"exhausted":[]}}
```

The `AUDIT LOG:` line goes to stderr (it is also appended to
`$ORDO_DEMO_DIR/log/ordo-demo.log`); the JSON is stdout. Keep the id:

```bash
RUN=run_f451590ccad679e8c7f469a4        # yours differs
bash scripts/ordo_scheduler.sh $CFG tick --json
bash scripts/ordo_scheduler.sh $CFG status "$RUN"
```

```
{"now":"2026-09-11T10:00:00Z","worker":"demo@<host>:<pid>","max_fanout":2,"expired_leases":[],"requeued":[],"failed":[],"expired":[],"timed_out":[],"heartbeats":[],"picked":[{"run_id":"run_f451590ccad679e8c7f469a4","state":"running","lease_id":"lease_5a25a6a90f26917b4bef799c","owner":"demo@<host>:<pid>","attempt_no":1,"resumed":false,"priority":100}],"skipped":[],"errors":[],"slots_used_before":0,"capacity":2,"picks":1}
run_f451590ccad679e8c7f469a4 running prio=100 attempts=1 ready=true (ready) lease=demo@<host>:<pid> exhausted=-
```

One tick: the run went `queued -> leased -> running` under a lease owned by
`demo@<host>:<pid>` (the runtime adapter is fake, so no pane was touched).

### 2.3 Request an approval; watch a model get refused

```bash
bash scripts/ordo_approve.sh $CFG request "$RUN" pr.merge --principal demo-operator \
  --idempotency-key "demo:pr.merge:12" --payload '{"args":["12","--method","squash"]}' --json
```

```
{"action":"pr.merge","actor":{"id":"demo-operator","type":"operator"},"correlation_id":"run_f451590ccad679e8c7f469a4","created_at":"2026-09-11T10:00:00Z","expires_at":"2026-09-11T11:00:00Z","id":"approval_4f7248dbf7aefd3a7b4f0237","idempotency_key":"demo:pr.merge:12","kind":"approval","policy_version":"demo-policy-v1","principal":"demo-operator","run_id":"run_f451590ccad679e8c7f469a4","schema_version":"1","state":"pending","payload":{"args":["12","--method","squash"]}}
```

```bash
APPROVAL=approval_4f7248dbf7aefd3a7b4f0237   # yours differs
bash scripts/ordo.sh approve $CFG "$APPROVAL" --by model:planner --json; echo "rc=$?"
```

```
{"error":{"code":"policy_refused","message":"an actor of type 'model' may not grant approvals (allowed: operator|system); models never decide","module":"approval","details":{"actor":{"type":"model","id":"planner"},"actor_type":"model","allowed_types":["operator","system"],"reason":"actor_type_not_allowed","approval_id":"approval_4f7248dbf7aefd3a7b4f0237","run_id":"run_f451590ccad679e8c7f469a4","decision":"deny","policy_decision_id":"policy_decision_9d54c006118644e76791218b"}}}
rc=3
```

An operator may:

```bash
bash scripts/ordo.sh approve $CFG "$APPROVAL" --by demo-operator --reason "CI green, reviewed" --json | jq -c '{state, decided_by, reason}'
```

```
{"state":"granted","decided_by":{"id":"demo-operator","type":"operator"},"reason":"CI green, reviewed"}
```

### 2.4 Refused mutation, approved mutation, replayed mutation

The approval is granted, but live mutation is **off by default**: the
external mutation gate (`ORCH_EXTERNAL_PR_MUTATIONS`, empty) refuses the
`pr_merge` scope before the fake forge is called. The approval stays
`granted`:

```bash
bash scripts/ordo_approve.sh $CFG authorize-and-run "$APPROVAL" --json -- pr_merge 12 --method squash; echo "rc=$?"
```

```
{"error":{"code":"policy_refused","message":"mutation pr_merge (scope pr_merge) refused by the external mutation policy","module":"provider_adapter","details":{"op":"pr_merge","scope":"pr_merge","gate_exit":80,"context":"provider_adapter:fake:pr_merge:acme/widgets#12","authorize_via":"ORCH_EXTERNAL_PR_MUTATIONS","retryable":false,"adapter":"fake"}}}
rc=3
```

Scope the gate to exactly that action and run the same command: the bridge
re-checks everything, executes once with the approval's idempotency key,
and consumes the approval:

```bash
ORCH_EXTERNAL_PR_MUTATIONS=pr_merge bash scripts/ordo_approve.sh $CFG authorize-and-run "$APPROVAL" --json -- pr_merge 12 --method squash; echo "rc=$?"
```

```
{"op":"pr_merge","adapter":"fake","repo":"acme/widgets","details":{"idempotency_key":"demo:pr.merge:12","replayed":false,"scope":"pr_merge","recorded_at":"2026-09-11T17:40:32Z","approval_id":"approval_4f7248dbf7aefd3a7b4f0237"},"result":{"number":12,"merged":true,"action":"merged","method":"squash","admin":false},"approval_id":"approval_4f7248dbf7aefd3a7b4f0237"}
rc=0
```

Run it a third time — a consumed approval with a receipt short-circuits
before the checklist; nothing is executed:

```bash
ORCH_EXTERNAL_PR_MUTATIONS=pr_merge bash scripts/ordo_approve.sh $CFG authorize-and-run "$APPROVAL" --json -- pr_merge 12 --method squash | jq -c '.details | {replayed, idempotency_key}'
wc -l < "$ORDO_DEMO_DIR/fake/mutations.jsonl"
bash scripts/ordo.sh approve --list $CFG "$RUN"
```

```
{"replayed":true,"idempotency_key":"demo:pr.merge:12"}
1
approval_4f7248dbf7aefd3a7b4f0237 consumed action=pr.merge principal=demo-operator policy=demo-policy-v1 expires=2026-09-11T11:00:00Z
```

Three deliveries, one line in the fake forge's mutation log. The audit log
recorded both gate decisions:

```bash
grep EXTERNAL_PR_MUTATION "$ORDO_DEMO_DIR/log/ordo-demo.log"
```

```
AUDIT LOG: 2026-09-11T17:40:31Z EXTERNAL_PR_MUTATION action=pr_merge mode=refused context=provider_adapter:fake:pr_merge:acme/widgets#12
AUDIT LOG: 2026-09-11T17:40:32Z EXTERNAL_PR_MUTATION action=pr_merge mode=allowed context=provider_adapter:fake:pr_merge:acme/widgets#12
```

### 2.5 Inspect the journal

The journal functions are bash; source the libraries in a subshell so the
profile's `PROJECT` and state directory apply:

```bash
( source $CFG; source lib/audit_log.sh; source lib/state_persist.sh; source lib/ordo_journal.sh
  ordo_journal_events "$RUN" | jq -r '[.run_seq, .type, .actor.type, (.mutation|tostring)] | @tsv' )
```

```
1	run.created	operator	false
2	lease.acquired	system	false
3	run.leased	system	false
4	run.started	system	false
5	attempt.started	system	false
6	approval.requested	operator	false
7	approval_bridge.requested	operator	false
8	policy.decided	model	false
9	policy.decided	operator	false
10	approval.granted	operator	false
11	policy.decided	operator	false
12	approval_bridge.execution_failed	operator	false
13	policy.decided	operator	false
14	approval.consumed	operator	false
15	approval_bridge.executed	operator	true
```

Event 8 is the model's refused grant (a `policy_decision` deny, actor
`model`), event 12 the gate refusal, event 15 the one mutation
(`mutation=true`, carrying the idempotency key). The projection:

```bash
( source $CFG; source lib/audit_log.sh; source lib/state_persist.sh; source lib/ordo_journal.sh
  ordo_journal_project "$RUN" | jq -c '{state, terminal, transitions: [.transitions[] | "\(.from)->\(.to)"], approval, counters: {events: .counters.events, mutations: .counters.mutations}}' )
```

```
{"state":"running","terminal":false,"transitions":["queued->leased","leased->running"],"approval":{"action":"pr.merge","id":"approval_4f7248dbf7aefd3a7b4f0237","state":"consumed"},"counters":{"events":15,"mutations":1}}
```

The compatibility export writes the legacy state files the existing scripts
read (`ordo-runs/<run>.json`; `assignments.json` only for runs that carry a
dispatched agent — this one does not, so `action=none`):

```bash
( source $CFG; source lib/audit_log.sh; source lib/state_persist.sh; source lib/ordo_journal.sh
  ordo_journal_compat_export "$RUN" 2>/dev/null )
ls "$ORDO_DEMO_DIR/state/ordo-demo"
```

```
{"run_id":"run_f451590ccad679e8c7f469a4","state":"running","files":["<ORDO_DEMO_DIR>/state/ordo-demo/ordo-runs/run_f451590ccad679e8c7f469a4.json"],"assignment":{"agent":null,"action":"none"}}
ordo-journal.sqlite  ordo-provider-idempotency.jsonl  ordo-runs  traces
```

### 2.6 Read a trace export

One run is one trace (`trace_id = sha256(run_id)[0:32]`). The export is an
OTLP/JSON `ResourceSpans` document you could POST to any collector:

```bash
( source $CFG; source lib/audit_log.sh; source lib/ordo_trace.sh
  T=$(ordo_trace_new_id trace "$RUN")
  ordo_trace_export "$T" | jq -c '.resourceSpans[0].scopeSpans[0].spans[] | {name, kind, status: .status.code, child: (.parentSpanId != "")}'
  ordo_trace_export "$T" | jq -c '.resourceSpans[0].resource.attributes | map({(.key): .value.stringValue}) | add' )
```

```
{"name":"approval.authorize","kind":1,"status":1,"child":false}
{"name":"approval.authorize","kind":1,"status":1,"child":false}
{"name":"approval.authorize","kind":1,"status":2,"child":false}
{"name":"policy.reauthorize","kind":1,"status":1,"child":true}
{"name":"policy.reauthorize","kind":1,"status":1,"child":true}
{"name":"provider.pr_merge","kind":3,"status":1,"child":true}
{"name":"provider.pr_merge","kind":3,"status":2,"child":true}
{"service.name":"ordo","ordo.project":"ordo-demo","ordo.run_id":"run_f451590ccad679e8c7f469a4"}
```

Three `approval.authorize` roots (refused, executed, replayed); the refused
one ends `status 2` (ERROR) with its `provider.pr_merge` child; `kind 3` is
OTLP `CLIENT` for provider calls. Every attribute went through redaction
before it was written ([tracing.md](tracing.md)).

### 2.7 Cancel, and see the state machine refuse

```bash
bash scripts/ordo.sh cancel $CFG "$RUN" --reason "demo over" --json; echo "rc=$?"
bash scripts/ordo.sh cancel $CFG "$RUN" --json; echo "rc=$?"
bash scripts/ordo_scheduler.sh $CFG status --json | jq -c '{capacity, counts}'
```

```
{"run_id":"run_f451590ccad679e8c7f469a4","state":"cancelled","from":"running","reason":"demo over","released_lease_id":"lease_5a25a6a90f26917b4bef799c","lease":null}
rc=0
{"error":{"code":"invalid_transition","message":"run run_f451590ccad679e8c7f469a4 is already terminal (cancelled); cancel is not allowed","module":"scheduler","details":{"run_id":"run_f451590ccad679e8c7f469a4","from":"cancelled","to":"cancelled","terminal":true}}}
rc=5
{"capacity":{"max_fanout":2,"in_use":0,"available":2},"counts":{"cancelled":1}}
```

### 2.8 Clean up

```bash
rm -rf "$DEMO" "$ORDO_DEMO_DIR"; unset DEMO ORDO_DEMO_DIR ORDO_JOURNAL_NOW
```

Nothing was written outside those two directories: the profile pins
`ORCH_STATE_BASE` and `ORCH_LOG_DIR` under `ORDO_DEMO_DIR`.

## What the guard test asserts

`tests/docs_demo_path.bats` runs both halves with a decoy `gh` on `PATH`
that fails loudly if invoked, and asserts: the ten scenarios are listed;
`demo` passes with zero regressions; the kept `pr_merge_approval`
trajectory ends `succeeded` with one mutation, a `provider.pr_merge` span and
a passing score; `approval_expiry` refuses with `policy_refused` /
`approval_expired` and zero mutations; and, on the live journal, the model
grant exits 3, the unscoped execution exits 3 from the gate, the scoped one
returns a receipt, the replay reports `replayed=true` with one recorded
mutation, the journal holds exactly one `mutation=true` event, the compat
export writes `ordo-runs/<run>.json`, the trace export contains the
`provider.pr_merge` span, cancel succeeds once and is refused the second
time with exit 5. Run it with `bats tests/docs_demo_path.bats`.

## Where to go next

- [overview.md](overview.md) — how the pieces you just touched fit together.
- [state-machine.md](state-machine.md) — every state and event you saw.
- [approvals.md → Enabling one scoped action](approvals.md#enabling-one-scoped-action-operator-runbook)
  — the same flow on a real forge.
- [migration.md](migration.md) — turning the pieces on in an existing deployment, and off again.
