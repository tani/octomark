const std = @import("std");
const octomark = @import("octomark.zig");

fn runBench(allocator: std.mem.Allocator, input: []const u8) !u64 {
    var parser: octomark.OctomarkParser = undefined;
    try parser.init(allocator);
    defer parser.deinit(allocator);

    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);
    const writer = output.writer(allocator);

    var timer = try std.time.Timer.start();
    var reader = std.io.Reader.fixed(input);
    try parser.parse(&reader, writer, allocator);
    return timer.read();
}

test "Pathological Case: 10,000 unclosed asterisks" {
    const allocator = std.testing.allocator;
    const size = 10000;
    const input = try allocator.alloc(u8, size);
    defer allocator.free(input);
    @memset(input, '*');

    const time = try runBench(allocator, input);
    std.debug.print("\n10k unclosed *: {d:>12} ns\n", .{time});
}

test "Pathological Case: 20,000 unclosed asterisks (Double size)" {
    const allocator = std.testing.allocator;
    const size = 20000;
    const input = try allocator.alloc(u8, size);
    defer allocator.free(input);
    @memset(input, '*');

    const time = try runBench(allocator, input);
    std.debug.print("20k unclosed *: {d:>12} ns\n", .{time});
}

test "Pathological Case: Unclosed links" {
    const allocator = std.testing.allocator;
    const count = 1000;
    const input = try allocator.alloc(u8, count * 2);
    defer allocator.free(input);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        input[i * 2] = '[';
        input[i * 2 + 1] = 'a';
    }

    const time = try runBench(allocator, input);
    std.debug.print("1k unclosed [: {d:>12} ns\n", .{time});
}

test "Pathological Case: Unclosed links (Double size)" {
    const allocator = std.testing.allocator;
    const count = 2000;
    const input = try allocator.alloc(u8, count * 2);
    defer allocator.free(input);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        input[i * 2] = '[';
        input[i * 2 + 1] = 'a';
    }

    const time = try runBench(allocator, input);
    std.debug.print("2k unclosed [: {d:>12} ns\n", .{time});
}

test "Deep Nesting: 32 levels" {
    const allocator = std.testing.allocator;
    var input = std.ArrayListUnmanaged(u8){};
    defer input.deinit(allocator);

    var i: usize = 0;
    while (i < 16) : (i += 1) {
        try input.appendSlice(allocator, "**_");
    }
    try input.appendSlice(allocator, "Content");
    i = 0;
    while (i < 16) : (i += 1) {
        try input.appendSlice(allocator, "_**");
    }

    const time = try runBench(allocator, input.items);
    std.debug.print("Deeply nested (32 levels): {d:>12} ns\n", .{time});
}
