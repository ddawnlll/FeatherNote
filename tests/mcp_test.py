#!/usr/bin/env python3
"""Acceptance tests for `feathernote mcp`, a stdio MCP server.

Uses only the Python standard library. Spawns the real binary over pipes and
exercises the JSON-RPC lifecycle, tools, resources, writes, conflicts, and
read-only mode.
"""
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(ROOT, "zig-out", "bin", "feathernote")

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


class Mcp:
    def __init__(self, db_path, allow_write):
        args = [BINARY, "mcp", "--db", db_path]
        if allow_write:
            args.append("--allow-write")
        self.proc = subprocess.Popen(
            args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, bufsize=0,
        )
        self.next_id = 0

    def notify(self, method, params=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self.proc.stdin.write((json.dumps(message) + "\n").encode())
        self.proc.stdin.flush()

    def request(self, method, params=None):
        self.next_id += 1
        message = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            message["params"] = params
        self.proc.stdin.write((json.dumps(message) + "\n").encode())
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError(f"server closed while waiting for {method}")
        return json.loads(line)

    def raw(self, text):
        self.proc.stdin.write((text + "\n").encode())
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        return json.loads(line) if line else None

    def call(self, name, arguments=None):
        response = self.request("tools/call", {"name": name, "arguments": arguments or {}})
        return response["result"]

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=10)
        return self.proc.stderr.read().decode()


def handshake(client, version="2025-06-18"):
    response = client.request("initialize", {
        "protocolVersion": version,
        "capabilities": {},
        "clientInfo": {"name": "feathernote-tests", "version": "1.0"},
    })
    client.notify("notifications/initialized")
    return response


def main():
    if not os.path.isfile(BINARY):
        print(f"missing binary: {BINARY}", file=sys.stderr)
        return 2
    work = tempfile.mkdtemp(prefix="feathernote-mcp-")
    try:
        run(work)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print(f"\n{passed} passed, {len(failed)} failed")
    return 0 if not failed else 1


