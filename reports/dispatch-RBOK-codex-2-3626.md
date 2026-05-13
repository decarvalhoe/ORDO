# Dispatch hotfix #3626 agent: RBOK-codex-2

- Agent label: `RBOK-codex-2`
- Cwd: `cd /root/repos/RBOK-codex-2`
- Repo: `RBOKproject/RBOK`
- PR target: `develop`
- Issue: #3626
- external-pr-mutations: pr_state,pr_comment,issue_comment

## Objectif

Remediate the current red `develop` caused by `DEV Critical Route Smoke` run 25711219496 on sha `b57e411`.

Create a small hotfix branch from `origin/develop`, fix the client UAT pixel-lock contract after the #3621 i18n merge, push, and open a draft PR to `develop`.

Observed failures:

- `frontend/tests/e2e/client-uat-pixel-lock.spec.ts` static test still searches hardcoded source strings `Notifications` and `References Nomos` in `ModuleContextPanelDefault`.
- The source now correctly uses `t("coaching.panel.notifications")` and `t("coaching.panel.references")` under `useTranslations("modulePage")`.
- The mobile/tablet composer test still looks up `Message au coach`; the UI now exposes the accessible label `Message a l'accompagnateur` with the French accent in source.

## Tools / sources autorises

- Use `git`, `gh`, `npm`, `npx playwright` if available, and normal shell inspection tools.
- Use the existing RBOK frontend patterns only.
- You may create/push one branch and open/update one PR for #3626.
- Use `env -u GITHUB_TOKEN gh ...` if the default token interferes.

## Boundaries / interdictions

- Do not touch unrelated issues #3595, #3598, #3603.
- Do not weaken the pixel-lock contract by deleting the failing tests or broad-skipping the spec.
- Do not merge the PR.
- Do not push to `develop` directly.
- Keep changes scoped to the smoke regression unless a tiny adjacent test fixture update is strictly required.

## Definition of Done verifiable

- `frontend/tests/e2e/client-uat-pixel-lock.spec.ts` remains strict:
  - still asserts `data-testid="module-context-panel-default"`;
  - still asserts DEFAULT does not render `context-panel-menu-`;
  - now asserts the i18n source keys for notifications/references and verifies the French message values in `frontend/messages/fr.json`;
  - composer lookup uses the post-i18n accessible label `Message à l'accompagnateur` (or an exact regex that only accepts the new label).
- Local validation:
  - `timeout 30 git diff --check`;
  - `cd frontend && npm run lint`;
  - run the targeted pixel-lock/static check if feasible, otherwise document why not.
- Push branch and open a draft PR to `develop` closing #3626.

## Preuves attendues

Final response must include:

- branch name, commit SHA, PR URL;
- exact files changed;
- validation commands and pass/fail status;
- whether any validation could not be run and why;
- confirmation that no merge was performed.

## Format de sortie attendu

Post a concise handoff in the agent pane and on the PR comment with:

- issue/branch/commit/PR;
- validation table;
- residual risks or blockers;
- explicit "ready for orchestrator merge" or "blocked".
