#ifndef OCTOMARK_C
#define OCTOMARK_C

#include <ctype.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/**
 * OctoMark Native C99 (Turbo Edition)
 * - Restrict pointers for better vectorization.
 * - Stack-based metadata (no malloc for lists/tables).
 * - Advanced SWAR bit-masking for plain text scanning.
 */

// --- Dynamic Buffer Implementation ---
typedef struct {
  char *data;
  size_t size;
  size_t capacity;
} Buffer;

void buf_init(Buffer *b, size_t initial_cap) {
  b->data = (char *)malloc(initial_cap);
  b->size = 0;
  b->capacity = initial_cap;
  if (b->data)
    b->data[0] = '\0';
}

static inline void buf_grow(Buffer *restrict b, size_t needed) {
  if (b->size + needed + 1 > b->capacity) {
    size_t new_cap = b->capacity * 2;
    if (new_cap < b->size + needed + 1)
      new_cap = b->size + needed + 1024;
    b->data = (char *)realloc(b->data, new_cap);
    b->capacity = new_cap;
  }
}

static inline void buf_append_n(Buffer *restrict b, const char *restrict s,
                                size_t n) {
  if (!s || n == 0)
    return;
  buf_grow(b, n);
  memcpy(b->data + b->size, s, n);
  b->size += n;
  b->data[b->size] = '\0';
}

static inline void buf_append(Buffer *restrict b, const char *restrict s) {
  if (!s)
    return;
  buf_append_n(b, s, strlen(s));
}

static inline void buf_push(Buffer *restrict b, char c) {
  buf_grow(b, 1);
  b->data[b->size++] = c;
  b->data[b->size] = '\0';
}

void buf_free(Buffer *b) {
  if (b->data)
    free(b->data);
  b->data = NULL;
  b->size = b->capacity = 0;
}

// --- List Stack (Fixed size for performance) ---
#define MAX_LIST_DEPTH 32
typedef struct {
  int types[MAX_LIST_DEPTH]; // 0 for ul, 1 for ol
  size_t size;
} ListStack;

typedef enum { ALIGN_NONE, ALIGN_LEFT, ALIGN_CENTER, ALIGN_RIGHT } Align;

// --- OctoMark State ---
typedef struct {
  bool special_chars[256];
  const char *escape_table[256];
  bool in_code;
  bool in_math;
  bool in_table;
  Align table_aligns[64];
  size_t table_cols;
  ListStack list_stack;
  bool list_item_open[MAX_LIST_DEPTH];
  Buffer leftover;
} OctoMark;

void octomark_init(OctoMark *om) {
  memset(om, 0, sizeof(OctoMark));
  const char *specs = "\\['*`&<>\"_~!$";
  for (int i = 0; specs[i]; i++)
    om->special_chars[(unsigned char)specs[i]] = true;
  om->special_chars['h'] = true;
  om->escape_table['&'] = "&amp;";
  om->escape_table['<'] = "&lt;";
  om->escape_table['>'] = "&gt;";
  om->escape_table['"'] = "&quot;";
  om->escape_table['\''] = "&#39;";
  buf_init(&om->leftover, 1024);
}

void octomark_free(OctoMark *om) { buf_free(&om->leftover); }

static inline void escape_buf(const OctoMark *restrict om,
                              const char *restrict str, size_t len,
                              Buffer *restrict out) {
  for (size_t i = 0; i < len; i++) {
    const char *esc = om->escape_table[(unsigned char)str[i]];
    if (esc)
      buf_append(out, esc);
    else
      buf_push(out, str[i]);
  }
}

void parse_inline(const OctoMark *restrict om, const char *restrict text,
                  size_t len, Buffer *restrict out);

static inline int find_special_swar(const OctoMark *restrict om,
                                    const char *restrict text, size_t len) {
  size_t i = 0;
  while (i + 7 < len) {
    uint64_t word;
    memcpy(&word, text + i, 8);
    uint64_t specials = 0;
    specials |= (uint64_t)om->special_chars[(word >> 0) & 0xFF] << 0;
    specials |= (uint64_t)om->special_chars[(word >> 8) & 0xFF] << 8;
    specials |= (uint64_t)om->special_chars[(word >> 16) & 0xFF] << 16;
    specials |= (uint64_t)om->special_chars[(word >> 24) & 0xFF] << 24;
    specials |= (uint64_t)om->special_chars[(word >> 32) & 0xFF] << 32;
    specials |= (uint64_t)om->special_chars[(word >> 40) & 0xFF] << 40;
    specials |= (uint64_t)om->special_chars[(word >> 48) & 0xFF] << 48;
    specials |= (uint64_t)om->special_chars[(word >> 56) & 0xFF] << 56;
    if (specials) {
      for (int k = 0; k < 8; k++) {
        if (om->special_chars[(unsigned char)text[i + k]])
          return (int)(i + k);
      }
    }
    i += 8;
  }
  while (i < len) {
    if (om->special_chars[(unsigned char)text[i]])
      return (int)i;
    i++;
  }
  return -1;
}

