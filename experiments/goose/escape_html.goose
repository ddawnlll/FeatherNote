// FeatherNote Goose experiment 01: byte-for-byte compatible HTML escaping.
//
// This is intentionally NOT a complete Markdown renderer or HTTP backend.
// It isolates the exact behavior of src/http_util.zig::escapeHtml and
// exercises Goose's grow-only, stack-managed output buffers.
//
// Build: goose build -o /tmp/feather-goose-escape experiments/goose/escape_html.goose
// Run:   printf '<a>&"\047' | /tmp/feather-goose-escape
//
// Source: FeatherNote master 8961d45e98984121d8c617d310374e502cdaf049

import std;
import os;

fn escape_html(out: u8[>..]&, input: const u8[:]) {
    for ch in input {
        if ch == '&' { out.append("&amp;"); }
        else if ch == '<' { out.append("&lt;"); }
        else if ch == '>' { out.append("&gt;"); }
        else if ch == '"' { out.append("&quot;"); }
        else if ch == '\'' { out.append("&#39;"); }
        else { out.push(ch); }
    }
}

fn main() {
    var input: u8[>..] = [];
    read_stdin(input);

    var html: u8[>..] = [];
    escape_html(html, input);
    write_stdout(html);
}
