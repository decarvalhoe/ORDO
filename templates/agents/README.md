# Agent Templates

Templates in this directory are vendor-neutral starting points for configuring
local and remote agents that participate in an ORDO-coordinated fleet.

| File | Purpose |
| --- | --- |
| `local-skill-default.md` | Generic local-agent skill template. Defaults to issue-pack handoff; remote dispatch is forbidden. Copy and adapt per agent. |
| `direct-dispatch-exception.md` | Exception template for emergency direct dispatch. Requires explicit operator authorization and a valid dispatch matrix row before use. |
| `agent-config.sh.tpl` | Shell-style template for the agent config fields (display name, default prompt, allowed control plane, forbidden actions, audit root, GitHub identity, validation mode, external sidecar root). |
| `operator-policy.md` | Operator-side policy template covering authorization, audit trail, and rotation expectations for the agent. |

See `docs/external-agent-skills.md` for the doctrine these templates
implement, and `examples/agents/` for filled-in vendor-neutral examples.

## Usage

1. Pick the runtime example closest to the agent you are configuring under
   `examples/agents/`.
2. Copy the relevant templates from this directory into your operator-owned
   profile location (outside this repository).
3. Replace every `{{placeholder}}` and verify forbidden actions still include
   `remote-dispatch` for any local agent that is not the orchestrator.
4. Reference the resulting agent profile from your ORDO project profile.

Templates here must remain free of secret values, account names, host paths,
and live repository identifiers.
