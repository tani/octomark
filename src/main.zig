const std = @import("std");
const octomark = @import("octomark.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var parser: octomark.OctomarkParser = undefined;
    try parser.init(allocator);
    defer parser.deinit(allocator);

    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;

    var reader = stdin.reader(&read_buffer);
    var writer = stdout.writer(&write_buffer);

    try parser.parse(&reader.interface, &writer.interface, allocator);
    try writer.interface.flush();
}
