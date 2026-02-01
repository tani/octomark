#include <ctype.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// --- Buffer Utility ---
typedef struct {
  char *data;
  size_t size;
  size_t capacity;
} Buffer;

void buf_init(Buffer *b, size_t cap) {
  b->data = (char *)malloc(cap);
  b->data[0] = '\0';
  b->size = 0;
  b->capacity = cap;
}

void buf_grow(Buffer *b, size_t min_cap) {
  if (b->capacity >= min_cap)
    return;
  size_t new_cap = b->capacity * 2;
  if (new_cap < min_cap)
    new_cap = min_cap;
  b->data = (char *)realloc(b->data, new_cap);
  b->capacity = new_cap;
}

void buf_push(Buffer *b, char c) {
  if (b->size + 2 > b->capacity)
    buf_grow(b, b->size + 2);
  b->data[b->size++] = c;
  b->data[b->size] = '\0';
}

void buf_append_n(Buffer *b, const char *s, size_t n) {
  if (b->size + n + 1 > b->capacity)
    buf_grow(b, b->size + n + 1);
  memcpy(b->data + b->size, s, n);
  b->size += n;
  b->data[b->size] = '\0';
}

void buf_append(Buffer *b, const char *s) { buf_append_n(b, s, strlen(s)); }

void buf_free(Buffer *b) {
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

// --- Block Type Flags ---
#define B_LIST 1
#define B_TABLE 2
#define B_DL 4
#define B_QUOTE 8
#define B_MATH 16
#define B_CODE 32
#define B_INTERRUPT (B_LIST | B_TABLE | B_DL | B_QUOTE)
#define B_ALL (B_INTERRUPT | B_MATH | B_CODE)

// --- OctoMark State ---
typedef struct {
  bool special_chars[256];
  const char *escape_table[256];
  bool in_code;
  bool in_math;
  bool in_table;
  bool in_dl;
  bool in_quote;
  Align table_aligns[64];
  size_t table_cols;
  ListStack list_stack;
  bool list_item_open[MAX_LIST_DEPTH];
  Buffer leftover;
} OctoMark;

void octomark_init(OctoMark *om) {
  memset(om, 0, sizeof(OctoMark));
  const char *specs = "\\['*`&<>\"_~!$h";
  for (int i = 0; specs[i]; i++)
    om->special_chars[(unsigned char)specs[i]] = true;

  for (int i = 0; i < 256; i++)
    om->escape_table[i] = NULL;
  om->escape_table['&'] = "&amp;";
  om->escape_table['<'] = "&lt;";
  om->escape_table['>'] = "&gt;";
  om->escape_table['"'] = "&quot;";
  om->escape_table['\''] = "&#39;";

  buf_init(&om->leftover, 4096);
}

void octomark_free(OctoMark *om) { buf_free(&om->leftover); }

static void close_blocks(OctoMark *om, Buffer *out, int mask) {
  if ((mask & B_LIST) && om->list_stack.size > 0) {
    while (om->list_stack.size > 0) {
      if (om->list_item_open[om->list_stack.size - 1]) {
        buf_append(out, "</li>\n");
        om->list_item_open[om->list_stack.size - 1] = false;
      }
      int t = om->list_stack.types[--om->list_stack.size];
      buf_append(out, t == 0 ? "</ul>\n" : "</ol>\n");
    }
  }
  if ((mask & B_DL) && om->in_dl) {
    buf_append(out, "</dl>\n");
    om->in_dl = false;
  }
  if ((mask & B_TABLE) && om->in_table) {
    buf_append(out, "</tbody></table>\n");
    om->in_table = false;
  }
  if ((mask & B_QUOTE) && om->in_quote) {
    buf_append(out, "</blockquote>\n");
    om->in_quote = false;
  }
  if ((mask & B_MATH) && om->in_math) {
    buf_append(out, "</div>\n");
    om->in_math = false;
  }
  if ((mask & B_CODE) && om->in_code) {
    buf_append(out, "</code></pre>\n");
    om->in_code = false;
  }
}

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
#if defined(__GNUC__) || defined(__clang__)
      return i + (__builtin_ctzll(specials) >> 3);
#else
      for (int k = 0; k < 8; k++)
        if (om->special_chars[(unsigned char)text[i + k]])
          return i + k;
#endif
    }
    i += 8;
  }
  while (i < len && !om->special_chars[(unsigned char)text[i]])
    i++;
  return (int)i;
}

