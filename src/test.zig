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

fn trimSpaces(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t");
}

fn parseExampleFence(line: []const u8) ?usize {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    const start = i;
    while (i < line.len and line[i] == '`') : (i += 1) {}
    const count = i - start;
    if (count < 3) return null;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i + 7 > line.len) return null;
    if (!std.mem.eql(u8, line[i .. i + 7], "example")) return null;
    i += 7;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i != line.len) return null;
    return count;
}

fn isClosingFence(line: []const u8, count: usize) bool {
    const t = trimSpaces(line);
    if (t.len != count) return false;
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        if (t[i] != '`') return false;
    }
    return true;
}

fn isDotLine(line: []const u8) bool {
    const t = trimSpaces(line);
    return t.len == 1 and t[0] == '.';
}

fn nextLine(data: []const u8, idx: *usize) ?struct { line: []const u8, has_newline: bool } {
    if (idx.* >= data.len) return null;
    const start = idx.*;
    var i = start;
    while (i < data.len and data[i] != '\n') : (i += 1) {}
    const has_newline = i < data.len;
    var end = i;
    if (end > start and data[end - 1] == '\r') end -= 1;
    idx.* = if (has_newline) i + 1 else i;
    return .{ .line = data[start..end], .has_newline = has_newline };
}

fn appendWithArrowTabs(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, line: []const u8, has_newline: bool) !void {
    var i: usize = 0;
    while (i < line.len) {
        if (i + 2 < line.len and line[i] == 0xE2 and line[i + 1] == 0x86 and line[i + 2] == 0x92) {
            try buf.append(allocator, '\t');
            i += 3;
            continue;
        }
        try buf.append(allocator, line[i]);
        i += 1;
    }
    if (has_newline) try buf.append(allocator, '\n');
}

fn normalizeHtml(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const code =
        \\import os, sys
        \\sys.path.insert(0, os.path.join(os.getcwd(), 'commonmark-spec', 'test'))
        \\from normalize import normalize_html
        \\data = sys.stdin.buffer.read().decode('utf-8')
        \\sys.stdout.write(normalize_html(data) + '\n')
    ;
    var child = std.process.Child.init(&[_][]const u8{ "python3", "-c", code }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    if (child.stdin) |stdin| {
        try stdin.writeAll(input);
        stdin.close();
        child.stdin = null;
    }
    const stdout = if (child.stdout) |stdout| blk: {
        const data = try stdout.readToEndAlloc(allocator, std.math.maxInt(usize));
        stdout.close();
        child.stdout = null;
        break :blk data;
    } else try allocator.alloc(u8, 0);
    const stderr = if (child.stderr) |stderr| blk: {
        const data = try stderr.readToEndAlloc(allocator, std.math.maxInt(usize));
        stderr.close();
        child.stderr = null;
        break :blk data;
    } else try allocator.alloc(u8, 0);
    defer allocator.free(stderr);
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        std.debug.print("normalize_html failed: {s}\n", .{stderr});
        return error.NormalizeFailed;
    }
    return stdout;
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

test "commonmark spec compliance summary" {
    const allocator = std.testing.allocator;
    const fail_on_mismatch = false;
    const normalize = true;

    var file = try std.fs.cwd().openFile("commonmark-spec/spec.txt", .{});
    defer file.close();
    const data = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);

    var input_buf = std.ArrayListUnmanaged(u8){};
    var output_buf = std.ArrayListUnmanaged(u8){};
    defer input_buf.deinit(allocator);
    defer output_buf.deinit(allocator);

    var pass_count: usize = 0;
    var fail_count: usize = 0;
    var total_count: usize = 0;

    var idx: usize = 0;
    while (nextLine(data, &idx)) |line_info| {
        if (parseExampleFence(line_info.line)) |fence_len| {
            total_count += 1;
            input_buf.clearRetainingCapacity();
            output_buf.clearRetainingCapacity();

            var separator_found = false;
            while (nextLine(data, &idx)) |in_line| {
                if (isDotLine(in_line.line)) {
                    separator_found = true;
                    break;
                }
                try appendWithArrowTabs(&input_buf, allocator, in_line.line, in_line.has_newline);
            }
            if (!separator_found) return error.InvalidSpec;

            var closing_found = false;
            while (nextLine(data, &idx)) |out_line| {
                if (isClosingFence(out_line.line, fence_len)) {
                    closing_found = true;
                    break;
                }
                try appendWithArrowTabs(&output_buf, allocator, out_line.line, out_line.has_newline);
            }
            if (!closing_found) return error.InvalidSpec;

            var parser: octomark.OctomarkParser = undefined;
            try parser.init(allocator);
            defer parser.deinit(allocator);
            parser.setOptions(.{ .enable_html = true });

            var out_list = std.ArrayListUnmanaged(u8){};
            defer out_list.deinit(allocator);

            var stream = std.io.fixedBufferStream(input_buf.items);
            try parser.parse(stream.reader(), out_list.writer(allocator), allocator);
            var actual = out_list.items;
            var expected = output_buf.items;
            var normalized_actual: ?[]u8 = null;
            var normalized_expected: ?[]u8 = null;
            defer {
                if (normalized_actual) |buf| allocator.free(buf);
                if (normalized_expected) |buf| allocator.free(buf);
            }
            if (normalize) {
                normalized_actual = try normalizeHtml(allocator, actual);
                normalized_expected = try normalizeHtml(allocator, expected);
                actual = normalized_actual.?;
                expected = normalized_expected.?;
            }
            if (std.mem.eql(u8, actual, expected)) {
                pass_count += 1;
            } else {
                fail_count += 1;
            }
        }
    }

    std.debug.print(
        "\\nCommonMark compliance summary: total={d} pass={d} fail={d}\\n",
        .{ total_count, pass_count, fail_count },
    );
    if (fail_on_mismatch and fail_count > 0) return error.TestFailed;
}
