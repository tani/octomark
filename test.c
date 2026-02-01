#define OCTOMARK_NO_MAIN
#include "octomark.c"
#include <stdio.h>
#include <string.h>

typedef struct {
  const char *name;
  const char *input;
  const char *expected;
} TestCase;

TestCase tests[] = {
    {"Heading", "# Hello World", "<h1>Hello World</h1>\n"},
    {"Blockquote", "> This is a quote",
     "<blockquote>This is a quote</blockquote>\n"},
    {"Horizontal Rule", "---", "<hr>\n"},
    {"Inline Styles", "**Bold** and _Italic_ and `Code`",
     "<p><strong>Bold</strong> and <em>Italic</em> and "
     "<code>Code</code></p>\n"},
    {"Links", "[Google](https://google.com)",
     "<p><a href=\"https://google.com\">Google</a></p>\n"},
    {"Escaping", "\\*Not Bold\\*", "<p>*Not Bold*</p>\n"},
    {"Fenced Code Block", "```js\nconsole.log('hi');\n```",
     "<pre><code "
     "class=\"language-js\">console.log(&#39;hi&#39;);\n</code></pre>\n"},
    {"Unordered List", "- Item 1\n- Item 2",
     "<ul>\n<li>Item 1</li>\n<li>Item 2</li>\n</ul>\n"},
    {"Task List", "- [ ] Todo\n- [x] Done",
     "<ul>\n<li><input type=\"checkbox\"  disabled> Todo</li>\n<li><input "
     "type=\"checkbox\" checked disabled> Done</li>\n</ul>\n"},
    {"Nested List (4 spaces)", "- Level 1\n    - Level 2\n- Back to 1",
     "<ul>\n<li>Level 1</li>\n<ul>\n<li>Level 2</li>\n</ul>\n<li>Back to "
     "1</li>\n</ul>\n"},
    {"Table", "| Head A | Head B |\n|---|---|\n| Cell 1 | Cell 2 |",
     "<table><thead><tr><th>Head A</th><th>Head B</th></tr></thead><tbody>\n"
     "<tr><td>Cell 1</td><td>Cell 2</td></tr>\n</tbody></table>\n"},
    {"Aligned Table",
     "| Left | Center | Right |\n|:---|:---:|---:|\n| A | B | C |",
     "<table><thead><tr><th style=\"text-align:left\">Left</th><th "
     "style=\"text-align:center\">Center</th><th "
     "style=\"text-align:right\">Right</th>"
     "</tr></thead><tbody>\n"
     "<tr><td style=\"text-align:left\">A</td><td "
     "style=\"text-align:center\">B</td><td "
     "style=\"text-align:right\">C</td></tr>\n"
     "</tbody></table>\n"},
    {"Table with Spaces in Separator", "| Head |\n|  :--- |\n| Cell |",
     "<table><thead><tr><th "
     "style=\"text-align:left\">Head</th></tr></thead><tbody>\n"
     "<tr><td style=\"text-align:left\">Cell</td></tr>\n</tbody></table>\n"},
    {"Nested Inline Styles", "**_Bold Italic_**",
     "<p><strong><em>Bold Italic</em></strong></p>\n"},
    {"Table with Inline Styles",
     "| **Bold** | `Code` |\n|---|---|\n| _Italic_ | [Link](url) |",
     "<table><thead><tr><th><strong>Bold</strong></th><th><code>Code</code></"
     "th></tr></thead><tbody>\n"
     "<tr><td><em>Italic</em></td><td><a href=\"url\">Link</a></td></tr>\n"
     "</tbody></table>\n"},
    {"Code Block Escaping", "```html\n<div></div>\n```",
     "<pre><code "
     "class=\"language-html\">&lt;div&gt;&lt;/div&gt;\n</code></pre>\n"},
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
    {"Block Math", "$$\nx^2 + y^2 = z^2\n$$",
     "<div class=\"math\">x^2 + y^2 = z^2\n</div>\n"},
    {"Inline Math", "The formula is $E=mc^2$ is famous.",
     "<p>The formula is <span class=\"math\">E=mc^2</span> is famous.</p>\n"},
    {"Linear Paragraphs", "Line 1\nLine 2", "<p>Line 1</p>\n<p>Line 2</p>\n"},
    {NULL, NULL, NULL}};

int main() {
  OctoMark om;
  Buffer output;
  int passed = 0;
  int failed = 0;

  printf("--- OctoMark C Correctness Tests ---\n");

  for (int i = 0; tests[i].name != NULL; i++) {
    octomark_init(&om);
    buf_init(&output, 1024);

    octomark_feed(&om, tests[i].input, strlen(tests[i].input), &output);
    octomark_finish(&om, &output);

    if (strcmp(output.data, tests[i].expected) == 0) {
      passed++;
    } else {
      printf("[FAIL] %s\n", tests[i].name);
      printf("Expected: [%s]\n", tests[i].expected);
      printf("Actual:   [%s]\n", output.data);
      failed++;
    }

    buf_free(&output);
    octomark_free(&om);
  }

  printf("\nTest Summary: %d Passed, %d Failed.\n", passed, failed);
  return failed > 0 ? 1 : 0;
}
