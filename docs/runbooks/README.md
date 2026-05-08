# ORDO Runbooks

Operator runbooks for repeatable ORDO fleet operations. Each runbook is the
chat-history-free reference an operator follows for a recurring procedure. The
runbooks are generic and rely on operator-owned profiles for live topology.

| Runbook | Purpose |
| --- | --- |
| [Fleet preparation](fleet-preparation.md) | Bring up, audit, or debug a multi-agent fleet on a fresh or reused host. Covers preflight, setup, verification, and audit capture, with a findings table and a strict cleanup-forbidden default. |
| [API rate limiting](api-rate-limiting.md) | Shape orchestrator API call rate (per-pane jitter + token-bucket limiter) to keep aggregate fleet QPS under the per-org Anthropic limit and surface remaining 429 events to a structured audit sink (#409). |

## Conventions

- Runbooks are fail-closed: each refusal-mode preflight stops the operator
  before destructive or expensive next steps.
- Runbooks write evidence into a per-run directory under
  `evidence/<runbook-name>-<timestamp>/`.
- Runbooks reference existing ORDO scripts and library docs rather than
  duplicating them. The single source of truth for the universal fleet
  contract stays in [docs/universal-fleet-manual.md](../universal-fleet-manual.md).
- Runbooks do not change the CSV validation disposition recorded in
  [docs/validation/README.md](../validation/README.md).

## Adding A Runbook

When adding a new runbook:

1. Use the same four-phase structure (preflight, setup, verification, audit
   capture) when the procedure fits it.
2. Include a findings table mapping symptom, risk, durable ORDO procedure,
   and evidence artifact.
3. Reference existing scripts; do not introduce a parallel onboarding,
   provisioning, or reconfiguration track.
4. Keep examples generic. Live host names, account labels, repository
   identifiers, and tmux session names belong in operator-owned profiles, not
   in runbook examples.
5. Update this index and the [Documentation Map in README.md](../../README.md).
