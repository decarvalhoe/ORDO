# OTEL export

The toolkit can mirror every `audit` call to an OTLP HTTP collector while
keeping the existing text log as the source of truth.

## Design

- trigger: `ORCH_OTEL_ENDPOINT` must be set
- transport: OTLP HTTP JSON `POST` to `/v1/traces`
- execution model: best-effort and asynchronous
- failure policy: collector down or Python missing does not break the caller

Each audit event becomes one span. The span name is derived from the first word
of the audit message, for example `DISPATCH`, `POLL`, or `QUOTA_DETECT`.

Default span attributes:

- `project`
- `event_type`
- `audit.message`

Any `key=value` token present in the audit message is also forwarded as a span
attribute, which covers the common orchestrator fields such as:

- `agent`
- `ticket`
- `wave`
- `pattern`

## Environment

```bash
export ORCH_OTEL_ENDPOINT="http://127.0.0.1:4318/v1/traces"
export ORCH_OTEL_TIMEOUT_SEC="0.2"
export ORCH_OTEL_SERVICE_NAME="ordo"
export ORCH_OTEL_SCOPE_NAME="ordo.audit"
```

Optional:

```bash
export ORCH_OTEL_PYTHON_BIN="/usr/bin/python3"
```

## Local collector with Jaeger

The repository includes a local Jaeger stack:

```bash
docker compose -f examples/otel/docker-compose.yml up -d
```

Endpoints:

- OTLP HTTP ingest: `http://127.0.0.1:4318/v1/traces`
- Jaeger UI: `http://127.0.0.1:16686`

Quick smoke test:

```bash
export ORCH_OTEL_ENDPOINT="http://127.0.0.1:4318/v1/traces"
export ORDO_PROJECT_PROFILE=/secure/operator/project.config.sh
source examples/ordo.config.sh
source lib/audit_log.sh
audit_action DISPATCH agent=builder ticket=#123 wave=wave-5
```

Then open Jaeger UI and search for service `ordo`.

## Grafana / Tempo suggestions

If you already run Tempo, point `ORCH_OTEL_ENDPOINT` at the OTLP HTTP endpoint,
for example:

```bash
export ORCH_OTEL_ENDPOINT="http://tempo:4318/v1/traces"
```

Useful dashboard slices:

- event volume by `event_type`
- event volume by `agent`
- wave-specific traces filtered on `wave=<label>`
- CI and merge traces filtered on `event_type in (CI, PR, MERGE, POLL)`

Recommended first panels:

1. time series: count of spans grouped by `event_type`
2. bar chart: count of spans grouped by `agent`
3. trace search saved filter: `project="target-system"`
4. trace search saved filter: `wave="wave-<n>"`

## Operational notes

- Keep the text log enabled; OTEL is additive, not a replacement.
- The exporter runs in the background to keep audit latency low.
- When the collector is unreachable, the audit line is still written locally.

## Control-plane trace spans (`lib/ordo_trace.sh`, #812)

The audit mirror above turns each `audit` line into one standalone span. The
agentic control plane (epic #806) adds a second, additive source of telemetry:
real spans with parents, durations, events and status, written locally as JSON
lines under `$(state_dir)/traces/<trace_id>.jsonl` and exported on demand as
an OTLP/JSON `ResourceSpans` document. Nothing here changes the audit
exporter; both can feed the same collector.

- Model: `docs/architecture/tracing.md` (kinds `agent model tool policy
  approval retry provider`, one trace per run derived from the run id,
  redaction of every attribute, env secret and wrapped command line).
- Emit: `ordo_trace_start/end/event`, or wrap any command —
  `ordo_trace_wrap retry.attempt --kind retry -- bash scripts/dispatch_ticket.sh …`.
- Export and ship to the same endpoint as the audit mirror:

```bash
source lib/audit_log.sh          # state_dir (PROJECT must be set)
source lib/ordo_trace.sh
trace=$(ordo_trace_new_id trace "$RUN_ID")   # the run's trace id
ordo_trace_export "$trace" \
  | curl -sS -X POST -H 'Content-Type: application/json' --data-binary @- "$ORCH_OTEL_ENDPOINT"
```

The export is synchronous and explicit (no background push), so it never slows
a dispatch and never runs without an operator or a supervisor step asking for
it. The resource carries `service.name` (`ORDO_TRACE_SERVICE_NAME`, defaults to
`ORCH_OTEL_SERVICE_NAME`), `ordo.project` and `ordo.run_id`; the scope is
`ORDO_TRACE_SCOPE_NAME` (`ordo.trace`). In Jaeger/Tempo, search
`service=ordo` and filter on `ordo.run_id` to see approval → policy → provider
spans of one run next to the audit spans.
