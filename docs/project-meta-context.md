# Project Meta Context

`project_meta_context.sh` creates a persistent, low-cost project memory from
documentation and root metadata. It is designed for orchestrator handoffs and
multi-session recovery: read the cached summary instead of re-reading the full
documentation every cycle.

## Command

```bash
bash scripts/project_meta_context.sh <project>
bash scripts/project_meta_context.sh <project> --print
bash scripts/project_meta_context.sh <project> --force
bash scripts/project_meta_context.sh <project> --path
```

## Stored Files

The script writes these files under `state_dir` for the project:

- `project_meta_context.md`: compact documentation map and high-signal rules.
- `project_meta_context.sig`: combined signature of indexed doc files.
- `project_meta_context.manifest.tsv`: path, hash, and byte size per file.
- `project_meta_context.json`: machine-readable metadata.

If the signature has not changed, the script logs `DOC_META unchanged` and
returns the cached path. With `--print`, it prints the cached document.

## Inputs

By default the scanner indexes common project docs:

- `AGENTS.md`, `README.md`, `INDEX.md`;
- `docs/`;
- `.github/workflows/`;
- package and requirements metadata.

Projects can override this in config:

```bash
DOC_META_REPO="/path/to/project"
DOC_META_PATHS=(AGENTS.md README.md docs .github/workflows)
```

## Dispatch Use

`brief_agents.sh` injects the cached context path into canonical dispatch
prompts. Agents can read it for global constraints, architecture map, and doc
diff context without burning time on a full documentation pass.
