# Direct Dispatch Exception Template

This template covers the **exception** path where an operator dispatches work
straight to a target agent's terminal instead of using the standard
issue-pack handoff. It is not the default flow.

Doctrine: `docs/external-agent-skills.md`. Related operator-side workflow:
`docs/controlled-operations.md`.

Direct dispatch is allowed only when **all** of the following are true:

- explicit operator authorization for a named target agent and named scope,
  recorded in a controlled operation evidence file (see
  `docs/controlled-operations.md`);
- a current dispatch matrix exists for the involved repo or portfolio, or one
  is created compliant with ORDO dispatch directives before dispatch;
- the target agent's matrix row is `ready`;
- the matrix row carries one active issue, a clean worktree, no conflicting
  hot spots, an explicit branch, explicit PR expectations, and no open
  blockers;
- the target agent does not already own a different active assignment.

Refuse direct dispatch when any row state is `blocked`, `dirty`,
`conflicting`, `owned-elsewhere`, or `unknown`.

## Required Authorization Fields

Fill every field. Missing values must abort dispatch.

```yaml
authorization:
  authorized_by: "{{operator_label}}"
  authorization_id: "{{controlled_operation_id}}"
  authorization_evidence: "{{evidence_file_path}}"
  reason: "{{short_reason_string}}"
  expires_at: "{{iso8601_timestamp}}"
target:
  agent_label: "{{agent_label}}"
  tmux_target: "{{session}}:{{window}}.{{pane}}"
  workdir: "{{absolute_path}}"
  github_identity: "{{provider_account}}"
scope:
  repo: "{{owner/repo}}"
  issue: "{{issue_number}}"
  branch: "{{feature_branch_slug}}"
  base_branch: "{{default_branch}}"
  base_sha: "{{base_sha}}"
  owned_paths:
    - "{{glob_or_path}}"
  forbidden_paths:
    - "{{glob_or_path}}"
validation:
  mode: "ci-delegated"  # or "require-local-validators" with operator note
  smoke_commands:
    - "{{cheap_foreground_check_with_timeout}}"
gate:
  matrix_source: "{{matrix_file_or_query}}"
  matrix_row_state: "ready"
  conflicting_hot_spots: "none"
  pre_dispatch_checks:
    - "pwd matches target.workdir"
    - "git status --short --branch matches scope.branch"
    - "git remote -v includes scope.repo"
    - "git config user.name == target.github_identity"
```

## Dispatch Matrix Row Schema

Direct dispatch requires a matrix row with at minimum these columns (see
sibling issue #253 for the full matrix gate definition):

| Column | Required value |
| --- | --- |
| `repo` | configured project repo |
| `issue` | open issue number, no other agent owns it |
| `priority` | label-derived priority |
| `validation_mode` | matches the brief above |
| `target_agent` | matches `target.agent_label` |
| `tmux_target` | matches `target.tmux_target` |
| `base_branch` | matches `scope.base_branch` |
| `owned_paths` | matches `scope.owned_paths` |
| `forbidden_paths` | matches `scope.forbidden_paths` |
| `readiness` | `ready` |
| `blockers` | `none` |
| `notes` | optional |

If the matrix row does not exist or any column is empty or conflicting,
**stop and create or update the matrix first**. Do not paste a brief into a
terminal until the row exists and is `ready`.

## Brief Body

The dispatch brief sent to the target terminal must:

- include a copy of the authorization block above;
- name the canonical dispatch prompt file under `/tmp/`;
- carry the same forbidden-actions list as the local skill template;
- explicitly acknowledge the exception status (`This is an authorized direct
  dispatch under controlled-operation {{controlled_operation_id}}; the
  default flow is issue-pack handoff.`);
- carry the validation strategy line and the strict timeout for any local
  smoke commands.

## Cleanup

After the direct-dispatch issue is delivered:

1. Move the matrix row state to `delivered` with the merged PR or final
   commit SHA.
2. Append a closing audit line referencing the controlled operation ID and
   the matrix row.
3. Verify the controlled-operation evidence file using
   `scripts/controlled_operation.sh ... verify` before recording the
   operation.
4. Remove any temporary credentials, branches, or workflows the operation
   required, per `docs/controlled-operations.md`.

Direct dispatch never substitutes for the gated merge path. The PR still has
to clear the configured CI and review gates through `lib/pr_merge.sh`.
