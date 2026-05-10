# Connector Permission Prompts Runbook

This runbook tells an ORDO operator how to detect connector permission prompts,
extend prompt matchers without changing engine code, and route unblock decisions
across a multi-project fleet. It covers the detector in
`lib/prompt_detector.sh` and the unblock-policy consumer in
`lib/prompt_unblock_policy.sh`.

The detector is read-only. It scans captured pane text and emits
`ordo.prompt_detector.v1` JSON records. It never sends keys, grants
permissions, or resumes a pane.

## Preflight

1. Confirm the target project or portfolio profile is the intended one.
2. Confirm `ORCH_STATE_BASE` points at the operator-owned state directory for
   the active project or portfolio.
3. If custom matchers are required, set `ORCH_PROMPT_MATCHERS_FILE` to an
   operator-owned matcher file outside product worktrees.
4. If unblock policy is required, set `ORCH_PROMPT_UNBLOCK_POLICY_FILE` to the
   active project's policy file, or rely on the default policy path under
   `$ORCH_STATE_BASE/_prompt_signals/policy.tsv`.
5. Start in audit mode. Do not enable live grants until the provider, command,
   project, pane, and owning operator are verified.

## Matcher Catalog

`prompt_detector_matchers` returns the built-in defaults followed by
non-blank, non-comment lines from `ORCH_PROMPT_MATCHERS_FILE`. Every matcher is
a pipe-separated 6-tuple:

```text
id|tool|provider|prompt_type|priority|regex
```

| Field | Meaning |
| --- | --- |
| `id` | Stable matcher identifier. Use lowercase words separated by hyphens. |
| `tool` | Tool family, such as `mcp`, `browser-connector`, `auto-mode`, or `generic`. |
| `provider` | Concrete provider when known, such as `claude.ai-figma` or `chrome-devtools`; leave empty for a catch-all. |
| `prompt_type` | Router class emitted as JSON field `prompt_class`, such as `allow-deny-confirmation`, `browser-connector-confirmation`, `auto-mode-denial`, or `generic-confirmation`. |
| `priority` | Integer priority. Higher priority wins when several matchers match the same captured line. |
| `regex` | Extended regular expression matched against one canonical prompt line. |

Custom lines append to the default catalog. They do not delete or silently
override default matchers. If two matchers match the same line, the highest
priority wins.

Example custom matcher file:

```text
# id|tool|provider|prompt_type|priority|regex
custom-vault-grant|secrets-manager|hashicorp-vault|allow-deny-confirmation|120|grant access to vault path
jetbrains-browser-connect|browser-connector|jetbrains-gateway|browser-connector-confirmation|100|Allow connection from JetBrains Gateway
```

Use the shipped template when creating a new operator-owned matcher file:

```bash
export ORCH_PROMPT_MATCHERS_FILE=/operator/profiles/prompt-matchers.txt
cp examples/prompt-matchers.example.txt "$ORCH_PROMPT_MATCHERS_FILE"
```

Then edit only the copied operator profile. The repository example remains a
parseable template.

## Built-In Default Matchers

The default detector catalog ships these six matchers:

| id | tool | provider | prompt_type | priority | Matches |
| --- | --- | --- | --- | --- | --- |
| `figma-mcp-confirm` | `mcp` | `claude.ai-figma` | `allow-deny-confirmation` | `110` | `Do you want to proceed?` on a line that also mentions `claude.ai Figma`. |
| `mcp-allow-deny-confirm` | `mcp` | empty | `allow-deny-confirmation` | `90` | Generic MCP `Do you want to proceed?` prompt with `1. Yes` and `2. Yes-don't-ask-again` choices. |
| `chrome-devtools-connect` | `browser-connector` | `chrome-devtools` | `browser-connector-confirmation` | `105` | Chrome DevTools connection prompts, including `chrome-devtools` and `chrome devtools` spelling. |
| `browser-connector-confirm` | `browser-connector` | empty | `browser-connector-confirmation` | `95` | Generic browser connector prompts for browser, Chromium, Firefox, or WebKit. |
| `auto-mode-denial` | `auto-mode` | empty | `auto-mode-denial` | `100` | Auto-mode denied, disabled, or requires-confirmation lines. |
| `generic-confirmation` | `generic` | empty | `generic-confirmation` | `10` | Bare `[y/n]`, `Allow ... Deny ...`, or `Confirm (y/n)` prompts. |

## Adding A Matcher

1. Capture a single prompt line from the stuck pane.
2. Choose the narrowest useful `tool` and `provider`.
3. Pick a `prompt_type` already understood by the consumer unless a new
   consumer route has been designed.
4. Set priority above a generic fallback only when the custom matcher should win
   over that fallback.
5. Add one 6-tuple line to the operator-owned matcher file.
6. Verify with:

```bash
ORCH_PROMPT_MATCHERS_FILE=/operator/profiles/prompt-matchers.txt \
  bash scripts/prompt_detector_scan.sh --capture /tmp/pane-capture.txt --json
```

Do not modify `lib/prompt_detector.sh` for project-specific prompts. The engine
is intentionally project-neutral.

