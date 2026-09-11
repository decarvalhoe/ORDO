#!/usr/bin/env bash
# lib/ordo_journal.sh — SQLite event journal and projections (#808, epic #806).
#
# Append-only journal of contract `event` objects with a gapless, monotonic
# `run_seq` per run, plus deterministic projections (snapshots) folded from
# those events, a compatibility export that writes the legacy state files
# (`assignments.json`) through lib/state_persist.sh, and thin lease/approval
# CRUD consumed by the scheduler (#810) and approval (#812) modules.
#
# Storage: `$(state_dir)/ordo-journal.sqlite` (override: ORDO_JOURNAL_DB).
# All SQLite access goes through python3's stdlib `sqlite3` module (the
# `sqlite3` CLI is not available locally nor in CI); the Python program is
# embedded below in ORDO_JOURNAL_PY and fed to `python3 -` on stdin.
#
# Public API (fixed by .work/agentic-control-plane-BRIEF.md):
#   ordo_journal_init                                   # create/migrate schema (idempotent)
#   ordo_journal_append <run_id> <type> <payload_json> [--idempotency-key K] [--actor JSON]
#                       [--mutation] [--correlation-id C] [--metadata JSON]
#                                                       # prints the event; duplicate key => exit 5 duplicate_event
#   ordo_journal_events <run_id> [--since RUN_SEQ]      # JSON lines, run_seq ascending
#   ordo_journal_project <run_id>                       # pure fold -> snapshot JSON (also refreshes projections row)
#   ordo_journal_rebuild_all                            # rebuild every projection
#   ordo_journal_state <run_id>                         # print state string (exit 4 if unknown)
#   ordo_journal_compat_export <run_id>                 # write legacy state files via state_persist/state_update
#   ordo_journal_lease_acquire <run_id> <owner> [--ttl S] [--task-id T] [--actor JSON]
#   ordo_journal_lease_renew <lease_id> [--ttl S] [--actor JSON]
#   ordo_journal_lease_release <lease_id> [--actor JSON]
#   ordo_journal_lease_expire_stale [--actor JSON]      # active/renewed leases past expires_at -> expired (+ lease.expired event)
#   ordo_journal_lease_get <lease_id> | ordo_journal_lease_list <run_id>
#   ordo_journal_approval_create <run_id> <action> <principal> --policy-version V --idempotency-key K
#                       [--ttl S | --expires-at TS] [--actor JSON]
#   ordo_journal_approval_get <approval_id> | ordo_journal_approval_list <run_id>
#   ordo_journal_approval_set_state <approval_id> <state> [--reason R] [--decided-by JSON] [--result JSON] [--actor JSON]
# Supporting helpers:
#   ordo_journal_db_path                                # print the DB path
#   ordo_journal_check                                  # integrity_check + counts (recovery aid)
#   ordo_journal_now                                    # RFC3339 UTC, honours ORDO_JOURNAL_NOW (tests)
#
# Errors: ONE JSON line on stderr {"error":{"code","message","module":"journal","details"}}
# and the exit code mapped by lib/ordo_contracts.sh (2 usage, 4 not_found,
# 5 duplicate/invalid/conflict, 6 missing_dependency, 8 lease_lost/lease_stale).
#
# Test hooks: ORDO_JOURNAL_FAULT=before_commit (raise) | kill_before_commit
# (SIGKILL) fires inside every write transaction right before COMMIT;
# ORDO_JOURNAL_NOW pins the clock; ORDO_JOURNAL_PYTHON_BIN overrides python3.
#
# Requires lib/audit_log.sh (state_dir) and lib/state_persist.sh to be sourced
# first, like every other ORDO library; they are sourced lazily when missing.

ORDO_JOURNAL_MODULE="journal"
: "${ORDO_JOURNAL_BUSY_TIMEOUT_MS:=5000}"
: "${ORDO_JOURNAL_DEFAULT_LEASE_TTL:=300}"
: "${ORDO_JOURNAL_DEFAULT_APPROVAL_TTL:=86400}"
: "${ORDO_JOURNAL_FAULT:=}"
: "${ORDO_JOURNAL_NOW:=}"

_ORDO_JOURNAL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F ordo_contracts_validate >/dev/null 2>&1; then
  # shellcheck source=lib/ordo_contracts.sh
  source "$_ORDO_JOURNAL_LIB_DIR/ordo_contracts.sh"
fi

# ---------------------------------------------------------------------------
# Embedded Python program (stdlib only). Invoked as:
#   python3 - <command> <args-json>   (program on stdin)
# Results go to stdout as one JSON document (or JSON lines for `events`);
# failures go to stderr as {"error":{...}} and exit 1 — the bash wrapper maps
# the code to the contract exit status.
# ---------------------------------------------------------------------------
IFS= read -r -d '' ORDO_JOURNAL_PY <<'PY' || true
import datetime
import json
import os
import signal
import sqlite3
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")
DB = os.environ["ORDO_JOURNAL_DB"]
BUSY_MS = int(os.environ.get("ORDO_JOURNAL_BUSY_TIMEOUT_MS", "5000") or "5000")
FAULT = os.environ.get("ORDO_JOURNAL_FAULT", "")
SCHEMA_VERSION = 1
LIVE_LEASE_STATES = ("active", "renewed")
TS_FMT = "%Y-%m-%dT%H:%M:%SZ"


