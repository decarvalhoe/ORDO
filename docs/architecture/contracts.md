# ORDO execution contracts (v1)

Audience: developer, integrator. Category: developer docs / API reference.

This page is the field-level reference for the canonical, versioned objects
that the ORDO agentic control plane exchanges (issue #807, epic #806). The
rules that govern writers and readers of those objects (versioning,
correlation, idempotency, actor identity, redaction) are in
[contracts/README.md](../../contracts/README.md); this page explains the
shapes, the state machines, the error convention and the design decisions.

Nothing here changes existing dispatch behaviour. The library is additive:
`lib/ordo_contracts.sh` is sourced only by the new `ordo_*` modules.

## Where things live

| Path | Content |
| --- | --- |
| `lib/ordo_contracts.sh` | The library and the **only** copy of the data (schemas, tables, exit map, redaction regexes). |
| `contracts/v1/emit.sh` | CLI that prints/validates/redacts through the library; `write-schemas <dir>` materialises `<kind>.schema.json` files for external tooling. |
| `contracts/README.md` | Rules: versioning, correlation ids, idempotency keys, actor identity, redaction. |
| `tests/fixtures/contracts/v1/` | `<kind>.valid.json`, `<kind>.invalid.json`, `compat/<kind>.extra-fields.json`. |
| `tests/ordo_contracts.bats` | 45 tests: fixtures, transitions, redaction, ids, errors, emit.sh sync. |

Why the data is embedded in a bash file: `scripts/run_bats.sh`,
`scripts/run_shell_tests.sh` and `scripts/run_shellcheck.sh` copy the repo
into a sanitized temp root and only mirror `*.sh`, `*.bash`, `*.bats`,
`*.md`, `*.txt`, `*.tpl` files plus `tests/fixtures/**`. A `contracts/*.json`
tree would be invisible to the suites. The three runners now also mirror
`contracts/` (one extra path in their `find` list) so that `emit.sh` is
tested and linted like any other script, but the library never depends on
that directory being present.

## Public API

```bash
source lib/ordo_contracts.sh

ordo_contracts_kinds                          # one kind per line
ordo_contracts_new_id <kind>                  # run_3f9c...  (<kind>_<24 hex>)
ordo_contracts_now                            # 2026-09-11T05:00:00Z
ordo_contracts_validate <kind> <json>         # 0 ok | 5 + error object on stderr
ordo_contracts_transition <table> <from> <to> # 0 ok | 5 + error object   (table: run|approval|lease)
ordo_contracts_is_terminal <table> <state>    # 0 terminal | 1 not terminal
ordo_contracts_redact <json>                  # masked JSON on stdout
ordo_contracts_schema <kind>                  # JSON-Schema-like document
ordo_contracts_error <module> <code> <message> [details-json]
                                              # prints the error object, returns the mapped exit code
# supporting helpers
ordo_contracts_exit_code <code>               # 0..8
ordo_contracts_exit_codes                     # {"<code>": <exit>, ...}
ordo_contracts_transitions <table>            # {"<from>": ["<to>", ...]}
ordo_contracts_tables                         # run approval lease
```

`<json>` is a literal string, `-` (stdin) or `@<path>` (file). Validation
never mutates the input and never redacts; redaction never validates.

Typical use in a module:

```bash
ordo_contracts_validate event "$event_json" || return $?      # error already on stderr
ordo_contracts_transition run "$cur" "$next" || return $?
if ordo_contracts_is_terminal run "$state"; then ...; fi
ordo_contracts_error journal duplicate_event "idempotency key already journaled" \
  "$(jq -cn --arg k "$key" '{"idempotency_key": $k, "retryable": false}')"; return $?
```

## The ten kinds

Every object carries the common envelope (`schema_version` `"1"`, `kind`,
`id`, `created_at`, `correlation_id`, `actor`) and the kind-specific fields
below. Required fields are in bold; every schema also accepts unknown extra
fields (forward compatibility). Ids referenced by other objects must match
`^<kind>_[0-9a-f]{24}$`.

| Kind | Purpose | Kind-specific fields |
| --- | --- | --- |
| `run` | One unit of orchestrated work (usually a ticket) that owns tasks and the budget. | **state**, **project**, ticket_ref, title, tasks[], budget{max_attempts,max_seconds,max_tokens}, updated_at, labels[], metadata |
| `task` | A schedulable step inside a run. | **run_id**, **state**, **title**, depends_on[], attempts[], assignee (agent id), priority, updated_at, metadata |
| `attempt` | One execution of a task by one agent under one lease; retries append, never rewrite. | **run_id**, **task_id**, **agent_id**, **attempt_no** (≥1), **state**, lease_id, started_at, ended_at, exit_code, evidence[] (artifact ids), error{code,message,...}, metadata |
| `agent` | A worker identity: slot + runtime + provider. Identity is the slot, never the model. | **name**, **slot**, **runtime**, **provider**, pane, capabilities[], status (idle/busy/degraded/offline), metadata |
| `lease` | Exclusive, expiring ownership of a run/task. | **run_id**, **owner**, **state**, **expires_at**, task_id, heartbeat_at, ttl_seconds, generation, metadata |
| `event` | Append-only journal entry. | **run_id**, **type** (`^[a-z][a-z0-9_.]*$`), **payload**{}, **mutation** (bool), idempotency_key (required when mutation=true), run_seq, metadata |
| `approval` | Human/policy gate for one action. | **run_id**, **action**, **principal**, **policy_version**, **state**, **idempotency_key**, expires_at, decided_at, decided_by{type,id}, reason, result{}, metadata |
| `artifact` | Evidence stored by reference. | **run_id**, **type**, **uri**, attempt_id, media_type, sha256, size_bytes, redacted, metadata |
| `policy_decision` | Deterministic verdict of a policy over one subject. | **run_id**, **policy**, **policy_version**, **subject**, **decision** (allow/deny/require_approval), **reasons**[], approval_id, inputs_digest, metadata |
| `blocker` | Something outside the run's control that stops progress. Never auto-resolves. | **run_id**, **type**, **severity** (info/warning/blocking), **summary**, task_id, state (open/resolved), external_ref, resolved_at, resolution, metadata |

`ordo_contracts_schema <kind>` prints the authoritative version of this table
with types, patterns, enums and descriptions.

## State tables

`run`, `task` and `attempt` share one vocabulary so the scheduler, the
journal projection and the CLI print the same words. A state with no
outgoing transition is terminal; `ordo_contracts_transition` refuses any
move out of it, including to itself, and no non-terminal state
self-transitions.

### `run` table (run, task, attempt)

```
queued            -> leased | cancelled | expired
leased            -> running | queued | expired | cancelled
running           -> waiting | blocked | approval_required | succeeded | failed | cancelled
waiting           -> running | expired | cancelled | failed
blocked           -> running | queued | failed | cancelled
approval_required -> running | queued | expired | cancelled | failed
terminal: succeeded, failed, cancelled, expired
```

### `approval` table

```
pending -> granted | denied | expired
granted -> consumed | expired
terminal: denied, consumed, expired
```

### `lease` table

```
active  -> renewed | released | expired
renewed -> renewed | released | expired
terminal: released, expired
```

A refused transition prints, for example:

```json
{"error":{"code":"invalid_transition","message":"transition queued -> running is not allowed in table run","module":"contracts","details":{"table":"run","from":"queued","to":"running","allowed":["leased","cancelled","expired"],"terminal":false}}}
```

## Error objects and exit codes

Every new ORDO surface (contracts, journal, CLI, scheduler, adapters,
approval, trace, eval) reports failure the same way: **one JSON line on
stderr**, nothing on stdout, and an exit code from the table below.

```json
{"error":{"code":"<snake_case>","message":"<human>","module":"<module>","details":{...}}}
```

| Exit | Meaning | Codes mapped by `ordo_contracts_error` |
| --- | --- | --- |
| 0 | ok | `ok` |
| 1 | generic failure | `generic_failure`, `internal_error`, any unlisted code |
| 2 | usage / bad arguments | `usage`, `bad_argument`, `unknown_command`, `unknown_kind`, `unknown_table` |
| 3 | refused (policy / fail-closed) | `refused`, `policy_refused`, `fail_closed` |
| 4 | not found | `not_found` |
| 5 | invalid state / transition / conflict | `invalid_state`, `invalid_transition`, `invalid_contract`, `invalid_json`, `unknown_state`, `conflict`, `duplicate_event` |
| 6 | missing dependency (python3, tmux, provider CLI) or feature not yet available | `missing_dependency`, `not_implemented`, `provider_not_available` |
| 7 | budget exhausted | `budget_exhausted` |
| 8 | lease lost / stale | `lease_lost`, `lease_stale` |

Conventions:

- `details` is always an object. Pass `{}`-shaped JSON; a scalar is wrapped
  as `{"value": ...}` and a non-JSON string as `{"raw": "..."}` so the line
  stays parseable.
- Adapters add `details.retryable: true|false`; the journal adds
  `details.idempotency_key` on `duplicate_event`.
- Existing scripts keep their historical exit codes; the table above applies
  to the `ordo_*` modules and `scripts/ordo.sh` only. `docs/exit-codes.md`
  gains this table through the CLI child (#809).

Why exit 5 for invalid JSON input: the argument was supplied but the object
is unusable, which is a state problem for the caller, not an argument-parse
problem; exit 2 is reserved for wrong kinds, tables and arities so a wrapper
can tell "you called me wrong" from "your data is wrong".

## Validation semantics

`ordo_contracts_validate` interprets the schema subset the library emits:
`type` (`string`, `integer`, `number`, `boolean`, `object`, `array`),
`const`, `enum`, `pattern`, `minLength`, `minimum`, `format: date-time`,
`properties`, `required`, `items`, and `allOf[{if, then}]`. It reports
**every** violation, each with a JSON path:

```json
{"error":{"code":"invalid_contract","message":"object does not satisfy the run v1 contract","module":"contracts","details":{"kind":"run","schema_version":"1","errors":["$.project: required field missing","$.state: value \"done\" not in [...]"]}}}
```

- `date-time` means RFC3339 **UTC with a `Z` suffix** (`YYYY-MM-DDTHH:MM:SS[.fff]Z`);
  offsets are rejected on purpose so journals sort lexically and never need
  timezone arithmetic. Impossible dates (month 13) are rejected too.
- The validator is deterministic, stdlib-only (jq) and never performs I/O
  beyond reading the input.
- A validator run that crashes (never expected) surfaces as `internal_error`
  / exit 1, not as a silent pass: validation is fail-closed.

## Redaction

`ordo_contracts_redact` is the single place where secrets are scrubbed
before an object reaches a log, artifact, PR body, trace or model prompt:

- keys matching `(?i)(token|secret|password|passwd|api[_-]?key|authorization|cookie)`
  get the value `"[REDACTED]"` (key kept, so schemas still validate);
- strings anywhere have `gh[pousr]_[A-Za-z0-9]{20,}`, `sk-[A-Za-z0-9]{20,}`
  and `Bearer [A-Za-z0-9._-]{20,}` replaced by `[REDACTED]`;
- the function is idempotent and leaves non-string values untouched.

## Versioning and compatibility

- `schema_version` is `"1"` for every kind; the schemas' `$id` is
  `https://ordo.invalid/contracts/v1/<kind>.schema.json` (a reserved,
  non-resolvable host: the id is an identifier, not a download location).
- Additive changes (new optional field, new kind, relaxed constraint) stay
  in v1. Readers must ignore unknown fields — enforced by
  `additionalProperties: true` and the `compat/` fixtures.
- Breaking changes create `contracts/v2/`, `schema_version: "2"`, new
  fixtures and a migration note here. Both majors stay readable while any
  journal still holds v1 objects.
- The transition tables are part of the contract: removing an edge is a
  breaking change (persisted histories would fail replay); adding an edge
  is additive.

## Design decisions to preserve

1. **No LLM in the loop.** `actor.type: "model"` is a provenance label. The
   schemas do not encode authorization because it is policy; consumers must
   refuse (exit 3) any lease, approval, policy decision or mutating event
   authored by a model.
2. **Fail-closed validation.** Missing required fields, unknown states,
   unknown tables and validator crashes all fail; there is no permissive
   mode and no environment switch to skip validation.
3. **Replay safety is a schema property.** `idempotency_key` is required
   by shape on mutating events and approvals, so a journal cannot even store
   a replay-unsafe side effect.
4. **One source of truth.** `contracts/v1/emit.sh` and the tests read the
   library; nothing else re-declares a schema, a table or an exit code.
   `tests/ordo_contracts.bats` fails on drift.
5. **Provider/model/framework neutral.** No field names a vendor; the
   `agent` contract identifies a slot, `artifact` a URI, `policy_decision` a
   policy name and version.

## Testing

```bash
bats tests/ordo_contracts.bats           # focused
shellcheck -x lib/ordo_contracts.sh contracts/v1/emit.sh
bash scripts/run_bats.sh                 # aggregate (mirrors contracts/ too)
```

Fixtures are deterministic (`0123456789abcdef01234567` ids, a fixed
timestamp) so diffs stay reviewable; regenerate them by hand when a schema
changes and keep one distinct violation per `<kind>.invalid.json`.
