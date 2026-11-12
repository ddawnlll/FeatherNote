/* FeatherNote shim over vendored MD4C (MIT, see LICENSE.md).
 *
 * This thin bridge exists so Zig talks to a plain C API with an owned,
 * NUL-terminated output buffer instead of C function-pointer callbacks.
 * All rendering flags are fixed here: MD4C is used with its GitHub dialect
 * (permissive autolinks, tables, strikethrough, task lists) and XHTML output.
 *
 * The caller owns the returned buffer and must call fn_md_free() on it.
 * Returns 0 on success, non-zero on failure (no partial output is returned).
 */
#ifndef FEATHERNOTE_MD_H
#define FEATHERNOTE_MD_H

#include <stddef.h>

int fn_md_render(const char* input, size_t input_size, char** out, size_t* out_size);
void fn_md_free(char* buf);

#endif
