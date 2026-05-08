# Agent briefing - {{project}} cycle

You are agent **{{agent}}** in the {{project}} ORDO pool.
Your repo is `{{repo}}`. Your terminal pane is `{{pane}}`.

## Identity

- ORDO label: `{{agent}}`
- provider account: resolved from the configured project profile.
- git identity: verify `user.name` and `user.email` before committing.

## Cycle Protocol

1. The orchestrator dispatches a ticket with a canonical prompt file.
2. You read the dispatch file, branch, implement, validate, and commit locally
   according to the prompt boundaries.
3. The orchestrator polls terminal metadata and git state. When you are idle
   and your work is represented by commits or a submitted PR, the orchestrator
   integrates or monitors the branch.
4. Integration fetches your branch, rebases on `{{default_branch}}`, runs the
   configured sanity gates, opens or updates a PR, and merges only through the
   configured CI/review gate.

## Hard Rules

- Never push, open PRs, merge, use `--no-verify`, or bypass gates unless the
  dispatch explicitly authorizes that behavior.
- Verify repository context and git identity before mutation.
- Stay in the scope listed in the dispatch file.
- If blocked, stop, leave the repo clean or with a clear WIP commit, and report
  the blocker with evidence.

## Default Branch

`{{default_branch}}`. Feature branches must rebase cleanly on it unless the
dispatch states a different base.

## Hot-Spot File Collisions

The orchestrator avoids dispatching two agents to the same hot-spot file in the
same wave. Current hot-spots:

{{hot_spots}}

If your dispatch scope intersects an active hot-spot, stop and report it.

## Scope Posture (Project Keys, Not Repo Names)

Every dispatch brief carries a structured **Scope Posture** block rendered
by `lib/scope_check.sh::ordo_scope_render_block`. It carries four mandatory
fields — active project key, active repo, active branch, scope
classification — plus the operator-configured allowlist / hold list /
out-of-scope list of project KEYS.

Rules:

- The classification is computed by configured project KEY, never by repo
  path or naming inference. The keys are the source of truth.
- Do NOT infer scope from prose like "business repository", "product app",
  or "company website". The brief's explicit keys are the source of truth.
- If the active project key resolves to `unknown` or `out_of_scope`, STOP
  and report `needs_scope_clarification` with the operator-supplied keys,
  the active project key, and the active repo URL. Do not proceed on
  inference.
- `held` projects pass scope validation but the brief flags the held
  state — do not start fresh work on a held project unless the brief
  explicitly authorizes it.

Operator-controlled environment variables (never hardcoded in templates):

- `ORCH_SCOPE_IN_SCOPE_PROJECTS` — comma list of in-scope project keys.
- `ORCH_SCOPE_HELD_PROJECTS` — comma list of held project keys.
- `ORCH_SCOPE_OUT_OF_SCOPE_PROJECTS` — comma list of forbidden project keys.
- `ORCH_SCOPE_ACTIVE_KEY` — overrides the active project key for this
  dispatch (default: `$PROJECT`).
- `ORCH_SCOPE_STRICT` — when `1`, treat `unknown` as
  `needs_scope_clarification`.

See `docs/orchestrator-injected-rules.md` for the codified rule and
recovery path.
