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
source examples/rbok.config.sh
source lib/audit_log.sh
audit_action DISPATCH agent=claude ticket=#123 wave=wave-5
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
3. trace search saved filter: `project="rbok"`
4. trace search saved filter: `wave="wave-<n>"`

## Operational notes

- Keep the text log enabled; OTEL is additive, not a replacement.
- The exporter runs in the background to keep audit latency low.
- When the collector is unreachable, the audit line is still written locally.