void parse_inline(const OctoMark *restrict om, const char *restrict text,
                  size_t len, Buffer *restrict out) {
  size_t i = 0;
  while (i < len) {
    int next_special = find_special_swar(om, text + i, len - i);
    if (next_special == -1) {
      buf_append_n(out, text + i, len - i);
      break;
    }
    if (next_special > 0) {
      buf_append_n(out, text + i, next_special);
      i += next_special;
    }

    char c = text[i];
    size_t rem = len - i;

    if (c == '\\' && rem > 1) {
      char escaped = text[i + 1];
      const char *esc = om->escape_table[(unsigned char)escaped];
      if (esc)
        buf_append(out, esc);
      else
        buf_push(out, escaped);
      i += 2;
      continue;
    }

    if (c == '[' || (c == '!' && rem > 1 && text[i + 1] == '[')) {
      bool img = (c == '!');
      size_t off = img ? 1 : 0;
      const char *close_b =
          (const char *)memchr(text + i + off + 1, ']', len - (i + off + 1));
      if (close_b && (size_t)(close_b - text + 1) < len &&
          *(close_b + 1) == '(') {
        const char *close_p =
            (const char *)memchr(close_b + 2, ')', len - (close_b - text + 2));
        if (close_p) {
          size_t url_len = close_p - (close_b + 2);
          bool has_space = false;
          for (size_t k = 0; k < url_len; k++)
            if (isspace(close_b[2 + k])) {
              has_space = true;
              break;
            }
          if (!has_space) {
            if (img) {
              buf_append(out, "<img src=\"");
              escape_buf(om, close_b + 2, url_len, out);
              buf_append(out, "\" alt=\"");
              escape_buf(om, text + i + 2, close_b - (text + i + 2), out);
              buf_append(out, "\">");
            } else {
              buf_append(out, "<a href=\"");
              escape_buf(om, close_b + 2, url_len, out);
              buf_append(out, "\">");
              parse_inline(om, text + i + 1, close_b - (text + i + 1), out);
              buf_append(out, "</a>");
            }
            i = close_p - text + 1;
            continue;
          }
        }
      }
    }

    if ((c == '*' && rem > 1 && text[i + 1] == '*') ||
        (c == '~' && rem > 1 && text[i + 1] == '~')) {
      const char *tag = (c == '*') ? "strong" : "del";
      const char *marker = (c == '*') ? "**" : "~~";
      const char *search_start = text + i + 2;
      const char *close = strstr(search_start, marker);
      if (close && (size_t)(close - text) < len) {
        buf_append_n(out, "<", 1);
        buf_append(out, tag);
        buf_append_n(out, ">", 1);
        parse_inline(om, text + i + 2, close - (text + i + 2), out);
        buf_append_n(out, "</", 2);
        buf_append(out, tag);
        buf_append_n(out, ">", 1);
        i = close - text + 2;
        continue;
      }
    }

    if (c == '_') {
      const char *close =
          (const char *)memchr(text + i + 1, '_', len - (i + 1));
      if (close) {
        buf_append(out, "<em>");
        parse_inline(om, text + i + 1, close - (text + i + 1), out);
        buf_append(out, "</em>");
        i = close - text + 1;
        continue;
      }
    }
    if (c == '`') {
      const char *close =
          (const char *)memchr(text + i + 1, '`', len - (i + 1));
      if (close) {
        buf_append(out, "<code>");
        escape_buf(om, text + i + 1, close - (text + i + 1), out);
        buf_append(out, "</code>");
        i = close - text + 1;
        continue;
      }
    }
    if (c == '$') {
      const char *close =
          (const char *)memchr(text + i + 1, '$', len - (i + 1));
      if (close) {
        buf_append(out, "<span class=\"math\">");
        escape_buf(om, text + i + 1, close - (text + i + 1), out);
        buf_append(out, "</span>");
        i = close - text + 1;
        continue;
      }
    }
    if (c == 'h' && rem >= 7 && strncmp(text + i, "http", 4) == 0) {
      bool full = (strncmp(text + i, "http://", 7) == 0) ||
                  (rem >= 8 && strncmp(text + i, "https://", 8) == 0);
      if (full) {
        size_t k = 0;
        while (i + k < len && !isspace(text[i + k]) &&
               !strchr("<>\"'[]()", text[i + k]))
          k++;
        if (k > 7) {
          buf_append(out, "<a href=\"");
          escape_buf(om, text + i, k, out);
          buf_append(out, "\">");
          escape_buf(om, text + i, k, out);
          buf_append(out, "</a>");
          i += k;
          continue;
        }
      }
    }

    const char *esc = om->escape_table[(unsigned char)c];
    if (esc)
      buf_append(out, esc);
    else
      buf_push(out, c);
    i++;
  }
}

