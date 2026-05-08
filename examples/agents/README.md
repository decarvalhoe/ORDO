# Agent Examples — Vendor-Neutral

This directory ships sample agent profiles for common runtimes. They are
**examples only**:

- ORDO does not load any of them by default.
- They are not implied recommendations for any specific vendor.
- Each file is a placeholder that an operator must copy into their own
  profile location and fill in.

| Example | Runtime hint |
| --- | --- |
| `claude.agent.example.sh` | Anthropic Claude CLI / IDE extension. |
| `codex.agent.example.sh` | OpenAI Codex CLI. |
| `cursor.agent.example.sh` | Cursor IDE agent. |
| `copilot.agent.example.sh` | GitHub Copilot CLI / chat. |
| `gemini.agent.example.sh` | Google Gemini CLI. |
| `generic-cli.agent.example.sh` | Any other terminal-driven agent. |

All examples implement the agent config fields documented in
`docs/external-agent-skills.md` and use the local skill template
(`templates/agents/local-skill-default.md`) as their default prompt. Forbidden
actions include `remote-dispatch`; only the orchestrator agent may remove
that entry, with the deviation documented in the operator policy template.

Operators must:

1. Copy a file into their operator-owned profile directory (outside this
   repository).
2. Replace every `{{placeholder}}`.
3. Verify the file contains no secret values.
4. Reference the resulting file from the project profile alongside
   `examples/ordo.config.sh`.

See `SECRETS.md` for the rules these example files preserve (variable names
and placeholders only; no token values).
