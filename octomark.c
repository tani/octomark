#include <ctype.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/**
 * OctoMark Native C99 Edition (Streaming & Buffer Passing)
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

void buf_grow(Buffer *b, size_t needed) {
  if (b->size + needed + 1 > b->capacity) {
    size_t new_cap = b->capacity * 2;
    if (new_cap < b->size + needed + 1)
      new_cap = b->size + needed + 1024;
    b->data = (char *)realloc(b->data, new_cap);
    b->capacity = new_cap;
  }
}

void buf_append_n(Buffer *b, const char *s, size_t n) {
  if (!s || n == 0)
    return;
  buf_grow(b, n);
  memcpy(b->data + b->size, s, n);
  b->size += n;
  b->data[b->size] = '\0';
}

void buf_append(Buffer *b, const char *s) {
  if (!s)
    return;
  buf_append_n(b, s, strlen(s));
}

void buf_push(Buffer *b, char c) {
  buf_grow(b, 1);
  b->data[b->size++] = c;
  b->data[b->size] = '\0';
}

void buf_free(Buffer *b) {
  free(b->data);
  b->data = NULL;
  b->size = b->capacity = 0;
}

// --- List Stack ---
typedef struct {
  int *types; // 0 for ul, 1 for ol
  size_t size;
  size_t capacity;
} ListStack;

void list_push(ListStack *s, int type) {
  if (s->size == s->capacity) {
    s->capacity = s->capacity ? s->capacity * 2 : 8;
    s->types = (int *)realloc(s->types, s->capacity * sizeof(int));
  }
  s->types[s->size++] = type;
}

int list_pop(ListStack *s) { return s->size > 0 ? s->types[--s->size] : -1; }

// --- OctoMark State ---
typedef struct {
  bool special_chars[256];
  const char *escape_table[256];
  bool in_code;
  bool in_math;
  bool in_table;
  char *table_aligns[64]; // Simplified fixed max columns
  size_t table_cols;
  ListStack list_stack;
  Buffer leftover;
} OctoMark;

void octomark_init(OctoMark *om) {
  memset(om->special_chars, 0, 256);
  memset(om->escape_table, 0, 256 * sizeof(char *));

  const char *specs = "\\['*`&<>\"_~!$";
  for (int i = 0; specs[i]; i++)
    om->special_chars[(unsigned char)specs[i]] = true;
  om->special_chars['h'] = true;

  om->escape_table['&'] = "&amp;";
  om->escape_table['<'] = "&lt;";
  om->escape_table['>'] = "&gt;";
  om->escape_table['"'] = "&quot;";
  om->escape_table['\''] = "&#39;";

  om->in_code = false;
  om->in_math = false;
  om->in_table = false;
  om->table_cols = 0;
  om->list_stack.types = NULL;
  om->list_stack.size = om->list_stack.capacity = 0;
  buf_init(&om->leftover, 1024);
}

void octomark_free(OctoMark *om) {
  buf_free(&om->leftover);
  free(om->list_stack.types);
  for (size_t i = 0; i < om->table_cols; i++)
    free(om->table_aligns[i]);
}

void escape_buf(const OctoMark *om, const char *str, size_t len, Buffer *out) {
  for (size_t i = 0; i < len; i++) {
    const char *esc = om->escape_table[(unsigned char)str[i]];
    if (esc)
      buf_append(out, esc);
    else
      buf_push(out, str[i]);
  }
}

void parse_inline(const OctoMark *om, const char *text, size_t len,
                  Buffer *out);

