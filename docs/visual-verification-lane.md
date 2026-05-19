# Visual verification lane

The visual verification lane is an opt-in ORDO capability that reports
whether the current host can run GUI-driven verifications (real browser
sessions, Playwright/Cypress automation, design-tool MCPs, screenshot
capture) and that gives dispatch briefs a single structured signal to
decide whether to include visual verification instructions.

The lane is **provider-neutral**: nothing in the implementation hardcodes
a host name, browser brand, automation tool, or design-tool. Defaults are
candidate lists that operators override via environment variables in their
project profile or dispatch brief.

## Acceptance criteria mapping (#264)

| Criterion | Where it is satisfied |
| --- | --- |
| GUI/visual-check readiness reported as a structured capability | `lib/visual_lane.sh::visual_lane_collect`, JSON schema below. |
| Dispatch briefs can include visual instructions only when required | Lane is opt-in via `ORCH_VISUAL_DISPLAY`; `enabled=false` payload is silent. |
| Provider-neutral, not host- or vendor-specific | All vendor names appear only as configurable candidate lists. |
| Documentation explains generic configuration | Configuration table below. |
| Visual evidence stored outside active worktrees | `visual_lane_evidence_dir` defaults to `$HOME/orch-visual-evidence`; the report flags `evidence_dir_in_worktree=true` when the configured path resolves under `$PWD`. |
| Tests cover GUI-available and GUI-unavailable hosts | `tests/test_visual_lane.bats`. |

## Quick start

```bash
# Opt in for a session — set the display value the operator runs.
export ORCH_VISUAL_DISPLAY=":20"
export ORCH_VISUAL_XAUTHORITY="$HOME/.Xauthority"

# Inspect what the lane sees.
scripts/visual_lane_probe.sh --text
scripts/visual_lane_probe.sh --json | jq '.summary'

# Hard-fail if the operator forgot to enable the lane.
scripts/visual_lane_probe.sh --require-enabled
```

When `ORCH_VISUAL_DISPLAY` is unset, the probe is a silent no-op: it exits
0 and prints an `enabled=false` payload. Hosts without a desktop pay zero
overhead.

## Configuration

| Variable | Required | Default | Purpose |
| --- | --- | --- | --- |
| `ORCH_VISUAL_DISPLAY` | yes (to enable) | — | Opt-in switch. The display value (`:20` on X, equivalent identifiers on other windowing systems). Empty/unset disables the lane. |
| `ORCH_VISUAL_XAUTHORITY` | no | — | Path to the X authority cookie when X requires it. |
| `ORCH_VISUAL_DISPLAY_PROBE` | no | `xdpyinfo` | Binary used to actively confirm the display is reachable. Operators on Wayland or other windowing systems point this at the equivalent (`wlr-randr`, `swaymsg`, etc.). When the named binary is absent, `display_probe=unknown` is reported instead of guessing readiness. |
| `ORCH_VISUAL_BROWSER` | no | auto-detect | Explicit browser command. Skips the candidate probe. |
| `ORCH_VISUAL_BROWSER_CANDIDATES` | no | `chromium chromium-browser google-chrome google-chrome-stable firefox firefox-esr` | Probe order when no explicit browser is set. |
| `ORCH_VISUAL_AUTOMATION` | no | auto-detect | Explicit automation command. |
| `ORCH_VISUAL_AUTOMATION_CANDIDATES` | no | `playwright cypress puppeteer webdriver-manager` | Probe order when no explicit tool is set. `npx playwright` is also tried automatically when `npx` is on `PATH`. |
| `ORCH_VISUAL_DESIGN_MCP_HINT` | no | — | Free-form string the lane echoes back so the dispatch brief can record which design MCP is wired in (`claude.ai Figma`, `internal-figma-mcp`, etc.). The lane does not introspect MCP processes. |
| `ORCH_VISUAL_EVIDENCE_DIR` | no | `$HOME/orch-visual-evidence` | Where screenshots/videos are stored. Must be **outside** active worktrees. |
| `ORCH_VISUAL_VIEWPORTS` | no | `desktop:1280x800,mobile:390x844` | Comma-separated `name:WIDTHxHEIGHT` list the brief is expected to capture. |
| `ORCH_VISUAL_FALLBACK` | no | `skip` | What dispatch briefs should do when the lane is enabled but not ready (`skip`, `headless`). |
| `ORCH_VISUAL_HOST_EVIDENCE` | no | — | Optional path to an audit file documenting the host's visual capability — surfaced under `audit.host_evidence` in the JSON so PR bodies can link it. |
| `ORCH_VISUAL_PROBE_TIMEOUT_SEC` | no | `3` | Per-probe timeout. The probe is safe to call from preflights. |

## Lifecycle