class JournalError(Exception):
    def __init__(self, code, message, details=None, stdout=None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or {}
        self.stdout = stdout


def fail(code, message, details=None, stdout=None):
    raise JournalError(code, message, details, stdout)


def dumps(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def emit(obj):
    sys.stdout.write(dumps(obj) + "\n")


def now_iso():
    pinned = os.environ.get("ORDO_JOURNAL_NOW", "")
    if pinned:
        return pinned
    return datetime.datetime.now(datetime.timezone.utc).strftime(TS_FMT)


def parse_ts(value):
    base = value.split(".")[0].rstrip("Z") + "Z" if "." in value else value
    return datetime.datetime.strptime(base, TS_FMT).replace(tzinfo=datetime.timezone.utc)


def plus_seconds(value, seconds):
    return (parse_ts(value) + datetime.timedelta(seconds=int(seconds))).strftime(TS_FMT)


def connect():
    conn = sqlite3.connect(DB, timeout=BUSY_MS / 1000.0, isolation_level=None)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=%d" % BUSY_MS)
    conn.execute("PRAGMA synchronous=FULL")
    return conn


def begin(conn):
    conn.execute("BEGIN IMMEDIATE")


def commit(conn):
    # Fault-injection point used by the crash-safety tests: everything
    # written in the open transaction must be rolled back / discarded.
    if FAULT == "before_commit":
        raise RuntimeError("fault injected: before_commit")
    if FAULT == "kill_before_commit":
        os.kill(os.getpid(), signal.SIGKILL)
    conn.execute("COMMIT")


def rollback(conn):
    try:
        conn.execute("ROLLBACK")
    except sqlite3.Error:
        pass


MIGRATIONS = [
    (1, [
        """CREATE TABLE IF NOT EXISTS schema_migrations (
             version INTEGER PRIMARY KEY,
             applied_at TEXT NOT NULL)""",
        """CREATE TABLE IF NOT EXISTS events (
             seq INTEGER PRIMARY KEY AUTOINCREMENT,
             event_id TEXT NOT NULL UNIQUE,
             run_id TEXT NOT NULL,
             run_seq INTEGER NOT NULL,
             ts TEXT NOT NULL,
             kind TEXT NOT NULL DEFAULT 'event',
             type TEXT NOT NULL,
             actor_json TEXT NOT NULL,
             payload_json TEXT NOT NULL,
             mutation INTEGER NOT NULL DEFAULT 0,
             idempotency_key TEXT UNIQUE,
             correlation_id TEXT NOT NULL,
             event_json TEXT NOT NULL,
             UNIQUE(run_id, run_seq))""",
        "CREATE INDEX IF NOT EXISTS events_run_idx ON events(run_id, run_seq)",
        """CREATE TABLE IF NOT EXISTS projections (
             run_id TEXT PRIMARY KEY,
             state TEXT NOT NULL,
             updated_at TEXT NOT NULL,
             last_seq INTEGER NOT NULL,
             snapshot_json TEXT NOT NULL)""",
        """CREATE TABLE IF NOT EXISTS leases (
             lease_id TEXT PRIMARY KEY,
             run_id TEXT NOT NULL,
             owner TEXT NOT NULL,
             state TEXT NOT NULL,
             expires_at TEXT NOT NULL,
             heartbeat_at TEXT NOT NULL,
             generation INTEGER NOT NULL DEFAULT 0,
             lease_json TEXT NOT NULL)""",
        "CREATE INDEX IF NOT EXISTS leases_run_idx ON leases(run_id, state)",
        """CREATE TABLE IF NOT EXISTS approvals (
             approval_id TEXT PRIMARY KEY,
             run_id TEXT NOT NULL,
             action TEXT NOT NULL,
             principal TEXT NOT NULL,
             policy_version TEXT NOT NULL,
             state TEXT NOT NULL,
             expires_at TEXT,
             idempotency_key TEXT NOT NULL UNIQUE,
             result_json TEXT,
             approval_json TEXT NOT NULL)""",
        "CREATE INDEX IF NOT EXISTS approvals_run_idx ON approvals(run_id, state)",
    ]),
]


def migrate(conn):
    version = conn.execute("PRAGMA user_version").fetchone()[0]
    if version >= SCHEMA_VERSION:
        return
    for attempt in range(20):
        try:
            conn.execute("PRAGMA journal_mode=WAL")
            break
        except sqlite3.OperationalError:
            time.sleep(0.05 * (attempt + 1))
    begin(conn)
    version = conn.execute("PRAGMA user_version").fetchone()[0]
    for target, statements in MIGRATIONS:
        if target <= version:
            continue
        for statement in statements:
            conn.execute(statement)
        conn.execute("INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES (?, ?)",
                     (target, now_iso()))
    conn.execute("PRAGMA user_version=%d" % SCHEMA_VERSION)
    conn.execute("COMMIT")


def open_db():
    conn = connect()
    migrate(conn)
    return conn


# --- events -----------------------------------------------------------------

def insert_event(conn, event):
    """Insert one validated event inside the caller's transaction. Assigns
    run_seq = MAX(run_seq)+1 for the run (gapless under BEGIN IMMEDIATE)."""
    run_id = event["run_id"]
    key = event.get("idempotency_key")
    if key:
        existing = conn.execute("SELECT event_json FROM events WHERE idempotency_key = ?", (key,)).fetchone()
        if existing:
            existing_event = json.loads(existing["event_json"])
            fail("duplicate_event", "an event with idempotency_key %r already exists" % key,
                 {"idempotency_key": key, "run_id": run_id,
                  "existing_event_id": existing_event.get("id"),
                  "existing_run_seq": existing_event.get("run_seq")},
                 stdout=existing["event_json"])
    row = conn.execute("SELECT COALESCE(MAX(run_seq), 0) + 1 AS next FROM events WHERE run_id = ?", (run_id,)).fetchone()
    event["run_seq"] = int(row["next"])
    event_json = dumps(event)
    try:
        conn.execute(
            "INSERT INTO events(event_id, run_id, run_seq, ts, kind, type, actor_json, payload_json, mutation, "
            "idempotency_key, correlation_id, event_json) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (event["id"], run_id, event["run_seq"], event["created_at"], event.get("kind", "event"),
             event["type"], dumps(event["actor"]), dumps(event.get("payload", {})),
             1 if event.get("mutation") else 0, key, event.get("correlation_id", run_id), event_json))
    except sqlite3.IntegrityError as exc:
        fail("conflict", "journal rejected the event: %s" % exc,
             {"run_id": run_id, "run_seq": event["run_seq"], "idempotency_key": key})
    return event


def load_events(conn, run_id, since=None):
    if since is None:
        rows = conn.execute("SELECT seq, event_json FROM events WHERE run_id = ? ORDER BY run_seq", (run_id,))
    else:
        rows = conn.execute("SELECT seq, event_json FROM events WHERE run_id = ? AND run_seq > ? ORDER BY run_seq",
                            (run_id, int(since)))
    return [(int(r["seq"]), json.loads(r["event_json"])) for r in rows]


def store_projection(conn, snapshot):
    conn.execute(
        "INSERT INTO projections(run_id, state, updated_at, last_seq, snapshot_json) VALUES (?,?,?,?,?) "
        "ON CONFLICT(run_id) DO UPDATE SET state = excluded.state, updated_at = excluded.updated_at, "
        "last_seq = excluded.last_seq, snapshot_json = excluded.snapshot_json",
        (snapshot["run_id"], snapshot["state"], snapshot["updated_at"], snapshot["last_seq"], dumps(snapshot)))


def refresh_projection(conn, run_id, args):
    events = load_events(conn, run_id)
    snapshot = fold(run_id, events, args.get("transitions") or {}, args.get("project"))
    store_projection(conn, snapshot)
    return snapshot


# --- projection fold (pure) ------------------------------------------------

STATE_EVENTS = {
    "run.leased": "leased",
    "run.started": "running",
    "run.running": "running",
    "run.resumed": "running",
    "run.waiting": "waiting",
    "run.blocked": "blocked",
    "run.approval_required": "approval_required",
    "run.requeued": "queued",
    "run.succeeded": "succeeded",
    "run.failed": "failed",
    "run.cancelled": "cancelled",
    "run.expired": "expired",
}
BUDGET_KEYS = ("max_attempts", "max_seconds", "max_tokens")


def fold(run_id, events, table, project):
    """Deterministic fold: events (ordered by run_seq) -> snapshot dict.
    Reads nothing but its arguments; never raises on bad data — invalid or
    unknown transitions become open blockers and the state is left as is."""
    snap = {
        "projection_version": 1,
        "schema_version": "1",
        "run_id": run_id,
        "project": project,
        "state": "queued",
        "initial_state": "queued",
        "terminal": False,
        "title": None,
        "ticket_ref": None,
        "created_at": None,
        "updated_at": None,
        "event_count": 0,
        "last_seq": 0,
        "last_run_seq": 0,
        "last_event": None,
        "counters": {"events": 0, "mutations": 0, "transitions": 0, "invalid_transitions": 0,
                     "blockers_open": 0, "attempts": 0, "by_type": {}},
        "budgets": {"max_attempts": None, "max_seconds": None, "max_tokens": None,
                    "attempts_used": 0, "seconds_used": 0, "tokens_used": 0, "exhausted": []},
        "transitions": [],
        "blockers": [],
        "dispatch": None,
        "lease": None,
        "approval": None,
        "metadata": {},
    }
    counters = snap["counters"]
    budgets = snap["budgets"]

    def add_blocker(blocker):
        snap["blockers"].append(blocker)

    for seq, ev in events:
        etype = ev.get("type", "")
        payload = ev.get("payload") or {}
        if not isinstance(payload, dict):
            payload = {}
        ts = ev.get("created_at")
        run_seq = ev.get("run_seq", 0)
        if snap["created_at"] is None:
            snap["created_at"] = ts
        snap["updated_at"] = ts
        snap["event_count"] += 1
        snap["last_seq"] = seq
        snap["last_run_seq"] = run_seq
        snap["last_event"] = {"seq": seq, "run_seq": run_seq, "event_id": ev.get("id"),
                              "type": etype, "ts": ts, "actor": ev.get("actor")}
        counters["events"] += 1
        counters["by_type"][etype] = counters["by_type"].get(etype, 0) + 1
        if ev.get("mutation"):
            counters["mutations"] += 1

        # Descriptive facts.
        if etype in ("run.created", "run.updated"):
            for key in ("title", "ticket_ref"):
                if isinstance(payload.get(key), str):
                    snap[key] = payload[key]
            if isinstance(payload.get("project"), str) and snap["project"] is None:
                snap["project"] = payload["project"]
            if isinstance(payload.get("metadata"), dict):
                snap["metadata"].update(payload["metadata"])
        if etype in ("run.created", "run.budget") and isinstance(payload.get("budget"), dict):
            for key in BUDGET_KEYS:
                value = payload["budget"].get(key)
                if isinstance(value, int) and not isinstance(value, bool):
                    budgets[key] = value
        if etype in ("run.created", "run.dispatched") and isinstance(payload.get("dispatch"), dict):
            merged = dict(snap["dispatch"] or {})
            merged.update(payload["dispatch"])
            snap["dispatch"] = merged
        if etype == "attempt.started":
            counters["attempts"] += 1
            budgets["attempts_used"] += 1
        usage = payload.get("usage")
        if isinstance(usage, dict):
            for key, target in (("tokens", "tokens_used"), ("seconds", "seconds_used")):
                value = usage.get(key)
                if isinstance(value, (int, float)) and not isinstance(value, bool):
                    budgets[target] += value

        # Blockers raised/resolved explicitly.
        if etype == "blocker.raised":
            add_blocker({"id": payload.get("id") or "blocker@%s" % run_seq,
                         "type": payload.get("type") or "unspecified",
                         "severity": payload.get("severity") or "blocking",
                         "summary": payload.get("summary") or "", "state": "open",
                         "run_seq": run_seq, "ts": ts})
        elif etype == "blocker.resolved":
            for blocker in snap["blockers"]:
                if blocker["state"] != "open":
                    continue
                if payload.get("id") and blocker["id"] != payload.get("id"):
                    continue
                if not payload.get("id") and payload.get("type") and blocker["type"] != payload.get("type"):
                    continue
                blocker["state"] = "resolved"
                blocker["resolved_at"] = ts
                blocker["resolved_run_seq"] = run_seq

        # Leases / approvals mirrored from their events.
        if etype.startswith("lease."):
            snap["lease"] = {"id": payload.get("lease_id"), "owner": payload.get("owner"),
                             "state": etype.split(".", 1)[1], "expires_at": payload.get("expires_at"),
                             "generation": payload.get("generation")}
        if etype.startswith("approval."):
            snap["approval"] = {"id": payload.get("approval_id"), "action": payload.get("action"),
                                "state": etype.split(".", 1)[1]}

        # State machine. A run.transition without a usable target is a
        # malformed transition, recorded as an unknown_state blocker.
        if etype == "run.transition":
            target = payload.get("to")
        elif etype in STATE_EVENTS:
            target = STATE_EVENTS[etype]
        else:
            continue
        current = snap["state"]
        if not isinstance(target, str) or target not in table:
            counters["invalid_transitions"] += 1
            add_blocker({"id": "unknown_state@%s" % run_seq, "type": "unknown_state", "severity": "blocking",
                         "summary": "event %s (%s) asks for unknown state %r" % (run_seq, etype, target),
                         "state": "open", "run_seq": run_seq, "ts": ts, "from": current, "to": target})
            continue
        if target not in table.get(current, []):
            counters["invalid_transitions"] += 1
            add_blocker({"id": "invalid_transition@%s" % run_seq, "type": "invalid_transition",
                         "severity": "blocking",
                         "summary": "event %s (%s): transition %s -> %s is not allowed" % (run_seq, etype, current, target),
                         "state": "open", "run_seq": run_seq, "ts": ts, "from": current, "to": target})
            continue
        snap["state"] = target
        counters["transitions"] += 1
        snap["transitions"].append({"run_seq": run_seq, "from": current, "to": target, "ts": ts, "type": etype})

    snap["terminal"] = len(table.get(snap["state"], [None])) == 0
    counters["blockers_open"] = sum(1 for b in snap["blockers"] if b["state"] == "open")
    exhausted = []
    for key, used in (("max_attempts", "attempts_used"), ("max_seconds", "seconds_used"), ("max_tokens", "tokens_used")):
        limit = budgets[key]
        if isinstance(limit, int) and limit > 0 and budgets[used] >= limit:
            exhausted.append(key)
    budgets["exhausted"] = exhausted
    return snap


# --- commands ---------------------------------------------------------------

def cmd_init(args):
    conn = open_db()
    mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
    version = conn.execute("PRAGMA user_version").fetchone()[0]
    emit({"db": DB, "schema_version": version, "journal_mode": mode, "initialised": True})


def cmd_check(args):
    conn = open_db()
    integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
    counts = {}
    for table in ("events", "projections", "leases", "approvals"):
        counts[table] = conn.execute("SELECT COUNT(*) FROM %s" % table).fetchone()[0]
    gaps = []
    for row in conn.execute("SELECT run_id, COUNT(*) AS n, MAX(run_seq) AS m FROM events GROUP BY run_id"):
        if int(row["n"]) != int(row["m"]):
            gaps.append({"run_id": row["run_id"], "events": int(row["n"]), "max_run_seq": int(row["m"])})
    emit({"db": DB, "integrity": integrity, "counts": counts, "run_seq_gaps": gaps,
          "schema_version": conn.execute("PRAGMA user_version").fetchone()[0], "ok": integrity == "ok" and not gaps})


def cmd_append(args):
    conn = open_db()
    begin(conn)
    try:
        event = insert_event(conn, args["event"])
        refresh_projection(conn, event["run_id"], args)
        commit(conn)
    except JournalError:
        rollback(conn)
        raise
    sys.stdout.write(dumps(event) + "\n")


def cmd_events(args):
    conn = open_db()
    events = load_events(conn, args["run_id"], args.get("since"))
    if not events and not conn.execute("SELECT 1 FROM events WHERE run_id = ? LIMIT 1", (args["run_id"],)).fetchone():
        fail("not_found", "no events for run %s" % args["run_id"], {"run_id": args["run_id"]})
    for _seq, ev in events:
        sys.stdout.write(dumps(ev) + "\n")


def cmd_project(args):
    conn = open_db()
    run_id = args["run_id"]
    events = load_events(conn, run_id)
    if not events:
        fail("not_found", "no events for run %s" % run_id, {"run_id": run_id})
    snapshot = fold(run_id, events, args.get("transitions") or {}, args.get("project"))
    if args.get("store", True):
        begin(conn)
        try:
            store_projection(conn, snapshot)
            commit(conn)
        except JournalError:
            rollback(conn)
            raise
    emit(snapshot)


def cmd_rebuild_all(args):
    conn = open_db()
    run_ids = [r["run_id"] for r in conn.execute("SELECT DISTINCT run_id FROM events ORDER BY run_id")]
    begin(conn)
    try:
        states = {}
        for run_id in run_ids:
            snapshot = refresh_projection(conn, run_id, args)
            states[run_id] = snapshot["state"]
        conn.execute("DELETE FROM projections WHERE run_id NOT IN (SELECT DISTINCT run_id FROM events)")
        commit(conn)
    except JournalError:
        rollback(conn)
        raise
    emit({"rebuilt": len(run_ids), "runs": states})


def cmd_state(args):
    conn = open_db()
    run_id = args["run_id"]
    row = conn.execute("SELECT state FROM projections WHERE run_id = ?", (run_id,)).fetchone()
    if row:
        sys.stdout.write(row["state"] + "\n")
        return
    events = load_events(conn, run_id)
    if not events:
        fail("not_found", "unknown run %s" % run_id, {"run_id": run_id})
    snapshot = fold(run_id, events, args.get("transitions") or {}, args.get("project"))
    sys.stdout.write(snapshot["state"] + "\n")


# --- leases -----------------------------------------------------------------

def lease_row_json(row):
    return row["lease_json"]


def get_lease(conn, lease_id):
    row = conn.execute("SELECT * FROM leases WHERE lease_id = ?", (lease_id,)).fetchone()
    if not row:
        fail("not_found", "unknown lease %s" % lease_id, {"lease_id": lease_id})
    return row


def cmd_lease_get(args):
    conn = open_db()
    sys.stdout.write(lease_row_json(get_lease(conn, args["lease_id"])) + "\n")


def cmd_lease_list(args):
    conn = open_db()
    for row in conn.execute("SELECT lease_json FROM leases WHERE run_id = ? ORDER BY rowid", (args["run_id"],)):
        sys.stdout.write(row["lease_json"] + "\n")


def cmd_lease_acquire(args):
    lease = args["lease"]
    event = args["event"]
    now = args["now"]
    conn = open_db()
    begin(conn)
    try:
        holder = conn.execute(
            "SELECT lease_id, owner, expires_at, state FROM leases WHERE run_id = ? AND state IN (?, ?) AND expires_at > ? "
            "ORDER BY rowid LIMIT 1", (lease["run_id"], LIVE_LEASE_STATES[0], LIVE_LEASE_STATES[1], now)).fetchone()
        if holder:
            fail("conflict", "run %s is already leased by %s" % (lease["run_id"], holder["owner"]),
                 {"run_id": lease["run_id"], "lease_id": holder["lease_id"], "owner": holder["owner"],
                  "expires_at": holder["expires_at"], "state": holder["state"]})
        conn.execute(
            "INSERT INTO leases(lease_id, run_id, owner, state, expires_at, heartbeat_at, generation, lease_json) "
            "VALUES (?,?,?,?,?,?,?,?)",
            (lease["id"], lease["run_id"], lease["owner"], lease["state"], lease["expires_at"],
             lease["heartbeat_at"], lease.get("generation", 0), dumps(lease)))
        insert_event(conn, event)
        refresh_projection(conn, lease["run_id"], args)
        commit(conn)
    except JournalError:
        rollback(conn)
        raise
    emit(lease)


def lease_update(args, new_state, guard_states, bump):
    """Guarded state change of one lease + its event, in one transaction."""
    lease_id = args["lease_id"]
    event = args["event"]
    now = args["now"]
    conn = open_db()
    begin(conn)
    try:
        row = get_lease(conn, lease_id)
        if row["state"] not in guard_states:
            fail("conflict", "lease %s changed concurrently (now %s)" % (lease_id, row["state"]),
                 {"lease_id": lease_id, "state": row["state"]})
        lease = json.loads(row["lease_json"])
        lease["state"] = new_state
        if bump:
            lease["generation"] = int(lease.get("generation", 0)) + 1
            lease["heartbeat_at"] = now
            lease["ttl_seconds"] = int(args.get("ttl") or lease.get("ttl_seconds") or 0)
            lease["expires_at"] = plus_seconds(now, lease["ttl_seconds"])
        lease["updated_at"] = now
        conn.execute(
            "UPDATE leases SET state = ?, expires_at = ?, heartbeat_at = ?, generation = ?, lease_json = ? WHERE lease_id = ?",
            (lease["state"], lease["expires_at"], lease["heartbeat_at"], lease.get("generation", 0), dumps(lease), lease_id))
        payload = event.setdefault("payload", {})
        payload.update({"lease_id": lease_id, "owner": lease["owner"], "state": lease["state"],
                        "expires_at": lease["expires_at"], "generation": lease.get("generation", 0)})
        insert_event(conn, event)
        refresh_projection(conn, lease["run_id"], args)
        commit(conn)
    except JournalError:
        rollback(conn)
        raise
    emit(lease)


def cmd_lease_renew(args):
    lease_update(args, "renewed", LIVE_LEASE_STATES, True)


def cmd_lease_release(args):
    lease_update(args, "released", LIVE_LEASE_STATES, False)


def cmd_lease_expire(args):
    lease_update(args, "expired", LIVE_LEASE_STATES, False)


def cmd_lease_stale(args):
    conn = open_db()
    now = args["now"]
    rows = conn.execute(
        "SELECT lease_id, run_id, owner, expires_at FROM leases WHERE state IN (?, ?) AND expires_at <= ? ORDER BY rowid",
        (LIVE_LEASE_STATES[0], LIVE_LEASE_STATES[1], now))
    for row in rows:
        emit({"lease_id": row["lease_id"], "run_id": row["run_id"], "owner": row["owner"], "expires_at": row["expires_at"]})


# --- approvals --------------------------------------------------------------

def get_approval(conn, approval_id):
    row = conn.execute("SELECT * FROM approvals WHERE approval_id = ?", (approval_id,)).fetchone()
    if not row:
        fail("not_found", "unknown approval %s" % approval_id, {"approval_id": approval_id})
    return row


def cmd_approval_get(args):
    conn = open_db()
    sys.stdout.write(get_approval(conn, args["approval_id"])["approval_json"] + "\n")


def cmd_approval_list(args):
    conn = open_db()
    state = args.get("state")
    if state:
        rows = conn.execute("SELECT approval_json FROM approvals WHERE run_id = ? AND state = ? ORDER BY rowid",
                            (args["run_id"], state))
    else:
        rows = conn.execute("SELECT approval_json FROM approvals WHERE run_id = ? ORDER BY rowid", (args["run_id"],))
    for row in rows:
        sys.stdout.write(row["approval_json"] + "\n")


def cmd_approval_create(args):
    approval = args["approval"]
    event = args["event"]
    conn = open_db()
    begin(conn)
    try:
        existing = conn.execute("SELECT approval_json FROM approvals WHERE idempotency_key = ?",
                                (approval["idempotency_key"],)).fetchone()
        if existing:
            existing_approval = json.loads(existing["approval_json"])
            fail("conflict", "an approval with idempotency_key %r already exists" % approval["idempotency_key"],
                 {"idempotency_key": approval["idempotency_key"], "approval_id": existing_approval.get("id"),
                  "state": existing_approval.get("state"), "reason": "duplicate_idempotency_key"},
                 stdout=existing["approval_json"])
        conn.execute(
            "INSERT INTO approvals(approval_id, run_id, action, principal, policy_version, state, expires_at, "
            "idempotency_key, result_json, approval_json) VALUES (?,?,?,?,?,?,?,?,?,?)",
            (approval["id"], approval["run_id"], approval["action"], approval["principal"],
             approval["policy_version"], approval["state"], approval.get("expires_at"),
             approval["idempotency_key"], None, dumps(approval)))
        insert_event(conn, event)
        refresh_projection(conn, approval["run_id"], args)
        commit(conn)
    except JournalError:
        rollback(conn)
        raise
    emit(approval)


def cmd_approval_set_state(args):
    approval_id = args["approval_id"]
    new_state = args["state"]
    expected = args["expected_state"]
    event = args["event"]
    now = args["now"]
    conn = open_db()
    begin(conn)
    try:
        row = get_approval(conn, approval_id)
        if row["state"] != expected:
            fail("conflict", "approval %s changed concurrently (now %s)" % (approval_id, row["state"]),
                 {"approval_id": approval_id, "state": row["state"], "expected": expected})
        approval = json.loads(row["approval_json"])
        approval["state"] = new_state
        approval["decided_at"] = now
        for key in ("decided_by", "reason", "result"):
            if args.get(key) is not None:
                approval[key] = args[key]
        result_json = dumps(approval["result"]) if isinstance(approval.get("result"), dict) else None
        conn.execute("UPDATE approvals SET state = ?, result_json = ?, approval_json = ? WHERE approval_id = ?",
                     (new_state, result_json, dumps(approval), approval_id))
        payload = event.setdefault("payload", {})
        payload.update({"approval_id": approval_id, "action": approval["action"], "state": new_state,
                        "principal": approval["principal"]})
        insert_event(conn, event)
        refresh_projection(conn, approval["run_id"], args)
        commit(conn)
    except JournalError:
        rollback(conn)
        raise
    emit(approval)


COMMANDS = {
    "init": cmd_init, "check": cmd_check, "append": cmd_append, "events": cmd_events,
    "project": cmd_project, "rebuild_all": cmd_rebuild_all, "state": cmd_state,
    "lease_get": cmd_lease_get, "lease_list": cmd_lease_list, "lease_acquire": cmd_lease_acquire,
    "lease_renew": cmd_lease_renew, "lease_release": cmd_lease_release, "lease_expire": cmd_lease_expire,
    "lease_stale": cmd_lease_stale,
    "approval_get": cmd_approval_get, "approval_list": cmd_approval_list,
    "approval_create": cmd_approval_create, "approval_set_state": cmd_approval_set_state,
}


def main(argv):
    if len(argv) < 2 or argv[1] not in COMMANDS:
        fail("usage", "unknown journal command", {"argv": argv[1:]})
    args = json.loads(argv[2]) if len(argv) > 2 and argv[2] else {}
    COMMANDS[argv[1]](args)


if __name__ == "__main__":
    try:
        main(sys.argv)
        sys.stdout.flush()
    except JournalError as err:
        if err.stdout is not None:
            sys.stdout.write(err.stdout + "\n")
            sys.stdout.flush()
        sys.stderr.write(dumps({"error": {"code": err.code, "message": err.message, "module": "journal",
                                          "details": err.details}}) + "\n")
        sys.exit(1)
    except sqlite3.Error as err:
        sys.stderr.write(dumps({"error": {"code": "internal_error", "message": "sqlite failure: %s" % err,
                                          "module": "journal", "details": {"db": DB}}}) + "\n")
        sys.exit(1)
PY

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------
_ordo_journal_fail() {
  ordo_contracts_error "$ORDO_JOURNAL_MODULE" "$@"
}

_ordo_journal_ensure_state() {
  # state_dir/state_persist come from lib/audit_log.sh + lib/state_persist.sh.
  if ! declare -F state_dir >/dev/null 2>&1; then
    if [[ -z "${PROJECT:-}" ]]; then
      _ordo_journal_fail usage "PROJECT must be set (source a project config or lib/audit_log.sh first)"
      return $?
    fi
    # shellcheck source=lib/audit_log.sh
    source "$_ORDO_JOURNAL_LIB_DIR/audit_log.sh"
  fi
  if ! declare -F state_persist >/dev/null 2>&1; then
    # shellcheck source=lib/state_persist.sh
    source "$_ORDO_JOURNAL_LIB_DIR/state_persist.sh"
  fi
}

ordo_journal_db_path() {
  if [[ -n "${ORDO_JOURNAL_DB:-}" ]]; then
    printf '%s\n' "$ORDO_JOURNAL_DB"
    return 0
  fi
  _ordo_journal_ensure_state || return $?
  printf '%s/ordo-journal.sqlite\n' "$(state_dir)"
}

ordo_journal_now() {
  if [[ -n "${ORDO_JOURNAL_NOW:-}" ]]; then
    printf '%s\n' "$ORDO_JOURNAL_NOW"
  else
    ordo_contracts_now
  fi
}

_ordo_journal_python_bin() {
  if [[ -n "${ORDO_JOURNAL_PYTHON_BIN:-}" ]]; then
    command -v "$ORDO_JOURNAL_PYTHON_BIN" 2>/dev/null && return 0
    return 1
  fi
  command -v python3 2>/dev/null
}

# _ordo_journal_py <command> [args-json]
# Runs the embedded program. stdout passes through; a JSON error on stderr is
# re-emitted and mapped to the contract exit code; anything else (traceback,
# signal) becomes an internal_error object carrying the raw tail.
_ordo_journal_py() {
  local cmd="${1:?usage: _ordo_journal_py <command> [args-json]}"
  local args="${2:-{\}}"
  local pybin
  if ! pybin=$(_ordo_journal_python_bin) || [[ -z "$pybin" ]]; then
    _ordo_journal_fail missing_dependency "python3 (stdlib sqlite3) is required by the journal" \
      '{"dependency":"python3","hint":"install python3 or set ORDO_JOURNAL_PYTHON_BIN"}'
    return $?
  fi
  local db
  db=$(ordo_journal_db_path) || return $?
  mkdir -p "$(dirname "$db")" 2>/dev/null || true
  local errfile
  errfile=$(mktemp "${TMPDIR:-/tmp}/ordo-journal-err.XXXXXX") || {
    _ordo_journal_fail internal_error "cannot create a temporary file for journal stderr"
    return $?
  }
  local rc=0
  # Subshell: keeps bash's "Killed" job notice (SIGKILL fault hook) inside
  # the captured stderr instead of the caller's terminal.
  (
    ORDO_JOURNAL_DB="$db" \
    ORDO_JOURNAL_BUSY_TIMEOUT_MS="$ORDO_JOURNAL_BUSY_TIMEOUT_MS" \
    ORDO_JOURNAL_FAULT="$ORDO_JOURNAL_FAULT" \
    ORDO_JOURNAL_NOW="$ORDO_JOURNAL_NOW" \
      "$pybin" - "$cmd" "$args" <<<"$ORDO_JOURNAL_PY"
  ) 2>"$errfile" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    rm -f "$errfile"
    return 0
  fi
  local code
  if code=$(jq -r '.error.code // empty' "$errfile" 2>/dev/null) && [[ -n "$code" ]]; then
    cat "$errfile" >&2
    rm -f "$errfile"
    return "$(ordo_contracts_exit_code "$code")"
  fi
  local tail_text
  tail_text=$(tail -n 3 "$errfile" 2>/dev/null | tr '\n' ' ' | cut -c1-400)
  rm -f "$errfile"
  _ordo_journal_fail internal_error "journal command '${cmd}' failed (rc=${rc})" \
    "$(jq -cn --arg cmd "$cmd" --argjson rc "$rc" --arg raw "$tail_text" '{"command": $cmd, "rc": $rc, "raw": $raw}')"
}

_ordo_journal_json_arg() {
  # <json|-|@path> -> compact JSON on stdout; 5 invalid_json otherwise.
  local raw
  if ! raw=$(_ordo_contracts_read_json_arg "${1-}"); then
    _ordo_journal_fail not_found "cannot read JSON input: ${1-}" "$(jq -cn --arg input "${1-}" '{"input": $input}')"
    return $?
  fi
  local out
  if ! out=$(printf '%s' "$raw" | jq -c . 2>/dev/null) || [[ -z "$out" ]]; then
    _ordo_journal_fail invalid_json "argument is not valid JSON" "$(jq -cn --arg input "${1-}" '{"input": ($input | .[0:200])}')"
    return $?
  fi
  printf '%s' "$out"
}

_ordo_journal_default_actor() {
  printf '{"type":"system","id":"ordo_journal"}'
}

_ordo_journal_require_run_id() {
  local run_id="${1-}"
  if [[ ! "$run_id" =~ ^run_[0-9a-f]{24}$ ]]; then
    _ordo_journal_fail bad_argument "run_id must be a canonical run id (run_<24 hex>): '${run_id}'" \
      "$(jq -cn --arg run_id "$run_id" '{"run_id": $run_id}')"
    return $?
  fi
}

_ordo_journal_project_args() {
  # Common args for every command that folds a projection: the run transition
  # table exported by the contracts library (single source of truth) and the
  # project key.
  jq -cn --argjson transitions "$(ordo_contracts_transitions run)" --arg project "${PROJECT:-}" \
    '{"transitions": $transitions, "project": (if $project == "" then null else $project end)}'
}

# _ordo_journal_build_event <run_id> <type> <payload-json> <actor-json> <mutation> <idem-key> <corr-id> <metadata-json>
# Builds and validates the event object (contract kind `event`).
_ordo_journal_build_event() {
  local run_id="$1" type="$2" payload="$3" actor="$4" mutation="$5" key="$6" corr="$7" metadata="$8"
  local id now
  id=$(ordo_contracts_new_id event) || return $?
  now=$(ordo_journal_now)
  local event
  event=$(jq -cn \
    --arg id "$id" --arg now "$now" --arg run_id "$run_id" --arg type "$type" \
    --argjson payload "$payload" --argjson actor "$actor" --argjson mutation "$mutation" \
    --arg key "$key" --arg corr "$corr" --argjson metadata "$metadata" '
    {"schema_version": "1", "kind": "event", "id": $id, "created_at": $now,
     "correlation_id": (if $corr == "" then $run_id else $corr end), "actor": $actor,
     "run_id": $run_id, "type": $type, "payload": $payload, "mutation": $mutation}
    + (if $key == "" then {} else {"idempotency_key": $key} end)
    + (if $metadata == {} then {} else {"metadata": $metadata} end)') || return $?
  local err rc=0
  err=$(ordo_contracts_validate event "$event" 2>&1 >/dev/null) || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    # Re-emit the contracts error under this module's name, keeping its details.
    local details
    details=$(printf '%s' "$err" | jq -c '.error.details // {}' 2>/dev/null || printf '{}')
    _ordo_journal_fail invalid_contract "event does not satisfy the event v1 contract" "$details"
    return $?
  fi
  printf '%s' "$event"
}

# ---------------------------------------------------------------------------
# Public API — journal
# ---------------------------------------------------------------------------
ordo_journal_init() {
  _ordo_journal_py init '{}'
}

ordo_journal_check() {
  _ordo_journal_py check '{}'
}

ordo_journal_append() {
  local run_id="${1-}" type="${2-}" payload_arg="${3-}"
  if [[ $# -lt 3 ]]; then
    _ordo_journal_fail usage "usage: ordo_journal_append <run_id> <type> <payload_json> [--idempotency-key K] [--actor JSON] [--mutation] [--correlation-id C] [--metadata JSON]"
    return $?
  fi
  shift 3
  local key="" actor="" mutation=false corr="" metadata="{}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --idempotency-key) key="${2-}"; shift 2 ;;
      --actor) actor="${2-}"; shift 2 ;;
      --mutation) mutation=true; shift ;;
      --correlation-id) corr="${2-}"; shift 2 ;;
      --metadata) metadata="${2-}"; shift 2 ;;
      *)
        _ordo_journal_fail usage "unknown option for ordo_journal_append: ${1}" "$(jq -cn --arg opt "$1" '{"option": $opt}')"
        return $?
        ;;
    esac
  done
  _ordo_journal_require_run_id "$run_id" || return $?
  local payload actor_json metadata_json
  payload=$(_ordo_journal_json_arg "$payload_arg") || return $?
  actor_json=$(_ordo_journal_json_arg "${actor:-$(_ordo_journal_default_actor)}") || return $?
  metadata_json=$(_ordo_journal_json_arg "$metadata") || return $?
  local event
  event=$(_ordo_journal_build_event "$run_id" "$type" "$payload" "$actor_json" "$mutation" "$key" "$corr" "$metadata_json") || return $?
  local args
  args=$(_ordo_journal_project_args | jq -c --argjson event "$event" '. + {"event": $event}')
  _ordo_journal_py append "$args"
}

