#!/usr/bin/env bash
# tests/fixtures/adapters/stub_server.sh — local HTTP stub for the REST
# provider adapters (#815: forgejo, gitlab). python3 stdlib only, no network
# beyond 127.0.0.1, no third-party module. Lives under tests/fixtures/ so the
# test runners mirror it (they only copy *.sh/*.bash/*.bats/*.md/*.txt plus
# tests/fixtures/**; a bare .py would be left behind).
#
# Usage:
#   stub_server.sh --fixtures DIR --control DIR --forge forgejo|gitlab \
#                  --port-file FILE [--token-file FILE] [--bind 127.0.0.1]
#
# The server binds an ephemeral port on --bind, writes "<port>" to
# --port-file once it is listening and serves until killed.
#
# Fixtures are recorded API responses keyed by METHOD + URL path:
#   DIR/GET/api/v1/repos/acme/widgets/issues/7.json      -> one object
#   DIR/GET/api/v1/repos/acme/widgets/issues.json        -> a collection
#   DIR/GET/api/v1/repos/acme/widgets/actions/jobs/2/logs.txt  -> text/plain
# The URL path is percent-decoded before lookup, so GitLab's
# /projects/acme%2Fwidgets/... maps onto DIR/GET/api/v4/projects/acme/widgets/.
# A .json fixture is served as-is with status 200, unless it is an envelope
#   {"__stub": {"status": 201, "headers": {...}, "body": ...}}
# (status 204 => no body). A missing fixture is a forge-style 404.
#
# Collections (a JSON array, or a Forgejo Actions object {"workflow_runs":[]})
# are filtered by the query parameters the real forges honour (state, labels,
# base/target_branch, ref, sha, status, ...) and paginated exactly like the
# forge: Forgejo `page`/`limit` with X-Total-Count + Link headers; GitLab
# `page`/`per_page` with X-Total/X-Total-Pages/X-Next-Page/X-Page/Link.
#
# Authentication: when --token-file is given every request must carry the
# token in the forge's header (Forgejo `Authorization: token T`, GitLab
# `PRIVATE-TOKEN: T` or `Authorization: Bearer T`); otherwise 401. A token in
# the query string (access_token=, private_token=) is always refused (400) so
# the adapters can prove they never leak the token into URLs. Request headers
# are never written anywhere.
#
# Control directory (failure injection + evidence):
#   DIR/fail.json      one rule or a list of rules
#                      {"method":"GET","path":"/api/v1/repos/acme/widgets/pulls/12",
#                       "path_regex":"...", "status":502, "body":{...}|"text",
#                       "headers":{"Retry-After":"1"}, "times":1, "sleep":0.0}
#                      The first matching rule answers; `times` counts down and
#                      the rule is dropped at 0; `sleep` delays the answer.
#   DIR/requests.jsonl one line per request: ts, method, path, query, body,
#                      status (no headers, ever).
#   DIR/server.log     plain access log (method path status).
set -u
exec python3 - "$@" <<'PY'
import argparse
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

ap = argparse.ArgumentParser()
ap.add_argument("--fixtures", required=True)
ap.add_argument("--control", required=True)
ap.add_argument("--forge", required=True, choices=["forgejo", "gitlab"])
ap.add_argument("--port-file", required=True)
ap.add_argument("--token-file", default="")
ap.add_argument("--bind", default="127.0.0.1")
args = ap.parse_args()

FIXTURES = os.path.abspath(args.fixtures)
CONTROL = os.path.abspath(args.control)
FORGE = args.forge
os.makedirs(CONTROL, exist_ok=True)
LOCK = threading.Lock()

PAGINATION_PARAMS = {"page", "limit", "per_page", "sort", "order_by", "type", "scope", "order", "with_labels_details"}


