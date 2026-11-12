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
