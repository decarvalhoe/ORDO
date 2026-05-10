# EPIC #236 Acceptance Closure Audit

Issue: #440
Parent: #236
Base audited: `origin/main` at `700328c908b5d661bae3f8d6455a160e94edd7e9`
Date: 2026-05-10

## Acceptance Evidence

| # | Acceptance bullet | Delivering PR(s) on `main` | Supporting files | Residual gap |
| --- | --- | --- | --- | --- |
| 1 | Standard ORDO cycles execute or dry-run Six Sigma Auto Upgrade as continuous improvement evidence. | #406 (`fix(#245): run Six Sigma auto-upgrade in standard ORDO cycles`), #420 (`fix(#237): ORDO Six Sigma architecture`) | `scripts/cycle.sh:71-89`; `scripts/orch_loop.sh:369-389`; `docs/sixsigma-autoupgrade.md:205-231`; `docs/sixsigma/README.md:131-169`; `tests/test_sixsigma_autoupgrade.sh:107-241`; `tests/test_dry_run.sh:313-371` | none for runtime wiring. Test hardening for a dedicated every-cycle drift guard remains tracked under #437 and is counted under bullet 5. |
| 2 | Project configs can opt into a DMAIC dossier module. | Partial: #420 (`fix(#237): ORDO Six Sigma architecture`), #277 (`feat(261): add reusable downstream documentation generator module`) | `docs/sixsigma/README.md:38-60`; `docs/sixsigma/README.md:171-224`; `README.md:295-315`; `docs/docs-generate.md:27-39`; `docs/docs-generate.md:77-91`; `templates/docs/sixsigma/dmaic.md.tpl:1-60`; `tests/test_docs_generate.sh:194-219` | gap linked to #240 (config helper), #243 (project module scaffold/gate command), #438 (default-off invariant), and #239 (controlled DMAIC templates). Current `main` documents the opt-in architecture and has an unrelated docs-generator `--sixsigma` layer, but the #236 project-profile DMAIC module helper/CLI is not implemented. |
| 3 | Programming runs can receive Six Sigma by design brief controls. | Partial: #415 (`fix(#248): wire Six Sigma module verification and release evidence`), #420 (`fix(#237): ORDO Six Sigma architecture`) | `docs/sixsigma/README.md:177-190`; `docs/sixsigma/README.md:200-224`; `docs/sixsigma/README.md:226-246` | gap linked to #246 (brief injection) and #247 (programming-run wrapper). Current `main` lists placeholders and tracking issues, but no shipped brief-control renderer or wrapper exists yet. |
| 4 | Evidence ledgers capture auditable metric rows and gate blockers. | Partial: #277 (`feat(261): add reusable downstream documentation generator module`), #420 (`fix(#237): ORDO Six Sigma architecture`), #524 (`docs: audit Six Sigma evidence injection paths (#439)`) | `templates/docs/sixsigma/metric-evidence-ledger.md.tpl:11-30`; `scripts/docs_generate.sh:291-325`; `lib/docs_generate.sh:132-160`; `docs/sixsigma/README.md:48-60`; `docs/audits/236-prompt-injection-evidence-2026-05.md:35-40` | gap linked to #241 (JSONL evidence ledger helper), #242 (DMAIC gate helper), and #244 (collect mode). Current `main` has a generated documentation ledger template and the #439 audit records planned write sites, but the schema-backed metric append helper and DMAIC gate blocker implementation are absent. |
| 5 | Tests cover dry-run, apply, disabled, blocked, and prompt-injection paths. | Partial: #406 (`fix(#245): run Six Sigma auto-upgrade in standard ORDO cycles`), #420 (`fix(#237): ORDO Six Sigma architecture`), #277 (`feat(261): add reusable downstream documentation generator module`), #524 (`docs: audit Six Sigma evidence injection paths (#439)`) | `tests/test_sixsigma_autoupgrade.sh:88-105`; `tests/test_sixsigma_autoupgrade.sh:178-241`; `tests/test_dry_run.sh:313-371`; `tests/test_sixsigma_project_module.sh:56-120`; `scripts/run_shell_tests.sh:48-128`; `tests/test_docs_generate.sh:50-95`; `tests/test_docs_generate.sh:131-219`; `docs/audits/236-prompt-injection-evidence-2026-05.md:24-55` | gap linked to #437 (dedicated standard-cycle drift guard), #438 (DMAIC default-off invariant), #241/#242/#243/#244/#246/#247 (tests for the not-yet-implemented Level 2 apply, disabled, blocked, ledger, brief, and wrapper paths). Current tests cover Level 1 dry-run and approval-boundary text; docs-generator tests cover its optional `--sixsigma` apply path, but not the #236 project-DMAIC module paths because those helpers are still open. |

## Open Follow-ups Counted As Gaps

- #239 — DMAIC base templates.
- #240 — Six Sigma project opt-in configuration helper.
- #241 — Six Sigma evidence ledger helper.
- #242 — DMAIC gate helper.
- #243 — Six Sigma project module scaffold/gate CLI.
- #244 — auditable Six Sigma metric collection.
- #246 — Six Sigma by-design brief injection.
- #247 — Six Sigma programming-run wrapper.
- #437 — dedicated standard-cycle autoupgrade drift guard.
- #438 — project-DMAIC default-off invariant test.
- #523 — restore or replace the missing durable implementation-plan reference cited by #239-#247.

No new GitHub issue mutation was needed for this audit: every residual gap above is already linked to an open follow-up.

## Judgment Calls

- Bullet 1 is marked closed for runtime behavior because #406 wires both explicit and daemon cycle paths and the current files show dry-run propagation plus OK/WARN audit evidence. The open #437 test hardening is counted under bullet 5 rather than as a runtime gap.
- #277 is counted only as partial evidence for bullets 2, 4, and 5. It ships a reusable docs-generator `--sixsigma` layer, but it belongs to epic #257 and is not the #236 project-profile DMAIC module.
- The #439 prompt-injection audit is counted as partial evidence for bullets 4 and 5 because it audits the current and planned write sites and links residual risks, but it does not by itself implement the missing Level 2 helpers.

## Verdict

`gaps-4`
