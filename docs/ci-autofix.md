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
4. Writes a canonical prompt file at:
   `/tmp/dispatch-<agent>-autofix-pr-<pr>.md`
5. Dispatches that prompt through `dispatch_ticket.sh`
6. Tracks retry count in:
   `$(state_dir)/ci_autofix_retries.json`

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
