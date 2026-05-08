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
