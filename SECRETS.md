# Secrets

This toolkit must never commit secret values. This document lists variable
names, ownership, storage locations, rotation steps, and leak response only.

## Audit Scope

The required audit scanned `examples/`, `lib/`, and `scripts/` for token,
secret, key, password, and PAT references. The secret-bearing references found
were:

| Variable or secret source | Referenced by | Purpose |
| --- | --- | --- |
| `PR_MERGE_ADMIN_TOKEN` | `examples/rbok.config.sh`, `examples/nomos.config.sh`, `lib/pr_merge.sh` | Privileged PR review and admin merge fallback |
| `GH_ADMIN_TOKEN` | `examples/orch-tokens.env.example` | Optional admin GitHub token template |
| `GH_TOKEN_RBOKCLI<agent>` | `examples/orch-tokens.env.example` | Optional per-agent GitHub token template |
| `GH_TOKEN` | `lib/pr_merge.sh` | Runtime carrier used to pass `PR_MERGE_ADMIN_TOKEN` to `gh` |
| GitHub CLI token store selected by `GH_CONFIG_DIR` | project configs, `lib/`, `scripts/` | Routine GitHub CLI authentication |

Other audit hits were non-secret strings such as tmux `send-keys`, audit log
key/value terminology, match patterns, or script argument names.

## Global Rules

1. Store secret values only in approved operator-controlled GitHub, shell, or
   credential-store locations.
2. Keep committed examples as variable names and placeholders only.
3. Never paste token values into issues, PRs, logs, terminal screenshots, or
   dispatch briefs.
4. Prefer short-lived or fine-grained credentials where GitHub supports them.
5. After any rotation, run the smallest command that proves the credential can
   perform its expected operation without exposing the value.

## `PR_MERGE_ADMIN_TOKEN`

- **Type:** Privileged GitHub token used as admin merge fallback.
- **Possessor:** Eric or the designated toolkit operator.
- **Current storage:** Project config defaults in versioned example configs and
  optional runtime shell override. `lib/pr_merge.sh` reads this variable only
  when branch protection is blocked on review and CI is already successful.
- **Used for:** `gh pr review --approve` and `gh pr merge --admin` through a
  transient `GH_TOKEN` environment variable.

### Rotation

1. Create a replacement GitHub credential with the minimum scopes required for
   the target repositories and branch-protection bypass policy.
2. Update the operator-controlled runtime source used before invoking toolkit
   commands.
3. Replace any committed placeholder or legacy default in examples in a
   separate hardening PR if policy requires removing committed defaults.
4. Verify with a non-production or already-approved PR path where possible.
5. Revoke the previous credential after the replacement is confirmed.
6. Record the rotation date, owner, affected repositories, and validation result
   in the operator audit trail.

### Leak Response

1. Revoke the credential immediately in GitHub.
2. Audit recent PR reviews, merges, branch-protection changes, and repository
   administration events for the affected owner.
3. Notify Eric, the orchestrator owner, and any affected repository maintainers.
4. Rotate any credentials stored or used in the same shell session or host.
5. Preserve relevant logs for incident review without copying token values.

## `GH_ADMIN_TOKEN`

- **Type:** GitHub admin PAT template variable.
- **Possessor:** Eric or the designated toolkit operator.
- **Current storage:** Versioned token template only; the real value belongs in
  the operator's approved local credential-loading process.
- **Used for:** Future or optional admin token loading for merge and branch
  protection operations.

### Rotation

1. Create a new GitHub PAT with the required repository and organization
   administration scopes.
2. Update the operator-controlled runtime source that exports `GH_ADMIN_TOKEN`.
3. Confirm `gh auth status` or a read-only repository API call succeeds under
   the intended account.
4. Revoke the old PAT.
5. Record the rotation in the operator audit trail.

### Leak Response

1. Revoke the PAT immediately in GitHub.
2. Review GitHub audit logs for repository, organization, and branch protection
   activity by the token owner.
3. Notify Eric and repository maintainers for every repository the token could
   access.
4. Replace the token and verify only after audit review begins.

## `GH_TOKEN_RBOKCLI<agent>`

- **Type:** Optional per-agent GitHub PAT.
- **Possessor:** The named RBOKCLI agent account owner.
- **Current storage:** Versioned token template only; real values belong in the
  operator's approved local credential-loading process.
- **Used for:** Agent-specific GitHub operations such as issue assignment when
  a workflow chooses to run under an agent identity.

### Rotation

1. For each affected agent account, create a replacement PAT with only the
   scopes required for assignment and repository operations.
2. Update the operator-controlled runtime source for that specific
   `GH_TOKEN_RBOKCLI<agent>` variable.
3. Validate with a harmless `gh issue view` or equivalent read-only command.
4. Revoke the old PAT for that agent account.
5. Record which agent account was rotated and why.

### Leak Response

1. Revoke the leaked agent PAT immediately.
2. Audit issue assignments, comments, pushes, PR reviews, and workflow triggers
   by that agent account.
3. Notify Eric, the orchestrator owner, and maintainers of repositories the
   agent could access.
4. Rotate any sibling agent tokens if the same storage location or shell session
   may have been exposed.

## `GH_TOKEN`

- **Type:** GitHub CLI environment token variable.
- **Possessor:** The process that sets it for a single command invocation.
- **Current storage:** Not a long-term storage location. `lib/pr_merge.sh`
  assigns it transiently from `PR_MERGE_ADMIN_TOKEN` for specific `gh`
  commands.
- **Used for:** Overriding the GitHub CLI credential for one command.

### Rotation

1. Rotate the source credential that populated `GH_TOKEN`.
2. Stop any shells, daemons, or jobs that may still have the old value in their
   environment.
3. Restart the relevant toolkit command after loading the replacement source.
4. Verify the command path succeeds without printing environment variables.

### Leak Response

1. Treat exposure as exposure of the source credential.
2. Revoke the source credential immediately.
3. Stop affected processes and clear shell history or logs that captured
   environment dumps.
4. Audit the GitHub actions available to the source credential.

## GitHub CLI Token Store via `GH_CONFIG_DIR`

- **Type:** GitHub CLI credential store pointer.
- **Possessor:** The operator account configured in that GitHub CLI profile.
- **Current storage:** GitHub CLI credential files or system keyring selected by
  `GH_CONFIG_DIR` in project configs.
- **Used for:** Routine `gh` operations in `lib/governance_check.sh`,
  `lib/pr_merge.sh`, and orchestration scripts.

### Rotation

1. Identify the GitHub account bound to the selected `GH_CONFIG_DIR`.
2. Log the profile out with `gh auth logout` using that config directory.
3. Re-authenticate with `gh auth login` using the intended account and scopes.
4. Confirm `gh auth status` reports the expected account.
5. Run a read-only repository command through the toolkit config.
6. Record account, scope, and rotation date in the operator audit trail.

### Leak Response

1. Revoke the GitHub CLI token or OAuth grant from the GitHub account settings.
2. Remove or quarantine the affected credential directory or keyring entry.
3. Audit GitHub activity by that account for the exposure window.
4. Re-authenticate into a fresh credential store.
5. Notify maintainers for repositories accessible by the account.

## Review Checklist

- [ ] No secret values are present in this file.
- [ ] Every variable found by the audit is listed above or explicitly classified
      as a non-secret audit hit.
- [ ] Rotation steps have an owner, revocation step, validation step, and audit
      trail step.
- [ ] Leak response includes immediate revocation, audit log review, and
      maintainer notification.
