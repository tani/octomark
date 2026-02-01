#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define OCTOMARK_NO_MAIN
#include "octomark.c"

typedef struct {
  const char *name;
  const char *input;
  const char *expected;
} TestCase;

TestCase tests[] = {
    {"Simple Paragraph", "Hello, OctoMark!", "<p>Hello, OctoMark!</p>\n"},
    {"Heading1", "# Welcome", "<h1>Welcome</h1>\n"},
    {"Heading2", "## Subtitle", "<h2>Subtitle</h2>\n"},
    {"Horizontal Rule", "---", "<hr>\n"},
    {"Strong Style", "**Bold**", "<p><strong>Bold</strong></p>\n"},
    {"Emphasis Style", "*Italic*", "<p><em>Italic</em></p>\n"},
    {"Inline Code", "`code`", "<p><code>code</code></p>\n"},
    {"Fenced Code Block", "```js\nconst x = 1;\n```",
     "<pre><code class=\"language-js\">const x = 1;\n</code></pre>\n"},
    {"Nested Blockquotes", "> > Double quote",
     "<blockquote><blockquote><p>Double "
     "quote</p>\n</blockquote>\n</blockquote>\n"},
    {"Link with Title", "[Google](https://google.com)",
     "<p><a href=\"https://google.com\">Google</a></p>\n"},
    {"Hard Line Break", "Line 1  \nLine 2", "<p>Line 1<br>\nLine 2</p>\n"},
    {"Table Support", "| Header | Value |\n|--|--:|\n| Data | 100 |",
     "<table><thead><tr><th>Header</th><th "
     "style=\"text-align:right\">Value</th></tr></thead><tbody>\n<tr><td>Data</"
     "td><td style=\"text-align:right\">100</td></tr>\n</tbody></table>\n"},
    {"Complex Definition List", "Term\n: Def 1\n: Def 2",
     "<dl>\n<dt>Term</dt>\n<dd>Def 1</dd>\n<dd>Def 2</dd>\n</dl>\n"},
    {"Math Support", "$$E=mc^2$$", "<div class=\"math\">\n</div>\n"},
    {"Inline Styles", "**Bold** and *Italic* and `Code`",
     "<p><strong>Bold</strong> and <em>Italic</em> and "
     "<code>Code</code></p>\n"},
    {"Links", "[Google](https://google.com)",
     "<p><a href=\"https://google.com\">Google</a></p>\n"},
    {"Escaping", "\\*Not Bold\\*", "<p>*Not Bold*</p>\n"},
    {"Unordered List", "- Item 1\n- Item 2",
     "<ul>\n<li>Item 1</li>\n<li>Item 2</li>\n</ul>\n"},
    {"Task List", "- [ ] Todo\n- [x] Done",
     "<ul>\n<li><input type=\"checkbox\"  disabled> Todo</li>\n<li><input "
     "type=\"checkbox\" checked disabled> Done</li>\n</ul>\n"},
    {"Nested List (2 spaces)", "- Level 1\n  - Level 2\n- Back to 1",
     "<ul>\n"
     "<li>Level 1<ul>\n"
     "<li>Level 2</li>\n"
     "</ul>\n"
     "</li>\n"
     "<li>Back to 1</li>\n"
     "</ul>\n"},
    {"Nested Inline Styles", "***Bold Italic***",
     "<p><strong><em>Bold Italic</em></strong></p>\n"},
    {"Definition List", "Term\n: # Def Heading\n: - Item 1\n: - Item 2",
     "<dl>\n<dt>Term</dt>\n<dd><h1>Def Heading</h1>\n</dd>\n<dd><ul>\n<li>Item "
     "1</li>\n</ul>\n</dd>\n<dd><ul>\n<li>Item 2</li>\n</ul>\n</dd>\n</dl>\n"},
    {"Mixed List Types", "- Regular\n- [ ] Task",
     "<ul>\n<li>Regular</li>\n<li><input type=\"checkbox\"  disabled> "
     "Task</li>\n</ul>\n"},
    {"Ordered List", "1. Item 1\n2. Item 2",
     "<ol>\n<li>Item 1</li>\n<li>Item 2</li>\n</ol>\n"},
    {"Image", "![Octo](https://octo.com/logo.png)",
     "<p><img src=\"https://octo.com/logo.png\" alt=\"Octo\"></p>\n"},
    {"Strikethrough", "~~Deleted text~~", "<p><del>Deleted text</del></p>\n"},
    {"Autolink", "Search on https://google.com now",
     "<p>Search on <a href=\"https://google.com\">https://google.com</a> "
     "now</p>\n"},
    {"Mixed List Transformation", "- Bullet\n1. Numbered",
     "<ul>\n<li>Bullet</li>\n</ul>\n<ol>\n<li>Numbered</li>\n</ol>\n"},
    {"Inline Math", "The formula is $E=mc^2$ is famous.",
     "<p>The formula is <span class=\"math\">E=mc^2</span> is famous.</p>\n"},
    {"Linear Paragraphs", "Line 1\nLine 2", "<p>Line 1\nLine 2</p>\n"},
    {"Lazy Blockquote", "> Line 1\nLine 2",
     "<blockquote><p>Line 1\nLine 2</p>\n</blockquote>\n"},
    {"Lazy Blockquote Break", "> Line 1\n## Header",
     "<blockquote><p>Line 1</p>\n</blockquote>\n<h2>Header</h2>\n"},
    {"Lazy List Continuation", "- Item 1\nContinued",
     "<ul>\n<li>Item 1\nContinued</li>\n</ul>\n"},
    {"Indented List Continuation", "- Item 1\n  Continued",
     "<ul>\n<li>Item 1\nContinued</li>\n</ul>\n"},
    {"Definition List Continuation", "Term\n: Def 1\n  Continued",
     "<dl>\n<dt>Term</dt>\n<dd>Def 1\nContinued</dd>\n</dl>\n"},
    {"Space Hard Break", "Line 1  \nLine 2", "<p>Line 1<br>\nLine 2</p>\n"},
    {"Backslash Hard Break", "Line 1\\\nLine 2",
     "<p>Line 1<br>\nLine 2</p>\n"}};

