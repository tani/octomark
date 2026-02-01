#include <ctype.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  char *data;
  size_t size;
  size_t capacity;
} Buffer;

static void buf_init(Buffer *b, size_t cap) {
  b->data = (char *)malloc(cap);
  b->data[0] = '\0';
  b->size = 0;
  b->capacity = cap;
}

static void buf_grow(Buffer *b, size_t m) {
  if (b->capacity >= m)
    return;
  size_t n = b->capacity * 2;
  if (n < m)
    n = m;
  b->data = (char *)realloc(b->data, n);
  b->capacity = n;
}

static void buf_push(Buffer *b, char c) {
  if (b->size + 2 > b->capacity)
    buf_grow(b, b->size + 2);
  b->data[b->size++] = c;
  b->data[b->size] = '\0';
}

static void buf_append_n(Buffer *b, const char *s, size_t n) {
  if (n == 0)
    return;
  if (b->size + n + 1 > b->capacity)
    buf_grow(b, b->size + n + 1);
  memcpy(b->data + b->size, s, n);
  b->size += n;
  b->data[b->size] = '\0';
}

static void buf_append(Buffer *b, const char *s) {
  buf_append_n(b, s, strlen(s));
}

static void buf_free(Buffer *b) {
  free(b->data);
  b->data = NULL;
  b->size = b->capacity = 0;
}

#define MAX_DEPTH 32
enum { T_UL, T_OL, T_QUOTE, T_DL, T_DD, T_CODE, T_MATH, T_TABLE, T_P };

typedef struct {
  int type, indent;
} Entry;

typedef enum { ALIGN_NONE, ALIGN_LEFT, ALIGN_CENTER, ALIGN_RIGHT } Align;

typedef struct {
  bool spec[256];
  const char *esc[256];
  Align t_aligns[64];
  size_t t_cols;
  Entry stack[MAX_DEPTH];
  size_t stack_size;
  Buffer leftover;
} OctoMark;

void octomark_init(OctoMark *om) {
  memset(om, 0, sizeof(OctoMark));
  for (const char *s = "\\['*`&<>\"_~!$h"; *s; s++)
    om->spec[(unsigned char)*s] = true;
  om->esc['&'] = "&amp;";
  om->esc['<'] = "&lt;";
  om->esc['>'] = "&gt;";
  om->esc['"'] = "&quot;";
  om->esc['\''] = "&#39;";
  buf_init(&om->leftover, 4096);
}
void octomark_free(OctoMark *om) { buf_free(&om->leftover); }

static inline void stack_push(OctoMark *om, int type, int indent) {
  if (om->stack_size < MAX_DEPTH) {
    om->stack[om->stack_size++] = (Entry){type, indent};
  }
}

static inline Entry *stack_peek(OctoMark *om) {
  return om->stack_size > 0 ? &om->stack[om->stack_size - 1] : NULL;
}

static inline void stack_pop(OctoMark *om) {
  if (om->stack_size > 0)
    om->stack_size--;
}

static inline int top_type(const OctoMark *om) {
  return om->stack_size > 0 ? om->stack[om->stack_size - 1].type : -1;
}

static void pop(OctoMark *om, Buffer *out) {
  if (om->stack_size == 0)
    return;
  int t = stack_peek(om)->type;
  stack_pop(om);
  if (t == T_UL)
    buf_append(out, "</li>\n</ul>\n");
  else if (t == T_OL)
    buf_append(out, "</li>\n</ol>\n");
  else if (t == T_QUOTE)
    buf_append(out, "</blockquote>\n");
  else if (t == T_DL)
    buf_append(out, "</dl>\n");
  else if (t == T_DD)
    buf_append(out, "</dd>\n");
  else if (t == T_CODE)
    buf_append(out, "</code></pre>\n");
  else if (t == T_MATH)
    buf_append(out, "</div>\n");
  else if (t == T_TABLE)
    buf_append(out, "</tbody></table>\n");
  else if (t == T_P)
    buf_append(out, "</p>\n");
}

static void close_p(OctoMark *om, Buffer *out) {
  if (top_type(om) == T_P)
    pop(om, out);
}

static void close_leaf_blocks(OctoMark *om, Buffer *out) {
  int t = top_type(om);
  if (t == T_P || t == T_TABLE || t == T_CODE || t == T_MATH)
    pop(om, out);
}

