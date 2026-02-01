const std = @import("std");
const octomark = @import("octomark.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var parser: octomark.OctomarkParser = undefined;
    try parser.init(allocator);
    defer parser.deinit(allocator);

    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

    var in_buf: [4096]u8 = undefined;
    var out_buf: [4096]u8 = undefined;

    var stdin_reader = stdin.reader(&in_buf);
    var stdout_writer = stdout.writer(&out_buf);

    try parser.parse(&stdin_reader.interface, &stdout_writer.interface, allocator);
    try stdout_writer.interface.flush();
}