void run_html_test() {
  printf("Running HTML Support Test...\n");
  OctomarkParser parser;
  StringBuffer out;
  string_buffer_init(&out, 4096);
  octomark_init(&parser);
  parser.enable_html = true;
  
  const char *input = "<b>Bold</b> <DIV>Mixed</DIV> <sPaN class=\"foo\">Span</sPaN> <br/> <!-- Comment --> <invalid\n"
                      "Mixed with **Markdown**: <i>Italic</i> and `code`";
  const char *expected = "<p><b>Bold</b> <DIV>Mixed</DIV> <sPaN class=\"foo\">Span</sPaN> <br/> <!-- Comment --> &lt;invalid\nMixed with <strong>Markdown</strong>: <i>Italic</i> and <code>code</code></p>\n";
  
  octomark_feed(&parser, input, strlen(input), &out);
  octomark_finish(&parser, &out);
  
  if (strcmp(out.data, expected) == 0) {
    printf("[PASS] HTML Support Test\n");
  } else {
    printf("[FAIL] HTML Support Test\n");
    printf("Expected: [%s]\n", expected);
    printf("Actual:   [%s]\n", out.data);
  }
  
  string_buffer_free(&out);
  octomark_free(&parser);
}

int main() {
  printf("--- OctoMark C Correctness Tests ---\n");
  OctomarkParser parser;
  StringBuffer out;
  string_buffer_init(&out, 65536);
  int passed = 0;
  int total = sizeof(tests) / sizeof(TestCase);

  for (int i = 0; i < total; i++) {
    octomark_init(&parser);
    out.size = 0;
    octomark_feed(&parser, tests[i].input, strlen(tests[i].input), &out);
    octomark_finish(&parser, &out);

    if (strcmp(out.data, tests[i].expected) == 0) {
      passed++;
    } else {
      printf("[FAIL] %s\n", tests[i].name);
      printf("Expected: [%s]\n", tests[i].expected);
      printf("Actual:   [%s]\n", out.data);
    }
    octomark_free(&parser);
  }

  run_html_test();

  printf("\nTest Summary: %d Passed, %d Failed.\n", passed, total - passed);
  string_buffer_free(&out);
  return (passed == total) ? 0 : 1;
}
