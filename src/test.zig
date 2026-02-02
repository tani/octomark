const std = @import("std");
const octomark = @import("octomark");

const TestCase = struct {
    name: []const u8,
    input: []const u8,
    expected: []const u8,
    enable_html: bool,
};

fn tc(name: []const u8, input: []const u8, expected: []const u8, enable_html: bool) TestCase {
    return .{ .name = name, .input = input, .expected = expected, .enable_html = enable_html };
}

fn render(allocator: std.mem.Allocator, input: []const u8, enable_html: bool) ![]u8 {
    var parser: octomark.OctomarkParser = undefined;
    try parser.init(allocator);
    defer parser.deinit(allocator);
    parser.setOptions(.{ .enable_html = enable_html });

    var fbs = std.io.fixedBufferStream(input);
    const reader = fbs.reader();

    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();
    const writer = list.writer();

    try parser.parse(reader, writer, allocator);

    return list.toOwnedSlice();
}

test "octomark cases" {
    const cases = [_]TestCase{
        tc("Simple Paragraph", "Hello, OctoMark!", "<p>Hello, OctoMark!</p>\n", false),
        tc("Heading1", "# Welcome", "<h1>Welcome</h1>\n", false),
        tc("Heading2", "## Subtitle", "<h2>Subtitle</h2>\n", false),
        tc("Horizontal Rule", "---", "<hr>\n", false),
        tc("Strong Style", "**Bold**", "<p><strong>Bold</strong></p>\n", false),
        tc("Emphasis Style", "_Italic_", "<p><em>Italic</em></p>\n", false),
        tc("Inline Code", "`code`", "<p><code>code</code></p>\n", false),
        tc("Fenced Code Block", "```js\nconst x = 1;\n```", "<pre><code class=\"language-js\">const x = 1;\n</code></pre>\n", false),
        tc("Nested Blockquotes", "> > Double quote", "<blockquote><blockquote><p>Double quote</p>\n</blockquote>\n</blockquote>\n", false),
        tc("Link with Title", "[Google](https://google.com)", "<p><a href=\"https://google.com\">Google</a></p>\n", false),
        tc("Hard Line Break", "Line 1  \nLine 2", "<p>Line 1<br>\nLine 2</p>\n", false),
        tc("Table Support", "| Header | Value |\n|--|--:|\n| Data | 100 |", "<table><thead><tr><th>Header</th><th style=\"text-align:right\">Value</th></tr></thead><tbody>\n<tr><td>Data</td><td style=\"text-align:right\">100</td></tr>\n</tbody></table>\n", false),
        tc("Complex Definition List", "Term\n: Def 1\n: Def 2", "<dl>\n<dt>Term</dt>\n<dd>Def 1</dd>\n<dd>Def 2</dd>\n</dl>\n", false),
        tc("Math Support", "$$E=mc^2$$", "<div class=\"math\">\nE=mc^2\n</div>\n", false),
        tc("Inline Styles", "**Bold** and _Italic_ and `Code`", "<p><strong>Bold</strong> and <em>Italic</em> and <code>Code</code></p>\n", false),
        tc("Links", "[Google](https://google.com)", "<p><a href=\"https://google.com\">Google</a></p>\n", false),
        tc("Escaping", "\\*Not Bold\\*", "<p>*Not Bold*</p>\n", false),
        tc("Unordered List", "- Item 1\n- Item 2", "<ul>\n<li>Item 1</li>\n<li>Item 2</li>\n</ul>\n", false),
        tc("Task List", "- [ ] Todo\n- [x] Done", "<ul>\n<li><input type=\"checkbox\"  disabled> Todo</li>\n<li><input type=\"checkbox\" checked disabled> Done</li>\n</ul>\n", false),
        tc("Nested List (2 spaces)", "- Level 1\n  - Level 2\n- Back to 1", "<ul>\n<li>Level 1<ul>\n<li>Level 2</li>\n</ul>\n</li>\n<li>Back to 1</li>\n</ul>\n", false),
        tc("Nested Inline Styles", "**Bold _Italic_**", "<p><strong>Bold <em>Italic</em></strong></p>\n", false),
        tc("Definition List", "Term\n: # Def Heading\n: - Item 1\n: - Item 2", "<dl>\n<dt>Term</dt>\n<dd><h1>Def Heading</h1>\n</dd>\n<dd><ul>\n<li>Item 1</li>\n</ul>\n</dd>\n<dd><ul>\n<li>Item 2</li>\n</ul>\n</dd>\n</dl>\n", false),
        tc("Mixed List Types", "- Regular\n- [ ] Task", "<ul>\n<li>Regular</li>\n<li><input type=\"checkbox\"  disabled> Task</li>\n</ul>\n", false),
        tc("Ordered List", "1. Item 1\n2. Item 2", "<ol>\n<li>Item 1</li>\n<li>Item 2</li>\n</ol>\n", false),
        tc("Image", "![Octo](https://octo.com/logo.png)", "<p><img src=\"https://octo.com/logo.png\" alt=\"Octo\"></p>\n", false),
        tc("Strikethrough", "~~Deleted text~~", "<p><del>Deleted text</del></p>\n", false),
        tc("Autolink", "Search on https://google.com now", "<p>Search on <a href=\"https://google.com\">https://google.com</a> now</p>\n", false),
        tc("Mixed List Transformation", "- Bullet\n1. Numbered", "<ul>\n<li>Bullet</li>\n</ul>\n<ol>\n<li>Numbered</li>\n</ol>\n", false),
        tc("Inline Math", "The formula is $E=mc^2$ is famous.", "<p>The formula is <span class=\"math\">E=mc^2</span> is famous.</p>\n", false),
        tc("Linear Paragraphs", "Line 1\nLine 2", "<p>Line 1\nLine 2</p>\n", false),
        tc("Lazy Blockquote", "> Line 1\nLine 2", "<blockquote><p>Line 1\nLine 2</p>\n</blockquote>\n", false),
        tc("Lazy Blockquote Break", "> Line 1\n## Header", "<blockquote><p>Line 1</p>\n</blockquote>\n<h2>Header</h2>\n", false),
        tc("Lazy List Continuation", "- Item 1\nContinued", "<ul>\n<li>Item 1\nContinued</li>\n</ul>\n", false),
        tc("Indented List Continuation", "- Item 1\n  Continued", "<ul>\n<li>Item 1\nContinued</li>\n</ul>\n", false),
        tc("Definition List Continuation", "Term\n: Def 1\n  Continued", "<dl>\n<dt>Term</dt>\n<dd>Def 1\nContinued</dd>\n</dl>\n", false),
        tc("Space Hard Break", "Line 1  \nLine 2", "<p>Line 1<br>\nLine 2</p>\n", false),
        tc("Backslash Hard Break", "Line 1\\\nLine 2", "<p>Line 1<br>\nLine 2</p>\n", false),
        tc("HTML Support", "<b>Bold</b> <DIV>Mixed</DIV> <sPaN class=\"foo\">Span</sPaN> <br/> <!-- Comment --> <invalid\nMixed with **Markdown**: <i>Italic</i> and `code`", "<p><b>Bold</b> <DIV>Mixed</DIV> <sPaN class=\"foo\">Span</sPaN> <br/> <!-- Comment --> &lt;invalid\nMixed with <strong>Markdown</strong>: <i>Italic</i> and <code>code</code></p>\n", true),
        tc("Strong Fallback", "**No Closing", "<p>**No Closing</p>\n", false),
        tc("Emphasis Fallback", "_No Closing", "<p>_No Closing</p>\n", false),
        tc("Single backtick", "`code`", "<p><code>code</code></p>\n", false),
        tc("Backtick with content", "`code ` text`", "<p><code>code </code> text`</p>\n", false),
    };

    const allocator = std.testing.allocator;
    for (cases) |case| {
        const output = try render(allocator, case.input, case.enable_html);
        defer allocator.free(output);
        try std.testing.expectEqualStrings(case.expected, output);
    }
}

