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
        tc("Math Support", "$$E=mc^2$$", "<div class=\"math\">\n</div>\n", false),
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

test "comprehensive cases" {
    const cases = [_]TestCase{
        tc("Header 1", "# H1", "<h1>H1</h1>\n", false),
        tc("Header 2", "## H2", "<h2>H2</h2>\n", false),
        tc("Header 3", "### H3", "<h3>H3</h3>\n", false),
        tc("Header 4", "#### H4", "<h4>H4</h4>\n", false),
        tc("Header 5", "##### H5", "<h5>H5</h5>\n", false),
        tc("Header 6", "###### H6", "<h6>H6</h6>\n", false),
        tc("Invalid Header 7", "####### H7", "<p>####### H7</p>\n", false),
        tc("Invalid Header No Space", "#Header", "<p>#Header</p>\n", false),
        tc("Header with Bold", "# **Bold**", "<h1><strong>Bold</strong></h1>\n", false),
        tc("Header with Code", "## `Code`", "<h2><code>Code</code></h2>\n", false),
        tc("Header with Link", "### [Link](url)", "<h3><a href=\"url\">Link</a></h3>\n", false),
        tc("List Ordered Start 1", "1. Item", "<ol>\n<li>Item</li>\n</ol>\n", false),
        tc("List Ordered Start 0", "0. Item", "<ol>\n<li>Item</li>\n</ol>\n", false),
        tc("List Unordered Star", "* Item", "<p>* Item</p>\n", false),
        tc("List Unordered Dash", "- Item", "<ul>\n<li>Item</li>\n</ul>\n", false),
        tc("List Unordered Plus", "+ Item", "<p>+ Item</p>\n", false),
        tc("List Nested 3 Levels", "- 1\n  - 2\n    - 3", "<ul>\n<li>1<ul>\n<li>2<ul>\n<li>3</li>\n</ul>\n</li>\n</ul>\n</li>\n</ul>\n", false),
        tc("List Mixed Nesting", "- 1\n  1. 2", "<ul>\n<li>1<ol>\n<li>2</li>\n</ol>\n</li>\n</ul>\n", false),
        tc("Task List Checked", "- [x] Done", "<ul>\n<li><input type=\"checkbox\" checked disabled> Done</li>\n</ul>\n", false),
        tc("Task List Unchecked", "- [ ] Todo", "<ul>\n<li><input type=\"checkbox\"  disabled> Todo</li>\n</ul>\n", false),
        tc("Task List Invalid", "- [o] Invalid", "<ul>\n<li>[o] Invalid</li>\n</ul>\n", false),
        tc("Code Block Fenced Backtick", "```\ncode\n```", "<pre><code>code\n</code></pre>\n", false),
        tc("Code Block Fenced Tilde", "~~~\ncode\n~~~", "<p>~~~\ncode\n~~~</p>\n", false),
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
        tc("HTML Pass", "<div>Content</div>", "<p><div>Content</div></p>\n", true),
        tc("Empty Input", "", "", false),
        tc("Whitespace Input", "   ", "", false),
    };

    const allocator = std.testing.allocator;
    for (cases) |case| {
        const output = try render(allocator, case.input, case.enable_html);
        defer allocator.free(output);
        try std.testing.expectEqualStrings(case.expected, output);
    }
}
