"""A stateful stand-in for FreshRSS's Google Reader API.

    python -I MockServer/mock_freshrss.py [--port 8787] [--host 127.0.0.1]

Then point Folio (Simulator, `folio-dev`, tests) at
http://127.0.0.1:8787/api/greader.php with the username and API password
from MOCK_USER / MOCK_PASSWORD (defaults: demo / folio-demo).

It mirrors the behaviour Folio relies on, as implemented in FreshRSS
p/api/greader.php: ClientLogin -> Auth token, GoogleLogin auth header, the
57-character action token, 401 + Google-Bad-Token on bad auth or token, 501
without output=json, item ids as microsecond numbers (decimal short form,
16-hex long form), HTML in summary.content, continuations only on full pages.
Standard library only.
"""
import argparse
import hashlib
import json
import os
import pathlib
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SEED = pathlib.Path(__file__).resolve().parent / "seed.json"
READ = "user/-/state/com.google/read"
STARRED = "user/-/state/com.google/starred"
READING_LIST = "user/-/state/com.google/reading-list"
LONG_PREFIX = "tag:google.com,2005:reader/item/"


class Store:
    def __init__(self, seed: dict, user: str, password: str):
        self.user = user
        self.password = password
        digest = hashlib.sha1(f"{user}:{password}".encode()).hexdigest()
        self.auth = f"{user}/{digest}"
        self.action_token = digest + "Z" * 17
        self.categories = seed["categories"]
        self.feeds = seed["feeds"]
        self.articles = {a["id"]: dict(a) for a in seed["articles"]}
        # Shift dates so the newest article is two hours old: the demo stays fresh.
        shift = int(time.time()) - 7200 - max(a["published"] for a in self.articles.values())
        for a in self.articles.values():
            a["published"] += shift
            a.setdefault("crawl", a["published"] * 1000)

    def feed(self, feed_id: str) -> dict:
        return next(f for f in self.feeds if f["id"] == feed_id)

    def label(self, category_id: str) -> str:
        return next(c["label"] for c in self.categories if c["id"] == category_id)

    def in_stream(self, article: dict, stream: str) -> bool:
        if stream == READING_LIST:
            return True
        if stream == STARRED:
            return article["starred"]
        if stream == READ:
            return article["read"]
        if stream.startswith("feed/"):
            return article["feed"] == stream
        if "/label/" in stream:
            return stream in self.feed(article["feed"])["categories"]
        return False

    def select(self, stream: str, q: dict) -> list:
        items = [a for a in self.articles.values() if self.in_stream(a, stream)]
        for xt in q.get("xt", []):
            items = [a for a in items if not self.in_stream(a, xt)]
        for it in q.get("it", []):
            items = [a for a in items if self.in_stream(a, it)]
        ot = int(q.get("ot", ["0"])[0] or 0)
        nt = int(q.get("nt", ["0"])[0] or 0)
        items = [a for a in items if a["published"] >= ot and (not nt or a["published"] <= nt)]
        oldest_first = q.get("r", [""])[0] == "o"
        items.sort(key=lambda a: int(a["id"]), reverse=not oldest_first)
        cont = q.get("c", [None])[0]
        if cont:
            items = [a for a in items if (int(a["id"]) > int(cont) if oldest_first else int(a["id"]) < int(cont))]
        return items

    def item_json(self, a: dict) -> dict:
        feed = self.feed(a["feed"])
        cats = [READING_LIST] + feed["categories"]
        if a["read"]:
            cats.append(READ)
        if a["starred"]:
            cats.append(STARRED)
        return {
            "id": LONG_PREFIX + format(int(a["id"]), "016x"),
            "crawlTimeMsec": str(a["crawl"]),
            "timestampUsec": str(a["crawl"] * 1000),
            "published": a["published"],
            "title": a["title"],
            "canonical": [{"href": a["url"]}],
            "alternate": [{"href": a["url"]}],
            "categories": cats,
            "origin": {"streamId": feed["id"], "htmlUrl": feed["htmlUrl"], "title": feed["title"]},
            "summary": {"content": a["html"]},
            "author": a.get("author", ""),
        }


def short_id(raw: str):
    try:
        if raw.startswith(LONG_PREFIX):
            return str(int(raw[len(LONG_PREFIX):], 16))
        return str(int(raw))
    except ValueError:
        return None


