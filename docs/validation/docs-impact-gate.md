# Documentation Impact Gate

This validation note documents the documentation impact gate introduced
under issue #260 as part of the ORDO documentation operating system
(epic #257). The gate makes documentation drift visible and auditable
without imposing hard blocks on changes that have no user-visible
documentation surface.

The gate is implemented as:

- `lib/docs_impact_gate.sh` — pure helpers: path classification,
  declaration parsing, decision matrix, and evidence rendering.
- `scripts/docs_impact_gate.sh` — CLI runner with subcommands
  `classify`, `summarize`, `check`, `declare`, and `render-evidence`.
- `.github/workflows/docs-impact-gate.yml` — pull-request check that
  runs the gate against the diff and the PR body, attaches evidence to
  the run summary, and uploads a `docs-impact-gate-evidence` artifact.
- `tests/test_docs_impact_gate.sh` — fixture coverage for
  classification, declaration parsing, the decision matrix, the CLI
  surface, and pattern overrides.

## Scope and ownership

- Owns the documentation impact policy, the gate runner, the helper
  library, the PR/CI check, and this validation note.
- Does not own unrelated CI workflows, the test runner harness logic
  beyond test registration, or the broader CSV dossier.
- Reuses the existing `findings_ledger` and `opportunity_registry`
  evidence shape: the gate emits markdown that can be appended to a
  ledger or attached to a PR comment.

## Path classification

`docs_gate_classify_path` matches a repo-relative path against the
configured `DOCS_GATE_*_PATTERN` extended regular expressions. The first
matching pattern wins. The default categories are:

| Category       | Default pattern (anchored at start of path)                           |
| -------------- | --------------------------------------------------------------------- |
| `docs`         | `^(docs/\|README\.md$\|PRODUCT\.md$\|CHANGELOG\.md$)`                 |
| `installation` | `^(install\.sh\|scripts/repository_bootstrap\.sh)$`                   |
| `onboarding`   | `^(scripts/(guided_onboarding\|onboarding_verification\|fleet_provisioning\|fleet_sizing\|host_assessment\|project_meta_context\|project_scaffold)\.sh\|lib/(host_assessment\|fleet_sizing\|fleet_provisioning)\.sh)$` |
| `dispatch`     | `^scripts/(dispatch_\|preempt_\|brief_\|integrate_wave\|orch_\|cycle).*\.sh$` |
| `integration`  | `^(scripts/(pr_merge\|post_merge_cleanup\|check_ci_health\|ci_autofix\|gh_actions_optimize\|pr_block_signals\|pr_merge_wave)\|lib/(pr_merge\|governance_check))\.sh$` |
| `profile`      | `^(profiles/\|examples/projects/\|examples/.*\.config\.sh$)`          |
| `workflow`     | `^\.github/(workflows\|ISSUE_TEMPLATE\|PULL_REQUEST_TEMPLATE)/`       |
| `cli`          | `^scripts/.*\.sh$` (catch-all for remaining script entry points)      |
| `lib`          | `^lib/.*\.sh$` (catch-all for shared helpers)                         |
| `tests`        | `^tests/`                                                             |
| `internal`     | anything else — the gate never blocks on internal-only changes        |

The categories that are reported as "user-visible surfaces"
(`installation`, `onboarding`, `dispatch`, `integration`, `profile`,
`workflow`, `cli`, `lib`) are the categories that require a
documentation impact declaration. `docs`, `tests`, and `internal` paths
never escalate the gate on their own.

Downstream projects can override any pattern by exporting
`DOCS_GATE_*_PATTERN` before invoking the gate. The library is pure and
side-effect free: sourcing `lib/docs_impact_gate.sh` does not touch the
filesystem or the network.

## Declaration model

The gate accepts free-form declaration text on stdin or via
`--declaration-from <file>`. Recognized trailers (case-insensitive on
the trailer name) are parsed and normalized:

```
Docs-Impact: <outcome>
Docs-Impact-Note: <free-form rationale>
Docs-Impact-Followup: <issue ref, e.g. #1234 or org/repo#1234>
```

Trailers may appear anywhere in the input. The PR workflow concatenates
the pull-request body with every commit message in the PR range so a
trailer placed in any commit is honored. Only the first occurrence of
each trailer wins; conflicting trailers across commits should be
resolved by the contributor.

## Decision matrix

`docs_gate_decide` returns one of `pass`, `warn`, or `block`. The
runner exits 0 for `pass` and `warn`, exits 1 for `block`, and supports
a `--soft` flag that downgrades a `block` to an advisory exit 0 (used
during initial rollout). The full matrix is:

| Surface touched | Docs touched | Declaration                              | Decision |
| --------------- | ------------ | ---------------------------------------- | -------- |
| no              | any          | any (or none)                            | `pass`   |
| yes             | yes          | none                                     | `warn`   |
| yes             | yes          | `outcome=docs-updated`                   | `pass`   |
| yes             | no           | `outcome=docs-updated`                   | `warn`   |
| yes             | any          | `outcome=no-docs-needed` + `note`        | `pass`   |
| yes             | any          | `outcome=no-docs-needed` without `note`  | `block`  |
| yes             | any          | `outcome=follow-up` + `followup`         | `pass`   |
| yes             | any          | `outcome=follow-up` without `followup`   | `block`  |
| yes             | any          | `outcome=blocked`                        | `block`  |
| yes             | any          | `outcome=<unknown>`                      | `block`  |
| yes             | no           | none                                     | `block`  |

The matrix is encoded in the test fixture in
`tests/test_docs_impact_gate.sh`; that test is the controlling
acceptance evidence for this gate.

## Evidence and audit trail

Every `check` invocation writes a markdown evidence block. The block
contains:

- the gate decision and reason;
- a UTC timestamp;
- a category-count summary table;
- the parsed declaration (or `_(no declaration supplied)_`);
- a per-path classification table when paths were supplied.

In CI the evidence is appended to the GitHub Actions run summary and
uploaded as the `docs-impact-gate-evidence` artifact. Locally the
evidence can be redirected with `--evidence-out <file>` and folded into
a `findings_ledger` entry to keep the auditable trail consistent with
the existing ORDO findings/opportunity flow.

## Local usage

```bash
# Classify the working tree's pending changes against origin/main.
git diff --name-only origin/main...HEAD \
  | bash scripts/docs_impact_gate.sh check \
      --declaration-from <(git log --format=%B origin/main..HEAD)

# Generate a declaration trailer for inclusion in a commit message.
bash scripts/docs_impact_gate.sh declare \
  --outcome no-docs-needed \
  --note "internal helper rename, no surface change"

# Render evidence for a custom paths file.
bash scripts/docs_impact_gate.sh render-evidence \
  --paths-from .docs-gate/paths.txt \
  --declaration-from .docs-gate/declaration.txt
```

## Optional GxP and Six Sigma layers (epic #257)

The gate intentionally stays neutral for normal-dev usage. To support
the GxP-grade and Six Sigma layers from epic #257 without leaking
into normal-dev:

- A GxP-grade deployment can extend `DOCS_GATE_DOCS_PATTERN` to include
  controlled-document directories (for example
  `^(docs/(validation\|controlled)/)`) so validation evidence updates
  count as documentation changes. The gate does not require GxP
  controls when those overrides are absent.
- A Six Sigma deployment can register additional surface categories by
  layering its own pattern overrides; classifications and decision
  outputs remain backward compatible because new categories simply
  raise the decision from internal-only to surface-touched.
- Neither layer is enabled by default. Normal-dev projects continue to
  use the defaults documented above and never see GxP or Six Sigma
  declaration requirements unless they explicitly opt in by setting
  the appropriate environment variables in their CI configuration.

## Validation status

This note is a working validation reference for the documentation
impact gate. It does not modify the CSV dossier disposition recorded in
`docs/validation/README.md`, which remains
`FINAL VALIDATION RELEASE REFUSED` and `NOT PRODUCTION READY`. The gate
is a development-time control; deployments that rely on it as part of
their own validated state must record that decision in their own
dossier.

Acceptance evidence:

- Decision matrix coverage: `tests/test_docs_impact_gate.sh`.
- CLI surface coverage: same test file (classify, summarize, declare,
  check, render-evidence, --soft, env-var overrides).
- CI integration: `.github/workflows/docs-impact-gate.yml`.

Reproduction:

```bash
timeout 60 bash tests/test_docs_impact_gate.sh
```

The expected output is a single `ok - ...` line and exit status 0.
