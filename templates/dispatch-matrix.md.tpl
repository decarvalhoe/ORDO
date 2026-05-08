# Direct Dispatch Matrix — {{project}} {{ticket}}

## Authorization

- Operator: {{operator}}
- Authorized at: {{authorized_at}}
- Reason: {{reason}}
- Named target: agent={{target_agent}}, tmux={{tmux_target}}
- Named scope: owned_paths={{owned_paths}}; forbidden_paths={{forbidden_paths}}
- PR expectations: branch=`{{branch_slug}}` -> base=`{{base_branch}}`, draft, body cites matrix row.

Direct dispatch is the **emergency exception** to the standard ORDO flow
`plan -> nuclear epic -> atomized issues -> notify remote orchestrator
-> stop`. This template documents one such exception and the matrix row
that gates it. File this alongside the dispatch brief so audit can
correlate the authorization with the audit-log entries
`DISPATCH_MATRIX gate result=*` and `DISPATCH MATRIX GATE *`.

## Matrix row (TSV)

```text
repo	issue	priority	validation_mode	target_agent	tmux_target	base_branch	owned_paths	forbidden_paths	readiness	blockers	notes
{{repo}}	{{ticket}}	{{priority}}	{{validation_mode}}	{{target_agent}}	{{tmux_target}}	{{base_branch}}	{{owned_paths}}	{{forbidden_paths}}	ready		{{notes}}
```

## Procedure

```bash
# 1. Read or refresh the matrix from ORDO read-only state + GitHub.
bash scripts/dispatch_matrix.sh {{project_config}} build

# 2. Add or update the named row for this emergency.
bash scripts/dispatch_matrix.sh {{project_config}} add {{ticket}} \
  target_agent={{target_agent}} \
  tmux_target={{tmux_target}} \
  base_branch={{base_branch}} \
  owned_paths='{{owned_paths}}' \
  forbidden_paths='{{forbidden_paths}}' \
  validation_mode={{validation_mode}} \
  readiness=ready \
  notes='{{notes}}'

# 3. Gate before any tmux send. Non-zero exit refuses dispatch.
bash scripts/dispatch_matrix.sh {{project_config}} gate {{ticket}}

# 4. Brief the agent, then dispatch with the gate flag so the matrix
#    is re-checked immediately before the tmux send.
bash scripts/brief_agents.sh {{project_config}} {{target_agent}} {{ticket}} \
  branch_slug={{branch_slug}} scope_files='{{owned_paths}}' \
  forbidden_files='{{forbidden_paths}}' summary='{{summary}}' \
  > /tmp/dispatch-{{target_agent}}-{{ticket}}.md
bash scripts/dispatch_ticket.sh --require-matrix-gate \
  {{project_config}} {{target_agent}} {{ticket}} \
  /tmp/dispatch-{{target_agent}}-{{ticket}}.md
```

## Refusal codes

If the gate refuses, capture the reason in this file under `Refusal log`
and remediate before retrying:

| Reason | Code | Remediation |
| --- | --- | --- |
| `blocked:*` | 80 | Resolve the cited blocker or unset `blockers`/`readiness`. |
| `dirty:<workdir>` | 81 | Commit, stash, or audit-and-clean the agent workdir. |
| `conflict:hot-spot-shared-with=<other>` | 82 | Reduce `owned_paths` overlap or pick a different agent. |
| `owned:agent=<a> busy with #<N>` | 83 | Wait for the other ticket to drain or recover the agent. |
| `missing:*` | 84 | Run `dispatch_matrix.sh build` and re-add the row. |
| `malformed:*` | 85 | Fill the missing required column (repo/issue/target_agent/base_branch). |

## Refusal log

- {{authorized_at}}: <fill in attempted gate result and remediation here>
