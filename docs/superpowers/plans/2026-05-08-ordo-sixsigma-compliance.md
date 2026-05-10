# ORDO Six Sigma Compliance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the #236 Six Sigma compliance and DMAIC work package tracked by #239-#247 without letting generated content assert approval, release, waiver, validation, or phase-completion claims.

**Architecture:** Keep Level 1 Six Sigma auto-upgrade evidence separate from the Level 2 project DMAIC module. Implement Level 2 as controlled Markdown templates, a profile opt-in resolver, schema-backed evidence and gate helpers, an explicit project-module CLI, controlled dispatch-brief text, and a programming-run wrapper that renders expectations only.

**Tech Stack:** POSIX shell, Bash, `jq`, ORDO project profiles, ORDO documentation generator templates, Markdown, JSONL evidence rows, and focused shell tests under `tests/`.

---

## Compliance Boundary

- Parent issue: #236.
- Work package issues: #239, #240, #241, #242, #243, #244, #246, and #247.
- Generated Six Sigma artifacts are operational evidence. They do not approve work, release changes, waive controls, validate a system, or mark DMAIC phases complete.
- Human decisions must remain outside generated text. Machine-written artifacts may record `draft`, `ready`, `blocked`, `observed`, or `not_approved` states only.
- All new generated dossier pages must include this exact boundary sentence near the top:

```text
This generated artifact is not an approval, release decision, waiver, validation record, or DMAIC phase-completion claim.
```

## Task 1: Controlled DMAIC Templates (#239)

**Files:**
- Modify: `templates/docs/sixsigma/dmaic.md.tpl`
- Modify: `templates/docs/sixsigma/ctq.md.tpl`
- Modify: `templates/docs/sixsigma/metric-evidence-ledger.md.tpl`
- Modify: `templates/docs/sixsigma/control-plan.md.tpl`
- Modify: `templates/docs/sixsigma/improvement-backlog.md.tpl`
- Test: `tests/test_docs_generate.sh`

- [ ] **Step 1: Add the boundary sentence to each Six Sigma template**

  Add the compliance boundary sentence from this plan immediately after each template heading.

- [ ] **Step 2: Normalize approval-like table columns**

  In `templates/docs/sixsigma/metric-evidence-ledger.md.tpl`, avoid an unqualified `approved_by` column. Use `human_reviewer` plus `decision_state`, and seed generated rows with `not_approved` or `draft`.

- [ ] **Step 3: Keep DMAIC phase language non-final**

  In `templates/docs/sixsigma/dmaic.md.tpl`, describe phase status as `ready`, `blocked`, or `observed`. Do not emit `complete`, `approved`, `validated`, `released`, or `waived` as generated verdicts.

- [ ] **Step 4: Add docs-generator assertions**

  Extend `tests/test_docs_generate.sh` to render the Six Sigma layer and assert that every generated Six Sigma page contains the boundary sentence.

- [ ] **Step 5: Run focused validation**

  Run:

  ```bash
  timeout 30 bash tests/test_docs_generate.sh
  ```

  Expected: PASS.

- [ ] **Step 6: Commit**

  ```bash
  git add templates/docs/sixsigma tests/test_docs_generate.sh
  git commit -m "fix(239): constrain generated DMAIC templates"
  ```

## Task 2: Project Opt-In Configuration Helper (#240)

**Files:**
- Create: `lib/sixsigma_config.sh`
- Modify: `scripts/docs_generate.sh`
- Modify: `docs/docs-generate.md`
- Test: `tests/test_docs_generate.sh`

- [ ] **Step 1: Add a single profile resolver**

  Create `lib/sixsigma_config.sh` with shell functions that resolve the project-profile opt-in to a boolean `PROJECT_SIXSIGMA_LAYER` decision. Treat absent configuration as disabled.

- [ ] **Step 2: Wire docs generation to the resolver**

  In `scripts/docs_generate.sh`, source `lib/sixsigma_config.sh` and initialize the Six Sigma layer from the project profile before applying explicit CLI overrides. Preserve the existing `--sixsigma` flag as an operator override.

- [ ] **Step 3: Record decision provenance**

  Extend the generated manifest so `layers.sixsigma_sources` distinguishes profile-derived enablement from `cli:--sixsigma`.

- [ ] **Step 4: Document the contract**

  In `docs/docs-generate.md`, state that the profile key enables the Six Sigma documentation layer and that `--sixsigma` remains a manual override.

- [ ] **Step 5: Add default-off and enabled-profile tests**

  Extend `tests/test_docs_generate.sh` with one disabled-profile case and one enabled-profile case. Assert file-plan outputs and manifest provenance.

- [ ] **Step 6: Run focused validation**

  ```bash
  timeout 30 bash tests/test_docs_generate.sh
  ```

  Expected: PASS.

- [ ] **Step 7: Commit**

  ```bash
  git add lib/sixsigma_config.sh scripts/docs_generate.sh docs/docs-generate.md tests/test_docs_generate.sh
  git commit -m "feat(240): add Six Sigma docs profile opt-in"
  ```

