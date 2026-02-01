#include <ctype.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  char *data;
  size_t size;
  size_t capacity;
} StringBuffer;

static void string_buffer_init(StringBuffer *buffer, size_t initial_capacity) {
  buffer->data = (char *)malloc(initial_capacity);
  buffer->data[0] = '\0';
  buffer->size = 0;
  buffer->capacity = initial_capacity;
}

static void string_buffer_grow(StringBuffer *buffer, size_t required_capacity) {
  if (buffer->capacity >= required_capacity)
    return;
  size_t new_capacity = buffer->capacity * 2;
  if (new_capacity < required_capacity)
    new_capacity = required_capacity;
  buffer->data = (char *)realloc(buffer->data, new_capacity);
  buffer->capacity = new_capacity;
}

static void string_buffer_append_char(StringBuffer *buffer, char c) {
  if (buffer->size + 2 > buffer->capacity)
    string_buffer_grow(buffer, buffer->size + 2);
  buffer->data[buffer->size++] = c;
  buffer->data[buffer->size] = '\0';
}

static void string_buffer_append_string_n(StringBuffer *buffer, const char *str,
                                          size_t length) {
  if (length == 0)
    return;
  if (buffer->size + length + 1 > buffer->capacity)
    string_buffer_grow(buffer, buffer->size + length + 1);
  memcpy(buffer->data + buffer->size, str, length);
  buffer->size += length;
  buffer->data[buffer->size] = '\0';
}

static void string_buffer_append_string(StringBuffer *buffer, const char *str) {
  string_buffer_append_string_n(buffer, str, strlen(str));
}

static void string_buffer_free(StringBuffer *buffer) {
  free(buffer->data);
  buffer->data = NULL;
  buffer->size = buffer->capacity = 0;
}

#define MAX_BLOCK_NESTING 32
enum {
  BLOCK_UNORDERED_LIST,
  BLOCK_ORDERED_LIST,
  BLOCK_BLOCKQUOTE,
  BLOCK_DEFINITION_LIST,
  BLOCK_DEFINITION_DESCRIPTION,
  BLOCK_CODE,
  BLOCK_MATH,
  BLOCK_TABLE,
  BLOCK_PARAGRAPH
};

typedef struct {
  int block_type;
  int indent_level;
} BlockEntry;

typedef enum {
  ALIGN_NONE,
  ALIGN_LEFT,
  ALIGN_CENTER,
  ALIGN_RIGHT
} TableAlignment;

typedef struct {
  bool is_special_char[256];
  const char *html_escape_map[256];
  TableAlignment table_alignments[64];
  size_t table_column_count;
  BlockEntry block_stack[MAX_BLOCK_NESTING];
  size_t stack_depth;
  StringBuffer pending_buffer;
  bool enable_html;
} OctomarkParser;

static size_t try_parse_html_tag(const char *text, size_t len) {
  if (len < 3 || text[0] != '<')
    return 0;

  size_t i = 1;

  // 1. Comments <!-- ... -->
  if (i + 2 < len && text[i] == '!' && text[i + 1] == '-' &&
      text[i + 2] == '-') {
    i += 3;
    while (i + 2 < len) {
      if (text[i] == '-' && text[i + 1] == '-' && text[i + 2] == '>')
        return i + 3;
      i++;
    }
    return 0; // Unclosed comment
  }

  // 2. CDATA <![CDATA[ ... ]]>
  if (i + 7 < len && strncmp(text + i, "![CDATA[", 8) == 0) {
    i += 8;
    while (i + 2 < len) {
      if (text[i] == ']' && text[i + 1] == ']' && text[i + 2] == '>')
        return i + 3;
      i++;
    }
    return 0;
  }

  // 3. Processing Instructions <? ... ?>
  if (i < len && text[i] == '?') {
    i++;
    while (i + 1 < len) {
      if (text[i] == '?' && text[i + 1] == '>')
        return i + 2;
      i++;
    }
    return 0;
  }

  // 4. Doctype <!DOCTYPE ... >
  if (i < len && text[i] == '!') {
    i++;
    while (i < len) {
      if (text[i] == '>')
        return i + 1;
      i++;
    }
    return 0;
  }

  // 5. Standard Tags (Open </tag> or <tag>)
  if (i < len && text[i] == '/')
    i++;

  if (i >= len || !isalpha(text[i]))
    return 0;

  while (i < len && (isalnum(text[i]) || text[i] == '-' || text[i] == ':'))
    i++;

  // Attributes
  while (i < len && text[i] != '>') {
    char c = text[i];
    if (c == '"' || c == '\'') {
      char quote = c;
      i++;
      while (i < len && text[i] != quote)
        i++;
      if (i >= len)
        return 0; // Unclosed quote
    }
    i++;
  }

  if (i < len && text[i] == '>')
    return i + 1;

  return 0;
}

