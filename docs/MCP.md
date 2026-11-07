# FeatherNote MCP server

FeatherNote ships a local [Model Context Protocol](https://modelcontextprotocol.io) server over stdio. It exposes the same SQLite database as the web app, so an MCP client can read and write notes without a browser, an API token, or a network listener.

## Run it

```sh
feathernote mcp --db ~/feathernote-data/feathernote.db
```

That is **read-only**. Add `--allow-write` to expose create, update, delete, restore, attachment, pin, and theme tools.

```sh
feathernote mcp --db ~/feathernote-data/feathernote.db --allow-write
```

The server speaks JSON-RPC 2.0, one JSON object per line, on stdin and stdout. It logs only to stderr. Supported protocol versions are `2025-06-18`, `2025-03-26`, and `2024-11-05`; it echoes a supported client version and otherwise answers with `2025-06-18`.

## Client configuration

### Claude Desktop and Cursor

Add to `claude_desktop_config.json` or `.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "feathernote": {
      "command": "/usr/local/bin/feathernote",
      "args": [
        "mcp",
        "--db",
        "/var/lib/feathernote/feathernote.db",
        "--allow-write"
      ]
    }
  }
}
```

Use the absolute path to the binary and the absolute path to the database. Omit `--allow-write` for a read-only session.

### Codex

Add to `~/.codex/config.toml`:

```toml
[mcp_servers.feathernote]
command = "/usr/local/bin/feathernote"
args = ["mcp", "--db", "/var/lib/feathernote/feathernote.db", "--allow-write"]
```

### Any other MCP client

Start the binary as a stdio subprocess. Do not expose it over TCP. If a client only supports remote MCP, place the process behind an SSH or local bridge rather than adding an unauthenticated network port.

## Tools

Read tools are always present. Write tools appear only with `--allow-write`.

| Tool | Write | Purpose |
|---|---|---|
| `list_notes` | no | Active notes, pinned first, with limit and offset |
| `search_notes` | no | FTS5 search with highlighted snippets |
| `get_note` | no | Full Markdown body, version, timestamps, attachments |
| `list_trash` | no | Soft-deleted notes with restore versions |
| `list_attachments` | no | Attachment metadata for one note |
| `get_attachment` | no | Base64 contents, MIME, size, SHA-256 |
| `get_library_stats` | no | Note, trash, and attachment counts plus theme |
| `get_theme` | no | Current theme id and the full list |
| `create_note` | yes | New title and Markdown body |
| `update_note` | yes | Replace title and body, requires `version` |
| `append_note` | yes | Append Markdown, requires `version` |
| `set_pinned` | yes | Pin or unpin, requires `version` |
| `delete_note` | yes | Move to Trash, requires `version` |
| `restore_note` | yes | Restore from Trash, requires the trash `version` |
| `attach_file` | yes | Base64 upload up to 8 MiB, appends the Markdown link |
| `delete_attachment` | yes | Remove an attachment record |
| `set_theme` | yes | Set a validated theme id |

Every write carries optimistic concurrency. A stale `version` returns `isError: true` with an `error` of `conflict` and the latest stored note, including its body, so the client can merge deliberately.

## Resources

| URI | Contents |
|---|---|
| `feathernote://notes/{id}` | The note body as `text/markdown`, with version, timestamps, and pinned state in `_meta` |

`resources/list` returns up to the 50 most recent active notes. `resources/templates/list` advertises `feathernote://notes/{id}`.

## Concurrency

The web app and MCP server can use the same database at the same time. Both open WAL-mode SQLite connections and serialize writes; the MCP connection uses a 5 second busy timeout. The MCP server does not run migrations differently from the web app: opening the database applies the same versioned migrations.

## Security

- Read-only by default. Writes require an explicit flag.
- No listener, no token, no network surface. The database file permissions are the trust boundary.
- No shell execution and no path arguments from tools.
- Attachment uploads are size-capped at 8 MiB, MIME-sniffed from bytes, filename-sanitized, and stored in SQLite.
- Error messages never include note bodies. The one exception is an explicit conflict result, which returns the latest note so a client can merge.
- Logs go to stderr only; stdout is reserved for protocol messages.
- Bodies and attachments remain plaintext in the database. Protect the file and backups.

## Limits

- One request at a time, in order. MCP clients normally issue sequential calls.
- Messages up to 12 MiB on stdin, enough for an 8 MiB attachment after base64 encoding.
- `search_notes` accepts up to 100 bytes of query, matching the web UI.
- `resources/list` is capped at 50 notes and does not paginate yet.

## Tests

```sh
python3 tests/mcp_test.py
```

The suite drives the real binary over pipes and covers the handshake, tool schemas, read tools, create, update, append, pin, delete, restore, attachment round-trip, theme writes, conflict payloads, malformed JSON, unknown methods, and the read-only gate.