static inline void escape(const OctoMark *restrict om, const char *restrict s,
                          size_t l, Buffer *restrict out) {
  for (size_t i = 0; i < l; i++) {
    const char *e = om->esc[(unsigned char)s[i]];
    if (e)
      buf_append(out, e);
    else
      buf_push(out, s[i]);
  }
}
static const char *tag_open[] = {"", "<em>", "<strong>", "<strong><em>"};
static const char *tag_close[] = {"", "</em>", "</strong>", "</em></strong>"};

static void parse_inline(const OctoMark *restrict om, const char *restrict text,
                         size_t len, Buffer *restrict out) {
  size_t i = 0;
  while (i < len) {
    char c = text[i];
    if (c == '\\') {
      if (i + 1 < len)
        buf_push(out, text[++i]);
      else
        buf_append(out, "<br>");
    } else if ((c == '*' || c == '_') && i + 1 < len) {
      int n = 1;
      while (i + n < len && text[i + n] == c)
        n++;
      if (n > 3)
        n = 3;
      buf_append(out, tag_open[n]);
      size_t st = i + n, cl = 0;
      i += n;
      while (i < len) {
        if (text[i] == c && ++cl == n)
          break;
        if (text[i] != c)
          cl = 0;
        i++;
      }
      parse_inline(om, text + st, i - st - n + 1, out);
      buf_append(out, tag_close[n]);
    } else if (c == '`') {
      int cnt = 1;
      while (i + cnt < len && text[i + cnt] == '`')
        cnt++;
      buf_append(out, "<code>");
      size_t s = i + cnt;
      while (i + cnt < len) {
        i++;
        bool m = true;
        for (int k = 0; k < cnt; k++)
          if (i + k >= len || text[i + k] != '`') {
            m = false;
            break;
          }
        if (m)
          break;
      }
      escape(om, text + s, i - s, out);
      buf_append(out, "</code>");
      i += cnt - 1;
    } else if (c == '~' && i + 1 < len && text[i + 1] == '~') {
      buf_append(out, "<del>");
      i += 2;
      size_t s = i;
      while (i + 1 < len && (text[i] != '~' || text[i + 1] != '~'))
        i++;
      parse_inline(om, text + s, i - s, out);
      buf_append(out, "</del>");
      i++;
    } else if (c == '!' || c == '[') {
      size_t start_idx = i;
      if (c == '!')
        i++;
      if (i < len && text[i] == '[') {
        i++;
        size_t s = i, d = 1;
        while (i < len && d > 0) {
          if (text[i] == '[')
            d++;
          else if (text[i] == ']')
            d--;
          i++;
        }
        if (i < len && text[i] == '(') {
          size_t txt_len = i - s - 1;
          i++;
          size_t us = i;
          while (i < len && text[i] != ')' && text[i] != ' ')
            i++;
          size_t ul = i - us;
          while (i < len && text[i] != ')')
            i++;
          if (c == '!') {
            buf_append(out, "<img src=\"");
            buf_append_n(out, text + us, ul);
            buf_append(out, "\" alt=\"");
            buf_append_n(out, text + s, txt_len);
            buf_append(out, "\">");
          } else {
            buf_append(out, "<a href=\"");
            buf_append_n(out, text + us, ul);
            buf_append(out, "\">");
            parse_inline(om, text + s, txt_len, out);
            buf_append(out, "</a>");
          }
          goto next;
        }
      }
      i = start_idx;
      goto def;
    } else if (c == 'h' && (strncmp(text + i, "http", 4) == 0) &&
               (strncmp(text + i + 4, "://", 3) == 0 ||
                strncmp(text + i + 4, "s://", 4) == 0)) {
      size_t st = i;
      while (i < len && !isspace(text[i]) && text[i] != '<' && text[i] != '>')
        i++;
      buf_append(out, "<a href=\"");
      buf_append_n(out, text + st, i - st);
      buf_append(out, "\">");
      buf_append_n(out, text + st, i - st);
      buf_append(out, "</a>");
      i--;
    } else if (c == '$') {
      buf_append(out, "<span class=\"math\">");
      i++;
      size_t s = i;
      while (i < len && text[i] != '$')
        i++;
      escape(om, text + s, i - s, out);
      buf_append(out, "</span>");
    } else {
    def:
      if (om->esc[(unsigned char)c])
        buf_append(out, om->esc[(unsigned char)c]);
      else
        buf_push(out, c);
    }
  next:
    i++;
  }
}
static size_t split(const char *l, size_t n, const char **c, size_t *s) {
  size_t cnt = 0, i = 0;
  while (i < n && isspace(l[i]))
    i++;
  if (i < n && l[i] == '|')
    i++;
  while (i < n) {
    while (i < n && isspace(l[i]))
      i++;
    if (i >= n || l[i] == '\n')
      break;
    c[cnt] = l + i;
    size_t st = i;
    while (i < n && l[i] != '|' && l[i] != '\n')
      i++;
    size_t ed = i;
    while (ed > st && isspace(l[ed - 1]))
      ed--;
    s[cnt++] = ed - st;
    if (i < n && l[i] == '|')
      i++;
  }
  return cnt;
}
static bool is_block(const char *s, size_t len) {
  if (len >= 3 && strncmp(s, "```", 3) == 0)
    return true;
  if (len >= 2 && s[0] == '$' && s[1] == '$')
    return true;
  if (len >= 1 && (s[0] == '#' || s[0] == ':'))
    return true;
  if (len >= 2 && s[0] == '-' && s[1] == ' ')
    return true;
  if (len >= 3 && isdigit(s[0]) && s[1] == '.' && s[2] == ' ')
    return true;
  if (len >= 3 && (strncmp(s, "---", 3) == 0 || strncmp(s, "***", 3) == 0 ||
                   strncmp(s, "___", 3) == 0))
    return true;
  return false;
}