bool process_line(OctoMark *restrict om, const char *restrict line, size_t len,
                  const char *restrict full, size_t next_pos,
                  Buffer *restrict out) {
  size_t t_s = 0;
  while (t_s < len && isspace(line[t_s]))
    t_s++;
  size_t t_e = len;
  while (t_e > t_s && isspace(line[t_e - 1]))
    t_e--;
  bool empty = (t_s == t_e);

  if (!om->in_code && empty) {
    while (om->list_stack.size > 0) {
      if (om->list_item_open[om->list_stack.size - 1]) {
        buf_append(out, "</li>\n");
        om->list_item_open[om->list_stack.size - 1] = false;
      }
      int t = om->list_stack.types[--om->list_stack.size];
      buf_append(out, t == 0 ? "</ul>\n" : "</ol>\n");
    }
    if (om->in_table) {
      buf_append(out, "</tbody></table>\n");
      om->in_table = false;
    }
    return false;
  }

  size_t indent = 0;
  if (!om->in_code) {
    while (len >= indent * 2 + 2 && line[indent * 2] == ' ' &&
           line[indent * 2 + 1] == ' ')
      indent++;
  }
  const char *rel = line + indent * 2;
  size_t rlen = len - indent * 2;

  if (rlen >= 3 && strncmp(rel, "```", 3) == 0) {
    while (om->list_stack.size > 0) {
      if (om->list_item_open[om->list_stack.size - 1]) {
        buf_append(out, "</li>\n");
        om->list_item_open[om->list_stack.size - 1] = false;
      }
      int t = om->list_stack.types[--om->list_stack.size];
      buf_append(out, t == 0 ? "</ul>\n" : "</ol>\n");
    }
    if (om->in_table) {
      buf_append(out, "</tbody></table>\n");
      om->in_table = false;
    }
    if (!om->in_code) {
      buf_append(out, "<pre><code");
      size_t lang_len = 0;
      while (3 + lang_len < rlen && !isspace(rel[3 + lang_len]))
        lang_len++;
      if (lang_len > 0) {
        buf_append(out, " class=\"language-");
        escape_buf(om, rel + 3, lang_len, out);
        buf_append(out, "\"");
      }
      buf_append(out, ">");
    } else
      buf_append(out, "</code></pre>\n");
    om->in_code = !om->in_code;
    return false;
  }

  if (rlen >= 2 && rel[0] == '$' && rel[1] == '$') {
    if (om->in_table) {
      buf_append(out, "</tbody></table>\n");
      om->in_table = false;
    }
    buf_append(out, om->in_math ? "</div>\n" : "<div class=\"math\">");
    om->in_math = !om->in_math;
    return false;
  }

  if (om->in_math || om->in_code) {
    escape_buf(om, line, len, out);
    buf_push(out, '\n');
    return false;
  }

  bool is_ul = (rlen >= 2 && rel[0] == '-' && rel[1] == ' ');
  bool is_ol = (rlen >= 3 && isdigit(rel[0]) && rel[1] == '.' && rel[2] == ' ');
  if (is_ul || is_ol) {
    int tag_type = is_ul ? 0 : 1;
    // A. Shallow return: Pop deeper levels and close their items
    while (om->list_stack.size > indent + 1) {
      if (om->list_item_open[om->list_stack.size - 1])
        buf_append(out, "</li>\n");
      om->list_item_open[om->list_stack.size - 1] = false;
      int t = om->list_stack.types[--om->list_stack.size];
      buf_append(out, t == 0 ? "</ul>\n" : "</ol>\n");
      // After popping a level, the parent <li> of that level is now the active
      // item at the new size-1
      if (om->list_stack.size > 0)
        om->list_item_open[om->list_stack.size - 1] = true;
    }

    // B. Deeper indent: Push new levels
    while (om->list_stack.size < indent + 1 &&
           om->list_stack.size < MAX_LIST_DEPTH) {
      buf_append(out, tag_type == 0 ? "<ul>\n" : "<ol>\n");
      om->list_stack.types[om->list_stack.size] = tag_type;
      om->list_item_open[om->list_stack.size] = false;
      om->list_stack.size++;
    }

    // C. Same level check:
    if (om->list_item_open[indent]) {
      // If we are moving to a new item at THIS level, close previous item
      // first. If we just pushed to this level in Step B,
      // om->list_item_open[indent] will be false.
      buf_append(out, "</li>\n");
    }

    if (om->list_stack.types[indent] != tag_type) {
      buf_append(out,
                 om->list_stack.types[indent] == 0 ? "</ul>\n" : "</ol>\n");
      buf_append(out, tag_type == 0 ? "<ul>\n" : "<ol>\n");
      om->list_stack.types[indent] = tag_type;
    }

    buf_append(out, "<li>");
    om->list_item_open[indent] = true;

    if (is_ul) {
      const char *rest = rel + 2;
      size_t r_l = rlen - 2;
      if (r_l >= 4 && rest[0] == '[' && (rest[1] == ' ' || rest[1] == 'x') &&
          rest[2] == ']' && rest[3] == ' ') {
        buf_append(out, "<input type=\"checkbox\" ");
        if (rest[1] == 'x')
          buf_append(out, "checked ");
        else
          buf_append(out, " ");
        buf_append(out, "disabled> ");
        parse_inline(om, rest + 4, r_l - 4, out);
      } else {
        parse_inline(om, rest, r_l, out);
      }
    } else {
      parse_inline(om, rel + 3, rlen - 3, out);
    }
    return false;
  } else if (om->list_stack.size > 0) {
    while (om->list_stack.size > 0) {
      if (om->list_item_open[om->list_stack.size - 1])
        buf_append(out, "</li>\n");
      om->list_item_open[om->list_stack.size - 1] = false;
      int t = om->list_stack.types[--om->list_stack.size];
      buf_append(out, t == 0 ? "</ul>\n" : "</ol>\n");
    }
  }

  if (rlen >= 2 && rel[0] == '#' && rel[1] == ' ') {
    buf_append(out, "<h1>");
    parse_inline(om, rel + 2, rlen - 2, out);
    buf_append(out, "</h1>\n");
  } else if (rlen >= 2 && rel[0] == '>' && rel[1] == ' ') {
    buf_append(out, "<blockquote>");
    parse_inline(om, rel + 2, rlen - 2, out);
    buf_append(out, "</blockquote>\n");
  } else if (t_e - t_s == 3 && strncmp(line + t_s, "---", 3) == 0) {
    buf_append(out, "<hr>\n");
  } else if (rlen > 0 && rel[0] == '|') {
    if (!om->in_table) {
      const char *newline = strchr(full + next_pos, '\n');
      if (newline) {
        const char *la = full + next_pos;
        size_t la_l = newline - la;
        size_t ls = 0;
        while (ls < la_l && isspace(la[ls]))
          ls++;
        if (ls < la_l && la[ls] == '|') {
          buf_append(out, "<table><thead><tr>");
          om->table_cols = 0;
          const char *p = la;
          if (*p == '|')
            p++;
          while (p < la + la_l && om->table_cols < 64) {
            const char *next_p = (const char *)memchr(p, '|', (la + la_l) - p);
            if (!next_p)
              next_p = la + la_l;
            const char *c = p;
            while (c < next_p && isspace(*c))
              c++;
            bool l = (c < next_p && *c == ':');
            const char *r_c = next_p - 1;
            while (r_c > c && isspace(*r_c))
              r_c--;
            bool r = (r_c >= c && *r_c == ':');
            om->table_aligns[om->table_cols++] =
                (l && r) ? ALIGN_CENTER
                         : (r ? ALIGN_RIGHT : (l ? ALIGN_LEFT : ALIGN_NONE));
            p = next_p + 1;
          }
          p = rel;
          if (*p == '|')
            p++;
          for (size_t i = 0; i < om->table_cols; i++) {
            const char *next_p = (const char *)memchr(p, '|', (rel + rlen) - p);
            size_t cell_len =
                (next_p ? (size_t)(next_p - p) : (size_t)((rel + rlen) - p));
            while (cell_len > 0 && isspace(*p)) {
              p++;
              cell_len--;
            }
            while (cell_len > 0 && isspace(p[cell_len - 1]))
              cell_len--;
            buf_append(out, "<th");
            if (om->table_aligns[i] == ALIGN_LEFT)
              buf_append(out, " style=\"text-align:left\"");
            else if (om->table_aligns[i] == ALIGN_CENTER)
              buf_append(out, " style=\"text-align:center\"");
            else if (om->table_aligns[i] == ALIGN_RIGHT)
              buf_append(out, " style=\"text-align:right\"");
            buf_append(out, ">");
            parse_inline(om, p, cell_len, out);
            buf_append(out, "</th>");
            if (!next_p)
              break;
            p = next_p + 1;
          }
          buf_append(out, "</tr></thead><tbody>\n");
          om->in_table = true;
          return true;
        }
      }
    }
    if (om->in_table) {
      buf_append(out, "<tr>");
      const char *p = rel;
      if (*p == '|')
        p++;
      for (size_t i = 0; i < om->table_cols; i++) {
        const char *next_p = (const char *)memchr(p, '|', (rel + rlen) - p);
        size_t cell_len =
            (next_p ? (size_t)(next_p - p) : (size_t)((rel + rlen) - p));
        while (cell_len > 0 && isspace(*p)) {
          p++;
          cell_len--;
        }
        while (cell_len > 0 && isspace(p[cell_len - 1]))
          cell_len--;
        buf_append(out, "<td");
        if (om->table_aligns[i] == ALIGN_LEFT)
          buf_append(out, " style=\"text-align:left\"");
        else if (om->table_aligns[i] == ALIGN_CENTER)
          buf_append(out, " style=\"text-align:center\"");
        else if (om->table_aligns[i] == ALIGN_RIGHT)
          buf_append(out, " style=\"text-align:right\"");
        buf_append(out, ">");
        parse_inline(om, p, cell_len, out);
        buf_append(out, "</td>");
        if (!next_p)
          break;
        p = next_p + 1;
      }
      buf_append(out, "</tr>\n");
    } else {
      buf_append(out, "<p>");
      parse_inline(om, line + t_s, t_e - t_s, out);
      buf_append(out, "</p>\n");
    }
    return false;
  } else {
    if (om->in_table) {
      buf_append(out, "</tbody></table>\n");
      om->in_table = false;
    }
    buf_append(out, "<p>");
    parse_inline(om, line + t_s, t_e - t_s, out);
    buf_append(out, "</p>\n");
  }
  return false;
}

