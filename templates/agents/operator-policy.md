# Operator Policy Template — Per Agent

This template captures the operator-side policy that wraps an agent's local
skill and config. It is the human-readable companion to
`templates/agents/agent-config.sh.tpl`. Copy it next to the agent profile in
the operator-owned policy directory and keep it updated when authorization,
identity, audit root, or validation mode changes.

## Identity

- agent label: `{{agent_label}}`
- display name: `{{display_name}}`
- short description: `{{short_description}}`
- runtime: `{{vendor_or_cli}}` (Claude / Codex / Cursor / Copilot / Gemini /
  generic CLI)
- GitHub identity (or provider equivalent): `{{provider_account}}`
- workdir: `{{absolute_path}}`
- tmux target (if applicable): `{{session}}:{{window}}.{{pane}}`

## Default Prompt Source of Truth

- file: `{{absolute_path_to}}/local-skill-default.md`
- last operator review: `{{iso8601_date}}`
- review owner: `{{operator_label}}`
- changes since template: `{{summary_or_none}}`

A change to the default prompt requires a fresh operator review and an audit
line referencing the new prompt SHA.

## Allowed Control Plane

Mirror the `ORDO_AGENT_ALLOWED_CONTROL_PLANE` array from the agent config.
Justify each non-default entry:

- `issue-pack-handoff` — required so the agent can hand work to the
  orchestrator instead of dispatching directly.
- `local-tests` — required for cheap foreground validators on changed files.
- `read-only-status` — required so the agent can read fleet/issue/PR signals.
- `{{additional_surface}}` — `{{justification}}`

## Forbidden Actions

Mirror the `ORDO_AGENT_FORBIDDEN_ACTIONS` array. Add agent-specific items as
needed; never remove the defaults below from a non-orchestrator agent:

- `remote-dispatch`
- `force-push`
- `merge-without-gate`
- `secret-write`
- `bypass-validation`
- `cross-product-mutation`

## Authorization for Direct Dispatch

Direct dispatch (sending a brief straight to a target agent's terminal) is an
exception path. Document any standing authorization here:

- standing authorization: `{{none|specific_scope}}`
- expires: `{{iso8601_date|na}}`
- evidence: `{{controlled_operation_id|na}}`

If standing authorization is `none`, every direct dispatch must follow
`templates/agents/direct-dispatch-exception.md` and produce a fresh
controlled-operation evidence file.

## Audit Root

- destination: `{{absolute_path_or_remote}}`
- retention: `{{retention_policy}}`
- access controls: `{{who_can_read_or_write}}`
- secrets policy: audit lines must never include token values, environment
  dumps, or `set -x` output. Validate by inspecting a recent log slice
  before each rotation review.

## Validation Mode

- declared mode: `ci-delegated`  (or `require-local-validators` with a dated
  operator note explaining why the host can sustain it)
- last validation evidence reference: `{{ci_run_url_or_pr_check}}`

## Identity and Credential Rotation

- provider account owner: `{{operator_label}}`
- credential storage: `{{operator_credential_source}}` (must be operator
  controlled, never inside this repository)
- rotation cadence: `{{cadence}}`
- last rotation: `{{iso8601_date}}`

Follow `SECRETS.md` for the full rotation and leak-response procedures.

## Review Checklist

- [ ] Agent config self-check passes
  (`ordo_agent_config_self_check`).
- [ ] Default prompt file SHA matches the operator-approved version.
- [ ] Forbidden actions still include `remote-dispatch` (or this agent is the
  designated orchestrator and the deviation is documented above).
- [ ] Audit root is reachable and recent lines contain no secret material.
- [ ] Validation mode matches the latest dispatch policy.
- [ ] Standing direct-dispatch authorization, if any, has not expired.
- [ ] Provider credential rotation is current.
