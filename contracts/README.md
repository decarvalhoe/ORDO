# ORDO execution contracts

This directory is the home of the **canonical, versioned contracts** that every
module of the ORDO agentic control plane exchanges: `run`, `task`, `attempt`,
`agent`, `lease`, `event`, `approval`, `artifact`, `policy_decision` and
`blocker`, plus the state-transition tables, the redaction rules and the
shared error-object / exit-code convention. It was introduced by issue #807
(epic #806). The architecture page is
[docs/architecture/contracts.md](../docs/architecture/contracts.md).

## Layout and where the data lives

| Path | Role |
| --- | --- |
| `lib/ordo_contracts.sh` | **Source of truth.** Schemas, transition tables, exit map and redaction rules are embedded there so the sanitized test runners (which only mirror `*.sh`, `*.md`, `*.bats`, fixtures) can exercise them. |
| `contracts/v1/emit.sh` | CLI over the library: print schemas, tables, exit codes; validate or redact a document; write `<kind>.schema.json` files. Carries no data of its own. |
| `contracts/README.md` | This page: the rules every writer and reader of a contract object must respect. |
| `tests/fixtures/contracts/v1/` | One `<kind>.valid.json`, one `<kind>.invalid.json` and one `compat/<kind>.extra-fields.json` per kind. |
| `tests/ordo_contracts.bats` | Fixture validation, transition, redaction, id and exit-code tests. |
| `docs/architecture/contracts.md` | Field-by-field reference, state diagrams, error object, design decisions. |

```bash
source lib/ordo_contracts.sh
ordo_contracts_schema run | jq .            # print a schema
contracts/v1/emit.sh schemas > /tmp/all.json
contracts/v1/emit.sh write-schemas build/schemas/   # one file per kind
contracts/v1/emit.sh validate event @tests/fixtures/contracts/v1/event.valid.json
```

## Versioning rule

- Every object carries `schema_version`. The current value is `"1"`; schemas
  are published under `contracts/v1/` and their `$id` ends in
  `/contracts/v1/<kind>.schema.json`.
- **Additive changes stay in v1**: adding an optional field, adding a value to
  an enum that no consumer switches on exhaustively, adding a new kind,
  relaxing a constraint. Readers must therefore accept fields they do not
  know (`additionalProperties: true` everywhere) — the
  `tests/fixtures/contracts/v1/compat/` set proves it.
- **Breaking changes open a new major**: removing or renaming a field, making
  an optional field required, narrowing a type or an enum, changing an id
  format or a transition table in a way that rejects previously valid
  histories. They ship as `contracts/v2/`, `schema_version: "2"`, a new
  fixture set, and a documented migration in `docs/architecture/contracts.md`.
  v1 stays readable until every persisted journal has been migrated.
- Never edit a published schema silently: change `lib/ordo_contracts.sh`, the
  fixtures and the docs in the same PR; `tests/ordo_contracts.bats` guards
  that `contracts/v1/emit.sh` and the library agree.

## Common envelope

Every object, whatever its kind, carries:

| Field | Type | Rule |
| --- | --- | --- |
| `schema_version` | string | `"1"` |
| `kind` | string | one of the ten kinds; equals the schema used to validate it |
| `id` | string | `<kind>_<24 lowercase hex>`, from `ordo_contracts_new_id <kind>` |
| `created_at` | string | RFC3339 **UTC** with `Z` suffix, from `ordo_contracts_now` (`2026-09-11T05:00:00Z`, fractional seconds allowed) |
| `correlation_id` | string | non-empty, see below |
| `actor` | object | `{"type": "operator|agent|system|model", "id": "<non-empty>"}` |

## Correlation IDs

`correlation_id` ties together every object of one causal chain so a trace,
a journal query or a log grep can reconstruct what happened from a single
value. Rules:

- The root of a chain is a `run`; its `correlation_id` **is its own id**
  (`run_<hex>`). Every task, attempt, lease, event, approval, artifact,
  policy decision and blocker produced for that run copies the same value.
- A correlation id is opaque to consumers: never parse it, never derive
  authorization from it, never reuse one across runs.
- Objects created outside any run (an `agent` declaration, a fleet-level
  blocker) use a fresh `run`-shaped id or the id of the operation that
  created them; they still must not leave the field empty.
- When a run spawns a child run, the child gets its own id as
  `correlation_id` and records the parent in `metadata.parent_run_id`; the
  link is explicit, not encoded in the id.

## Idempotency keys

`idempotency_key` is the guarantee that **replaying a journal never repeats a
side effect**.

- Required on every `event` with `mutation: true` and on every `approval`
  (the schema enforces both; `ordo_contracts_validate` fails with
  `invalid_contract` otherwise). Optional elsewhere.
- Deterministic: the same intended side effect must produce the same key
  on every attempt, e.g. `run_<hex>:pr.merge:<pr number>` or
  `run_<hex>:approval:<action>`. Random keys defeat the purpose.
- Unique per side effect: the journal stores it in a `UNIQUE` column and
  refuses a duplicate with exit 5 / `duplicate_event`. Consumers treat that
  refusal as "already done", not as an error to retry.
- Every provider `mutate` call takes `--idempotency-key` and forwards the
  same key to the provider when it supports one.

## Actor identity

`actor` says **who produced the object**, never who is allowed to act:

- `operator` — a human at the console or an operator-owned automation
  (`id`: operator handle or `operator:<name>`).
- `agent` — a fleet worker; `id` is the neutral slot label or the agent
  contract id (`fleet-001`, `agent_<hex>`), never the model or provider.
- `system` — deterministic ORDO code (`scheduler`, `journal`,
  `external_mutation_gate`, ...).
- `model` — output of an LLM. A `model` actor can propose (a `task`, a
  `blocker`, a suggested `policy_decision` input) but **never** owns
  authorization, persistence, scheduling or an irreversible mutation. Any
  object of kind `approval`, `lease`, `policy_decision` or a mutating
  `event` whose actor is `model` must be refused by the consumer with exit 3
  (`policy_refused`); the schema does not encode that rule because it is a
  policy, not a shape.

MCP tool metadata, provider webhooks and dispatch briefs are inputs; they
never become an `actor` of type `operator` on their own.

## Redaction rules

`ordo_contracts_redact <json>` must be applied before any object is written
to a log, an artifact, a PR body, a trace exporter or a model prompt.

- **Keys**: any key matching `(?i)(token|secret|password|passwd|api[_-]?key|authorization|cookie)`
  at any depth has its value replaced by the string `"[REDACTED]"`.
- **Values**: any string, at any depth (including inside arrays), has every
  match of `gh[pousr]_[A-Za-z0-9]{20,}`, `sk-[A-Za-z0-9]{20,}` and
  `Bearer [A-Za-z0-9._-]{20,}` replaced by `[REDACTED]`.
- The output is still valid JSON with the same shape; redaction is
  idempotent; it never removes keys (so schemas still validate) and never
  touches non-string values.
- Redaction is not authorization: a redacted object is still subject to the
  same policy decisions as the original. Set `artifact.redacted: true` once a
  stored artifact body has been passed through the function.

## Errors and exit codes

Every new surface prints one JSON line on stderr and exits with the mapped
code — see `contracts/v1/emit.sh exit-codes` and
[docs/architecture/contracts.md](../docs/architecture/contracts.md#error-objects-and-exit-codes).
Existing scripts keep their historical exit codes (`docs/exit-codes.md`).
