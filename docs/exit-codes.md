# ORDO Exit Codes

This manifest is the maintained source of truth for ORDO exit codes.
Operators, runbooks, downstream automation, and audit consumers should
treat this document as the canonical mapping from a numeric exit
status to a remediation step. Scripts continue to declare the codes
inline as `: "${ORCH_*_EXIT_CODE:=<n>}"` defaults so that callers can
override them per deployment, but the documented meaning lives here.

This page is informational. It does not change runtime behavior; it
records the contract that the existing scripts already implement under
issue #290.

## Audit scope

The codes documented here are inventoried from the toolkit at base
`c790a6c` (see `docs/exit-codes.md` history for refresh dates). The
inventory was produced with:

```bash
grep -rn 'ORCH_[A-Z_]*EXIT_CODE' lib/ scripts/
```

Every `ORCH_*_EXIT_CODE` variable name found by that command is listed
in the manifest below. New variables added in future PRs must be
appended to the same table in the same PR so this document does not
drift.

## Reserved ranges

| Range  | Reserved for                                               |
| ------ | ---------------------------------------------------------- |
| 0      | Success.                                                   |
| 1      | Generic failure (default `set -e` propagation).            |
| 2      | Usage / argument-parse error (`die`, `usage`).             |
| 4      | Portfolio context mismatch and matrix readiness refusal.   |
| 75–79  | ORDO operational refusals (degraded host, mismatch, opt-in required). |
| 124    | Subprocess timeout (POSIX `timeout(1)` convention).        |
| 137    | Subprocess killed (SIGKILL, often from `timeout --kill-after`). |

The 75–79 band is the ORDO-specific refusal block. Operators inspecting
a non-zero exit from a dispatch wave should map it to this manifest
first; values outside the documented ranges are unexpected and warrant
a finding under the production CAPA rule
(`docs/orchestrator-injected-rules.md` rule 9).

## Manifest

| Code | Variable                                  | Defining file                | Meaning                                                                                                                                              | Operator remediation                                                                                                                              |
| ---- | ----------------------------------------- | ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| 75   | `ORCH_TMUX_DEGRADED_EXIT_CODE`            | `scripts/dispatch_ticket.sh` | tmux probe failed; brief was not sent to the pane and dispatch fell back to GitHub-only signalling.                                                  | Inspect the tmux server (`tmux ls`), restart the agent pane, then redispatch. See `docs/host-health-runbook.md`.                                  |
| 75   | `ORCH_HOST_GATE_DEGRADED_EXIT_CODE`       | `lib/host_load_gate.sh`      | Host load gate refused work because CPU load, fork latency, disk usage, or a configured guard process exceeded the gate threshold.                   | Wait for load to recover or rerun with `ORCH_HOST_GATE_MODE=audit` after triaging the offending signal. Audit line: `HOST_GATE refuse context=...`. |
| 75   | `ORCH_HOST_FORENSICS_DEGRADED_EXIT_CODE`  | `lib/host_forensics.sh`      | Host forensics probe (`scripts/host_forensics_probe.sh`) detected a degraded condition (timeout, missing tool, or threshold breach).                 | Read the probe stderr line, follow the linked remediation, and rerun the probe. The shared 75 code keeps the "degraded host" semantic class consistent. |
| 75   | `ORCH_VALIDATOR_FORK_DEGRADED_EXIT_CODE`  | `lib/process_safety.sh`      | Validator fork preflight or semaphore detected an unsafe fork latency, an existing semaphore lock, or a stuck validator runner.                      | Free the semaphore (`scripts/process_safety_preflight.sh`), wait for fork latency to recover, and rerun the validator.                            |
| 76   | `ORCH_CONTEXT_MISMATCH_EXIT_CODE`         | `scripts/dispatch_ticket.sh` | Post-dispatch pane context proof refused: the pane's pwd, remote, branch, or workdir did not match what dispatch had recorded.                       | Inspect the pane (`tmux display-message`), reconcile the workdir or remote drift, and redispatch. Distinct from 77 so callers can tell wrong-context (76) from never-sent (77). |
| 77   | `ORCH_DISPATCH_NOT_READY_EXIT_CODE`       | `scripts/dispatch_ticket.sh` | Pre-dispatch readiness handshake failed: the pane was not in the worktree with the agent CLI live, so the brief was never delivered.                 | Inspect `AGENT_READY_REASON` in the audit log, fix the pane (respawn, login, cd to worktree), then redispatch.                                    |
| 78   | `ORCH_HEAVY_VALIDATION_EXIT_CODE`         | `scripts/dispatch_ticket.sh`, `scripts/brief_agents.sh` | Heavy local validators were requested without `--require-local-validators`. The dispatch is refused so a wave does not duplicate the CI `validate` job. | Add `--require-local-validators` to the brief or dispatch invocation, or remove the heavy validator from the prompt.                              |
| 78   | `ORCH_GITHUB_IDENTITY_MISMATCH_EXIT_CODE` | `lib/github_identity.sh`     | The active `gh` login does not match the agent's expected login. The mutation (issue assign, comment, label) is refused before any GitHub state is changed. | Switch the active `gh` login (`gh auth switch`), set `GH_CONFIG_DIR` to the right config directory, or correct `ORCH_EXPECTED_GH_LOGIN`. The audit line is `github_identity_mismatch: expected=... active=... context=...`. |
| 79   | `ORCH_DISPATCH_NOT_CONSUMED_EXIT_CODE`    | `scripts/dispatch_ticket.sh` | Brief paste-buffer or send-keys was attempted but the pane did not consume the dispatch (queued input, stuck shell, abandoned prompt).               | Inspect the pane, clear stale input or queued work, and redispatch. The script also files a `dispatch_blockers.json` entry under the project state dir. |
| 124  | `ORCH_TIMEOUT_EXIT_CODE`                  | `lib/process_safety.sh`      | A wrapped subprocess hit its `timeout(1)` limit (matches the POSIX convention; `137` is also accepted for SIGKILL after `--kill-after`).             | Increase the timeout if the operation is genuinely long, or fix the underlying hang. The wrappers in `lib/process_safety.sh` and `lib/host_forensics.sh` translate 124/137 into a degraded-host signal where appropriate. |

