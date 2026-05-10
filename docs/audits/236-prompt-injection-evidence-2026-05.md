# Prompt-Injection Audit for Six Sigma Evidence Claims

Issue: #439
Parent: #236
Base audited: `origin/main` at `9def608e2afacf65d28de0507da9450ec164892c`
Date: 2026-05-10

## Scope

This audit covers current and planned ORDO Six Sigma evidence-write paths named
in #439:

- Level 1 Six Sigma Auto Upgrade audit evidence.
- Level 2 DMAIC evidence ledger helper (#241) and metric collector (#244).
- Level 2 DMAIC gate helper (#242).
- Level 2 project scaffold CLI (#243).
- Six Sigma by-design dispatch brief injection (#246).
- Six Sigma programming-run wrapper (#247).

The reviewed control is #236's non-negotiable rule: generated material must not
author approval, release, waiver, validation, or phase-completion claims on
behalf of a human.

## Evidence Write-Site Matrix

| ID | Evidence write site | Interpolated variables / inputs | Sanitiser or boundary observed | Verdict | Residual-risk note and follow-up |
| --- | --- | --- | --- | --- | --- |
| L1-1 | `lib/audit_log.sh:154-164` (`audit`) | Raw caller message `$*`, UTC timestamp, `$PROJECT` for log file path. | Log line is written with `printf '%s\n'` and mirrored to OTLP. No approval-claim sanitizer is applied at this central sink. | safe | Safe only as a generic sink when callers keep messages structured. For Six Sigma callers below, no generated agent prose is passed directly into `audit`; residual risk is owned at each caller. |
| L1-2 | `scripts/sixsigma_autoupgrade.sh:78-83` (pool snapshot failure) | `$PROJECT`. | NONE - trusted config only; no generated free-form output is interpolated. | safe | The message records failure status only and cannot by itself assert approval or release readiness. |
| L1-3 | `scripts/sixsigma_autoupgrade.sh:87-96` (PR blocker signal audit) | `$signal_line` from `scripts/pr_block_signals.sh --tsv`; fields include PR number, branch, head SHA, agent, merge state, review state, CI aggregate, failed check names, and blocker signals. | Tabs are converted to spaces by `awk`; `read -r` enforces one physical line per audit record. No semantic sanitizer for approval/release wording. | safe | Current source data is structured PR/check metadata, not generated agent prose. A branch or check name can contain suggestive text, but it remains inside metadata fields and does not change the audit event action. If future code admits PR body or agent output into the TSV row, #246/#247 should add claim filtering before this sink. |
| L1-4 | `scripts/sixsigma_autoupgrade.sh:99-107` plus `scripts/gh_actions_optimize.sh:65-69` (GHA optimizer audit) | `$gha_line`; inside optimizer: fixed `severity`, `code`, workflow `file`, fixed `message`. | Messages are static literals; workflow paths are local repo paths; no approval-claim sanitizer. | safe | The current emitted findings are process-smell diagnostics and do not carry generated approval text. If a future optimizer starts copying workflow step names, job names, or agent-authored YAML text into `message`, add filtering under #236 before appending. |
| L1-5 | `scripts/sixsigma_autoupgrade.sh:118-175` (PR observe/skip/rebase/autofix/end audit) | PR number, branch, draft flag, merge state, failed/pending check counts, agent label, workdir-derived owner, `$DEFAULT_BRANCH`, `$SIXSIGMA_MAX_AUTOFIX_DISPATCHES`, `$PROJECT`, dispatch count. | Counts/booleans come through `jq`; branch/merge state/agent/project are emitted as structured tokens. No approval-claim sanitizer. | safe | Current rows state operational observations and dispatch decisions only. They do not consume agent prose, validation reports, or human names. Residual risk is metadata wording only, not an evidence-claim substitution path. |
| L1-6 | `scripts/cycle.sh:79-88` (explicit cycle Six Sigma wrapper audit) | `$WAVE`, `$PROJECT`, subprocess exit status implied by branch. | NONE - trusted operator/cycle metadata only; fixed OK/WARN wording. | safe | OK/WARN refers only to whether `sixsigma_autoupgrade.sh` exited zero. It does not state that work, validation, or a phase is approved. |
| L1-7 | `scripts/orch_loop.sh:379-389` (daemon loop Six Sigma wrapper audit) | `$cycle`, `$PROJECT`, subprocess exit status implied by branch. | NONE - loop metadata only; fixed OK/WARN wording. | safe | OK/WARN refers only to the auto-upgrade subprocess result and does not imply approval, release, waiver, validation, or phase completion. |
| L2-1 | `templates/docs/sixsigma/metric-evidence-ledger.md.tpl:1-40`, rendered by `scripts/docs_generate.sh:292-302` via `lib/docs_generate.sh:132-160` | `${DG_PROJECT_NAME}`, `${DG_GENERATED_AT}`, `${DG_SIXSIGMA_ENABLED}`, `${DG_OPERATOR_CONTEXT}`. The ledger table also contains an `approved_by` column with a TODO row. | NONE - risk. `docs_generate_render_template` performs raw token substitution and writes the rendered file; operator context is inserted verbatim. | risk | A supplied operator-context file can land approval-like text inside a generated Six Sigma ledger page, and the template has an `approved_by` column without a local "not approved by generator" status line. Covered follow-ups: #239 for controlled DMAIC templates, #241/#244 for schema-backed evidence rows. |
| L2-2 | Planned `lib/sixsigma_evidence.sh` from #241; referenced in issue #241, not present on this base. | Expected future row fields: metric, source, action, UTC timestamp, actor role, digest, limits, disposition. | Unknown - file does not exist on `origin/main`; no implementation sanitizer can be audited. | unknown | Follow-up already filed: #241. #244 covers the collect mode that will append JSONL evidence under `.ordo/sixsigma/evidence`. |
| L2-3 | Planned `lib/sixsigma_dmaic.sh` from #242; referenced in issue #242, not present on this base. | Expected future phase names and required dossier/evidence file lists. | Unknown - file does not exist on `origin/main`; no implementation sanitizer can be audited. | unknown | Follow-up already filed: #242. The implementation should keep phase verdicts limited to ready/blocked and must not render phase-complete claims. |
| L2-4 | Planned `scripts/sixsigma_project_module.sh` / scaffold CLI from #243; placeholders documented at `docs/sixsigma/README.md:200-224`. | Expected future project config, dossier path, mode, phase/gate inputs, and generated dossier content. | Unknown - command does not exist on `origin/main`; only placeholders are documented. | unknown | Follow-up already filed: #243. Apply mode must write only inside the target dossier and must mark generated pages as draft/not approved. |
| L2-5 | Planned Six Sigma by-design brief injection from #246; current generic renderer is `scripts/brief_agents.sh:157-190` and template is `templates/dispatch-canonical.md.tpl:1-96`. | Current renderer substitutes `K[...]` values including summary, scope, validation, and template text. Future Six Sigma block content is not present on this base. | Current renderer avoids shell re-evaluation and rejects unresolved placeholders; it does not sanitize natural-language claims. | unknown | Follow-up already filed: #246. The Six Sigma block should be generated from controlled literals or schema fields, not raw agent output, and should explicitly state that evidence is not approval. |
| L2-6 | Planned `scripts/sixsigma_programming_run.sh` from #247; placeholders documented at `docs/sixsigma/README.md:200-224`. | Expected future project config, ticket, DMAIC phase expectations, and dispatch/brief fields. | Unknown - command does not exist on `origin/main`; no implementation sanitizer can be audited. | unknown | Follow-up already filed: #247. The wrapper must refuse disabled projects, render expectations only, and avoid phase-completion language. |

## Final Summary

Rows requiring follow-up:

- `risk`: L2-1. Linked follow-ups: #239, #241, #244.
- `unknown`: L2-2. Linked follow-ups: #241, #244.
- `unknown`: L2-3. Linked follow-up: #242.
- `unknown`: L2-4. Linked follow-up: #243.
- `unknown`: L2-5. Linked follow-up: #246.
- `unknown`: L2-6. Linked follow-up: #247.

No new GitHub issue mutation was required for this audit because the existing
#236 child issues already cover every risk or unknown implementation surface
identified above.

## Judgment Calls

- Level 1 Auto Upgrade audit lines are marked `safe` because current callers
  append structured operational metadata and fixed status words, not generated
  agent prose or human approval names.
- The docs generator's metric ledger template is marked `risk` because it is a
  present write path, it emits a generated Six Sigma ledger page, it has an
  `approved_by` column, and it substitutes operator context verbatim.
- Planned Level 2 helper rows are marked `unknown` rather than `risk` because
  the files are not present on `origin/main`; there is no implementation to
  inspect beyond open tracking issues and README placeholders.