bool process_line(OctoMark *restrict om, const char *restrict line, size_t len,
                  const char *restrict full, size_t pos, Buffer *restrict out) {
  int top = top_type(om);
  if (top == T_CODE) {
    size_t ts = 0;
    while (ts < len && isspace(line[ts]))
      ts++;
    if (len - ts >= 3 && strncmp(line + ts, "```", 3) == 0) {
      pop(om, out);
      return false;
    }
    escape(om, line, len, out);
    buf_push(out, '\n');
    return false;
  }
  if (top == T_MATH) {
    size_t ts = 0;
    while (ts < len && isspace(line[ts]))
      ts++;
    if (len - ts >= 2 && strncmp(line + ts, "$$", 2) == 0) {
      pop(om, out);
      return false;
    }
    escape(om, line, len, out);
    buf_push(out, '\n');
    return false;
  }

  size_t ls = 0;
  while (ls < len && line[ls] == ' ')
    ls++;
  const char *rel = line + ls;
  size_t rlen = len - ls;

  if (rlen == 0) {
    close_leaf_blocks(om, out);
    while (om->stack_size > 0 && top_type(om) >= T_QUOTE)
      pop(om, out);
    return false;
  }

  size_t ql = 0;
  while (rlen > 0 && rel[0] == '>') {
    ql++;
    rel++;
    rlen--;
    if (rlen > 0 && rel[0] == ' ') {
      rel++;
      rlen--;
    }
  }

  size_t cur_ql = 0;
  for (size_t k = 0; k < om->stack_size; k++)
    if (om->stack[k].type == T_QUOTE)
      cur_ql++;

  if (ql < cur_ql && top_type(om) == T_P) {
    size_t ti = 0;
    while (ti < rlen && rel[ti] == ' ')
      ti++;
    if (!is_block(rel + ti, rlen - ti))
      ql = cur_ql;
  }

  while (cur_ql > ql) {
    int t = top_type(om);
    pop(om, out);
    if (t == T_QUOTE)
      cur_ql--;
  }

  while (om->stack_size < ql) {
    close_p(om, out);
    buf_append(out, "<blockquote>");
    stack_push(om, T_QUOTE, 0);
  }

  bool hdd = (rlen > 0 && rel[0] == ':');
  if (hdd) {
    rel++;
    rlen--;
    if (rlen > 0 && rel[0] == ' ') {
      rel++;
      rlen--;
    }
    close_p(om, out);
    bool in_dl = false, in_dd = false;
    for (size_t k = 0; k < om->stack_size; k++) {
      if (om->stack[k].type == T_DL)
        in_dl = true;
      if (om->stack[k].type == T_DD)
        in_dd = true;
    }
    if (!in_dl) {
      buf_append(out, "<dl>\n");
      stack_push(om, T_DL, (int)ls);
    }
    if (in_dd)
      while (top_type(om) != T_DL && om->stack_size > 0)
        pop(om, out);
    buf_append(out, "<dd>");
    stack_push(om, T_DD, (int)ls);
  }

  size_t ils = 0;
  while (ils < rlen && rel[ils] == ' ')
    ils++;
  bool is_u = (rlen - ils >= 2 && rel[ils] == '-' && rel[ils + 1] == ' '),
       is_o = (rlen - ils >= 3 && isdigit(rel[ils]) && rel[ils + 1] == '.' &&
               rel[ils + 2] == ' ');

  if (is_u || is_o) {
    int tt = (is_u ? T_UL : T_OL);
    int ci = (int)(ls + ils);
    while (om->stack_size > 0 && top_type(om) < T_QUOTE &&
           (stack_peek(om)->indent > ci ||
            (stack_peek(om)->indent == ci && top_type(om) != tt)))
      pop(om, out);

    int top = top_type(om);
    if (top == tt && stack_peek(om)->indent == ci) {
      close_leaf_blocks(om, out);
      buf_append(out, "</li>\n<li>");
    } else {
      close_leaf_blocks(om, out);
      buf_append(out, tt == T_UL ? "<ul>\n<li>" : "<ol>\n<li>");
      stack_push(om, tt, ci);
    }
    rel += ils + (is_u ? 2 : 3);
    rlen -= ils + (is_u ? 2 : 3);
    if (is_u && rlen >= 4 && rel[0] == '[' &&
        (rel[1] == ' ' || rel[1] == 'x') && rel[2] == ']' && rel[3] == ' ') {
      buf_append(out, rel[1] == 'x'
                          ? "<input type=\"checkbox\" checked disabled> "
                          : "<input type=\"checkbox\"  disabled> ");
      rel += 4;
      rlen -= 4;
    }
  }

  if (rlen >= 3 && strncmp(rel, "```", 3) == 0) {
    close_leaf_blocks(om, out);
    buf_append(out, "<pre><code");
    size_t ll = 0;
    while (3 + ll < rlen && !isspace(rel[3 + ll]))
      ll++;
    if (ll > 0) {
      buf_append(out, " class=\"language-");
      escape(om, rel + 3, ll, out);
      buf_append(out, "\"");
    }
    buf_append(out, ">");
    stack_push(om, T_CODE, 0);
    return false;
  }
  if (rlen >= 2 && rel[0] == '$' && rel[1] == '$') {
    close_leaf_blocks(om, out);
    buf_append(out, "<div class=\"math\">\n");
    stack_push(om, T_MATH, 0);
    return false;
  }
  if (rlen >= 2 && rel[0] == '#') {
    size_t lv = 0;
    while (lv < 6 && lv < rlen && rel[lv] == '#')
      lv++;
    if (lv < rlen && rel[lv] == ' ') {
      close_leaf_blocks(om, out);
      char tag[] = "<h1>";
      tag[2] = '0' + lv;
      buf_append(out, tag);
      parse_inline(om, rel + lv + 1, rlen - lv - 1, out);
      tag[1] = '/';
      tag[2] = 'h';
      tag[3] = '0' + lv;
      buf_append_n(out, tag, 4);
      buf_append(out, ">\n");
      return false;
    }
  }
  if (rlen == 3 &&
      (strncmp(rel, "---", 3) == 0 || strncmp(rel, "***", 3) == 0 ||
       strncmp(rel, "___", 3) == 0)) {
    close_leaf_blocks(om, out);
    buf_append(out, "<hr>\n");
    return false;
  }

  if (rlen > 0 && rel[0] == '|') {
    if (top_type(om) != T_TABLE) {
      const char *nl = full + pos, *nn = strchr(nl, '\n');
      if (nn) {
        const char *la = nl;
        size_t lal = nn - la, lls = 0;
        while (lls < lal && la[lls] == ' ')
          lls++;
        if (lls < lal && la[lls] == '|') {
          close_leaf_blocks(om, out);
          buf_append(out, "<table><thead><tr>");
          om->t_cols = 0;
          const char *p = la;
          if (*p != '|')
            p = strchr(p, '|');
          if (p)
            p++;
          while (p && p < nn) {
            while (p < nn && isspace(*p))
              p++;
            if (p >= nn)
              break;
            const char *st = p;
            while (p < nn && *p != '|')
              p++;
            const char *ed = p;
            while (ed > st && isspace(ed[-1]))
              ed--;
            Align a = ALIGN_NONE;
            if (st < ed && st[0] == ':' && ed[-1] == ':')
              a = ALIGN_CENTER;
            else if (ed > st && ed[-1] == ':')
              a = ALIGN_RIGHT;
            else if (st < ed && st[0] == ':')
              a = ALIGN_LEFT;
            om->t_aligns[om->t_cols++] = a;
            if (p < nn && *p == '|')
              p++;
          }
          const char *hcs[64];
          size_t hls[64];
          size_t hc = split(rel, rlen, hcs, hls);
          for (size_t k = 0; k < hc; k++) {
            buf_append(out, "<th");
            Align a = (k < om->t_cols) ? om->t_aligns[k] : ALIGN_NONE;
            if (a == ALIGN_LEFT)
              buf_append(out, " style=\"text-align:left\"");
            else if (a == ALIGN_CENTER)
              buf_append(out, " style=\"text-align:center\"");
            else if (a == ALIGN_RIGHT)
              buf_append(out, " style=\"text-align:right\"");
            buf_append(out, ">");
            parse_inline(om, hcs[k], hls[k], out);
            buf_append(out, "</th>");
          }
          buf_append(out, "</tr></thead><tbody>\n");
          stack_push(om, T_TABLE, 0);
          return true;
        }
      }
    }
    if (top_type(om) == T_TABLE) {
      const char *bcs[64];
      size_t bls[64];
      size_t bc = split(rel, rlen, bcs, bls);
      buf_append(out, "<tr>");
      for (size_t k = 0; k < bc; k++) {
        buf_append(out, "<td");
        Align a = (k < om->t_cols) ? om->t_aligns[k] : ALIGN_NONE;
        if (a == ALIGN_LEFT)
          buf_append(out, " style=\"text-align:left\"");
        else if (a == ALIGN_CENTER)
          buf_append(out, " style=\"text-align:center\"");
        else if (a == ALIGN_RIGHT)
          buf_append(out, " style=\"text-align:right\"");
        buf_append(out, ">");
        parse_inline(om, bcs[k], bls[k], out);
        buf_append(out, "</td>");
      }
      buf_append(out, "</tr>\n");
      return false;
    }
  }

  const char *nl = full + pos, *nn = strchr(nl, '\n');
  if (nn) {
    const char *p = nl;
    while (p < nn && isspace(*p))
      p++;
    if (p < nn && *p == ':') {
      close_leaf_blocks(om, out);
      if (om->stack_size == 0 || top_type(om) != T_DL) {
        buf_append(out, "<dl>\n");
        stack_push(om, T_DL, (int)ls);
      }
      buf_append(out, "<dt>");
      parse_inline(om, rel, rlen, out);
      buf_append(out, "</dt>\n");
      return false;
    }
  }

  bool in_c =
      (om->stack_size > 0 && (top_type(om) < T_QUOTE || top_type(om) == T_DD));
  if (top_type(om) != T_P && !in_c) {
    buf_append(out, "<p>");
    stack_push(om, T_P, 0);
  } else if (top_type(om) == T_P || (in_c && !is_u && !is_o && !hdd))
    buf_push(out, '\n');

  bool br = (rlen >= 2 && rel[rlen - 1] == ' ' && rel[rlen - 2] == ' ');
  parse_inline(om, rel, br ? rlen - 2 : rlen, out);
  if (br)
    buf_append(out, "<br>");
  return false;
}
void octomark_feed(OctoMark *om, const char *chunk, size_t len, Buffer *out) {
  buf_append_n(&om->leftover, chunk, len);
  char *data = om->leftover.data;
  size_t size = om->leftover.size, pos = 0;
  while (pos < size) {
    char *next = (char *)memchr(data + pos, '\n', size - pos);
    if (!next)
      break;
    size_t line_len = next - (data + pos);
    bool skip =
        process_line(om, data + pos, line_len, data, pos + line_len + 1, out);
    pos += line_len + 1;
    if (skip) {
      char *nn = (char *)memchr(data + pos, '\n', size - pos);
      if (nn)
        pos = (size_t)(nn - data + 1);
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
  if (om->leftover.size > 0)
    process_line(om, om->leftover.data, om->leftover.size, om->leftover.data,
                 om->leftover.size, out);
  while (om->stack_size > 0)
    pop(om, out);
}
#ifndef OCTOMARK_NO_MAIN
int main() {
  OctoMark om;
  octomark_init(&om);
  Buffer out;
  buf_init(&out, 65536);
  char b[65536];
  size_t n;
  while ((n = fread(b, 1, sizeof(b), stdin)) > 0) {
    octomark_feed(&om, b, n, &out);
    if (out.size > 0) {
      fwrite(out.data, 1, out.size, stdout);
      out.size = 0;
      out.data[0] = '\0';
    }
  }
  octomark_finish(&om, &out);
  if (out.size > 0)
    fwrite(out.data, 1, out.size, stdout);
  buf_free(&out);
  octomark_free(&om);
  return 0;
}
#endif