def expected_token():
    if not args.token_file:
        return None
    try:
        with open(args.token_file, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return None


def not_found_body():
    if FORGE == "forgejo":
        return {"errors": None, "message": "The target couldn't be found.", "url": "https://forge.example/api/swagger"}
    return {"message": "404 Not Found"}


def unauthorized_body():
    if FORGE == "forgejo":
        return {"errors": None, "message": "token is required", "url": "https://forge.example/api/swagger"}
    return {"message": "401 Unauthorized"}


def item_labels(item):
    labels = item.get("labels") or []
    out = []
    for lab in labels:
        if isinstance(lab, dict):
            out.append(str(lab.get("name", "")))
        else:
            out.append(str(lab))
    return out


def user_login(obj):
    if not isinstance(obj, dict):
        return ""
    return str(obj.get("login") or obj.get("username") or "")


def text_of(item, *fields):
    return " ".join(str(item.get(f) or "") for f in fields).lower()


def match_item(item, key, value):
    """Return True when `item` satisfies the query parameter key=value.
    Unknown parameters are ignored (like the forges ignore them)."""
    if FORGE == "forgejo":
        if key == "state":
            return value == "all" or str(item.get("state", "")).lower() == value.lower()
        if key == "labels":
            wanted = [v for v in value.split(",") if v]
            have = item_labels(item)
            return all(w in have for w in wanted)
        if key == "q":
            return value.lower() in text_of(item, "title", "body")
        if key == "milestones":
            ms = item.get("milestone") or {}
            return str(ms.get("title", "")) in value.split(",")
        if key == "created_by" or key == "poster":
            return user_login(item.get("user")) == value
        if key == "assigned_by":
            return any(user_login(a) == value for a in item.get("assignees") or [])
        if key == "head_branch":
            return str(item.get("head_branch", "")) == value
        if key == "head_sha":
            return str(item.get("head_sha", "")) == value
        if key == "status":
            return str(item.get("status", "")).lower() == value.lower()
        if key == "event":
            return str(item.get("event", "")).lower() == value.lower()
        if key == "name":
            return str(item.get("name", "")) == value
        return True
    # gitlab
    if key == "state":
        return value == "all" or str(item.get("state", "")).lower() == value.lower()
    if key == "labels":
        wanted = [v for v in value.split(",") if v]
        have = item_labels(item)
        return all(w in have for w in wanted)
    if key in ("source_branch", "target_branch", "ref", "sha", "source", "username", "title", "name"):
        return str(item.get(key, "")) == value
    if key == "status":
        return str(item.get("status", "")).lower() == value.lower()
    if key == "search":
        return value.lower() in text_of(item, "title", "description")
    if key == "author_username":
        return user_login(item.get("author")) == value
    if key == "assignee_username":
        return any(user_login(a) == value for a in item.get("assignees") or [])
    if key == "milestone":
        ms = item.get("milestone") or {}
        return str(ms.get("title", "")) == value
    if key == "wip":
        return bool(item.get("draft")) == (value == "yes")
    if key == "pipeline_id":
        return str(item.get("pipeline_id", "")) == value
    return True


def filter_items(items, query, path):
    if FORGE == "forgejo" and "state" not in query and (path.endswith("/issues") or path.endswith("/pulls")):
        query = dict(query)
        query["state"] = "open"  # Forgejo lists open issues/pulls by default
    for key, value in query.items():
        if key in PAGINATION_PARAMS:
            continue
        items = [it for it in items if match_item(it, key, value)]
    return items


def paginate(items, query, path):
    total = len(items)
    page = max(int(query.get("page", "1") or 1), 1)
    if FORGE == "forgejo":
        size = int(query.get("limit", "30") or 30)
        size = max(1, min(size, 50))
    else:
        size = int(query.get("per_page", "20") or 20)
        size = max(1, min(size, 100))
    start = (page - 1) * size
    chunk = items[start:start + size]
    pages = max((total + size - 1) // size, 1)
    headers = {}
    links = []
    base = path
    if page < pages:
        links.append('<%s?page=%d&%s=%d>; rel="next"' % (base, page + 1, "limit" if FORGE == "forgejo" else "per_page", size))
    links.append('<%s?page=%d&%s=%d>; rel="last"' % (base, pages, "limit" if FORGE == "forgejo" else "per_page", size))
    if FORGE == "forgejo":
        headers["X-Total-Count"] = str(total)
    else:
        headers["X-Total"] = str(total)
        headers["X-Total-Pages"] = str(pages)
        headers["X-Page"] = str(page)
        headers["X-Per-Page"] = str(size)
        headers["X-Next-Page"] = str(page + 1) if page < pages else ""
        headers["X-Prev-Page"] = str(page - 1) if page > 1 else ""
    headers["Link"] = ", ".join(links)
    return chunk, total, headers


def load_fixture(method, path):
    rel = path.lstrip("/")
    base = os.path.join(FIXTURES, method, rel)
    for candidate, kind in ((base + ".json", "json"), (base + ".txt", "text")):
        if os.path.isfile(candidate):
            with open(candidate, encoding="utf-8") as fh:
                data = fh.read()
            if kind == "json":
                return json.loads(data), "json"
            return data, "text"
    return None, None


def load_fail_rules():
    fpath = os.path.join(CONTROL, "fail.json")
    if not os.path.isfile(fpath):
        return None, fpath
    try:
        with open(fpath, encoding="utf-8") as fh:
            rules = json.load(fh)
    except (OSError, ValueError):
        return None, fpath
    if isinstance(rules, dict):
        rules = [rules]
    return rules, fpath


def take_fail_rule(method, path):
    with LOCK:
        rules, fpath = load_fail_rules()
        if not rules:
            return None
        for idx, rule in enumerate(rules):
            if rule.get("method") and rule["method"].upper() != method:
                continue
            if rule.get("path") and rule["path"] != path:
                continue
            if rule.get("path_regex") and not re.search(rule["path_regex"], path):
                continue
            times = rule.get("times")
            if isinstance(times, int):
                if times <= 0:
                    continue
                rule["times"] = times - 1
                remaining = [r for r in rules if not (isinstance(r.get("times"), int) and r["times"] <= 0)]
                with open(fpath, "w", encoding="utf-8") as fh:
                    json.dump(remaining, fh)
            return rule
    return None


class Handler(BaseHTTPRequestHandler):
    server_version = "ordo-stub/1"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *largs):  # never the default stderr chatter
        with LOCK:
            with open(os.path.join(CONTROL, "server.log"), "a", encoding="utf-8") as fh:
                fh.write("%s %s\n" % (self.command, fmt % largs))

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        if not raw:
            return None
        try:
            return json.loads(raw.decode("utf-8"))
        except ValueError:
            return raw.decode("utf-8", "replace")

    def _send(self, status, body=None, headers=None, kind="json"):
        payload = b""
        if status != 204 and body is not None:
            if kind == "json":
                payload = json.dumps(body).encode("utf-8")
                ctype = "application/json; charset=utf-8"
            else:
                payload = str(body).encode("utf-8")
                ctype = "text/plain; charset=utf-8"
        else:
            ctype = "application/json; charset=utf-8"
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        for k, v in (headers or {}).items():
            self.send_header(k, str(v))
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if payload:
            self.wfile.write(payload)
        return status

    def _authorized(self):
        token = expected_token()
        if token is None:
            return True
        auth = self.headers.get("Authorization") or ""
        if FORGE == "forgejo":
            return auth == "token " + token
        private = self.headers.get("PRIVATE-TOKEN") or ""
        return private == token or auth == "Bearer " + token

    def _record(self, method, path, query, body, status):
        with LOCK:
            with open(os.path.join(CONTROL, "requests.jsonl"), "a", encoding="utf-8") as fh:
                fh.write(json.dumps({
                    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "method": method, "path": path, "query": query, "body": body, "status": status,
                }) + "\n")

    def _handle(self, method):
        parts = urlsplit(self.path)
        path = unquote(parts.path)
        raw_query = parse_qs(parts.query, keep_blank_values=True)
        query = {k: v[-1] for k, v in raw_query.items()}
        body = self._read_body()
        status = self._dispatch(method, path, raw_query, query, body)
        self._record(method, path, query, body, status)

    def _dispatch(self, method, path, raw_query, query, body):
        if any(k in raw_query for k in ("access_token", "private_token", "token")):
            return self._send(400, {"message": "credentials in the query string are forbidden by this stub"})
        rule = take_fail_rule(method, path)
        if rule is not None:
            if rule.get("sleep"):
                time.sleep(float(rule["sleep"]))
            rbody = rule.get("body")
            if rbody is None:
                rbody = {"message": "injected failure %s" % rule.get("status", 500)}
            kind = "json" if not isinstance(rbody, str) else "text"
            return self._send(int(rule.get("status", 500)), rbody, rule.get("headers") or {}, kind)
        if not self._authorized():
            return self._send(401, unauthorized_body())
        data, kind = load_fixture(method, path)
        if data is None:
            return self._send(404, not_found_body())
        if kind == "text":
            return self._send(200, data, {}, "text")
        headers = {}
        status = 200
        if isinstance(data, dict) and "__stub" in data:
            env = data["__stub"]
            status = int(env.get("status", 200))
            headers = dict(env.get("headers") or {})
            data = env.get("body")
            if status == 204 or data is None:
                return self._send(status, None, headers)
        if method == "GET" and isinstance(data, list):
            items = filter_items(data, query, path)
            chunk, _total, pheaders = paginate(items, query, path)
            headers.update(pheaders)
            return self._send(status, chunk, headers)
        if method == "GET" and isinstance(data, dict) and isinstance(data.get("workflow_runs"), list):
            items = filter_items(data["workflow_runs"], query, path)
            chunk, total, pheaders = paginate(items, query, path)
            headers.update(pheaders)
            return self._send(status, {"workflow_runs": chunk, "total_count": total}, headers)
        return self._send(status, data, headers)

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def do_PUT(self):
        self._handle("PUT")

    def do_PATCH(self):
        self._handle("PATCH")

    def do_DELETE(self):
        self._handle("DELETE")


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


httpd = Server((args.bind, 0), Handler)
port = httpd.server_address[1]
tmp = args.port_file + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write("%d\n" % port)
os.replace(tmp, args.port_file)
try:
    httpd.serve_forever(poll_interval=0.2)
except KeyboardInterrupt:
    pass
finally:
    httpd.server_close()
sys.exit(0)
PY
