# Controlled Operations

Controlled operations are exceptional operator workflows that need temporary
privilege or external platform setup. ORDO treats them as evidence-gated
operations instead of normal dispatch work.

Use `scripts/controlled_operation.sh` to plan, verify, and record the evidence.
The helper does not perform the operation itself.

## Workflow

1. Generate the evidence plan.

   ```bash
   bash scripts/controlled_operation.sh examples/my-project.config.sh plan \
     --type emergency-admin \
     --id emergency-001 \
     --reason "temporary maintenance" \
     --json
   ```

2. Perform the temporary operation through the approved operator path.

3. Remove the temporary branch, workflow, secrets, and cache entries.

4. Verify the evidence file.

   ```bash
   bash scripts/controlled_operation.sh examples/my-project.config.sh verify \
     --evidence-file /tmp/emergency-001-evidence.json \
     --json
   ```

5. Record the operation after verification passes.

   ```bash
   bash scripts/controlled_operation.sh examples/my-project.config.sh record \
     --evidence-file /tmp/emergency-001-evidence.json \
     --json
   ```

Use `--dry-run` with `record` to preview the state write.

## Evidence Schema

Evidence files store references and outcomes only. They must never contain
secret values, tokens, passwords, private keys, or credential material.

```json
{
  "operation": {
    "id": "emergency-001",
    "type": "emergency-admin",
    "reason": "temporary maintenance"
  },
  "approval": {
    "approved_by": "operator-a"
  },
  "temporary_branch": {
    "name": "ops/emergency-001",
    "base": "main",
    "created": true,
    "removed": true
  },
  "workflow": {
    "path": "workflows/controlled-operation.yml",
    "created": true,
    "removed": true
  },
  "secrets": {
    "names": ["TEMP_CONTROLLED_SECRET"],
    "created": true,
    "removed": true
  },
  "run": {
    "id": "123",
    "url": "https://example.invalid/runs/123",
    "conclusion": "success"
  },
  "cache": {
    "key": "controlled-cache-001",
    "purged": true
  },
  "cleanup": {
    "completed": true,
    "branch_deleted": true,
    "workflow_removed": true,
    "secrets_removed": true,
    "cache_purged": true
  }
}
```

Verification fails until every required field is present and cleanup booleans
are true. If the evidence includes prohibited secret-material keys such as
`value`, `password`, `private_key`, `token_value`, or `credential`, verification
fails with exit code `10`.

## State

Recorded operations append compact JSON lines to:

```text
$ORCH_STATE_BASE/<project>/controlled_operations.jsonl
```

Each successful record also writes a `CONTROLLED_OPERATION` audit line for the
project.
