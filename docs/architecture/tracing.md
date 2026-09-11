# ORDO trace spans

Audience: operator, developer. Category: developer docs / API reference.

`lib/ordo_trace.sh` (issue #812, epic #806) records OpenTelemetry-compatible
spans for agent, model, tool, policy, approval, retry and provider operations
as local JSON lines, and exports them as an OTLP/JSON `ResourceSpans`
document. It is provider-, model- and framework-neutral, needs only bash, jq
and coreutils, and never writes an attribute before redacting it. The existing
audit → OTLP mirror ([docs/otel-export.md](../otel-export.md)) is untouched;
this is the span model for the new control-plane modules.

## Where things live

| Path | Content |
| --- | --- |
| `lib/ordo_trace.sh` | The library. |
| `$(state_dir)/traces/<trace_id>.jsonl` | One file per trace (override the directory with `ORDO_TRACE_DIR`). |
| `$(state_dir)/traces/spans.index` | `span_id trace_id` lines so `ordo_trace_end <span_id>` finds its file. |
| `tests/ordo_trace.bats` | 7 tests: lifecycle, parent linking, export shape, redaction, wrap, errors. |

## Span model

A span is identified by a 32-hex `trace_id` and a 16-hex `span_id` (OTLP
sizes). The trace id is `ORDO_TRACE_ID` when set, else derived from
`ORDO_RUN_ID` (`sha256(run_id)[0:32]`, so one run is one trace), else random.

```
{"trace_id","span_id","parent_span_id","name","kind",
 "start_time_unix_nano","end_time_unix_nano",
 "status":{"code":"UNSET|OK|ERROR","message"},
 "attributes":{...},
 "resource":{"service.name":"ordo","ordo.project":"<PROJECT>","ordo.run_id":"<run>"},
 "events":[{"name","time_unix_nano","attributes"}]}
```

`kind` is one of `agent model tool policy approval retry provider internal`
(`ORDO_TRACE_KINDS`). The file is **append-only**: every call appends one line
carrying that field set plus `phase` (`start`, `event`, `end`); readers fold
the lines per `span_id` (start fields, last end, events in order). Nothing is
rewritten, so concurrent writers (a wrapped command and its parent) cannot
corrupt each other; writes are serialised with `flock`.

## API

```
ordo_trace_start <name> [--kind K] [--parent SPAN_ID] [--trace TRACE_ID] [--attr k=v ...]   # prints span_id
ordo_trace_end <span_id> [--status ok|error|unset] [--message M] [--attr k=v ...]
ordo_trace_event <span_id> <name> [--attr k=v ...]
ordo_trace_wrap <name> [--kind K] [--parent ID] [--trace ID] [--attr k=v ...] -- <command...>
ordo_trace_span <span_id> | ordo_trace_spans <trace_id>          # folded JSON
ordo_trace_export <trace_id> [--format otlp-json|jsonl]
ordo_trace_id | ordo_trace_new_id trace|span [seed] | ordo_trace_dir | ordo_trace_redact <json>
```

- Attribute values that look like integers, floats or booleans are typed;
  everything else is a string. `--attr` may repeat.
- The default parent is `ORDO_TRACE_PARENT_SPAN`; `ordo_trace_wrap` exports
  `ORDO_TRACE_ID` and `ORDO_TRACE_PARENT_SPAN` to the wrapped command, so any
  module — the scheduler's retry loop, an adapter, a dispatched script — links
  its spans without sourcing this library, and a command that ignores them
  still gets a correctly timed span.
- `ordo_trace_wrap` maps exit 0 to `status.code=OK` and anything else to
  `ERROR` with `message="exit <rc>"` and `ordo.exit_code`; the command's exit
  code passes through unchanged. It records `ordo.command` (the shell-quoted
  argv, redacted) and `ordo.command.argv0`; the default kind is `tool`.
- `ORDO_TRACE_ENABLED=0` turns every call into a no-op (ids are still printed).
- Clock: `ORDO_TRACE_NOW_NS`, else `ORDO_JOURNAL_NOW` (tests pin it), else
  `date +%s%N`.
- Errors: one JSON line, module `trace`; 2 usage / unknown kind or status,
  4 unknown span or trace.

## Export

`ordo_trace_export <trace_id>` prints an OTLP/JSON document:

```
{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"ordo"}},...]},
  "scopeSpans":[{"scope":{"name":"ordo.trace","version":"1"},
    "spans":[{"traceId","spanId","parentSpanId","name","kind",
              "startTimeUnixNano","endTimeUnixNano","attributes":[{"key","value":{...}}],
              "status":{"code":0|1|2,"message"},"events":[...]}]}]}]}
```

Spans are grouped by resource; `kind` becomes the OTLP integer (`provider` →
`CLIENT`=3, everything else `INTERNAL`=1) and the ORDO kind survives as the
attribute `ordo.span.kind`; status codes map `UNSET/OK/ERROR` → `0/1/2`;
values become `stringValue` / `intValue` / `doubleValue` / `boolValue`.
`--format jsonl` prints the folded spans one per line. Send the document to a
collector with any HTTP client, e.g.
`ordo_trace_export "$trace" | curl -sS -X POST -H 'Content-Type: application/json' --data-binary @- "$ORCH_OTEL_ENDPOINT"`.

## Redaction guarantees

Every span name, event name, status message, attribute value and wrapped
command line goes through `ordo_trace_redact` before it reaches a file:

1. `ordo_contracts_redact` — keys matching
   `(?i)(token|secret|password|passwd|api[_-]?key|authorization|cookie)` become
   `"[REDACTED]"`; values matching `gh[pousr]_…`, `sk-…`, `Bearer …` are masked
   wherever they appear;
2. the literal value of every exported environment variable whose **name**
   matches that key regex (8+ characters) is masked wherever it appears — so a
   forge token read from `GH_TOKEN`/`ORDO_FORGE_TOKEN…` never lands in a trace
   even when it does not match a known token shape;
3. `ORDO_TRACE_REDACT_RE` (optional, jq regex) is masked as well.

Exports read from the redacted files, so they cannot leak more than the files.
`tests/ordo_trace.bats` injects a fake `ghp_…` token through an attribute, an
exported `FAKE_FORGE_TOKEN` and a wrapped `curl`-like command line and greps
the whole traces directory and both export formats for it.

## Spans emitted by the approval bridge

`ordo_approval_authorize_and_run` ([approvals.md](approvals.md)) produces, in
the run's trace: `approval.authorize` (kind `approval`, root) →
`policy.reauthorize` (kind `policy`, with a `policy.decided` event carrying the
decision and reasons) and `provider.<op>` (kind `provider`, with the adapter,
scope, idempotency key and `provider.replayed`). Refusals end the spans with
`status.code=ERROR` and the reason as message.