## Task 3: Schema-Backed Evidence Ledger Helper (#241)

**Files:**
- Create: `lib/sixsigma_evidence.sh`
- Create: `tests/test_sixsigma_evidence.sh`
- Modify: `scripts/run_shell_tests.sh`

- [ ] **Step 1: Define the JSONL row schema**

  Implement `sixsigma_evidence_append` in `lib/sixsigma_evidence.sh`. Each row must contain `timestamp_utc`, `project`, `metric`, `source`, `action`, `actor_role`, `digest`, `limits`, and `disposition`.

- [ ] **Step 2: Enforce safe dispositions**

  Accept only `draft`, `observed`, `ready`, `blocked`, and `not_approved`. Reject `approved`, `released`, `waived`, `validated`, and `complete`.

- [ ] **Step 3: Hash raw evidence input**

  Store a digest of raw input rather than copying uncontrolled agent prose into approval-facing fields.

- [ ] **Step 4: Add shell tests**

  In `tests/test_sixsigma_evidence.sh`, assert valid rows append, invalid dispositions fail, and generated JSON parses with `jq`.

- [ ] **Step 5: Register the test**

  Add `tests/test_sixsigma_evidence.sh` to `scripts/run_shell_tests.sh`.

- [ ] **Step 6: Run focused validation**

  ```bash
  timeout 30 bash tests/test_sixsigma_evidence.sh
  ```

  Expected: PASS.

- [ ] **Step 7: Commit**

  ```bash
  git add lib/sixsigma_evidence.sh tests/test_sixsigma_evidence.sh scripts/run_shell_tests.sh
  git commit -m "feat(241): add Six Sigma evidence ledger helper"
  ```

## Task 4: DMAIC Gate Helper (#242)

**Files:**
- Create: `lib/sixsigma_dmaic.sh`
- Create: `tests/test_sixsigma_dmaic.sh`
- Modify: `scripts/run_shell_tests.sh`

- [ ] **Step 1: Define allowed phase names**

  Implement `sixsigma_dmaic_normalize_phase` for `define`, `measure`, `analyze`, `improve`, and `control`.

- [ ] **Step 2: Return readiness without completion claims**

  Implement `sixsigma_dmaic_gate_status` so it returns `ready` only when required dossier and evidence files exist, and `blocked` with missing paths otherwise.

- [ ] **Step 3: Reject completion vocabulary**

  Make helper output never include `complete`, `approved`, `validated`, `released`, or `waived`.

- [ ] **Step 4: Add shell tests**

  In `tests/test_sixsigma_dmaic.sh`, cover valid phases, invalid phases, missing evidence blockers, and ready status when all required files exist.

- [ ] **Step 5: Register the test**

  Add `tests/test_sixsigma_dmaic.sh` to `scripts/run_shell_tests.sh`.

- [ ] **Step 6: Run focused validation**

  ```bash
  timeout 30 bash tests/test_sixsigma_dmaic.sh
  ```

  Expected: PASS.

- [ ] **Step 7: Commit**

  ```bash
  git add lib/sixsigma_dmaic.sh tests/test_sixsigma_dmaic.sh scripts/run_shell_tests.sh
  git commit -m "feat(242): add DMAIC gate helper"
  ```

## Task 5: Project Module Scaffold and Gate CLI (#243)

**Files:**
- Create: `scripts/sixsigma_project_module.sh`
- Modify: `docs/sixsigma/README.md`
- Modify: `tests/test_sixsigma_project_module.sh`

- [ ] **Step 1: Add explicit modes**

  Implement `scripts/sixsigma_project_module.sh` with `preview`, `apply`, and `gate` modes. Refuse to run when the project is not Six Sigma enabled by `lib/sixsigma_config.sh`.

- [ ] **Step 2: Keep writes inside the dossier**

  In `apply` mode, write only under the target dossier directory and include the boundary sentence in generated pages.

- [ ] **Step 3: Delegate gate checks**

  In `gate` mode, call `lib/sixsigma_dmaic.sh` and print `ready` or `blocked` only.

- [ ] **Step 4: Document the CLI**

  Update `docs/sixsigma/README.md` with commands for preview, apply, and gate. State that generated pages are draft operational evidence.

- [ ] **Step 5: Extend existing tests**

  In `tests/test_sixsigma_project_module.sh`, cover disabled refusal, preview output, apply path containment, and gate status.

- [ ] **Step 6: Run focused validation**

  ```bash
  timeout 30 bash tests/test_sixsigma_project_module.sh
  ```

  Expected: PASS.

- [ ] **Step 7: Commit**

  ```bash
  git add scripts/sixsigma_project_module.sh docs/sixsigma/README.md tests/test_sixsigma_project_module.sh
  git commit -m "feat(243): add Six Sigma project module CLI"
  ```

## Task 6: Auditable Metric Collection (#244)

**Files:**
- Modify: `scripts/sixsigma_project_module.sh`
- Modify: `lib/sixsigma_evidence.sh`
- Modify: `tests/test_sixsigma_project_module.sh`
- Modify: `tests/test_sixsigma_evidence.sh`

