# ORDO event journal and projections

Audience: developer, operator. Category: developer docs / API reference.

`lib/ordo_journal.sh` is the persistence layer of the agentic control plane
(issue #808, epic #806). It stores every contract `event` (see
[contracts.md](contracts.md)) in an append-only SQLite journal with a gapless,
monotonic sequence per run, folds those events into deterministic snapshots
("projections"), and re-emits the legacy state files so the existing scripts
keep reading exactly what they read today. Leases and approvals get thin CRUD
on the same database; the scheduler (#810) and approval (#812) modules consume
it.

Nothing here changes existing dispatch behaviour. `lib/state_persist.sh` is
untouched; the compatibility export writes *through* it.

## Where things live

| Path | Content |
| --- | --- |
| `lib/ordo_journal.sh` | The library: bash API + the embedded Python program (`ORDO_JOURNAL_PY`) that talks to SQLite. |
| `$(state_dir)/ordo-journal.sqlite` | The database (WAL: `-wal` and `-shm` sidecars appear while open). Override with `ORDO_JOURNAL_DB`. |
| `$(state_dir)/ordo-runs/<run_id>.json` | Per-run snapshot written by `ordo_journal_compat_export`. |
| `$(state_dir)/assignments.json` | Legacy ledger, upserted/deleted by the compat export (see mapping below). |
| `$(state_dir)/ordo-journal-compat.json` | `{"agents": {<agent>: <run_id>}}` — which `assignments.json` rows the journal owns. |
| `tests/ordo_journal.bats` | 23 tests: schema, append, projection, purity, crash safety, concurrency, compat, leases, approvals, exit codes. |

### Decision: python3 stdlib `sqlite3`, no `sqlite3` CLI

The `sqlite3` command-line tool is installed neither on the operator hosts nor
in CI; `python3` with the stdlib `sqlite3` module (SQLite 3.46)
is. All database access therefore goes through one Python program embedded in
the bash library and fed to `python3 -` on stdin (the pattern already used by
`lib/ready_queue.sh` and `lib/audit_log.sh`). No `.py` file exists: the test
runners only mirror `*.sh/*.bats/*.md` into their sanitized root. The program
is stdlib-only (`sqlite3`, `json`, `datetime`, `os`, `signal`). Without
`python3` every journal call exits 6 with a `missing_dependency` error object;
`ORDO_JOURNAL_PYTHON_BIN` selects another interpreter.

Bash owns everything that is policy: building and validating contract objects
(`ordo_contracts_validate`), checking lease/approval transitions
(`ordo_contracts_transition`), error objects and exit codes. Python owns only
the transaction: sequence assignment, uniqueness, the guarded update, the fold.

## Public API

```bash
source lib/audit_log.sh        # state_dir (needs PROJECT)
source lib/state_persist.sh    # state_persist / state_update (compat export)
source lib/ordo_journal.sh     # sources lib/ordo_contracts.sh itself

ordo_journal_init                                        # {"db","schema_version","journal_mode":"wal",...}
ordo_journal_append <run_id> <type> <payload_json> \
    [--idempotency-key K] [--actor JSON] [--mutation] \
    [--correlation-id C] [--metadata JSON]               # prints the stored event (with run_seq)
ordo_journal_events <run_id> [--since RUN_SEQ]           # JSON lines, run_seq ascending, run_seq > RUN_SEQ
ordo_journal_project <run_id>                            # snapshot JSON (one line, sorted keys)
ordo_journal_rebuild_all                                 # {"rebuilt": N, "runs": {run_id: state}}
ordo_journal_state <run_id>                              # state string; exit 4 if unknown
ordo_journal_runs [--state S[,S...]]                     # snapshot JSON lines of every projected run, enqueue order (#810)
ordo_journal_compat_export <run_id>                      # {"run_id","state","files":[...],"assignment":{agent,action}}

ordo_journal_lease_acquire <run_id> <owner> [--ttl S] [--task-id T] [--actor JSON]
ordo_journal_lease_renew   <lease_id> [--ttl S] [--actor JSON]
ordo_journal_lease_release <lease_id> [--actor JSON]
ordo_journal_lease_expire_stale [--actor JSON]           # {"expired":[lease...],"count":N}
ordo_journal_lease_get <lease_id> | ordo_journal_lease_list <run_id>

ordo_journal_approval_create <run_id> <action> <principal> \
    --policy-version V --idempotency-key K [--ttl S | --expires-at TS] [--actor JSON]
ordo_journal_approval_get <approval_id> | ordo_journal_approval_list <run_id> [--state S]
ordo_journal_approval_set_state <approval_id> <state> \
    [--reason R] [--decided-by JSON] [--result JSON] [--actor JSON]

# helpers
ordo_journal_db_path        ordo_journal_check        ordo_journal_now
```

`<payload_json>` and every `JSON` option accept a literal, `-` (stdin) or
`@<path>`. `run_id` must be a canonical `run_<24 hex>` (exit 2 otherwise).
The default actor is `{"type":"system","id":"ordo_journal"}`; the default
`correlation_id` is the run id. Every command reads `PROJECT` /
`ORCH_STATE_BASE` from the environment like the rest of ORDO.

### Errors and exit codes

One JSON line on stderr, `{"error":{"code","message","module":"journal","details"}}`,
exit code from the contracts map. Codes the journal emits:

| Exit | Code | When |
| --- | --- | --- |
| 1 | `internal_error` | Python failure or a transaction that did not commit (`details.rc`, `details.raw`). |
| 2 | `usage`, `bad_argument` | Missing/unknown arguments, non-canonical run id, bad `--ttl` / `--since`. |
| 4 | `not_found` | Unknown run, lease or approval; unreadable `@path`. |
| 5 | `invalid_contract`, `invalid_json` | The event/lease/approval does not satisfy its v1 contract (details carry the validator errors). |
| 5 | `duplicate_event` | `--idempotency-key` already stored. **The existing event is printed on stdout.** |
| 5 | `conflict` | Run already leased by a live lease (`details.owner`), duplicate approval key (`details.reason=duplicate_idempotency_key`, existing approval on stdout), or a row changed between check and guarded update. |
| 5 | `invalid_transition` (module `contracts`) | Lease/approval transition refused by the contract tables. |
| 6 | `missing_dependency` | No `python3`. |
| 8 | `lease_lost`, `lease_stale` | Renew/release of an `expired` lease, or of a lease past `expires_at` not yet swept. |

## Schema (version 1)

`PRAGMA user_version` holds the schema version; `schema_migrations(version,
applied_at)` records each applied step. `ordo_journal_init` is idempotent and
every command migrates lazily, so a fresh state dir works without `init`.

```
events      seq INTEGER PRIMARY KEY AUTOINCREMENT     -- global order
            event_id TEXT UNIQUE                      -- contract id (event_<hex>)
            run_id TEXT, run_seq INTEGER              -- UNIQUE(run_id, run_seq)
            ts TEXT (created_at), kind TEXT ('event'), type TEXT
            actor_json TEXT, payload_json TEXT, mutation INTEGER
            idempotency_key TEXT UNIQUE (NULL allowed)
            correlation_id TEXT
            event_json TEXT                           -- the canonical object; printed verbatim by events/append
projections run_id TEXT PRIMARY KEY, state, updated_at, last_seq, snapshot_json
leases      lease_id PK, run_id, owner, state, expires_at, heartbeat_at, generation, lease_json
approvals   approval_id PK, run_id, action, principal, policy_version, state,
            expires_at, idempotency_key UNIQUE, result_json, approval_json
```

`event_json`, `lease_json` and `approval_json` are the source of truth for
the printed objects; the typed columns are indexes and guards. JSON is stored
and printed canonically (sorted keys, compact separators, UTF-8), so two
reads of the same row are byte-identical.

## Sequence guarantees

- `run_seq` starts at 1 per run and is gapless: it is computed as
  `MAX(run_seq)+1` inside a `BEGIN IMMEDIATE` transaction, which takes the
  database write lock before the read, so two appenders can never compute
  the same value. `UNIQUE(run_id, run_seq)` is the belt to that brace.
- `seq` is the global insertion order (AUTOINCREMENT, never reused).
- `idempotency_key` is global (not per run). A second append with the same
  key never writes: it prints the stored event on stdout, the
  `duplicate_event` error on stderr and exits 5, so callers can treat "0 or 5
  with the same event" as "the side effect is recorded exactly once". The
  contract already requires a key on every `mutation=true` event; replaying a
  log through `ordo_journal_append` therefore never records a mutation twice.
- Eight concurrent appenders on one run, and eight racing on one key, are
  exercised by `tests/ordo_journal.bats` (`8 concurrent appenders…`,
  `concurrent appends racing on one idempotency key…`).

## Projection semantics

`ordo_journal_project` is a pure fold: `snapshot = fold(events ordered by
run_seq)`. It reads only the events of the run and the run transition table
exported by `ordo_contracts_transitions run` (the same data
`ordo_contracts_transition` checks), performs no external call, writes no
state file, and stores its result in the `projections` table (its own cache,
inside the journal database). Rebuilding twice yields byte-identical output;
`ordo_journal_append` and the lease/approval writers refresh the projection
row in the same transaction as the event, so `ordo_journal_state` is always
consistent with the last committed event. `ordo_journal_rebuild_all` recomputes
every run and drops projection rows whose events are gone (recovery).

Snapshot shape (sorted keys when printed):

```json
{
  "projection_version": 1, "schema_version": "1",
  "run_id": "run_…", "project": "<PROJECT>",
  "state": "running", "initial_state": "queued", "terminal": false,
  "title": "…", "ticket_ref": "owner/repo#42",
  "created_at": "<ts of first event>", "updated_at": "<ts of last event>",
  "event_count": 5, "last_seq": 17, "last_run_seq": 5,
  "last_event": {"seq", "run_seq", "event_id", "type", "ts", "actor"},
  "counters": {"events", "mutations", "transitions", "invalid_transitions",
               "blockers_open", "attempts", "by_type": {"<type>": n}},
  "budgets": {"max_attempts", "max_seconds", "max_tokens", "max_turns", "max_tool_calls", "max_cost",
              "attempts_used", "seconds_used", "tokens_used", "turns_used", "tool_calls_used", "cost_used",
              "exhausted": ["max_tokens"]},
  "transitions": [{"run_seq", "from", "to", "ts", "type"}],
  "blockers": [{"id", "type", "severity", "summary", "state", "run_seq", "ts", "from?", "to?", "resolved_at?", "resolved_run_seq?"}],
  "dispatch": {"agent", "ticket", "branch", "workdir", "repo_root", "prompt_file", "dispatched_at", "head_at_dispatch", "…"} | null,
  "lease": {"id", "owner", "state", "expires_at", "generation"} | null,
  "approval": {"id", "action", "state"} | null,
  "metadata": {}
}
```

Event types the fold understands (anything else is counted in `by_type` and
otherwise ignored, forward compatible):

| Event type | Effect |
| --- | --- |
| `run.created`, `run.updated` | `title`, `ticket_ref`, `project` (first wins), `budget.max_*`, `dispatch` (merge). |
| any `run.*` event with `payload.metadata` | shallow merge into `metadata` (the scheduler, #810, records `not_before`, lease owner, heartbeat on the state event itself). |
| `run.dispatched` | merge `payload.dispatch` into `dispatch`. |
| `run.budget` | `budget.max_*` override. |
| `run.leased` `run.started`/`run.running`/`run.resumed` `run.waiting` `run.blocked` `run.approval_required` `run.requeued` `run.succeeded` `run.failed` `run.cancelled` `run.expired` | transition to the named state (`requeued` → `queued`, `started/running/resumed` → `running`). |
| `run.transition` | transition to `payload.to`. |
| `attempt.started` | `counters.attempts` and `budgets.attempts_used` +1. |
| any event with `payload.usage.{tokens,seconds,turns,tool_calls,cost}` | added to `budgets.tokens_used/seconds_used/turns_used/tool_calls_used/cost_used` (numbers). |
| `blocker.raised` / `blocker.resolved` | open a blocker (`id`, `type`, `severity`, `summary`) / resolve by `id` (or all open blockers of `type`). |
| `lease.*` / `approval.*` | mirror the last lease/approval and its state. |

The initial state is `queued`. Each transition is checked against the run
table; a refused transition (e.g. `running -> queued`) or an unknown target
state does **not** crash and does not change the state: it increments
`counters.invalid_transitions` and appends an open blocker of type
`invalid_transition` or `unknown_state` carrying `from`, `to` and `run_seq`.
`terminal` is true for `succeeded`, `failed`, `cancelled`, `expired`.
`budgets.exhausted` lists every `max_*` that is set (> 0) and reached.

## Compatibility projection (legacy state files)

`ordo_journal_compat_export <run_id>` rebuilds the projection and writes,
through `lib/state_persist.sh`:

| File under `$(state_dir)` | Written how | Content |
| --- | --- | --- |
| `ordo-runs/<run_id>.json` | `state_persist` (atomic tmp + mv) | The snapshot, pretty-printed with sorted keys (`jq -S .`). Always written. |
| `assignments.json` | `state_update assignments` (flock + jq, same pretty output as `scripts/dispatch_ticket.sh`) | `.[<agent>]` upserted while the run is **not terminal**, deleted once it is — only if `ordo-journal-compat.json` says the journal wrote that row. Untouched when the run has no `dispatch.agent`. |
| `ordo-journal-compat.json` | `state_update` | `{"agents": {<agent>: <run_id>}}` ownership map. |

The `assignments.json` row is built from `snapshot.dispatch` with exactly the
key order and null/empty rules of `dispatch_assignment_payload` in
`scripts/dispatch_ticket.sh`:

```
ticket            = dispatch.ticket (string)          issue = same, numeric when it is all digits
branch            = dispatch.branch or null            workdir, repo_root, prompt_file, dispatched_at = value or ""
head_at_dispatch  = dispatch.head_at_dispatch or null
optional (only when non-empty): route_mode, context_proof_route, context_proof_live_workdir, status, reason, updated_at
```

Readers that keep working unchanged: `scripts/orch_ctl.sh status`
(`assignments: N` counts `to_entries | length`), `scripts/orch_loop.sh`,
`scripts/monitor_heartbeat.sh`, `scripts/recover.sh` (`.issue`, `.workdir`,
`.prompt_file`), `scripts/preempt_assignment.sh`, `lib/worktree_helpers.sh`
(`.workdir` and arbitrary fields), `lib/agent_softblock.sh` (`.issue //
.ticket`), `lib/dispatch_capacity.sh`, `lib/capacity_report.sh`,
`lib/recovery_context.sh`. The test `compat_export reproduces the legacy
assignments.json byte-for-byte…` extracts `dispatch_assignment_payload` from
`scripts/dispatch_ticket.sh` at run time, writes the ledger the legacy way and
`cmp`s it against the export, so any drift in the script fails the suite.

## Leases and approvals

Leases are `lease` contract objects, exclusive per run: `acquire` refuses
(exit 5 `conflict`, `details.owner`) while an `active`/`renewed` lease with
`expires_at > now` exists. `renew` bumps `generation`, sets `heartbeat_at =
now`, `expires_at = now + ttl` (ttl defaults to the previous one, then
`ORDO_JOURNAL_DEFAULT_LEASE_TTL=300`). Transitions follow the contract table
(`active -> renewed | released | expired`, `renewed -> renewed | released |
expired`); a renew/release of an `expired` lease exits 8 `lease_lost`, of a
lease past `expires_at` not yet swept exits 8 `lease_stale`. Every change
appends `lease.acquired|renewed|released|expired` to the run (payload:
`lease_id`, `owner`, `state`, `expires_at`, `generation`) in the same
transaction as the row update, and the update is guarded (`WHERE state IN
(active, renewed)`), so two sweepers or a sweeper racing a holder cannot both
win.

`ordo_journal_lease_expire_stale` is the sweep the scheduler runs each cycle:
every live lease with `expires_at <= now` becomes `expired` and emits
`lease.expired`; the run becomes acquirable again. Holders compare
`generation` to detect that they lost a lease.

Approvals are `approval` contract objects with a mandatory global
`idempotency_key` (duplicate: exit 5 `conflict`, existing approval on stdout,
nothing written). `set_state` checks `pending -> granted | denied | expired`,
`granted -> consumed | expired` through `ordo_contracts_transition approval`,
records `decided_at`, `decided_by` (defaults to the actor), `reason`,
`result`, and appends `approval.<state>` to the run. `expires_at` defaults to
`now + ORDO_JOURNAL_DEFAULT_APPROVAL_TTL` (86400 s); expiring is a state
change the approval module decides (`set_state … expired`), never a silent
timeout.

Timestamps are RFC3339 UTC seconds (`ordo_journal_now`); `ORDO_JOURNAL_NOW`
pins the clock for tests and the comparisons are lexical on that format.

## WAL, locking and durability

- `PRAGMA journal_mode=WAL` is set once by the migration and persists in the
  file; `synchronous=FULL` on every connection, so a committed event
  survives a power loss, not only a process crash.
- Every write is an explicit `BEGIN IMMEDIATE … COMMIT`. Readers never block
  writers and vice versa (WAL), writers serialise on the database lock with
  `busy_timeout` = `ORDO_JOURNAL_BUSY_TIMEOUT_MS` (5000).
- Crash safety: the hook `ORDO_JOURNAL_FAULT=before_commit` (raise) or
  `kill_before_commit` (SIGKILL) fires after every statement of a write and
  before `COMMIT`. The tests prove that an interrupted append/lease/approval
  leaves no row, no run_seq gap and an `integrity_check` of `ok`; SQLite
  discards the uncommitted WAL frames on the next open.
- Non-zero Python exits that are not journal errors (a traceback, a signal)
  surface as `internal_error` with `details.rc` and the stderr tail.
- The `-wal`/`-shm` sidecars are part of the database while any connection
  is open: copy all three files together, or checkpoint first
  (`python3 -c 'import sqlite3;sqlite3.connect(p).execute("PRAGMA wal_checkpoint(TRUNCATE)")'`).

## Recovery procedure

1. `ordo_journal_check` — prints `integrity_check`, row counts and any run
   whose `COUNT(run_seq) != MAX(run_seq)` (a gap can only come from manual
   surgery; the library never produces one).
2. `ordo_journal_rebuild_all` — recomputes every projection from the events
   and drops orphans. Projections are a cache: deleting the table is safe.
3. `ordo_journal_compat_export <run_id>` for each run whose legacy files must
   be re-emitted (for example after restoring `assignments.json` from a
   backup): the export is idempotent.
4. `ordo_journal_lease_expire_stale` — after a host crash, sweeps the leases
   whose holders are gone; the scheduler then re-queues from the projection.
5. If the database itself is unreadable, restore the three files
   (`ordo-journal.sqlite`, `-wal`, `-shm`) from backup, then repeat steps 1–3.
   Events are never rewritten: fixing a wrong state means appending a
   corrective event (`run.transition`, `blocker.resolved`), never editing rows.

## Change history

- #808 (epic #806): initial journal, projections, compat export, lease and
  approval CRUD, crash/concurrency tests.
- #810: additive — `ordo_journal_runs`, `payload.metadata` merged on every
  `run.*` event, `max_turns`/`max_tool_calls`/`max_cost` limits and
  `turns`/`tool_calls`/`cost` usage counters in the projection (numbers,
  not only integers).