void octomark_init(OctomarkParser *parser) {
  memset(parser, 0, sizeof(OctomarkParser));
  for (const char *s = "\\['*`&<>\"'_~!$h"; *s; s++)
    parser->is_special_char[(unsigned char)*s] = true;
  parser->html_escape_map['&'] = "&amp;";
  parser->html_escape_map['<'] = "&lt;";
  parser->html_escape_map['>'] = "&gt;";
  parser->html_escape_map['"'] = "&quot;";
  parser->html_escape_map['\''] = "&#39;";
  string_buffer_init(&parser->pending_buffer, 4096);
  parser->enable_html = false;
}
void octomark_free(OctomarkParser *parser) {
  string_buffer_free(&parser->pending_buffer);
}

static inline void push_block(OctomarkParser *parser, int type, int indent) {
  if (parser->stack_depth < MAX_BLOCK_NESTING) {
    parser->block_stack[parser->stack_depth++] = (BlockEntry){type, indent};
  }
}

static inline BlockEntry *peek_block(OctomarkParser *parser) {
  return parser->stack_depth > 0 ? &parser->block_stack[parser->stack_depth - 1]
                                 : NULL;
}

static inline void pop_block(OctomarkParser *parser) {
  if (parser->stack_depth > 0)
    parser->stack_depth--;
}

static inline int get_current_block_type(const OctomarkParser *parser) {
  return parser->stack_depth > 0
             ? parser->block_stack[parser->stack_depth - 1].block_type
             : -1;
}

static void render_and_close_top_block(OctomarkParser *parser,
                                       StringBuffer *output) {
  if (parser->stack_depth == 0)
    return;
  int type = peek_block(parser)->block_type;
  pop_block(parser);
  if (type == BLOCK_UNORDERED_LIST)
    string_buffer_append_string(output, "</li>\n</ul>\n");
  else if (type == BLOCK_ORDERED_LIST)
    string_buffer_append_string(output, "</li>\n</ol>\n");
  else if (type == BLOCK_BLOCKQUOTE)
    string_buffer_append_string(output, "</blockquote>\n");
  else if (type == BLOCK_DEFINITION_LIST)
    string_buffer_append_string(output, "</dl>\n");
  else if (type == BLOCK_DEFINITION_DESCRIPTION)
    string_buffer_append_string(output, "</dd>\n");
  else if (type == BLOCK_CODE)
    string_buffer_append_string(output, "</code></pre>\n");
  else if (type == BLOCK_MATH)
    string_buffer_append_string(output, "</div>\n");
  else if (type == BLOCK_TABLE)
    string_buffer_append_string(output, "</tbody></table>\n");
  else if (type == BLOCK_PARAGRAPH)
    string_buffer_append_string(output, "</p>\n");
}

static void close_paragraph_if_open(OctomarkParser *parser,
                                    StringBuffer *output) {
  if (get_current_block_type(parser) == BLOCK_PARAGRAPH)
    render_and_close_top_block(parser, output);
}

static void close_leaf_blocks(OctomarkParser *parser, StringBuffer *output) {
  int type = get_current_block_type(parser);
  if (type == BLOCK_PARAGRAPH || type == BLOCK_TABLE || type == BLOCK_CODE ||
      type == BLOCK_MATH)
    render_and_close_top_block(parser, output);
}

static inline void append_escaped_text(const OctomarkParser *restrict parser,
                                       const char *restrict text, size_t length,
                                       StringBuffer *restrict output) {
  for (size_t i = 0; i < length; i++) {
    const char *entity = parser->html_escape_map[(unsigned char)text[i]];
    if (entity)
      string_buffer_append_string(output, entity);
    else
      string_buffer_append_char(output, text[i]);
  }
}
static const char *tag_open[] = {"", "<em>", "<strong>", "<strong><em>"};
static const char *tag_close[] = {"", "</em>", "</strong>", "</em></strong>"};

