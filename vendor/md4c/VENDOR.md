# Vendored MD4C

MD4C 0.5.3 (release-0.5.3), MIT licensed. Copyright 2016-2024 Martin Mitas.

- Upstream: https://github.com/mity/md4c
- Tag: `release-0.5.3`, commit `093c3f45ce44bd6661849982b1dd7f0e7f385621`
- Release tarball: https://github.com/mity/md4c/archive/refs/tags/release-0.5.3.tar.gz
- Tarball SHA-256: `353c346f376b87c954a13f3415ede2d51264cc61dc5abcd38ff1d2aa0d059b9e`
- Per-file SHA-256: see `CHECKSUMS.txt`

Files used: `md4c.h`, `md4c.c`, `md4c-html.h`, `md4c-html.c`, `entity.h`,
`entity.c`, `LICENSE.md`. The other files in the upstream tarball (tests,
tools, packaging) are not vendored.

`feathernote_md.h` / `feathernote_md.c` are FeatherNote's own MIT-compatible
bridge that calls `md_html()` with `MD_DIALECT_GITHUB` and
`MD_HTML_FLAG_XHTML` and returns an owned output buffer. It is not upstream
code.