void octomark_feed(OctoMark *restrict om, const char *restrict chunk,
                   size_t len, Buffer *restrict out) {
  buf_append_n(&om->leftover, chunk, len);
  char *data = om->leftover.data;
  size_t size = om->leftover.size;
  size_t pos = 0;
  while (pos < size) {
    char *next = (char *)memchr(data + pos, '\n', size - pos);
    if (!next)
      break;
    size_t line_len = next - (data + pos);
    bool skip_next =
        process_line(om, data + pos, line_len, data, pos + line_len + 1, out);
    pos += line_len + 1;
    if (skip_next) {
      char *next_next = (char *)memchr(data + pos, '\n', size - pos);
      if (next_next)
        pos = (size_t)(next_next - data + 1);
      else
        pos = size;
    }
  }
  if (pos > 0) {
    size_t rem = size - pos;
    memmove(data, data + pos, rem);
    om->leftover.size = rem;
    data[rem] = '\0';
  }
}

void octomark_finish(OctoMark *om, Buffer *out) {
  if (om->leftover.size > 0) {
    process_line(om, om->leftover.data, om->leftover.size, om->leftover.data,
                 om->leftover.size, out);
    om->leftover.size = 0;
  }
  while (om->list_stack.size > 0) {
    if (om->list_item_open[om->list_stack.size - 1]) {
      buf_append(out, "</li>\n");
      om->list_item_open[om->list_stack.size - 1] = false;
    }
    int t = om->list_stack.types[--om->list_stack.size];
    buf_append(out, t == 0 ? "</ul>\n" : "</ol>\n");
  }
  if (om->in_table) {
    buf_append(out, "</tbody></table>\n");
    om->in_table = false;
  }
  if (om->in_math) {
    buf_append(out, "</div>\n");
    om->in_math = false;
  }
  if (om->in_code) {
    buf_append(out, "</code></pre>\n");
    om->in_code = false;
  }
}

#ifndef OCTOMARK_NO_MAIN
int main() {
  OctoMark om;
  octomark_init(&om);
  Buffer output;
  buf_init(&output, 65536);

  char buf[65536];
  size_t bytes;
  while ((bytes = fread(buf, 1, sizeof(buf), stdin)) > 0) {
    octomark_feed(&om, buf, bytes, &output);
    if (output.size > 0) {
      fwrite(output.data, 1, output.size, stdout);
      output.size = 0;
      output.data[0] = '\0';
    }
  }

  octomark_finish(&om, &output);
  if (output.size > 0) {
    fwrite(output.data, 1, output.size, stdout);
  }

  buf_free(&output);
  octomark_free(&om);
  return 0;
}
#endif

#endif