class Handler(BaseHTTPRequestHandler):
    store: Store = None  # set in main
    server_version = "FolioMock/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("mock: " + fmt % args + "\n")

    # -- helpers -------------------------------------------------------------
    def reply(self, status: int, body, content_type="application/json; charset=UTF-8", headers=None):
        data = body if isinstance(body, bytes) else (
            json.dumps(body, ensure_ascii=False).encode() if not isinstance(body, str) else body.encode())
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def unauthorized(self):
        self.reply(401, "Unauthorized!", "text/plain; charset=UTF-8", {"Google-Bad-Token": "true"})

    def authorized(self) -> bool:
        header = self.headers.get("Authorization", "")
        return header == f"GoogleLogin auth={self.store.auth}"

    def route(self, method: str):
        parsed = urllib.parse.urlsplit(self.path)
        q = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
        if method == "POST":
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length).decode()
            for k, v in urllib.parse.parse_qs(body, keep_blank_values=True).items():
                q.setdefault(k, []).extend(v)
        prefix = "/api/greader.php/"
        if not parsed.path.startswith(prefix):
            return self.reply(404, "Not found", "text/plain")
        path = urllib.parse.unquote(parsed.path[len(prefix):])
        s = self.store

        if path == "accounts/ClientLogin":
            if q.get("Email", [""])[0] == s.user and q.get("Passwd", [""])[0] == s.password:
                return self.reply(200, f"SID={s.auth}\nLSID=null\nAuth={s.auth}\n", "text/plain; charset=UTF-8")
            return self.unauthorized()
        if not self.authorized():
            return self.unauthorized()
        json_paths = ("reader/api/0/subscription/list", "reader/api/0/tag/list", "reader/api/0/unread-count",
                      "reader/api/0/stream/items/ids")
        if path in json_paths and q.get("output", [""])[0] != "json":
            return self.reply(501, "Not implemented", "text/plain")

        if path == "reader/api/0/token":
            return self.reply(200, s.action_token + "\n", "text/plain; charset=UTF-8")
        if path == "reader/api/0/user-info":
            return self.reply(200, {"userId": "1", "userName": s.user, "userProfileId": "1", "userEmail": ""})
        if path == "reader/api/0/subscription/list":
            return self.reply(200, {"subscriptions": [{
                "id": f["id"], "title": f["title"],
                "categories": [{"id": c, "label": s.label(c)} for c in f["categories"]],
                "url": f["url"], "htmlUrl": f["htmlUrl"], "iconUrl": ""} for f in s.feeds]})
        if path == "reader/api/0/tag/list":
            tags = [{"id": STARRED}]
            tags += [{"id": c["id"], "type": "folder"} for c in s.categories]
            return self.reply(200, {"tags": tags})
        if path == "reader/api/0/unread-count":
            counts = {}
            for a in s.articles.values():
                if a["read"]:
                    continue
                feed = s.feed(a["feed"])
                for key in [feed["id"], READING_LIST] + feed["categories"]:
                    counts[key] = counts.get(key, 0) + 1
            return self.reply(200, {"max": 1000, "unreadcounts": [
                {"id": k, "count": v, "newestItemTimestampUsec": "0"} for k, v in counts.items()]})
        if path == "reader/api/0/stream/items/ids":
            n = int(q.get("n", ["20"])[0])
            items = s.select(q.get("s", [READING_LIST])[0], q)
            page = items[:n]
            body = {"itemRefs": [{"id": a["id"]} for a in page]}
            if len(items) > n:
                body["continuation"] = page[-1]["id"]
            return self.reply(200, body)
        if path == "reader/api/0/stream/items/contents":
            ids = [short_id(i) for i in q.get("i", [])]
            items = [s.item_json(s.articles[i]) for i in ids if i in s.articles]
            return self.reply(200, {"id": "user/-/state/com.google/reading-list", "updated": int(time.time()), "items": items})
        if path.startswith("reader/api/0/stream/contents"):
            stream = path[len("reader/api/0/stream/contents/"):] or q.get("s", [READING_LIST])[0]
            n = int(q.get("n", ["20"])[0])
            items = s.select(stream, q)
            page = items[:n]
            body = {"id": stream, "updated": int(time.time()), "items": [s.item_json(a) for a in page]}
            if len(items) > n:
                body["continuation"] = page[-1]["id"]
            return self.reply(200, body)
        if path == "reader/api/0/edit-tag":
            if method != "POST":
                return self.reply(400, "Bad request", "text/plain")
            if q.get("T", [""])[0] != s.action_token:
                return self.unauthorized()
            for raw in q.get("i", []):
                a = s.articles.get(short_id(raw) or "")
                if not a:
                    continue
                for tag in q.get("a", []):
                    if tag == READ:
                        a["read"] = True
                    if tag == STARRED:
                        a["starred"] = True
                for tag in q.get("r", []):
                    if tag == READ:
                        a["read"] = False
                    if tag == STARRED:
                        a["starred"] = False
            return self.reply(200, "OK", "text/plain; charset=UTF-8")
        if path == "reader/api/0/mark-all-as-read":
            if q.get("T", [""])[0] != s.action_token:
                return self.unauthorized()
            stream = q.get("s", [READING_LIST])[0]
            ts = int(q.get("ts", ["0"])[0] or 0)
            for a in s.articles.values():
                if s.in_stream(a, stream) and (ts == 0 or int(a["id"]) <= ts):
                    a["read"] = True
            return self.reply(200, "OK", "text/plain; charset=UTF-8")
        return self.reply(400, "Bad request", "text/plain")

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    args = parser.parse_args()
    seed = json.loads(SEED.read_text(encoding="utf-8"))
    Handler.store = Store(seed, os.environ.get("MOCK_USER", "demo"), os.environ.get("MOCK_PASSWORD", "folio-demo"))
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"Folio mock FreshRSS on http://{args.host}:{args.port}/api/greader.php "
          f"(user {Handler.store.user})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