static void parse_inline_content(const OctomarkParser *restrict parser,
                                 const char *restrict text, size_t length,
                                 StringBuffer *restrict output) {
  size_t i = 0;
  while (i < length) {
    size_t start = i;
    // Fast skip: Check 8 bytes at a time for special characters
    while (i + 7 < length) {
      if (parser->is_special_char[(unsigned char)text[i]] ||
          parser->is_special_char[(unsigned char)text[i + 1]] ||
          parser->is_special_char[(unsigned char)text[i + 2]] ||
          parser->is_special_char[(unsigned char)text[i + 3]] ||
          parser->is_special_char[(unsigned char)text[i + 4]] ||
          parser->is_special_char[(unsigned char)text[i + 5]] ||
          parser->is_special_char[(unsigned char)text[i + 6]] ||
          parser->is_special_char[(unsigned char)text[i + 7]])
        break;
      i += 8;
    }

    // Skip single bytes until special or end
    while (i < length && !parser->is_special_char[(unsigned char)text[i]]) {
      i++;
    }

    if (i > start) {
      string_buffer_append_string_n(output, text + start, i - start);
    }

    if (i >= length)
      break;

    // Check for HTML Tags if enabled
    if (text[i] == '<' && parser->enable_html) {
      size_t tag_len = try_parse_html_tag(text + i, length - i);
      if (tag_len > 0) {
        string_buffer_append_string_n(output, text + i, tag_len);
        i += tag_len;
        continue;
      }
    }

    char c = text[i];
    if (c == '\\') {
      if (i + 1 < length)
        string_buffer_append_char(output, text[++i]);
      else
        string_buffer_append_string(output, "<br>");
    } else if (c == '_') {
      size_t content_start = i + 1;
      size_t j = content_start;
      while (j < length && text[j] != '_')
        j++;
      if (j < length) {
        string_buffer_append_string(output, "<em>");
        parse_inline_content(parser, text + content_start, j - content_start,
                             output);
        string_buffer_append_string(output, "</em>");
        i = j;
      } else {
        goto default_char;
      }
    } else if (c == '*' && i + 1 < length && text[i + 1] == '*') {
      size_t content_start = i + 2;
      size_t j = content_start;
      while (j + 1 < length) {
        if (text[j] == '*' && text[j + 1] == '*')
          break;
        j++;
      }
      if (j + 1 < length) {
        string_buffer_append_string(output, "<strong>");
        parse_inline_content(parser, text + content_start, j - content_start,
                             output);
        string_buffer_append_string(output, "</strong>");
        i = j + 1;
      } else {
        goto default_char;
      }
    } else if (c == '`') {
      int backtick_count = 1;
      while (i + backtick_count < length && text[i + backtick_count] == '`')
        backtick_count++;
      string_buffer_append_string(output, "<code>");
      size_t content_start = i + backtick_count;
      while (i + backtick_count < length) {
        i++;
        bool match = true;
        for (int k = 0; k < backtick_count; k++)
          if (i + k >= length || text[i + k] != '`') {
            match = false;
            break;
          }
        if (match)
          break;
      }
      append_escaped_text(parser, text + content_start, i - content_start,
                          output);
      string_buffer_append_string(output, "</code>");
      i += backtick_count - 1;
    } else if (c == '~' && i + 1 < length && text[i + 1] == '~') {
      string_buffer_append_string(output, "<del>");
      i += 2;
      size_t content_start = i;
      while (i + 1 < length && (text[i] != '~' || text[i + 1] != '~'))
        i++;
      parse_inline_content(parser, text + content_start, i - content_start,
                           output);
      string_buffer_append_string(output, "</del>");
      i++;
    } else if (c == '!' || c == '[') {
      size_t start_idx = i;
      if (c == '!')
        i++;
      if (i < length && text[i] == '[') {
        i++;
        size_t link_text_start = i, depth = 1;
        while (i < length && depth > 0) {
          if (text[i] == '[')
            depth++;
          else if (text[i] == ']')
            depth--;
          i++;
        }
        if (i < length && text[i] == '(') {
          size_t link_text_len = i - link_text_start - 1;
          i++;
          size_t url_start = i;
          while (i < length && text[i] != ')' && text[i] != ' ')
            i++;
          size_t url_len = i - url_start;
          while (i < length && text[i] != ')')
            i++;
          if (c == '!') {
            string_buffer_append_string(output, "<img src=\"");
            string_buffer_append_string_n(output, text + url_start, url_len);
            string_buffer_append_string(output, "\" alt=\"");
            string_buffer_append_string_n(output, text + link_text_start,
                                          link_text_len);
            string_buffer_append_string(output, "\">");
          } else {
            string_buffer_append_string(output, "<a href=\"");
            string_buffer_append_string_n(output, text + url_start, url_len);
            string_buffer_append_string(output, "\">");
            parse_inline_content(parser, text + link_text_start, link_text_len,
                                 output);
            string_buffer_append_string(output, "</a>");
          }
          goto next_iteration;
        }
      }
      i = start_idx;
      goto default_char;
    } else if (c == 'h' && (strncmp(text + i, "http", 4) == 0) &&
               (strncmp(text + i + 4, "://", 3) == 0 ||
                strncmp(text + i + 4, "s://", 4) == 0)) {
      size_t url_start = i;
      while (i < length && !isspace(text[i]) && text[i] != '<' &&
             text[i] != '>')
        i++;
      string_buffer_append_string(output, "<a href=\"");
      string_buffer_append_string_n(output, text + url_start, i - url_start);
      string_buffer_append_string(output, "\">");
      string_buffer_append_string_n(output, text + url_start, i - url_start);
      string_buffer_append_string(output, "</a>");
      i--;
    } else if (c == '$') {
      string_buffer_append_string(output, "<span class=\"math\">");
      i++;
      size_t content_start = i;
      while (i < length && text[i] != '$')
        i++;
      append_escaped_text(parser, text + content_start, i - content_start,
                          output);
      string_buffer_append_string(output, "</span>");
    } else {
    default_char:
      if (parser->html_escape_map[(unsigned char)c])
        string_buffer_append_string(output,
                                    parser->html_escape_map[(unsigned char)c]);
      else
        string_buffer_append_char(output, c);
    }
  next_iteration:
    i++;
  }
}
static size_t split_table_row_cells(const char *line, size_t length,
                                    const char **cells, size_t *cell_lengths) {
  size_t count = 0, i = 0;
  while (i < length && isspace(line[i]))
    i++;
  if (i < length && line[i] == '|')
    i++;
  while (i < length) {
    while (i < length && isspace(line[i]))
      i++;
    if (i >= length || line[i] == '\n')
      break;
    cells[count] = line + i;
    size_t start = i;
    while (i < length && line[i] != '|' && line[i] != '\n')
      i++;
    size_t end = i;
    while (end > start && isspace(line[end - 1]))
      end--;
    cell_lengths[count++] = end - start;
    if (i < length && line[i] == '|')
      i++;
  }
  return count;
}
static bool is_block_start_marker(const char *str, size_t len) {
  if (len >= 3 && strncmp(str, "```", 3) == 0)
    return true;
  if (len >= 2 && str[0] == '$' && str[1] == '$')
    return true;
  if (len >= 1 && (str[0] == '#' || str[0] == ':'))
    return true;
  if (len >= 2 && str[0] == '-' && str[1] == ' ')
    return true;
  if (len >= 3 && isdigit(str[0]) && str[1] == '.' && str[2] == ' ')
    return true;
  if (len >= 3 && (strncmp(str, "---", 3) == 0 || strncmp(str, "***", 3) == 0 ||
                   strncmp(str, "___", 3) == 0))
    return true;
  return false;
}