void parse_inline(const OctoMark *restrict om, const char *restrict text,
                  size_t len, Buffer *restrict out) {
  size_t i = 0;
  while (i < len) {
    int next_spec = find_special_swar(om, text + i, len - i);
    if (next_spec > 0)
      buf_append_n(out, text + i, next_spec);
    i += next_spec;
    if (i >= len)
      break;

    char c = text[i];
    if (c == '\\' && i + 1 < len) {
      buf_push(out, text[++i]);
    } else if (c == '*' || c == '_') {
      int count = 1;
      while (i + 1 < len && text[i + 1] == c) {
        count++;
        i++;
      }
      if (count >= 2)
        buf_append(out, "<strong>");
      else
        buf_append(out, "<em>");
      size_t start = i + 1;
      int close_count = 0;
      while (i + 1 < len) {
        i++;
        if (text[i] == c) {
          close_count++;
          if (close_count == count)
            break;
        } else
          close_count = 0;
      }
      parse_inline(om, text + start, i - start - count + 1, out);
      if (count >= 2)
        buf_append(out, "</strong>");
      else
        buf_append(out, "</em>");
    } else if (c == '`') {
      int count = 1;
      while (i + 1 < len && text[i + 1] == '`') {
        count++;
        i++;
      }
      buf_append(out, "<code>");
      size_t start = i + 1;
      while (i + 1 < len) {
        i++;
        bool match = true;
        for (int k = 0; k < count; k++) {
          if (i + k >= len || text[i + k] != '`') {
            match = false;
            break;
          }
        }
        if (match)
          break;
      }
      escape_buf(om, text + start, i - start, out);
      buf_append(out, "</code>");
      i += count - 1;
    } else if (c == '~' && i + 1 < len && text[i + 1] == '~') {
      buf_append(out, "<del>");
      i += 2;
      size_t start = i;
      while (i + 1 < len && !(text[i] == '~' && text[i + 1] == '~'))
        i++;
      parse_inline(om, text + start, i - start, out);
      buf_append(out, "</del>");
      i++;
    } else if (c == '!') {
      if (i + 1 < len && text[i + 1] == '[') {
        i += 2;
        size_t label_start = i;
        int depth = 1;
        while (i < len && depth > 0) {
          if (text[i] == '[')
            depth++;
          else if (text[i] == ']')
            depth--;
          i++;
        }
        if (i < len && text[i] == '(') {
          size_t label_len = i - label_start - 1;
          i++;
          size_t url_start = i;
          while (i < len && text[i] != ')')
            i++;
          buf_append(out, "<img src=\"");
          buf_append_n(out, text + url_start, i - url_start);
          buf_append(out, "\" alt=\"");
          buf_append_n(out, text + label_start, label_len);
          buf_append(out, "\">");
        }
      } else
        buf_push(out, '!');
    } else if (c == '[') {
      i++;
      size_t label_start = i;
      int depth = 1;
      while (i < len && depth > 0) {
        if (text[i] == '[')
          depth++;
        else if (text[i] == ']')
          depth--;
        i++;
      }
      if (i < len && text[i] == '(') {
        size_t label_len = i - label_start - 1;
        i++;
        size_t url_start = i;
        while (i < len && text[i] != ')')
          i++;
        buf_append(out, "<a href=\"");
        buf_append_n(out, text + url_start, i - url_start);
        buf_append(out, "\">");
        parse_inline(om, text + label_start, label_len, out);
        buf_append(out, "</a>");
      }
    } else if (c == 'h' && (strncmp(text + i, "http://", 7) == 0 ||
                            strncmp(text + i, "https://", 8) == 0)) {
      size_t start = i;
      while (i < len && !isspace(text[i]) && text[i] != '<' && text[i] != '>')
        i++;
      buf_append(out, "<a href=\"");
      buf_append_n(out, text + start, i - start);
      buf_append(out, "\">");
      buf_append_n(out, text + start, i - start);
      buf_append(out, "</a>");
      i--;
    } else if (c == '<') {
      size_t start = i + 1;
      while (i < len && text[i] != '>')
        i++;
      if (i < len) {
        buf_append(out, "<a href=\"");
        buf_append_n(out, text + start, i - start);
        buf_append(out, "\">");
        buf_append_n(out, text + start, i - start);
        buf_append(out, "</a>");
      }
    } else if (c == '$') {
      buf_append(out, "<span class=\"math\">");
      i++;
      size_t start = i;
      while (i < len && text[i] != '$')
        i++;
      escape_buf(om, text + start, i - start, out);
      buf_append(out, "</span>");
    } else if (om->escape_table[(unsigned char)c])
      buf_append(out, om->escape_table[(unsigned char)c]);
    else
      buf_push(out, c);
    i++;
  }
}