test "NestingTooDeep" {
    const allocator = std.testing.allocator;
    var parser: octomark.OctomarkParser = undefined;
    try parser.init(allocator);
    defer parser.deinit(allocator);

    var input = std.ArrayListUnmanaged(u8){};
    defer input.deinit(allocator);
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        try input.appendSlice(allocator, "> ");
    }
    try input.appendSlice(allocator, "Deep");

    var fbs = std.io.fixedBufferStream(input.items);
    const reader = fbs.reader();

    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();
    const writer = list.writer();

    const result = parser.parse(reader, writer, allocator);
    try std.testing.expectError(error.NestingTooDeep, result);
}

// Table Column Limit test removed - table auto-detection no longer supported (simplification #1)

test "mandatory fixes" {
    const cases = [_]TestCase{
        tc("2.1 ATX No Space", "#Header", "<h1>Header</h1>\n", false),
        tc("2.1 ATX Empty", "#", "<h1></h1>\n", false),
        tc("2.2 List Star", "* A", "<ul>\n<li>A</li>\n</ul>\n", false),
        tc("2.2 List Plus", "+ A", "<ul>\n<li>A</li>\n</ul>\n", false),
        tc("2.3 Tilde Fence", "~~~\nA\n~~~", "<pre><code>A\n</code></pre>\n", false),
        tc("2.4 Inline Code Empty", " `` ", "<p>`` </p>\n", false), // Input " `` " has space at end. Output should preserve it if not code.
        // Wait, " `` " is 4 chars: space, backtick, backtick, space.
        // If the instruction implies ` `` ` as input, it means empty code span?
        // Standard CommonMark: `` ` `` -> <code> </code>? No.
        // If input is " `` ", it's just text.
        // The prompt says: "以下を **コードスパンとして解釈してはならない**。 `` ".
        // And "opening delimiter と closing delimiter が成立しない場合... 通常テキスト".
        // My interpretation: The input ` `` ` (two backticks) should NOT be parsed as empty inline code.
        // So output should be <p>``</p>.
        tc("2.4 Inline Code Unmatched", "``", "<p>``</p>\n", false),
        tc("2.5 Angle Autolink", "<http://a.b>", "<p><a href=\"http://a.b\">http://a.b</a></p>\n", false), // Should not escape <
        // Note: The prompt says output `<a href="...">...</a>`. My parser wraps in <p> for inline content.
        // I will assume the paragraph wrapper is correct for inline content unless strictly forbidden.
        // 1.6 says "HTML block ... <p>の子要素にしてはならない". Autolink is inline.

        tc("2.6 HTML Block Div", "<div>A</div>", "<div>A</div>\n", true),
        tc("2.6 HTML Block Content", "<div>**A**</div>", "<div>**A**</div>\n", true),

        tc("2.7 Empty Quote", ">", "", false),
        tc("2.7 Empty List", "- ", "", false),
    };

    const allocator = std.testing.allocator;
    for (cases) |case| {
        const output = try render(allocator, case.input, case.enable_html);
        defer allocator.free(output);
        try std.testing.expectEqualStrings(case.expected, output);
    }
}

