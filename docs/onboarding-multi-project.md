# Multi-project onboarding (issue #252)

Extends the existing `scripts/guided_onboarding.sh` flow so a single
operator can onboard a portfolio of projects without forking a second
onboarding system, hardcoding any single vendor (RBOK, Claude, Codex,
…), or duplicating the canonical `ordo.guided_onboarding_profile.v1`
schema.

## Why an extension, not a rewrite

The single-project profile and state remain the canonical onboarding
entry point. The multi-project surface is implemented as:

- six optional CLI flags on `scripts/guided_onboarding.sh`
  (`--project-alias`, `--default-branch`, `--validation-mode`,
  `--operator-class`, `--runtime-root`, `--agent-label`); and
- a wrapper `scripts/multi_project_onboarding.sh` that consumes a
  manifest and invokes the canonical script once per project, then
  aggregates the resulting profiles into a portfolio index.

No state or profile schemas are forked. Every per-project profile
written by the wrapper still validates against
`ordo.guided_onboarding_profile.v1`.

## Manifest schema

`scripts/multi_project_onboarding.sh --manifest <file>` reads JSON of
shape:

```json
{
  "schema_version": "ordo.multi_project_onboarding.manifest.v1",
  "portfolio_alias": "<string>",
  "projects": [
    {
      "alias":           "<string, required>",
      "default_branch":  "<string>",
      "validation_mode": "gxp" | "dev",
      "operator_class":  "internal" | "external",
      "runtime_root":    "<absolute path>",
      "agent_labels":    ["<string>", "..."],
      "repo_mode":       "existing" | "greenfield",
      "host_report":           "<path>",
      "repository_report":     "<path>",
      "bootstrap_report":      "<path>",
      "scaffold_report":       "<path>",
      "fleet_sizing":          "<path>",
      "provisioning_report":   "<path>"
    }
  ]
}
```

`alias` is the only required per-project field; everything else is
optional. The wrapper translates each entry into a single
`guided_onboarding.sh` invocation, propagating its arguments verbatim.

## Output schema

`scripts/multi_project_onboarding.sh` emits a portfolio index of shape
`ordo.multi_project_onboarding.portfolio.v1`:

```json
{
  "schema_version": "ordo.multi_project_onboarding.portfolio.v1",
  "portfolio_alias": "...",
  "status": "plan | applied | dry-run | blocked",
  "safe_to_apply": true | false,
  "projects": [
    {
      "alias": "...",
      "validation_mode": "gxp | dev",
      "operator_class":  "internal | external",
      "status": "plan | applied | blocked",
      "safe_to_apply": true | false,
      "exit_code": 0,
      "blockers": [...],
      "profile_path": "<file or null>",
      "state_path":   "<file or null>",
      "onboarding_profile": { /* ordo.guided_onboarding_profile.v1 */ }
    }
  ],
  "blockers": ["project_<alias>::<blocker>", "..."]
}
```

When any per-project run is unsafe, the wrapper exits `78` (the same
refusal exit code the single-project flow uses) and the portfolio
status is `blocked`. Per-project blockers are aggregated under a
`project_<alias>::<blocker>` namespace so wave orchestration can attach
the right project context to each remediation.

## Runtime root layout

Every project that supplies `--runtime-root <path>` (or sets
`runtime_root` in the manifest) gets the eight-subdirectory layout
documented in the issue:

| Subdir          | Purpose                                                                              |
|-----------------|--------------------------------------------------------------------------------------|
| `cache/`        | Derived data, indexes, downloaded artifacts. Safe to wipe for a clean rebuild.        |
| `repos/`        | Git checkouts, one subdirectory per agent label.                                      |
| `profiles/`     | Generated onboarding profiles + project configs (`*.config.sh`).                      |
| `logs/`         | Per-project audit-able logs. Rotated on a documented schedule under `validation_mode=gxp`. |
| `state/`        | ORDO state JSON (`assignments.json`, dispatch records).                               |
| `launch/`       | Reproducible launch scripts (tmux session boot, agent boot).                          |
| `audit/`        | Append-only audit trail per project. Append-only is mandatory under `validation_mode=gxp`.|
| `orchestrator/` | Orchestrator-private state. Never read by agents.                                     |

The wrapper computes these subdirs from `runtime_root` and surfaces
them under `onboarding_profile.runtime_root.subdirs` for downstream
verification (no directories are created by `guided_onboarding.sh`
itself; `scripts/fleet_provisioning.sh --apply` is the script that
materialises the layout).

## GxP-grade vs normal-dev mode

`validation_mode` is a per-project field with two valid values:

- **`gxp`** — validated workflow. Operator MUST treat the project's
  `audit/` subdir as append-only, MUST keep `logs/` rotated on a
  documented schedule, and MUST capture identity bindings (the ones
  surfaced under `inputs.summaries.repository_readiness.identity_bindings`)
  in the audit trail before any provisioning step.
- **`dev`** — normal-dev workflow. The runtime layout is still
  recommended but rolling buffers are acceptable in `audit/` and
  `logs/`. Identity bindings still need to be present, but the audit
  capture is informational rather than load-bearing.

Any other value is rejected pre-flight with `validation_mode_invalid`.
The portfolio refuses with exit `78` if any project supplies a
forbidden value.

## Internal operators vs external agents

`operator_class` is the per-project field that records who is driving
onboarding for a given project:

- **`internal`** — an operator inside the project's owning organisation.
  May resolve identity bindings from a private identity store, may
  declare `validation_mode=gxp`, and may use the
  `examples/ordo.config.sh`-style RBOKproject reference fixtures shipped
  in this repo as a starting point.
- **`external`** — an external agent contributing to a multi-project
  fleet. MUST bring their own `gh` / CLI credentials (verified via
  `gh auth status` before onboarding), SHOULD declare
  `validation_mode=dev` unless explicitly granted GxP scope by the
  internal operator, and MUST start from
  `examples/multi-project.portfolio.template.config.sh` rather than the
  RBOKproject reference fixtures.

Any other value is rejected pre-flight with `operator_class_invalid`.

## Existing onboarding verification

The existing onboarding verification suite is **extended**, not
bypassed:

- `tests/test_guided_onboarding.sh` keeps every previous assertion and
  adds three new cases — multi-project metadata surfaced under
  `onboarding_profile.project_metadata` and `runtime_root`, refusal on
  invalid `validation_mode`, refusal on invalid `operator_class`.
- `tests/test_multi_project_onboarding.sh` (new) drives the wrapper
  against a 2-project manifest and asserts the per-project profiles
  use the canonical `ordo.guided_onboarding_profile.v1` schema, the
  portfolio aggregate uses
  `ordo.multi_project_onboarding.portfolio.v1`, and a single bad
  `validation_mode` refuses the whole portfolio with exit `78`.
- `tests/test_onboarding_verification.sh` continues to verify the
  canonical profile/state without modification, proving the extension
  is backwards compatible.

The wrapper does not introduce any new exit codes; it reuses
`ORDO_GUIDED_ONBOARDING_REFUSAL_EXIT_CODE` (78) for refusals and
`exit 2` for malformed manifests. `docs/exit-codes.md` is unchanged.

## Examples

- `examples/multi-project.portfolio.template.config.sh` — generic,
  vendor-neutral starting point.
- `examples/ordo.config.sh`, `examples/portfolio.config.sh`,
  `examples/nomos.config.sh`, `examples/praxis.config.sh`,
  `examples/web.config.sh`, `examples/42t.config.sh`,
  `examples/rbok.config.sh` — RBOKproject reference fixtures.
  Treat them as worked examples, not templates.
