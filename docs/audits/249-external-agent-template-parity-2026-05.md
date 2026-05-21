# External-Agent Skills Template Parity Audit (2026-05)

- Parent issue: #249
- Audit issue: #449
- Source under audit: `docs/external-agent-skills.md`
- Companion under audit: `templates/agents/multi-agent-roster.md`
- Repo base SHA at audit time: `7e4856de76f0fc7bd27f4affa54fc5b5866080dd`
- Audit date: 2026-05-21

## Scope and method

This audit walks every named template, example, runtime path, and supporting
file cited in `docs/external-agent-skills.md` and records, for each cited path:

1. whether the file exists in the repo at the base SHA above,
2. whether its content covers the fields/role the doc claims it should, and
3. whether `templates/agents/multi-agent-roster.md` references the same file
   (so the doc and the roster stay in parity).

The required field list for **agent config files** (the template plus the six
runtime examples) is taken verbatim from the *Agent Config Fields* section of
`docs/external-agent-skills.md` (lines 67-85) plus the *Sidecar Paths and
Runtime Metadata* section (lines 90-132):

- `display name` → `ORDO_AGENT_DISPLAY_NAME`
- `short description` → `ORDO_AGENT_DESCRIPTION`
- `default prompt` → `ORDO_AGENT_DEFAULT_PROMPT_FILE`
- `allowed control plane` → `ORDO_AGENT_ALLOWED_CONTROL_PLANE`
- `forbidden actions` → `ORDO_AGENT_FORBIDDEN_ACTIONS`
- `audit root` → `ORDO_AGENT_AUDIT_ROOT`
- `GitHub identity` → `ORDO_AGENT_GITHUB_IDENTITY`
- `validation mode` → `ORDO_AGENT_VALIDATION_MODE`
- `external sidecar root` → `ORDO_AGENT_EXTERNAL_SIDECAR_ROOT`