test "comprehensive cases" {
    const cases = [_]TestCase{
        tc("Header 1", "# H1", "<h1>H1</h1>\n", false),
        tc("Header 2", "## H2", "<h2>H2</h2>\n", false),
        tc("Header 3", "### H3", "<h3>H3</h3>\n", false),
        tc("Header 4", "#### H4", "<h4>H4</h4>\n", false),
        tc("Header 5", "##### H5", "<h5>H5</h5>\n", false),
        tc("Header 6", "###### H6", "<h6>H6</h6>\n", false),
        tc("Invalid Header 7", "####### H7", "<p>####### H7</p>\n", false),
        tc("Invalid Header No Space", "#Header", "<h1>Header</h1>\n", false),
        tc("Header with Bold", "# **Bold**", "<h1><strong>Bold</strong></h1>\n", false),
        tc("Header with Code", "## `Code`", "<h2><code>Code</code></h2>\n", false),
        tc("Header with Link", "### [Link](url)", "<h3><a href=\"url\">Link</a></h3>\n", false),
        tc("List Ordered Start 1", "1. Item", "<ol>\n<li>Item</li>\n</ol>\n", false),
        tc("List Ordered Start 0", "0. Item", "<ol>\n<li>Item</li>\n</ol>\n", false),
        tc("List Unordered Star", "* Item", "<ul>\n<li>Item</li>\n</ul>\n", false),
        tc("List Unordered Dash", "- Item", "<ul>\n<li>Item</li>\n</ul>\n", false),
        tc("List Unordered Plus", "+ Item", "<ul>\n<li>Item</li>\n</ul>\n", false),
        tc("List Nested 3 Levels", "- 1\n  - 2\n    - 3", "<ul>\n<li>1<ul>\n<li>2<ul>\n<li>3</li>\n</ul>\n</li>\n</ul>\n</li>\n</ul>\n", false),
        tc("List Mixed Nesting", "- 1\n  1. 2", "<ul>\n<li>1<ol>\n<li>2</li>\n</ol>\n</li>\n</ul>\n", false),
        tc("Task List Checked", "- [x] Done", "<ul>\n<li><input type=\"checkbox\" checked disabled> Done</li>\n</ul>\n", false),
        tc("Task List Unchecked", "- [ ] Todo", "<ul>\n<li><input type=\"checkbox\"  disabled> Todo</li>\n</ul>\n", false),
        tc("Task List Invalid", "- [o] Invalid", "<ul>\n<li>[o] Invalid</li>\n</ul>\n", false),
        tc("Code Block Fenced Backtick", "```\ncode\n```", "<pre><code>code\n</code></pre>\n", false),
        tc("Code Block Fenced Tilde", "~~~\ncode\n~~~", "<pre><code>code\n</code></pre>\n", false),
        tc("Code Block With Info", "```rust\nfn main() {}\n```", "<pre><code class=\"language-rust\">fn main() {}\n</code></pre>\n", false),
        tc("Blockquote Simple", "> Quote", "<blockquote><p>Quote</p>\n</blockquote>\n", false),
        tc("Blockquote Nested", "> > Quote", "<blockquote><blockquote><p>Quote</p>\n</blockquote>\n</blockquote>\n", false),
        tc("Blockquote with Header", "> # Header", "<blockquote><h1>Header</h1>\n</blockquote>\n", false),
        tc("Blockquote with List", "> - Item", "<blockquote><ul>\n<li>Item</li>\n</ul>\n</blockquote>\n", false),
        tc("Bold Nested in Italic", "_**Bold**_", "<p><em><strong>Bold</strong></em></p>\n", false),
        tc("Italic Nested in Bold", "**_Italic_**", "<p><strong><em>Italic</em></strong></p>\n", false),
        tc("Bold Mismatch", "**Bold*", "<p>**Bold*</p>\n", false),
        tc("Link Empty URL", "[Link]()", "<p><a href=\"\">Link</a></p>\n", false),
        tc("Link Empty Text", "[](url)", "<p><a href=\"url\"></a></p>\n", false),
        tc("Image Empty URL", "![Alt]()", "<p><img src=\"\" alt=\"Alt\"></p>\n", false),
        tc("Image Empty Alt", "![](url)", "<p><img src=\"url\" alt=\"\"></p>\n", false),
        tc("Auto Link HTTP", "http://example.com", "<p><a href=\"http://example.com\">http://example.com</a></p>\n", false),
        tc("Auto Link HTTPS", "https://example.com", "<p><a href=\"https://example.com\">https://example.com</a></p>\n", false),
        tc("Math Inline", "$E=mc^2$", "<p><span class=\"math\">E=mc^2</span></p>\n", false),
        tc("Math Block", "$$\nE=mc^2\n$$", "<div class=\"math\">\nE=mc^2\n</div>\n", false),
        tc("Table One Column", "| H |\n|---|\n| V |", "<table><thead><tr><th>H</th></tr></thead><tbody>\n<tr><td>V</td></tr>\n</tbody></table>\n", false),
        tc("Table Alignment Left", "| H |\n|:--|\n| V |", "<table><thead><tr><th style=\"text-align:left\">H</th></tr></thead><tbody>\n<tr><td style=\"text-align:left\">V</td></tr>\n</tbody></table>\n", false),
        tc("Table Alignment Center", "| H |\n|:-:|\n| V |", "<table><thead><tr><th style=\"text-align:center\">H</th></tr></thead><tbody>\n<tr><td style=\"text-align:center\">V</td></tr>\n</tbody></table>\n", false),
        tc("Table Alignment Right", "| H |\n|--:|\n| V |", "<table><thead><tr><th style=\"text-align:right\">H</th></tr></thead><tbody>\n<tr><td style=\"text-align:right\">V</td></tr>\n</tbody></table>\n", false),
        tc("Table Missing Cells", "| H1 | H2 |\n|----|----|\n| V1 |", "<table><thead><tr><th>H1</th><th>H2</th></tr></thead><tbody>\n<tr><td>V1</td></tr>\n</tbody></table>\n", false),
        tc("Table Extra Cells", "| H1 |\n|----|\n| V1 | V2 |", "<table><thead><tr><th>H1</th></tr></thead><tbody>\n<tr><td>V1</td><td>V2</td></tr>\n</tbody></table>\n", false),
        tc("HR Dash", "---", "<hr>\n", false),
        tc("HR Star", "***", "<hr>\n", false),
        tc("HR Underscore", "___", "<hr>\n", false),
        tc("Escaped Asterisk", "\\*", "<p>*</p>\n", false),
        tc("HTML Pass", "<div>Content</div>", "<div>Content</div>\n", true),
        tc("Empty Input", "", "", false),
        tc("Whitespace Input", "   ", "", false),
        // Additional Nesting Cases
        tc("List Nested 4 Levels", "- 1\n  - 2\n    - 3\n      - 4", "<ul>\n<li>1<ul>\n<li>2<ul>\n<li>3<ul>\n<li>4</li>\n</ul>\n</li>\n</ul>\n</li>\n</ul>\n</li>\n</ul>\n", false),
        tc("List Nested 5 Levels", "- 1\n  - 2\n    - 3\n      - 4\n        - 5", "<ul>\n<li>1<ul>\n<li>2<ul>\n<li>3<ul>\n<li>4<ul>\n<li>5</li>\n</ul>\n</li>\n</ul>\n</li>\n</ul>\n</li>\n</ul>\n</li>\n</ul>\n", false),
        tc("Quote Inside List", "- Item\n  > Quote", "<ul>\n<li>Item<blockquote><p>Quote</p>\n</blockquote>\n</li>\n</ul>\n", false),
        tc("Header Inside List", "- Item\n  # Header", "<ul>\n<li>Item<h1>Header</h1>\n</li>\n</ul>\n", false),
        tc("Code Inside List", "- Item\n  ```\n  code\n  ```", "<ul>\n<li>Item<pre><code>code\n</code></pre>\n</li>\n</ul>\n", false),
        tc("List Inside Quote", "> - Item 1\n> - Item 2", "<blockquote><ul>\n<li>Item 1</li>\n<li>Item 2</li>\n</ul>\n</blockquote>\n", false),
        tc("Header Inside Quote", "> # H1", "<blockquote><h1>H1</h1>\n</blockquote>\n", false),
        tc("Code Inside Quote", "> ```\n> code\n> ```", "<blockquote><pre><code>code\n</code></pre>\n</blockquote>\n", false),
        tc("Bold Italic Mix 1", "**Bold _Italic_**", "<p><strong>Bold <em>Italic</em></strong></p>\n", false),
        tc("Bold Italic Mix 2", "_Italic **Bold**_", "<p><em>Italic <strong>Bold</strong></em></p>\n", false),
        tc("Bold Italic Mix 3", "**_Bold Italic_**", "<p><strong><em>Bold Italic</em></strong></p>\n", false),
        tc("Link Inside Bold", "**[Link](url)**", "<p><strong><a href=\"url\">Link</a></strong></p>\n", false),
        tc("Bold Inside Link", "[**Bold**](url)", "<p><a href=\"url\"><strong>Bold</strong></a></p>\n", false),
        tc("Code Inside Bold", "**`Code`**", "<p><strong><code>Code</code></strong></p>\n", false),
        tc("Code Inside Link", "[`Code`](url)", "<p><a href=\"url\"><code>Code</code></a></p>\n", false),
        tc("Image Inside Link", "[![Alt](img)](url)", "<p><a href=\"url\"><img src=\"img\" alt=\"Alt\"></a></p>\n", false),
        tc("Math Inside Bold", "**$E=mc^2$**", "<p><strong><span class=\"math\">E=mc^2</span></strong></p>\n", false),
        tc("Math Inside Link", "[$E$](url)", "<p><a href=\"url\"><span class=\"math\">E</span></a></p>\n", false),
        tc("Strike Inside Bold", "**~~Strike~~**", "<p><strong><del>Strike</del></strong></p>\n", false),
        tc("Strike Inside Italic", "_~~Strike~~_", "<p><em><del>Strike</del></em></p>\n", false),
        tc("Table With Bold", "| **H** |\n|---|\n| **V** |", "<table><thead><tr><th><strong>H</strong></th></tr></thead><tbody>\n<tr><td><strong>V</strong></td></tr>\n</tbody></table>\n", false),
        tc("Table With Italic", "| _H_ |\n|---|\n| _V_ |", "<table><thead><tr><th><em>H</em></th></tr></thead><tbody>\n<tr><td><em>V</em></td></tr>\n</tbody></table>\n", false),
        tc("Table With Code", "| `C` |\n|---|\n| `V` |", "<table><thead><tr><th><code>C</code></th></tr></thead><tbody>\n<tr><td><code>V</code></td></tr>\n</tbody></table>\n", false),
        tc("Table With Link", "| [L](u) |\n|---|\n| [V](u) |", "<table><thead><tr><th><a href=\"u\">L</a></th></tr></thead><tbody>\n<tr><td><a href=\"u\">V</a></td></tr>\n</tbody></table>\n", false),
        tc("Table With Math", "| $M$ |\n|---|\n| $V$ |", "<table><thead><tr><th><span class=\"math\">M</span></th></tr></thead><tbody>\n<tr><td><span class=\"math\">V</span></td></tr>\n</tbody></table>\n", false),
        tc("Table With Image", "| ![I](u) |\n|---|\n| ![V](u) |", "<table><thead><tr><th><img src=\"u\" alt=\"I\"></th></tr></thead><tbody>\n<tr><td><img src=\"u\" alt=\"V\"></td></tr>\n</tbody></table>\n", false),
        tc("Nested Blockquote 3", "> > > Quote", "<blockquote><blockquote><blockquote><p>Quote</p>\n</blockquote>\n</blockquote>\n</blockquote>\n", false),
        tc("Nested Blockquote 4", "> > > > Quote", "<blockquote><blockquote><blockquote><blockquote><p>Quote</p>\n</blockquote>\n</blockquote>\n</blockquote>\n</blockquote>\n", false),
        tc("List in Quote in List", "- 1\n  > - 2", "<ul>\n<li>1<blockquote><ul>\n<li>2</li>\n</ul>\n</blockquote>\n</li>\n</ul>\n", false),
        tc("Quote in List in Quote", "> - 1\n>   > 2", "<blockquote><ul>\n<li>1<blockquote><p>2</p>\n</blockquote>\n</li>\n</ul>\n</blockquote>\n", false),
        tc("Ordered in Unordered", "- 1\n  1. 2", "<ul>\n<li>1<ol>\n<li>2</li>\n</ol>\n</li>\n</ul>\n", false),
        tc("Unordered in Ordered", "1. 1\n   - 2", "<ol>\n<li>1<ul>\n<li>2</li>\n</ul>\n</li>\n</ol>\n", false),
        tc("Task in Ordered", "1. [x] Done", "<ol>\n<li><input type=\"checkbox\" checked disabled> Done</li>\n</ol>\n", false),
        tc("Task in Nested", "- 1\n  - [ ] Todo", "<ul>\n<li>1<ul>\n<li><input type=\"checkbox\"  disabled> Todo</li>\n</ul>\n</li>\n</ul>\n", false),
        tc("Lazy Quote Multi", "> 1\n2", "<blockquote><p>1\n2</p>\n</blockquote>\n", false),
        tc("Lazy Quote List", "> - 1\n2", "<blockquote><ul>\n<li>1\n2</li>\n</ul>\n</blockquote>\n", false),
        tc("Lazy List Multi", "- 1\n2", "<ul>\n<li>1\n2</li>\n</ul>\n", false),
        tc("Lazy List Quote", "- > 1\n2", "<ul>\n<li><blockquote><p>1\n2</p>\n</blockquote>\n</li>\n</ul>\n", false),
        tc("Header with Escapes", "# \\# H", "<h1># H</h1>\n", false),
        tc("Link with Escapes", "[\\[](url)", "<p><a href=\"url\">[</a></p>\n", false),
        tc("Image with Escapes", "![\\!](url)", "<p><img src=\"url\" alt=\"!\"></p>\n", false),
        tc("Code with Escapes", "`\\`code`", "<p><code>\\</code>code`</p>\n", false),
        tc("Math with Escapes", "$\\$E$", "<p><span class=\"math\">\\$E</span></p>\n", false),
        tc("Table with Pipe Escape", "| \\| |\n|---|\n| V |", "<table><thead><tr><th>|</th></tr></thead><tbody>\n<tr><td>V</td></tr>\n</tbody></table>\n", false),
        tc("HTML in List", "- <div>H</div>", "<ul>\n<li></li>\n</ul>\n<div>H</div>\n", true), // HTML Block breaks out of list
        tc("HTML in Quote", "> <span>S</span>", "<blockquote><p><span>S</span></p>\n</blockquote>\n", true),
        tc("HTML in Header", "# <i>I</i>", "<h1><i>I</i></h1>\n", true),
        tc("Complex 1", "> - **B**", "<blockquote><ul>\n<li><strong>B</strong></li>\n</ul>\n</blockquote>\n", false),
        tc("Complex 2", "- > _I_", "<ul>\n<li><blockquote><p><em>I</em></p>\n</blockquote>\n</li>\n</ul>\n", false),
        tc("Complex 3", "1. `C`", "<ol>\n<li><code>C</code></li>\n</ol>\n", false),
        tc("Complex 4", "> 1. [L](u)", "<blockquote><ol>\n<li><a href=\"u\">L</a></li>\n</ol>\n</blockquote>\n", false),
        tc("Complex 5", "- [x] **B**", "<ul>\n<li><input type=\"checkbox\" checked disabled> <strong>B</strong></li>\n</ul>\n", false),
        tc("Complex 6", "### _I_ `C`", "<h3><em>I</em> <code>C</code></h3>\n", false),
        tc("Complex 7", "| **B** | _I_ |\n|---|---|\n| `C` | [L](u) |", "<table><thead><tr><th><strong>B</strong></th><th><em>I</em></th></tr></thead><tbody>\n<tr><td><code>C</code></td><td><a href=\"u\">L</a></td></tr>\n</tbody></table>\n", false),
        tc("Complex 8", "$$ **B** $$", "<div class=\"math\">\n**B**\n</div>\n", false), // Math block content is raw
        tc("Complex 9", "`**B**`", "<p><code>**B**</code></p>\n", false), // Code content is raw
        tc("Combinations 1", "_**B**_ `C`", "<p><em><strong>B</strong></em> <code>C</code></p>\n", false),
        tc("Combinations 2", "**_I_** [L](u)", "<p><strong><em>I</em></strong> <a href=\"u\">L</a></p>\n", false),
        tc("Combinations 3", "[**B**](u) _I_", "<p><a href=\"u\"><strong>B</strong></a> <em>I</em></p>\n", false),
        tc("Combinations 4", "![**B**](u)", "<p><img src=\"u\" alt=\"**B**\"></p>\n", false), // Alt text does not render markdown
        tc("Combinations 5", "`_I_`", "<p><code>_I_</code></p>\n", false),
        tc("Combinations 6", "$**B**$", "<p><span class=\"math\">**B**</span></p>\n", false),
        tc("Combinations 7", "**$E$**", "<p><strong><span class=\"math\">E</span></strong></p>\n", false),
        tc("Combinations 8", "_`C`_", "<p><em><code>C</code></em></p>\n", false),
        tc("Combinations 9", "`[L](u)`", "<p><code>[L](u)</code></p>\n", false),
        tc("Combinations 10", "[`C`](u)", "<p><a href=\"u\"><code>C</code></a></p>\n", false),
        tc("Link in Table 1", "| [A](b) |\n|---|\n| C |", "<table><thead><tr><th><a href=\"b\">A</a></th></tr></thead><tbody>\n<tr><td>C</td></tr>\n</tbody></table>\n", false),
        tc("Image in Table 1", "| ![A](b) |\n|---|\n| C |", "<table><thead><tr><th><img src=\"b\" alt=\"A\"></th></tr></thead><tbody>\n<tr><td>C</td></tr>\n</tbody></table>\n", false),
        tc("Bold in Table 1", "| **A** |\n|---|\n| C |", "<table><thead><tr><th><strong>A</strong></th></tr></thead><tbody>\n<tr><td>C</td></tr>\n</tbody></table>\n", false),
        tc("Italic in Table 1", "| _A_ |\n|---|\n| C |", "<table><thead><tr><th><em>A</em></th></tr></thead><tbody>\n<tr><td>C</td></tr>\n</tbody></table>\n", false),
        tc("Code in Table 1", "| `A` |\n|---|\n| C |", "<table><thead><tr><th><code>A</code></th></tr></thead><tbody>\n<tr><td>C</td></tr>\n</tbody></table>\n", false),
        tc("Math in Table 1", "| $A$ |\n|---|\n| C |", "<table><thead><tr><th><span class=\"math\">A</span></th></tr></thead><tbody>\n<tr><td>C</td></tr>\n</tbody></table>\n", false),
        tc("Mixed Nesting 1", "- 1\n  - 2\n    - 3\n      1. 4", "<ul>\n<li>1<ul>\n<li>2<ul>\n<li>3<ol>\n<li>4</li>\n</ol>\n</li>\n</ul>\n</li>\n</ul>\n</li>\n</ul>\n", false),
        tc("Mixed Nesting 2", "1. 1\n   1. 2\n      - 3", "<ol>\n<li>1<ol>\n<li>2<ul>\n<li>3</li>\n</ul>\n</li>\n</ol>\n</li>\n</ol>\n", false),
        tc("Mixed Nesting 3", "> - 1\n>   - 2", "<blockquote><ul>\n<li>1<ul>\n<li>2</li>\n</ul>\n</li>\n</ul>\n</blockquote>\n", false),
        tc("Mixed Nesting 4", "- > 1\n  > 2", "<ul>\n<li><blockquote><p>1\n2</p>\n</blockquote>\n</li>\n</ul>\n", false),
        tc("Deep Quote 1", "> > > > > 5", "<blockquote><blockquote><blockquote><blockquote><blockquote><p>5</p>\n</blockquote>\n</blockquote>\n</blockquote>\n</blockquote>\n</blockquote>\n", false),
        tc("Deep List 1", "- 1\n  - 2\n    - 3\n      - 4\n        - 5\n          - 6", "<ul>\n<li>1<ul>\n<li>2<ul>\n<li>3<ul>\n<li>4<ul>\n<li>5<ul>\n<li>6</li>\n</ul>\n</li>\n</ul>\n</li>\n</ul>\n</li>\n</ul>\n</li>\n</ul>\n</li>\n</ul>\n", false),
        tc("Deep Ordered 1", "1. 1\n   1. 2\n      1. 3\n         1. 4", "<ol>\n<li>1<ol>\n<li>2<ol>\n<li>3<ol>\n<li>4</li>\n</ol>\n</li>\n</ol>\n</li>\n</ol>\n</li>\n</ol>\n", false),
        tc("Edge Empty Header", "#", "<h1></h1>\n", false),
        tc("Edge Header Space", "# ", "<h1></h1>\n", false),
        tc("Edge Empty List", "-", "<p>-</p>\n", false), // Needs space
        tc("Edge List Space", "- ", "", false),
        tc("Edge Empty Quote", ">", "", false),
        tc("Edge Quote Space", "> ", "", false),
        tc("Edge Empty Link", "[]()", "<p><a href=\"\"></a></p>\n", false),
        tc("Edge Empty Image", "![]()", "<p><img src=\"\" alt=\"\"></p>\n", false),
        tc("Edge Empty Code", "``", "<p>``</p>\n", false),
        tc("Edge Empty Math", "$$", "<div class=\"math\">\n</div>\n", false),
        tc("Edge Empty Block Math", "$$\n$$", "<div class=\"math\">\n</div>\n", false),
        tc("Edge Empty Fenced", "```\n```", "<pre><code></code></pre>\n", false),
        tc("Edge Empty Table", "||\n|--|", "<table><thead><tr><th></th></tr></thead><tbody>\n</tbody></table>\n", false), // Minimal table
        tc("Edge Table No Body", "|H|\n|--|", "<table><thead><tr><th>H</th></tr></thead><tbody>\n</tbody></table>\n", false),
        tc("Misc 1", "**B**_I_", "<p><strong>B</strong><em>I</em></p>\n", false),
        tc("Misc 2", "_I_**B**", "<p><em>I</em><strong>B</strong></p>\n", false),
        tc("Misc 3", "`C`**B**", "<p><code>C</code><strong>B</strong></p>\n", false),
        tc("Misc 4", "**B**`C`", "<p><strong>B</strong><code>C</code></p>\n", false),
        tc("Misc 5", "[L](u)**B**", "<p><a href=\"u\">L</a><strong>B</strong></p>\n", false),
        tc("Misc 6", "**B**[L](u)", "<p><strong>B</strong><a href=\"u\">L</a></p>\n", false),
        tc("Misc 7", "![A](u)**B**", "<p><img src=\"u\" alt=\"A\"><strong>B</strong></p>\n", false),
        tc("Misc 8", "**B**![A](u)", "<p><strong>B</strong><img src=\"u\" alt=\"A\"></p>\n", false),
        tc("Misc 9", "$M$**B**", "<p><span class=\"math\">M</span><strong>B</strong></p>\n", false),
        tc("Misc 10", "**B**$M$", "<p><strong>B</strong><span class=\"math\">M</span></p>\n", false),
        tc("Misc 11", "**B**_I_`C`", "<p><strong>B</strong><em>I</em><code>C</code></p>\n", false),
        tc("Misc 12", "`C`_I_**B**", "<p><code>C</code><em>I</em><strong>B</strong></p>\n", false),
        tc("Misc 13", "1. **B**", "<ol>\n<li><strong>B</strong></li>\n</ol>\n", false),
        tc("Misc 14", "- _I_", "<ul>\n<li><em>I</em></li>\n</ul>\n", false),
        tc("Misc 15", "> `C`", "<blockquote><p><code>C</code></p>\n</blockquote>\n", false),
        tc("Misc 16", "# $M$", "<h1><span class=\"math\">M</span></h1>\n", false),
        tc("Misc 17", "| **B** |\n|---|\n| V |", "<table><thead><tr><th><strong>B</strong></th></tr></thead><tbody>\n<tr><td>V</td></tr>\n</tbody></table>\n", false),
        tc("Misc 18", "| _I_ |\n|---|\n| V |", "<table><thead><tr><th><em>I</em></th></tr></thead><tbody>\n<tr><td>V</td></tr>\n</tbody></table>\n", false),
        tc("Misc 19", "| `C` |\n|---|\n| V |", "<table><thead><tr><th><code>C</code></th></tr></thead><tbody>\n<tr><td>V</td></tr>\n</tbody></table>\n", false),
        tc("Misc 20", "| [L](u) |\n|---|\n| V |", "<table><thead><tr><th><a href=\"u\">L</a></th></tr></thead><tbody>\n<tr><td>V</td></tr>\n</tbody></table>\n", false),
        tc("Auto 1", "http://a.b", "<p><a href=\"http://a.b\">http://a.b</a></p>\n", false),
        tc("Auto 2", "https://a.b", "<p><a href=\"https://a.b\">https://a.b</a></p>\n", false),
        tc("Auto 3", "http://a.b/c", "<p><a href=\"http://a.b/c\">http://a.b/c</a></p>\n", false),
        tc("Auto 4", "https://a.b/c?d=e", "<p><a href=\"https://a.b/c?d=e\">https://a.b/c?d=e</a></p>\n", false),
        tc("Auto 5", "(http://a.b)", "<p>(<a href=\"http://a.b\">http://a.b</a>)</p>\n", false),
        tc("Auto 6", "<http://a.b>", "<p><a href=\"http://a.b\">http://a.b</a></p>\n", false),
        tc("Escape 1", "\\\\", "<p>\\</p>\n", false),
        tc("Escape 2", "\\`", "<p>`</p>\n", false),
        tc("Escape 3", "\\*", "<p>*</p>\n", false),
        tc("Escape 4", "\\_", "<p>_</p>\n", false),
        tc("Escape 5", "\\{", "<p>{</p>\n", false),
        tc("Escape 6", "\\}", "<p>}</p>\n", false),
        tc("Escape 7", "\\[", "<p>[</p>\n", false),
        tc("Escape 8", "\\]", "<p>]</p>\n", false),
        tc("Escape 9", "\\(", "<p>(</p>\n", false),
        tc("Escape 10", "\\)", "<p>)</p>\n", false),
        tc("Escape 11", "\\#", "<p>#</p>\n", false),
        tc("Escape 12", "\\+", "<p>+</p>\n", false),
        tc("Escape 13", "\\-", "<p>-</p>\n", false),
        tc("Escape 14", "\\.", "<p>.</p>\n", false),
        tc("Escape 15", "\\!", "<p>!</p>\n", false),
        tc("No Escape 1", "\\a", "<p>\\a</p>\n", false),
        tc("No Escape 2", "\\0", "<p>\\0</p>\n", false),
        tc("Quote Gap", "> 1\n\n> 2", "<blockquote><p>1</p>\n</blockquote>\n<blockquote><p>2</p>\n</blockquote>\n", false),
        tc("List Gap", "- 1\n\n- 2", "<ul>\n<li>1</li>\n<li>2</li>\n</ul>\n", false),
        tc("Header Gap", "# 1\n\n# 2", "<h1>1</h1>\n<h1>2</h1>\n", false),
        tc("Code Gap", "```\n1\n```\n\n```\n2\n```", "<pre><code>1\n</code></pre>\n<pre><code>2\n</code></pre>\n", false),
        tc("Math Gap", "$$\n1\n$$\n\n$$\n2\n$$", "<div class=\"math\">\n1\n</div>\n<div class=\"math\">\n2\n</div>\n", false),
        tc("Table Gap", "| 1 |\n|---|\n\n| 2 |\n|---|", "<table><thead><tr><th>1</th></tr></thead><tbody>\n</tbody></table>\n<table><thead><tr><th>2</th></tr></thead><tbody>\n</tbody></table>\n", false),
        tc("Nested 100", "- 1\n  - 2", "<ul>\n<li>1<ul>\n<li>2</li>\n</ul>\n</li>\n</ul>\n", false),
        tc("Nested 101", "1. 1\n   1. 2", "<ol>\n<li>1<ol>\n<li>2</li>\n</ol>\n</li>\n</ol>\n", false),
        tc("Nested 102", "> 1\n> > 2", "<blockquote><p>1</p>\n<blockquote><p>2</p>\n</blockquote>\n</blockquote>\n", false),
        tc("Nested 103", "- > 1", "<ul>\n<li><blockquote><p>1</p>\n</blockquote>\n</li>\n</ul>\n", false),
        tc("Nested 104", "> - 1", "<blockquote><ul>\n<li>1</li>\n</ul>\n</blockquote>\n", false),
        tc("Nested 105", "- 1\n  1. 2", "<ul>\n<li>1<ol>\n<li>2</li>\n</ol>\n</li>\n</ul>\n", false),
        tc("Nested 106", "1. 1\n   - 2", "<ol>\n<li>1<ul>\n<li>2</li>\n</ul>\n</li>\n</ol>\n", false),
        tc("Nested 107", "- [ ] 1\n  - [x] 2", "<ul>\n<li><input type=\"checkbox\"  disabled> 1<ul>\n<li><input type=\"checkbox\" checked disabled> 2</li>\n</ul>\n</li>\n</ul>\n", false),
        tc("Nested 108", "> # H", "<blockquote><h1>H</h1>\n</blockquote>\n", false),
        tc("Nested 109", "> ```\n> C\n> ```", "<blockquote><pre><code>C\n</code></pre>\n</blockquote>\n", false),
        tc("Nested 110", "> $$ M $$", "<blockquote><div class=\"math\">\nM\n</div>\n</blockquote>\n", false),
        tc("Nested 111", "- # H", "<ul>\n<li><h1>H</h1>\n</li>\n</ul>\n", false),
        tc("Nested 112", "- ```\n  C\n  ```", "<ul>\n<li><pre><code>C\n</code></pre>\n</li>\n</ul>\n", false),
        tc("Nested 113", "- $$ M $$", "<ul>\n<li><div class=\"math\">\nM\n</div>\n</li>\n</ul>\n", false),
        tc("Nested 114", "1. # H", "<ol>\n<li><h1>H</h1>\n</li>\n</ol>\n", false),
        tc("Nested 115", "1. ```\n   C\n   ```", "<ol>\n<li><pre><code>C\n</code></pre>\n</li>\n</ol>\n", false),
        tc("Nested 116", "1. $$ M $$", "<ol>\n<li><div class=\"math\">\nM\n</div>\n</li>\n</ol>\n", false),
        tc("Deep Inline 1", "**_`C`_**", "<p><strong><em><code>C</code></em></strong></p>\n", false),
        tc("Deep Inline 2", "_**`C`**_", "<p><em><strong><code>C</code></strong></em></p>\n", false),
        tc("Deep Inline 3", "`**_T_**`", "<p><code>**_T_**</code></p>\n", false),
        tc("Deep Inline 4", "[**_T_**](u)", "<p><a href=\"u\"><strong><em>T</em></strong></a></p>\n", false),
        tc("Deep Inline 5", "![**_T_**](u)", "<p><img src=\"u\" alt=\"**_T_**\"></p>\n", false),
        tc("Deep Inline 6", "$**_T_**$", "<p><span class=\"math\">**_T_**</span></p>\n", false),
    };

    const allocator = std.testing.allocator;
    for (cases) |case| {
        const output = try render(allocator, case.input, case.enable_html);
        defer allocator.free(output);
        try std.testing.expectEqualStrings(case.expected, output);
    }
}