static bool process_leaf_block_continuation(OctomarkParser *parser,
                                            const char *line, size_t len,
                                            StringBuffer *output) {
  int top = get_current_block_type(parser);
  if (top != BLOCK_CODE && top != BLOCK_MATH)
    return false;

  size_t trim_start = 0;
  while (trim_start < len && isspace(line[trim_start]))
    trim_start++;

  if (top == BLOCK_CODE) {
    if (len - trim_start >= 3 && strncmp(line + trim_start, "```", 3) == 0) {
      render_and_close_top_block(parser, output);
      return true;
    }
  } else { /* BLOCK_MATH */
    if (len - trim_start >= 2 && strncmp(line + trim_start, "$$", 2) == 0) {
      render_and_close_top_block(parser, output);
      return true;
    }
  }
  append_escaped_text(parser, line, len, output);
  string_buffer_append_char(output, '\n');
  return true;
}

static bool try_parse_fenced_code_block(OctomarkParser *parser,
                                        const char *line_content,
                                        size_t remaining_len,
                                        StringBuffer *output) {
  if (remaining_len >= 3 && strncmp(line_content, "```", 3) == 0) {
    close_leaf_blocks(parser, output);
    string_buffer_append_string(output, "<pre><code");
    size_t lang_len = 0;
    while (3 + lang_len < remaining_len && !isspace(line_content[3 + lang_len]))
      lang_len++;
    if (lang_len > 0) {
      string_buffer_append_string(output, " class=\"language-");
      append_escaped_text(parser, line_content + 3, lang_len, output);
      string_buffer_append_string(output, "\"");
    }
    string_buffer_append_string(output, ">");
    push_block(parser, BLOCK_CODE, 0);
    return true;
  }
  return false;
}

