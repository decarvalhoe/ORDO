# Dispatch deploy-red hotfix agent: RBOK-claude-2

- Agent label: `RBOK-claude-2`
- Cwd: `cd /root/repos/RBOK-claude-2`
- Repo: `RBOKproject/RBOK`
- PR target: `develop`
- Ticket: `3598-deploy-red-d659d7e`
- Follow-up source: merged PR `#3627`, issue `#3598`
- external-pr-mutations: pr_state,pr_comment

## Scope Posture

- active project key: `rbok`
- active repo: `RBOKproject/RBOK`
- active branch: `develop`
- scope classification: `in_scope`
- in-scope project keys (allowlist): `rbok`
- held project keys (work paused, awaiting external gate): `<none>`
- out-of-scope project keys (forbidden for autonomous dispatch): `<none>`

The classification above is computed by configured project key, not by
repo path or naming inference. If the active project key resolves to
`unknown` or `out_of_scope`, STOP and report
`needs_scope_clarification` with the operator-supplied keys, the active
project key, and the active repo URL. Do not infer scope from prose or
paths.

## Objectif

Recover the red `develop` deploy gate at commit
`d659d7e5645ade19d9036f2ea3d36ead71c93ce0`, introduced by merged PR
`#3627` (`feat(3598): gate public bundle budgets`).

Create a scoped hotfix branch from current `origin/develop`, diagnose the
DEV frontend 502 / freshness failure, implement the smallest safe fix,
push the branch, and open a draft PR to `develop`. Do not merge it.

Observed provider evidence:

- `Deploy DEV` run `25712458384` failed on `d659d7e5`.
- Backend deploy passed.
- Frontend health check passed.
- Frontend freshness check failed because
  `https://dev.realisons.com/deploy-version.json` returned no `.sha` for
  60 attempts.
- Smoke tests then failed because the homepage returned HTTP 502 for all
  retry attempts.
- Follow-on `Deploy Health Gate` run `25713129980` set `Deploy gate` to
  failure for `develop`.

Likely inspection targets from PR `#3627`:

- `.github/workflows/ci.yml`
- `frontend/scripts/check-bundle-budget.js`
- `frontend/src/components/admin/GlobalAnalytics.tsx`
- `frontend/src/components/admin/GlobalAnalyticsCharts.tsx`
- `frontend/src/components/admin/RAGAdminDashboard.tsx`
- `frontend/src/components/admin/RAGQualitySimilarityChart.tsx`

## Format de sortie attendu

```text
deploy-red hotfix status:
  source: PR #3627 / issue #3598 / develop d659d7e5
  branch: <branch>
  commit: <sha>
  draft PR: <url>
  root cause: <one concise paragraph>
  changed files: <list>
  validation:
    - <command>: PASS|FAIL|SKIPPED (<reason if skipped>)
  blockers: none | <list>
  merge: not performed
  readiness: ready for orchestrator merge | blocked
```

## Tools / sources autorises

- `git`, `gh`, `curl`, `jq`, `npm`, and existing repo scripts.
- GitHub evidence:
  - `gh run view 25712458384 --repo RBOKproject/RBOK --log`
  - `gh run view 25713129980 --repo RBOKproject/RBOK --log`
  - `gh pr view 3627 --repo RBOKproject/RBOK`
- DEV verification endpoints:
  - `https://dev.realisons.com/api/health`
  - `https://dev.realisons.com/deploy-version.json`
  - `https://dev.realisons.com/`
- You may create and push one hotfix branch and open/update one draft PR.
- Use `env -u GITHUB_TOKEN gh ...` if token environment interferes.

## Boundaries / interdictions

- Do not push to `develop` directly.
- Do not merge any PR.
- Do not weaken deploy gates, freshness checks, smoke tests, or bundle
  budgets to make CI green.
- Do not make unrelated visual/design changes.
- Keep the scope tied to the deploy-red regression from PR `#3627`.
- Avoid touching active unrelated issues `#3595`, `#3603`, and `#3626`.

## Definition of Done verifiable

- A minimal fix is committed on a branch from current `origin/develop`.
- A draft PR to `develop` exists and references PR `#3627` / issue `#3598`
  as a follow-up, without re-closing already closed work.
- Local validation includes at least:
  - `timeout 30 git diff --check`
  - a focused frontend build, lint, or script validation matching the
    changed files
  - a non-mutating probe of the affected DEV endpoint(s), if useful after
    CI deploys the draft PR
- If a validation cannot be run locally, explain why and point to the CI
  check that will cover it.
- The draft PR should be left unmerged for orchestrator review.

## Preuves attendues

- Branch name, commit SHA, and draft PR URL.
- Exact changed files.
- Root cause tied to provider logs or local reproduction.
- Validation commands with pass/fail/skipped status.
- Explicit statement that no merge was performed.
