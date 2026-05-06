# Fleet Injected Rules

ORDO injects these rules into worker-agent dispatch prompts through
`templates/dispatch-canonical.md.tpl`. They are intentionally model-neutral and
apply to any agent pool.

## Required Rules

1. Repo context check: before mutation, verify `pwd`, `git status --short
   --branch`, `git remote -v`, and the expected base branch. Stop on
   `context-mismatch`.
2. Multi-product isolation: mutate only the workdir named in the dispatch
   prompt. Never edit another product repo from the same pane.
3. Scope discipline: modify only allowed files. Stop and ask for clarification
   when the ticket requires out-of-scope files.
4. Evidence reporting: final status must include base SHA, modified files,
   validation command, validation result, judgment calls, blockers, and
   opportunity findings.
5. Opportunity findings: operational blockers or improvement signals observed
   by an agent must be reported as `opportunity_findings`, with impact and a
   safe remediation suggestion when possible.
6. Dangerous mutations remain forbidden: no push, PR, merge, admin bypass,
   force rebase, destructive reset, destructive stash, hardcoded secret, or
   broad deletion unless explicitly authorized.

## Orchestrator Follow-Up

The orchestrator consumes `opportunity_findings` from final agent reports and
either fixes them immediately or records a durable ORDO opportunity item using
the fields defined in `docs/orchestrator-injected-rules.md`.