1. **Profile-level enablement.** A project profile that needs a visual
   lane sources an opt-in fragment (see
   `examples/visual-lane.example.sh`) which sets `ORCH_VISUAL_DISPLAY`
   and any operator-specific overrides. Profiles that don't need a
   visual lane leave the variable unset and the lane stays silent.

2. **Dispatch-time probe.** The dispatcher (or an operator preflight)
   runs `scripts/visual_lane_probe.sh --json` and inspects `summary`:
   - `display_ready=true` and `browser_ready=true` and
     `automation_ready=true` ⇒ include full visual verification
     instructions in the brief.
   - `enabled=false` ⇒ omit visual verification instructions
     entirely (silent no-op).
   - `enabled=true` but any `*_ready=false` ⇒ apply
     `ORCH_VISUAL_FALLBACK` (skip or headless) and surface the gap
     in the brief so the agent does not silently drop coverage.

3. **Evidence collection.** Captures land in the `evidence_dir`. The
   report flags `evidence_dir_in_worktree=true` when the configured
   path resolves under the current `$PWD`, which preempts the common
   accident of committing screenshots into a feature branch.

4. **PR-time linkage.** The dispatch brief embeds
   `audit.host_evidence` (when set) so reviewers can trace which host
   capability the run relied on, without trusting the agent's account
   of it.

## JSON schema

```json
{
  "lane": "visual",
  "enabled": true,
  "summary": {
    "display_ready": true,
    "browser_ready": true,
    "automation_ready": true,
    "design_mcp_hint": "claude.ai Figma",
    "evidence_dir_ready": true
  },
  "details": {
    "display": ":20",
    "display_probe": "true",
    "display_detail": "display=:20",
    "xauthority": "/home/rbok/.Xauthority",
    "browser": "name=google-chrome path=/usr/bin/google-chrome version=Google Chrome 145.0.7632.116",
    "automation": "name=npx-playwright version=Version 1.59.1",
    "evidence_dir": "/root/orch-visual-evidence",
    "evidence_dir_in_worktree": false,
    "viewports": ["desktop:1280x800", "mobile:390x844"]
  },
  "fallback": "skip",
  "audit": {
    "host_evidence": "/root/.../audit/visual/visual-host-capability-latest.md",
    "schema_version": 1
  }
}
```

When `enabled=false`, only the top-level keys (`lane`, `enabled`,
`summary`, `details`, `fallback`, `audit`) are present and `summary`
and `details` are empty objects. Consumers should branch on `enabled`
before reading `summary` or `details`.

## Fallback semantics

`ORCH_VISUAL_FALLBACK` controls what dispatch briefs say when the lane
is enabled but a probe is not ready:

- `skip` (default) — the brief asks the agent to mark the visual step
  as `SKIPPED` with the unreadiness reason. Audit evidence remains
  intact; reviewers see the gap.
- `headless` — the brief instructs the agent to fall back to a
  headless run that does not depend on `$DISPLAY` (Playwright headless,
  CI-style screenshot diffs). This trades visual fidelity for keeping
  the verification step green.

Operators who run hosts without GUIs simply leave `ORCH_VISUAL_DISPLAY`
unset; the lane is silent and no fallback is consulted.

## RBOK authenticated `/client/*` fixture

Playwright visual proof for authenticated RBOK `/client/*` routes needs a
test account, an active session, and seeded backend state. The visual
lane treats those inputs as **operator-scoped fixtures**: the dispatch
brief tells the agent *which* variables to read, the operator's project
profile is the only place those variables are actually set, and no
credential value is ever committed to this repository.

### Operator-scoped variables

| Variable | Required | Purpose |
| --- | --- | --- |
| `ORCH_RBOK_AUTH_BASE_URL` | yes | Origin of the RBOK environment the agent should drive (`https://dev.rbok.example`, never production). |
| `ORCH_RBOK_AUTH_EMAIL` | yes | Email of the seeded test account. |
| `ORCH_RBOK_AUTH_PASSWORD_FILE` | yes | Path to a `0600`-mode file holding the test account password. The brief reads the file at runtime; the literal password never appears in env, logs, or evidence. |
| `ORCH_RBOK_AUTH_STORAGE_STATE` | no | Optional path to a Playwright `storageState.json` produced by a prior login. When set, the agent skips the interactive login step. |
| `ORCH_RBOK_AUTH_SEED_SCRIPT` | no | Optional path to an operator-provided script that seeds backend state (fixtures, demo client records) before the visual run. |
| `ORCH_RBOK_AUTH_CLIENT_ID` | no | Identifier of the seeded client used to compose `/client/<id>/...` URLs when the test account owns multiple clients. |

All six variables live in the operator's project profile, never in
`examples/`, `lib/`, or `scripts/` — the visual-lane diff guard
described later in this document keeps them out of those surfaces by
default. Docs may reference the variable names in prose (as above)
because the guard's anchored patterns only match line-leading
assignments.

