# Persistent CLI flags across internal restarts

This page documents the per-CLI flag set ORDO treats as **persistent**
across an agent's internal worker restarts, and the drift detector that
backs the regression coverage at
[`tests/cli/test_persistent_flags.bats`](../../tests/cli/test_persistent_flags.bats).

## Background — why it matters

Some agent CLIs (notably Claude Code; Codex behaves the same way) have
an internal session-worker process that the launcher re-spawns on
long-running runs or on certain error recoveries. The launcher parses
CLI flags once at process start. If it does not re-apply the originally
parsed set to the new worker, persistent operator flags silently revert
to their CLI defaults.

Issue [#411](https://github.com/RBOKproject/ORDO/issues/411) captured
this in the field: 8 of 12 fleet panes lost their `--debug-file` target
after a Claude CLI internal restart, so log output stopped landing at
the operator-supplied path (`/var/log/ordo/<agent>.log`) and started
landing at the CLI default (`~/.claude/debug/<random>.log`). Log
aggregation broke silently.

The fix proper lives in the upstream CLI (the launcher must persist its
own originally-parsed argv across worker re-spawns). The
ORDO-side workaround documented below makes the drift observable so
operators can heal it through the existing launch-contract path.

## Persistent-flags contract

| CLI    | Persistent flags                                                                      |
|--------|---------------------------------------------------------------------------------------|
| claude | `--name`, `--debug-file`, `--append-system-prompt`, `--mcp-config`, `--allowed-tools` |
| codex  | `--name`, `--debug-file`                                                              |

The `claude` row extends the identity-token set already enforced by
`agent_launch_command_missing_identity_tokens`
([`lib/worktree_helpers.sh`](../../lib/worktree_helpers.sh)) with the
two flags Claude operators rely on to scope MCP servers
(`--mcp-config`) and the agent toolset (`--allowed-tools`) — both must
survive a worker re-spawn for parity with the pre-restart session.
Operators should always read the canonical list at runtime via
`persistent_flags_for_cli <cli>` rather than hard-code it.

## Drift detector

[`lib/persistent_flags.sh`](../../lib/persistent_flags.sh) exposes three
pure helpers:

- `persistent_flags_for_cli <cli>` — echo the canonical persistent flag
  list, one per line. Empty list (rc=0) for unknown CLIs.

- `persistent_flags_extract_value <cmdline_file> <flag>` — parse a
  NUL-separated `/proc/<pid>/cmdline` file and echo the live value of
  `<flag>`. Handles both `--flag value` (separate argv entries) and
  `--flag=value` (single argv entry). Returns rc=1 (no stdout) when the
  flag is absent.

- `persistent_flags_drift <cmdline_file> <flag> <expected>` — compare
  the live value to the contract. Return codes:

  | rc | meaning                                                                |
  |----|------------------------------------------------------------------------|
  | 0  | no drift; the live value matches the contract                          |
  | 1  | mismatch; the flag is present but points at a different target         |
  | 2  | absent; the flag is missing from cmdline (canonical #411 symptom)      |
  | 3  | usage error (missing `<expected>` argument)                            |

These return codes do not introduce new `ORCH_*_EXIT_CODE` variables so
the manifest at [`docs/exit-codes.md`](../exit-codes.md) is unchanged.

## Healing flow

When `persistent_flags_drift` returns 1 or 2 for a live agent process,
the operator (or a poller running this detector) re-launches the agent
through the launch-contract path:

1. Read the contract command via `agent_launch_contract <label>` (or
   the operator's `AGENT_LAUNCH_COMMAND` / `AGENT_LAUNCH_CONTRACTS`
   profile entry).
2. Hard-respawn the pane (e.g. through
   `scripts/agent_product_switch.sh --hard`), which `exec`s the
   contract command in place. The new process starts with the
   persistent flag set restored.
3. Re-run the drift check; rc=0 confirms the heal.

This is the same pathway PR
[#305](https://github.com/RBOKproject/ORDO/pull/305) introduced for
product-switch identity preservation; #411 just adds the read-side
detector.

## Acceptance criteria mapping

The acceptance criteria from #411 map onto this layer as follows:

| Criterion                                                                | Where it is satisfied                                                                                                                |
|--------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------|
| `lsof` on the agent process shows the same `--debug-file` target after the restart | Live measurement is the upstream-CLI fix; ORDO observes the same fact via `/proc/<pid>/cmdline` (`persistent_flags_extract_value`). |
| Test in `tests/cli/test_persistent_flags.bats`                          | Synthetic `/proc/<pid>/cmdline` fixtures cover the pre-restart, post-restart-absent, and post-restart-mismatch cases.                |
| Persisted flags list documented                                          | The Persistent-flags contract table above.                                                                                           |