- [ ] **Step 1: Add collect mode**

  Add a `collect` mode to `scripts/sixsigma_project_module.sh` that accepts metric name, source path, action, limits, and disposition.

- [ ] **Step 2: Append via the evidence helper**

  Route every collect-mode row through `sixsigma_evidence_append` so disposition validation and digest handling are centralized.

- [ ] **Step 3: Keep raw evidence out of claims**

  Store source path and digest in JSONL; do not copy raw uncontrolled text into generated approval-facing prose.

- [ ] **Step 4: Add tests**

  Extend the project-module and evidence tests to assert collect mode appends parseable JSONL and rejects approval-like dispositions.

- [ ] **Step 5: Run focused validation**

  ```bash
  timeout 30 bash tests/test_sixsigma_project_module.sh
  timeout 30 bash tests/test_sixsigma_evidence.sh
  ```

  Expected: PASS for both commands.

- [ ] **Step 6: Commit**

  ```bash
  git add scripts/sixsigma_project_module.sh lib/sixsigma_evidence.sh tests/test_sixsigma_project_module.sh tests/test_sixsigma_evidence.sh
  git commit -m "feat(244): add Six Sigma metric collection"
  ```

## Task 7: Six Sigma Brief Controls (#246)

**Files:**
- Modify: `scripts/brief_agents.sh`
- Modify: `templates/dispatch-canonical.md.tpl`
- Create: `tests/test_sixsigma_brief_controls.sh`
- Modify: `scripts/run_shell_tests.sh`

- [ ] **Step 1: Render controlled literals**

  Add a Six Sigma dispatch block generated from controlled fields, not raw agent output. Include parent issue, phase expectation, evidence paths, and the boundary sentence.

- [ ] **Step 2: Keep the block optional**

  Render the Six Sigma block only when the project profile or dispatch metadata says the project is Six Sigma enabled.

- [ ] **Step 3: Reject approval vocabulary in generated blocks**

  Add a guard that refuses to render a Six Sigma dispatch block containing `approved`, `released`, `waived`, `validated`, or `complete` as generated verdict text.

- [ ] **Step 4: Add tests**

  Create `tests/test_sixsigma_brief_controls.sh` with enabled, disabled, and forbidden-vocabulary cases.

- [ ] **Step 5: Register and run the test**

  ```bash
  timeout 30 bash tests/test_sixsigma_brief_controls.sh
  ```

  Expected: PASS.

- [ ] **Step 6: Commit**

  ```bash
  git add scripts/brief_agents.sh templates/dispatch-canonical.md.tpl tests/test_sixsigma_brief_controls.sh scripts/run_shell_tests.sh
  git commit -m "feat(246): add Six Sigma dispatch brief controls"
  ```

## Task 8: Programming-Run Wrapper (#247)

**Files:**
- Create: `scripts/sixsigma_programming_run.sh`
- Create: `tests/test_sixsigma_programming_run.sh`
- Modify: `scripts/run_shell_tests.sh`
- Modify: `docs/sixsigma/README.md`

- [ ] **Step 1: Add wrapper preflight**

  Implement `scripts/sixsigma_programming_run.sh` so it refuses disabled projects, missing issue IDs, missing dossier path, and unsupported DMAIC phases.

- [ ] **Step 2: Render expectations only**

  The wrapper may render expected phase, required evidence paths, and validation commands. It must not render phase-completion or approval claims.

- [ ] **Step 3: Integrate gate and evidence helpers**

  Call `lib/sixsigma_dmaic.sh` for phase readiness and `lib/sixsigma_evidence.sh` for any machine-written evidence row.

- [ ] **Step 4: Document wrapper usage**

  In `docs/sixsigma/README.md`, document wrapper inputs and output boundaries.

- [ ] **Step 5: Add tests**

  Create `tests/test_sixsigma_programming_run.sh` for disabled refusal, bad phase refusal, expectation rendering, and forbidden-vocabulary rejection.

- [ ] **Step 6: Register and run the test**

  ```bash
  timeout 30 bash tests/test_sixsigma_programming_run.sh
  ```

  Expected: PASS.

- [ ] **Step 7: Commit**

  ```bash
  git add scripts/sixsigma_programming_run.sh tests/test_sixsigma_programming_run.sh scripts/run_shell_tests.sh docs/sixsigma/README.md
  git commit -m "feat(247): add Six Sigma programming run wrapper"
  ```

## Final Verification

- [ ] Run the complete focused shell suite:

  ```bash
  timeout 120 bash scripts/run_shell_tests.sh
  ```

  Expected: PASS.

- [ ] Run the docs generator Six Sigma preview once and confirm the emitted manifest records Six Sigma layer provenance.

- [ ] Confirm no generated artifact contains approval, release, waiver, validation, or phase-completion claims authored by automation.

- [ ] Confirm the #236 acceptance audit can cite this plan as the durable implementation reference for #239-#247.
