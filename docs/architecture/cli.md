# Unified `ordo` CLI

Audience: operators and developers. Category: API / CLI references
(see [docs/architecture/README.md → 7. API / CLI references](README.md#7-api--cli-references)).

Epic [#806](https://github.com/decarvalhoe/ORDO/issues/806) (agentic control
plane), child [#809](https://github.com/decarvalhoe/ORDO/issues/809).

`scripts/ordo.sh` is the single entry point of ORDO. It is a **facade**: every
command routes to the existing script that implements the behaviour today,
passes the arguments through verbatim, and returns that script's exit code.
Nothing in the routed scripts changed; calling them directly keeps working.

```bash
ln -s "$PWD/scripts/ordo.sh" ~/.local/bin/ordo   # or: alias ordo="bash $PWD/scripts/ordo.sh"
source <(ordo completion bash)

ordo help
ordo status examples/lumen.config.sh --json
ordo plan examples/lumen.config.sh --ready-only --json
ordo dispatch examples/lumen.config.sh fleet-001 42 /tmp/dispatch-fleet-001-42.md --dry-run
ordo watch examples/lumen.config.sh wave-7
ordo merge examples/lumen.config.sh wave-7 '^feat/wave-7-' --dry-run
```

## Files

| Path | Role |
| --- | --- |
| `scripts/ordo.sh` | Entry point. Resolves `TK`, sources the library, calls `ordo_cli_main "$@"`. |
| `lib/ordo_cli.sh` | Command registry, routing, output modes, structured errors, help, bash completion. All functions are prefixed `ordo_cli_`. |
| `tests/cli/ordo_cli.bats` | Coverage. Routed commands run against stub scripts selected through `ORDO_CLI_SCRIPT_DIR`, so the suite needs neither tmux nor a provider CLI. |
| `docs/exit-codes.md` → "Agentic control plane" | The exit-code table and error-object shape shared by every new `ordo_*` surface. |

## Command table

| Command | Purpose | Status |
| --- | --- | --- |
| `status` | Fleet status for one project; `--loop` for the supervisor loop; `--portfolio` for the portfolio capacity summary | routed |
| `plan` | Ranked dispatch plan from the issue queue (ready/blocked, atomize, hotspots, priority sets) | routed |
| `dispatch` | Send one prepared brief to one agent pane; `--wave` dispatches a matrix file with a durable ledger | routed |
| `watch` | Wait for agents to commit a wave's worth of work; `--prs` surfaces pull-request states that block the merge flow | routed |
| `resume` | Resume a paused or blocked run | planned, native scheduler (#810) |
| `approve` | Grant or deny a pending approval | planned, native approvals (#812) |
| `cancel` | Cancel a queued or running run | planned, native scheduler (#810) |
| `recover` | Re-dispatch an agent whose pane died or got stuck | routed |
| `merge` | Merge the pull requests of a wave in CI-gated order; `--portfolio` runs the portfolio-level preview/apply | routed |
| `help` | List commands with descriptions and routing targets; `help <cmd> [variant]` prints the underlying script's usage banner | native |
| `version` | Print the CLI version (`--json` for a JSON object) | native |
| `completion` | `ordo completion bash` prints a bash completion script generated from the registry | native |

The registry is the array `ORDO_CLI_REGISTRY` in `lib/ordo_cli.sh`. Each row is
`name|variant|status|script|json_mode|needs_project|post_args|description`.
`ordo help --json` prints it as a JSON array for tooling.

## Routing table

| `ordo` invocation | Runs | JSON mode | First positional |
| --- | --- | --- | --- |
| `ordo status <project> [--tsv]` | `scripts/agent_pool_status.sh <project> [--tsv] [--json]` | passthrough | project |
| `ordo status --loop <project>` | `scripts/orch_ctl.sh <project> status` | wrap | project |
| `ordo status --portfolio <portfolio-config> [...]` | `scripts/portfolio_status.sh <portfolio-config> [...] [--json]` | passthrough | portfolio config |
| `ordo plan <project> [...]` | `scripts/dispatch_plan.sh <project> [...] [--json]` | passthrough | project |
| `ordo dispatch <project> <agent> <ticket> <prompt> [...]` | `scripts/dispatch_ticket.sh <project> <agent> <ticket> <prompt> [...]` | wrap | project |
| `ordo dispatch --wave <wave-id> <matrix> [...]` | `scripts/dispatch_wave.sh <wave-id> <matrix> [...]` | wrap | wave id |
| `ordo watch <project> [wave]` | `scripts/smart_poll_agents.sh <project> [wave]` | wrap | project |
| `ordo watch --prs <project>` | `scripts/pr_block_signals.sh <project> [--json]` | passthrough | project |
| `ordo recover <project> <agent> [--reset-state]` | `scripts/recover.sh <project> <agent> [--reset-state]` | wrap | project |
| `ordo merge <project> <wave> <branch-regex> [...]` | `scripts/pr_merge_wave.sh <project> <wave> <branch-regex> [...]` | wrap | project |
| `ordo merge --portfolio <portfolio-config> [...]` | `scripts/portfolio_auto_merge.sh <portfolio-config> [...] [--json]` | passthrough | portfolio config |
| `ordo resume`, `ordo cancel`, `ordo approve` | nothing yet — exit 6 with `not_implemented` | native | — |

Rules that make the routing predictable:

- A **variant flag** (`--loop`, `--portfolio`, `--wave`, `--prs`) is consumed
  by the CLI only when it is registered for that command. `ordo dispatch ...
  --portfolio pf.config.sh` therefore still reaches `dispatch_ticket.sh`
  unchanged, because `--portfolio` is not a variant of `dispatch`.
- Every other argument is forwarded in the order given, including `--dry-run`,
  `--tsv`, `--apply`, `--reset-state`, and anything after a literal `--`.
- `--json` and `--help`/`-h` are global: they are recognised anywhere in argv
  (before or after the command) and removed before routing. Anything after a
  literal `--` is forwarded verbatim, `--json` included.
- Commands whose first positional argument is a **project** accept the same
  values as the underlying scripts (short profile name or config path,
  resolved by `lib/config_resolver.sh`). When it is omitted, the CLI uses
  `ORDO_PROJECT_PROFILE`; when that is empty too, the CLI exits 2 with a
  `missing_project` error instead of letting the script misread a flag as a
  profile name.
- `ORDO_CLI_SCRIPT_DIR` overrides the directory the routed scripts are looked
  up in (default `$TK/scripts`). Tests use it to point at stubs.

## Output modes

| Mode | Selected by | Behaviour |
| --- | --- | --- |
| human (default) | no `--json` | The child's stdout and stderr stream through untouched; the exit code is the child's. |
| machine, passthrough | `--json` on a command whose target already accepts `--json` | `--json` is appended to the child's argv; the child's native JSON is the output. |
| machine, wrap | `--json` on a command whose target has no JSON mode | The child's stdout is captured and printed as one JSON object; stderr still streams through; the exit code is still the child's. |

Wrapped shape:

```json
{"command":"status","target":"scripts/orch_ctl.sh","exit_code":0,"stdout":"project: ...\nloop: ...\n"}
```

Native commands honour `--json` as well: `ordo help --json` prints the
registry, `ordo version --json` prints `{"version":...,"toolkit_root":...}`.

## Errors and exit codes

Every error the CLI itself raises is **one JSON line on stderr** in the shape
fixed by the epic brief, and nothing on stdout:

```json
{"error":{"code":"unknown_command","message":"unknown command: bogus (try: ordo help)","module":"cli","details":{"command":"bogus"}}}
```

| Exit | Meaning | CLI error codes |
| --- | --- | --- |
| 0 | ok | — |
| 1 | generic failure | any unmapped code |
| 2 | usage / bad arguments | `usage`, `unknown_command`, `missing_project` |
| 3 | refused (policy / fail-closed) | `refused` |
| 4 | not found | `not_found`, `unknown_variant` |
| 5 | invalid state / transition / conflict | `invalid_state`, `conflict` |
| 6 | missing dependency | `not_implemented` (resume/cancel/approve until #810/#812 land), `target_missing` (routing target absent) |
| 7 | budget exhausted | `budget_exhausted` |
| 8 | lease lost / stale | `lease_lost` |

Routed commands do **not** remap anything: the exit code of `dispatch_ticket.sh`,
`pr_merge_wave.sh`, etc. is returned unchanged (the legacy 75–92 refusal band
of [docs/exit-codes.md](../exit-codes.md) stays authoritative for them), and in
wrap mode it is also reported in the `exit_code` field.

`ordo_cli_error <code> <message> [details-json]` is the emitter. When
`lib/ordo_contracts.sh` (child #807) is present it is sourced and its
`ordo_contracts_error` is used to print the object; the CLI keeps ownership of
the code → exit mapping (`ordo_cli_exit_code_for`) so exit codes stay stable
regardless of which emitter printed the line. `ORDO_CLI_NO_CONTRACTS=1`
disables the sourcing (tests use it to pin the fallback path).

## Help and completion

- `ordo help` — every command with its one-line description and routing target.
- `ordo help <cmd>` or `ordo <cmd> --help` — the command's target, whether it
  needs a project, its sibling variants, then the usage banner of the routed
  script (the leading comment block, which is the script's contract).
- `ordo help <cmd> <variant-flag>` (e.g. `ordo help status --loop`) — same for
  one variant.
- `ordo completion bash` — prints a completion function generated from the
  registry (command names, per-command variant flags, global flags; positional
  arguments fall back to filename completion). Install with
  `source <(ordo completion bash)`; it registers for both `ordo` and `ordo.sh`.

## Migration plan: route incrementally

1. **Now (this child):** the facade routes to the existing scripts. Operators
   can start using `ordo <cmd>` today; every documented `bash scripts/<x>.sh`
   invocation keeps working and keeps its output, flags and exit codes.
2. **As native modules land**, a registry row flips from `routed` to `native`
   without changing the command's public shape:
   - `resume`, `cancel` → scheduler (#810) replaces the `planned:#810` rows;
   - `approve` → approvals (#812) replaces the `planned:#812` row;
   - `status`, `watch` may gain journal-backed variants (#808) next to the
     routed ones, selected by a variant flag so the routed behaviour is still
     reachable.
3. **Compatibility wrappers stay** until each surface has a proven native
   replacement (epic decision: keep Bash adapters operational during
   migration). The existing script remains the reference implementation and
   its tests keep running unchanged; the CLI test suite only asserts routing,
   output modes and error contracts.
4. **Adding a command or variant** means adding one registry row, one row in
   the tables above, and one routing test in `tests/cli/ordo_cli.bats`. Help
   and completion are generated from the registry, so they cannot drift.

## Compatibility notes

- No existing script was modified. `scripts/ordo.sh` and `lib/ordo_cli.sh` are
  additive; direct invocation is covered by the pre-existing suites and by a
  regression test in `tests/cli/ordo_cli.bats`.
- The CLI adds no runtime dependency: bash and `jq` (already required by the
  routed scripts).
- No `ORCH_*_EXIT_CODE` variable is introduced, so the legacy exit-code
  manifest and its drift guard (`tests/test_exit_codes_manifest.sh`) are
  untouched; the new table is appended to `docs/exit-codes.md` as a separate
  section.
- `ordo watch --loop` (a `tail -f` of the supervisor log) is intentionally
  not registered: a streaming command cannot be wrapped in JSON mode. Use
  `bash scripts/orch_ctl.sh <project> tail` directly.
