const std = @import("std");
const octomark = @import("octomark.zig");

// Helper to verify rendering output
fn verifyRender(parser: *octomark.OctomarkParser, input: []const u8, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    var out_list = std.ArrayListUnmanaged(u8){};
    defer out_list.deinit(allocator);

    var stream = std.io.fixedBufferStream(input);
    try parser.parse(stream.reader(), out_list.writer(allocator), allocator);

    // Trim warnings or extra newlines if necessary, but octomark usually outputs exact HTML
    const actual = out_list.items;

    if (!std.mem.eql(u8, actual, expected)) {
        std.debug.print("\nFAIL:\nInput:\n{s}\nExpected:\n{s}\nActual:\n{s}\n", .{ input, expected, actual });
        return error.TestFailed;
    }
}

test "compliance reproduction cases" {
    var parser: octomark.OctomarkParser = undefined;
    const allocator = std.testing.allocator;
    try parser.init(allocator);
    defer parser.deinit(allocator);
    // Enable HTML for these tests
    parser.setOptions(.{ .enable_html = true });

    // 1. HTML Block Content Loss (Example 187)
    // The parser was dropping 'bar'
    try verifyRender(&parser, "Foo\n<div>\nbar\n</div>", "<p>Foo</p>\n<div>\nbar\n</div>\n");

    parser.deinit(allocator);
    try parser.init(allocator);
    parser.setOptions(.{ .enable_html = true });

    // 2. Entity Null Char (Example 26)
    // Should be replaced by replacement character U+FFFD ()
    // Note: CommonMark might expect specific handling.
    // Example 26: &#35; &#1234; &#992; &#0; -> <p># Ӓ Ϡ </p>
    try verifyRender(&parser, "&#35; &#1234; &#992; &#0;", "<p># Ӓ Ϡ \xEF\xBF\xBD</p>\n");

    parser.deinit(allocator);
    try parser.init(allocator);
    parser.setOptions(.{ .enable_html = true });

    // 4. Emphasis Flanking Rules (Example 378)
    // _foo_bar_baz_ -> <p><em>foo_bar_baz</em></p>
    try verifyRender(&parser, "_foo_bar_baz_", "<p><em>foo_bar_baz</em></p>\n");
}