static bool try_parse_math_block(OctomarkParser *parser,
                                 const char *line_content, size_t remaining_len,
                                 StringBuffer *output) {
  if (remaining_len >= 2 && line_content[0] == '$' && line_content[1] == '$') {
    close_leaf_blocks(parser, output);
    string_buffer_append_string(output, "<div class=\"math\">\n");
    push_block(parser, BLOCK_MATH, 0);
    return true;
  }
  return false;
}

static bool try_parse_header(OctomarkParser *parser, const char *line_content,
                             size_t remaining_len, StringBuffer *output) {
  if (remaining_len >= 2 && line_content[0] == '#') {
    size_t level = 0;
    while (level < 6 && level < remaining_len && line_content[level] == '#')
      level++;
    if (level < remaining_len && line_content[level] == ' ') {
      close_leaf_blocks(parser, output);
      char tag[] = "<h1>";
      tag[2] = '0' + level;
      string_buffer_append_string(output, tag);
      parse_inline_content(parser, line_content + level + 1,
                           remaining_len - level - 1, output);
      tag[1] = '/';
      tag[2] = 'h';
      tag[3] = '0' + level;
      string_buffer_append_string_n(output, tag, 4);
      string_buffer_append_string(output, ">\n");
      return true;
    }
  }
  return false;
}

static bool try_parse_horizontal_rule(OctomarkParser *parser,
                                      const char *line_content,
                                      size_t remaining_len,
                                      StringBuffer *output) {
  if (remaining_len == 3 && (strncmp(line_content, "---", 3) == 0 ||
                             strncmp(line_content, "***", 3) == 0 ||
                             strncmp(line_content, "___", 3) == 0)) {
    close_leaf_blocks(parser, output);
    string_buffer_append_string(output, "<hr>\n");
    return true;
  }
  return false;
}

static bool try_parse_definition_list(OctomarkParser *parser,
                                      const char **line_content_ptr,
                                      size_t *remaining_len_ptr,
                                      size_t leading_spaces,
                                      StringBuffer *output) {
  const char *line_content = *line_content_ptr;
  size_t remaining_len = *remaining_len_ptr;
  if (remaining_len > 0 && line_content[0] == ':') {
    line_content++;
    remaining_len--;
    if (remaining_len > 0 && line_content[0] == ' ') {
      line_content++;
      remaining_len--;
    }
    close_paragraph_if_open(parser, output);
    bool in_dl = false, in_dd = false;
    for (size_t k = 0; k < parser->stack_depth; k++) {
      if (parser->block_stack[k].block_type == BLOCK_DEFINITION_LIST)
        in_dl = true;
      if (parser->block_stack[k].block_type == BLOCK_DEFINITION_DESCRIPTION)
        in_dd = true;
    }
    if (!in_dl) {
      string_buffer_append_string(output, "<dl>\n");
      push_block(parser, BLOCK_DEFINITION_LIST, (int)leading_spaces);
    }
    if (in_dd)
      while (get_current_block_type(parser) != BLOCK_DEFINITION_LIST &&
             parser->stack_depth > 0)
        render_and_close_top_block(parser, output);
    string_buffer_append_string(output, "<dd>");
    push_block(parser, BLOCK_DEFINITION_DESCRIPTION, (int)leading_spaces);
    *line_content_ptr = line_content;
    *remaining_len_ptr = remaining_len;
    return true;
  }
  return false;
}

