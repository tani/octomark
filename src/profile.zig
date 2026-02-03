const std = @import("std");
const octomark = @import("octomark.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Loading compliance test examples from commonmark-spec/spec.txt...\n", .{});
    const spec_content = try std.fs.cwd().readFileAlloc(allocator, "commonmark-spec/spec.txt", 10 * 1024 * 1024);
    defer allocator.free(spec_content);

    var examples = std.ArrayListUnmanaged(u8){};
    defer examples.deinit(allocator);

    var it = std.mem.splitSequence(u8, spec_content, "example\n");
    _ = it.next(); // Skip everything before the first "example\n"
    while (it.next()) |chunk| {
        if (std.mem.indexOf(u8, chunk, "\n.\n")) |dot_pos| {
            try examples.appendSlice(allocator, chunk[0..dot_pos]);
            try examples.append(allocator, '\n');
        }
    }

    if (examples.items.len == 0) {
        std.debug.print("No examples found in spec.txt, falling back to EXAMPLE.md\n", .{});
        const block = try std.fs.cwd().readFileAlloc(allocator, "EXAMPLE.md", 1 << 20);
        defer allocator.free(block);
        try examples.appendSlice(allocator, block);
    }

    const block = examples.items;
    const target_size = 10 * 1024 * 1024;
    const iterations = target_size / block.len;
    const total_size = iterations * block.len;

    const data = try allocator.alloc(u8, total_size);
    defer allocator.free(data);

    var p: usize = 0;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        @memcpy(data[p .. p + block.len], block);
        p += block.len;
    }

    var parser: octomark.OctomarkParser = undefined;
    try parser.init(allocator);
    parser.options.enable_html = true;
    defer parser.deinit(allocator);

    std.debug.print("Profiling Octomark with {d}MB input (repeated spec examples)...\n", .{total_size / 1024 / 1024});

    var timer = try std.time.Timer.start();
    const start = timer.read();

    var stream = std.io.fixedBufferStream(data);
    const reader = stream.reader();

    // We use a null writer to measure only parsing performance
    const null_writer = std.io.null_writer;

    try parser.parse(reader, null_writer, allocator);

    const end = timer.read();
    const elapsed_ns = end - start;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const throughput = (@as(f64, @floatFromInt(data.len)) / 1024.0 / 1024.0 / 1024.0) / (elapsed_ms / 1000.0);

    std.debug.print("Time: {d:.2} ms | Throughput: {d:.2} GB/s\n", .{ elapsed_ms, throughput });

    parser.dumpStats();
}
