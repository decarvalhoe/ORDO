# ORDO trajectory evaluation and failure injection

Audience: developer, operator. Category: developer docs / API reference.

`lib/ordo_eval.sh` (issue #813, epic #806) runs scripted scenarios against
the agentic control plane in a fully fake world and scores the resulting
trajectories. It exercises the real modules — the scheduler
([scheduler.md](scheduler.md)), the journal ([journal.md](journal.md)), the
approval bridge ([approvals.md](approvals.md)), the trace spans
([tracing.md](tracing.md)) and the fake runtime/provider adapters
([adapters.md](adapters.md)) — with no forge, no tmux and no credentials, on
a pinned clock, so that two runs of one scenario are byte-identical and any
behavioural drift shows up as a diff against a committed baseline.

Nothing here is used by production paths; the harness only consumes the
public functions of the other modules. Its files are:

| Path | Content |
| --- | --- |
| `lib/ordo_eval.sh` | The library: sandbox, step interpreter, trajectory writer, normaliser, scorer, baseline/check. |
| `scripts/ordo_eval.sh` | Operator entry point: `run`, `score`, `baseline`, `check`, `demo`, `list`. No project config needed. |
| `tests/fixtures/eval/demo/` | The demo workload: 4 scenarios with their `*.expected.json` and the committed `baseline.json`. |
| `tests/fixtures/eval/failures/` | The 6 failure-injection scenarios with their expectations. |
| `tests/ordo_eval.bats` | 18 tests: every scenario, determinism, score card, negative scoring cases, baseline check and regression, no-network proof, exit codes, the script. |

## Running the demo with zero credentials

```bash
bash scripts/ordo_eval.sh demo                                    # run + score the 4 demo scenarios, compare with the baseline
bash scripts/ordo_eval.sh run tests/fixtures/eval/failures/process_crash.json --out /tmp/traj
bash scripts/ordo_eval.sh score /tmp/traj tests/fixtures/eval/failures/process_crash.expected.json --json
bash scripts/ordo_eval.sh list                                    # every scenario (demo + failures)
bats tests/ordo_eval.bats                                         # the whole suite (a few minutes)
```

Requirements: bash, jq, python3 (stdlib `sqlite3`, for the journal), coreutils.
`gh`, `tmux`, `curl`, `ssh`, `wget` and `glab` must **not** be reachable: the
sandbox puts guard stubs first on `PATH` that refuse (exit 6) and record every
call; a recorded call makes the run fail closed (exit 3) and the summary lists
it under `forbidden_calls`. `tests/ordo_eval.bats` also runs a scenario with a
`PATH` that contains none of those tools.

## The fake world

`ordo_eval_run` executes each scenario in a subshell with:

| What | Value |
| --- | --- |
| `PROJECT`, `ORCH_STATE_BASE`, `ORCH_LOG_DIR` | `eval-<name>` under a fresh temporary work directory (removed after the run unless `--keep`). The journal, ledger, traces and runtime evidence live there. |
| `ORDO_RUNTIME_ADAPTER` / `ORDO_PROVIDER_ADAPTER` | `fake` / `fake`; `ORDO_FAKE_ADAPTER_DIR` is a copy of `tests/fixtures/<scenario.fixtures>` (default `adapters/fake`: repo `acme/widgets`, issue #7, PRs #12–#16, runs 100/200). |
| Clock | `ORDO_JOURNAL_NOW = scenario.clock`; `advance` steps move it; the trace clock and `ordo_contracts_now` follow it, so receipts, fake records and timestamps are stable. |
| Scheduler | `ORDO_SCHED_JITTER=0`, worker `eval@evalhost:<pid>`; `scenario.env` may override `ORDO_SCHED_*`, `ORDO_APPROVAL_DEFAULT_TTL`, `ORDO_JOURNAL_DEFAULT_*` (nothing else). |
| Policy | `ORCH_EXTERNAL_PR_MUTATIONS = policy.external_mutations`, `ORDO_APPROVAL_PRINCIPALS = policy.principals`, `ORDO_POLICY_VERSION = policy.policy_version` (default `eval-policy-v1`). Live mutation stays scoped per scenario. |
| Actors | The harness acts as `{"type":"agent","id":"eval-agent"}` for worker-side calls and provider reads, as operator `scenario.operator` (default `eval-operator`) for enqueue, resume, cancel, fail; grants/denies/executions take `by`/`actor` per step (`type:id`, JSON, or a bare operator id). |
| Audit | `audit()` writes to the sandbox log only, so stderr carries nothing but error objects. |
| Forbidden tools | `gh glab tmux curl ssh wget` stubs, see above. |

Every scenario **enqueues its runs first** (the `runs` array), then plays
the `steps` in order. A step whose exit code differs from `expect_rc`
(default 0) or whose `expect` block does not hold stops the scenario: the
trajectory is still written, `summary.json` records `ok=false` and the
mismatch, and `ordo_eval_run` exits 5.

## Scenario format

```jsonc
{
  "schema_version": "1",
  "name": "pr_merge_approval",               // ^[a-z0-9_-]+$ ; the expected file is <name>.expected.json next to it
  "description": "…",
  "clock": "2026-09-11T10:00:00Z",           // RFC3339 UTC, the pinned start
  "repo": "acme/widgets",                    // ORDO_FORGE_REPO (default acme/widgets)
  "operator": "eric",                        // operator actor id
  "fixtures": "adapters/fake",               // relative to tests/fixtures (default)
  "policy": {"external_mutations": "pr_merge", "principals": "eric=pr.merge", "policy_version": "policy-v1"},
  "env": {"ORDO_SCHED_MAX_FANOUT": "2"},     // scheduler knobs only
  "runs": [                                  // enqueued in order, each gets an alias used by the steps
    {"alias": "merge12", "title": "…", "ticket": "acme/widgets#12", "priority": 10,
     "budget": {"max_tokens": 5000}, "metadata": {…}, "readiness": {"state": "unknown"},
     "depends_on": ["other_alias"], "not_before": "…", "expires_at": "…", "max_retries": 3,
     "runtime_target": "fleet-001:0.0", "brief": "text of the dispatch brief"}
  ],
  "steps": [ … ]
}
```

Common step fields: `op` (required), `label` (free text, shown in
mismatches), `expect_rc` (default 0), `expect` — any of `state` (run state
after the step; `run` selects the alias, default the step's run, else the
first run), `error_code`, `reason` (`error.details.reason`), `retryable`
(`"true"`/`"false"`), `attempts` (provider attempts), `replayed`
(`receipt.details.replayed`, `"true"`/`"false"`).

| `op` | Fields | What it does |
| --- | --- | --- |
| `enqueue` | same as a `runs` entry | Enqueue a run later in the scenario. |
| `tick` | `max_picks`, `worker_pid` (`"dead"` = a pid that cannot exist) | `ordo_scheduler_tick`. `worker_pid: "dead"` leases with an owner `recover` will find dead. |
| `advance` / `clock` | `seconds` / `at` | Move the pinned clock. |
| `heartbeat` / `usage` | `run`, `usage` | `ordo_scheduler_heartbeat` (renews the lease, enforces budgets — exit 7) / `ordo_scheduler_report_usage`. |
| `readiness` | `run`, `state`, `source` | Appends `run.updated {"metadata":{"readiness":…}}` (what a planner/provider adapter writes). |
| `provider` | `run`, `args: [op, …]`, `retry: {max, backoff_seconds, heal_after}` | A provider **read** through `ordo_provider`; retried while `details.retryable` is true, the clock advancing by `backoff_seconds` between attempts, every injected fixture restored after `heal_after` failures. Journals `provider.read` (op, args, attempts) and emits a `provider.<op>` span (+ one `retry.attempt` span per attempt when `max > 1`). |
| `mutate` | `run`, `key`, `args: [op, …]` | A **direct** mutation delivery with `--idempotency-key key` (no bridge) — the way to deliver a duplicate or an unapproved mutation. Journaled as `provider.mutation_delivered` (`mutation=true`). |
| `require_approval` | `run`, `action`, `reason`, `deadline` | `ordo_scheduler_require_approval` (run parks, lease released). |
| `approval_request` | `run`, `ref`, `action`, `principal`, `key`, `ttl`, `args`, `payload` | `ordo_approval_request` with `args` pinned in the payload; `ref` names the approval for later steps. |
| `grant` / `deny` | `approval`, `by`, `reason` | `ordo_approval_grant` / `_deny` (a `model:x` actor is refused with exit 3). |
| `execute` | `approval`, `args: [op, …]`, `by` | `ordo_approval_authorize_and_run … -- op args` (the bridge: re-authorization, provider with the approval's key, consume). |
| `sweep` | — | `ordo_approval_sweep`. |
| `resume` / `complete` / `fail` / `wait` / `block` / `cancel` | `run`, `requeue` / `result` / `reason` / `reason`,`deadline` / `reason`,`type` / `reason` | The scheduler transitions. |
| `recover` | — | `ordo_scheduler_recover` (rebuild, sweep, dead-owner reconciliation). |
| `fixture` | `path`, then `json: {…}` or `error: {…}` or `restore: true` | Write a fake-provider fixture (an `{"error":…}` document is replayed as that error, with its `details.retryable`); `restore` puts every injected file back. Provider outage and network timeout are built with it. |
| `crash` | `during: {step}`, `at: first_write` (default) or `approval_consume` | Runs the inner step with `ORDO_JOURNAL_FAULT=kill_before_commit` armed on the chosen journal write: `first_write` kills the first write of the step, `approval_consume` lets the provider mutate and kills the `consumed` transition of the bridge. The inner step must fail (that is the crash); the result carries the inner exit code and error. `during` cannot be `enqueue` or `approval_request` (aliases created inside the crashed step are not kept). |
| `runtime` | `run`, `args: [op, …]` | `ordo_runtime <op> <target>` on the run's fake runtime target (`start`, `inspect`, `signal`, `stop`). |
| `evidence` | `run`, `label` | `ordo_runtime collect_evidence`; the capture is copied to `<trajectory>/evidence/<alias>-NN-<label>.txt` and recorded as a validated `artifact` contract object in `artifacts.jsonl` plus an `artifact.recorded` event. |

## Trajectory directory

`ordo_eval_run <scenario> --out DIR` writes (a previous trajectory in `DIR`
is replaced; `scripts/ordo_eval.sh run` without `--out`/`--keep` scores a
temporary trajectory and removes it, reporting `trajectory: null`):

| File | Content |
| --- | --- |
| `scenario.json` | The scenario, pretty-printed with sorted keys. |
| `steps.jsonl` | One line per step: `index, op, label, clock, rc, expect_rc, ok, idempotency_key, result, error`. `idempotency_key` is set on deliveries only (`execute`, `mutate`, `crash` around one of them), refused or crashed ones included, so the scorer can count deliveries against executions. `error` is the error object of the module that refused the step. |
| `events.jsonl` | Every journal event of every run (`+ alias`), runs in enqueue order, `run_seq` ascending. |
| `runs.json` | `{alias: projection}` — the final `ordo_journal_project` snapshot of each run. |
| `leases.jsonl`, `approvals.jsonl` | Lease and approval rows per run (approvals with their pinned payload). |
| `traces.jsonl` | Folded spans of each run's trace (`trace_id = sha256(run_id)[0:32]`), in the order their start lines were appended. |
| `mutations.jsonl` | The fake provider's record of every **executed** mutation. |
| `ledger.jsonl` | The provider idempotency ledger. |
| `runtime_events.jsonl` | The fake runtime's event log. |
| `artifacts.jsonl`, `evidence/` | Artifact objects and the captured files. |
| `summary.json` | `scenario, clock_start, clock_end, elapsed_seconds, steps_executed/total, ok, mismatch, forbidden_calls, runs{alias: run_id,state}, mutations, events`. |
| `idmap.json` | The normalisation map (raw → normalised). **The only volatile file**; `ordo_eval_digest` skips it. |

### Normalisation rules (replay determinism)

After collection every file above (except `idmap.json`, in the fixed order of
`ORDO_EVAL_TRAJECTORY_FILES`) is rewritten by one pass of the embedded
Python normaliser (`ordo_eval_normalize`):

1. the sandbox work directory becomes `<WORK>`, the toolkit root `<TK>`;
2. runtime-evidence file names (`<target>-<real stamp>-<label>-<pid>.txt`,
   the only place where the wall clock and a pid leak) become
   `<target>-<STAMP>-<label>-<PID>.txt`; the capture itself is copied under
   `evidence/` with a deterministic name;
3. contract ids `<kind>_<hex>` (`run`, `lease`, `approval`, `event`,
   `attempt`, `policy_decision`, `artifact`, `blocker`, …) become
   `<kind>_<zero-padded counter>` of the same length, numbered per kind **in
   order of first appearance** (so `run_000000000000000000000001` is the
   first run enqueued, `event_…0001` the first event written);
4. bare 32-hex and 16-hex words (trace and span ids) become zero-padded
   counters of the same length, in order of first appearance (40-hex commit
   shas and 64-hex digests are untouched);
5. lease-owner pids `@evalhost:<pid>` become `@evalhost:100001`, `100002`, …
   in order of first appearance (a dead owner and a live one map to two
   numbers).

Everything else is already deterministic: the clock is pinned, jitter is off,
fixtures are copied, sorted-key JSON is used throughout. `ordo_eval_digest
DIR` prints `sha256  file` lines for the comparison; the determinism test
`cmp`s two runs of `pr_merge_approval` file by file and score card by score
card.

## Scoring: `ordo_eval_score <trajectory_dir> <expected.json>`

The expected file (`<name>.expected.json` next to the scenario):

```jsonc
{
  "runs": {"merge12": {"state": "succeeded", "terminal": true}},
  "policy": {"max_unapproved": 0, "refused": 0, "denials": 0},
  "evidence": {"events": {"merge12": ["run.created", "run.leased", "…"]},   // ordered subsequence per run
               "spans": ["approval.authorize", "provider.pr_merge"], "artifacts": 1},
  "cost": {"merge12": {"max_attempts": 1, "max_tokens": 2000, "max_seconds": 300, "max_turns": …, "max_tool_calls": …, "max_cost": …, "exhausted": []}},
  "latency": {"max_elapsed_seconds": 300},
  "side_effects": {"executed": 1, "deliveries": 1}
}
```

The score card (sorted keys; exit 0 when `pass`, 1 otherwise) carries
`pass`, six `dimensions` — each with `pass`, `failures[]` and its numbers —
and a flat `metrics` object used by the baseline:

| Dimension | Pass when | Numbers |
| --- | --- | --- |
| `completion` | every expected run has the expected terminal/non-terminal state **and** the harness finished the scenario (`summary.ok`). | per-run expected/actual. |
| `policy_compliance` | every executed mutation (`mutations.jsonl`) carries the idempotency key of a **consumed** approval (at most `max_unapproved` exceptions, default 0); no `approval.granted`/`approval.consumed`/`policy.decided` event has a `model` actor; when given, the number of refused deliveries (`execute`/`mutate` steps that exited 3) and of `policy.decided` deny events match. | `mutations_executed/approved/unapproved`, `unapproved_keys`, `mutations_refused`, `policy_denials`, `model_decisions`. |
| `evidence_completeness` | every listed event type appears in the run's journal in that order (subsequence); every listed span name exists; at least N artifacts; every executed mutation key is journaled as a `mutation=true` event, and no key is journaled twice. | `events_total`, `spans_total`, `artifacts`, `required_events`, `missing_spans`, `unjournaled_mutations`. |
| `cost` | the projection budgets of each run stay within the given `max_*`, and `exhausted` matches when given. | per-run `attempts/tokens/seconds/turns/tool_calls/cost_used`, `exhausted`; totals. |
| `latency` | pinned-clock `elapsed_seconds` (clock_end − clock_start) ≤ `max_elapsed_seconds`. | `elapsed_seconds`, per-run enqueue→finish seconds. |
| `duplicate_side_effects` | no idempotency key appears twice in `mutations.jsonl` nor in the ledger; when given, the number of executed mutations and of deliveries (bridge executions, direct deliveries and crashed deliveries, replayed or not) match. | `mutations_executed`, `distinct_keys`, `deliveries`, `replayed_deliveries`, `repeated_keys`, `repeated_ledger_keys`. |

## Scenarios

Demo workload (`tests/fixtures/eval/demo/`, the baseline set):

| Scenario | Story | End state | Mutations |
| --- | --- | --- | --- |
| `issue_triage` | Read issue #7 (with comments), the ready queue and the open PRs, report usage, park for approval, an operator grants one `issue.comment`, the bridge posts it, the run resumes and succeeds. | `succeeded` | 1 |
| `pr_merge_approval` | Start the fake runtime, make CI green through a fixture, read PR/checks/reviews, heartbeat, capture pane evidence (artifact), park, grant `pr.merge`, execute `pr_merge 12 --method squash`, resume, succeed. | `succeeded` | 1 |
| `blocked_run` | A run with `readiness.state=unknown` is never picked (fail-closed); once ready it starts, reads red CI and parks `blocked`; a dependent run stays `queued`; a resume with unknown readiness is refused (exit 3). | `blocked` / `queued` | 0 |
| `budget_exhausted` | Two heartbeats push `tokens_used` past `max_tokens`: exit 7, run `failed`, lease released. | `failed` | 0 |

Failure injection (`tests/fixtures/eval/failures/`):

| Scenario | Injection | Assertions |
| --- | --- | --- |
| `process_crash` | `crash at=approval_consume during execute` (the bridge dies after the provider merged, before consuming), then `crash at=first_write during complete` (the scheduler dies inside `run.succeeded`). | The replayed `execute` returns the ledger receipt (`replayed=true`), `mutations.jsonl` and the ledger hold one line, `run_seq` is gapless, `approval.consumed` and `run.succeeded` appear once, deliveries 2 / executed 1. |
| `network_timeout` | `fixture pr_get/12.json = {error: timeout, retryable}` then a `provider` read with `retry {max 4, backoff 30, heal_after 2}`; a non-retryable 401 on #13. | Attempts `[1,1,0]` at 10:00:00 / 10:00:30 / 10:01:00, four `retry.attempt` spans (ERROR, ERROR, OK, ERROR), the 401 is not retried. |
| `provider_outage` | `checks_get/12.json = HTTP 502` for longer than the retry budget. | The read fails after 3 retryable attempts, the run parks `waiting` (lease released, deadline set), the next tick gives the slot to another run, after `fixture restore` the run resumes and succeeds. |
| `stale_lease` | `tick worker_pid=dead`, then a lease left past its TTL. | `recover` reconciles `owner_dead` and requeues without backoff; the tick sweeps the expired lease and requeues with a 60 s backoff; `not_before` holds the run; attempt 3 succeeds; two distinct owner pids in `leases.jsonl`. |
| `duplicate_delivery` | One approved `issue.comment` delivered through the bridge, again through the bridge, then directly with the same key. | `mutations.jsonl` has one line, the ledger one line, deliveries 3 of which 2 replayed, one `mutation=true` journal event. |
| `approval_expiry` | Grant a 600 s approval, advance 601 s, execute. | Exit 3 `policy_refused` / `approval_expired`, the approval is `expired`, a `policy.decided` deny is journaled, the run stays `approval_required`, nothing in `mutations.jsonl` or the ledger. |

## Adding a scenario

1. Write `tests/fixtures/eval/<dir>/<name>.json` (format above) and
   `<name>.expected.json`. Start from the closest existing scenario; put
   `expect` blocks on the steps whose outcome matters so a divergence is
   reported at the step, not at scoring time.
2. Run it: `bash scripts/ordo_eval.sh run tests/fixtures/eval/<dir>/<name>.json --out /tmp/t`.
   A step mismatch exits 5 and names the step; read `/tmp/t/steps.jsonl`
   (`error` carries the module's error object).
3. Check determinism: run it twice into two directories and `cmp` the
   `ordo_eval_digest` outputs. A difference means a new volatile value —
   extend the normalisation rules (and this page) rather than the scenario.
4. Add a `@test` in `tests/ordo_eval.bats` (and the name to
   `EVAL_SCENARIOS` so `setup_file` runs it once) asserting the facts the
   scenario exists to prove.
5. If the scenario belongs to the demo workload, regenerate the baseline
   (below) in the same change.

## Baseline policy

`tests/fixtures/eval/demo/baseline.json` is generated, never edited by hand:

```bash
bash scripts/ordo_eval.sh baseline          # rewrites tests/fixtures/eval/demo/baseline.json
bash scripts/ordo_eval.sh check             # exit 1 with a diff on any regression
```

It holds, per demo scenario, `pass`, the per-dimension pass flags and the
`metrics` object. It carries no timestamp and no host data, so
`baseline` regenerates it byte-for-byte on any machine (the bats suite
checks that). `check` reruns the demo and reports per scenario:

- **regression** (exit 1): `pass` or any dimension flipped to false; the
  end states differ; any behavioural count differs
  (`mutations_executed`, `mutations_unapproved`, `mutations_refused`,
  `policy_denials`, `repeated_keys`, `deliveries`, `replayed_deliveries`,
  `artifacts`); or a cost/latency/volume metric **grew**
  (`elapsed_seconds`, `attempts_used`, `tokens_used`, `seconds_used`,
  `turns_used`, `tool_calls_used`, `cost_used`, `events_total`); a scenario
  present in the baseline but not run is also a regression;
- **improved**: a cost/latency/volume metric shrank (reported, exit 0);
- **new**: a scenario absent from the baseline (reported, exit 0);
- **ok**: identical.

Regenerate the baseline in the same pull request as an intentional change
of behaviour (a new event type, a cheaper path, a new scenario), and say so
in the PR body; a baseline change without a behaviour change is a review
finding. Adding spans is reported under `changes` and never fails the check.

## Errors and exit codes

One JSON line on stderr, module `eval` (errors of the modules under test
pass through in the step records, never on the harness's stderr):

| Exit | `error.code` | When |
| --- | --- | --- |
| 1 | `generic_failure` | `ordo_eval_check` found regressions; `ordo_eval_baseline` ran but a scenario does not pass its expectations; a score card with `pass=false` (no error object, the card is printed). |
| 2 | `usage`, `unknown_command` | Missing or unknown command/arguments. |
| 3 | `fail_closed` | A forbidden tool (`gh`, `tmux`, `curl`, `ssh`, …) was invoked inside the sandbox. |
| 4 | `not_found` | Scenario, expected file, trajectory file or fixture directory missing. |
| 5 | `invalid_contract`, `invalid_json`, `invalid_state`, `conflict` | Malformed scenario or step; unknown alias; a step diverged from `expect_rc`/`expect` (the trajectory is written with `ok=false`); `--out` names a non-empty directory that is not a previous trajectory (nothing is deleted). |
| 6 | `missing_dependency` | No `python3`. |

## Relationship with the other children

- The harness is a consumer only: it never redefines a contract, a state
  table or a policy. Two functions are shadowed **inside the sandbox
  subshell** for determinism and quiet output: `audit` (sandbox log only)
  and `ordo_contracts_now` (the pinned clock).
- `ORDO_JOURNAL_FAULT=kill_before_commit` (journal, #808) is the crash
  primitive; `ORDO_JOURNAL_NOW` (journal) pins every module's clock;
  `ORDO_SCHED_JITTER=0` (scheduler, #810) pins the backoff; the fake
  adapters (#811) provide the forge and the runtime; the approval bridge and
  the trace spans (#812) provide the evidence the scorer reads.
- #816 can point `fixtures` at other datasets and reuse the `provider` /
  `mutate` steps to prove a migrated call site end to end with no `gh`.

## Change history

- #813 (epic #806): initial harness, demo workload and baseline, six
  failure-injection scenarios, determinism and scoring tests.
