# Issue 424 - Six Sigma Docs Layer Audit

- Issue: #424, "investigation: audit Six Sigma docs layer wiring through the project doc generator"
- Parent: #257
- Audit date: 2026-05-10
- Base reviewed: `origin/main` at `9def608e2afacf65d28de0507da9450ec164892c`
- Scope: read-only investigation; no generator, template, or test code changed.

## Audit Question

When a downstream project is launched with Six Sigma options, generated
documentation is expected to include DMAIC, CTQ, metric evidence ledger,
control plan, improvement backlog, and future Six Sigma module hooks.

This audit checks whether the current project documentation generator emits
the `templates/docs/sixsigma/*.md.tpl` layer from a project-profile opt-in such
as `PROJECT_SIXSIGMA_LAYER=1`, or an equivalent mechanism.

## Sources Reviewed

| Source | Purpose |
| --- | --- |
| `scripts/docs_generate.sh` | CLI entry point, flag parsing, render loop, manifest output. |
| `lib/docs_generate.sh` | Layer resolution, template discovery, file-plan construction, token rendering. |
| `scripts/sixsigma_autoupgrade.sh` | Six Sigma operational loop entry point and project-config use. |
| `templates/docs/sixsigma/*.md.tpl` | Six Sigma documentation templates that must map to emit paths. |
| `docs/docs-generate.md` | Documented generator behavior and output layout. |
| `docs/architecture/README.md` | Optional-layer architecture contract. |
| `docs/integration.md` | Integration-level optional layer statement. |

## Entry Point Wiring

| Entry point | Consults Six Sigma opt-in? | Observed behavior | Evidence |
| --- | --- | --- | --- |
| `scripts/docs_generate.sh --sixsigma` | Yes, explicit CLI flag only. | Initializes `SIXSIGMA=0`; sets `SIXSIGMA=1` only when `--sixsigma` is parsed. | `scripts/docs_generate.sh:76-90` |
| `scripts/docs_generate.sh` project config load | No docs-layer key observed. | Calls `load_project_config "$CFG_ARG"`, but the generator does not read `PROJECT_SIXSIGMA_LAYER`, `DOCS_GENERATE_SIXSIGMA`, or another project-profile docs-layer variable. | `scripts/docs_generate.sh:70-81` |
| `lib/docs_generate.sh::docs_generate_resolve_layers` | Indirectly, through caller argument. | Appends `sixsigma` only when its second positional argument is `1`; it does not read project config or environment directly. | `lib/docs_generate.sh:85-98` |
| `lib/docs_generate.sh::docs_generate_layer_files` | N/A, layer already selected. | Maps every `templates/docs/sixsigma/*.md.tpl` file to `sixsigma/*.md` when the `sixsigma` layer is in the resolved layer list. | `lib/docs_generate.sh:100-115` |
| `scripts/docs_generate.sh` render loop | N/A, file plan already selected. | Renders every file in `files_json` to `$resolved_output_dir/$rel` and passes `DG_SIXSIGMA_ENABLED="$SIXSIGMA"` to templates. | `scripts/docs_generate.sh:281-303` |
| `scripts/docs_generate.sh` manifest | N/A, records selected state. | Records `layers.sixsigma` and `layers.selected` in `generated.manifest.json`. | `scripts/docs_generate.sh:308-344` |
| `scripts/sixsigma_autoupgrade.sh` | No for docs layer. | Loads project config and consults `SIXSIGMA_*` operational knobs for Level 1 CI/autofix behavior. It does not call `docs_generate.sh`, set the docs generator `SIXSIGMA` flag, or emit documentation templates. | `scripts/sixsigma_autoupgrade.sh:22-38`, `scripts/sixsigma_autoupgrade.sh:78-175` |

## Template Emit Matrix

Expected emit paths are relative to the generator output directory. By
default, that output directory is `<target-dir>/docs/generated`; when
`--output-dir` is supplied, it is the supplied output directory.