def run(work):
    db_path = os.path.join(work, "mcp.db")
    subprocess.run(
        [BINARY, "admin", "set-password", "--db", db_path],
        input=b"mcp-test-password\n", check=True, capture_output=True,
    )
    client = Mcp(db_path, allow_write=True)
    try:
        init = handshake(client)
        result = init["result"]
        check("initialize returns the negotiated protocol",
              result["protocolVersion"] == "2025-06-18", result.get("protocolVersion"))
        check("server identifies itself", result["serverInfo"]["name"] == "feathernote")
        check("tools capability advertised", "tools" in result["capabilities"])
        check("resources capability advertised", "resources" in result["capabilities"])

        tools = client.request("tools/list")["result"]["tools"]
        names = {tool["name"] for tool in tools}
        check("write mode exposes 17 tools", len(tools) == 17, len(tools))
        check("all expected tools present", {
            "list_notes", "search_notes", "get_note", "create_note", "update_note",
            "append_note", "attach_file", "delete_attachment", "restore_note",
        } <= names)
        check("tool schemas are objects",
              all(isinstance(tool["inputSchema"], dict) for tool in tools))

        listing = client.call("list_notes")["structuredContent"]
        check("empty library lists zero notes", listing["total"] == 0)

        created = client.call("create_note", {"title": "MCP smoke", "body": "# hello\n\nfrom mcp"})["structuredContent"]
        note = created["note"]
        check("create returns an id and version", note["id"] == 1 and note["version"] == 1, note)
        check("create returns a resource uri", note["uri"] == "feathernote://notes/1")

        fetched = client.call("get_note", {"id": note["id"]})["structuredContent"]
        check("get_note returns the markdown body", fetched["note"]["body"] == "# hello\n\nfrom mcp")
        check("get_note includes attachment list", fetched["attachments"] == [])

        search = client.call("search_notes", {"query": "hello"})["structuredContent"]
        check("FTS search finds the note", search["total"] == 1)
        check("search returns a snippet", "hello" in search["results"][0]["snippet"].lower())

        resources = client.request("resources/list")["result"]["resources"]
        check("resources list exposes the note",
              any(r["uri"] == "feathernote://notes/1" for r in resources))
        templates = client.request("resources/templates/list")["result"]["resourceTemplates"]
        check("resource template advertised",
              templates[0]["uriTemplate"] == "feathernote://notes/{id}")
        resource = client.request("resources/read", {"uri": "feathernote://notes/1"})["result"]
        check("resources/read returns markdown",
              resource["contents"][0]["mimeType"] == "text/markdown"
              and "from mcp" in resource["contents"][0]["text"])

        stale = client.call("update_note", {
            "id": note["id"], "version": 99, "title": "nope", "body": "nope",
        })
        check("stale update is a conflict", stale.get("isError") is True
              and stale["structuredContent"]["error"] == "conflict")
        check("conflict returns the latest note",
              stale["structuredContent"]["latest"]["body"] == "# hello\n\nfrom mcp")

        updated = client.call("update_note", {
            "id": note["id"], "version": 1, "title": "MCP smoke", "body": "version 2",
        })["structuredContent"]["note"]
        check("update advances the version", updated["version"] == 2, updated["version"])

        appended = client.call("append_note", {
            "id": note["id"], "version": 2, "text": "appended line",
        })["structuredContent"]["note"]
        check("append keeps the old body", appended["body"].startswith("version 2"))
        check("append advances the version", appended["version"] == 3)

        pinned = client.call("set_pinned", {
            "id": note["id"], "version": 3, "pinned": True,
        })["structuredContent"]["note"]
        check("set_pinned updates state", pinned["pinned"] is True and pinned["version"] == 4)

        png = b"\x89PNG\r\n\x1a\n" + b"feathernote-mcp-image"
        attached = client.call("attach_file", {
            "note_id": note["id"], "version": 4, "filename": "pixel.png",
            "content_base64": base64.b64encode(png).decode(),
        })["structuredContent"]
        attachment = attached["attachment"]
        check("attach stores a sniffed image", attachment["mime"] == "image/png", attachment)
        check("attach appends a markdown link", "![pixel.png](/files/" in attached["note"]["body"])
        check("attach advances the note version", attached["note"]["version"] == 5)

        files = client.call("list_attachments", {"note_id": note["id"]})["structuredContent"]
        check("list_attachments returns metadata", len(files["attachments"]) == 1)
        got = client.call("get_attachment", {"id": attachment["id"]})["structuredContent"]
        check("get_attachment round-trips bytes",
              base64.b64decode(got["content_base64"]) == png)

        removed = client.call("delete_attachment", {
            "note_id": note["id"], "attachment_id": attachment["id"],
        })["structuredContent"]
        check("delete_attachment reports deletion", removed["deleted"] is True)

        deleted = client.call("delete_note", {"id": note["id"], "version": 5})["structuredContent"]["note"]
        check("delete moves the note to trash", deleted["deleted_at"] is not None)
        trash = client.call("list_trash")["structuredContent"]
        check("trash lists the note", trash["total"] == 1)
        restored = client.call("restore_note", {
            "id": note["id"], "version": deleted["version"],
        })["structuredContent"]["note"]
        check("restore clears deleted_at", restored["deleted_at"] is None)

        theme = client.call("set_theme", {"theme": "ink"})["structuredContent"]
        check("set_theme applies a valid id", theme["theme"] == "ink" and theme["name"] == "Ink")
        bad_theme = client.call("set_theme", {"theme": "not-a-theme"})
        check("set_theme rejects unknown ids", bad_theme.get("isError") is True)

        stats = client.call("get_library_stats")["structuredContent"]
        check("stats report the library", stats["notes"] == 1 and stats["attachments"] == 0)
        omitted = client.request("tools/call", {"name": "get_library_stats"})["result"]
        check("arguments may be omitted for no-arg tools",
              omitted.get("isError") is not True
              and omitted["structuredContent"]["notes"] == 1)

        unknown = client.request("no/such/method")
        check("unknown method returns -32601", unknown.get("error", {}).get("code") == -32601)
        malformed = client.raw("{not json")
        check("malformed JSON returns -32700", malformed.get("error", {}).get("code") == -32700)
        missing = client.call("get_note", {"id": 999999})
        check("missing note is a tool error", missing.get("isError") is True)
        unknown_tool = client.call("no_such_tool")
        check("unknown tool is a tool error", unknown_tool.get("isError") is True)

        stderr = client.close()
    except Exception:
        client.proc.kill()
        raise
    check("logs stay off stdout", "feathernote mcp:" in stderr)

    read_db = os.path.join(work, "readonly.db")
    read_client = Mcp(read_db, allow_write=False)
    try:
        fallback = handshake(read_client, "2099-01-01")["result"]
        check("unsupported protocol version falls back",
              fallback["protocolVersion"] == "2025-06-18", fallback["protocolVersion"])
        read_tools = read_client.request("tools/list")["result"]["tools"]
        read_names = {tool["name"] for tool in read_tools}
        check("read-only mode exposes only read tools", len(read_tools) == 8, len(read_tools))
        check("read-only mode hides create_note", "create_note" not in read_names)
        refused = read_client.call("create_note", {"title": "no", "body": "no"})
        check("read-only mode refuses writes",
              refused.get("isError") is True
              and refused["structuredContent"]["error"] == "writes_disabled")
        read_client.close()
    except Exception:
        read_client.proc.kill()
        raise
    check("database file created", os.path.isfile(db_path))


if __name__ == "__main__":
    sys.exit(main())