## Conventions

- **Default-and-override pattern.** Every code is declared as
  `: "${ORCH_<NAME>_EXIT_CODE:=<n>}"` so a deployment can override the
  numeric value through the environment. Documentation must always
  refer to the variable name, not the numeric value alone, because the
  numeric default can in principle differ between deployments.
- **Shared-code semantic classes.** When several variables share a
  numeric default (75 for "degraded host", 78 for "refused"), the
  shared code is intentional: it lets a single operator runbook handle
  every refusal in the same band. Any new variable in a shared band
  must keep the band's semantic meaning or pick a new code.
- **Standard codes.** Codes 124 and 137 follow the POSIX timeout
  conventions and are not ORDO-specific. They are listed here only so
  operators reading an exit code do not misclassify them.
- **Audit lines.** Every refusal in this manifest is also recorded in
  the configured audit trail. The audit line format is documented next
  to the source of the refusal (search for the variable name in
  `lib/audit_log.sh` consumers).

## Adding a new exit code

When a new exit code is introduced:

1. Pick the smallest free number in the appropriate range. Reuse an
   existing code only if the new condition belongs to the same
   semantic class (e.g. another "degraded host" signal can reuse 75).
2. Declare the override-friendly variable at the top of the script or
   library:
   ```bash
   : "${ORCH_<NAME>_EXIT_CODE:=<n>}"
   ```
3. Append a row to the manifest table above in the same PR. The CI
   convention assumes that the manifest stays in sync with the source.
4. Cross-reference the new variable from the relevant operator doc
   (`docs/dispatch-planning.md`, `docs/host-health-runbook.md`,
   `docs/controlled-operations.md`, etc.) so an operator landing on
   the runbook can reach this manifest in one click.
5. Update or extend `docs/orchestrator-injected-rules.md` rule 11 if
   the new code carries an audit-policy implication that orchestrator
   agents need to honor.

## Out of scope for this manifest

- **Issue-provider exit codes** (e.g. `gh` itself) — the relevant
  failure surface is the audit line emitted by the wrapper, not the
  raw `gh` exit code, which can change between releases.
- **Application-level exit codes from downstream products** — those
  belong in each product's own runbook and are not coordinated by
  ORDO.
- **`set -e` propagation chains** — the manifest documents intentional
  refusals. A `set -e` exit from an unintended command failure is a
  bug to fix in the script, not a documented contract.