static size_t split_row(const char *line, size_t len, const char **cells,
                        size_t *cell_lens) {
  size_t count = 0;
  size_t i = 0;
  while (i < len && isspace(line[i]))
    i++;
  if (i < len && line[i] == '|')
    i++;
  while (i < len) {
    while (i < len && isspace(line[i]))
      i++;
    if (i >= len || line[i] == '\n')
      break;
    cells[count] = line + i;
    size_t start = i;
    while (i < len && line[i] != '|' && line[i] != '\n')
      i++;
    size_t end = i;
    while (end > start && isspace(line[end - 1]))
      end--;
    cell_lens[count] = end - start;
    count++;
    if (i < len && line[i] == '|')
      i++;
  }
  return count;
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
    close_blocks(om, out, B_INTERRUPT);
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
    close_blocks(om, out, B_INTERRUPT);
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
    close_blocks(om, out, B_INTERRUPT);
    if (!om->in_math)
      buf_append(out, "<div class=\"math\">");
    else
      buf_append(out, "</div>\n");
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
    close_blocks(om, out, B_INTERRUPT & ~B_LIST);
    int tag_type = is_ul ? 0 : 1;
    while (om->list_stack.size > indent + 1) {
      if (om->list_item_open[om->list_stack.size - 1])
        buf_append(out, "</li>\n");
      om->list_item_open[om->list_stack.size - 1] = false;
      int t = om->list_stack.types[--om->list_stack.size];
      buf_append(out, t == 0 ? "</ul>\n" : "</ol>\n");
      if (om->list_stack.size > 0)
        om->list_item_open[om->list_stack.size - 1] = true;
    }
    while (om->list_stack.size < indent + 1 &&
           om->list_stack.size < MAX_LIST_DEPTH) {
      buf_append(out, tag_type == 0 ? "<ul>\n" : "<ol>\n");
      om->list_stack.types[om->list_stack.size] = tag_type;
      om->list_item_open[om->list_stack.size] = false;
      om->list_stack.size++;
    }
    if (om->list_item_open[indent])
      buf_append(out, "</li>\n");
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
      } else
        parse_inline(om, rest, r_l, out);
    } else
      parse_inline(om, rel + 3, rlen - 3, out);
    return false;
  } else if (om->list_stack.size > 0) {
    close_blocks(om, out, B_LIST);
  }

  if (rlen >= 2 && rel[0] == '#' && rel[1] == ' ') {
    close_blocks(om, out, B_INTERRUPT);
    buf_append(out, "<h1>");
    parse_inline(om, rel + 2, rlen - 2, out);
    buf_append(out, "</h1>\n");
  } else if (rlen >= 2 && rel[0] == '>' && rel[1] == ' ') {
    if (!om->in_quote) {
      close_blocks(om, out, B_INTERRUPT & ~B_QUOTE);
      buf_append(out, "<blockquote>");
      om->in_quote = true;
    }
    parse_inline(om, rel + 2, rlen - 2, out);
    buf_append(out, "\n");
    return false;
  } else if (t_e - t_s == 3 && strncmp(line + t_s, "---", 3) == 0) {
    close_blocks(om, out, B_INTERRUPT);
    buf_append(out, "<hr>\n");
  } else if (rlen > 0 && rel[0] == '|') {
    if (om->in_dl || om->in_quote)
      close_blocks(om, out, B_DL | B_QUOTE);
    if (!om->in_table) {
      const char *newline = strchr(full + next_pos, '\n');
      if (newline) {
        const char *la = full + next_pos;
        size_t la_l = newline - la;
        size_t ls = 0;
        while (ls < la_l && isspace(la[ls]))
          ls++;
        if (ls < la_l && la[ls] == '|') {
          close_blocks(om, out, B_INTERRUPT & ~B_TABLE);
          buf_append(out, "<table><thead><tr>");
          om->table_cols = 0;
          const char *p = la;
          if (*p == '|')
            p++;
          while (p < newline) {
            while (p < newline && isspace(*p))
              p++;
            if (p >= newline)
              break;
            const char *start = p;
            while (p < newline && *p != '|')
              p++;
            const char *end = p;
            while (end > start && isspace(end[-1]))
              end--;
            Align align = ALIGN_NONE;
            bool left = (start < end && start[0] == ':');
            bool right = (end > start && end[-1] == ':');
            if (left && right)
              align = ALIGN_CENTER;
            else if (right)
              align = ALIGN_RIGHT;
            else if (left)
              align = ALIGN_LEFT;
            om->table_aligns[om->table_cols++] = align;
            if (p < newline && *p == '|')
              p++;
          }
          const char *h_cells[64];
          size_t h_lens[64];
          size_t h_count = split_row(line, len, h_cells, h_lens);
          for (size_t i = 0; i < h_count; i++) {
            buf_append(out, "<th");
            Align a = (i < om->table_cols) ? om->table_aligns[i] : ALIGN_NONE;
            if (a == ALIGN_LEFT)
              buf_append(out, " style=\"text-align:left\"");
            else if (a == ALIGN_CENTER)
              buf_append(out, " style=\"text-align:center\"");
            else if (a == ALIGN_RIGHT)
              buf_append(out, " style=\"text-align:right\"");
            buf_append(out, ">");
            parse_inline(om, h_cells[i], h_lens[i], out);
            buf_append(out, "</th>");
          }
          buf_append(out, "</tr></thead><tbody>\n");
          om->in_table = true;
          return true;
        }
      }
    }
    if (om->in_table) {
      const char *b_cells[64];
      size_t b_lens[64];
      size_t b_count = split_row(line, len, b_cells, b_lens);
      buf_append(out, "<tr>");
      for (size_t i = 0; i < b_count; i++) {
        buf_append(out, "<td");
        Align a = (i < om->table_cols) ? om->table_aligns[i] : ALIGN_NONE;
        if (a == ALIGN_LEFT)
          buf_append(out, " style=\"text-align:left\"");
        else if (a == ALIGN_CENTER)
          buf_append(out, " style=\"text-align:center\"");
        else if (a == ALIGN_RIGHT)
          buf_append(out, " style=\"text-align:right\"");
        buf_append(out, ">");
        parse_inline(om, b_cells[i], b_lens[i], out);
        buf_append(out, "</td>");
      }
      buf_append(out, "</tr>\n");
      return false;
    }
    buf_append(out, "<p>");
    parse_inline(om, line + t_s, t_e - t_s, out);
    buf_append(out, "</p>\n");
  } else if (rlen > 0 && rel[0] == ':') {
    if (om->in_quote)
      close_blocks(om, out, B_QUOTE);
    if (!om->in_dl) {
      buf_append(out, "<dl>\n");
      om->in_dl = true;
    }
    buf_append(out, "<dd>");
    const char *d_start = rel + 1;
    size_t d_len = rlen - 1;
    if (d_len > 0 && d_start[0] == ' ') {
      d_start++;
      d_len--;
    }
    parse_inline(om, d_start, d_len, out);
    buf_append(out, "</dd>\n");
    return false;
  } else {
    const char *next_line = full + next_pos;
    const char *next_newline = strchr(next_line, '\n');
    bool next_is_def = false;
    if (next_newline) {
      const char *p = next_line;
      while (p < next_newline && isspace(*p))
        p++;
      if (p < next_newline && *p == ':')
        next_is_def = true;
    }
    if (next_is_def) {
      if (om->in_quote)
        close_blocks(om, out, B_QUOTE);
      if (!om->in_dl) {
        buf_append(out, "<dl>\n");
        om->in_dl = true;
      }
      buf_append(out, "<dt>");
      parse_inline(om, line + t_s, t_e - t_s, out);
      buf_append(out, "</dt>\n");
      return false;
    }
    close_blocks(om, out, B_INTERRUPT);
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
  close_blocks(om, out, B_ALL);
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
