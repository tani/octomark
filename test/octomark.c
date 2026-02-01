#include <stdio.h>

#include "test_framework.h"

static const TestCase tests[] = {
    {"Simple Paragraph", "Hello, OctoMark!", "<p>Hello, OctoMark!</p>\n",
     false},
    {"Heading1", "# Welcome", "<h1>Welcome</h1>\n", false},
    {"Heading2", "## Subtitle", "<h2>Subtitle</h2>\n", false},
    {"Horizontal Rule", "---", "<hr>\n", false},
    {"Strong Style", "**Bold**", "<p><strong>Bold</strong></p>\n", false},
    {"Emphasis Style", "_Italic_", "<p><em>Italic</em></p>\n", false},
    {"Inline Code", "`code`", "<p><code>code</code></p>\n", false},
    {"Fenced Code Block", "```js\nconst x = 1;\n```",
     "<pre><code class=\"language-js\">const x = 1;\n</code></pre>\n", false},
    {"Nested Blockquotes", "> > Double quote",
     "<blockquote><blockquote><p>Double "
     "quote</p>\n</blockquote>\n</blockquote>\n",
     false},
    {"Link with Title", "[Google](https://google.com)",
     "<p><a href=\"https://google.com\">Google</a></p>\n", false},
    {"Hard Line Break", "Line 1  \nLine 2", "<p>Line 1<br>\nLine 2</p>\n",
     false},
    {"Table Support", "| Header | Value |\n|--|--:|\n| Data | 100 |",
     "<table><thead><tr><th>Header</th><th "
     "style=\"text-align:right\">Value</th></tr></thead><tbody>\n<tr><td>Data</"
     "td><td style=\"text-align:right\">100</td></tr>\n</tbody></table>\n",
     false},
    {"Complex Definition List", "Term\n: Def 1\n: Def 2",
     "<dl>\n<dt>Term</dt>\n<dd>Def 1</dd>\n<dd>Def 2</dd>\n</dl>\n", false},
    {"Math Support", "$$E=mc^2$$", "<div class=\"math\">\n</div>\n", false},
    {"Inline Styles", "**Bold** and _Italic_ and `Code`",
     "<p><strong>Bold</strong> and <em>Italic</em> and "
     "<code>Code</code></p>\n",
     false},
    {"Links", "[Google](https://google.com)",
     "<p><a href=\"https://google.com\">Google</a></p>\n", false},
    {"Escaping", "\\*Not Bold\\*", "<p>*Not Bold*</p>\n", false},
    {"Unordered List", "- Item 1\n- Item 2",
     "<ul>\n<li>Item 1</li>\n<li>Item 2</li>\n</ul>\n", false},
    {"Task List", "- [ ] Todo\n- [x] Done",
     "<ul>\n<li><input type=\"checkbox\"  disabled> Todo</li>\n<li><input "
     "type=\"checkbox\" checked disabled> Done</li>\n</ul>\n",
     false},
    {"Nested List (2 spaces)", "- Level 1\n  - Level 2\n- Back to 1",
     "<ul>\n"
     "<li>Level 1<ul>\n"
     "<li>Level 2</li>\n"
     "</ul>\n"
     "</li>\n"
     "<li>Back to 1</li>\n"
     "</ul>\n",
     false},
    {"Nested Inline Styles", "**Bold _Italic_**",
     "<p><strong>Bold <em>Italic</em></strong></p>\n", false},
    {"Definition List", "Term\n: # Def Heading\n: - Item 1\n: - Item 2",
     "<dl>\n<dt>Term</dt>\n<dd><h1>Def Heading</h1>\n</dd>\n<dd><ul>\n<li>Item "
     "1</li>\n</ul>\n</dd>\n<dd><ul>\n<li>Item 2</li>\n</ul>\n</dd>\n</dl>\n",
     false},
    {"Mixed List Types", "- Regular\n- [ ] Task",
     "<ul>\n<li>Regular</li>\n<li><input type=\"checkbox\"  disabled> "
     "Task</li>\n</ul>\n",
     false},
    {"Ordered List", "1. Item 1\n2. Item 2",
     "<ol>\n<li>Item 1</li>\n<li>Item 2</li>\n</ol>\n", false},
    {"Image", "![Octo](https://octo.com/logo.png)",
     "<p><img src=\"https://octo.com/logo.png\" alt=\"Octo\"></p>\n", false},
    {"Strikethrough", "~~Deleted text~~", "<p><del>Deleted text</del></p>\n",
     false},
    {"Autolink", "Search on https://google.com now",
     "<p>Search on <a href=\"https://google.com\">https://google.com</a> "
     "now</p>\n",
     false},
    {"Mixed List Transformation", "- Bullet\n1. Numbered",
     "<ul>\n<li>Bullet</li>\n</ul>\n<ol>\n<li>Numbered</li>\n</ol>\n", false},
    {"Inline Math", "The formula is $E=mc^2$ is famous.",
     "<p>The formula is <span class=\"math\">E=mc^2</span> is famous.</p>\n",
     false},
    {"Linear Paragraphs", "Line 1\nLine 2", "<p>Line 1\nLine 2</p>\n", false},
    {"Lazy Blockquote", "> Line 1\nLine 2",
     "<blockquote><p>Line 1\nLine 2</p>\n</blockquote>\n",
     false},
    {"Lazy Blockquote Break", "> Line 1\n## Header",
     "<blockquote><p>Line 1</p>\n</blockquote>\n<h2>Header</h2>\n",
     false},
    {"Lazy List Continuation", "- Item 1\nContinued",
     "<ul>\n<li>Item 1\nContinued</li>\n</ul>\n", false},
    {"Indented List Continuation", "- Item 1\n  Continued",
     "<ul>\n<li>Item 1\nContinued</li>\n</ul>\n", false},
    {"Definition List Continuation", "Term\n: Def 1\n  Continued",
     "<dl>\n<dt>Term</dt>\n<dd>Def 1\nContinued</dd>\n</dl>\n", false},
    {"Space Hard Break", "Line 1  \nLine 2", "<p>Line 1<br>\nLine 2</p>\n",
     false},
    {"Backslash Hard Break", "Line 1\\\nLine 2",
     "<p>Line 1<br>\nLine 2</p>\n", false},
    {"HTML Support",
     "<b>Bold</b> <DIV>Mixed</DIV> <sPaN class=\"foo\">Span</sPaN> <br/> <!-- "
     "Comment --> <invalid\n"
     "Mixed with **Markdown**: <i>Italic</i> and `code`",
     "<p><b>Bold</b> <DIV>Mixed</DIV> <sPaN class=\"foo\">Span</sPaN> <br/> <!-- "
     "Comment --> &lt;invalid\nMixed with <strong>Markdown</strong>: <i>Italic</"
     "i> and <code>code</code></p>\n",
     true}};

int main() {
  printf("--- OctoMark C Correctness Tests ---\n");
  TestSummary summary =
      run_octomark_tests(tests, sizeof(tests) / sizeof(tests[0]));
  printf("\nTest Summary: %d Passed, %d Failed.\n", summary.passed,
         summary.total - summary.passed);
  return (summary.passed == summary.total) ? 0 : 1;
}
