const std = @import("std");
const octomark = @import("octomark");

const SpecTest = struct {
    markdown: []const u8,
    html: []const u8,
    example: i32,
    start_line: i32,
    end_line: i32,
    section: []const u8,
};

fn render(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var parser: octomark.OctomarkParser = undefined;
    try parser.init(allocator);
    defer parser.deinit(allocator);

    // Enable HTML support as per spec requirements (often needed for full compliance)
    parser.setOptions(.{ .enable_html = true });

    var fbs = std.io.fixedBufferStream(input);
    const reader = fbs.reader();

    var writer_buffer = std.ArrayList(u8).init(allocator);
    defer writer_buffer.deinit();
    const writer = writer_buffer.writer();

    try parser.parse(reader, writer, allocator);

    return writer_buffer.toOwnedSlice();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const file = try std.fs.cwd().openFile("spec.json", .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(buffer);

    const bytes_read = try file.readAll(buffer);
    const json_content = buffer[0..bytes_read];

    const parsed = try std.json.parseFromSlice([]SpecTest, allocator, json_content, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var passed: usize = 0;
    var failed: usize = 0;

    const stdout = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout);
    const writer = bw.writer();

    const tests = parsed.value;

    try writer.print("Running {d} tests...\n", .{tests.len});

    for (tests) |test_case| {
        const output = render(allocator, test_case.markdown) catch |err| {
            try writer.print("Test #{d} ({s}) ERROR: {}\n", .{ test_case.example, test_case.section, err });
            failed += 1;
            continue;
        };
        defer allocator.free(output);

        const expected_trimmed = std.mem.trim(u8, test_case.html, &std.ascii.whitespace);
        const actual_trimmed = std.mem.trim(u8, output, &std.ascii.whitespace);

        if (std.mem.eql(u8, expected_trimmed, actual_trimmed)) {
            passed += 1;
        } else {
            failed += 1;
        }
    }

    try writer.print("\nCompliance Report:\n", .{});
    try writer.print("------------------\n", .{});
    try writer.print("Total Tests:  {d}\n", .{tests.len});
    try writer.print("Passed:       {d}\n", .{passed});
    try writer.print("Failed:       {d}\n", .{failed});

    if (tests.len > 0) {
        const rate = @as(f64, @floatFromInt(passed)) / @as(f64, @floatFromInt(tests.len)) * 100.0;
        try writer.print("Success Rate: {d:.2}%\n", .{rate});
    }

    try bw.flush();
}
