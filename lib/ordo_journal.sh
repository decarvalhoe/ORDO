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
#   ordo_journal_runs [--state S[,S...]]                # snapshot JSON lines of every projected run (enqueue order)
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
# Batched commands (#817, additive; one python3 process each):
#   ordo_journal_tick_view [--now TS] [--state S[,S...]]  # {"now","stale_leases","runs","slots_used","counts","states"}
#   ordo_journal_append_batch <events-json|-|@path> [--actor JSON]
#                                                       # N appends in ONE transaction; JSON lines; duplicate key => 5, nothing written
#   ordo_journal_batch <ops-json|-|@path> [--actor JSON] # append / lease_acquire / lease_renew / lease_release / lease_expire
#                                                       # in ONE transaction; {"results":[...],"touched":[run_id...]}
#   ordo_journal_approval_view <approval_id>            # {"approval","run_id","run_state","events"} (events naming the approval)
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
ORDO_JOURNAL_PY=$(cat <<'PY'
import json
import os
import signal
import sys
import time
# The C module directly: the sqlite3 package wrapper (dbapi2) would pull
# datetime and collections.abc into every start for adapters this program
# never uses; connect/Row/the error classes are the same objects.
import _sqlite3 as sqlite3

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
    return time.strftime(TS_FMT, time.gmtime())


def parse_ts(value):
    """RFC3339 UTC seconds (fractions dropped) -> epoch seconds. Pure
    arithmetic (no datetime/strptime import); the same strings strptime
    accepted are accepted, anything else raises ValueError."""
    base = value.split(".")[0].rstrip("Z") + "Z" if "." in value else value
    if len(base) != 20 or base[4] != "-" or base[7] != "-" or base[10] != "T" or base[13] != ":" or base[16] != ":" or base[19] != "Z":
        raise ValueError("time data %r does not match format %r" % (value, TS_FMT))
    y, m, d = int(base[0:4]), int(base[5:7]), int(base[8:10])
    hh, mm, ss = int(base[11:13]), int(base[14:16]), int(base[17:19])
    leap = (y % 4 == 0 and y % 100 != 0) or y % 400 == 0
    mdays = (31, 29 if leap else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
    if not (1 <= m <= 12 and 1 <= d <= mdays[m - 1] and hh < 24 and mm < 60 and ss < 62):
        raise ValueError("time data %r does not match format %r" % (value, TS_FMT))
    # days from civil (proleptic Gregorian), then seconds
    yy = y - (1 if m <= 2 else 0)
    era = (yy if yy >= 0 else yy - 399) // 400
    yoe = yy - era * 400
    doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    days = era * 146097 + doe - 719468
    return days * 86400 + hh * 3600 + mm * 60 + ss


def plus_seconds(value, seconds):
    return time.strftime(TS_FMT, time.gmtime(parse_ts(value) + int(seconds)))


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
BUDGET_KEYS = ("max_attempts", "max_seconds", "max_tokens", "max_turns", "max_tool_calls", "max_cost")
# usage.<key> on any event -> budgets.<counter> (additive; #810 scheduler reports them through run.budget)
USAGE_KEYS = (("tokens", "tokens_used"), ("seconds", "seconds_used"), ("turns", "turns_used"),
              ("tool_calls", "tool_calls_used"), ("cost", "cost_used"))
BUDGET_PAIRS = (("max_attempts", "attempts_used"), ("max_seconds", "seconds_used"), ("max_tokens", "tokens_used"),
                ("max_turns", "turns_used"), ("max_tool_calls", "tool_calls_used"), ("max_cost", "cost_used"))


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
                    "max_turns": None, "max_tool_calls": None, "max_cost": None,
                    "attempts_used": 0, "seconds_used": 0, "tokens_used": 0,
                    "turns_used": 0, "tool_calls_used": 0, "cost_used": 0, "exhausted": []},
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
        # Any run.* event may carry payload.metadata (shallow merge): the
        # scheduler (#810) records not_before, lease owner, heartbeat_at, ...
        # on the same event as the state change.
        if etype.startswith("run.") and isinstance(payload.get("metadata"), dict):
            snap["metadata"].update(payload["metadata"])
        if etype in ("run.created", "run.budget") and isinstance(payload.get("budget"), dict):
            for key in BUDGET_KEYS:
                value = payload["budget"].get(key)
                if isinstance(value, (int, float)) and not isinstance(value, bool):
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
            for key, target in USAGE_KEYS:
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
    for key, used in BUDGET_PAIRS:
        limit = budgets[key]
        if isinstance(limit, (int, float)) and not isinstance(limit, bool) and limit > 0 and budgets[used] >= limit:
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


def cmd_runs(args):
    """Snapshot JSON of every projected run, optionally filtered by state,
    in projection-row order (rowid = first projection = enqueue order)."""
    conn = open_db()
    states = [s for s in (args.get("states") or []) if s]
    if states:
        marks = ",".join("?" for _ in states)
        rows = conn.execute("SELECT snapshot_json FROM projections WHERE state IN (%s) ORDER BY rowid" % marks, states)
    else:
        rows = conn.execute("SELECT snapshot_json FROM projections ORDER BY rowid")
    for row in rows:
        sys.stdout.write(row["snapshot_json"] + "\n")


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
    """expected_state given: the guarded update (the row must still be in
    that state). expected_state absent: one round trip — the transition is
    checked here against the approval table passed in (bash re-runs
    ordo_contracts_transition to print the contracts error on refusal) and
    the event, built before the run was known, is bound to the row's run."""
    approval_id = args["approval_id"]
    new_state = args["state"]
    expected = args.get("expected_state")
    event = args["event"]
    now = args["now"]
    conn = open_db()
    begin(conn)
    try:
        row = get_approval(conn, approval_id)
        if expected is None:
            table = args.get("approval_transitions") or {}
            if new_state not in table.get(row["state"], []):
                fail("invalid_transition", "transition %s -> %s is not allowed in table approval" % (row["state"], new_state),
                     {"table": "approval", "from": row["state"], "to": new_state, "approval_id": approval_id})
            bind_event_run(event, row["run_id"])
        elif row["state"] != expected:
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


# --- batched commands (#817) -----------------------------------------------
# One python3 process for a whole scheduler/approval step: a read-only view
# of everything a tick needs, and a multi-operation write transaction.

PLACEHOLDER_RUN_ID = "run_000000000000000000000000"


def new_event_id():
    return "event_" + os.urandom(12).hex()


def bind_event_run(event, run_id):
    """Lease ops built without knowing the run bind the run id here (the
    lease row is the source of truth); correlation_id follows when it was
    defaulted to the placeholder."""
    if event.get("run_id") != run_id:
        if event.get("correlation_id") == event.get("run_id"):
            event["correlation_id"] = run_id
        event["run_id"] = run_id


def batch_lease_acquire(conn, op, now):
    lease = op["lease"]
    event = op["event"]
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
    return lease, lease["run_id"]


def apply_lease_change(conn, row, new_state, bump, ttl, now, event):
    """The guarded update + event of lease_update, on an already fetched row."""
    lease = json.loads(row["lease_json"])
    lease["state"] = new_state
    if bump:
        lease["generation"] = int(lease.get("generation", 0)) + 1
        lease["heartbeat_at"] = now
        lease["ttl_seconds"] = int(ttl or lease.get("ttl_seconds") or 0)
        lease["expires_at"] = plus_seconds(now, lease["ttl_seconds"])
    lease["updated_at"] = now
    conn.execute(
        "UPDATE leases SET state = ?, expires_at = ?, heartbeat_at = ?, generation = ?, lease_json = ? WHERE lease_id = ?",
        (lease["state"], lease["expires_at"], lease["heartbeat_at"], lease.get("generation", 0), dumps(lease), lease["id"]))
    payload = event.setdefault("payload", {})
    payload.update({"lease_id": lease["id"], "owner": lease["owner"], "state": lease["state"],
                    "expires_at": lease["expires_at"], "generation": lease.get("generation", 0)})
    insert_event(conn, event)
    return lease


def batch_lease_change(conn, op, new_state, bump, now, table):
    """renew / release / expire inside a batch. The guards are those of the
    single-lease commands (not_found 4, lease_lost / lease_stale 8, the lease
    transition table 5). With "lenient": true a lease that is no longer live
    is skipped instead of failing the batch, and a live lease past its expiry
    is expired (lease.expired) instead — the scheduler's best-effort release."""
    lease_id = op["lease_id"]
    lenient = bool(op.get("lenient"))
    event = op["event"]
    row = conn.execute("SELECT * FROM leases WHERE lease_id = ?", (lease_id,)).fetchone()
    if not row:
        if lenient:
            return {"lease_id": lease_id, "skipped": "not_found"}, None
        fail("not_found", "unknown lease %s" % lease_id, {"lease_id": lease_id})
    if op.get("run_id") and row["run_id"] != op["run_id"]:
        fail("conflict", "lease %s belongs to run %s, not %s" % (lease_id, row["run_id"], op["run_id"]),
             {"lease_id": lease_id, "run_id": row["run_id"], "expected_run_id": op["run_id"]})
    run_id = row["run_id"]
    bind_event_run(event, run_id)
    state, expires = row["state"], row["expires_at"]
    if new_state != "expired":
        if state == "expired":
            if lenient:
                return {"lease_id": lease_id, "skipped": "lease_lost"}, None
            fail("lease_lost", "lease %s has expired" % lease_id,
                 {"lease_id": lease_id, "state": state, "expires_at": expires})
        if state != "released" and expires < now:
            if lenient:
                expired_event = dict(event)
                expired_event["id"] = new_event_id()
                expired_event["type"] = "lease.expired"
                expired_event["payload"] = dict(event.get("payload") or {})
                lease = apply_lease_change(conn, row, "expired", False, None, now, expired_event)
                return {"lease_id": lease_id, "skipped": "lease_stale", "expired": lease}, run_id
            fail("lease_stale", "lease %s is past its expiry (%s < %s); run expire_stale" % (lease_id, expires, now),
                 {"lease_id": lease_id, "state": state, "expires_at": expires, "now": now})
    allowed = table.get(state, [])
    if new_state not in allowed:
        if lenient:
            return {"lease_id": lease_id, "skipped": "invalid_transition"}, None
        fail("invalid_transition", "transition %s -> %s is not allowed in table lease" % (state, new_state),
             {"table": "lease", "from": state, "to": new_state, "allowed": allowed, "terminal": len(allowed) == 0})
    lease = apply_lease_change(conn, row, new_state, bump, op.get("ttl"), now, event)
    return lease, run_id


def cmd_batch(args):
    """Several journal operations in ONE transaction, in order:
      {"op":"append","event":{...}}
      {"op":"lease_acquire","lease":{...},"event":{...}}
      {"op":"lease_renew"|"lease_release"|"lease_expire","lease_id":..,"event":{...},
       ["run_id":..],["ttl":N],["lenient":true]}
    Any failure rolls the whole batch back (details.batch_index names the
    op); a duplicate idempotency key is duplicate_event exactly as append.
    Projections of every touched run are refreshed once, after the last op."""
    ops = args.get("ops") or []
    now = args["now"]
    table = args.get("lease_transitions") or {}
    conn = open_db()
    begin(conn)
    results = []
    touched = []
    index = -1
    try:
        for index, op in enumerate(ops):
            kind = op.get("op")
            if kind == "append":
                event = insert_event(conn, op["event"])
                results.append(event)
                run_id = event["run_id"]
            elif kind == "lease_acquire":
                result, run_id = batch_lease_acquire(conn, op, now)
                results.append(result)
            elif kind in ("lease_renew", "lease_release", "lease_expire"):
                new_state = {"lease_renew": "renewed", "lease_release": "released", "lease_expire": "expired"}[kind]
                result, run_id = batch_lease_change(conn, op, new_state, kind == "lease_renew", now, table)
                results.append(result)
            else:
                fail("bad_argument", "unknown batch op %r" % kind, {"op": kind})
            if run_id and run_id not in touched:
                touched.append(run_id)
        for run_id in touched:
            refresh_projection(conn, run_id, args)
        commit(conn)
    except JournalError as err:
        rollback(conn)
        err.details = dict(err.details or {})
        err.details["batch_index"] = index
        raise
    if args.get("format") == "lines":
        for result in results:
            sys.stdout.write(dumps(result) + "\n")
    else:
        emit({"results": results, "touched": touched})


def cmd_tick_view(args):
    """Everything a scheduler tick reads, in one document: stale leases
    (as lease_stale), the stored snapshots of the runs in the requested
    states (rowid = enqueue order), the number of worker slots in use
    (leased|running), per-state counts and a run_id -> state map."""
    conn = open_db()
    now = args["now"]
    states = [s for s in (args.get("states") or []) if s]
    stale = []
    for row in conn.execute(
            "SELECT lease_id, run_id, owner, expires_at FROM leases WHERE state IN (?, ?) AND expires_at <= ? ORDER BY rowid",
            (LIVE_LEASE_STATES[0], LIVE_LEASE_STATES[1], now)):
        stale.append({"lease_id": row["lease_id"], "run_id": row["run_id"], "owner": row["owner"], "expires_at": row["expires_at"]})
    if states:
        marks = ",".join("?" for _ in states)
        rows = conn.execute("SELECT snapshot_json FROM projections WHERE state IN (%s) ORDER BY rowid" % marks, states)
    else:
        rows = conn.execute("SELECT snapshot_json FROM projections ORDER BY rowid")
    runs = [json.loads(r["snapshot_json"]) for r in rows]
    counts = {}
    state_map = {}
    for row in conn.execute("SELECT run_id, state FROM projections ORDER BY rowid"):
        counts[row["state"]] = counts.get(row["state"], 0) + 1
        state_map[row["run_id"]] = row["state"]
    slots = counts.get("leased", 0) + counts.get("running", 0)
    emit({"now": now, "stale_leases": stale, "runs": runs, "slots_used": slots, "counts": counts, "states": state_map})


def cmd_approval_view(args):
    """One approval with its run's current state (null when the run is
    unknown) and every event of the run whose payload names the approval."""
    conn = open_db()
    approval_id = args["approval_id"]
    row = get_approval(conn, approval_id)
    run_id = row["run_id"]
    proj = conn.execute("SELECT state FROM projections WHERE run_id = ?", (run_id,)).fetchone()
    if proj:
        run_state = proj["state"]
    else:
        events = load_events(conn, run_id)
        run_state = fold(run_id, events, args.get("transitions") or {}, args.get("project"))["state"] if events else None
    related = []
    for ev_row in conn.execute("SELECT event_json FROM events WHERE run_id = ? ORDER BY run_seq", (run_id,)):
        ev = json.loads(ev_row["event_json"])
        payload = ev.get("payload")
        if isinstance(payload, dict) and payload.get("approval_id") == approval_id:
            related.append(ev)
    emit({"approval": json.loads(row["approval_json"]), "run_id": run_id, "run_state": run_state, "events": related})


COMMANDS = {
    "init": cmd_init, "check": cmd_check, "append": cmd_append, "events": cmd_events,
    "batch": cmd_batch, "tick_view": cmd_tick_view, "approval_view": cmd_approval_view,
    "project": cmd_project, "rebuild_all": cmd_rebuild_all, "state": cmd_state, "runs": cmd_runs,
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
)

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

# _ordo_journal_db_var: sets _OJ_DB (ordo_journal_db_path without a subshell;
# cached per PROJECT/ORCH_STATE_BASE/ORDO_JOURNAL_DB, the directory created once).
_ordo_journal_db_var() {
  local key="${ORDO_JOURNAL_DB:-}|${PROJECT:-}|${ORCH_STATE_BASE:-}"
  if [[ "${_OJ_DB_KEY-}" != "$key" || -z "${_OJ_DB-}" ]]; then
    _OJ_DB=$(ordo_journal_db_path) || return $?
    _OJ_DB_KEY="$key"
  fi
  local dir="${_OJ_DB%/*}"
  [[ "$dir" == "$_OJ_DB" || -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || true
}

# _ordo_journal_pyc_var <pybin>: sets _OJ_PYC to a cached bytecode file of
# the embedded program (compiled once per program version and interpreter,
# under ORDO_JOURNAL_PYC_DIR, default $XDG_CACHE_HOME/ordo/journal-py), or to
# "" when no cache can be used — the program is then fed on stdin as before.
# Compiling the 37 KB program is a third of a python3 start; the cache is
# keyed by sha256 of the program text, so a library upgrade never runs stale
# code. ORDO_JOURNAL_PYC_CACHE=0 disables it. Only files owned by the caller
# (never symlinks) are executed.
_ordo_journal_pyc_var() {
  local pybin="$1"
  if [[ "${_OJ_PYC_KEY-}" == "$pybin|${ORDO_JOURNAL_PYC_DIR:-}|${ORDO_JOURNAL_PYC_CACHE:-1}" ]]; then
    return 0
  fi
  _OJ_PYC="" _OJ_PYC_KEY="$pybin|${ORDO_JOURNAL_PYC_DIR:-}|${ORDO_JOURNAL_PYC_CACHE:-1}"
  [[ "${ORDO_JOURNAL_PYC_CACHE:-1}" == 0 ]] && return 0
  local dir="${ORDO_JOURNAL_PYC_DIR:-}"
  if [[ -z "$dir" ]]; then
    if [[ -n "${XDG_CACHE_HOME:-}" ]]; then dir="$XDG_CACHE_HOME/ordo/journal-py"
    elif [[ -n "${HOME:-}" ]]; then dir="$HOME/.cache/ordo/journal-py"
    else dir="${TMPDIR:-/tmp}/ordo-journal-py-${UID:-0}"; fi
  fi
  local sha
  sha=$(printf '%s\n' "$ORDO_JOURNAL_PY" | sha256sum 2>/dev/null) || return 0
  sha="${sha:0:16}"
  [[ "$sha" =~ ^[0-9a-f]{16}$ ]] || return 0
  local src="$dir/ordo_journal_${sha}.py" pyc="$dir/ordo_journal_${sha}.pyc"
  if [[ -f "$pyc" && -O "$pyc" && ! -L "$pyc" ]]; then
    _OJ_PYC="$pyc"
    return 0
  fi
  [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || return 0
  [[ -d "$dir" && -O "$dir" && ! -L "$dir" && -w "$dir" ]] || return 0
  { printf '%s\n' "$ORDO_JOURNAL_PY" > "$src.$$.tmp" && mv -f "$src.$$.tmp" "$src"; } 2>/dev/null || { rm -f "$src.$$.tmp"; return 0; }
  if "$pybin" -I -S -c 'import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' "$src" "$pyc.$$.tmp" 2>/dev/null \
     && mv -f "$pyc.$$.tmp" "$pyc" 2>/dev/null; then
    _OJ_PYC="$pyc"
  else
    rm -f "$pyc.$$.tmp" 2>/dev/null
  fi
  return 0
}

# _ordo_journal_py <command> [args-json]
# Runs the embedded program. stdout passes through; a JSON error on stderr is
# re-emitted and mapped to the contract exit code; anything else (traceback,
# signal) becomes an internal_error object carrying the raw tail.
_ordo_journal_py() {
  local cmd="${1:?usage: _ordo_journal_py <command> [args-json]}"
  local args="${2:-{\}}"
  local pybin="${ORDO_JOURNAL_PYTHON_BIN:-python3}" found=0
  # Same resolution as `command -v`, without a subshell: a path must be an
  # executable file, a bare name is looked up on PATH.
  if [[ "$pybin" == */* ]]; then
    [[ -x "$pybin" && -f "$pybin" ]] && found=1
  elif hash "$pybin" 2>/dev/null; then
    found=1
  fi
  if [[ "$found" -ne 1 ]]; then
    _ordo_journal_fail missing_dependency "python3 (stdlib sqlite3) is required by the journal" \
      '{"dependency":"python3","hint":"install python3 or set ORDO_JOURNAL_PYTHON_BIN"}'
    return $?
  fi
  _ordo_journal_db_var || return $?
  _ordo_journal_pyc_var "$pybin"
  local rc=0 err out_fd
  # stderr is captured in a variable while stdout passes through a
  # bash-allocated fd (no temp file, no fixed fd a caller may rely on); the
  # inner subshell keeps bash's "Killed" job notice (SIGKILL fault hook)
  # inside the captured stderr instead of the caller's terminal.
  {
    err=$(
      (
        if [[ -n "$_OJ_PYC" ]]; then
          ORDO_JOURNAL_DB="$_OJ_DB" ORDO_JOURNAL_BUSY_TIMEOUT_MS="$ORDO_JOURNAL_BUSY_TIMEOUT_MS" \
          ORDO_JOURNAL_FAULT="$ORDO_JOURNAL_FAULT" ORDO_JOURNAL_NOW="$ORDO_JOURNAL_NOW" \
            "$pybin" -I -S "$_OJ_PYC" "$cmd" "$args"
        else
          ORDO_JOURNAL_DB="$_OJ_DB" ORDO_JOURNAL_BUSY_TIMEOUT_MS="$ORDO_JOURNAL_BUSY_TIMEOUT_MS" \
          ORDO_JOURNAL_FAULT="$ORDO_JOURNAL_FAULT" ORDO_JOURNAL_NOW="$ORDO_JOURNAL_NOW" \
            "$pybin" -I -S - "$cmd" "$args" <<<"$ORDO_JOURNAL_PY"
        fi
      ) 2>&1 >&"$out_fd"
    ) || rc=$?
  } {out_fd}>&1
  exec {out_fd}>&-
  if [[ "$rc" -eq 0 ]]; then
    return 0
  fi
  if [[ -n "$_OJ_PYC" && "$err" == *"Bad magic number"* ]]; then
    # Bytecode of another interpreter version: drop it and run from source.
    rm -f "$_OJ_PYC" 2>/dev/null
    _OJ_PYC="" _OJ_PYC_KEY=""
    ORDO_JOURNAL_PYC_CACHE=0 _ordo_journal_py "$cmd" "$args"
    return $?
  fi
  local code=""
  if [[ "$err" == '{"error":'* ]]; then
    code=$(printf '%s' "$err" | jq -r '.error.code // empty' 2>/dev/null) || code=""
  fi
  if [[ -n "$code" ]]; then
    printf '%s\n' "$err" >&2
    _ordo_contracts_exit_code_var "$code"
    return "$_ORDO_CONTRACTS_EXIT"
  fi
  local tail_text
  tail_text=$(printf '%s\n' "$err" | tail -n 3 | tr '\n' ' ' | cut -c1-400)
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

# _ordo_journal_project_args_load: fills _ORDO_JOURNAL_PROJECT_ARGS in the
# calling shell — the common args of every command that folds a projection:
# the run transition table exported by the contracts library (single source
# of truth) and the project key. Pure function of PROJECT (#817).
_ordo_journal_project_args_load() {
  local project="${PROJECT:-}"
  if [[ -z "${_ORDO_JOURNAL_PROJECT_ARGS:-}" || "${_ORDO_JOURNAL_PROJECT_ARGS_KEY-}" != "$project" ]]; then
    _ORDO_JOURNAL_PROJECT_ARGS=$(jq -cn --argjson transitions "$ORDO_CONTRACTS_TRANSITIONS_RUN" --arg project "$project" \
      '{"transitions": $transitions, "project": (if $project == "" then null else $project end)}')
    _ORDO_JOURNAL_PROJECT_ARGS_KEY="$project"
  fi
}

_ordo_journal_project_args() {
  _ordo_journal_project_args_load
  printf '%s\n' "$_ORDO_JOURNAL_PROJECT_ARGS"
}

# _ordo_journal_args_with <"key":value,...>: sets _OJ_ARGS to the project args
# object extended with the given members (no process spawned).
_ordo_journal_args_with() {
  _ordo_journal_project_args_load
  _OJ_ARGS="${_ORDO_JOURNAL_PROJECT_ARGS%\}},${1}}"
}

# _ordo_journal_now_var: sets _OJ_NOW (ordo_journal_now without a subshell).
_ordo_journal_now_var() {
  if [[ -n "${ORDO_JOURNAL_NOW:-}" ]]; then
    _OJ_NOW="$ORDO_JOURNAL_NOW"
  else
    _OJ_NOW=$(ordo_contracts_now)
  fi
}

# The contracts validator as jq definitions only (its last line is the call),
# so builders can validate the objects they create in the same jq run.
# shellcheck disable=SC2016 # the quoted pattern is literal jq text
_ORDO_JOURNAL_VALIDATOR_DEFS="${ORDO_CONTRACTS_JQ_VALIDATOR%%'check($schema; .; "$")'*}"
_ordo_journal_validator_defs() {
  printf '%s' "$_ORDO_JOURNAL_VALIDATOR_DEFS"
}

# _ordo_journal_schemas_load <kind>...: the contract schemas the builders
# embed, loaded into the contracts cache in the calling shell.
_ordo_journal_schemas_load() {
  local kind
  for kind in "$@"; do _ordo_contracts_schema_load "$kind" || return 1; done
}

# _ordo_journal_build_event <run_id> <type> <payload-json> <actor-json> <mutation> <idem-key> <corr-id> <metadata-json>
# Builds and validates the event object (contract kind `event`) in one jq run.
_ordo_journal_build_event() {
  local run_id="$1" type="$2" payload="$3" actor="$4" mutation="$5" key="$6" corr="$7" metadata="$8"
  local id now
  id=$(ordo_contracts_new_id event) || return $?
  _ordo_journal_now_var; now="$_OJ_NOW"
  _ordo_journal_schemas_load event
  local out
  out=$(jq -cn \
    --arg id "$id" --arg now "$now" --arg run_id "$run_id" --arg type "$type" \
    --argjson payload "$payload" --argjson actor "$actor" --argjson mutation "$mutation" \
    --arg key "$key" --arg corr "$corr" --argjson metadata "$metadata" \
    --argjson schema "${_ORDO_CONTRACTS_SCHEMA_CACHE[event]}" "${_ORDO_JOURNAL_VALIDATOR_DEFS}"'
    ({"schema_version": "1", "kind": "event", "id": $id, "created_at": $now,
      "correlation_id": (if $corr == "" then $run_id else $corr end), "actor": $actor,
      "run_id": $run_id, "type": $type, "payload": $payload, "mutation": $mutation}
     + (if $key == "" then {} else {"idempotency_key": $key} end)
     + (if $metadata == {} then {} else {"metadata": $metadata} end)) as $ev
    | ($ev | check($schema; .; "$")) as $errors
    | if ($errors | length) == 0 then $ev else {"__invalid": $errors} end') || return $?
  if [[ "$out" == '{"__invalid":'* ]]; then
    # Same error object ordo_contracts_validate would carry, under this module.
    _ordo_journal_fail invalid_contract "event does not satisfy the event v1 contract" \
      "$(printf '%s' "$out" | jq -c '{"kind": "event", "schema_version": "1", "errors": .__invalid}')"
    return $?
  fi
  printf '%s' "$out"
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
  actor_json=$(_ordo_journal_actor_json "$actor") || return $?
  if [[ "$metadata" == "{}" ]]; then metadata_json="{}"; else metadata_json=$(_ordo_journal_json_arg "$metadata") || return $?; fi
  local event
  event=$(_ordo_journal_build_event "$run_id" "$type" "$payload" "$actor_json" "$mutation" "$key" "$corr" "$metadata_json") || return $?
  _ordo_journal_args_with "\"event\":${event}"
  _ordo_journal_py append "$_OJ_ARGS"
}

# _ordo_journal_append_compact <run_id> <type> <compact-payload-json> <actor-json>
# Internal fast path for callers that built the payload with jq -c and hold
# a normalised actor: ordo_journal_append minus the argument normalisation.
_ordo_journal_append_compact() {
  local event
  event=$(_ordo_journal_build_event "$1" "$2" "$3" "$4" false "" "" '{}') || return $?
  _ordo_journal_args_with "\"event\":${event}"
  _ordo_journal_py append "$_OJ_ARGS"
}

# _ordo_journal_actor_json [actor-arg] -> compact actor JSON (default actor
# without a jq run; anything else normalised like every JSON argument).
_ordo_journal_actor_json() {
  if [[ -z "${1-}" ]]; then
    _ordo_journal_default_actor
    return 0
  fi
  _ordo_journal_json_arg "$1"
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
  if [[ -z "$since" ]]; then
    _ordo_journal_py events "{\"run_id\":\"${run_id}\"}"
  else
    _ordo_journal_py events "{\"run_id\":\"${run_id}\",\"since\":${since}}"
  fi
}

ordo_journal_project() {
  local run_id="${1-}"
  if [[ $# -lt 1 ]]; then
    _ordo_journal_fail usage "usage: ordo_journal_project <run_id>"
    return $?
  fi
  _ordo_journal_require_run_id "$run_id" || return $?
  _ordo_journal_args_with "\"run_id\":\"${run_id}\",\"store\":true"
  _ordo_journal_py project "$_OJ_ARGS"
}

ordo_journal_rebuild_all() {
  _ordo_journal_project_args_load
  _ordo_journal_py rebuild_all "$_ORDO_JOURNAL_PROJECT_ARGS"
}

ordo_journal_state() {
  local run_id="${1-}"
  if [[ $# -lt 1 ]]; then
    _ordo_journal_fail usage "usage: ordo_journal_state <run_id>"
    return $?
  fi
  _ordo_journal_require_run_id "$run_id" || return $?
  _ordo_journal_args_with "\"run_id\":\"${run_id}\""
  _ordo_journal_py state "$_OJ_ARGS"
}

# ordo_journal_runs [--state S[,S...]]
# Prints the stored snapshot of every projected run (one JSON line each,
# enqueue order), optionally restricted to the given states. Reads the
# projections cache only; run ordo_journal_rebuild_all first after a crash.
ordo_journal_runs() {
  local states=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state) states="${2-}"; shift 2 ;;
      *)
        _ordo_journal_fail usage "unknown option for ordo_journal_runs: ${1}" "$(jq -cn --arg opt "$1" '{"option": $opt}')"
        return $?
        ;;
    esac
  done
  _ordo_journal_py runs "$(jq -cn --arg states "$states" '{"states": ($states | split(",") | map(select(. != "")))}')"
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

# _ordo_journal_epoch_var <rfc3339-utc> : sets _OJ_EPOCH to the epoch seconds of a canonical
# `YYYY-MM-DDTHH:MM:SS[.fff]Z` timestamp in pure bash (days-from-civil), the
# same value GNU `date -u -d` gives; returns 1 for any other format so the
# caller falls back to date. No process spawned (#817).
_ordo_journal_epoch_var() {
  local ts="$1"
  [[ "$ts" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?Z$ ]] || return 1
  local y=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]})) d=$((10#${BASH_REMATCH[3]}))
  local hh=$((10#${BASH_REMATCH[4]})) mm=$((10#${BASH_REMATCH[5]})) ss=$((10#${BASH_REMATCH[6]}))
  (( m >= 1 && m <= 12 && d >= 1 && d <= 31 && hh < 24 && mm < 60 && ss < 62 )) || return 1
  local yy=$(( m <= 2 ? y - 1 : y )) era yoe doy doe
  era=$(( (yy >= 0 ? yy : yy - 399) / 400 ))
  yoe=$(( yy - era * 400 ))
  doy=$(( (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1 ))
  doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
  _OJ_EPOCH=$(( (era * 146097 + doe - 719468) * 86400 + hh * 3600 + mm * 60 + ss ))
}

# _ordo_journal_rfc3339_var <epoch>: sets _OJ_TS to the RFC3339 UTC form
# (bash printf %T, pinned to UTC — what `date -u -d @epoch` prints).
_ordo_journal_rfc3339_var() {
  TZ=UTC printf -v _OJ_TS '%(%Y-%m-%dT%H:%M:%SZ)T' "$1"
}

_ordo_journal_add_seconds() {
  # <rfc3339> <seconds> -> rfc3339 (in bash for canonical input; GNU date otherwise)
  if _ordo_journal_epoch_var "$1"; then
    _ordo_journal_rfc3339_var $(( _OJ_EPOCH + $2 ))
    printf '%s\n' "$_OJ_TS"
    return 0
  fi
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
  actor_json=$(_ordo_journal_actor_json "$_OJ_ACTOR") || return $?
  local id eid now expires
  id=$(ordo_contracts_new_id lease) || return $?
  eid=$(ordo_contracts_new_id event) || return $?
  _ordo_journal_now_var; now="$_OJ_NOW"
  expires=$(_ordo_journal_add_seconds "$now" "$ttl")
  _ordo_journal_schemas_load lease event
  # One jq: the lease object, its lease.acquired event, both validated.
  local built
  built=$(jq -cn --arg id "$id" --arg eid "$eid" --arg now "$now" --arg run_id "$run_id" --arg owner "$owner" \
    --arg expires "$expires" --argjson ttl "$ttl" --arg task_id "$_OJ_TASK_ID" --argjson actor "$actor_json" \
    --argjson lschema "${_ORDO_CONTRACTS_SCHEMA_CACHE[lease]}" --argjson eschema "${_ORDO_CONTRACTS_SCHEMA_CACHE[event]}" \
    "${_ORDO_JOURNAL_VALIDATOR_DEFS}"'
    ({"schema_version": "1", "kind": "lease", "id": $id, "created_at": $now, "correlation_id": $run_id,
      "actor": $actor, "run_id": $run_id, "owner": $owner, "state": "active", "expires_at": $expires,
      "heartbeat_at": $now, "ttl_seconds": $ttl, "generation": 0}
     + (if $task_id == "" then {} else {"task_id": $task_id} end)) as $lease
    | {"schema_version": "1", "kind": "event", "id": $eid, "created_at": $now, "correlation_id": $run_id,
       "actor": $actor, "run_id": $run_id, "type": "lease.acquired",
       "payload": {"lease_id": $id, "owner": $owner, "state": "active", "expires_at": $expires, "ttl_seconds": $ttl, "generation": 0},
       "mutation": false} as $event
    | {"lease": $lease, "event": $event, "now": $now,
       "lease_errors": ($lease | check($lschema; .; "$")), "event_errors": ($event | check($eschema; .; "$"))}') || return $?
  if [[ "$built" != *'"lease_errors":[],"event_errors":[]}' ]]; then
    if [[ "$built" != *'"lease_errors":[],'* ]]; then
      ordo_contracts_validate lease "$(printf '%s' "$built" | jq -c .lease)" || return $?   # emits the contracts error
    fi
    _ordo_journal_fail invalid_contract "event does not satisfy the event v1 contract" \
      "$(printf '%s' "$built" | jq -c '{"kind": "event", "schema_version": "1", "errors": .event_errors}')"
    return $?
  fi
  _ordo_journal_args_with "${built:1:-1}"
  _ordo_journal_py lease_acquire "$_OJ_ARGS"
}

ordo_journal_lease_get() {
  local lease_id="${1-}"
  if [[ $# -lt 1 || -z "$lease_id" ]]; then
    _ordo_journal_fail usage "usage: ordo_journal_lease_get <lease_id>"
    return $?
  fi
  _ordo_journal_py lease_get "{\"lease_id\":$(_ordo_journal_json_string "$lease_id")}"
}

ordo_journal_lease_list() {
  local run_id="${1-}"
  if [[ $# -lt 1 ]]; then
    _ordo_journal_fail usage "usage: ordo_journal_lease_list <run_id>"
    return $?
  fi
  _ordo_journal_require_run_id "$run_id" || return $?
  _ordo_journal_py lease_list "{\"run_id\":\"${run_id}\"}"
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
  { read -r state; read -r expires; read -r run_id; } < <(printf '%s' "$current" | jq -r '.state, .expires_at, .run_id')
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
  actor_json=$(_ordo_journal_actor_json "$_OJ_ACTOR") || return $?
  event=$(_ordo_journal_build_event "$run_id" "$etype" "{\"lease_id\":$(_ordo_journal_json_string "$lease_id")}" "$actor_json" false "" "" '{}') || return $?
  local extra
  extra="\"lease_id\":$(_ordo_journal_json_string "$lease_id"),\"event\":${event},\"now\":\"${now}\""
  [[ -n "$_OJ_TTL" ]] && extra="${extra},\"ttl\":${_OJ_TTL}"
  _ordo_journal_args_with "$extra"
  case "$to" in
    renewed) _ordo_journal_py lease_renew "$_OJ_ARGS" ;;
    released) _ordo_journal_py lease_release "$_OJ_ARGS" ;;
    expired) _ordo_journal_py lease_expire "$_OJ_ARGS" ;;
  esac
}

# _ordo_journal_json_string <text> -> JSON string literal (no jq for plain ids).
_ordo_journal_json_string() {
  if [[ "$1" =~ ^[A-Za-z0-9_.:@/+=,-]*$ ]]; then
    printf '"%s"' "$1"
  else
    jq -cn --arg s "$1" '$s'
  fi
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
  local now stale
  now=$(ordo_journal_now)
  stale=$(_ordo_journal_py lease_stale "{\"now\":\"${now}\"}") || return $?
  if [[ -z "$stale" ]]; then
    printf '{"expired":[],"count":0}\n'
    return 0
  fi
  # Every stale lease is expired in ONE transaction (lenient: a lease another
  # sweeper changed meanwhile is skipped, like the per-lease conflict before).
  local ops out rc=0
  ops=$(printf '%s\n' "$stale" | jq -sc 'map({"op": "lease_expire", "lease_id": .lease_id, "lenient": true})')
  local -a actor_opt=()
  [[ -n "$_OJ_ACTOR" ]] && actor_opt=(--actor "$_OJ_ACTOR")
  out=$(ordo_journal_batch "$ops" ${actor_opt[@]+"${actor_opt[@]}"} 2>/dev/null) || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    _ordo_journal_fail internal_error "could not expire stale leases (rc=${rc})" "$(jq -cn --argjson rc "$rc" --argjson ops "$ops" '{"rc": $rc, "leases": ($ops | map(.lease_id))}')"
    return $?
  fi
  printf '%s' "$out" | jq -c '[.results[] | select(has("skipped") | not)] | {"expired": ., "count": length}'
}

# ---------------------------------------------------------------------------
# Batched commands (#817) — one python3 process per step
# ---------------------------------------------------------------------------
# ordo_journal_tick_view [--now TS] [--state S[,S...]]
# The scheduler tick's read phase in one document:
#   {"now": TS, "stale_leases": [{lease_id,run_id,owner,expires_at}...],   (as lease_expire_stale would sweep)
#    "runs": [snapshot...],            projections in the given states, enqueue order (all states when omitted)
#    "slots_used": N,                  runs in leased|running
#    "counts": {state: N}, "states": {run_id: state}}
ordo_journal_tick_view() {
  local now="" states=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --now) now="${2-}"; shift 2 ;;
      --state) states="${2-}"; shift 2 ;;
      *)
        _ordo_journal_fail usage "unknown option for ordo_journal_tick_view: ${1}" "$(jq -cn --arg opt "$1" '{"option": $opt}')"
        return $?
        ;;
    esac
  done
  [[ -n "$now" ]] || now=$(ordo_journal_now)
  _ordo_journal_py tick_view "$(jq -cn --arg now "$now" --arg states "$states" '{"now": $now, "states": ($states | split(",") | map(select(. != "")))}')"
}

# ordo_journal_approval_view <approval_id>
#   {"approval": {...}, "run_id": R, "run_state": S|null, "events": [event...]}
#   events = every event of the run whose payload.approval_id is this approval.
ordo_journal_approval_view() {
  local approval_id="${1-}"
  if [[ $# -lt 1 || -z "$approval_id" ]]; then
    _ordo_journal_fail usage "usage: ordo_journal_approval_view <approval_id>"
    return $?
  fi
  _ordo_journal_args_with "\"approval_id\":$(_ordo_journal_json_string "$approval_id")"
  _ordo_journal_py approval_view "$_OJ_ARGS"
}

# ordo_journal_append_batch <events-json|-|@path> [--actor JSON]
# events: [{"run_id","type","payload",["actor"],["mutation"],["idempotency_key"],["correlation_id"],["metadata"]}...]
# Appends them all in ONE transaction, in order (run_seq per run as if appended
# one by one) and prints the stored events as JSON lines. Any failure — a
# duplicate idempotency key (5 duplicate_event, the existing event on stdout),
# an invalid contract (5), an unknown run id (2) — writes nothing.
ordo_journal_append_batch() {
  local events_arg="${1-}"
  if [[ $# -lt 1 ]]; then
    _ordo_journal_fail usage "usage: ordo_journal_append_batch <events-json|-|@path> [--actor JSON]"
    return $?
  fi
  shift
  local events ops
  events=$(_ordo_journal_json_arg "$events_arg") || return $?
  if ! ops=$(printf '%s' "$events" | jq -c 'if type == "array" and all(.[]; type == "object") then map(. + {"op": "append"}) else error("not an array of objects") end' 2>/dev/null); then
    _ordo_journal_fail bad_argument "ordo_journal_append_batch expects a JSON array of event objects"
    return $?
  fi
  _ordo_journal_batch_run lines "$ops" "$@"
}

# ordo_journal_batch <ops-json|-|@path> [--actor JSON]
# ops: [{"op":"append", <append fields>}
#       {"op":"lease_acquire","run_id","owner",["id"],["ttl"],["task_id"],["actor"]}   (id: caller-minted lease id)
#       {"op":"lease_renew"|"lease_release"|"lease_expire","lease_id",["run_id"],["ttl"],["actor"],["lenient"]}]
# All ops run in ONE transaction, in order; any failure rolls everything back
# (details.batch_index names the op). Lease ops apply the guards of their
# single commands (4 not_found, 8 lease_lost/lease_stale, 5 invalid_transition);
# with "lenient": true a lease that is no longer live is skipped
# ({"skipped": code}) and a live lease past its expiry is expired instead.
# Prints {"results": [event | lease | {"lease_id","skipped"} ...], "touched": [run_id...]}.
ordo_journal_batch() {
  local ops_arg="${1-}"
  if [[ $# -lt 1 ]]; then
    _ordo_journal_fail usage "usage: ordo_journal_batch <ops-json|-|@path> [--actor JSON]"
    return $?
  fi
  shift
  local ops
  ops=$(_ordo_journal_json_arg "$ops_arg") || return $?
  _ordo_journal_batch_run object "$ops" "$@"
}

# _ordo_journal_batch_run <lines|object> <ops-json> [--actor JSON]
_ordo_journal_batch_run() {
  local format="$1" ops="$2"
  shift 2
  _ordo_journal_parse_actor_opt ordo_journal_batch "$@" || return $?
  local actor_json
  actor_json=$(_ordo_journal_actor_json "$_OJ_ACTOR") || return $?
  _ordo_journal_batch_ops "$format" "$ops" "$actor_json"
}

# _ordo_journal_batch_ops <lines|object> <ops-compact-json> <actor-json>
# The batch core (internal entry for callers that build compact ops
# themselves): ONE jq validates the ops, builds every contract object with
# pre-minted ids and validates each against its schema; then ONE python3
# transaction. Two output lines from jq: a failure object (or null) and the
# python args document.
_ordo_journal_batch_ops() {
  local format="$1" ops="$2" actor_json="$3"
  _ordo_journal_now_var
  local now="$_OJ_NOW"
  _ordo_journal_project_args_load
  _ordo_contracts_table_cache_load lease
  _ordo_journal_schemas_load event lease
  # Ids: one urandom read for up to N event ids + N lease ids, N = number
  # of ops (an over-count from payloads containing "op": is harmless).
  local marker='"op":' tmp="${ops//\"op\":/}" count hex
  count=$(( (${#ops} - ${#tmp}) / ${#marker} ))
  (( count < 1 )) && count=1
  hex=$(od -An -N"$((24 * count))" -tx1 /dev/urandom | tr -d ' \n')
  if [[ ${#hex} -ne $((48 * count)) ]]; then
    _ordo_journal_fail internal_error "could not read random bytes from /dev/urandom"
    return $?
  fi
  # Lease expiries: epoch(now) + ttl, formatted by jq (UTC), exactly like
  # _ordo_journal_add_seconds; the epoch is only needed for acquire ops.
  local now_epoch=0
  if [[ "$ops" == *'"op":"lease_acquire"'* ]]; then
    if _ordo_journal_epoch_var "$now"; then now_epoch="$_OJ_EPOCH"; else now_epoch=$(date -u -d "$now" +%s) || return $?; fi
  fi
  local errors args
  { IFS= read -r errors; IFS= read -r args; } < <(jq -cn --argjson ops "$ops" --arg hex "$hex" --arg now "$now" --argjson now_epoch "$now_epoch" \
    --argjson actor "$actor_json" --argjson pargs "$_ORDO_JOURNAL_PROJECT_ARGS" \
    --argjson ltable "$ORDO_CONTRACTS_TRANSITIONS_LEASE" --arg format "$format" \
    --arg default_ttl "$ORDO_JOURNAL_DEFAULT_LEASE_TTL" \
    --argjson eschema "${_ORDO_CONTRACTS_SCHEMA_CACHE[event]}" --argjson lschema "${_ORDO_CONTRACTS_SCHEMA_CACHE[lease]}" \
    "${_ORDO_JOURNAL_VALIDATOR_DEFS}"'
    def event($op; $id; $run_id; $type; $payload):
      {"schema_version": "1", "kind": "event", "id": $id, "created_at": $now,
       "correlation_id": (if ($op.correlation_id // "") == "" then $run_id else $op.correlation_id end),
       "actor": ($op.actor // $actor), "run_id": $run_id, "type": $type, "payload": $payload,
       "mutation": (($op.mutation // false) == true)}
      + (if ($op.idempotency_key // "") == "" then {} else {"idempotency_key": $op.idempotency_key} end)
      + (if ($op.metadata // {}) == {} then {} else {"metadata": $op.metadata} end);
    def plus_seconds($n): ($now_epoch + $n) | strftime("%Y-%m-%dT%H:%M:%SZ");
    def bad($code; $message; $details): {"code": $code, "message": $message, "details": $details};
    # 1. shape and argument checks (the errors ordo_journal_* raise for the same input)
    (if ($ops | type) != "array" or ($ops | length) == 0 or ($ops | all(.[]; type == "object") | not)
     then bad("bad_argument"; "ordo_journal_batch expects a non-empty JSON array of op objects"; {})
     else ([range($ops | length) as $i | $ops[$i] as $op
             | ($op.op // "") as $kind | ($op.run_id // "" | tostring) as $run_id | ($op.ttl // "" | tostring) as $ttl
             | if ($kind | IN("append", "lease_acquire", "lease_renew", "lease_release", "lease_expire") | not)
               then bad("bad_argument"; "unknown batch op \($kind | tojson | .[1:-1]) (append|lease_acquire|lease_renew|lease_release|lease_expire)"; {"op": $kind})
               elif ($kind | IN("append", "lease_acquire")) and ($run_id | test("^run_[0-9a-f]{24}$") | not)
               then bad("bad_argument"; "run_id must be a canonical run id (run_<24 hex>): \($run_id | tojson | .[1:-1])"; {"run_id": $run_id})
               elif ($kind | IN("lease_renew", "lease_release", "lease_expire")) and ($op.lease_id // "") == ""
               then bad("bad_argument"; "batch op \($kind) needs a lease_id"; {"op": $kind})
               elif ($kind | IN("lease_renew", "lease_release", "lease_expire")) and $run_id != "" and ($run_id | test("^run_[0-9a-f]{24}$") | not)
               then bad("bad_argument"; "run_id must be a canonical run id (run_<24 hex>): \($run_id | tojson | .[1:-1])"; {"run_id": $run_id})
               elif $kind == "lease_acquire" and ($op.id // "") != "" and (($op.id | tostring) | test("^lease_[0-9a-f]{24}$") | not)
               then bad("bad_argument"; "lease_acquire id must be a canonical lease id (lease_<24 hex>): \($op.id | tostring | tojson | .[1:-1])"; {"id": ($op.id | tostring)})
               elif $ttl != "" and ($ttl | test("^[1-9][0-9]*$") | not)
               then bad("bad_argument"; "--ttl expects a positive integer number of seconds"; {"ttl": $ttl})
               else empty end] | first // null) end) as $usage_error
    | if $usage_error != null then $usage_error, "" else
      # 2. build + validate
      [range($ops | length) as $i | $ops[$i] as $op
        | ("event_" + $hex[48 * $i : 48 * $i + 24]) as $eid
        | ($op.id // ("lease_" + $hex[48 * $i + 24 : 48 * $i + 48])) as $lid
        | if $op.op == "append" then
            event($op; $eid; $op.run_id; ($op.type // ""); ($op.payload // {})) as $ev
            | {"index": $i, "op": "append", "event": $ev, "errors": ($ev | check($eschema; .; "$")), "kind": "event"}
          elif $op.op == "lease_acquire" then
            (($op.ttl // $default_ttl) | tostring | tonumber) as $ttl
            | plus_seconds($ttl) as $expires
            | ({"schema_version": "1", "kind": "lease", "id": $lid, "created_at": $now, "correlation_id": $op.run_id,
                "actor": ($op.actor // $actor), "run_id": $op.run_id, "owner": ($op.owner // ""), "state": "active",
                "expires_at": $expires, "heartbeat_at": $now, "ttl_seconds": $ttl, "generation": 0}
               + (if ($op.task_id // "") == "" then {} else {"task_id": $op.task_id} end)) as $lease
            | event($op; $eid; $op.run_id; "lease.acquired";
                    {"lease_id": $lease.id, "owner": $lease.owner, "state": "active", "expires_at": $expires,
                     "ttl_seconds": $ttl, "generation": 0}) as $ev
            | ($lease | check($lschema; .; "$")) as $lerr
            | {"index": $i, "op": "lease_acquire", "lease": $lease, "event": $ev,
               "errors": (if ($lerr | length) > 0 then $lerr else ($ev | check($eschema; .; "$")) end),
               "kind": (if ($lerr | length) > 0 then "lease" else "event" end)}
          else
            ($op.run_id // "run_000000000000000000000000") as $run_id
            | event($op; $eid; $run_id; ("lease." + {"lease_renew": "renewed", "lease_release": "released", "lease_expire": "expired"}[$op.op]);
                    {"lease_id": $op.lease_id}) as $ev
            | {"index": $i, "op": $op.op, "lease_id": $op.lease_id, "event": $ev, "errors": ($ev | check($eschema; .; "$")), "kind": "event"}
              + (if ($op.run_id // "") == "" then {} else {"run_id": $op.run_id} end)
              + (if ($op.ttl // "") == "" then {} else {"ttl": ($op.ttl | tostring | tonumber)} end)
              + (if ($op.lenient // false) == true then {"lenient": true} else {} end)
          end] as $built
      | ([$built[] | select((.errors | length) > 0)] | first // null
         | if . == null then null else {"code": "invalid_contract", "message": "batch op does not satisfy the \(.kind) v1 contract",
                                          "details": {"batch_index": .index, "kind": .kind, "schema_version": "1", "errors": .errors}} end),
        ($pargs + {"ops": ($built | map(del(.errors, .kind, .index))), "now": $now, "lease_transitions": $ltable, "format": $format})
      end') || return $?
  if [[ "$errors" != "null" ]]; then
    local code message details
    { IFS= read -r code; IFS= read -r message; IFS= read -r details; } < <(printf '%s' "$errors" | jq -r '.code, .message, (.details | tojson)')
    _ordo_journal_fail "$code" "$message" "$details"
    return $?
  fi
  _ordo_journal_py batch "$args"
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
  actor_json=$(_ordo_journal_actor_json "$_OJ_ACTOR") || return $?
  local id eid now expires
  id=$(ordo_contracts_new_id approval) || return $?
  eid=$(ordo_contracts_new_id event) || return $?
  _ordo_journal_now_var; now="$_OJ_NOW"
  _ordo_journal_schemas_load approval event
  if [[ -n "$_OJ_EXPIRES_AT" ]]; then
    expires="$_OJ_EXPIRES_AT"
  else
    expires=$(_ordo_journal_add_seconds "$now" "${_OJ_TTL:-$ORDO_JOURNAL_DEFAULT_APPROVAL_TTL}")
  fi
  # One jq: the approval object, its approval.requested event, both validated.
  local built
  built=$(jq -cn --arg id "$id" --arg eid "$eid" --arg now "$now" --arg run_id "$run_id" --arg action "$action" \
    --arg principal "$principal" --arg policy "$_OJ_POLICY_VERSION" --arg key "$_OJ_IDEM_KEY" \
    --arg expires "$expires" --argjson actor "$actor_json" \
    --argjson aschema "${_ORDO_CONTRACTS_SCHEMA_CACHE[approval]}" --argjson eschema "${_ORDO_CONTRACTS_SCHEMA_CACHE[event]}" \
    "${_ORDO_JOURNAL_VALIDATOR_DEFS}"'
    {"schema_version": "1", "kind": "approval", "id": $id, "created_at": $now, "correlation_id": $run_id,
     "actor": $actor, "run_id": $run_id, "action": $action, "principal": $principal,
     "policy_version": $policy, "state": "pending", "idempotency_key": $key, "expires_at": $expires} as $approval
    | {"schema_version": "1", "kind": "event", "id": $eid, "created_at": $now, "correlation_id": $run_id,
       "actor": $actor, "run_id": $run_id, "type": "approval.requested",
       "payload": {"approval_id": $id, "action": $action, "principal": $principal, "policy_version": $policy, "state": "pending", "expires_at": $expires},
       "mutation": false} as $event
    | {"approval": $approval, "event": $event,
       "approval_errors": ($approval | check($aschema; .; "$")), "event_errors": ($event | check($eschema; .; "$"))}') || return $?
  if [[ "$built" != *'"approval_errors":[],"event_errors":[]}' ]]; then
    if [[ "$built" != *'"approval_errors":[],'* ]]; then
      ordo_contracts_validate approval "$(printf '%s' "$built" | jq -c .approval)" || return $?   # emits the contracts error
    fi
    _ordo_journal_fail invalid_contract "event does not satisfy the event v1 contract" \
      "$(printf '%s' "$built" | jq -c '{"kind": "event", "schema_version": "1", "errors": .event_errors}')"
    return $?
  fi
  _ordo_journal_args_with "${built:1:-1}"
  _ordo_journal_py approval_create "$_OJ_ARGS"
}

ordo_journal_approval_get() {
  local approval_id="${1-}"
  if [[ $# -lt 1 || -z "$approval_id" ]]; then
    _ordo_journal_fail usage "usage: ordo_journal_approval_get <approval_id>"
    return $?
  fi
  _ordo_journal_py approval_get "{\"approval_id\":$(_ordo_journal_json_string "$approval_id")}"
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
  _ordo_journal_project_args_load
  # One python3 round trip (#817): the approval is read, its transition
  # checked against the contracts table and the row updated in the same
  # transaction; a refused transition comes back as a marker and the
  # contracts library then prints its own error (same object as before).
  local actor_json decided_by result
  actor_json=$(_ordo_journal_actor_json "$_OJ_ACTOR") || return $?
  if [[ -n "$_OJ_DECIDED_BY" ]]; then decided_by=$(_ordo_journal_json_arg "$_OJ_DECIDED_BY") || return $?; else decided_by="$actor_json"; fi
  if [[ -n "$_OJ_RESULT" ]]; then result=$(_ordo_journal_json_arg "$_OJ_RESULT") || return $?; else result=null; fi
  local now event
  _ordo_journal_now_var; now="$_OJ_NOW"
  # The event's run is bound by the journal from the approval row (placeholder here).
  event=$(_ordo_journal_build_event run_000000000000000000000000 "approval.${to}" "{\"approval_id\":$(_ordo_journal_json_string "$approval_id")}" "$actor_json" false "" "" '{}') || return $?
  local args
  args=$(jq -cn --argjson pargs "$_ORDO_JOURNAL_PROJECT_ARGS" --arg id "$approval_id" --arg to "$to" \
    --argjson event "$event" --arg now "$now" --arg reason "$_OJ_REASON" --argjson decided_by "$decided_by" --argjson result "$result" \
    --argjson table "$ORDO_CONTRACTS_TRANSITIONS_APPROVAL" '
    $pargs + {"approval_id": $id, "state": $to, "event": $event, "now": $now, "approval_transitions": $table,
              "decided_by": $decided_by, "result": $result}
    + (if $reason == "" then {} else {"reason": $reason} end)')
  local err rc=0
  { err=$(_ordo_journal_py approval_set_state "$args" 2>&1 >&"$_OJ_FD"); } {_OJ_FD}>&1 || rc=$?
  exec {_OJ_FD}>&-
  if [[ "$rc" -eq 5 && "$err" == '{"error":{"code":"invalid_transition",'* ]]; then
    local state
    state=$(printf '%s' "$err" | jq -r '.error.details.from // ""')
    ordo_contracts_transition approval "$state" "$to"     # prints the contracts error, returns 5
    return $?
  fi
  [[ -n "$err" ]] && printf '%s\n' "$err" >&2
  return "$rc"
}

# Warm the process-local caches once at load (#817): the three schemas the
# builders embed and the projection args (recomputed if PROJECT changes).
_ordo_journal_schemas_load event lease approval
_ordo_journal_project_args_load