static bool try_parse_list_item(OctomarkParser *parser,
                                const char **line_content_ptr,
                                size_t *remaining_len_ptr,
                                size_t leading_spaces, StringBuffer *output) {
  const char *line_content = *line_content_ptr;
  size_t remaining_len = *remaining_len_ptr;
  size_t internal_spaces = 0;
  while (internal_spaces < remaining_len &&
         line_content[internal_spaces] == ' ')
    internal_spaces++;
  bool is_ul = (remaining_len - internal_spaces >= 2 &&
                line_content[internal_spaces] == '-' &&
                line_content[internal_spaces + 1] == ' '),
       is_ol = (remaining_len - internal_spaces >= 3 &&
                isdigit(line_content[internal_spaces]) &&
                line_content[internal_spaces + 1] == '.' &&
                line_content[internal_spaces + 2] == ' ');

  if (is_ul || is_ol) {
    int target_type = (is_ul ? BLOCK_UNORDERED_LIST : BLOCK_ORDERED_LIST);
    int current_indent = (int)(leading_spaces + internal_spaces);
    while (parser->stack_depth > 0 &&
           get_current_block_type(parser) < BLOCK_BLOCKQUOTE &&
           (peek_block(parser)->indent_level > current_indent ||
            (peek_block(parser)->indent_level == current_indent &&
             get_current_block_type(parser) != target_type)))
      render_and_close_top_block(parser, output);

    int top = get_current_block_type(parser);
    if (top == target_type &&
        peek_block(parser)->indent_level == current_indent) {
      close_leaf_blocks(parser, output);
      string_buffer_append_string(output, "</li>\n<li>");
    } else {
      close_leaf_blocks(parser, output);
      string_buffer_append_string(output, target_type == BLOCK_UNORDERED_LIST
                                              ? "<ul>\n<li>"
                                              : "<ol>\n<li>");
      push_block(parser, target_type, current_indent);
    }
    line_content += internal_spaces + (is_ul ? 2 : 3);
    remaining_len -= internal_spaces + (is_ul ? 2 : 3);
    if (is_ul && remaining_len >= 4 && line_content[0] == '[' &&
        (line_content[1] == ' ' || line_content[1] == 'x') &&
        line_content[2] == ']' && line_content[3] == ' ') {
      string_buffer_append_string(
          output, line_content[1] == 'x'
                      ? "<input type=\"checkbox\" checked disabled> "
                      : "<input type=\"checkbox\"  disabled> ");
      line_content += 4;
      remaining_len -= 4;
    }
    *line_content_ptr = line_content;
    *remaining_len_ptr = remaining_len;
    return true;
  }
  return false;
}

static bool try_parse_table(OctomarkParser *parser, const char *line_content,
                            size_t remaining_len, const char *full_data,
                            size_t current_pos, StringBuffer *output) {
  if (remaining_len > 0 && line_content[0] == '|') {
    if (get_current_block_type(parser) != BLOCK_TABLE) {
      const char *next_line = full_data + current_pos,
                 *next_newline = strchr(next_line, '\n');
      if (next_newline) {
        const char *lookahead = next_line;
        size_t lookahead_len = next_newline - lookahead, la_spaces = 0;
        while (la_spaces < lookahead_len && lookahead[la_spaces] == ' ')
          la_spaces++;
        if (la_spaces < lookahead_len && lookahead[la_spaces] == '|') {
          close_leaf_blocks(parser, output);
          string_buffer_append_string(output, "<table><thead><tr>");
          parser->table_column_count = 0;
          const char *p = lookahead;
          if (*p != '|')
            p = strchr(p, '|');
          if (p)
            p++;
          while (p && p < next_newline) {
            while (p < next_newline && isspace(*p))
              p++;
            if (p >= next_newline)
              break;
            const char *start = p;
            while (p < next_newline && *p != '|')
              p++;
            const char *end = p;
            while (end > start && isspace(end[-1]))
              end--;
            TableAlignment align = ALIGN_NONE;
            if (start < end && start[0] == ':' && end[-1] == ':')
              align = ALIGN_CENTER;
            else if (end > start && end[-1] == ':')
              align = ALIGN_RIGHT;
            else if (start < end && start[0] == ':')
              align = ALIGN_LEFT;
            parser->table_alignments[parser->table_column_count++] = align;
            if (p < next_newline && *p == '|')
              p++;
          }
          const char *header_cells[64];
          size_t header_lens[64];
          size_t header_count = split_table_row_cells(
              line_content, remaining_len, header_cells, header_lens);
          for (size_t k = 0; k < header_count; k++) {
            string_buffer_append_string(output, "<th");
            TableAlignment align = (k < parser->table_column_count)
                                       ? parser->table_alignments[k]
                                       : ALIGN_NONE;
            if (align == ALIGN_LEFT)
              string_buffer_append_string(output, " style=\"text-align:left\"");
            else if (align == ALIGN_CENTER)
              string_buffer_append_string(output,
                                          " style=\"text-align:center\"");
            else if (align == ALIGN_RIGHT)
              string_buffer_append_string(output,
                                          " style=\"text-align:right\"");
            string_buffer_append_string(output, ">");
            parse_inline_content(parser, header_cells[k], header_lens[k],
                                 output);
            string_buffer_append_string(output, "</th>");
          }
          string_buffer_append_string(output, "</tr></thead><tbody>\n");
          push_block(parser, BLOCK_TABLE, 0);
          return true;
        }
      }
    }
    if (get_current_block_type(parser) == BLOCK_TABLE) {
      const char *body_cells[64];
      size_t body_lens[64];
      size_t body_count = split_table_row_cells(line_content, remaining_len,
                                                body_cells, body_lens);
      string_buffer_append_string(output, "<tr>");
      for (size_t k = 0; k < body_count; k++) {
        string_buffer_append_string(output, "<td");
        TableAlignment align = (k < parser->table_column_count)
                                   ? parser->table_alignments[k]
                                   : ALIGN_NONE;
        if (align == ALIGN_LEFT)
          string_buffer_append_string(output, " style=\"text-align:left\"");
        else if (align == ALIGN_CENTER)
          string_buffer_append_string(output, " style=\"text-align:center\"");
        else if (align == ALIGN_RIGHT)
          string_buffer_append_string(output, " style=\"text-align:right\"");
        string_buffer_append_string(output, ">");
        parse_inline_content(parser, body_cells[k], body_lens[k], output);
        string_buffer_append_string(output, "</td>");
      }
      string_buffer_append_string(output, "</tr>\n");
      return true;
    }
  }
  return false;
}

