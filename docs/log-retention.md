# ORDO / Codex Log Retention

ORDO and the Codex TUI write local logs that can grow without an explicit
retention policy. Parent issue [#636] flagged two storm shapes after the
2026-05-11 cleanup:

- `/var/log/orch/*.log` accumulated multi-MB current and rotated files
  and required manual trimming.
- `/root/.codex/logs_2.sqlite` reached ~1.1 GiB with active WAL writes
  and Codex TUI showed `INSERT INTO logs` statements taking 1.1 – 2.0 s.

This document specifies the retention contract enforced by
[`scripts/log_retention.sh`](../scripts/log_retention.sh) and the bounded
warning gate added to
[`scripts/host_health_preflight.sh`](../scripts/host_health_preflight.sh).

## Targets

| Target          | Default path                  | Kind        |
| --------------- | ----------------------------- | ----------- |
| `orch_log_dir`  | `/var/log/orch`               | Directory   |
| `codex_log_dir` | `/root/.codex/log`            | Directory   |
| `codex_sqlite`  | `/root/.codex/logs_2.sqlite`  | SQLite file |

Override at the CLI with `--orch-dir`, `--codex-log-dir`, `--sqlite`, or
globally via `LOG_RETENTION_ORCH_DIR`, `LOG_RETENTION_CODEX_LOG_DIR`,
`LOG_RETENTION_CODEX_SQLITE`. The script never walks outside the paths
it was given.

## Thresholds

| Variable                         | Default | Meaning                                                 |
| -------------------------------- | ------- | ------------------------------------------------------- |
| `LOG_RETENTION_MAX_FILE_MB`      | `50`    | Truncate any single log file larger than this (MiB).    |
| `LOG_RETENTION_KEEP_ROTATIONS`   | `3`     | Keep rotated files `<name>.1` … `<name>.N`; delete the rest. |
| `LOG_RETENTION_MAX_AGE_DAYS`     | `14`    | Delete files whose mtime is older than this.            |
| `LOG_RETENTION_SQLITE_MAX_MB`    | `256`   | Above this, run `PRAGMA wal_checkpoint(TRUNCATE)`.      |
| `LOG_RETENTION_SQLITE_VACUUM_MB` | `512`   | Above this, additionally run `VACUUM`.                  |
| `LOG_RETENTION_DIR_WARN_MB`      | `512`   | Directory size warn threshold (preflight + summary).    |
| `LOG_RETENTION_DIR_MAX_MB`       | `2048`  | Directory size critical threshold.                      |
| `LOG_RETENTION_TIMEOUT_SEC`      | `5`     | Per-external-call timeout for `du`, `stat`, `sqlite3`.  |

All thresholds compare integers in MiB. Non-numeric values fall back to a
defensive default rather than failing the whole pass.

## Modes

`scripts/log_retention.sh` is safe to schedule from cron because the
default mode is `--dry-run`:

```bash
# Report planned actions (default, never mutates).
bash scripts/log_retention.sh

# Same as --dry-run plus per-target summary line for metric collection.
bash scripts/log_retention.sh --report

# Apply the plan: truncate oversize, delete over-keep / aged-out,
# checkpoint or vacuum the Codex SQLite log.
bash scripts/log_retention.sh --apply
```

Each pass emits:

- One `LOG_RETENTION status=<ok|warning|critical> target=<name> path=… size_mb=…`
  line per target (always, regardless of mode).
- `LOG_RETENTION_PLAN action=<truncate|delete|checkpoint|vacuum> target=… reason=…`
  lines for every action the policy would take.
- In `--apply` mode, `LOG_RETENTION_APPLY applied=<action> target=…` lines
  for every action actually executed. `applied=skip` shows when an action
  could not run (e.g. `sqlite3` missing).

## Preflight signal

`scripts/host_health_preflight.sh` adds three retention metrics to its
existing wtmp / journal / var-log / session matrix:

- `orch_log_mb`
- `codex_log_mb`
- `codex_sqlite_mb`

They share the same `warning` / `critical` semantics as the other
host-health metrics and emit the hint
`run_scripts_log_retention_sh_apply` so an operator can move directly
from the preflight line to the remediation command.

The retention block is **opt-in**: set
`HOST_HEALTH_INCLUDE_LOG_RETENTION=1` in the environment (or as part of
the orchestrator's preflight invocation) to enable it. The default of
`0` keeps the preflight contract identical to pre-#747 behavior for
callers that have not subscribed to the new metric.

## Scheduling

The retention script is designed to be called from a small cron entry
or a systemd timer. The recommended cadence is:

- Hourly `--dry-run` from a low-privilege user to feed metrics.
- Daily `--apply` from a user that owns the target paths (typically
  `root` for `/var/log/orch` and the operator account for
  `/root/.codex`).

Example crontab fragment:

```cron
@hourly /usr/bin/env bash /opt/ordo/scripts/log_retention.sh --report \
        >> /var/log/orch/log-retention.dry.log 2>&1
17 4 * * * /usr/bin/env bash /opt/ordo/scripts/log_retention.sh --apply \
        >> /var/log/orch/log-retention.apply.log 2>&1
```

Pipe the daily apply output through your normal log shipper to keep an
audit trail; the format is grep-friendly.

## SQLite policy

`scripts/log_retention.sh --apply` runs at most two SQLite statements,
both inside the configured timeout:

1. `PRAGMA wal_checkpoint(TRUNCATE);` when the database exceeds
   `LOG_RETENTION_SQLITE_MAX_MB`. This reclaims WAL pages without
   exclusive-locking writers for long.
2. `PRAGMA wal_checkpoint(TRUNCATE); VACUUM;` when the database exceeds
   `LOG_RETENTION_SQLITE_VACUUM_MB`. `VACUUM` is heavier and is held back
   until the file itself has materially bloated.

If `sqlite3` is missing the script reports
`applied=skip ... sqlite3-missing` instead of failing the whole pass, so
the operator can decide whether to install it or change targets.

## Verification

After enabling the schedule, the parent verification target from #636
becomes:

```bash
du -sh /var/log/orch /root/.codex/log /root/.codex/logs_2.sqlite*
bash scripts/log_retention.sh --report
bash scripts/host_health_preflight.sh
```

A successful steady state shows directory sizes below
`LOG_RETENTION_DIR_WARN_MB`, the SQLite log below
`LOG_RETENTION_SQLITE_MAX_MB`, and `summary=ok` on the preflight.

[#636]: https://github.com/RBOKproject/ORDO/issues/636
