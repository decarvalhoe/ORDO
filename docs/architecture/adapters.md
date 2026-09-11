# Runtime and provider adapters

Audience: developer, integrator. Category: developer docs / API reference
(see [docs/architecture/README.md → 5. Developer docs](README.md#5-developer-docs)).

Epic [#806](https://github.com/decarvalhoe/ORDO/issues/806) (agentic control
plane), child [#811](https://github.com/decarvalhoe/ORDO/issues/811).
Consumers: the scheduler (#810), approvals (#812), the eval harness (#813),
the Forgejo/GitLab adapters (#815) and the migration of the direct `gh` call
sites (#816).

Two boundaries isolate ORDO from the machinery it drives:

- the **runtime adapter** talks to the place where an agent runs (a tmux pane
  on this host, a tmux pane on a remote host over SSH, or a fake for tests);
- the **provider adapter** talks to the forge that holds issues, pull
  requests, checks, reviews and CI runs (GitHub today through `gh`; Forgejo
  and GitLab through REST once #815 lands; a fake for tests).

**Forge neutrality is a first-class requirement.** The organisation runs on
Forgejo; GitHub stays supported but is no longer privileged; GitLab must be
possible. The vocabulary of the boundary is therefore generic — issue, pr
(a pull request on GitHub/Forgejo, a merge request on GitLab), check, review,
run, mutation — and no `gh` concept crosses it: every adapter returns the
same normalised JSON shape per operation, and every failure is one typed
error object with `details.retryable`.

Nothing in the existing scripts changed. The libraries are additive: they
wrap `lib/tmux_helpers.sh` and `lib/external_mutation_gate.sh`, they never
rewrite them, and the existing call sites keep calling `tmux` and `gh`
directly until #816 migrates them.

## Files

| Path | Role |
| --- | --- |
| `lib/ordo_runtime_adapter.sh` | `ordo_runtime <op>`: registry, dispatch on `ORDO_RUNTIME_ADAPTER`, shared argument parsing, envelope, typed errors, evidence storage. |
| `lib/ordo_runtime_adapter_tmux.sh` | tmux backend: wraps `terminal_dispatch_submit`, `capture_pane`, `agent_is_idle`, `pane_acceptance_proof`, `tmux_run_timeout`. |
| `lib/ordo_runtime_adapter_ssh.sh` | SSH backend: ships the same tmux commands through `ssh <host> "tr -d '\r' \| bash -s"` (the transport of `scripts/windows_ssh_dispatch.sh`). |
| `lib/ordo_runtime_adapter_fake.sh` | Fake backend: JSON state under `$ORDO_FAKE_ADAPTER_DIR/runtime/`. |
| `lib/ordo_provider_adapter.sh` | `ordo_provider <op>`: registry (github, forgejo, gitlab, fake), dispatch on `ORDO_PROVIDER_ADAPTER`, argument parsing, mutation policy, idempotency ledger, stubs for forgejo/gitlab. |
| `lib/ordo_provider_adapter_github.sh` | GitHub backend. **The only place in the new code that invokes `gh`.** Normalises `gh --json` payloads; runs mutations through `external_pr_mutation_run`. |
| `lib/ordo_provider_adapter_fake.sh` | Fake backend: serves fixtures from `$ORDO_FAKE_ADAPTER_DIR/<op>/`, appends mutations to `$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl`. |
| `tests/ordo_runtime_adapter.bats` | 13 tests: fake lifecycle, tmux (mocked `tmux` logging every call), ssh (mocked `ssh` executing the snippet locally). |
| `tests/ordo_provider_adapter.bats` | 47 tests: registry, stubs, pass-through github == fake, 1:1 `gh` invocations, mutation policy, ledger, escape hatch, no-`gh` proof, and the conformance suite for github and fake. |
| `tests/ordo_provider_conformance.bash` | The reusable conformance suite (16 scenarios) parameterised by `ORDO_PROVIDER_ADAPTER`. |
| `tests/fixtures/adapters/github/` | Raw `gh` payloads plus `mock_gh.sh`, the fake `gh` used by the suites. |
| `tests/fixtures/adapters/fake/` | The normalised fixtures the fake serves — generated from the github fixtures through the github adapter, so both backends agree byte for byte. |

## Selection knobs

| Variable | Values | Default | Notes |
| --- | --- | --- | --- |
| `ORDO_RUNTIME_ADAPTER` | `tmux` \| `ssh` \| `fake` | `tmux` | Which runtime backend `ordo_runtime` dispatches to. |
| `ORDO_PROVIDER_ADAPTER` | `github` \| `forgejo` \| `gitlab` \| `fake` | `github` | Which forge backend `ordo_provider` dispatches to. `github` keeps today's behaviour. |
| `ORDO_FORGE_REPO` | `owner/repo` | — | Repository used when `--repo` is absent. `GH_REPO` is honoured as the legacy fallback so existing profiles work unchanged. |
| `ORDO_FORGE_URL` | base URL | — | Forge API base for the REST adapters (`https://forge.example/api/v1`, `https://gitlab.example/api/v4`). For `github` a non-github.com host becomes `GH_HOST` (GitHub Enterprise). |
| `ORDO_FORGE_TOKEN_FILE` | path | — | Token file for the REST adapters. Read only through `ordo_provider_adapter_token`; never inline, never logged, never part of any output. |
| `ORDO_FAKE_ADAPTER_DIR` | directory | — | Fixture root of both fake backends. Required when a fake is selected. |
| `ORDO_SSH_HOST` | ssh target | — | Host of the ssh runtime backend (`--host` overrides). Also `ORDO_SSH_BIN`, `ORDO_SSH_OPTS`, `ORDO_SSH_TIMEOUT_SEC` (30), `ORDO_SSH_REMOTE_COMMAND` (`tr -d '\r' \| bash -s`), `ORDO_SSH_REMOTE_TMUX` (`tmux`). |
| `ORDO_PROVIDER_TIMEOUT_SEC` | seconds | `30` | Timeout around read calls of the backend CLI/HTTP. Mutations are never killed mid-flight. |
| `ORDO_PROVIDER_LEDGER_FILE` | path | `<state_dir>/ordo-provider-idempotency.jsonl` | Override of the idempotency ledger location. |
| `ORDO_RUNTIME_EVIDENCE_DIR` | directory | `<state_dir>/runtime-evidence` | Where `collect_evidence` stores captures. |
| `ORDO_RUNTIME_LAUNCH_COMMAND` | command | — | Command used by `recover` when the session must be recreated (falls back to `agent_launch_command` when `lib/worktree_helpers.sh` is sourced). |

`state_dir` is the per-project directory of `lib/audit_log.sh`
(`$ORCH_STATE_BASE/$PROJECT`); when that library is not sourced the adapters
use the same layout with `PROJECT` defaulting to `default`. See the commented
block at the end of `examples/ordo.config.sh` for a profile example.

## Errors and retries

Every failure prints exactly one JSON line on stderr and nothing on stdout:

```json
{"error":{"code":"not_found","message":"gh pr_get failed (not_found): ...","module":"provider_adapter",
 "details":{"op":"pr_get","retryable":false,"adapter":"github","category":"not_found", "...":"..."}}}
```

`module` is `runtime_adapter` or `provider_adapter`. `details.retryable` is
always present and is `true` only when repeating the same call unchanged is
safe and may succeed (transport hiccup, timeout, rate limit, HTTP 5xx, a
dispatch text that was not consumed). Policy refusals, missing data, auth or
permission failures and conflicts are never retryable. Exit codes follow the
shared table of [docs/exit-codes.md → Agentic control plane](../exit-codes.md#agentic-control-plane-scriptsordosh-and-libordo_sh):

| Exit | `error.code` | When |
| --- | --- | --- |
| 1 | `provider_error`, `runtime_error` | backend failure; read `details.category` (`transient`, `timeout`, `auth`, `permission`, `unknown`) and `details.retryable` |
| 2 | `usage`, `bad_argument`, `unknown_command` | bad arguments, unknown op, unknown adapter name, mutation without `--idempotency-key`, unknown gate scope |
| 3 | `policy_refused` | the external mutation policy refused the scope (`details.scope`, `details.authorize_via`) |
| 4 | `not_found` | issue/pr/run/fixture/target does not exist |
| 5 | `conflict`, `invalid_json` | not mergeable / already merged / validation failed; idempotency key reused for a different op |
| 6 | `missing_dependency`, `provider_not_available`, `not_implemented` | `gh`/`tmux` missing; forgejo/gitlab selected before #815 (`details.implemented_by`) |

The github backend classifies `gh` stderr; token-looking values are masked
with `[REDACTED]` before they reach the error object.

## Runtime adapter

```bash
source lib/ordo_runtime_adapter.sh        # ORDO_RUNTIME_ADAPTER=tmux|ssh|fake

ordo_runtime start <target> (--text T | --text-file F) [--workdir DIR] [--agent A --ticket N] [--acceptance-timeout S]
ordo_runtime inspect <target> [--lines N]
ordo_runtime signal <target> <interrupt|escape|enter|clear|KEY>
ordo_runtime stop <target> [--kill]
ordo_runtime collect_evidence <target> [--lines N] [--label L] [--out FILE]
ordo_runtime recover <target> [--workdir DIR] [--command CMD]
ordo_runtime ops | adapters                  # introspection
```

`<target>` is the runtime-specific address, e.g. the tmux pane `fleet-001:0.0`
(`agent_target` from `lib/tmux_helpers.sh` still produces it). The ssh
backend also takes `--host` (or `ORDO_SSH_HOST`).

| Op | What it does (tmux) | Wrapped helper |
| --- | --- | --- |
| `start` | pastes the text and submits it; verifies consumption; with `--agent/--ticket` waits for the acceptance proof | `terminal_dispatch_submit`, `pane_acceptance_proof` |
| `inspect` | alive/dead, idle heuristic, cwd, foreground command, tail of the scrollback | `display-message`, `capture_pane`, `agent_is_idle` |
| `signal` | `interrupt`→`C-c`, `escape`→`Escape`, `enter`→`Enter`, `clear`→`terminal_dispatch_clear_input`, anything else is sent as a tmux key name | `send-keys`, `terminal_dispatch_clear_input` |
| `stop` | interrupt (`C-c`); `--kill` kills the pane | `send-keys`, `kill-pane` |
| `collect_evidence` | stores the last N lines (default 200), token-masked, under `runtime-evidence/`, with sha256 | `capture_pane` |
| `recover` | recreates a missing session (`new-session -d -s <session> -c <workdir> <cmd>`), respawns a dead pane (`respawn-pane -k`), otherwise no-op | `has-session`, `new-session`, `respawn-pane` (the sequence of `scripts/recover.sh`) |

Result shapes (one JSON object on stdout; every object carries
`op`, `adapter`, `ts`, `target`; the ssh backend adds `host`):

```jsonc
start            {"submitted":true,"bytes":123,"reason":"submitted","acceptance":null|{"accepted":bool,"reason":"brief-filename|ticket-reference|no-acceptance-evidence"}}
inspect          {"alive":bool,"idle":bool,"cwd":"/work/agent","command":"claude","capture":"...last lines...","lines":30}
signal           {"signal":"interrupt","delivered":true}
stop             {"action":"interrupt|kill","delivered":true}
collect_evidence {"requested_lines":200,"path":"<state_dir>/runtime-evidence/<target>-<ts>-<label>-<pid>.txt","lines":57,"bytes":2210,"sha256":"...","redacted":true}
recover          {"session":"fleet-001","action":"none|session_created|pane_respawned","alive":true,"workdir":"...","command":"..."}
```

A target that tmux cannot resolve is `not_found` (exit 4) for every op
except `recover`, which creates it. A submission that is not consumed is
`runtime_error` with `details.reason` (`submission-still-visible`,
`idle-prompt`, `no-positive-execution-proof`, ...) and `retryable=true`.

### ssh backend

The remote snippet is built locally, prefixed with `T=<target>` and a
`command -v tmux || exit 6` guard, and piped to
`ssh [ORDO_SSH_OPTS] <host> "tr -d '\r' | bash -s"` — exactly the transport of
`scripts/windows_ssh_dispatch.sh`, so carriage returns from Windows-originated
hosts never reach argv. Remote exit 4 = target missing, 6 = tmux missing,
ssh exit 255 or a local timeout = `runtime_error` with `retryable=true`.
The idle heuristic is applied locally to the captured tail (same regexes as
`agent_is_idle`).

### fake backend

`$ORDO_FAKE_ADAPTER_DIR/runtime/<safe-target>.json` holds
`{"target","alive","idle","cwd","command","capture","history":[...]}`;
every state change is also appended to `runtime/events.jsonl`. `recover`
creates a target, `stop --kill` marks it dead, `start` appends the first line
of the text to the capture and clears `idle`. The eval harness (#813) seeds
these files to script agent behaviour without tmux.

## Provider adapter

```bash
source lib/ordo_provider_adapter.sh       # ORDO_PROVIDER_ADAPTER=github|forgejo|gitlab|fake

# reads
ordo_provider auth_status
ordo_provider repo_get     [--repo R]
ordo_provider issue_get    <n> [--repo R] [--with comments]
ordo_provider issue_list   [--repo R] [--state open|closed|all] [--label L]... [--assignee A] [--author A] [--search Q] [--milestone M] [--limit N] [--page P]
ordo_provider pr_get       <n> [--repo R]
ordo_provider pr_list      [--repo R] [--state open|closed|merged|all] [--base B] [--head H] [--label L]... [--author A] [--assignee A] [--search Q] [--limit N] [--page P]
ordo_provider pr_files     <n> [--repo R]
ordo_provider checks_get   <n> [--repo R]
ordo_provider review_list  <n> [--repo R]
ordo_provider run_list     [--repo R] [--branch B] [--commit SHA] [--workflow W] [--state queued|in_progress|completed] [--limit N] [--page P]
ordo_provider run_get      <id> [--repo R] [--with log_failed]

# mutations (all require --idempotency-key K, alias -k)
ordo_provider issue_create  --title T [--body B | --body-file F] [--label L]... [--assignee A]... [--milestone M] -k K
ordo_provider issue_edit    <n> [--title T] [--body B|--body-file F] [--add-label L]... [--remove-label L]... [--add-assignee A]... [--remove-assignee A]... [--milestone M] [--state open|closed [--reason completed|not_planned]] -k K
ordo_provider issue_comment <n> (--body B | --body-file F) -k K
ordo_provider issue_labels  <n> [--add L]... [--remove L]... -k K
ordo_provider pr_create     --title T --head BRANCH [--base BRANCH] [--body B|--body-file F] [--draft] [--label L]... [--assignee A]... -k K
ordo_provider pr_edit       <n> [--title T] [--body B|--body-file F] [--base B] [--add-label L]... [--remove-label L]... [--add-assignee A]... [--remove-assignee A]... [--state open|closed] -k K
ordo_provider pr_ready      <n> [--undo] -k K
ordo_provider pr_merge      <n> [--method squash|merge|rebase] [--admin] [--auto] [--disable-auto] [--delete-branch] -k K
ordo_provider mutate        --scope <gate-scope> -k K -- <adapter-native args...>

ordo_provider ops | adapters                 # introspection
```

`--repo` defaults to `ORDO_FORGE_REPO`, then `GH_REPO`. Bodies always travel
by file (`--body` is written to a temp file first), following the doctrine of
`lib/gh_body_helpers.sh`.

### Normalised shapes

Every read returns `{"op","adapter","repo"} + payload`. Timestamps are
RFC3339 strings or `null`; enums are lowercase and forge-neutral.

```jsonc
auth_status {"forge":"github","authenticated":true,"host":"github.com","login":"octo-bot","scopes":["repo",...],"backend":"gh"}
repo_get    {"name","owner","full_name":"owner/repo","default_branch","url","private":bool,"permission":"admin|maintain|write|triage|read|","description"}
issue       {"number","title","state":"open|closed","labels":[str],"assignees":[str],"url","body","author","created_at","updated_at","closed_at",
             "milestone":str|null,"closed_by_prs":[{"number","state"}],"comments":[{"author","body","created_at","url"}]  /* only with --with comments */}
pr          {"number","title","state":"open|closed|merged","draft":bool,"head":{"ref","sha"},"base":{"ref"},"url",
             "mergeable":"mergeable|conflicting|unknown","merge_state":"clean|blocked|behind|dirty|unstable|has_hooks|draft|unknown",
             "author","labels":[str],"assignees":[str],"review_decision":"approved|changes_requested|review_required|none",
             "auto_merge":bool,"created_at","updated_at","merged_at","closed_at","merge_commit":str|null,"body","changed_files":int|null}
issue_list / pr_list / run_list
            {"items":[...],"count":n,"page":p,"limit":l,"has_more":bool}
pr_files    {"number","files":[{"path","additions","deletions"}],"count"}
checks_get  {"number","sha","checks":[{"name","kind":"check_run|status","status":"queued|in_progress|completed",
             "conclusion":"success|failure|neutral|cancelled|skipped|timed_out|action_required|stale|startup_failure|null",
             "url","workflow":str|null,"started_at","completed_at"}],
             "summary":{"total","passed","failed","pending","state":"pass|fail|pending|none"}}
review_list {"number","decision":"approved|changes_requested|review_required|none",
             "reviews":[{"author","state":"approved|changes_requested|commented|dismissed|pending","body","submitted_at","url"}]}
run         {"id","run_number","name","workflow","title","status":"queued|in_progress|completed|...","conclusion":str|null,
             "head_sha","head_branch","url","created_at","updated_at","event",
             "jobs":[{"id","name","status","conclusion","url","started_at","completed_at","steps":[{"name","number","status","conclusion"}]}]  /* run_get */,
             "log_failed":"..."  /* run_get --with log_failed, token-masked, capped by ORDO_PROVIDER_LOG_MAX_BYTES */}
```

Pagination: `--page P --limit N` selects items `[(P-1)N, PN)`; `has_more` is
exact (the github backend asks `gh` for `P·N+1` items and slices locally,
because `gh` lists have `--limit` but no page cursor). `summary.state` of
`checks_get` follows the CI-gate vocabulary of `lib/pr_merge.sh`
(`pass`, `fail`, `pending`, `none`).

Provider content (issue bodies, logs) is returned as-is except `log_failed`,
which is masked; callers that persist provider content into artifacts apply
`ordo_contracts_redact`.

### Mutation policy

The policy is enforced in `lib/ordo_provider_adapter.sh`, once, whatever the
backend, and stays authoritative over every adapter (#815 inherits it):

1. `--idempotency-key` is mandatory (`usage`, exit 2, before anything else);
2. the **ledger** `<state_dir>/ordo-provider-idempotency.jsonl` is consulted:
   a known key returns the recorded receipt unchanged with
   `details.replayed=true` and exit 0 — the backend is not called; the same
   key with a different op is `conflict` (exit 5);
3. the gate scope is derived from the op and its arguments —
   `issue_create`, `issue_comment`, `issue_labels`, `pr_ready`, `pr_merge`,
   `pr_create→pr_state`, `issue_edit/pr_edit→*_edit|*_labels|*_assignees|*_close|*_reopen`,
   `mutate→--scope` — and asserted through `external_pr_mutation_assert`
   (`lib/external_mutation_gate.sh`): audit-only by default, authorised per
   scope through `ORCH_EXTERNAL_PR_MUTATIONS`, every decision audited as
   `EXTERNAL_PR_MUTATION action=<scope> mode=allowed|refused context=provider_adapter:<adapter>:<op>:<repo>#<n>`;
   a refusal is `policy_refused` (exit 3);
4. the backend executes; the github backend runs the `gh` command through
   `external_pr_mutation_run`, which re-classifies the actual `gh` arguments
   and asserts again — so `mutate --scope pr_review -- pr merge ...` is
   refused even when `pr_review` is authorised;
5. the receipt is appended to the ledger. Failed or refused mutations are
   not recorded, so a retry with the same key executes.

Mutation results are receipts:

```jsonc
{"op":"pr_merge","adapter":"github","repo":"acme/widgets",
 "details":{"idempotency_key":"run_…:pr.merge:12","replayed":false,"scope":"pr_merge","recorded_at":"2026-09-11T06:38:42Z"},
 "result":{"number":12,"merged":true,"action":"merged|auto_merge_enabled|auto_merge_disabled","method":"squash","admin":false}}
```

`result` per op: `issue_create`/`pr_create` → `{number,url,...}`;
`issue_comment` → `{number,url}`; `issue_edit`/`pr_edit`/`issue_labels` →
`{number,url,labels_added,labels_removed}` or `{number,state}` for
close/reopen; `pr_ready` → `{number,draft}`; `mutate` →
`{backend,args,stdout}`.

The ledger records the receipt after the backend returned. If the process
dies between the two, a replay executes again: the key protects against
event replay (the journal, #808) and operator retries, not against a crash
in that window; forge-side idempotency (e.g. "already merged" → `conflict`)
covers the rest.

`mutate` is the escape hatch for call sites without a dedicated op
(`gh pr review --approve`, `gh issue close`, `gh pr merge --disable-auto`
…). Its native arguments are adapter-specific by design and carry no
forge-neutral guarantee; #816 should prefer the dedicated ops and keep
`mutate` for the long tail.

### fake backend

Fixtures live under `$ORDO_FAKE_ADAPTER_DIR/<op>/<key>.json` where `<key>` is
the number/id, the sanitised repo (`repo_get/acme__widgets.json`) or
`default`; lists are arrays filtered by `--state`, `--base`, `--branch`,
`--label`, `--author` then paginated. A fixture holding `{"error":{...}}`
is replayed as that error (used to test retry classification). Mutations
append one line to `$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl`
(`{"ts","op","adapter":"fake","repo","idempotency_key","scope","number","result",...}`)
and update the touched fixture best-effort (`pr_merge` → `state=merged`,
`pr_ready` → `draft=false`, label edits, `--state closed`). No CLI and no
network: `tests/ordo_provider_adapter.bats` proves every op works with an
empty `PATH` (no `gh`) — the pattern #816 uses for its end-to-end proof.

## Capability matrix

| Capability | github (`gh`) | forgejo (#815) | gitlab (#815) | fake |
| --- | --- | --- | --- | --- |
| auth_status, repo_get, issue_*, pr_get/list/files, pr_create/edit/ready/merge | yes | planned (REST v1) | planned (REST v4, merge requests) | yes |
| checks_get | check runs + commit statuses (`kind`) | planned: commit statuses / Actions | planned: pipelines/jobs | yes |
| review_list | reviews + `reviewDecision` | planned: reviews (no decision → derived) | planned: approvals | yes |
| run_list / run_get / log_failed | Actions | planned: Forgejo Actions (subset) | planned: pipelines | yes |
| `merge_state` detail | full | `unknown` unless the API exposes it | `unknown`/`dirty` from `merge_status` | fixture |
| pagination | `--limit` + local slicing | `page`/`limit` query | `page`/`per_page` | local |
| rate limiting | `gh` retries; 5xx retryable | to define (headers) | to define (headers) | n/a |

Until #815 lands, `ORDO_PROVIDER_ADAPTER=forgejo|gitlab` answers every op
with `provider_not_available` (exit 6, `details.implemented_by="#815"`),
before any policy or ledger side effect.

## How #815 adds an adapter

1. Create `lib/ordo_provider_adapter_forgejo.sh` (same for `gitlab`) defining
   `ordo_provider_adapter_forgejo_<op>` for the twenty ops. Each function
   reads the parsed arguments from the `ORDO_PV_*` globals
   (`ORDO_PV_NUMBER`, `ORDO_PV_REPO`, `ORDO_PV_STATE`, `ORDO_PV_LIMIT`,
   `ORDO_PV_PAGE`, `ORDO_PV_LABELS[]`, `ORDO_PV_ADD_LABELS[]`, `ORDO_PV_TITLE`,
   `ORDO_PV_BODY_PATH`, `ORDO_PV_HEAD`, `ORDO_PV_BASE`, `ORDO_PV_METHOD`,
   `ORDO_PV_WITH`, `ORDO_PV_NATIVE[]`, `ORDO_PV_SCOPE_RESOLVED`,
   `ORDO_PV_CONTEXT`, ... see `ordo_provider_adapter_parse_args`), prints the
   **bare** payload (the generic layer adds the envelope / receipt), and
   reports failures with `ordo_provider_adapter_error <code> <message> <retryable> [details]`.
   Use `ordo_provider_adapter_token` for the token, `ORDO_FORGE_URL` for the
   base URL, `ordo_provider_adapter_run_with_timeout` around `curl`.
   Do not call the mutation gate yourself: the generic layer already did.
2. The loader prefers the file over the stub, so the registry line
   `forgejo|stub:#815` in `ORDO_PROVIDER_ADAPTER_REGISTRY` only needs to be
   flipped to `forgejo|implemented` for documentation.
3. Run the conformance suite: in `tests/ordo_provider_adapter_forgejo.bats`,
   `load './helpers.bash'`, `setup_orch_test`, source the library and
   `tests/ordo_provider_conformance.bash`, define the three hooks
   (`conformance_backend_setup` — start the python3 stub HTTP server with
   recorded fixtures for the dataset described at the top of the suite;
   `conformance_inject_failure retryable|non_retryable` — make `pr_get <N>`
   fail that way and print N; `conformance_mutation_count`), then one
   `@test` per scenario calling `ordo_provider_conformance_run <scenario>`
   with `ORDO_PROVIDER_ADAPTER=forgejo`. The scenario names come from
   `ordo_provider_conformance_scenarios`.
4. Fill the capability matrix above and document the per-forge
   configuration in `docs/architecture/providers.md`.

## How #816 migrates call sites

Each direct `gh` call becomes one adapter call with the same inputs and the
normalised output; the mapping is 1:1 because the github backend issues
exactly the invocations the call sites use today
(`tests/ordo_provider_adapter.bats` pins them):

| Today | Adapter |
| --- | --- |
| `gh pr view N --json state,mergeStateStatus,mergeable` | `ordo_provider pr_get N` → `.state`, `.merge_state`, `.mergeable` |
| `gh pr view N --json files` | `ordo_provider pr_files N` → `.files[].path` |
| `gh pr view N --json statusCheckRollup` | `ordo_provider checks_get N` → `.checks[]`, `.summary.state` |
| `gh pr checks N --json name,state,bucket,link,workflow` | `ordo_provider checks_get N` → `.checks[] \| select(.conclusion == "failure")` |
| `gh pr list --state open --base main --json number,...` | `ordo_provider pr_list --state open --base main --limit L` → `.items[]` |
| `gh issue view N --json title,body,url` | `ordo_provider issue_get N` |
| `gh issue list --state open --limit L --json ...` | `ordo_provider issue_list --state open --limit L` → `.items[]` |
| `gh run list --branch B --json databaseId,...` | `ordo_provider run_list --branch B` → `.items[] \| {id,name,status,conclusion,head_sha}` |
| `gh run view ID --json jobs` / `--log-failed` | `ordo_provider run_get ID [--with log_failed]` |
| `gh repo view R --json defaultBranchRef` | `ordo_provider repo_get --repo R` → `.default_branch` |
| `gh auth status` preflights | `ordo_provider auth_status` → `.authenticated`, `.forge`, `.login`, `.host` |
| `gh_body_with_file issue comment N` | `ordo_provider issue_comment N --body-file F -k K` |
| `gh issue edit N --add-label L` | `ordo_provider issue_labels N --add L -k K` |
| `gh_retry gh pr merge N --squash` | `ordo_provider pr_merge N --method squash -k K` (retry on `details.retryable`) |
| `gh pr ready N`, `gh issue close N --reason completed` | `ordo_provider pr_ready N -k K`, `ordo_provider issue_edit N --state closed --reason completed -k K` |
| anything else that mutates | `ordo_provider mutate --scope S -k K -- <gh args>` |

Rules for the migration: keep `ORCH_EXTERNAL_PR_MUTATIONS` semantics
untouched (the adapter asserts the same scopes); derive idempotency keys from
stable inputs (`<run_id>:<action>:<subject>` — e.g. `run_…:pr.merge:12`), not
from timestamps; the ledger is per project, under `state_dir`; with
`ORDO_PROVIDER_ADAPTER=fake` and fixtures seeded from
`tests/fixtures/adapters/fake/`, a script must run end to end with no `gh`
on `PATH`.

## Design decisions

- **Policy lives in the generic layer.** `external_pr_mutation_run` is a
  `gh` wrapper; a REST adapter could not use it. The generic layer asserts
  the scope with `external_pr_mutation_assert` for every adapter and the
  github backend keeps `external_pr_mutation_run` as a second, `gh`-aware
  gate. Both audit; the audit line context names the adapter, op, repo and
  number.
- **Ledger before gate.** A replayed key must return the recorded result
  even when the policy has since been tightened: replay never mutates, so
  asking permission again would only create noise and non-determinism for
  the journal (#808).
- **`has_more` is exact, not a heuristic**, at the price of fetching one
  extra item; scripts that page through the whole queue
  (`dispatch_plan.sh`) need a trustworthy end-of-list signal.
- **Read output is not redacted**, `log_failed` and evidence captures are.
  Issue bodies are the work itself; logs and pane captures are the places
  where credentials leak.
- **Receipts are distinct from entities.** A mutation returns what happened
  (`details.scope`, `details.replayed`) plus the backend's `result`; a read
  returns the entity. Callers that need the fresh entity read it again.
- **Stubs fail before policy.** Selecting `forgejo` today gives
  `provider_not_available`, not `policy_refused`, so nobody "fixes" the
  policy to reach an adapter that does not exist yet.
