# ORDO Project Scaffold

`scripts/project_scaffold.sh` turns a product intent into a neutral minimum
project baseline. It is designed for onboarding before agent orchestration
starts.

The scaffold is universal. It does not choose a framework, runtime, hosting
target, repository platform, CI provider, account, host, terminal session,
terminal pane, local machine path, vendor, or secret store. Those decisions
belong in deployment-specific configuration and engineering records.

## Relationship to Repository Readiness

The scaffold does not create repositories and does not validate repository
identity or permissions itself.

Use the existing contracts first:

- Existing repository: `scripts/repository_platform_readiness.sh <project> --json`
- Greenfield repository: `scripts/repository_bootstrap.sh <project> --apply --json`

Pass the resulting ready report to the scaffold with `--readiness-report`.
Without a ready report, `project_scaffold.sh --apply` refuses to write.

## Safe Preview

Preview is the default:

```bash
bash scripts/project_scaffold.sh <project> \
  --intent "Describe the product outcome in business terms" \
  --target-dir <target-directory> \
  --repo-mode existing \
  --json
```

The report includes:

- selected archetype;
- selection reason;
- assumptions made by the scaffold;
- product and engineering decisions still required;
- repository readiness contract required for the selected path;
- files that would be created.

## Apply

Writes require explicit `--apply` and a ready repository report:

```bash
bash scripts/project_scaffold.sh <project> \
  --intent "Describe the product outcome in business terms" \
  --target-dir <target-directory> \
  --repo-mode existing \
  --readiness-report <ready-report.json> \
  --apply \
  --json
```

`--dry-run` or `ORCH_DRY_RUN=1` keeps the command non-mutating even when
`--apply` is present.

Apply refuses when:

- product intent is missing;
- target directory is missing, not a directory, or already contains unmanaged
  content;
- generated scaffold files already exist and `--overwrite` is not supplied;
- repository mode is missing or invalid;
- readiness report is missing, unreadable, or not ready.

## Archetypes

The selector supports:

- `generic`
- `service`
- `web-interface`
- `worker`
- `library`
- `data-workflow`
- `documentation`

Use `--archetype auto` to infer from product intent or specify one explicitly.
An archetype is only a scaffold shape. It is not a framework or runtime
decision.

## Generated Baseline

The minimum scaffold includes:

- `README.md`
- `.gitignore`
- `.env.example`
- `config/project.config.example.sh`
- `ci/validate.sh`
- `docs/architecture.md`
- `docs/bootstrap-summary.md`
- `docs/decisions/0001-project-archetype.md`
- `docs/operator-runbook.md`
- `docs/requirements.md`

The validation stub only verifies the scaffold baseline exists. Replace it
with approved project checks before treating CI as implementation evidence.
