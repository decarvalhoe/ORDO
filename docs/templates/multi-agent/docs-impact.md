# Docs Impact / Freshness Checklist

> Template — copy into the documentation tree of `{{project_name}}` and
> include the rendered checklist in the PR body of every change that
> matches one of the triggers below.

This template enforces docs freshness for ORDO deployments. It binds the
mode-specific docs packs ([`single-project.md`](single-project.md),
[`portfolio.md`](portfolio.md), [`gxp-grade.md`](gxp-grade.md),
[`normal-dev.md`](normal-dev.md), [`sixsigma.md`](sixsigma.md),
[`external-agent-handoff.md`](external-agent-handoff.md)) to the events
that should trigger a docs refresh.

The checklist is intentionally short. The goal is that every PR-author
running through it can answer **yes / no / not-applicable** without any
ambiguity.

## When This Applies

Run this checklist on every PR that ships one of the following changes:

| Trigger | Affected mode template(s) |
| --- | --- |
| New ORDO feature or operator command | every mode that lists the loop |
| Change to the daily loop or smart-poll behavior | single-project, portfolio |
| Validation-grade change (normal-dev ↔ GxP-grade) | both impacted mode templates |
| GxP option toggled on or off | gxp-grade, normal-dev |
| Six Sigma option toggled on or off | sixsigma plus the underlying mode |
| Agent pool roster change (label, runtime, identity, audit root) | every mode in use for the product |
| Dispatch matrix gate or direct-dispatch exception change | external-agent-handoff and any mode using direct dispatch |
| Local skill template revision | external-agent-handoff |
| Credential rotation policy change | every mode (links to `SECRETS.md`) |
| Validation dossier section addition or disposition change | gxp-grade |
| DMAIC scope or watcher cadence change | sixsigma |
| Portfolio membership or priority change | portfolio |
| New runtime example added under `examples/agents/` | external-agent-handoff |

If a trigger is missing, add it with the same line shape rather than
bypassing the checklist.

## Checklist

Render the checklist and paste it into the PR body. Mark each item PASS,
N/A, or FAIL (with a one-line note explaining the FAIL).

```markdown
### Docs Impact (multi-agent multi-config)

- [ ] Trigger identified: <feature-change | validation-grade-change | gxp-option-change | sixsigma-option-change | other>
- [ ] Affected mode templates listed: <single-project | portfolio | gxp-grade | normal-dev | sixsigma | external-agent-handoff>
- [ ] Each affected template's "Docs Impact" section was reviewed and updated where required.
- [ ] Each affected template's "Installation" section was reviewed for new prerequisites.
- [ ] Each affected template's "Integration" section was reviewed for profile, identity, or roster updates.
- [ ] Each affected template's "Usage" section was reviewed for new commands or workflow steps.
- [ ] Each affected template's "Troubleshooting" section was reviewed for new symptoms.
- [ ] Each affected template's "Audit Evidence" section was reviewed for new artifacts.
- [ ] Each affected template's "Known Limitations" section was reviewed for new caveats.
- [ ] Each affected template's "Update Policy" section was reviewed for new toolkit, profile, or rotation steps.
- [ ] No GxP-only language leaked into normal-dev templates.
- [ ] No Six Sigma-only language leaked into normal-dev or gxp-grade templates unless the option is enabled.
- [ ] No secret values, private paths, or RBOK-only topology were embedded as defaults (`SECRETS.md`).
- [ ] If the change is a Six Sigma option toggle, the watcher cadence and autofix limit are explicit.
- [ ] If the change is a validation-grade flip, the dossier disposition or its absence is explicit.
- [ ] If the change is an agent roster update, every affected agent's `templates/agents/operator-policy.md` was reviewed.
```

## Exit Criteria

A PR is docs-fresh when:

- every checklist item is PASS or N/A;
- every FAIL has a follow-up issue or a same-PR fix;
- the mode-specific docs packs render without broken cross-links;
- no secret values, no live operator profiles, no RBOK-only defaults
  appear in the diff.

If the change is purely internal (does not match any trigger above), state
that explicitly in the PR body so reviewers can confirm the absence of a
docs impact rather than skipping the checklist silently.
