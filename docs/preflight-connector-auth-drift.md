# Codex Connector / MCP Auth Drift in Fleet Preflight

This page is generic. Live hostnames, account names, fleet-session names, and
provider-specific re-auth flows belong in the operator profile that invokes
ORDO, not in this repository.

## Why this exists (#748)

Codex TUI and fleet panes repeatedly surface two distinct symptoms of
connector / MCP auth drift that do not stop the agent CLI but pull operator
attention away from the real assignment:

1. **Codex connector directory drift** — the Codex TUI calls
   `chatgpt.com/backend-api/connectors/directory/list` on startup to
   populate the discoverable tool suggestions picker. When the user's
   ChatGPT session is unauthenticated or scoped down, that call returns
   `403 Forbidden` and the TUI logs `failed to load discoverable tool
   suggestions`. The CLI continues to run.
2. **MCP startup auth failures** — individual MCP servers (Cloudflare,
   Gmail, etc.) report `<name> MCP server is not logged in.` or
   `MCP startup incomplete (failed: ...)`. Existing ORDO code (#670)
   already classifies these as `blocking` / `degraded` / `nonblocking`.

Without preflight surfacing, both symptoms look fatal in pane captures
even when the assignment does not require those connectors.

## What the preflight surfaces

`scripts/host_health_preflight.sh` scans Codex / fleet pane log files
listed in the relevant env var and emits one structured HOST_HEALTH
metric per drift category:

```
HOST_HEALTH status=warning metric=codex_mcp_startup_failures value=<n> ...
HOST_HEALTH status=warning metric=codex_connector_directory_drift value=<n>
  unit=count symptoms=<token:hits>,... hint=codex_connector_reauth_or_disable_directory
  signals=codex_connector_directory_drift
```

Signals attached to the summary line:

- `mcp_unavailable:<name>` — one per MCP server that failed startup auth.
- `codex_connector_directory_drift` — connector directory probe drift.

Both signals are warnings by default; only required-list MCPs (via
`HOST_HEALTH_REQUIRED_MCP_SERVERS`) or
`HOST_HEALTH_CODEX_CONNECTOR_DIRECTORY_REQUIRED=1` escalate to critical
and trigger `--refuse` exit 7.

## Env vars

| Variable | Purpose |
| --- | --- |
| `HOST_HEALTH_CODEX_STARTUP_LOGS` | Colon-separated list of pane / debug log files scanned for MCP startup failures *and* (by default) connector directory drift. |
| `HOST_HEALTH_CODEX_CONNECTOR_LOGS` | Optional override — colon-separated list scanned only for connector directory drift. Useful when the Codex TUI log is separate from the MCP startup log. Falls back to `HOST_HEALTH_CODEX_STARTUP_LOGS` when unset. |
| `HOST_HEALTH_REQUIRED_MCP_SERVERS` | Comma-separated MCP names that should escalate startup failures from warning to critical. |
| `HOST_HEALTH_CODEX_CONNECTOR_DIRECTORY_REQUIRED` | Set to `1` to escalate connector directory drift from warning to critical (so `--refuse` exits 7 when drift is present). |

## Library helpers

`lib/mcp_permission_preflight.sh` exposes:

- `mcp_preflight_detect_connector_directory_drift <log>` — echoes one symptom
  token per line: `directory_list_403`, `tool_suggestions`. Missing log => no
  output, rc=0.
- `mcp_preflight_count_connector_directory_drift <log>` — echoes one
  `<symptom>=<count>` pair per line in stable order.
- `mcp_preflight_classify_connector_directory_log <log> [<severity>]` —
  emits one `CODEX_CONNECTOR_DIRECTORY_DRIFT` record per detected symptom.
  Default severity is `warning` (audit-only, rc=0). Pass `blocking` to opt
  in to rc=1 so a caller can refuse-on-startup.

The detection is universal: the same patterns appear in Codex TUI logs and
in fleet pane captures, and the helpers do not assume a particular CLI
build.

## Operator action

When the metric appears:

1. **Capture evidence** — keep the pane capture or log file that triggered
   the warning; the symptom tokens (`directory_list_403`,
   `tool_suggestions`, `mcp_unavailable:<name>`) are the searchable keys.
2. **Decide whether the connector / MCP is required for this wave** —
   if not, the warning is operator-acknowledged noise and no further
   action is needed. If yes, escalate via the env var listed above so
   the next preflight refuses fleet expansion until re-auth completes.
3. **Re-auth or disable** — re-authenticate the affected connector via
   the operator-profile flow, or disable the discoverable tool
   directory probe / MCP plugin for hosts that do not need it.

## Verification

```bash
timeout 30 bats tests/test_mcp_auth_drift.bats
timeout 120 bash tests/test_host_health_preflight.sh
timeout 120 bash tests/test_mcp_auth_classification.sh
```
