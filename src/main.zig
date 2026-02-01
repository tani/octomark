const std = @import("std");
const octomark = @import("octomark.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var parser: octomark.OctomarkParser = undefined;
    try parser.init(allocator);
    defer parser.deinit(allocator);

    const stdin_file = std.fs.File.stdin();
    var reader_buffer: [65536]u8 = undefined;
    var reader = stdin_file.reader(&reader_buffer);
    var writer_buffer: [65536]u8 = undefined;
    var writer = octomark.FastWriter.fromStdout(&writer_buffer);
    var chunk: [65536]u8 = undefined;

    while (true) {
        const n = try reader.interface.readSliceShort(&chunk);
        if (n == 0) break;
        try parser.feed(chunk[0..n], &writer, allocator);
    }

    try parser.finish(&writer);
    try writer.flush();
}
