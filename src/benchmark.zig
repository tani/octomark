const std = @import("std");
const octomark = @import("octomark.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    std.debug.print("--- OctoMark Zig Performance Benchmark & O(N) Verification ---\n", .{});

    const input_path = "EXAMPLE.md";
    const block = try std.fs.cwd().readFileAlloc(allocator, input_path, 1 << 30);
    defer allocator.free(block);
    if (block.len == 0) {
        std.debug.print("Empty or invalid {s}\n", .{input_path});
        return;
    }

    const sizes_mb = [_]usize{ 10, 50, 100, 200 };
    var null_file = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only });
    defer null_file.close();

    for (sizes_mb) |target_mb| {
        const target_bytes = target_mb * 1024 * 1024;
        var iterations = target_bytes / block.len;
        if (iterations == 0) iterations = 1;
        const total_size = iterations * block.len;

        var data = try allocator.alloc(u8, total_size);
        defer allocator.free(data);

        var p: usize = 0;
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            std.mem.copyForwards(u8, data[p .. p + block.len], block);
            p += block.len;
        }

        var parser: octomark.OctomarkParser = .{};
        try parser.init(allocator);
        defer parser.deinit(allocator);

        var write_buffer: [4096]u8 = undefined;
        var writer = null_file.writer(&write_buffer);

        var timer = try std.time.Timer.start();

        var stream = std.io.fixedBufferStream(data);
        const reader = stream.reader();

        try parser.parse(reader, &writer.interface, allocator);
        try writer.interface.flush();

        const elapsed_ns = timer.read();
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
        const gb_s = (@as(f64, @floatFromInt(total_size)) / (1024.0 * 1024.0 * 1024.0)) /
            (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);

        std.debug.print(
            "Size: {d:>3} MB | Time: {d:>7.2} ms | Throughput: {d:.2} GB/s\n",
            .{ target_mb, elapsed_ms, gb_s },
        );
    }
}