### Authenticated Playwright run

When the visual lane reports `enabled=true` and `automation_ready=true`,
and `ORCH_RBOK_AUTH_BASE_URL`, `ORCH_RBOK_AUTH_EMAIL`, and
`ORCH_RBOK_AUTH_PASSWORD_FILE` are all set, the dispatch brief instructs
the agent to:

1. Resolve the password at runtime by reading
   `"$ORCH_RBOK_AUTH_PASSWORD_FILE"` into a local variable; never echo
   it, never write it to evidence files.
2. Reuse `ORCH_RBOK_AUTH_STORAGE_STATE` when present; otherwise perform
   a Playwright login against `$ORCH_RBOK_AUTH_BASE_URL/login` with the
   test account and persist the resulting storage state to
   `"$ORCH_VISUAL_EVIDENCE_DIR/storage-state.json"` (already outside the
   worktree by the lane's own contract).
3. Run `"$ORCH_RBOK_AUTH_SEED_SCRIPT"` if set so the backend holds the
   expected records before screenshots are taken.
4. Navigate to the `/client/*` route under test for each viewport
   declared by `ORCH_VISUAL_VIEWPORTS`, capture screenshots into
   `$ORCH_VISUAL_EVIDENCE_DIR`, and reference them in the PR body.

When any required variable is missing, the brief applies
`ORCH_VISUAL_FALLBACK`: `skip` records the gap with the unset variable
name, `headless` runs the same flow without `$DISPLAY` so reviewers
still see a render even if visual fidelity is reduced.

### No-hard-coded-secrets contract

- No `ORCH_RBOK_AUTH_*` value is checked in. The repository carries
  only the variable *names* in this document.
- Password and session material are loaded from operator-controlled
  file paths so rotation lives in the operator profile, not in code.
- Evidence files land in `$ORCH_VISUAL_EVIDENCE_DIR`, which the lane
  already requires to live outside the active worktree, so storage
  state and cookies cannot leak into a feature branch.
- Agents do not modify product routes to enable verification: every
  authenticated request goes through the same `/login` and `/client/*`
  surface real users hit.

## Testing

`tests/test_visual_lane.bats` covers:

- Disabled-by-default behavior (no environment, no display).
- Display readiness with a mocked `xdpyinfo` reporting success.
- Display unreadiness when the probe fails or the binary is missing.
- Browser auto-detection from a candidate list.
- Automation auto-detection (including `npx playwright`).
- Evidence directory location signalling (in-worktree vs out).
- `--require-enabled` exit codes.

Run them with `bats tests/test_visual_lane.bats`.

## Non-goals

- The lane does not run the verification itself — it reports whether
  the host can. The dispatcher and the agent compose the actual
  verification (Playwright script, manual screenshot, etc.).
- The lane does not introspect MCP processes. `ORCH_VISUAL_DESIGN_MCP_HINT`
  is a free-form string operators set to document which design MCP
  they wired into the agent harness.
- The lane does not write to a profile or persist state. Each call
  is a fresh probe.
# Visual Verification Lane
The orchestrator-injected visual-verification lane is **opt-in by design**.
Visual-lane environment variables — `DISPLAY`, `XAUTHORITY`, and anything
prefixed by the ORDO visual namespace — are operator-scoped: they MUST live
in the operator's project profile only, never in shared examples, libs,
scripts, templates, docs, or canonical configs, so headless agents stay
headless by default.
PR #319 (`tests/docs_layers_optionality.bats`) enforces this at the
bats-suite level. Issue #324 noted that a doc/template/script PR could
introduce a leak and only discover it late in full CI; this document
describes the cheap diff-level guard that catches such leaks in seconds.
## Pattern set
The guard flags any of:
| Pattern | Anchor | Example match |
|---|---|---|
| `ORCH_VISUAL_*` (visual env namespace prefix) | unanchored | `export ORCH_VISUAL_DISPLAY=:99` |
| `^DISPLAY=` | line start | `DISPLAY=:0` |
| `^XAUTHORITY=` | line start | `XAUTHORITY=/tmp/xauth` |
The two `^...=` patterns deliberately match line-leading **assignments**,
not arbitrary mentions, so a doc paragraph that explains the variable name
does not self-trigger.
## Default search surface
The guard scans the same three repo-relative directories that PR #319's
bats already locks down, so the diff-level pre-pass and the full-suite
gate stay semantically aligned:
- `examples/`
- `lib/`
- `scripts/`
`tests/` is **intentionally excluded** so bats fixtures may set or
reference the patterns when exercising the guard itself. Other surfaces
(`templates/`, `docs/`, `config/`, `profiles/`, …) are left out of the
default scan because they either ship informational content
(`docs/`, `templates/` agent prompts) or live outside this toolkit
(operator profiles). Override the search set with `--paths <prefix>...`
when running locally if you want to broaden coverage on a specific
audit.
## Operator workflow
### Fast diff-level pre-pass
Run before pushing to catch a leak in the files this branch actually
introduces:
bash scripts/visual_lane_probe.sh --diff
# or pin a base explicitly:
bash scripts/visual_lane_probe.sh --diff origin/main
Diff mode resolves the base in this order: `origin/main` → `main` →
`HEAD~1`. Both committed (`git diff <base>...HEAD`) and staged
(`git diff --cached`) changes are included so a pre-commit hook sees
the same surface the upcoming commit will publish. Untracked files are
NOT scanned in `--diff` mode — stage them with `git add` first or use
`--full`.
### Full scan (CI / occasional sanity)
bash scripts/visual_lane_probe.sh --full
Equivalent to PR #319's bats case 1, but standalone — runs in ~50 ms
without spinning up bats.
### Test-only override
bash scripts/visual_lane_probe.sh --full --paths profiles examples
bash scripts/visual_lane_probe.sh --full --root /tmp/synthetic-repo
Used by `tests/visual_lane_diff_guard.bats` and by operators who want to
probe a non-default surface (e.g. `profiles/` during a portfolio audit).
## Exit codes
| Code | Meaning |
|---|---|
| `0` | Clean — no visual-lane leak in scope. |
| `$VISUAL_LANE_LEAK_EXIT_CODE` (default `81`) | Leak detected — guard prints `<file>:<line>:<text>\tpattern=<regex>` for each offender on stdout, then writes `visual_lane_probe: leak detected` to stderr. |
| `2` | Usage error (unknown flag) or unresolvable diff base. |
The exit code is configurable via the `VISUAL_LANE_LEAK_EXIT_CODE`
environment variable so dashboards can group it with other gate
refusals if the default collides with another signal in a given fleet.
## Remediation when the guard fires
1. **Move the assignment to the operator's project profile.** Project
   profiles live outside the toolkit tree (typically under
   `/root/rbokproject-fleet-*/profiles/`) and are sourced explicitly by
   the operator before launching agents.
2. **Replace direct env exports with conditional opt-in.** A shared lib
   should *read* the visual env vars (`if [ -n "${ORCH_VISUAL_DISPLAY:-}" ]`)
   rather than *set* them. Reading does not trigger the guard because
   the patterns require a line-leading assignment or the unanchored
   `ORCH_VISUAL_` prefix used in a setting context.
3. **For docs that need to mention the variable name**, refer to it as
   a quoted string in prose ("`ORCH_VISUAL_DISPLAY` controls …") which
   is fine because the unanchored pattern still matches such mentions.
   If the doc must show an assignment example, prefix the line so it
   is not at the start: `# example: ORCH_VISUAL_DISPLAY=:99` would still
   trip the guard via the unanchored match — keep examples in
   `tests/` fixtures or operator runbooks outside the default search
   surface.
4. **Re-run the guard locally**: `bash scripts/visual_lane_probe.sh --diff`.
## Library API
`lib/visual_lane.sh` exposes the pattern set and scan helpers so other
ORDO tooling (a pre-commit hook, a workflow step, or a future
`run_shellcheck.sh` pre-pass — see issue #324's "Safe remediation
candidate") can reuse the same logic without shelling out to the probe:
| Function | Purpose |
|---|---|
| `visual_lane_leak_patterns` | Emit the three regex patterns, one per line. |
| `visual_lane_default_search_paths` | Emit the six default search prefixes. |
| `visual_lane_scan_paths <root> [<rel-path>...]` | Recursively scan one or more directories under `<root>`. |
| `visual_lane_scan_files <root> <files>...` | Scan an explicit list of repo-relative files (e.g. from `git diff --name-only`). |
| `visual_lane_filter_diff_files [<rel-prefix>...]` | Read newline-separated paths from stdin and echo only those under the visual-lane prefixes. |
The library is self-contained: it does NOT depend on `audit_log.sh` or any
other ORDO lib, so it can run in pre-commit hooks before a project config
is loaded.
## Self-detection avoidance
The unanchored `ORCH_VISUAL_` prefix is assembled at runtime inside
`lib/visual_lane.sh` (via `printf 'ORCH%sVISUAL%s' '_' '_'`) so the file
itself does not contain the literal token that the guard flags. The two
`^...=` patterns are line-anchored and never self-trigger because their
strings are quoted assignments inside shell code, not line-leading
assignments. As a result, the guard returns clean when run against the
toolkit root that contains its own implementation — verified by the
`tests/visual_lane_diff_guard.bats` self-test case.