| Template | Expected emit path | Generator path that should emit it | Observed status |
| --- | --- | --- | --- |
| `templates/docs/sixsigma/control-plan.md.tpl` | `sixsigma/control-plan.md` | `docs_generate_resolve_layers 0 1` selects `sixsigma`; `docs_generate_layer_files sixsigma` converts the template path to `sixsigma/control-plan.md`; the render loop writes `$resolved_output_dir/sixsigma/control-plan.md`. | Wired for `--sixsigma`; not wired to a project-profile opt-in. |
| `templates/docs/sixsigma/ctq.md.tpl` | `sixsigma/ctq.md` | `docs_generate_resolve_layers 0 1` selects `sixsigma`; `docs_generate_layer_files sixsigma` converts the template path to `sixsigma/ctq.md`; the render loop writes `$resolved_output_dir/sixsigma/ctq.md`. | Wired for `--sixsigma`; not wired to a project-profile opt-in. |
| `templates/docs/sixsigma/dmaic.md.tpl` | `sixsigma/dmaic.md` | `docs_generate_resolve_layers 0 1` selects `sixsigma`; `docs_generate_layer_files sixsigma` converts the template path to `sixsigma/dmaic.md`; the render loop writes `$resolved_output_dir/sixsigma/dmaic.md`. | Wired for `--sixsigma`; not wired to a project-profile opt-in. |
| `templates/docs/sixsigma/improvement-backlog.md.tpl` | `sixsigma/improvement-backlog.md` | `docs_generate_resolve_layers 0 1` selects `sixsigma`; `docs_generate_layer_files sixsigma` converts the template path to `sixsigma/improvement-backlog.md`; the render loop writes `$resolved_output_dir/sixsigma/improvement-backlog.md`. | Wired for `--sixsigma`; not wired to a project-profile opt-in. |
| `templates/docs/sixsigma/metric-evidence-ledger.md.tpl` | `sixsigma/metric-evidence-ledger.md` | `docs_generate_resolve_layers 0 1` selects `sixsigma`; `docs_generate_layer_files sixsigma` converts the template path to `sixsigma/metric-evidence-ledger.md`; the render loop writes `$resolved_output_dir/sixsigma/metric-evidence-ledger.md`. | Wired for `--sixsigma`; not wired to a project-profile opt-in. |

## Gap Table

| Gap | Impact | Evidence | Safe remediation candidate |
| --- | --- | --- | --- |
| The docs generator has no observed project-profile opt-in such as `PROJECT_SIXSIGMA_LAYER=1`. | A downstream project can be configured as Six Sigma-enabled at launch time, but generated docs will omit the Six Sigma layer unless the operator also remembers the CLI-only `--sixsigma` flag. | `scripts/docs_generate.sh` reads environment defaults for intent, context, target, and output only; `SIXSIGMA` changes only from `--sixsigma`. Repository search found no `PROJECT_SIXSIGMA_LAYER` consumer. | Define a project-profile key for the docs layer and have `scripts/docs_generate.sh` initialize `SIXSIGMA=1` from that key, while preserving explicit CLI behavior. |
| `sixsigma_autoupgrade.sh` is operational Level 1 wiring, not docs-layer wiring. | Operators may confuse `SIXSIGMA_*` autoupgrade knobs with the Level 2 documentation layer. Tuning the autoupgrade loop does not cause DMAIC/CTQ docs to be generated. | `scripts/sixsigma_autoupgrade.sh` loads project config and uses `SIXSIGMA_*` knobs for pool snapshots, PR signals, Actions optimization, and CI autofix dispatches; it never calls the docs generator. | Document the boundary in the profile contract, or add a distinct docs-layer key so Level 1 operational knobs cannot be mistaken for generated documentation opt-in. |
| The template-to-file-plan path is generic and currently depends on the layer being selected upstream. | The five templates are discoverable, but there is no profile-level assertion that a Six Sigma-enabled project causes the layer selection upstream. | `docs_generate_layer_files sixsigma` maps all templates correctly once the `sixsigma` layer is selected. The missing piece is before layer resolution, not template discovery. | Add a focused generator test that enables the profile key and asserts all five `sixsigma/*.md` paths plus manifest `layers.sixsigma=true`. |

## Required Follow-up

1. File an implementation issue: `docs_generate.sh` should honor a project
   profile docs-layer opt-in, for example `PROJECT_SIXSIGMA_LAYER=1`, or a
   documented equivalent. Acceptance should cover default-off behavior,
   CLI `--sixsigma`, profile-enabled behavior, and conflict/precedence rules.
2. File a test issue, or include in the implementation issue: add focused
   generator coverage proving that all five `templates/docs/sixsigma/*.md.tpl`
   entries appear in the file plan, rendered output, and manifest when the
   Six Sigma docs layer is enabled through the project profile.
3. File a documentation issue: clarify the boundary between Level 1
   `sixsigma_autoupgrade.sh` operational knobs and the Level 2 generated
   Six Sigma documentation layer, so `SIXSIGMA_*` CI/autofix settings are not
   mistaken for docs-generation opt-in.