static bool try_parse_definition_term(OctomarkParser *parser,
                                      const char *line_content,
                                      size_t remaining_len,
                                      const char *full_data, size_t current_pos,
                                      StringBuffer *output) {
  const char *next_line = full_data + current_pos,
             *next_newline = strchr(next_line, '\n');
  if (next_newline) {
    const char *p = next_line;
    while (p < next_newline && isspace(*p))
      p++;
    if (p < next_newline && *p == ':') {
      close_leaf_blocks(parser, output);
      if (parser->stack_depth == 0 ||
          get_current_block_type(parser) != BLOCK_DEFINITION_LIST) {
        string_buffer_append_string(output, "<dl>\n");
        push_block(parser, BLOCK_DEFINITION_LIST, 0);
      }
      string_buffer_append_string(output, "<dt>");
      parse_inline_content(parser, line_content, remaining_len, output);
      string_buffer_append_string(output, "</dt>\n");
      return true;
    }
  }
  return false;
}

static void process_paragraph(OctomarkParser *parser, const char *line_content,
                              size_t remaining_len, bool is_dl, bool is_list,
                              StringBuffer *output) {
  bool in_container =
      (parser->stack_depth > 0 &&
       (get_current_block_type(parser) < BLOCK_BLOCKQUOTE ||
        get_current_block_type(parser) == BLOCK_DEFINITION_DESCRIPTION));
  if (get_current_block_type(parser) != BLOCK_PARAGRAPH && !in_container) {
    string_buffer_append_string(output, "<p>");
    push_block(parser, BLOCK_PARAGRAPH, 0);
  } else if (get_current_block_type(parser) == BLOCK_PARAGRAPH ||
             (in_container && !is_list && !is_dl))
    string_buffer_append_char(output, '\n');

  bool line_break =
      (remaining_len >= 2 && line_content[remaining_len - 1] == ' ' &&
       line_content[remaining_len - 2] == ' ');
  parse_inline_content(parser, line_content,
                       line_break ? remaining_len - 2 : remaining_len, output);
  if (line_break)
    string_buffer_append_string(output, "<br>");
}

