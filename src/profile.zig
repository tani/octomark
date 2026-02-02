const std = @import("std");
const octomark = @import("octomark.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Generating 10MB dataset by repeating EXAMPLE.md...\n", .{});
    const block = try std.fs.cwd().readFileAlloc(allocator, "EXAMPLE.md", 1 << 20);
    defer allocator.free(block);

    const target_size = 10 * 1024 * 1024;
    const iterations = target_size / block.len;
    const total_size = iterations * block.len;

    const data = try allocator.alloc(u8, total_size);
    defer allocator.free(data);

    var p: usize = 0;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        std.mem.copyForwards(u8, data[p .. p + block.len], block);
        p += block.len;
    }

    var parser: octomark.OctomarkParser = undefined;
    try parser.init(allocator);
    parser.options.enable_html = true;
    defer parser.deinit(allocator);

    std.debug.print("Profiling Octomark with 10MB input...\n", .{});

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