ordo_journal_events() {
  local run_id="${1-}"
  if [[ $# -lt 1 ]]; then
    _ordo_journal_fail usage "usage: ordo_journal_events <run_id> [--since RUN_SEQ]"
    return $?
  fi
  shift
  local since=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since)
        since="${2-}"
        if [[ ! "$since" =~ ^[0-9]+$ ]]; then
          _ordo_journal_fail bad_argument "--since expects a non-negative integer run_seq" "$(jq -cn --arg v "$since" '{"since": $v}')"
          return $?
        fi
        shift 2 ;;
      *)
        _ordo_journal_fail usage "unknown option for ordo_journal_events: ${1}" "$(jq -cn --arg opt "$1" '{"option": $opt}')"
        return $?
        ;;
    esac
  done
  _ordo_journal_require_run_id "$run_id" || return $?
  local args
  args=$(jq -cn --arg run_id "$run_id" --arg since "$since" \
    '{"run_id": $run_id} + (if $since == "" then {} else {"since": ($since | tonumber)} end)')
  _ordo_journal_py events "$args"
}

ordo_journal_project() {
  local run_id="${1-}"
  if [[ $# -lt 1 ]]; then
    _ordo_journal_fail usage "usage: ordo_journal_project <run_id>"
    return $?
  fi
  _ordo_journal_require_run_id "$run_id" || return $?
  local args
  args=$(_ordo_journal_project_args | jq -c --arg run_id "$run_id" '. + {"run_id": $run_id, "store": true}')
  _ordo_journal_py project "$args"
}

ordo_journal_rebuild_all() {
  _ordo_journal_py rebuild_all "$(_ordo_journal_project_args)"
}

ordo_journal_state() {
  local run_id="${1-}"
  if [[ $# -lt 1 ]]; then
    _ordo_journal_fail usage "usage: ordo_journal_state <run_id>"
    return $?
  fi
  _ordo_journal_require_run_id "$run_id" || return $?
  local args
  args=$(_ordo_journal_project_args | jq -c --arg run_id "$run_id" '. + {"run_id": $run_id}')
  _ordo_journal_py state "$args"
}

# ---------------------------------------------------------------------------
# Compatibility export — legacy state files via lib/state_persist.sh
# ---------------------------------------------------------------------------
# Files written under $(state_dir):
#   ordo-runs/<run_id>.json      the snapshot (pretty, sorted keys)   [state_persist]
#   assignments.json             .[<agent>] upserted with the exact row shape
#                                scripts/dispatch_ticket.sh writes (ticket, issue,
#                                branch, workdir, repo_root, prompt_file,
#                                dispatched_at, head_at_dispatch [+ route_mode,
#                                context_proof_route, context_proof_live_workdir,
#                                status, reason, updated_at]) while the run is
#                                not terminal; the row is deleted once the run is
#                                terminal, but only if this journal wrote it.  [state_update]
#   ordo-journal-compat.json     {"agents": {<agent>: <run_id>}} ownership map   [state_update]
# The agent and row facts come from snapshot.dispatch (payload.dispatch of
# run.created / run.dispatched events).
ordo_journal_compat_export() {
  local run_id="${1-}"
  if [[ $# -lt 1 ]]; then
    _ordo_journal_fail usage "usage: ordo_journal_compat_export <run_id>"
    return $?
  fi
  _ordo_journal_require_run_id "$run_id" || return $?
  _ordo_journal_ensure_state || return $?
  local snapshot
  snapshot=$(ordo_journal_project "$run_id") || return $?

  local dir
  dir=$(state_dir)
  mkdir -p "$dir/ordo-runs"
  state_persist "ordo-runs/${run_id}.json" "$(printf '%s' "$snapshot" | jq -S .)"$'\n'

  local agent terminal action="none"
  agent=$(printf '%s' "$snapshot" | jq -r '.dispatch.agent // ""')
  terminal=$(printf '%s' "$snapshot" | jq -r '.terminal')
  if [[ -n "$agent" ]]; then
    local agent_key
    agent_key=$(jq -rn --arg a "$agent" '[$a] | tojson')
    if [[ "$terminal" == "true" ]]; then
      local owner
      owner=$(state_get ordo-journal-compat | jq -r --arg a "$agent" '.agents[$a] // ""')
      if [[ "$owner" == "$run_id" ]]; then
        state_update assignments "del(.${agent_key})"
        state_update ordo-journal-compat "del(.agents${agent_key})"
        action="deleted"
      fi
    else
      local row
      row=$(printf '%s' "$snapshot" | jq -c '
        .dispatch as $d
        | ($d.ticket // $d.issue // "" | tostring) as $ticket
        | {
            ticket: $ticket,
            issue: (if ($ticket | test("^[0-9]+$")) then ($ticket | tonumber) else $ticket end),
            branch: (($d.branch // "") | if . == "" then null else . end),
            workdir: ($d.workdir // ""),
            repo_root: ($d.repo_root // ""),
            prompt_file: ($d.prompt_file // ""),
            dispatched_at: ($d.dispatched_at // ""),
            head_at_dispatch: (($d.head_at_dispatch // "") | if . == "" then null else . end)
          }
        + (if ($d.route_mode // "") == "" then {} else {route_mode: $d.route_mode} end)
        + (if ($d.context_proof_route // "") == "" then {} else {context_proof_route: $d.context_proof_route} end)
        + (if ($d.context_proof_live_workdir // "") == "" then {} else {context_proof_live_workdir: $d.context_proof_live_workdir} end)
        + (if ($d.status // "") == "" then {} else {status: $d.status} end)
        + (if ($d.reason // "") == "" then {} else {reason: $d.reason} end)
        + (if ($d.updated_at // "") == "" then {} else {updated_at: $d.updated_at} end)')
      state_update assignments ".${agent_key} = ${row}"
      state_update ordo-journal-compat ".agents${agent_key} = $(jq -rn --arg r "$run_id" '$r | tojson')"
      action="upserted"
    fi
  fi
  jq -cn --arg run_id "$run_id" --arg state "$(printf '%s' "$snapshot" | jq -r .state)" \
    --arg agent "$agent" --arg action "$action" --arg dir "$dir" '
    {"run_id": $run_id, "state": $state,
     "files": ([($dir + "/ordo-runs/" + $run_id + ".json")]
               + (if $action == "none" then [] else [($dir + "/assignments.json"), ($dir + "/ordo-journal-compat.json")] end)),
     "assignment": {"agent": (if $agent == "" then null else $agent end), "action": $action}}'
}

# ---------------------------------------------------------------------------
# Leases — exclusive, expiring ownership of a run (lease contract objects)
# ---------------------------------------------------------------------------
_ordo_journal_parse_actor_opt() {
  # Shared option parser for the lease/approval commands. Sets ACTOR_JSON,
  # TTL, TASK_ID, REASON, DECIDED_BY, RESULT, POLICY_VERSION, IDEM_KEY,
  # EXPIRES_AT in the caller's scope (via nameref-free globals prefixed _OJ_).
  _OJ_ACTOR="" _OJ_TTL="" _OJ_TASK_ID="" _OJ_REASON="" _OJ_DECIDED_BY="" _OJ_RESULT="" \
  _OJ_POLICY_VERSION="" _OJ_IDEM_KEY="" _OJ_EXPIRES_AT="" _OJ_STATE=""
  local fn="$1"; shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --actor) _OJ_ACTOR="${2-}"; shift 2 ;;
      --ttl) _OJ_TTL="${2-}"; shift 2 ;;
      --task-id) _OJ_TASK_ID="${2-}"; shift 2 ;;
      --reason) _OJ_REASON="${2-}"; shift 2 ;;
      --decided-by) _OJ_DECIDED_BY="${2-}"; shift 2 ;;
      --result) _OJ_RESULT="${2-}"; shift 2 ;;
      --policy-version) _OJ_POLICY_VERSION="${2-}"; shift 2 ;;
      --idempotency-key) _OJ_IDEM_KEY="${2-}"; shift 2 ;;
      --expires-at) _OJ_EXPIRES_AT="${2-}"; shift 2 ;;
      --state) _OJ_STATE="${2-}"; shift 2 ;;
      *)
        _ordo_journal_fail usage "unknown option for ${fn}: ${1}" "$(jq -cn --arg opt "$1" '{"option": $opt}')"
        return $?
        ;;
    esac
  done
  if [[ -n "$_OJ_TTL" && ! "$_OJ_TTL" =~ ^[1-9][0-9]*$ ]]; then
    _ordo_journal_fail bad_argument "--ttl expects a positive integer number of seconds" "$(jq -cn --arg v "$_OJ_TTL" '{"ttl": $v}')"
    return $?
  fi
}

_ordo_journal_add_seconds() {
  # <rfc3339> <seconds> -> rfc3339 (GNU date; python is not needed here)
  date -u -d "${1} + ${2} seconds" +%Y-%m-%dT%H:%M:%SZ
}

ordo_journal_lease_acquire() {
  local run_id="${1-}" owner="${2-}"
  if [[ $# -lt 2 || -z "$owner" ]]; then
    _ordo_journal_fail usage "usage: ordo_journal_lease_acquire <run_id> <owner> [--ttl S] [--task-id T] [--actor JSON]"
    return $?
  fi
  shift 2
  _ordo_journal_parse_actor_opt ordo_journal_lease_acquire "$@" || return $?
  _ordo_journal_require_run_id "$run_id" || return $?
  local ttl="${_OJ_TTL:-$ORDO_JOURNAL_DEFAULT_LEASE_TTL}"
  local actor_json
  actor_json=$(_ordo_journal_json_arg "${_OJ_ACTOR:-$(_ordo_journal_default_actor)}") || return $?
  local id now expires
  id=$(ordo_contracts_new_id lease) || return $?
  now=$(ordo_journal_now)
  expires=$(_ordo_journal_add_seconds "$now" "$ttl")
  local lease
  lease=$(jq -cn --arg id "$id" --arg now "$now" --arg run_id "$run_id" --arg owner "$owner" \
    --arg expires "$expires" --argjson ttl "$ttl" --arg task_id "$_OJ_TASK_ID" --argjson actor "$actor_json" '
    {"schema_version": "1", "kind": "lease", "id": $id, "created_at": $now, "correlation_id": $run_id,
     "actor": $actor, "run_id": $run_id, "owner": $owner, "state": "active", "expires_at": $expires,
     "heartbeat_at": $now, "ttl_seconds": $ttl, "generation": 0}
    + (if $task_id == "" then {} else {"task_id": $task_id} end)')
  ordo_contracts_validate lease "$lease" || return $?
  local payload event
  payload=$(jq -cn --arg id "$id" --arg owner "$owner" --arg expires "$expires" --argjson ttl "$ttl" \
    '{"lease_id": $id, "owner": $owner, "state": "active", "expires_at": $expires, "ttl_seconds": $ttl, "generation": 0}')
  event=$(_ordo_journal_build_event "$run_id" "lease.acquired" "$payload" "$actor_json" false "" "" '{}') || return $?
  local args
  args=$(_ordo_journal_project_args | jq -c --argjson lease "$lease" --argjson event "$event" --arg now "$now" \
    '. + {"lease": $lease, "event": $event, "now": $now}')
  _ordo_journal_py lease_acquire "$args"
}

ordo_journal_lease_get() {
  local lease_id="${1-}"
  if [[ $# -lt 1 || -z "$lease_id" ]]; then
    _ordo_journal_fail usage "usage: ordo_journal_lease_get <lease_id>"
    return $?
  fi
  _ordo_journal_py lease_get "$(jq -cn --arg id "$lease_id" '{"lease_id": $id}')"
}

ordo_journal_lease_list() {
  local run_id="${1-}"
  if [[ $# -lt 1 ]]; then
    _ordo_journal_fail usage "usage: ordo_journal_lease_list <run_id>"
    return $?
  fi
  _ordo_journal_require_run_id "$run_id" || return $?
  _ordo_journal_py lease_list "$(jq -cn --arg id "$run_id" '{"run_id": $id}')"
}

# _ordo_journal_lease_change <fn> <lease_id> <to-state> <event-type> [opts]
# Shared by renew/release/expire: fetch, refuse lost/stale leases with exit 8,
# check the lease transition table, then run the guarded update + event.
_ordo_journal_lease_change() {
  local fn="$1" lease_id="$2" to="$3" etype="$4"
  shift 4
  _ordo_journal_parse_actor_opt "$fn" "$@" || return $?
  local current
  current=$(ordo_journal_lease_get "$lease_id") || return $?
  local state expires run_id now
  state=$(printf '%s' "$current" | jq -r .state)
  expires=$(printf '%s' "$current" | jq -r .expires_at)
  run_id=$(printf '%s' "$current" | jq -r .run_id)
  now=$(ordo_journal_now)
  if [[ "$to" != "expired" ]]; then
    if [[ "$state" == "expired" ]]; then
      _ordo_journal_fail lease_lost "lease ${lease_id} has expired" \
        "$(jq -cn --arg id "$lease_id" --arg state "$state" --arg expires "$expires" '{"lease_id": $id, "state": $state, "expires_at": $expires}')"
      return $?
    fi
    if [[ "$state" != "released" && "$expires" < "$now" ]]; then
      _ordo_journal_fail lease_stale "lease ${lease_id} is past its expiry (${expires} < ${now}); run expire_stale" \
        "$(jq -cn --arg id "$lease_id" --arg state "$state" --arg expires "$expires" --arg now "$now" '{"lease_id": $id, "state": $state, "expires_at": $expires, "now": $now}')"
      return $?
    fi
  fi
  ordo_contracts_transition lease "$state" "$to" || return $?
  local actor_json event
  actor_json=$(_ordo_journal_json_arg "${_OJ_ACTOR:-$(_ordo_journal_default_actor)}") || return $?
  event=$(_ordo_journal_build_event "$run_id" "$etype" "$(jq -cn --arg id "$lease_id" '{"lease_id": $id}')" "$actor_json" false "" "" '{}') || return $?
  local args
  args=$(_ordo_journal_project_args | jq -c --arg lease_id "$lease_id" --argjson event "$event" --arg now "$now" --arg ttl "$_OJ_TTL" \
    '. + {"lease_id": $lease_id, "event": $event, "now": $now} + (if $ttl == "" then {} else {"ttl": ($ttl | tonumber)} end)')
  case "$to" in
    renewed) _ordo_journal_py lease_renew "$args" ;;
    released) _ordo_journal_py lease_release "$args" ;;
    expired) _ordo_journal_py lease_expire "$args" ;;
  esac
}

ordo_journal_lease_renew() {
  local lease_id="${1-}"
  if [[ $# -lt 1 || -z "$lease_id" ]]; then
    _ordo_journal_fail usage "usage: ordo_journal_lease_renew <lease_id> [--ttl S] [--actor JSON]"
    return $?
  fi
  shift
  _ordo_journal_lease_change ordo_journal_lease_renew "$lease_id" renewed lease.renewed "$@"
}

ordo_journal_lease_release() {
  local lease_id="${1-}"
  if [[ $# -lt 1 || -z "$lease_id" ]]; then
    _ordo_journal_fail usage "usage: ordo_journal_lease_release <lease_id> [--actor JSON]"
    return $?
  fi
  shift
  _ordo_journal_lease_change ordo_journal_lease_release "$lease_id" released lease.released "$@"
}

# ordo_journal_lease_expire_stale [--actor JSON]
# Every active/renewed lease whose expires_at <= now becomes `expired` and
# gets a lease.expired event on its run. Prints {"expired":[...],"count":N}.
ordo_journal_lease_expire_stale() {
  _ordo_journal_parse_actor_opt ordo_journal_lease_expire_stale "$@" || return $?
  local actor_opt=()
  [[ -n "$_OJ_ACTOR" ]] && actor_opt=(--actor "$_OJ_ACTOR")
  local now stale
  now=$(ordo_journal_now)
  stale=$(_ordo_journal_py lease_stale "$(jq -cn --arg now "$now" '{"now": $now}')") || return $?
  local expired="[]" lease_id lease rc
  while IFS= read -r lease_id; do
    [[ -n "$lease_id" ]] || continue
    rc=0
    lease=$(_ordo_journal_lease_change ordo_journal_lease_expire_stale "$lease_id" expired lease.expired ${actor_opt[@]+"${actor_opt[@]}"} 2>/dev/null) || rc=$?
    # 5 = conflict: another sweeper expired it between our SELECT and UPDATE.
    if [[ "$rc" -eq 0 ]]; then
      expired=$(printf '%s' "$expired" | jq -c --argjson l "$lease" '. + [$l]')
    elif [[ "$rc" -ne 5 ]]; then
      _ordo_journal_fail internal_error "could not expire lease ${lease_id} (rc=${rc})" "$(jq -cn --arg id "$lease_id" --argjson rc "$rc" '{"lease_id": $id, "rc": $rc}')"
      return $?
    fi
  done < <(printf '%s\n' "$stale" | jq -r 'select(. != null) | .lease_id')
  printf '%s' "$expired" | jq -c '{"expired": ., "count": length}'
}

# ---------------------------------------------------------------------------
# Approvals — human/policy gates (approval contract objects)
# ---------------------------------------------------------------------------
ordo_journal_approval_create() {
  local run_id="${1-}" action="${2-}" principal="${3-}"
  if [[ $# -lt 3 || -z "$action" || -z "$principal" ]]; then
    _ordo_journal_fail usage "usage: ordo_journal_approval_create <run_id> <action> <principal> --policy-version V --idempotency-key K [--ttl S | --expires-at TS] [--actor JSON]"
    return $?
  fi
  shift 3
  _ordo_journal_parse_actor_opt ordo_journal_approval_create "$@" || return $?
  _ordo_journal_require_run_id "$run_id" || return $?
  if [[ -z "$_OJ_POLICY_VERSION" || -z "$_OJ_IDEM_KEY" ]]; then
    _ordo_journal_fail usage "ordo_journal_approval_create requires --policy-version and --idempotency-key"
    return $?
  fi
  local actor_json
  actor_json=$(_ordo_journal_json_arg "${_OJ_ACTOR:-$(_ordo_journal_default_actor)}") || return $?
  local id now expires
  id=$(ordo_contracts_new_id approval) || return $?
  now=$(ordo_journal_now)
  if [[ -n "$_OJ_EXPIRES_AT" ]]; then
    expires="$_OJ_EXPIRES_AT"
  else
    expires=$(_ordo_journal_add_seconds "$now" "${_OJ_TTL:-$ORDO_JOURNAL_DEFAULT_APPROVAL_TTL}")
  fi
  local approval
  approval=$(jq -cn --arg id "$id" --arg now "$now" --arg run_id "$run_id" --arg action "$action" \
    --arg principal "$principal" --arg policy "$_OJ_POLICY_VERSION" --arg key "$_OJ_IDEM_KEY" \
    --arg expires "$expires" --argjson actor "$actor_json" '
    {"schema_version": "1", "kind": "approval", "id": $id, "created_at": $now, "correlation_id": $run_id,
     "actor": $actor, "run_id": $run_id, "action": $action, "principal": $principal,
     "policy_version": $policy, "state": "pending", "idempotency_key": $key, "expires_at": $expires}')
  ordo_contracts_validate approval "$approval" || return $?
  local payload event
  payload=$(jq -cn --arg id "$id" --arg action "$action" --arg principal "$principal" --arg policy "$_OJ_POLICY_VERSION" --arg expires "$expires" \
    '{"approval_id": $id, "action": $action, "principal": $principal, "policy_version": $policy, "state": "pending", "expires_at": $expires}')
  event=$(_ordo_journal_build_event "$run_id" "approval.requested" "$payload" "$actor_json" false "" "" '{}') || return $?
  local args
  args=$(_ordo_journal_project_args | jq -c --argjson approval "$approval" --argjson event "$event" '. + {"approval": $approval, "event": $event}')
  _ordo_journal_py approval_create "$args"
}

ordo_journal_approval_get() {
  local approval_id="${1-}"
  if [[ $# -lt 1 || -z "$approval_id" ]]; then
    _ordo_journal_fail usage "usage: ordo_journal_approval_get <approval_id>"
    return $?
  fi
  _ordo_journal_py approval_get "$(jq -cn --arg id "$approval_id" '{"approval_id": $id}')"
}

ordo_journal_approval_list() {
  local run_id="${1-}"
  if [[ $# -lt 1 ]]; then
    _ordo_journal_fail usage "usage: ordo_journal_approval_list <run_id> [--state S]"
    return $?
  fi
  shift
  _ordo_journal_parse_actor_opt ordo_journal_approval_list "$@" || return $?
  _ordo_journal_require_run_id "$run_id" || return $?
  _ordo_journal_py approval_list "$(jq -cn --arg id "$run_id" --arg state "$_OJ_STATE" '{"run_id": $id} + (if $state == "" then {} else {"state": $state} end)')"
}

ordo_journal_approval_set_state() {
  local approval_id="${1-}" to="${2-}"
  if [[ $# -lt 2 || -z "$approval_id" || -z "$to" ]]; then
    _ordo_journal_fail usage "usage: ordo_journal_approval_set_state <approval_id> <state> [--reason R] [--decided-by JSON] [--result JSON] [--actor JSON]"
    return $?
  fi
  shift 2
  _ordo_journal_parse_actor_opt ordo_journal_approval_set_state "$@" || return $?
  local current
  current=$(ordo_journal_approval_get "$approval_id") || return $?
  local state run_id
  state=$(printf '%s' "$current" | jq -r .state)
  run_id=$(printf '%s' "$current" | jq -r .run_id)
  ordo_contracts_transition approval "$state" "$to" || return $?
  local actor_json decided_by result
  actor_json=$(_ordo_journal_json_arg "${_OJ_ACTOR:-$(_ordo_journal_default_actor)}") || return $?
  decided_by=$(_ordo_journal_json_arg "${_OJ_DECIDED_BY:-$actor_json}") || return $?
  result=$(_ordo_journal_json_arg "${_OJ_RESULT:-null}") || return $?
  local now event
  now=$(ordo_journal_now)
  event=$(_ordo_journal_build_event "$run_id" "approval.${to}" "$(jq -cn --arg id "$approval_id" '{"approval_id": $id}')" "$actor_json" false "" "" '{}') || return $?
  local args
  args=$(_ordo_journal_project_args | jq -c --arg id "$approval_id" --arg to "$to" --arg expected "$state" \
    --argjson event "$event" --arg now "$now" --arg reason "$_OJ_REASON" --argjson decided_by "$decided_by" --argjson result "$result" '
    . + {"approval_id": $id, "state": $to, "expected_state": $expected, "event": $event, "now": $now,
         "decided_by": $decided_by, "result": $result}
    + (if $reason == "" then {} else {"reason": $reason} end)')
  _ordo_journal_py approval_set_state "$args"
}