## Unblock Policy Modes

Policy files are pipe-separated 4-tuples:

```text
tool|provider|action|cooldown_sec
```

Lookup precedence is:

1. exact `tool` plus `provider`;
2. same `tool` with an empty provider;
3. `ORCH_PROMPT_UNBLOCK_DEFAULT_ACTION`, which defaults to `audit-only`.

| Policy mode | Lane state | Behavior |
| --- | --- | --- |
| `audit-only` | `needs_operator_permission` | Record the prompt and operator action. Never answer it. This is the default and the required starting mode. |
| `escalate` | `blocked_external` | Treat the pane as blocked on an external operator or owning team. Use when the local operator cannot safely grant. |
| `live-grant` with live grant disabled | `needs_operator_permission` | The policy is advisory only. The prompt remains operator-gated. |
| `live-grant` with live grant enabled (`live_grant_enabled`) | `auto_unblocked` | The consumer may delegate to `auto_unblock` after both the policy line and runtime `--live-grant` opt-in are present. |

Runtime live grant is a second opt-in. A stale `live-grant` policy line does not
grant by itself. In the loop, operators enable the consumer with
`ORCH_PROMPT_UNBLOCK_ENABLED=1`; live grants additionally require
`ORCH_PROMPT_UNBLOCK_LIVE_GRANT=1`, which invokes the consumer with
`--live-grant`.

Example policy:

```text
# Exact provider rule: manual review lane.
mcp|claude.ai-figma|audit-only|300

# Provider catch-all: any browser connector becomes an external blocker.
browser-connector||escalate|600
```

## Multi-Project Portfolio Behavior

Prompt detection is fleet-wide, but configuration authority is project-scoped.
In a portfolio:

- Each project profile owns its matcher file and unblock policy path.
- The active project alias on the signal is the routing key for status,
  capacity, and operator-action queues.
- Matchers resolve defaults plus the active project's
  `ORCH_PROMPT_MATCHERS_FILE`. Do not infer a matcher from another project just
  because the same physical pane or agent label was reused.
- Policies resolve exact provider, then tool catch-all, then default action
  inside the active project's policy file.
- Portfolio status should fold lane states by project alias. A pane in
  `needs_operator_permission`, `blocked_external`, or pending `auto_unblocked`
  state is not free capacity for that project.

Expected portfolio-level emissions:

| Artifact | Expected content |
| --- | --- |
| `signals.jsonl` | One detector record per matched prompt line, including `project`, `pane`, `agent`, `tool`, `provider`, `matcher_id`, and `matched_text`. |
| `lane_states.jsonl` | One current lane state per consumed signal after policy lookup and cooldown handling. |
| `operator_actions.tsv` | Operator queue rows with pane, agent, workdir, requested tool, and safest next action. |
| `audit.log` | Narrative stale-prompt escalation lines when prompt age crosses the configured threshold. |

Store these artifacts under the operator state directory, not in product
worktrees. They are operational evidence and should survive product cleanup.

## Internal Vs External Handoff

An internal operator can grant directly only when all of these are true:

- the profile marks the operator as responsible for the project;
- the provider and command are recognized;
- the requested grant is limited to the active project and pane;
- the policy file allows the action, and live grant is enabled only for a
  reviewed, low-risk provider;
- evidence is captured in `signals.jsonl`, `lane_states.jsonl`, and
  `operator_actions.tsv`.

Escalate to the external owning team when any of these is true:

- the project profile belongs to an external team or tenant;
- the prompt requests access outside the active project workdir or repository;
- the provider identity, browser origin, MCP command, or requested permission is
  ambiguous;
- the policy resolves to `escalate` or no local operator is authorized to grant;
- the same prompt is stale or repeated after a prior local review.

External handoff should include the project alias, pane, workdir, provider,
command, matcher id, matched text, lane state, and the policy action that was
applied. Do not grant first and notify later.

## Verification

For a changed matcher template or policy profile, run a targeted foreground
check with strict timeouts:

```bash
timeout 30 bash -n tests/test_prompt_detector.sh
timeout 60 bash tests/test_prompt_detector.sh
timeout 60 bash tests/test_prompt_unblock_policy.sh
```

If a validator hangs or produces no output for the dispatch timeout, stop the
process and report `validator-hang` with the command and elapsed time. Do not
start a second copy of the same validator.

## Audit Capture

Record these items in the operator evidence bundle:

| Evidence | Why |
| --- | --- |
| Active project or portfolio profile path | Proves which policy authority was used. |
| `ORCH_PROMPT_MATCHERS_FILE` path and checksum | Proves which custom matchers were active. |
| `ORCH_PROMPT_UNBLOCK_POLICY_FILE` path and checksum | Proves which unblock policy was active. |
| Detector signal excerpt | Shows the matched prompt and winning matcher. |
| Lane state excerpt | Shows policy action, lane, and alert eligibility. |
| Operator action row | Shows the safe next action surfaced to the operator. |

Keep copied excerpts short and redact secrets. The prompt detector should never
need secret material to decide whether a permission prompt is present.