// Forward declaration needed for recursion
void parse_inline(const OctoMark *om, const char *text, size_t len,
                  Buffer *out) {
  size_t i = 0;
  while (i < len) {
    size_t start = i;
    // SWAR Jump Scan (64-bit)
    while (i + 7 < len) {
      uint64_t word;
      memcpy(&word, text + i, 8);
      if (om->special_chars[(word >> 0) & 0xFF] ||
          om->special_chars[(word >> 8) & 0xFF] ||
          om->special_chars[(word >> 16) & 0xFF] ||
          om->special_chars[(word >> 24) & 0xFF] ||
          om->special_chars[(word >> 32) & 0xFF] ||
          om->special_chars[(word >> 40) & 0xFF] ||
          om->special_chars[(word >> 48) & 0xFF] ||
          om->special_chars[(word >> 56) & 0xFF])
        break;
      i += 8;
    }
    while (i < len && !om->special_chars[(unsigned char)text[i]])
      i++;
    if (i > start)
      buf_append_n(out, text + start, i - start);
    if (i >= len)
      break;

    char c = text[i];
    size_t rem = len - i;

    // Escaping
    if (c == '\\' && i + 1 < len) {
      char escaped = text[i + 1];
      const char *esc = om->escape_table[(unsigned char)escaped];
      if (esc)
        buf_append(out, esc);
      else
        buf_push(out, escaped);
      i += 2;
      continue;
    }

    // Links/Images
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
              buf_push(out, '\"');
              buf_push(out, '>');
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

    // Bold/Strikethrough
    if ((c == '*' && rem > 1 && text[i + 1] == '*') ||
        (c == '~' && rem > 1 && text[i + 1] == '~')) {
      const char *tag = (c == '*') ? "strong" : "del";
      const char *marker = (c == '*') ? "**" : "~~";
      const char *close = strstr(
          text + i + 2, marker); // Simple search for demo, real one needs limit
      if (close && (size_t)(close - text) < len) {
        buf_push(out, '<');
        buf_append(out, tag);
        buf_push(out, '>');
        parse_inline(om, text + i + 2, close - (text + i + 2), out);
        buf_append(out, "</");
        buf_append(out, tag);
        buf_push(out, '>');
        i = close - text + 2;
        continue;
      }
    }

    // Others (Italic, Code, Math...)
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

void process_line(OctoMark *om, const char *line, size_t len, const char *full,
                  size_t next_pos, Buffer *out) {
  size_t t_start = 0;
  while (t_start < len && isspace(line[t_start]))
    t_start++;
  size_t t_end = len;
  while (t_end > t_start && isspace(line[t_end - 1]))
    t_end--;
  bool empty = (t_start == t_end);

  if (!om->in_code && empty) {
    while (om->list_stack.size > 0) {
      int t = list_pop(&om->list_stack);
      buf_append(out, t == 0 ? "</ul>\n" : "</ol>\n");
    }
    if (om->in_table) {
      buf_append(out, "</tbody></table>\n");
      om->in_table = false;
    }
    return;
  }

  size_t indent = 0;
  if (!om->in_code) {
    while (len >= indent * 4 + 4 && strncmp(line + indent * 4, "    ", 4) == 0)
      indent++;
  }
  const char *rel = line + indent * 4;
  size_t rlen = len - indent * 4;

  // Fenced Code
  if (rlen >= 3 && strncmp(rel, "```", 3) == 0) {
    while (om->list_stack.size > 0) {
      int t = list_pop(&om->list_stack);
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
        buf_push(out, '\"');
      }
      buf_push(out, '>');
    } else
      buf_append(out, "</code></pre>\n");
    om->in_code = !om->in_code;
    return;
  }

  // Block Math
  if (rlen >= 2 && rel[0] == '$' && rel[1] == '$') {
    if (om->in_table) {
      buf_append(out, "</tbody></table>\n");
      om->in_table = false;
    }
    if (!om->in_math)
      buf_append(out, "<div class=\"math\">");
    else
      buf_append(out, "</div>\n");
    om->in_math = !om->in_math;
    return;
  }

  if (om->in_math || om->in_code) {
    escape_buf(om, line, len, out);
    buf_push(out, '\n');
    return;
  }

  // Lists
  bool is_ul = (rlen >= 2 && rel[0] == '-' && rel[1] == ' ');
  bool is_ol = (rlen >= 3 && isdigit(rel[0]) && rel[1] == '.' && rel[2] == ' ');
  if (is_ul || is_ol) {
    int tag_type = is_ul ? 0 : 1;
    while (om->list_stack.size < indent + 1) {
      buf_append(out, tag_type == 0 ? "<ul>\n" : "<ol>\n");
      list_push(&om->list_stack, tag_type);
    }
    while (om->list_stack.size > indent + 1) {
      int t = list_pop(&om->list_stack);
      buf_append(out, t == 0 ? "</ul>\n" : "</ol>\n");
    }
    if (om->list_stack.types[om->list_stack.size - 1] != tag_type) {
      int t = list_pop(&om->list_stack);
      buf_append(out, t == 0 ? "</ul>\n" : "</ol>\n");
      buf_append(out, tag_type == 0 ? "<ul>\n" : "<ol>\n");
      list_push(&om->list_stack, tag_type);
    }

    if (is_ul) {
      const char *rest = rel + 2;
      size_t rest_len = rlen - 2;
      if (rest_len >= 4 && rest[0] == '[' &&
          (rest[1] == ' ' || rest[1] == 'x') && rest[2] == ']' &&
          rest[3] == ' ') {
        buf_append(out, "<li><input type=\"checkbox\" ");
        if (rest[1] == 'x')
          buf_append(out, "checked ");
        buf_append(out, "disabled> ");
        parse_inline(om, rest + 4, rest_len - 4, out);
        buf_append(out, "</li>\n");
      } else {
        buf_append(out, "<li>");
        parse_inline(om, rest, rest_len, out);
        buf_append(out, "</li>\n");
      }
    } else {
      buf_append(out, "<li>");
      parse_inline(om, rel + 3, rlen - 3, out);
      buf_append(out, "</li>\n");
    }
    return;
  } else if (om->list_stack.size > 0) {
    while (om->list_stack.size > 0) {
      int t = list_pop(&om->list_stack);
      buf_append(out, t == 0 ? "</ul>\n" : "</ol>\n");
    }
  }

  // Header, Quote, Table...
  if (rlen >= 2 && rel[0] == '#' && rel[1] == ' ') {
    buf_append(out, "<h1>");
    parse_inline(om, rel + 2, rlen - 2, out);
    buf_append(out, "</h1>\n");
  } else if (rlen >= 2 && rel[0] == '>' && rel[1] == ' ') {
    buf_append(out, "<blockquote>");
    parse_inline(om, rel + 2, rlen - 2, out);
    buf_append(out, "</blockquote>\n");
  } else if (t_end - t_start == 3 && strncmp(line + t_start, "---", 3) == 0) {
    buf_append(out, "<hr>\n");
  } else if (rlen > 0 && rel[0] == '|') {
    if (!om->in_table) {
      const char *newline = strchr(full + next_pos, '\n');
      if (newline) {
        size_t la_len = newline - (full + next_pos);
        const char *la = full + next_pos;
        size_t ls = 0;
        while (ls < la_len && isspace(la[ls]))
          ls++;
        if (ls < la_len && la[ls] == '|') {
          // Header confirmation logic truncated for simplicity, but same flow
          buf_append(out, "<table><thead><tr>");
          // (Simplified table parsing here)
          buf_append(out, "</tr></thead><tbody>\n");
          om->in_table = true;
          return; // Placeholder
        }
      }
    }
    buf_append(out, "<tr><td>");
    parse_inline(om, rel, rlen, out);
    buf_append(out, "</td></tr>\n");
  } else {
    if (om->in_table) {
      buf_append(out, "</tbody></table>\n");
      om->in_table = false;
    }
    buf_append(out, "<p>");
    parse_inline(om, line + t_start, t_end - t_start, out);
    buf_append(out, "</p>\n");
  }
}

void octomark_feed(OctoMark *om, const char *chunk, size_t len, Buffer *out) {
  buf_append_n(&om->leftover, chunk, len);
  char *data = om->leftover.data;
  size_t size = om->leftover.size;
  size_t pos = 0;

  while (pos < size) {
    char *next = (char *)memchr(data + pos, '\n', size - pos);
    if (!next)
      break;
    size_t line_len = next - (data + pos);
    process_line(om, data + pos, line_len, data, pos + line_len + 1, out);
    pos += line_len + 1;
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
    int t = list_pop(&om->list_stack);
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

int main() {
  OctoMark om;
  octomark_init(&om);
  Buffer output;
  buf_init(&output, 10 * 1024 * 1024);

  const char *data = "# Title\n- [x] Task\nThis is **bold** and `code`.\n";
  size_t data_len = strlen(data);

  printf("--- Streaming C99 Benchmark ---\n");
  clock_t t1 = clock();
  for (int i = 0; i < 100000; i++) {
    octomark_feed(&om, data, data_len, &output);
  }
  octomark_finish(&om, &output);
  clock_t t2 = clock();

  double sec = (double)(t2 - t1) / CLOCKS_PER_SEC;
  double mb = (double)data_len * 100000 / (1024 * 1024);
  printf("Speed: %.2f MB/s (Total %.2f MB in %.3f sec)\n", mb / sec, mb, sec);

  buf_free(&output);
  octomark_init(&om);
  return 0;
}
