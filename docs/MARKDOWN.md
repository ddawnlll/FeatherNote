# Markdown and safe HTML support

Notes are stored as Markdown in SQLite and rendered on every read. Parsing is
the vendored MD4C 0.5.3 (GitHub dialect), followed by an allowlist HTML
sanitizer. See `docs/DECISIONS.md` D019 for the rationale and security model.

## Supported

| Feature | Behavior |
|---|---|
| ATX and setext headings H1-H6 | yes |
| Paragraphs, soft/hard line breaks | yes (CommonMark semantics) |
| Emphasis, strong, strikethrough | yes |
| Inline code, fenced code with language, indented code | yes |
| Blockquotes (nested) | yes |
| Ordered/unordered lists, deeply nested, ordered start number | yes |
| Task lists `- [x]` / `- [ ]` | yes, rendered as disabled checkboxes |
| Tables with alignment | yes, responsive scroll region on narrow screens |
| Table directly after a list/paragraph (no blank line) | renders: the renderer inserts the missing blank line at read time (stored Markdown unchanged) |
| Links: inline, reference, autolinks (URL, www, email) | yes |
| Images | same-origin paths only (`/files/...`), refuses remote URLs |
| Horizontal rules | yes |
| Escapes and HTML entities | yes |
| Footnotes `[^label]` with backlinks | yes (FeatherNote extension preprocessor; definitions not referenced are omitted; inside code the syntax stays literal) |
| Safe embedded HTML (see below) | yes, after sanitization |
| Unicode including Turkish characters | yes |

## Safe embedded HTML

Allowlisted elements: `p`, `br`, `hr`, `h1`-`h6`, `strong`, `em`, `del`,
`code`, `pre`, `blockquote`, `ul`, `ol`, `li`, `table`, `thead`, `tbody`,
`tfoot`, `tr`, `th`, `td`, `a`, `img`, `details`, `summary`, `mark`, `kbd`,
`sup`, `sub`, `div`, `span`, `section`, `dl`, `dt`, `dd`, `figure`,
`figcaption`, and checkbox `input` elements.

Allowlisted attributes are validated per element: `href` (http/https,
mailto, same-origin, `#` fragments), `src` (same-origin only), `alt`,
`title`, `align` (left/center/right), `colspan`/`rowspan`/`start`
(digits), `scope` (col/row), `open` on details, plus inert `class`/`id`.
Everything else is dropped, including all `on*` event handlers, `style`,
`srcdoc`, `formaction`, and data URLs. Disallowed elements (`script`,
`style`, `iframe`, `object`, `embed`, `form`, `svg`, `math`, `link`,
`meta`, `base`, ...) are shown as escaped text, never executed, so the
author still sees what they wrote. Comments are removed.

## Editing in blocks (Issue #3)

The Blocks tab edits the same stored Markdown one block at a time, without
JavaScript. See `docs/DECISIONS.md` D020 for the byte-range design. Every
block shows its rendered preview plus its own edit form; unedited blocks
keep their exact bytes.

| Block kind | Block-editor behavior |
|---|---|
| Paragraph | text form |
| Heading H1-H6 | text + level select |
| Unordered / ordered list, checklist | text, one item per line; checklist items keep `[x]`/`[ ]` |
| Blockquote | `>`-prefixed lines |
| Fenced code | code text + optional language |
| Table | cell grid (header cells, data cells, per-column alignment) + add/delete row/column; escaped pipes and code spans preserved |
| Link / image | text + URL/path form |
| Thematic break | delete or convert only |
| Raw (source fallback) | verbatim Markdown textarea |

Raw fallback covers indented code, nested or mixed lists, footnote and
link reference definitions, HTML blocks, and tables over 512 cells: these
still render fully in the read view (table above), they are just edited as
source. Block operations: title save, update, insert, confirmed delete,
move up/down, duplicate, convert between kinds. All are POST with CSRF and
the optimistic version; a stale tab gets 409 with its draft preserved.
Preview draft renders the current text server-side and writes nothing.

## Deliberately unsupported

- **Alerts/admonitions** (`> [!NOTE]`): renders as normal text.
- **Math** (LaTeX spans/blocks): not parsed; `$...$` stays text.
- **Diagrams** (Mermaid, PlantUML): not rendered; fenced code stays code.
- **Syntax highlighting:** language is kept as a `language-...` class only.
- **Wiki links, underline extension, header anchors/IDs, heading slug
  links:** not generated.
- **Raw HTML outside the allowlist:** escaped as text, as described above.

## Security invariants

- The Content Security Policy is unchanged: `default-src 'none'`, no
  `script-src`, `img-src 'self'`. No JavaScript is served by any page.
- Sanitization runs over all rendered HTML, including Markdown-generated
  links and raw note HTML, after entity decoding of attribute values, so
  schemes hidden behind `&#106;avascript:` are still blocked.
- Reading a note never writes to the database. Rendering is a pure function
  of the stored Markdown.
