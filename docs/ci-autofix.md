# CI autofix runbook

`scripts/ci_autofix.sh` builds a remediation prompt from a failed PR, then
re-dispatches the original agent with the CI context attached.

## When to use it

Use it when:

- a PR already exists
- one or more GitHub checks are red
- you want the same agent to fix the failure with the exact failed-step logs

Do not use it when:

- the PR has no failing checks
- the branch failure is unrelated to the PR itself
- all failed checks are GitHub Actions billing/spending-limit job-start blockers
- the retry cap for that PR has already been reached

## Command

```bash
bash scripts/ci_autofix.sh <project> <pr_number> <agent> [--dry-run]
```

Example:

```bash
bash scripts/ci_autofix.sh <project-config> 2724 builder --dry-run
```

## What it does

1. Reads PR metadata with `gh pr view`
2. Reads failed checks with `gh pr checks`
3. Extracts failed-step logs with `gh run view --log-failed`
4. Checks empty-log failed jobs for external GitHub Actions blocker annotations
5. Writes a canonical prompt file at:
   `/tmp/dispatch-<agent>-autofix-pr-<pr>.md`
6. Dispatches that prompt through `dispatch_ticket.sh`
7. Tracks retry count in:
   `$(state_dir)/ci_autofix_retries.json`

## Merged-PR skip (#371)

`ci_autofix.sh` queries the target PR's GitHub state up-front (extending
the existing `gh pr view` call's `--json` field list, so no extra round
trip is added on the merged path) and refuses to dispatch when the PR is
already merged or closed without merge. This avoids wasting agent
capacity on a PR that no longer exists and prevents a worker that
follows stale instructions literally from resurrecting a deleted head
branch. Two skip paths fire depending on the PR's terminal state:

```text
AUDIT LOG: <ts> CI_AUTOFIX skip reason=already_merged
  agent=<a> pr=<n> mergedAt=<ts> mergeCommit=<sha>
ci_autofix: skipping pr #<n> — already merged at <ts> (commit <sha>)
```

```text
AUDIT LOG: <ts> CI_AUTOFIX skip reason=closed_without_merge
  agent=<a> pr=<n> closedAt=<ts>
ci_autofix: skipping pr #<n> — closed without merge at <ts>;
  reopen or open a new PR before retry
```

Both paths exit 0, so cron-driven autofix loops do not escalate the skip
as a failure; the audit lines are the durable signal for the orchestrator
summary. Skipped stale dispatches aggregate separately from
`CI_AUTOFIX no failed checks` and `CI_AUTOFIX retry cap reached` thanks
to their distinct `reason=` codes.

As defense-in-depth against the brief-seconds race where a PR is merged
between `ci_autofix.sh`'s state check and the actual brief paste, the
script forwards `--skip-if-pr-merged` to `dispatch_ticket.sh`. That flag
re-runs the same `state` / `mergedAt` lookup immediately before pasting
into the agent pane, refusing with exit 0 and a
`DISPATCH skip reason=already_merged` audit line if the second check
finds the PR merged. The flag is **opt-in** (default off) so existing
`dispatch_ticket.sh` callers — operator-driven dispatches, the wave
dispatcher, integration tests where the ticket is an issue rather than
a PR — see no behavior change. Operators that drive `dispatch_ticket.sh`
directly for autofix-style waves can pass the flag explicitly or set
`ORCH_DISPATCH_SKIP_IF_PR_MERGED=1` for the duration of the session.

## External blocker skip (#623)

When a failed GitHub Actions check has no failed-step log, `ci_autofix.sh`
looks up the check-run annotations for the job id in the check URL. If the
annotation text matches a GitHub Actions billing, spending-limit, or
job-not-started failure, the script classifies the PR as externally blocked
instead of dispatching a code-remediation prompt.

```text
AUDIT LOG: <ts> CI_AUTOFIX skip reason=blocked_external
  agent=<a> pr=<n> blocker=github_actions_billing_job_start merge_watch=1
ci_autofix: skipping pr #<n> - blocked_external;
  leaving PR on merge-watch queue
```

The skip exits 0, does not write a prompt file, and does not increment
`ci_autofix_retries.json`. This keeps retry accounting focused on
worktree-remediable failures while leaving the PR visible for the normal
merge-watch flow once GitHub Actions account billing or spending-limit
state is fixed.

## Retry guard

The script refuses once `CI_AUTOFIX_MAX_RETRIES` is reached for a PR.

Default:

```bash
CI_AUTOFIX_MAX_RETRIES=3
```

The retry state is not mutated in `--dry-run`.

## Dry-run behavior

With `--dry-run`, the script still:

- reads PR and check metadata
- generates the prompt file
- relays `--dry-run` to `dispatch_ticket.sh`

But it does not increment retry state.

## Operational notes

- The generated prompt is canonical, so normal dispatch validation still applies.
- The script is intentionally standalone for now; no automatic hook into
  `orch_loop.sh` is enabled by default.
- The current implementation assumes the failed check links expose a GitHub
  Actions run id (`/actions/runs/<id>`). If a provider or check format does not
  expose that, the prompt still dispatches, but the log section will note the
  missing run id.