bool process_single_line(OctomarkParser *restrict parser,
                         const char *restrict line, size_t len,
                         const char *restrict full_data, size_t current_pos,
                         StringBuffer *restrict output) {
  if (process_leaf_block_continuation(parser, line, len, output))
    return false;

  size_t leading_spaces = 0;
  while (leading_spaces < len && line[leading_spaces] == ' ')
    leading_spaces++;
  const char *line_content = line + leading_spaces;
  size_t remaining_len = len - leading_spaces;

  if (remaining_len == 0) {
    close_leaf_blocks(parser, output);
    while (parser->stack_depth > 0 &&
           get_current_block_type(parser) >= BLOCK_BLOCKQUOTE)
      render_and_close_top_block(parser, output);
    return false;
  }

  size_t quote_level = 0;
  while (remaining_len > 0 && line_content[0] == '>') {
    quote_level++;
    line_content++;
    remaining_len--;
    if (remaining_len > 0 && line_content[0] == ' ') {
      line_content++;
      remaining_len--;
    }
  }

  size_t current_quote_level = 0;
  for (size_t k = 0; k < parser->stack_depth; k++)
    if (parser->block_stack[k].block_type == BLOCK_BLOCKQUOTE)
      current_quote_level++;

  if (quote_level < current_quote_level &&
      get_current_block_type(parser) == BLOCK_PARAGRAPH) {
    size_t ti = 0;
    while (ti < remaining_len && line_content[ti] == ' ')
      ti++;
    if (!is_block_start_marker(line_content + ti, remaining_len - ti))
      quote_level = current_quote_level;
  }

  while (current_quote_level > quote_level) {
    int t = get_current_block_type(parser);
    render_and_close_top_block(parser, output);
    if (t == BLOCK_BLOCKQUOTE)
      current_quote_level--;
  }

  while (parser->stack_depth < quote_level) {
    close_paragraph_if_open(parser, output);
    string_buffer_append_string(output, "<blockquote>");
    push_block(parser, BLOCK_BLOCKQUOTE, 0);
  }

  bool is_dl = try_parse_definition_list(parser, &line_content, &remaining_len,
                                         leading_spaces, output);
  bool is_list = try_parse_list_item(parser, &line_content, &remaining_len,
                                     leading_spaces, output);

  if (try_parse_fenced_code_block(parser, line_content, remaining_len, output))
    return false;
  if (try_parse_math_block(parser, line_content, remaining_len, output))
    return false;
  if (try_parse_header(parser, line_content, remaining_len, output))
    return false;
  if (try_parse_horizontal_rule(parser, line_content, remaining_len, output))
    return false;
  if (try_parse_table(parser, line_content, remaining_len, full_data,
                      current_pos, output))
    return true; /* Skip next */
  if (try_parse_definition_term(parser, line_content, remaining_len, full_data,
                                current_pos, output))
    return false;

  process_paragraph(parser, line_content, remaining_len, is_dl, is_list,
                    output);
  return false;
}
void octomark_feed(OctomarkParser *parser, const char *chunk, size_t len,
                   StringBuffer *output) {
  string_buffer_append_string_n(&parser->pending_buffer, chunk, len);
  char *data = parser->pending_buffer.data;
  size_t size = parser->pending_buffer.size, pos = 0;
  while (pos < size) {
    char *next = (char *)memchr(data + pos, '\n', size - pos);
    if (!next)
      break;
    size_t line_len = next - (data + pos);
    bool skip = process_single_line(parser, data + pos, line_len, data,
                                    pos + line_len + 1, output);
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
    parser->pending_buffer.size = rem;
    data[rem] = '\0';
  }
}
void octomark_finish(OctomarkParser *parser, StringBuffer *output) {
  if (parser->pending_buffer.size > 0)
    process_single_line(
        parser, parser->pending_buffer.data, parser->pending_buffer.size,
        parser->pending_buffer.data, parser->pending_buffer.size, output);
  while (parser->stack_depth > 0)
    render_and_close_top_block(parser, output);
}
#ifndef OCTOMARK_NO_MAIN
int main() {
  OctomarkParser parser;
  octomark_init(&parser);
  StringBuffer output;
  string_buffer_init(&output, 65536);
  char buffer[65536];
  size_t n;
  while ((n = fread(buffer, 1, sizeof(buffer), stdin)) > 0) {
    octomark_feed(&parser, buffer, n, &output);
    if (output.size > 0) {
      fwrite(output.data, 1, output.size, stdout);
      output.size = 0;
      output.data[0] = '\0';
    }
  }
  octomark_finish(&parser, &output);
  if (output.size > 0)
    fwrite(output.data, 1, output.size, stdout);
  string_buffer_free(&output);
  octomark_free(&parser);
  return 0;
}
#endif
