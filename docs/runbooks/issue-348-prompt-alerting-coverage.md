# Issue #348 Prompt-Alerting Acceptance Coverage

- Parent epic: [#348](https://github.com/RBOKproject/ORDO/issues/348)
- Audit child: [#431](https://github.com/RBOKproject/ORDO/issues/431)
- Audit date: 2026-05-10
- Audited base: `origin/main` at `4bd16d6d8b6b68cd46f952fe42f50ab591b38b16`
- Closure-plan comment: [#348 atomization comment](https://github.com/RBOKproject/ORDO/issues/348#issuecomment-4410619021)
- Method: reviewed the #348 body, the atomization comment, child issue and PR metadata, and current repository evidence on `origin/main`.

## Acceptance Evidence

| # | Acceptance criterion from #348 | Delivering PR or child | Evidence on `origin/main` | Residual gap |
| --- | --- | --- | --- | --- |
| 1 | Prompt gates are detected across live panes with session, pane, cwd, command, prompt type, matched text, age, and linked issue/PR when available. | #349 / PR [#352](https://github.com/RBOKproject/ORDO/pull/352); executable follow-up PR [#405](https://github.com/RBOKproject/ORDO/pull/405) | `lib/prompt_detector.sh:130` documents the meta fields; `lib/prompt_detector.sh:231` emits the `ordo.prompt_detector.v1` JSON record with pane/session/cwd/command/type/text/age/link fields; `scripts/prompt_detector_scan.sh:128` passes live metadata into the detector; `tests/test_prompt_detector.sh:64` asserts the Figma fixture populates schema, command, session, pane, agent, project, and cwd. | none |
| 2 | Detection supports Figma MCP, Chrome/DevTools connector, browser connector, auto-mode permission denials, and generic allow/deny confirmation prompts through a configurable matcher registry. | #349 / PR [#352](https://github.com/RBOKproject/ORDO/pull/352) | `lib/prompt_detector.sh:40` ships the six default matchers; `lib/prompt_detector.sh:51` appends `ORCH_PROMPT_MATCHERS_FILE`; `tests/test_prompt_detector.sh:93` covers Chrome DevTools; `tests/test_prompt_detector.sh:105` covers generic browser connectors; `tests/test_prompt_detector.sh:114` covers auto-mode denials; `tests/test_prompt_detector.sh:123` covers generic confirmations; `tests/test_prompt_detector.sh:147` covers custom matchers. | none |
| 3 | ORDO records the signal in the audit ledger and dispatch/capacity state as `needs_operator_permission` or `blocked_external`. | #349 / PR [#352](https://github.com/RBOKproject/ORDO/pull/352); #350 / PR [#356](https://github.com/RBOKproject/ORDO/pull/356) | `lib/prompt_detector.sh:64` defines the prompt-signals ledger path; `lib/prompt_detector.sh:278` appends JSONL detector records; `lib/prompt_unblock_policy.sh:83` defines `lane_states.jsonl`; `lib/prompt_unblock_policy.sh:222` maps policy actions to `needs_operator_permission`, `blocked_external`, or `auto_unblocked`; `lib/prompt_unblock_policy.sh:350` emits `ordo.prompt_unblock_lane_state.v1` records. | none |
| 4 | The orchestrator removes blocked panes from healthy busy/available claims and surfaces a concise operator-action list. | #350 / PR [#356](https://github.com/RBOKproject/ORDO/pull/356); test hardening child [#429](https://github.com/RBOKproject/ORDO/issues/429) remains open | `lib/prompt_unblock_policy.sh:13` states audit-only prompts emit `needs_operator_permission` so capacity rollups stop counting the pane as healthy; `docs/orchestrator-injected-rules.md:1143` requires capacity/dispatch consumers to treat lane-state panes as non-healthy; `lib/prompt_unblock_policy.sh:409` formats the operator-action TSV; `lib/prompt_unblock_policy.sh:455` persists lane states and the action queue; `tests/test_prompt_unblock_policy.sh:221` asserts prompt-blocked panes do not leak into healthy/ready/busy lanes; `tests/test_prompt_unblock_policy.sh:239` asserts non-empty operator-action rows. | Capacity-matrix integration coverage remains open under #429. Runtime lane-state and operator-action evidence is present, but the dedicated `agent_pool_status` / capacity report regression requested by #429 has not landed. |
| 5 | If a profile policy explicitly allows an unblock response, ORDO can perform that response safely; otherwise it only alerts/escalates. | #350 / PR [#356](https://github.com/RBOKproject/ORDO/pull/356) | `lib/prompt_unblock_policy.sh:111` documents the policy format and precedence; `lib/prompt_unblock_policy.sh:123` defines `audit-only`, `escalate`, and `live-grant`; `lib/prompt_unblock_policy.sh:222` downgrades `live-grant` unless live grant is enabled; `scripts/orch_loop.sh:323` makes the consumer opt-in and requires a second live-grant opt-in; `tests/test_prompt_unblock_policy.sh:128` covers default audit-only, live-grant with and without opt-in, catch-all escalation, and explicit escalation. | none |
| 6 | Signals are deduplicated and rate-limited so one stuck pane does not spam the orchestrator. | #349 / PR [#352](https://github.com/RBOKproject/ORDO/pull/352); #350 / PR [#356](https://github.com/RBOKproject/ORDO/pull/356); stale-age follow-up #430 / PR [#442](https://github.com/RBOKproject/ORDO/pull/442) | `lib/prompt_detector.sh:175` deduplicates `(matcher_id, matched-line)` inside one scan; `lib/prompt_unblock_policy.sh:240` suppresses repeat alerts inside cooldown; `lib/prompt_unblock_policy.sh:425` deduplicates consumed signals by `(pane, matcher_id)` and persists alert state; `lib/prompt_unblock_policy.sh:324` applies stale-prompt escalation without bypassing cooldown; `tests/test_prompt_detector.sh:162` covers duplicate detector lines; `tests/test_prompt_unblock_policy.sh:179` covers rate limiting; `tests/test_prompt_unblock_policy.sh:209` covers batch dedupe; `tests/test_prompt_unblock_policy.sh:340` covers stale escalation cooldown suppression. | none |
| 7 | Tests cover Figma and Chrome connector prompt fixtures, stale prompt age, dedupe, and capacity matrix impact. | #349 / PR [#352](https://github.com/RBOKproject/ORDO/pull/352); #350 / PR [#356](https://github.com/RBOKproject/ORDO/pull/356); #430 / PR [#442](https://github.com/RBOKproject/ORDO/pull/442); open child [#429](https://github.com/RBOKproject/ORDO/issues/429) | `tests/test_prompt_detector.sh:64` covers Figma MCP; `tests/test_prompt_detector.sh:93` covers Chrome DevTools; `tests/test_prompt_detector.sh:162` covers detector dedupe; `tests/test_prompt_unblock_policy.sh:179` and `tests/test_prompt_unblock_policy.sh:209` cover consumer rate-limit and dedupe; `tests/test_prompt_unblock_policy.sh:300` covers stale prompt age; `tests/test_prompt_unblock_policy.sh:221` covers non-healthy lane states as the current pre-integration proxy. | Capacity-matrix impact remains uncovered until #429 lands. Current `origin/main` has no dedicated `tests/test_prompt_blocker_capacity_matrix.sh` or equivalent `agent_pool_status` / `capacity_report` regression for prompt-blocked panes, and `scripts/run_shell_tests.sh:65` registers no prompt-blocker capacity test. |
| 8 | Documentation/runbooks explain how to configure prompt matchers and unblock policy for multi-agent, multi-project fleets. | #428 / PR [#545](https://github.com/RBOKproject/ORDO/pull/545) | `docs/runbooks/connector-permission-prompts.md:1` introduces the operator runbook; `docs/runbooks/connector-permission-prompts.md:26` documents the matcher 6-tuple; `docs/runbooks/connector-permission-prompts.md:67` lists the default matchers; `docs/runbooks/connector-permission-prompts.md:100` documents unblock-policy format and modes; `docs/runbooks/connector-permission-prompts.md:136` documents multi-project portfolio behavior; `docs/runbooks/connector-permission-prompts.md:167` documents internal vs external handoff; `docs/runbooks/README.md:10` links the runbook. | none |

## Residual Gaps

- [#429](https://github.com/RBOKproject/ORDO/issues/429) remains open for the "capacity matrix impact" portion of AC #7. The current tests prove consumed prompt blockers become non-healthy lane states and produce operator actions, but they do not yet drive `scripts/agent_pool_status.sh` or `lib/capacity_report.sh` against a prompt-blocked pane and assert removal from healthy busy/available claims.

No new child issue is required by this audit because #429 already tracks the remaining acceptance gap.

## Close-Out Comment For #348

Structured comment posted on #348:
[issuecomment-4414486675](https://github.com/RBOKproject/ORDO/issues/348#issuecomment-4414486675)

Posted body:

```markdown
## #348 acceptance closure audit

Coverage runbook: `docs/runbooks/issue-348-prompt-alerting-coverage.md`

Merged closures reviewed:
- #349 / PR #352 and executable follow-up PR #405: detector and scanner.
- #350 / PR #356: prompt-unblock consumer, lane states, policy, and operator-action queue.
- #386 / PR #388: tmux escaped batch separator fix supporting reliable pane cwd evidence.
- PR #413: durable 2026-05-08 outage findings handoff that links #348/#349/#350 to the dispatch-consumption evidence gap.
- #428 / PR #545: connector permission prompts runbook.
- #430 / PR #442: stale-prompt-age force escalation and cooldown-preserving audit line.

AC mapping:
- AC1: shipped via #349 / PR #352; evidence `lib/prompt_detector.sh:130`, `lib/prompt_detector.sh:231`, `scripts/prompt_detector_scan.sh:128`, `tests/test_prompt_detector.sh:64`.
- AC2: shipped via #349 / PR #352; evidence `lib/prompt_detector.sh:40`, `lib/prompt_detector.sh:51`, `tests/test_prompt_detector.sh:93`, `tests/test_prompt_detector.sh:105`, `tests/test_prompt_detector.sh:114`, `tests/test_prompt_detector.sh:123`, `tests/test_prompt_detector.sh:147`.
- AC3: shipped via #349 / PR #352 and #350 / PR #356; evidence `lib/prompt_detector.sh:64`, `lib/prompt_detector.sh:278`, `lib/prompt_unblock_policy.sh:83`, `lib/prompt_unblock_policy.sh:222`, `lib/prompt_unblock_policy.sh:350`.
- AC4: runtime behavior shipped via #350 / PR #356; capacity-matrix test hardening remains #429. Evidence `docs/orchestrator-injected-rules.md:1143`, `lib/prompt_unblock_policy.sh:409`, `lib/prompt_unblock_policy.sh:455`, `tests/test_prompt_unblock_policy.sh:221`, `tests/test_prompt_unblock_policy.sh:239`.
- AC5: shipped via #350 / PR #356; evidence `lib/prompt_unblock_policy.sh:111`, `lib/prompt_unblock_policy.sh:123`, `lib/prompt_unblock_policy.sh:222`, `scripts/orch_loop.sh:323`, `tests/test_prompt_unblock_policy.sh:128`.
- AC6: shipped via #349 / PR #352, #350 / PR #356, and #430 / PR #442; evidence `lib/prompt_detector.sh:175`, `lib/prompt_unblock_policy.sh:240`, `lib/prompt_unblock_policy.sh:425`, `lib/prompt_unblock_policy.sh:324`, `tests/test_prompt_detector.sh:162`, `tests/test_prompt_unblock_policy.sh:179`, `tests/test_prompt_unblock_policy.sh:209`, `tests/test_prompt_unblock_policy.sh:340`.
- AC7: partially shipped via #349 / PR #352, #350 / PR #356, and #430 / PR #442; remaining capacity-matrix impact gap is #429.
- AC8: shipped via #428 / PR #545; evidence `docs/runbooks/connector-permission-prompts.md:1`, `docs/runbooks/connector-permission-prompts.md:26`, `docs/runbooks/connector-permission-prompts.md:100`, `docs/runbooks/connector-permission-prompts.md:136`, `docs/runbooks/connector-permission-prompts.md:167`, `docs/runbooks/README.md:10`.

Recommended close action: keep #348 open until #429 and #431 are merged. After #429 lands and this coverage runbook is on `develop`/`main` per the release flow, #348 can close with the runbook as the closure evidence.
```

## Judgment Calls

- Counted AC #4 runtime behavior as shipped because the current consumer emits non-healthy lane states and an operator-action queue, and the injected rules require capacity consumers to treat those lanes as non-healthy. Counted the missing end-to-end capacity-matrix regression under AC #7 and #429.
- Counted #386 / PR #388 and PR #413 as supporting closure context rather than direct AC implementers. #386 repairs the live pane cwd evidence layer used by prompt-blocker classification; PR #413 preserves the outage findings that linked #348 to dispatch-consumption proof.
- Did not create a new follow-up because the only uncovered item found during this audit is already represented by open child #429.

Verdict: `gaps-1`
