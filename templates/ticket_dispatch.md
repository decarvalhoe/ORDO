# Dispatch — {{project}} agent: {{agent}}
# Ticket: #{{ticket}} {{summary}}

## Repo & branch

- Repo: `{{repo}}`
- Origin remote: `{{orch_remote}}`
- Target branch: `{{branch_slug}}`
- Branch from: `{{default_branch}}` (sha `{{base_sha}}` — `git fetch` first and verify)

## Workflow

1. `cd {{repo}}`
2. `git fetch orchestrator`
3. Confirm `orchestrator/{{default_branch}}` is at `{{base_sha}}`. If older, STOP and report.
4. `git checkout -B {{branch_slug}} orchestrator/{{default_branch}}`
5. **Verify your git identity** matches your agent name before commit (`git config user.name && git config user.email`). Set if missing.
6. Read the full ticket: `gh issue view {{ticket}} --repo {{gh_repo}}`
7. Implement strictly per spec. Stay in scope.
8. Run validation: `{{validation}}` (must PASS before commit).
9. Commit locally only. Conventional commit:
   `feat({{ticket}}): <one-line summary>`
10. Report final status when done or blocked.

## Scope

Files you may modify:
{{scope_files}}

Files you must NOT touch:
{{forbidden_files}}

## Forbidden

- No `--no-verify`, no `--admin` bypass.
- No push, no PR — orchestrator handles those.
- No changes outside the scope listed above.
- Zero claim language (`validated|certified|Part 11|GxP|compliant|regulated-grade`) outside an explicit non-claim section.

## Report format

```
{{ticket}} status:
  branch: {{branch_slug}}
  head: <sha>
  base: orchestrator/{{default_branch}} @ {{base_sha}} (verified)
  files:
    <list of files modified/created with line counts>
  validation: <command run> — PASS|FAIL|SKIPPED
  judgment calls: <list>
  blockers: none | <list>
```
