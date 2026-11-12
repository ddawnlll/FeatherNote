/* FeatherNote shim over vendored MD4C. See feathernote_md.h. */
#include "feathernote_md.h"

#include "md4c-html.h"

#include <stdlib.h>
#include <string.h>

struct fn_buf {
    char* data;
    size_t size;
    size_t cap;
    int err;
};

static void fn_append(const MD_CHAR* data, MD_SIZE size, void* userdata)
{
    struct fn_buf* b = (struct fn_buf*)userdata;
    size_t need;
    size_t ncap;
    char* ndata;

    if (b->err || size == 0) return;
    if (size > (size_t)-1 - b->size - 1) { b->err = 1; return; }
    need = b->size + (size_t)size + 1; /* +1 for the trailing NUL */
    if (need > b->cap) {
        ncap = b->cap ? b->cap : 4096;
        while (ncap < need) {
            if (ncap > (size_t)-1 / 2) { ncap = need; break; }
            ncap *= 2;
        }
        ndata = (char*)realloc(b->data, ncap);
        if (!ndata) { b->err = 1; return; }
        b->data = ndata;
        b->cap = ncap;
    }
    memcpy(b->data + b->size, data, (size_t)size);
    b->size += (size_t)size;
    b->data[b->size] = '\0';
}

int fn_md_render(const char* input, size_t input_size, char** out, size_t* out_size)
{
    struct fn_buf b;
    int ret;

    if (!out || !out_size) return -1;
    *out = NULL;
    *out_size = 0;
    if (input_size > 0 && !input) return -1;

    memset(&b, 0, sizeof(b));
    /* GitHub dialect: tables, task lists, strikethrough, permissive
     * autolinks. XHTML output so void elements are self-closed. */
    ret = md_html(input ? input : "", input_size, fn_append, &b,
                  MD_DIALECT_GITHUB, MD_HTML_FLAG_XHTML);
    if (ret != 0 || b.err) {
        free(b.data);
        return -1;
    }
    if (!b.data) {
        b.data = (char*)malloc(1);
        if (!b.data) return -1;
        b.data[0] = '\0';
        b.size = 0;
    }
    *out = b.data;
    *out_size = b.size;
    return 0;
}

void fn_md_free(char* buf)
{
    free(buf);
}
