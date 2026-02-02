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

    var reader = std.io.Reader.fixed(input);
    var writer_alloc = std.io.Writer.Allocating.init(allocator);
    defer allocator.free(writer_alloc.writer.buffer);

    try parser.parse(&reader, &writer_alloc.writer, allocator);

    const result = writer_alloc.writer.buffered();
    const final = try allocator.alloc(u8, result.len);
    @memcpy(final, result);
    return final;
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

    var reader = std.io.Reader.fixed(input.items);
    var writer_alloc = std.io.Writer.Allocating.init(allocator);
    defer allocator.free(writer_alloc.writer.buffer);

    const result = parser.parse(&reader, &writer_alloc.writer, allocator);
    try std.testing.expectError(error.NestingTooDeep, result);
}

// Table Column Limit test removed - table auto-detection no longer supported (simplification #1)
