# Forge providers: Forgejo/Gitea, GitLab, GitHub

Audience: integrator, operator, developer. Category: integration / developer
docs (see [docs/architecture/README.md → 2. Integration](README.md#2-integration)
and [→ 5. Developer docs](README.md#5-developer-docs)).

Epic [#806](https://github.com/decarvalhoe/ORDO/issues/806), child
[#815](https://github.com/decarvalhoe/ORDO/issues/815). This page is the
per-forge companion of [adapters.md](adapters.md), which defines the boundary
(`ordo_provider <op>`), the normalised JSON shapes, the mutation policy and
the conformance suite. Here: how to configure each forge, which endpoints
each op maps onto, what is native, emulated or unsupported, and the known
differences a caller may observe.

**The organisation runs on Forgejo. GitHub stays supported but is not
privileged; GitLab works too.** Callers cannot tell the forge apart: every
op returns the same key set on the three forges (pinned by
`tests/ordo_provider_adapter_{forgejo,gitlab}.bats` against the
github-derived fixtures of `tests/fixtures/adapters/fake/`).

## Files

| Path | Role |
| --- | --- |
| `lib/ordo_provider_adapter_http.sh` | Shared `curl` layer of the REST backends: base URL, token handling, timeouts, retries, classification of HTTP/transport failures into the typed error objects, pagination helpers, the native `mutate` passthrough. Never sourced directly; loaded by the backends. |
| `lib/ordo_provider_adapter_forgejo.sh` | Forgejo / Gitea backend (REST API v1). |
| `lib/ordo_provider_adapter_gitlab.sh` | GitLab backend (REST API v4). |
| `lib/ordo_provider_adapter_github.sh` | GitHub backend through `gh` (#811, unchanged). |
| `tests/fixtures/adapters/stub_server.sh` | python3-stdlib HTTP stub (127.0.0.1, ephemeral port) serving recorded responses keyed by `METHOD/path`, with forge-faithful pagination headers, token check, failure injection (`fail.json`) and a request journal (`requests.jsonl`). |
| `tests/fixtures/adapters/forgejo/`, `tests/fixtures/adapters/gitlab/` | Recorded API responses of the conformance dataset (repo `acme/widgets`, issues #7–#11, PRs/MRs #12–#16, runs/pipelines 100–103 and 200) built from the public API documentation of each forge. |
| `tests/ordo_provider_rest_harness.bash` | Shared bats harness: starts the stub per test, writes a 0600 token, installs a `gh` decoy, defines the conformance hooks and `assert_no_token_leak`. |

## Configuration

| Variable | Forgejo / Gitea | GitLab | GitHub |
| --- | --- | --- | --- |
| `ORDO_PROVIDER_ADAPTER` | `forgejo` | `gitlab` | `github` (default) |
| `ORDO_FORGE_URL` | instance base, e.g. `https://forge.example` (`/api/v1` appended; a URL already ending in `/api/v1` is accepted) | instance base, e.g. `https://gitlab.example` (`/api/v4` appended or accepted) | optional; a non-github.com host becomes `GH_HOST` |
| `ORDO_FORGE_REPO` | `owner/repo` | project path, nested groups allowed (`group/sub/repo`); sent URL-encoded as the project id | `owner/repo` (`GH_REPO` fallback) |
| `ORDO_FORGE_TOKEN_FILE` | 0600 file holding an access token → `Authorization: token <t>` | 0600 file holding a personal/project/group access token → `PRIVATE-TOKEN: <t>` | not used (`gh auth`) |
| `ORDO_FORGE_TOKEN` | env fallback when no file is configured | same | — |
| `ORDO_PROVIDER_TIMEOUT_SEC` | read timeout per call (30) | same | timeout around `gh` reads |
| `ORDO_PROVIDER_MUTATION_TIMEOUT_SEC` | timeout per mutating call (120) | same | — (mutations never killed) |
| `ORDO_PROVIDER_HTTP_RETRIES` | bounded retries of **reads** on 429/5xx/transport errors (0); `Retry-After` honoured up to `ORDO_PROVIDER_HTTP_RETRY_MAX_SLEEP` (5 s) | same | `gh` retries itself |
| `ORDO_PROVIDER_HTTP_PAGE_SIZE`, `ORDO_PROVIDER_HTTP_MAX_PAGES` | page size (50) and page cap (20) of the "fetch every page" loops | same | — |
| `ORDO_PROVIDER_HTTP_LOG` | optional trace file: `ts method url status ms` — never headers, never bodies | same | — |
| `ORDO_FORGEJO_WIP_PREFIXES` | draft title prefixes recognised (`WIP:\|[WIP]\|Draft:\|[Draft]`); the first one is written by `pr_create --draft` / `pr_ready --undo` | — | — |
| `ORDO_GITLAB_DRAFT_PREFIX` | — | prefix written for drafts (`Draft:`); `Draft:`, `[Draft]`, `(Draft)`, `WIP:`, `[WIP]` are recognised | — |

### Token file setup

```bash
install -d -m 700 ~/.config/ordo
umask 077
printf '%s\n' '<the token>' > ~/.config/ordo/forge-token      # one line, no quotes
chmod 600 ~/.config/ordo/forge-token
```

Rules enforced by `lib/ordo_provider_adapter_http.sh`:

- a token file readable by group or other is **refused** with exit 3
  (`error.code=refused`, `details.reason=token_file_permissive`,
  `details.fix="chmod 600 <file>"`) before any request;
- a missing file is `not_found` (exit 4), an empty file `bad_argument`
  (exit 2), no file and no `ORDO_FORGE_TOKEN` is `bad_argument`;
- the token reaches `curl` through a configuration document on stdin
  (`curl --config -`): it is never on the command line (`ps`), never in a
  file, never in a URL (`access_token=` / `private_token=` are refused),
  never in `ORDO_PROVIDER_HTTP_LOG`, the audit log, the idempotency ledger,
  an error object or a payload. Forge error messages that echo the token
  back are masked (`[REDACTED]`), as are `ghp_…`, `sk-…`, `Bearer …` and
  `glpat-…` values in `log_failed`. The bats suites grep every produced file
  and every captured output for the token after each op, success and
  failure paths included;
- `curl` never follows redirects, so the token cannot be replayed to
  another host.

Which token: on Forgejo an access token with `read:user`, `read:repository`,
`write:issue`, `write:repository` (merge) and `read:misc`; on GitLab a token
with the `api` scope (`read_api` suffices for a read-only profile). With
`ORCH_EXTERNAL_PR_MUTATIONS` empty (the default), ORDO only reads, whatever
the token can do.

### Forgejo example

```bash
# external project profile (never in the repository)
PROJECT=widgets
GH_REPO=acme/widgets                      # legacy name, still the default of ORDO_FORGE_REPO
ORDO_PROVIDER_ADAPTER=forgejo
ORDO_FORGE_URL=https://forge.example.org
ORDO_FORGE_REPO=acme/widgets
ORDO_FORGE_TOKEN_FILE=$HOME/.config/ordo/forge-token
export ORDO_PROVIDER_ADAPTER ORDO_FORGE_URL ORDO_FORGE_REPO ORDO_FORGE_TOKEN_FILE

source lib/ordo_provider_adapter.sh
ordo_provider auth_status            # {"forge":"forgejo","authenticated":true,"host":"forge.example.org","login":"ordo-bot",...}
ordo_provider pr_get 12 | jq '.mergeable, .merge_state, .review_decision'
ORCH_EXTERNAL_PR_MUTATIONS=pr_merge ordo_provider pr_merge 12 --method squash --delete-branch -k "run_x:pr.merge:12"
```

### GitLab example

```bash
ORDO_PROVIDER_ADAPTER=gitlab
ORDO_FORGE_URL=https://gitlab.example.org
ORDO_FORGE_REPO=platform/tools/widgets    # nested group path; encoded as platform%2Ftools%2Fwidgets
ORDO_FORGE_TOKEN_FILE=$HOME/.config/ordo/gitlab-token
export ORDO_PROVIDER_ADAPTER ORDO_FORGE_URL ORDO_FORGE_REPO ORDO_FORGE_TOKEN_FILE

ordo_provider pr_list --state open --base main --limit 20 | jq '.items[] | {number, title, merge_state}'
ordo_provider checks_get 12 | jq '.summary'
ordo_provider issue_comment 7 --body-file note.md -k "run_x:issue.comment:7"
```

## Capability matrix

`native` = one forge call with the same meaning; `emulated` = rebuilt from
other calls or local filtering; `unsupported` = an honest neutral value
(never an error, never a fabricated "ready").

| Op | Forgejo / Gitea (API v1) | GitLab (API v4) |
| --- | --- | --- |
| `auth_status` | native `GET /user`. `scopes` is always `[]` (the API does not expose token scopes). A 401/403 gives `authenticated=false`, exit 0. | native `GET /user` + `GET /personal_access_tokens/self` (scopes, best effort). |
| `repo_get` | native `GET /repos/{o}/{r}`; `permission` from `permissions` (`admin`/`write`/`read`). | native `GET /projects/:id`; `permission` from the access level (40+ `admin`, 30 `write`, 20 `triage`, 10 `read`); `private` = visibility ≠ public. |
| `issue_get` | native `GET /repos/{o}/{r}/issues/{n}` (+ `/comments`, all pages, with `--with comments`). `closed_by_prs`: **unsupported → `[]`**. | native `GET /projects/:id/issues/:iid` + `/closed_by` (MRs that will close it) (+ `/notes` without system notes). |
| `issue_list` | native `GET …/issues?type=issues&state=&labels=&q=&created_by=&assigned_by=&milestones=&page=&limit=`; `has_more` from `X-Total-Count` (fallback `Link rel=next`). `--state merged` is meaningless for issues → `closed`. | native `GET …/issues?state=opened\|closed\|all&labels=&search=&author_username=&assignee_username=&milestone=&page=&per_page=`; `has_more` from `X-Next-Page`/`X-Total`. |
| `issue_create` | native `POST …/issues`; label **names resolved to ids** (repository labels, then organisation labels) — an unknown label is `not_found` (exit 4, `details.labels`); milestone by title. | native `POST …/issues`; `labels` as names; assignees resolved to user ids (`GET /users?username=`), milestone by title — unknown → `not_found`. |
| `issue_edit` | `--state` → `PATCH {state}` (+ a comment when `--body` is given with `--state closed`); otherwise `PATCH {title, body, milestone, assignees}` — the assignee list is **replaced**, so add/remove reads the current list first; labels through the label endpoints below. | `--state` → `PUT {state_event: close\|reopen}`; otherwise `PUT {title, description, target_branch, milestone_id, add_labels, remove_labels, assignee_ids}` (assignees read-merge-write, `[0]` clears). |
| `issue_comment` | native `POST …/issues/{n}/comments` (also for PRs: same index). | native `POST …/issues/:iid/notes`; `url` rebuilt as `<web_url>#note_<id>`. |
| `issue_labels` | native `POST …/issues/{n}/labels {labels:[ids]}` + `DELETE …/issues/{n}/labels/{id}` per removal. | native `PUT …/issues/:iid {add_labels, remove_labels}`. |
| `pr_get` | native `GET …/pulls/{n}` + `GET …/pulls/{n}/reviews`; `review_decision` derived (latest review per user: any `REQUEST_CHANGES` → `changes_requested`, else any `APPROVED` → `approved`, else requested reviewers or pending → `review_required`, else `none`). `mergeable` from the boolean `mergeable`; `merge_state` `clean`/`dirty`/`draft`/`unknown`. `auto_merge`: **unsupported → `false`**. `merge_commit` only once merged. | native `GET …/merge_requests/:iid` + `/approvals`; `review_decision`: `requested_changes` → `changes_requested`, approved by someone with no approvals left → `approved`, approvals required or `not_approved` or reviewers assigned → `review_required`, else `none`. `mergeable`/`merge_state` from `detailed_merge_status` (`conflict`→`conflicting`/`dirty`, `need_rebase`→`behind`, `ci_still_running`→`unstable`, `ci_must_pass`/`not_approved`/`discussions_not_resolved`/… → `blocked`, `draft_status`→`draft`, `checking`→`unknown`). `changed_files` from `changes_count` when numeric. |
| `pr_list` | `state`/`labels` native (`page`/`limit`, exact `has_more`). `--base`, `--head`, `--author`, `--assignee`, `--search` and `--state merged` are **emulated**: pages are walked (`ORDO_PROVIDER_HTTP_PAGE_SIZE` × up to `ORDO_PROVIDER_HTTP_MAX_PAGES`), filtered locally and sliced with an exact `has_more`. Items carry an **approximate** `review_decision` (`review_required` when reviewers are requested, else `none`) — call `pr_get`/`review_list` for the authoritative value. | all filters native (`target_branch`, `source_branch`, `author_username`, `assignee_username`, `search`, `labels`, `state=merged`). Items carry an approximate `review_decision` derived from `detailed_merge_status`/reviewers. |
| `pr_create` | native `POST …/pulls {title, body, head, base, labels:[ids], assignees}`; base defaults to the repository default branch; `--draft` prefixes the title with the first `ORDO_FORGEJO_WIP_PREFIXES` entry. | native `POST …/merge_requests {source_branch, target_branch, title, description, labels, assignee_ids}`; `--draft` prefixes with `ORDO_GITLAB_DRAFT_PREFIX`. |
| `pr_edit` | native `PATCH …/pulls/{n}` (`title`, `body`, `base`, `milestone`, `assignees`) + label endpoints. | native `PUT …/merge_requests/:iid`. |
| `pr_ready` | **emulated**: the edit API has no draft field; the WIP prefix is stripped from the title (`--undo` adds it). No request when the title already has the right form. | **emulated** the same way (`Draft:` prefix). |
| `pr_merge` | native `POST …/pulls/{n}/merge {Do: merge\|rebase\|squash, delete_branch_after_merge, merge_when_checks_succeed (--auto), force_merge (--admin)}`; `--disable-auto` = `DELETE …/pulls/{n}/merge`. Already merged / not mergeable → `conflict` (exit 5, HTTP 405/409). | native `PUT …/merge_requests/:iid/merge {squash, should_remove_source_branch, merge_when_pipeline_succeeds (--auto)}`; `--disable-auto` = `POST …/cancel_merge_when_pipeline_succeeds`. `--method rebase`: GitLab merges with the project's merge method — the request is sent with `squash=false` and `result.method` echoes what was asked; `--admin` has no equivalent and is ignored (`result.admin` echoes the flag). Not mergeable / draft / conflicts → `conflict` (HTTP 405/406). |
| `pr_files` | native `GET …/pulls/{n}/files` (all pages). | native `GET …/merge_requests/:iid/diffs` (all pages); `additions`/`deletions` **counted from the diff text**. |
| `checks_get` | native `GET …/commits/{sha}/status` (the combined status: one entry per context). Forgejo Actions jobs are published as statuses whose context is `<workflow> / <job> (<event>)`: they become `kind=check_run` with `name=<job>` and `workflow=<workflow>`; other contexts are `kind=status`. `pending` → `status=queued`; `success`/`failure`/`error`/`warning` → `completed` with `success`/`failure`/`failure`/`neutral`. | native `GET …/repository/commits/:sha/statuses` (all pipelines of the head sha, all pages); one entry per status name, the most recent wins (retried jobs, older pipelines). Statuses with a `pipeline_id` are `kind=check_run` (workflow = head pipeline name or `pipeline #<id>`), external ones `kind=status`. `running` → `in_progress`; `created`/`pending`/`waiting_for_resource`/`preparing`/`scheduled` → `queued`; `failed` → `failure` (`neutral` when `allow_failure`); `canceled` → `cancelled`; `manual` → `action_required` (`skipped` when `allow_failure`). |
| `review_list` | native `GET …/pulls/{n}/reviews` (`APPROVED`→`approved`, `REQUEST_CHANGES`→`changes_requested`, `COMMENT`→`commented`, `PENDING`→`pending`, dismissed→`dismissed`; `REQUEST_REVIEW` entries are not reviews); `decision` as in `pr_get`. | approvals (`approved_by` → `approved`) + `GET …/reviewers` (`requested_changes`→`changes_requested`, `reviewed`→`commented`, `unapproved`→`dismissed`, else `pending`); a user in both lists appears once (approval wins); `body` is `""`. |
| `run_list` | `GET …/actions/runs` (Forgejo ≥ v12 / Gitea ≥ 1.24, GitHub-like `{workflow_runs, total_count}`), fallback `GET …/actions/tasks` (Gitea ≥ 1.23). **Neither → empty list with `details.capability="unsupported"`, exit 0** (never an error, never "ready"). `--branch`/`--commit` via `head_branch`/`head_sha`, `--workflow` and `--state` filtered locally; local slicing. `name`/`workflow` are the workflow file name without extension when the API gives no name. | native `GET …/pipelines?ref=&sha=&status=&name=&page=&per_page=` (`--state queued`→`pending`, `in_progress`→`running`, `completed`→`scope=finished`). `run_number` = pipeline `iid`, `event` = pipeline `source`, `name` = pipeline name or `pipeline #<iid>`. |
| `run_get` | `GET …/actions/runs/{id}` + `…/actions/runs/{id}/jobs` (absent → `jobs=[]`). `--with log_failed`: `GET …/actions/jobs/{job}/logs` of each failed job, best effort, masked, capped by `ORDO_PROVIDER_LOG_MAX_BYTES`. | `GET …/pipelines/:id` + `…/pipelines/:id/jobs`; jobs carry `steps=[]` (no step API). `--with log_failed`: `GET …/jobs/:id/trace` of failed jobs, masked, capped. |
| `mutate` | native passthrough: `-- --method POST\|PUT\|PATCH\|DELETE --path <relative or /api/v1/…> [--body JSON \| --body-file F]`. The method+path are classified (`…/pulls/N/merge` → `pr_merge`, `…/reviews` → `pr_review`, `…/comments` → `issue_comment`, `…/labels` → `issue_labels`, `PATCH …/pulls/N` → `pr_edit`, `POST …/pulls` → `pr_state`, …) and must be covered by the declared `--scope`, otherwise `policy_refused` before any request — the REST counterpart of the `gh`-argument double gate. Result: `{backend:"rest", args, stdout, method, path, status, body}`. | same, with the GitLab paths (`…/merge_requests/N/merge`, `/approve`, `/notes`, …). |

## Errors, retries, rate limits

`lib/ordo_provider_adapter_http.sh` classifies every exchange once, for both
forges (`details.backend="rest"`, `details.method`, `details.path`,
`details.http_status`, `details.curl_exit`, `details.category`,
`details.attempts`, `details.mutation`):

| Outcome | `error.code` | exit | `details.retryable` | `details.category` |
| --- | --- | --- | --- | --- |
| HTTP 404 / 410 | `not_found` | 4 | false | `not_found` |
| HTTP 401 | `provider_error` | 1 | false | `auth` |
| HTTP 403 | `policy_refused` | 3 | false | `permission` — the **forge** refused (branch protection, missing right); `details.authorize_via` is absent, unlike a local policy refusal |
| HTTP 405 / 406 / 409 / 422 | `conflict` | 5 | false | `conflict` (already merged, not mergeable, validation) |
| HTTP 429 | `rate_limited` | 1 | **true** | `rate_limited`, `details.retry_after` when the forge sent `Retry-After` |
| HTTP 5xx | `provider_error` | 1 | **true** | `transient` |
| other 4xx | `provider_error` | 1 | false | `client` (the forge message is flattened into `error.message`) |
| curl timeout (28) on a read | `provider_error` | 1 | **true** | `timeout` |
| curl timeout on a mutation | `provider_error` | 1 | **false** | `timeout` — the outcome is unknown; the message says so. Read the forge state, then retry with the same idempotency key |
| curl 6/7/35/52/55/56 (DNS, connect, TLS, empty reply, send/recv) | `provider_error` | 1 | true for reads (connect/DNS also for mutations) | `transient` |
| other curl failures | `provider_error` | 1 | false | `transport` |
| non-JSON body where JSON was expected | `invalid_json` | 5 | false | — |
| missing `curl` | `missing_dependency` | 6 | false | — |

Retries: `ORDO_PROVIDER_HTTP_RETRIES` (default 0) re-issues **reads** on
retryable outcomes, sleeping `Retry-After` seconds (capped by
`ORDO_PROVIDER_HTTP_RETRY_MAX_SLEEP`, 1 s when absent). Mutations are never
retried by the HTTP layer: `details.attempts` is always 1 for them, and the
retry mechanism is the idempotency key of the generic layer (a failed
mutation is not recorded in the ledger, so the same key executes again).

## Known differences a caller may observe

- **`review_decision` in lists is approximate** on both REST forges (one
  request per page, not per item). `pr_get` and `review_list` are
  authoritative. GitHub lists carry the exact `reviewDecision`.
- **`closed_by_prs` is empty on Forgejo** (no API); GitLab and GitHub fill it.
- **`auto_merge` is always `false` on Forgejo** (the PR object does not
  expose a scheduled auto-merge); `--auto`/`--disable-auto` still work.
- **`pr_ready` and `--draft` are title edits** on Forgejo and GitLab. On a
  repository whose WIP prefixes were customised, set
  `ORDO_FORGEJO_WIP_PREFIXES` accordingly.
- **`checks_get` timestamps**: Forgejo statuses have `created_at`/`updated_at`
  only (`started_at`/`completed_at` are derived); GitLab statuses have both.
- **Forgejo `pr_list` with local filters** costs up to
  `ORDO_PROVIDER_HTTP_MAX_PAGES` requests; prefer `--state open` + `--label`
  (native) when possible.
- **GitLab `pr_merge --method rebase` / `--admin`** are not expressible; the
  project merge method applies. Forgejo honours `Do=rebase` and
  `force_merge`.
- **Runs on Forgejo depend on the instance version**; an instance without
  the Actions API answers `run_list` with an empty list and
  `details.capability="unsupported"` so a fail-closed caller sees "no
  evidence" rather than a crash. `run_get` on such an instance is
  `not_found`.
- **Bodies are sent verbatim** (`jq --rawfile`): the trailing newline the
  generic layer appends to `--body` reaches the forge, exactly as
  `gh --body-file` sends it.
- **Rate limits**: neither forge exposes a documented `X-RateLimit-*`
  contract like GitHub; the adapters only react to HTTP 429 (+ `Retry-After`).

## Tests

```bash
bats tests/ordo_provider_adapter_forgejo.bats tests/ordo_provider_adapter_gitlab.bats tests/ordo_provider_adapter.bats
shellcheck -e SC1090,SC1091 -x lib/ordo_provider_adapter_*.sh tests/fixtures/adapters/stub_server.sh
```

Each test starts its own stub (`tests/fixtures/adapters/stub_server.sh`,
python3 stdlib, 127.0.0.1, ephemeral port written to a port file), gives it
a 0600 token file the stub demands on every request, and runs the
conformance suite of [adapters.md](adapters.md) plus adapter-specific
scenarios: key-set parity with the github-derived fixtures, the exact
request bodies of every mutation, pagination headers, the Actions fallback
chain, the classification table above (including a 429 with `Retry-After`,
a read timeout, a mutation timeout and bounded retries), and token hygiene
after every op — success and failure paths — by grepping every produced
file (audit log, ledger, http log, stub journal) and every captured output.
A `gh` decoy on `PATH` proves the REST adapters never call it.

Failure injection for new scenarios: write `fail.json` into the stub control
directory, e.g.
`{"method":"GET","path":"/api/v1/repos/acme/widgets/pulls/12","status":429,"headers":{"Retry-After":"7"},"times":1}`
(`path_regex`, `body`, `sleep` are also accepted); requests land in
`requests.jsonl` (method, path, query, body, status — never headers).

## Migration status

Child [#816](https://github.com/decarvalhoe/ORDO/issues/816) routes the
existing direct `gh` call sites through `ordo_provider`. Each row is one
file; "sites" counts direct `gh` invocations before → after the migration.
The guard `tests/ordo_no_direct_gh_lib.bats` pins the remaining sites and
`tests/ordo_lib_fake_provider.bats` proves the migrated libraries run end to
end with `ORDO_PROVIDER_ADAPTER=fake` and no `gh` on `PATH`.

### lib/ (migrated by #816)

| File | Sites (before → after) | Ops used | Idempotency keys | Notes |
| --- | --- | --- | --- | --- |
| `lib/pr_merge.sh` | 17 → 0 | `pr_get`, `checks_get` (via governance_check), `run_list`, `repo_get`, `pr_ready`, `pr_merge` (`--method squash`, `--admin`, `--disable-auto`), `issue_comment`, `issue_edit --state closed`, `issue_labels`, `mutate --scope pr_review` | `pr_merge:<repo>#<n>:<head_sha>`, `pr_merge.admin:…`, `pr_merge.disable_auto:…`, `pr_ready:<repo>#<n>:<head_sha>`, `pr_review.approve:…`, `issue_comment.reconcile:<repo>#<issue>:pr<n>:<merge_commit>`, `issue_close.reconcile:…`, `issue_labels.reconcile:…:<label>` | `gh_retry` became `provider_retry` (retries on `details.retryable`). Mutations are now gated: set `ORCH_EXTERNAL_PR_MUTATIONS=pr_merge,pr_ready,pr_review,issue_comment,issue_close,issue_labels` (or `all`); a refusal audits `MERGE REFUSED … reason=policy-refused` and exits 4. Enums are projected back to the upper-case audit vocabulary. Closing-issue references come from title/body keywords only. The admin approval still uses `mutate` (no `pr_review` op yet). |
| `lib/governance_check.sh` | 8 → 3 | `checks_get`, `pr_get`, `pr_files` | — (reads) | Commit statuses (`kind=status`) now count as checks — on Forgejo every check is one. `gov_required_checks`, `gov_branch_protected`, `gov_pr_review_required` keep `gh api …/branches/…/protection` on the github adapter only (`TODO(#816)`: needs a branch-protection op) and answer "unknown" elsewhere. |
| `lib/ci_external_blockers.sh` | 2 → 1 | `run_get` (`.jobs[]`) | — | Check-run annotations stay on `gh api` for the github adapter only (`TODO(#816)`: needs a check-annotations op); empty elsewhere. |
| `lib/env_diagnostics.sh` | 4 → 0 | `auth_status`, `issue_list`, `pr_list`, `repo_get` | — | Keys unchanged (`gh.status`, `gh.login`, `gh.host`, counts) plus `gh.forge` and `gh.adapter`; `gh.status=missing` when the backend CLI is absent (`missing_dependency`). |
| `lib/recovery_context.sh` | 1 → 0 | `pr_get` | — | Adapter loaded lazily (sourced by `dispatch_ticket.sh`); the `pr_status …` line keeps its upper-case values. |
| `lib/autonomous_pr_ops.sh` | 2 → 0 | `pr_get`, `pr_files`, `checks_get` | — | `_auto_pr_ops_pr_view` projects the neutral shape onto the `gh pr view --json` vocabulary so gate evaluators and `auto_pr_ops_pr_field` jq expressions are unchanged. `ORCH_GH_BIN` retired. |
| `lib/blocker_issue_registry.sh` | 1 (+ wrapper) → 0 | `issue_list --search`, `issue_edit --state open\|closed`, `issue_labels --add` | `blocker_issue:<close\|reopen\|label:<l>>:<repo>#<n>` | `blocker_issue_gh` is kept as a shim for `scripts/blocker_issue_registry.sh` (issue reopen/edit/close only); delete it once that script calls `ordo_provider` directly. |
| `lib/github_identity.sh` | 1 → 0 | `auth_status` (`.login`) | — | `orch_github_active_login` reads the active login of whatever forge is configured; `ORCH_GITHUB_IDENTITY_GH_BIN` retired; adapter loaded lazily. |
| `lib/gh_body_helpers.sh` | 1 → 0 | `issue_comment`, `issue_create`, `pr_create`, `mutate --scope pr_comment\|pr_review` | `ORDO_PROVIDER_IDEMPOTENCY_KEY` or `gh_body:<op>:<repo>#<subject>:<sha256(body)[0:16]>` | Same argument shape as before, bodies still travel by file; stdout is `result.url`. Callers are now gated by `ORCH_EXTERNAL_PR_MUTATIONS`. `GH_BODY_HELPERS_GH_BIN` retired. |
| `lib/gh_pr_files_batch.sh` | 1 → 1 | `pr_files` (one read per PR) | — | The batched `gh api graphql` read is kept on the github adapter only (`TODO(#816)`: needs a batched `pr_files` op); every other forge loops `pr_files` with the same TSV output. |
| `lib/external_mutation_gate.sh` | 1 → 1 | — | — | `command gh "$@"` in `external_pr_mutation_run` is the gh-aware second gate the github backend runs mutations through (adapters.md, "Mutation policy", step 4) — infrastructure, not a call site. |

Remaining direct `gh` reads in `lib/` (all marked `TODO(#816)`, all guarded on
`ordo_provider_adapter_name`): branch protection (3 lines,
`governance_check.sh`), check-run annotations (1 line,
`ci_external_blockers.sh`), batched GraphQL file listing (3 lines,
`gh_pr_files_batch.sh`). Adding a `repo_branch_protection`,
`check_annotations` and batched `pr_files` op to the adapter boundary (#815
for Forgejo/GitLab) removes them.

### scripts/ (migrated by #816)

Every forge call of `scripts/*.sh` goes through `ordo_provider <op>`; the
scripts project the normalised shapes back onto the field names their
existing `jq`/`awk`/`python` consumers read (enums upper-cased as `gh`
printed them), so the human-readable output, the TSV/JSON columns and the
exit codes are unchanged. Mutations carry a stable idempotency key
(`<context>:<action>:<subject>`; a per-run id — `ORDO_RUN_ID` under the
scheduler — for acts that must be re-applied on a later run) and are gated
by the adapter (`ORCH_EXTERNAL_PR_MUTATIONS`, audit-only by default).
`tests/ordo_no_direct_gh_scripts.bats` guards the result;
`tests/ordo_provider_scripts_e2e.bats` runs the status, dispatch and merge
scripts against the fake adapter with no `gh` on `PATH`.

| Script | Ops used | Status |
| --- | --- | --- |
| `agent_pool_status.sh` | `pr_list` | migrated |
| `agent_product_switch.sh` | `pr_list --head` | migrated |
| `audit_state.sh` | `pr_list`, `run_list` | migrated |
| `auto_close_shipped_suspect.sh` | `pr_get`, `issue_get`, `issue_edit --state closed` (key `auto_close_shipped_suspect:issue_close:<repo>#<issue>:pr<pr>`) | migrated; the former `external_pr_mutation_run` pair is replaced by the adapter gate |
| `brief_agents.sh` | `issue_get` | migrated |
| `check_ci_health.sh` | `run_list`, `run_get` | migrated; **TODO** `gh api …/check-runs/{id}/annotations` (needs `check_annotations`) and `gh run view --log` (needs `run_get --with log`) stay GitHub-only, skipped on other adapters |
| `ci_autofix.sh` | `pr_get`, `pr_files`, `checks_get`, `run_get --with log_failed` | migrated |
| `ci_watcher_daemon.sh` | `run_list --branch` | migrated |
| `dispatch_matrix.sh` | `issue_list`, `issue_get` | migrated |
| `dispatch_plan.sh` | `issue_list`, `issue_get [--with comments]`, `pr_list`, `pr_get`, `pr_files`, `checks_get`, `issue_create`, `issue_labels`, `issue_comment` (keys derived from the atomize trace id) | migrated; **TODO** `gh label list` (needs `label_list`) stays GitHub-only. The atomize mutations are now gated: `--atomize --apply` needs `issue_create,issue_labels,issue_comment` in `ORCH_EXTERNAL_PR_MUTATIONS` |
| `dispatch_ticket.sh` | `pr_list`, `pr_get`, `issue_get`, `issue_edit --add-assignee` (key `<run>:issue_assignees:<repo>#<n>:<login>`) | migrated; the script's own `issue_assignees` assert and identity guard stay in front of the adapter call |
| `monitor_heartbeat.sh` | `pr_list`, `checks_get` (per mergeable PR), `issue_list --search` | migrated |
| `orch_loop.sh` | — (preflight) | `gh` is only required when `ORDO_PROVIDER_ADAPTER=github` (`curl` for forgejo/gitlab) |
| `portfolio_repo_bind_plan.sh` | — | **TODO** `gh repo list <owner>` (needs `repo_list`): owner discovery stays GitHub-only |
| `portfolio_session_start.sh` | `repo_get` | migrated: a missing workdir is cloned with `git clone` from the forge URL (`clone_url`, else `<url>.git`); `gh repo clone` is gone |
| `post_merge_cleanup.sh` | `repo_get`, `issue_get`, `pr_get`, `issue_edit --state closed` (key `post_merge_cleanup:issue_close:<repo>#<issue>:pr<pr>`) | migrated; **TODO** the pr shape has no linked-issue list (`closingIssuesReferences`), closing keywords in title/body remain the source |
| `pr_block_signals.sh` | `pr_list`, `pr_get`, `checks_get`, `pr_files`, `run_list --branch --commit` | migrated; **TODO** `gh api …/branches/{b}/protection` (needs `branch_protection_get`) and `gh workflow list` (needs `workflow_list`) stay GitHub-only, empty/unknown elsewhere |
| `pr_merge_wave.sh` | `pr_list`, `pr_files` | migrated (the merge itself is `lib/pr_merge.sh`) |
| `reclaim_orphan_assignments.sh` | `issue_get`, `issue_edit --remove-assignee` (key `<run>:issue_assignees:<repo>#<n>:remove:<login>`) | migrated |
| `safe_post_merge_cleanup_recovery.sh` | `pr_get` | migrated |
| `sixsigma_autoupgrade.sh` | `pr_list`, `checks_get` (per PR) | migrated |
| `smart_poll_agents.sh` | `pr_list` | migrated |
| `ci_autofix.sh`, `dispatch_pr_ops.sh` (prompt text) | — | the `gh …` lines are instructions rendered into agent briefs, not calls |

Conventions the migrated scripts share (candidates for `lib/` helpers):
`_provider_backend_available` (github → `gh` on `PATH`, fake →
`ORDO_FAKE_ADAPTER_DIR`, otherwise `curl`) keeps the historical "no CLI, skip
silently" behaviour; `ORDO_PROVIDER_TIMEOUT_SEC=<script timeout>` and
`GH_CONFIG_DIR=<profile dir>` are set per call; the adapter is sourced
**after** `lib/audit_log.sh` (which defines an array of the same name as the
gate's scope registry — the gate's string must win).
