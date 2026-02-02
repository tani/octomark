const std = @import("std");
const octomark = @import("octomark.zig");

test "debug HTML edge cases" {
    var parser: octomark.OctomarkParser = undefined;
    const allocator = std.testing.allocator;
    try parser.init(allocator);
    defer parser.deinit(allocator);
    parser.setOptions(.{ .enable_html = true });

    const verifyTag = struct {
        fn call(p: *octomark.OctomarkParser, input: []const u8, expect_valid: bool) !void {
            const len = p.parseHtmlTag(input);
            if (expect_valid) {
                if (len == 0) std.debug.print("FAIL: Expected valid, got 0 for '{s}'\n", .{input});
                try std.testing.expect(len > 0);
            } else {
                if (len > 0) std.debug.print("FAIL: Expected invalid, got {} for '{s}'\n", .{ len, input });
                try std.testing.expectEqual(@as(usize, 0), len);
            }
        }
    }.call;

    // 611: <m:abc> should be invalid (colon in tag name)
    try verifyTag(&parser, "<m:abc>", false);

    // 628: <!--> should be invalid (text starts with >)
    try verifyTag(&parser, "<!-->", false);
    try verifyTag(&parser, "<!--->", false);

    // Strict comment: no -- inside
    try verifyTag(&parser, "<!-- foo -- bar -->", false);

    // 624: <a href='bar'title=title> should be invalid (missing whitespace)
    try verifyTag(&parser, "<a href='bar'title=title>", false);

    // Multi-line should be valid
    try verifyTag(&parser, "<a\nhref='bar'>", true);
}