For **docs / scripts / lib files** the third column ("Required fields /
claimed role covered") is interpreted as: *does the cited file actually
fulfill the role `docs/external-agent-skills.md` assigns to it?* — verified by
direct inspection of each file at the audit base SHA.

Paths cited in the doc that are NOT files in the repo (environment variables
like `GH_CONFIG_DIR`, `ORDO_AGENT_EXTERNAL_SIDECAR_ROOT`,
`ORCH_RUNTIME_FRESHNESS_SIDECAR_GLOBS`, runtime sidecar globs like
`.claude/scheduled_tasks.lock`, `.cursor/*`, `.aider/*`, `.vscode/*`,
`.idea/*`, and the explicitly out-of-scope private path
`~/.config/agent-cli/skills/`) are noted at the end but not treated as
parity rows because they are intentionally not tracked artifacts.

## Per-cited-path parity table

Legend for column 3 — `yes` (fully covers), `partial` (covers most but a
named claim is broken or stale), `no` (does not cover at all). Column 4
records whether `templates/agents/multi-agent-roster.md` references the same
file in its **Runtimes** or **Linkage** section.

| # | Cited path | Exists | Required fields / claimed role covered | Referenced from `multi-agent-roster.md` | Verdict |
| - | --- | --- | --- | --- | --- |
| 1 | `README.md` | yes | yes — confirms agent-neutral, provider-adapter doctrine the doc opens on (README.md lines 19, 23-24) | no (project README is not a roster artifact) | ok |
| 2 | `docs/dispatch-planning.md` | yes | yes — provides the pre-dispatch planner and "Validation Placement" section the doc points at (lines 3, 80, 788, 884) | no | ok |
| 3 | `docs/orchestrator-injected-rules.md` | yes | yes — titled and scoped exactly as the doc claims ("Orchestrator Injected Rules") | no | ok |
| 4 | `docs/fleet-injected-rules.md` | yes | yes — titled "Fleet Injected Rules" and describes the worker-agent dispatch-prompt injection the doc claims | no | ok |
| 5 | `docs/controlled-operations.md` | yes | yes — defines the evidence-gated exception workflow the doc points at; `scripts/controlled_operation.sh plan/verify` flow is present | yes (Roster Rules + Linkage cite `docs/controlled-operations.md`) | ok |
| 6 | `SECRETS.md` | yes | yes — defines `GH_CONFIG_DIR`-keyed token store, the operator-controlled credential rule, and `GH_TOKEN_AGENT_<label>` policy referenced by the doc | yes (Review Checklist cites `SECRETS.md`) | ok |
| 7 | `scripts/dispatch_ticket.sh` | yes | yes — the script the doc tells local agents NOT to invoke; it exists, which is necessary for the prohibition to be meaningful | no | ok |
| 8 | `templates/agents/local-skill-default.md` | yes | yes — covers identity, allowed control plane, forbidden actions, default working loop, evidence/findings, validation mode, stop conditions; matches the "default skill template every local agent should ship with" claim | yes (Linkage section explicitly lists it) | ok |
| 9 | `templates/agents/direct-dispatch-exception.md` | yes | yes — provides the required authorization fields, matrix-row schema, brief-body requirements, and cleanup steps the doc says live there | yes (Linkage section explicitly lists it) | ok |
| 10 | `templates/agents/agent-config.sh.tpl` | yes | yes — declares all 9 required ORDO_AGENT_* fields (display name, description, label/GitHub identity, default prompt file, allowed control plane, forbidden actions, audit root, external sidecar root + paths, validation mode); ships `ordo_agent_config_self_check` for early-fail validation | yes (Roster Header + Inventory + Linkage explicitly derive agent profiles from this template) | ok |
| 11 | `scripts/dispatch_plan.sh` | yes | partial — script exists, but the doc claims it accepts a `--require-local-validators` opt-in mirroring the `validation mode` field. Greps for `require`, `validator`, `local.test`, `ci.delegated` in the file return nothing related to a validator opt-in. Only `scripts/brief_agents.sh` actually declares and parses `--require-local-validators` (its usage line, the `[require_local_validators]="no"` default, and the `--require-local-validators)` case branch). This is a documentation overclaim, not a missing file. **Gap #1.** | no | gap |
| 12 | `scripts/brief_agents.sh` | yes | yes — usage line documents `[--require-local-validators]`, default key `[require_local_validators]="no"`, parser handles the flag and sets `K[require_local_validators]="yes"`/`"no"` | no | ok |
| 13 | `lib/runtime_freshness.sh` | yes | yes — defines `DEFAULT_SIDECAR_GLOBS` (includes `.claude/*`, `.claude/scheduled_tasks.lock`, `.cursor/*`, `.aider/*`, `.vscode/*`, `.idea/*` as the doc claims), classifies worktrees as `sidecar-dirty`, and emits `externalize-agent-sidecar-paths` remediation, all exactly as the doc describes | no | ok |
| 14 | `examples/agents/claude.agent.example.sh` | yes | yes — all 9 required fields present; ships concrete sidecar mapping (`CLAUDE_CONFIG_DIR` doctrine via `ORDO_AGENT_EXTERNAL_SIDECAR_ROOT` plus `claude.scheduled_tasks_lock` / `claude.sessions_dir` entries) and the `ANTHROPIC_API_KEY` env placeholder | yes (Runtimes + Linkage) | ok |
| 15 | `examples/agents/codex.agent.example.sh` | yes | yes — all 9 required fields present; sidecar mapping commented as documentary; OPENAI_API_KEY env placeholder | yes (Runtimes + Linkage) | ok |
| 16 | `examples/agents/cursor.agent.example.sh` | yes | yes — all 9 required fields present; sidecar mapping commented as documentary; CURSOR_API_KEY env placeholder | yes (Runtimes + Linkage) | ok |
| 17 | `examples/agents/copilot.agent.example.sh` | yes | yes — all 9 required fields present; sidecar mapping commented as documentary; GH_TOKEN_AGENT_<label> env placeholder | yes (Runtimes + Linkage) | ok |
| 18 | `examples/agents/gemini.agent.example.sh` | yes | yes — all 9 required fields present; sidecar mapping commented as documentary; GOOGLE_API_KEY env placeholder | yes (Runtimes + Linkage) | ok |
| 19 | `examples/agents/generic-cli.agent.example.sh` | yes | yes — all 9 required fields present; sidecar mapping commented as documentary; generic GH_TOKEN_AGENT_<label> env placeholder | yes (Runtimes + Linkage) | ok |
| 20 | `examples/ordo.config.sh` | yes | yes — exists in `examples/` as the project profile companion the doc tells operators to load agent profiles alongside | no | ok |
| 21 | `examples/orch-tokens.env.example` | yes | yes — declares `GH_TOKEN_AGENT_<label>` placeholders (`GH_TOKEN_AGENT_planner`, `GH_TOKEN_AGENT_builder`) exactly as the doc claims | no | ok |

## Roster-side parity note

`templates/agents/multi-agent-roster.md` lists exactly the same six
runtime examples cited by `docs/external-agent-skills.md` (lines 47-52 and
86-91 of the roster). The roster additionally references
`examples/agents/visual-check.agent.example.sh` (present in the repo) and
flags it explicitly as opt-in / role-specific, NOT part of the runtime
parity set — so the omission from `docs/external-agent-skills.md` is
intentional and consistent. No drift between the two files' runtime example
lists.

The roster also references `templates/agents/operator-policy.md` (present
in the repo). `docs/external-agent-skills.md` does not cite that template,
which is consistent with operator-policy being a per-agent annotation
rather than a doctrine artifact; not a gap.

## Out-of-table cited identifiers (informational)

The doc also cites non-file identifiers that intentionally do not appear in
the parity table:

- Environment variables / config knobs: `GH_CONFIG_DIR`,
  `ORDO_AGENT_EXTERNAL_SIDECAR_ROOT`, `ORDO_AGENT_EXTERNAL_SIDECAR_PATHS`,
  `ORCH_RUNTIME_FRESHNESS_SIDECAR_GLOBS`, `CLAUDE_CONFIG_DIR`,
  `CURSOR_HOME`, `GH_TOKEN_AGENT_<label>`. Each is referenced by name from a
  cited file (template, example, lib, or `SECRETS.md`).
- Runtime sidecar globs: `.claude/scheduled_tasks.lock`, `.claude/sessions/`,
  `.cursor/agent.log`, plus the broader `.claude/*`, `.cursor/*`,
  `.aider/*`, `.vscode/*`, `.idea/*` classes — all present in
  `DEFAULT_SIDECAR_GLOBS` (`lib/runtime_freshness.sh` lines 86-101).
- Explicitly out-of-scope private path: `~/.config/agent-cli/skills/`
  (the doc itself marks it out of scope).

## Gaps and follow-ups

### Gap #1 — `scripts/dispatch_plan.sh` does not accept `--require-local-validators`

- **Where claimed:** `docs/external-agent-skills.md` lines 83-84
  (Agent Config Fields table, `validation mode` row):
  > Mirrors the `--require-local-validators` opt-in used by
  > `scripts/dispatch_plan.sh` and `scripts/brief_agents.sh`.
- **Reality at audit base SHA:**
  - `scripts/brief_agents.sh` declares the flag in its usage line (line 6),
    defaults `[require_local_validators]="no"` (line 298), accepts
    `--require-local-validators` in the option parser (line 375), and
    propagates `K[require_local_validators]="yes"`/`"no"` (lines 670, 676).
  - `scripts/dispatch_plan.sh` has zero references to `validator`,
    `require_local`, `--require-local-validators`, `local-test`,
    `ci-delegated`, or `validation_mode` (1706 lines scanned).
- **Closes-the-gap note:** none currently — this is a real doc-vs-code drift.
- **Recommended follow-up issue:** open a child issue under #249 titled
  *"docs/external-agent-skills.md overclaims --require-local-validators
  scope: only brief_agents.sh accepts it"*. Suggested fix-side options
  (audit only — do NOT apply here per acceptance criteria):
  1. drop `scripts/dispatch_plan.sh` from the doc sentence and leave only
     `scripts/brief_agents.sh`; or
  2. wire the same `--require-local-validators` opt-in into
     `scripts/dispatch_plan.sh` so its CLI matches the doc claim.
  Option 1 is the minimum-blast-radius doc fix; option 2 is a code change
  that should go through a separate dispatch.

No other gaps surfaced by this audit.

## Acceptance Criteria checklist

- [x] Every path cited in `docs/external-agent-skills.md` appears in the
      parity table with file path, exists yes/no, required fields covered
      yes/no/partial (with which fields/claim missing for `partial`/`no`),
      and referenced-from-`multi-agent-roster.md` yes/no.
- [x] Each gap row links a follow-up note (Gap #1 above) — no separate
      follow-up issue has been filed by this PR per the audit-only mandate;
      the recommended title and remediation options are recorded inline.
- [x] Final verdict line below is unambiguous.
- [x] No production code or template content changed in this PR. The audit
      is the only artifact added.

Verdict: gaps-found-1
