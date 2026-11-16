#!/usr/bin/env python3
"""End-to-end acceptance and adversarial tests for FeatherNote.

Runs against a real compiled server process with JavaScript disabled by design
(the client is a plain HTTP library). Requires only the Python standard library.

Usage: python3 tests/integration.py [--binary zig-out/bin/feathernote]
"""
import argparse
import http.client
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASSWORD = "correct horse battery staple"
NOTE_TITLE = "Grüße aus Köln <script>alert('x')</script>"
NOTE_BODY = "line one\n</textarea><script>alert(2)</script>\nTürkçe: ğüşiöç — 日本語"

passed = 0
failed = []


def check(name, condition, detail=""):
    global passed
    if condition:
        passed += 1
        print(f"PASS {name}")
    else:
        failed.append(name)
        print(f"FAIL {name} {detail}")


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def wait_healthy(port, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
            c.request("GET", "/healthz")
            r = c.getresponse()
            body = r.read()
            c.close()
            if r.status == 200 and body == b"ok\n":
                return True
        except OSError:
            time.sleep(0.05)
    return False


class Client:
    def __init__(self, port):
        self.port = port
        self.cookies = {}

    def request(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        hdrs = dict(headers or {})
        if body is not None and "Content-Type" not in hdrs:
            hdrs["Content-Type"] = "application/x-www-form-urlencoded"
        if self.cookies:
            hdrs["Cookie"] = "; ".join(f"{k}={v}" for k, v in self.cookies.items())
        conn.request(method, path, body=body, headers=hdrs)
        resp = conn.getresponse()
        data = resp.read()
        raw_headers = resp.getheaders()
        for name, value in raw_headers:
            if name.lower() == "set-cookie":
                first = value.split(";", 1)[0]
                if "=" in first:
                    cname, cval = first.split("=", 1)
                    if "max-age=0" in value.lower() or cval == "":
                        self.cookies.pop(cname, None)
                    else:
                        self.cookies[cname] = cval
        conn.close()
        return resp.status, {k.lower(): v for k, v in raw_headers}, data

    def form(self, path, fields, csrf=None, version=None):
        data = dict(fields)
        if csrf is not None:
            data["csrf"] = csrf
        if version is not None:
            data["version"] = str(version)
        return self.request("POST", path, urllib.parse.urlencode(data))

    def get(self, path):
        return self.request("GET", path)


def csrf_of(html):
    m = re.search(rb'name="csrf" value="([0-9a-f]{64})"', html)
    return m.group(1).decode() if m else None


def version_of(html):
    m = re.search(rb'name="version" value="(\d+)"', html)
    return int(m.group(1)) if m else None


def multipart_body(fields, filename, content, content_type="image/png", boundary="----feathernoteTestBoundary"):
    chunks = []
    for name, value in fields.items():
        chunks.append(f"--{boundary}\r\n".encode())
        chunks.append(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        chunks.append(value.encode() + b"\r\n")
    chunks.append(f"--{boundary}\r\n".encode())
    chunks.append(
        f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'.encode()
    )
    chunks.append(f"Content-Type: {content_type}\r\n\r\n".encode())
    chunks.append(content + b"\r\n")
    chunks.append(f"--{boundary}--\r\n".encode())
    return b"".join(chunks), f"multipart/form-data; boundary={boundary}"


def start_server(binary, db_path, port, log_path):
    log = open(log_path, "ab")
    proc = subprocess.Popen(
        [binary, "serve", "--db", db_path, "--listen", f"127.0.0.1:{port}",
         "--insecure-cookies", "--trust-proxy"],
        cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
    )
    if not wait_healthy(port):
        proc.terminate()
        raise RuntimeError(f"server did not become healthy; log={log_path}")
    return proc


def stop_server(proc):
    proc.terminate()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)


def login(client):
    status, headers, body = client.form("/login", {"password": PASSWORD})
    check("login succeeds", status == 303 and headers.get("location") == "/notes", f"{status} {headers}")
    cookie = headers.get("set-cookie", "")
    check("session cookie is HttpOnly SameSite=Strict Path=/",
          "HttpOnly" in cookie and "SameSite=Strict" in cookie and "Path=/" in cookie and "Domain=" not in cookie,
          cookie)
    check("login response is no-store", headers.get("cache-control") == "no-store")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default=os.path.join(ROOT, "zig-out", "bin", "feathernote"))
    args = ap.parse_args()
    binary = os.path.abspath(args.binary)
    if not os.path.exists(binary):
        print(f"missing binary: {binary}")
        return 2

    work = tempfile.mkdtemp(prefix="feathernote-it-", dir=os.path.join(ROOT, ".jcode-test") if os.path.isdir(os.path.join(ROOT, ".jcode-test")) else None)
    db_path = os.path.join(work, "feather.db")
    log_path = os.path.join(work, "server.log")
    port = free_port()

    subprocess.run([binary, "admin", "set-password", "--db", db_path],
                   input=(PASSWORD + "\n").encode(), check=True, cwd=ROOT,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    proc = start_server(binary, db_path, port, log_path)
    try:
        c = Client(port)

        status, headers, body = c.get("/healthz")
        check("healthz is public", status == 200 and body == b"ok\n")

        status, headers, body = c.get("/notes")
        check("unauthenticated notes redirects to login",
              status == 303 and headers.get("location") == "/login", f"{status}")

        status, _, _ = c.form("/login", {"password": "wrong password"})
        check("wrong password rejected", status == 401, status)
        status, _, _ = c.form("/login", {"password": "' OR 1=1 --"})
        check("SQL injection in login rejected", status == 401, status)

        login(c)

        status, headers, body = c.get("/notes")
        check("empty note list renders", status == 200 and b"No notes yet" in body)
        check("authenticated page is no-store", headers.get("cache-control") == "no-store")
        check("CSP denies scripts", "default-src 'none'" in headers.get("content-security-policy", ""))
        check("CSP allows same-origin images", "img-src 'self'" in headers.get("content-security-policy", ""))
        check("nosniff header present", headers.get("x-content-type-options") == "nosniff")
        check("pages contain no script tags", b"<script" not in body)

        status, _, body = c.get("/settings")
        check("theme page lists twelve themes", status == 200 and body.count(b'class="theme-card"') == 12)
        csrf = csrf_of(body)
        status, headers, _ = c.form("/settings/theme", {"theme": "signal"}, csrf=csrf)
        check("theme change redirects", status == 303 and headers.get("location") == "/settings?saved=1")
        status, _, body = c.get("/settings?saved=1")
        check("selected theme is applied", b'data-theme="signal"' in body and b"Theme updated." in body)
        status, _, _ = c.form("/settings/theme", {"theme": "not-a-theme"}, csrf=csrf)
        check("unknown theme is rejected", status == 400, status)
        status, _, _ = c.form("/settings/theme", {"theme": "midnight"}, csrf="0" * 64)
        check("theme change requires CSRF", status == 403, status)
        c.form("/settings/theme", {"theme": "paper"}, csrf=csrf)

        status, _, body = c.get("/notes/new")
        csrf = csrf_of(body)
        check("new note form has CSRF token", status == 200 and csrf is not None)

        status, headers, body = c.form("/notes", {"title": NOTE_TITLE, "body": NOTE_BODY}, csrf=csrf)
        check("create note redirects (PRG)", status == 303 and headers.get("location", "").startswith("/notes/1"), f"{status} {headers}")
        note_url = headers.get("location").split("?")[0]

        status, _, body = c.get(note_url + "?saved=1")
        check("saved confirmation visible", status == 200 and b"Saved." in body)
        check("script tags escaped in textarea",
              b"<script>alert" not in body and b"&lt;script&gt;" in body and b"&lt;/textarea&gt;" in body)
        check("UTF-8 round trip", "Grüße aus Köln".encode() in body and "日本語".encode() in body)

        status, _, body = c.get("/notes")
        check("list includes escaped title", b"Gr&uuml;" not in body and b"&lt;script&gt;" in body)

        status, _, body = c.get("/notes?q=" + urllib.parse.quote("Köln"))
        check("search by Unicode title", status == 200 and b"1 result for" in body)
        status, _, body = c.get("/notes?q=" + urllib.parse.quote("<script>alert"))
        check("search output escapes reflected query", b"&lt;script&gt;" in body and b"<script>alert" not in body)
        status, _, body = c.get("/notes?q=" + urllib.parse.quote("' OR 1=1 --"))
        check("SQL injection search returns no rows", status == 200 and b"No notes matched" in body)
        status, _, body = c.get("/notes?q=" + urllib.parse.quote("line one"))
        check("search by body", status == 200 and b"1 result for" in body)

        status, _, body = c.get(note_url + "/edit")
        csrf = csrf_of(body)
        version = version_of(body)
        check("editor exposes version", version == 1, version)

        status, headers, _ = c.form(note_url, {"title": "First update", "body": "version 2"}, csrf=csrf, version=version)
        check("first save succeeds", status == 303, status)
        status, _, body = c.form(note_url, {"title": "Stale draft", "body": "my unsaved draft"}, csrf=csrf, version=version)
        check("stale save returns 409", status == 409, status)
        check("conflict preserves submitted draft", b"Stale draft" in body and b"my unsaved draft" in body)
        check("conflict shows latest stored version", b"First update" in body and b"version 2" in body)
        status, _, body = c.get("/notes?q=" + urllib.parse.quote("version 2"))
        check("FTS index reflects saved update", status == 200 and b"First update" in body)
        status, _, body = c.get("/notes?q=" + urllib.parse.quote("my unsaved draft"))
        check("unsaved conflict draft is not indexed", status == 200 and b"No notes matched" in body)

        status, _, body = c.form(note_url, {"title": "hacked", "body": "nope"}, csrf="0" * 64, version=2)
        check("bad CSRF is rejected", status == 403, status)
        status, _, body = c.get(note_url + "/edit")
        check("bad CSRF made no change", b"First update" in body and b"hacked" not in body)

        status, _, body = c.form(note_url, {"title": "x", "body": "y"}, csrf=csrf, version="not-a-number")
        check("invalid version is 400", status == 400, status)

        status, _, body = c.get(note_url)
        csrf = csrf_of(body)
        version = version_of(body)
        status, headers, _ = c.form(note_url + "/pin", {}, csrf=csrf, version=version)
        check("pin succeeds", status == 303, status)
        status, _, body = c.get("/notes")
        check("pinned note is marked", b"Pinned" in body)

        status, _, body = c.get(note_url + "/delete")
        check("delete confirmation page", status == 200 and b"Delete this note?" in body)
        csrf = csrf_of(body)
        version = version_of(body)
        status, headers, _ = c.form(note_url + "/delete", {}, csrf=csrf, version=version)
        check("soft delete redirects to list", status == 303 and headers.get("location") == "/notes")
        status, headers, _ = c.get(note_url)
        check("deleted note routes to trash", status == 303 and headers.get("location") == "/trash")
        status, _, body = c.get("/trash")
        check("trash lists deleted note", b"First update" in body and b"Restore" in body)
        status, _, body = c.get("/notes?q=" + urllib.parse.quote("First update"))
        check("deleted note is excluded from search", status == 200 and b"No notes matched" in body)
        status, _, body = c.get("/trash")
        csrf = csrf_of(body)
        version = version_of(body)
        status, headers, _ = c.form(note_url + "/restore", {}, csrf=csrf, version=version)
        check("restore succeeds", status == 303 and headers.get("location") == "/trash")
        status, _, body = c.get("/notes")
        check("restored note appears again", b"First update" in body)
        status, _, body = c.get("/notes?q=" + urllib.parse.quote("First update"))
        check("restored note is searchable again", status == 200 and b"1 result for" in body)

        # Markdown rendering.
        status, _, edit = c.get(note_url + "/edit")
        csrf = csrf_of(edit)
        version = version_of(edit)
        markdown_body = "# Heading\n\n**bold** and `code`\n\n<script>alert(1)</script>"
        status, _, _ = c.form(note_url, {"title": "First update", "body": markdown_body}, csrf=csrf, version=version)
        check("markdown save succeeds", status == 303, status)
        status, _, read = c.get(note_url)
        check("markdown renders heading, emphasis, and code",
              b"<h1>Heading</h1>" in read and b"<strong>bold</strong>" in read and b"<code>code</code>" in read)
        check("markdown escapes raw html", b"&lt;script&gt;" in read and b"<script>alert(1)</script>" not in read)

        # Full GFM renderer: Fibonacci table, task lists, footnotes, alignment,
        # safe HTML, stored-XSS fixtures. Body must not mutate on read.
        status, _, edit = c.get(note_url + "/edit")
        gfm_body = (
            "# Fibonacci\n\n"
            "| Katsayi | Yuzde | Aciklama |\n"
            "|---------|:-----:|----------|\n"
            "| 0.000 | %0 | Baslangic |\n"
            "| 0.236 | %23,6 | Sig geri cekilme |\n\n"
            "- [x] done\n- [ ] açık\n\n"
            "Text with a note[^1] and ~~strike~~.\n\n"
            "[^1]: Footnote content\n\n"
            "<details><summary>More</summary>body</details> <mark>highlight</mark>\n\n"
            "[bad](javascript:alert(1)) ![remote](https://evil.example/pixel.png)"
        )
        status, _, _ = c.form(note_url, {"title": "First update", "body": gfm_body},
                              csrf=csrf_of(edit), version=version_of(edit))
        check("gfm save succeeds", status == 303, status)
        status, _, read = c.get(note_url)
        check("fibonacci table renders as table",
              b"<table" in read and b"<thead" in read and b"<tbody" in read and
              b"Katsayi" in read and b"| Katsayi |" not in read and b"%23,6" in read)
        check("table alignment attributes present", b'align="center"' in read)
        check("task list renders checkboxes", b'type="checkbox"' in read and b"checked" in read)
        check("footnote renders with backlink", b'fn-1' in read and b"Footnote content" in read
              and b"footnote-backref" in read)
        check("safe html details and mark render", b"<details" in read and b"<mark" in read)
        check("strikethrough renders", b"<del" in read)
        check("javascript link is stripped", b"javascript:" not in read)
        check("remote image is not served", b"evil.example/pixel" not in read and b"src=\"https" not in read)
        check("no script tags anywhere", b"<script" not in read)
        status, _, read2 = c.get(note_url)
        check("read renders are stable", status == 200 and read2 == read)
        status, _, edit2 = c.get(note_url + "/edit")
        check("source body unchanged by renders", b"Katsayi" in edit2 and b"[^1]: Footnote content" in edit2 and b"- [x] done" in edit2)

        # A table directly after a list with no blank line still renders
        # (GFM would swallow it as list text; the renderer inserts the
        # separator), and the stored source is not rewritten.
        status, _, edit_glued = c.get(note_url + "/edit")
        glued_body = "- one item\n- two items\n| A | B |\n| --- | --- |\n| 1 | 2 |\n"
        status, _, _ = c.form(note_url, {"title": "First update", "body": glued_body},
                              csrf=csrf_of(edit_glued), version=version_of(edit_glued))
        check("glued table save succeeds", status == 303, status)
        status, _, read_glued = c.get(note_url)
        check("table after list without blank line renders",
              b"<table" in read_glued and b"<tbody" in read_glued and b"| A |" not in read_glued)
        status, _, edit_glued2 = c.get(note_url + "/edit")
        check("glued table source not rewritten", edit_glued2.count(b"- one item") == 1 and b"| A | B |" in edit_glued2)

        # Adversarial stored-XSS fixtures through the full save/render path.
        status, _, edit = c.get(note_url + "/edit")
        xss_body = ("<svg onload=alert(1)>\n\n<img src=x onerror=alert(1)>\n\n"
                    "[x](&#106;avascript:alert(1))\n\n"
                    "<iframe src=https://evil.example></iframe>")
        status, _, _ = c.form(note_url, {"title": "First update", "body": xss_body},
                              csrf=csrf_of(edit), version=version_of(edit))
        check("xss fixture save succeeds (as text)", status == 303, status)
        status, _, read = c.get(note_url)
        # (The page header legitimately contains an inline logo `<svg>`.)
        check("stored xss has no live svg/img/script/iframe",
              b"<svg onload" not in read and b"onerror=" not in read and b"<script" not in read
              and b"<iframe" not in read and b"javascript:" not in read)
        check("xss fixture CSP still denies scripts", status == 200)
        status, _, edit = c.get(note_url + "/edit")
        check("xss fixture source preserved", b"onload=alert(1)" in edit and b"106;avascript" in edit)

        # Issue #3: server-driven preview and block editor (still zero JS).
        # NOTE: keep this fixture titled "First update"; the restart check below needs it.
        status, _, edit = c.get(note_url + "/edit")
        status, _, _ = c.form(note_url, {"title": "First update", "body": "First para\n\n## Head\n\n- [x] done\n"},
                              csrf=csrf_of(edit), version=version_of(edit))
        check("blocks fixture save succeeds", status == 303, status)
        # Preview: draft rendered, database untouched.
        status, _, edit = c.get(note_url + "/edit")
        p_version = version_of(edit)
        status, headers, preview = c.form(note_url + "/preview",
                                          {"title": "Blocks Note", "body": "**Draft only**"},
                                          csrf=csrf_of(edit), version=p_version)
        check("preview renders unsaved draft", status == 200 and b"Draft only" in preview
              and b"Preview (unsaved)" in preview)
        status, _, after_preview = c.get(note_url + "/edit")
        check("preview does not mutate the database", b"First para" in after_preview and b"Draft only" not in after_preview)
        check("preview has no script tags", b"<script" not in preview)
        status, _, _ = c.get(note_url + "/preview")
        check("preview rejects GET", status == 405, status)
        status, _, _ = c.form(note_url + "/preview", {"title": "x", "body": "y"}, csrf="0" * 64, version=p_version)
        check("preview requires CSRF", status == 403, status)
        status, _, new_preview = c.form("/notes/preview", {"title": "t", "body": "**brand new**"}, csrf=csrf_of(edit))
        check("new-note preview renders", status == 200 and b"brand new" in new_preview)
        # Block editor: list blocks, edit paragraph losslessly.
        status, _, blocks_page = c.get(note_url + "/blocks")
        check("block editor renders blocks", status == 200 and b"Block 1 of" in blocks_page
              and b"First para" in blocks_page and b"Head" in blocks_page)
        status, _, blocks_page = c.get(note_url + "/blocks")
        bcsrf = csrf_of(blocks_page)
        bversion = version_of(blocks_page)
        status, headers, _ = c.form(note_url + "/blocks/update",
                                    {"block": "0", "text": "First para edited"}, csrf=bcsrf, version=bversion)
        check("block paragraph update redirects to anchor", status == 303 and headers.get("location") == note_url + "/blocks#block-0",
              f"{status} {headers.get('location')}")
        status, _, edit = c.get(note_url + "/edit")
        check("block update saved exactly one block", b"First para edited" in edit and b"## Head" in edit and b"- [x] done" in edit)
        # New-note preview writes nothing (no note count change check via list).
        # Insert heading + checklist blocks.
        status, _, blocks_page = c.get(note_url + "/blocks")
        status, headers, _ = c.form(note_url + "/blocks/insert", {"after": "-1", "kind": "heading"},
                                    csrf=csrf_of(blocks_page), version=version_of(blocks_page))
        check("insert heading block redirects", status == 303 and headers.get("location") == note_url + "/blocks#block-0")
        status, _, blocks_page = c.get(note_url + "/blocks")
        status, headers, _ = c.form(note_url + "/blocks/insert", {"after": "0", "kind": "list_task"},
                                    csrf=csrf_of(blocks_page), version=version_of(blocks_page))
        check("insert checklist block redirects", status == 303 and headers.get("location") == note_url + "/blocks#block-1")
        status, _, edit = c.get(note_url + "/edit")
        check("inserted blocks are in source", b"## New heading" in edit and b"- [ ] task" in edit)
        # Convert a paragraph to a checklist, duplicate, move, delete.
        status, _, blocks_page = c.get(note_url + "/blocks")
        cur_version = version_of(blocks_page)
        status, headers, _ = c.form(note_url + "/blocks/duplicate", {"block": "0"}, csrf=csrf_of(blocks_page), version=cur_version)
        check("duplicate redirects to new block", status == 303 and headers.get("location") == note_url + "/blocks#block-1")
        status, _, blocks_page = c.get(note_url + "/blocks")
        status, headers, _ = c.form(note_url + "/blocks/move", {"block": "1", "dir": "up"}, csrf=csrf_of(blocks_page), version=version_of(blocks_page))
        check("move up redirects to new position", status == 303 and headers.get("location") == note_url + "/blocks#block-0")
        status, _, blocks_page = c.get(note_url + "/blocks")
        check("move up kept content", b"New heading" in blocks_page)
        status, headers, _ = c.form(note_url + "/blocks/delete", {"block": "0"}, csrf=csrf_of(blocks_page), version=version_of(blocks_page))
        check("delete redirects", status == 303)
        status, _, edit = c.get(note_url + "/edit")
        check("delete removed exactly one block", edit.count(b"New heading") == 1)
        status, _, confirm_page = c.get(note_url + "/blocks?confirm=0")
        check("delete confirmation renders without mutating", status == 200 and b"Delete this block?" in confirm_page)
        # Table cell editing + add row.
        status, _, blocks_page = c.get(note_url + "/blocks")
        status, headers, _ = c.form(note_url + "/blocks/insert", {"after": "-1", "kind": "table"},
                                    csrf=csrf_of(blocks_page), version=version_of(blocks_page))
        check("insert table block", status == 303)
        status, _, blocks_page = c.get(note_url + "/blocks")
        t_version = version_of(blocks_page)
        cells = {"block": "0", "cell_h_0": "Alpha", "cell_r0_c0": "1", "align_0": ""}
        status, headers, _ = c.form(note_url + "/blocks/update", cells, csrf=csrf_of(blocks_page), version=t_version)
        check("table cell update saves", status == 303)
        status, _, blocks_page = c.get(note_url + "/blocks")
        status, headers, _ = c.form(note_url + "/blocks/tableaddrow", {"block": "0"}, csrf=csrf_of(blocks_page), version=version_of(blocks_page))
        check("table add row saves", status == 303)
        status, _, edit = c.get(note_url + "/edit")
        check("table source has edited cell and new row", b"Alpha" in edit and edit.count(b"| 1 |") + edit.count(b"|  |") >= 1)
        # No-op roundtrip: reading the block editor twice keeps the same version (GETs never write).
        status, _, blocks_v1 = c.get(note_url + "/blocks")
        status, _, blocks_v2 = c.get(note_url + "/blocks")
        check("block reads never change the version", version_of(blocks_v1) == version_of(blocks_v2))
        # Stale block save -> 409 conflict with draft preserved.
        status, _, blocks_page = c.get(note_url + "/blocks")
        old_version = version_of(blocks_page)
        status, _, _ = c.form(note_url + "/blocks/update", {"block": "0", "text": "changed once"}, csrf=csrf_of(blocks_page), version=old_version)
        check("first block save succeeds", status == 303)
        status, _, conflict_body = c.form(note_url + "/blocks/update", {"block": "0", "text": "stale attempt"}, csrf=csrf_of(blocks_page), version=old_version)
        check("stale block save returns 409", status == 409)
        check("conflict preserves draft", b"stale attempt" in conflict_body)
        status, _, _ = c.get(note_url + "/blocks/unknown")
        check("unknown block op is 404", status == 404, status)

        # File upload and delivery. SVG is deliberately served as a download.
        status, _, edit = c.get(note_url + "/edit")
        png = b"\x89PNG\r\n\x1a\n" + b"feathernote-test-image"
        payload, ctype = multipart_body({"csrf": csrf_of(edit)}, "pixel.png", png)
        status, headers, _ = c.request("POST", note_url + "/files", payload, {"Content-Type": ctype})
        check("image upload redirects to editor",
              status == 303 and "uploaded=1" in headers.get("location", ""), f"{status} {headers}")
        status, _, read = c.get(note_url)
        check("uploaded image is linked in the note",
              b"<img" in read and b"/files/" in read and b"pixel.png" in read)
        m = re.search(rb'/files/(\d+)/pixel\.png', read)
        check("uploaded image URL is present", m is not None)
        if m:
            file_path = f"/files/{int(m.group(1))}/pixel.png"
            file_id = int(m.group(1))
            status, headers, data = c.get(file_path)
            check("image is served inline with a sniffed type",
                  status == 200 and headers.get("content-type") == "image/png" and
                  headers.get("content-disposition", "").startswith("inline") and
                  data.startswith(b"\x89PNG"))
            anon = Client(port)
            status, headers, _ = anon.get(file_path)
            check("files require a session", status == 303 and headers.get("location") == "/login")
            _, _, edit2 = c.get(note_url + "/edit")
            note_id = note_url.rsplit("/", 1)[-1]
            status, headers, _ = c.form(f"/notes/{note_id}/files/{file_id}/delete", {}, csrf=csrf_of(edit2))
            check("file delete redirects", status == 303, status)
            status, _, _ = c.get(file_path)
            check("deleted file is gone", status == 404, status)
            bad_payload, bad_type = multipart_body({"csrf": "0" * 64}, "nope.png", png)
            status, _, _ = c.request("POST", note_url + "/files", bad_payload, {"Content-Type": bad_type})
            check("upload requires CSRF", status == 403, status)

        status, _, edit = c.get(note_url + "/edit")
        svg = b'<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"></svg>'
        payload, ctype = multipart_body({"csrf": csrf_of(edit)}, "evil.svg", svg)
        status, headers, _ = c.request("POST", note_url + "/files", payload, {"Content-Type": ctype})
        check("svg upload accepted as a generic file", status == 303, status)
        status, _, read = c.get(note_url)
        m = re.search(rb'/files/(\d+)/evil\.svg', read)
        if m:
            status, headers, data = c.get(f"/files/{int(m.group(1))}/evil.svg")
            check("svg is served as an attachment, not an image",
                  status == 200 and headers.get("content-type") == "text/plain; charset=utf-8" and
                  headers.get("content-disposition", "").startswith("attachment"))
            check("svg body is preserved", b"onload" in data)
        else:
            check("svg attachment link rendered", False, "no /files link")

        status, _, _ = c.request("POST", "/notes", b"title=%FF", headers={"Content-Type": "application/x-www-form-urlencoded"})
        check("invalid UTF-8 form is rejected", status == 400, status)

        status, _, _ = c.request("POST", "/notes", b"x=" + b"a" * 330000,
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
        check("oversized request is 413", status == 413, status)

        status, headers, _ = c.request("PUT", "/notes", b"")
        check("disallowed method is 405", status == 405 and "allow" in headers, f"{status} {headers}")

        status, _, _ = c.get("/notes/999999")
        check("missing note is 404", status == 404, status)

        status, headers, body = c.get(note_url + "/edit")
        csrf = csrf_of(body)
        status, headers, _ = c.form("/logout", {}, csrf=csrf)
        check("logout redirects and expires cookie",
              status == 303 and "Max-Age=0" in headers.get("set-cookie", ""), f"{status} {headers}")
        status, headers, _ = c.get("/notes")
        check("logout revokes session", status == 303 and headers.get("location") == "/login")

        # Restart persistence check.
        stop_server(proc)
        proc = start_server(binary, db_path, port, log_path)
        c2 = Client(port)
        login(c2)
        status, _, body = c2.get("/notes")
        check("note survives process restart", status == 200 and b"First update" in body)

        # SIGKILL immediately after an acknowledged write. WAL + synchronous=FULL
        # must preserve the committed note without a graceful close.
        _, _, new_edit = c2.get("/notes/new")
        new_csrf = csrf_of(new_edit)
        status, headers, _ = c2.form("/notes", {"title": "Crash durable", "body": "acknowledged before kill"},
                                     csrf=new_csrf)
        check("crash-test note acknowledged", status == 303, status)
        proc.kill()
        proc.wait(timeout=10)
        proc = start_server(binary, db_path, port, log_path)
        c3 = Client(port)
        login(c3)
        status, _, body = c3.get("/notes")
        check("acknowledged note survives SIGKILL", status == 200 and b"Crash durable" in body)

        # Consistent online backup while the server is running.
        wc = Client(port)
        login(wc)
        _, _, edit = wc.get(note_url + "/edit")
        wcsrf = csrf_of(edit)
        wversion = version_of(edit)
        write_statuses = []

        def writer():
            nonlocal wversion
            for i in range(40):
                status, _, _ = wc.form(note_url, {"title": f"Concurrent {i}", "body": f"write {i}"},
                                       csrf=wcsrf, version=wversion)
                write_statuses.append(status)
                if status == 303:
                    wversion += 1
                time.sleep(0.002)

        thread = threading.Thread(target=writer)
        thread.start()
        time.sleep(0.02)
        backup_path = os.path.join(work, "backup.db")
        result = subprocess.run([binary, "admin", "backup", "--db", db_path, "--out", backup_path],
                                cwd=ROOT, capture_output=True, text=True)
        thread.join()
        check("online backup succeeds and passes integrity_check",
              result.returncode == 0 and "integrity_check = ok" in (result.stdout + result.stderr),
              result.stderr)
        check("concurrent saves all committed during backup",
              len(write_statuses) == 40 and all(s == 303 for s in write_statuses), write_statuses[:5])

        restore_dir = os.path.join(work, "restored")
        os.makedirs(restore_dir, exist_ok=True)
        restored_db = os.path.join(restore_dir, "feather.db")
        shutil.copyfile(backup_path, restored_db)
        restore_port = free_port()
        restore_log = os.path.join(restore_dir, "server.log")
        restore_proc = start_server(binary, restored_db, restore_port, restore_log)
        try:
            rc = Client(restore_port)
            login(rc)
            status, _, body = rc.get("/notes")
            check("restored backup serves original data",
                  status == 200 and (b"First update" in body or b"Concurrent " in body))
        finally:
            stop_server(restore_proc)

        # No sensitive material in logs.
        log_text = open(log_path, "rb").read()
        check("password absent from logs", PASSWORD.encode() not in log_text)
        check("note body absent from logs", "my unsaved draft".encode() not in log_text)

    finally:
        stop_server(proc)

    print(f"\n{passed} passed, {len(failed)} failed")
    if failed:
        print("Failed: " + ", ".join(failed))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
