const std = @import("std");
const builtin = @import("builtin");
const MAX_BLOCK_NESTING = 32;
const MAX_INLINE_NESTING = 32;
const BlockType = enum(u8) {
    unordered_list,
    ordered_list,
    blockquote,
    definition_list,
    definition_description,
    code,
    indented_code,
    math,
    table,
    html_block,
    paragraph,
};
const block_close_tags = [_][]const u8{
    "</li>\n</ul>\n",
    "</li>\n</ol>\n",
    "</blockquote>\n",
    "</dl>\n",
    "</dd>\n",
    "</code></pre>\n",
    "</code></pre>\n",
    "</div>\n",
    "</tbody></table>\n",
    "",
    "</p>\n",
};
const TableAlignment = enum { none, left, center, right };
const BlockEntry = struct {
    block_type: BlockType,
    indent_level: i32,
    content_indent: i32,
    loose: bool,
    pending_empty_item: bool = false,
    buffer_index: i32 = -1,
    extra_type: u8 = 0,
    fence_char: u8 = 0,
    fence_count: u8 = 0,
    list_start: u32 = 0,
};
const Buffer = std.ArrayListUnmanaged(u8);
const AllocError = std.mem.Allocator.Error;
const ParseError = AllocError || std.fs.File.WriteError || error{
    NestingTooDeep,
    TooManyTableColumns,
};
pub const OctomarkOptions = struct {
    enable_html: bool = true,
};
const special_chars = "\\['*`&<>\"'_~!$\n";
const punct_symbol_ranges = [_][2]u32{
    .{ 0x00A1, 0x00BF },
    .{ 0x2000, 0x206F },
    .{ 0x20A0, 0x20CF },
    .{ 0x2100, 0x214F },
    .{ 0x2190, 0x21FF },
    .{ 0x2200, 0x22FF },
    .{ 0x2300, 0x23FF },
    .{ 0x2400, 0x243F },
    .{ 0x2440, 0x245F },
    .{ 0x2460, 0x24FF },
    .{ 0x2500, 0x257F },
    .{ 0x2580, 0x259F },
    .{ 0x25A0, 0x25FF },
    .{ 0x2600, 0x26FF },
    .{ 0x2700, 0x27BF },
    .{ 0x27C0, 0x27EF },
    .{ 0x27F0, 0x27FF },
    .{ 0x2800, 0x28FF },
    .{ 0x2900, 0x297F },
    .{ 0x2980, 0x29FF },
    .{ 0x2A00, 0x2AFF },
    .{ 0x2B00, 0x2BFF },
    .{ 0x2E00, 0x2E7F },
    .{ 0x3000, 0x303F },
    .{ 0xFE10, 0xFE1F },
    .{ 0xFE30, 0xFE4F },
    .{ 0xFE50, 0xFE6F },
    .{ 0xFF00, 0xFFEF },
    .{ 0x1E2C0, 0x1E2FF },
    .{ 0x1F300, 0x1F5FF },
    .{ 0x1F600, 0x1F64F },
    .{ 0x1F680, 0x1F6FF },
    .{ 0x1F700, 0x1F77F },
    .{ 0x1F780, 0x1F7FF },
    .{ 0x1F800, 0x1F8FF },
    .{ 0x1F900, 0x1F9FF },
    .{ 0x1FA00, 0x1FAFF },
};
const html_escape_map = blk: {
    var map = [_]?[]const u8{null} ** 256;
    map['&'] = "&amp;";
    map['<'] = "&lt;";
    map['>'] = "&gt;";
    map['\"'] = "&quot;";
    map['\''] = "&#39;";
    break :blk map;
};

fn leadingIndent(line: []const u8) struct { idx: usize, columns: usize } {
    if (line.len == 0 or (line[0] != ' ' and line[0] != '\t' and line[0] != '\r')) return .{ .idx = 0, .columns = 0 };
    var idx: usize = 0;
    var columns: usize = 0;
    while (idx < line.len) : (idx += 1) switch (line[idx]) {
        ' ' => columns += 1,
        '\t' => columns += 4 - (columns % 4),
        '\r' => columns += 1,
        else => break,
    };
    return .{ .idx = idx, .columns = columns };
}

fn stripIndentColumns(line: []const u8, columns: usize) []const u8 {
    var idx: usize = 0;
    var col: usize = 0;
    while (idx < line.len and col < columns) : (idx += 1) switch (line[idx]) {
        ' ' => col += 1,
        '\t' => col += 4 - (col % 4),
        '\r' => col += 1,
        else => break,
    };
    return line[idx..];
}

fn isThematicBreakLine(line: []const u8) bool {
    var marker: u8 = 0;
    var count: usize = 0;
    for (line) |c| {
        if (c == ' ' or c == '\t') continue;
        if (c != '*' and c != '-' and c != '_') return false;
        if (marker == 0) marker = c else if (c != marker) return false;
        count += 1;
    }
    return count >= 3;
}

pub const OctomarkParser = struct {
    table_alignments: [64]TableAlignment = [_]TableAlignment{.none} ** 64,
    table_column_count: usize = 0,
    block_stack: [MAX_BLOCK_NESTING]BlockEntry = undefined,
    stack_depth: usize = 0,
    pending_buffer: Buffer = .{},
    paragraph_content: std.ArrayList(u8) = undefined,
    pending_code_blank_lines: std.ArrayList(usize) = undefined,
    delimiter_stack: [MAX_INLINE_NESTING]Delimiter = undefined,
    delimiter_stack_len: usize = 0,
    replacements: std.ArrayList(Replacement) = undefined,
    allocator: std.mem.Allocator = undefined,
    options: OctomarkOptions = .{},
    stats: if (builtin.mode == .Debug) Stats else struct {} = .{},
    pending_task_marker: u8 = 0,
    pending_loose_idx: ?usize = null,
    prev_line_blank: bool = false,
    active_list_stack_idx: i32 = -1,
    blockquote_depth: u8 = 0,
    list_buffers: std.ArrayListUnmanaged(ListBuffer) = .{},
    timer: if (builtin.mode == .Debug) std.time.Timer else struct {} = undefined,
    const ListMetaTag = enum(u8) {
        item,
        paragraph,
    };
    const ListMeta = struct {
        tag: ListMetaTag,
        start: usize,
        end: usize = 0,
        flags: u8 = 0,
    };
    const ListMetaFlags = struct {
        const has_block: u8 = 1 << 0;
        const has_p: u8 = 1 << 1;
    };
    const ListBuffer = struct {
        bytes: std.ArrayListUnmanaged(u8),
        meta: std.ArrayListUnmanaged(ListMeta),
        last_item_idx: ?usize = null,
        para_count: usize = 0,
    };
    const Delimiter = struct {
        pos: usize,
        content_end: usize,
        char: u8,
        count: usize,
        can_open: bool,
        can_close: bool,
        active: bool,
    };
    const Replacement = struct {
        pos: usize,
        end: usize,
        text: []const u8,
    };
    const Stats = struct {
        const C = struct {
            count: usize = 0,
            time_ns: u64 = 0,
        };
        feed: C = .{},
        processSingleLine: C = .{},
        parseInlineContent: C = .{},
        parseHeader: C = .{},
        parseHorizontalRule: C = .{},
        parseFencedCodeBlock: C = .{},
        parseMathBlock: C = .{},
        parseListItem: C = .{},
        parseTable: C = .{},
        parseDefinitionList: C = .{},
        parseDefinitionTerm: C = .{},
        esc: C = .{},
        findSpec: C = .{},
        renderTop: C = .{},
        pushBlock: C = .{},
        pop: C = .{},
        parseHtmlTag: C = .{},
        splitTableRowCells: C = .{},
        isBlockStartMarker: C = .{},
        isNextLineTableSeparator: C = .{},
        finish: C = .{},
        closeP: C = .{},
        tryCloseLeaf: C = .{},
        scanDelimiters: C = .{},
        scanInline: C = .{},
        renderInline: C = .{},
        parseIndentedCodeBlock: C = .{},
        processLeafBlockContinuation: C = .{},
        processParagraph: C = .{},
        init: C = .{},
        deinit: C = .{},
        setOptions: C = .{},
        parse: C = .{},
        pushBlockExtra: C = .{},
        currentListBufferIndex: C = .{},
        listItemStart: C = .{},
        listItemEnd: C = .{},
        listItemMarkBlock: C = .{},
        listItemMarkParagraph: C = .{},
        listItemRecordParagraphSpan: C = .{},
        applyPendingLoose: C = .{},
        findLabelEnd: C = .{},
        parseInlineLink: C = .{},
        labelHasLinkLike: C = .{},
        parseInlineContentScoped: C = .{},
    };
    inline fn startCall(self: *OctomarkParser, comptime field: std.meta.FieldEnum(Stats)) u64 {
        if (builtin.mode == .Debug) {
            @field(self.stats, @tagName(field)).count += 1;
            return self.timer.read();
        }
        return 0;
    }
    inline fn endCall(self: *OctomarkParser, comptime field: std.meta.FieldEnum(Stats), s: u64) void {
        if (builtin.mode == .Debug) {
            @field(self.stats, @tagName(field)).time_ns += self.timer.read() - s;
        }
    }
    pub fn init(self: *OctomarkParser, allocator: std.mem.Allocator) !void {
        self.* = .{
            .allocator = allocator,
            .paragraph_content = .{},
            .pending_code_blank_lines = .{},
            .replacements = .{},
            .pending_task_marker = 0,
            .pending_loose_idx = null,
            .active_list_stack_idx = -1,
            .blockquote_depth = 0,
            .list_buffers = .{},
        };
        if (builtin.mode == .Debug) self.timer = try std.time.Timer.start();
        self.pending_buffer = .{};
        try self.pending_buffer.ensureTotalCapacity(allocator, 4096);
    }
    pub fn deinit(self: *OctomarkParser, allocator: std.mem.Allocator) void {
        self.pending_buffer.deinit(allocator);
        self.paragraph_content.deinit(allocator);
        self.pending_code_blank_lines.deinit(allocator);
        self.replacements.deinit(allocator);
        for (self.list_buffers.items) |*lb| {
            lb.bytes.deinit(allocator);
            lb.meta.deinit(allocator);
        }
        self.list_buffers.deinit(allocator);
    }
    pub fn setOptions(self: *OctomarkParser, options: OctomarkOptions) void {
        const _s = self.startCall(.setOptions);
        defer self.endCall(.setOptions, _s);
        self.options = options;
    }
    pub fn parse(self: *OctomarkParser, reader: anytype, writer: anytype, allocator: std.mem.Allocator) !void {
        const _s = self.startCall(.parse);
        defer self.endCall(.parse, _s);
        var buf: [65536]u8 = undefined;
        const R = if (@typeInfo(@TypeOf(reader)) == .pointer) std.meta.Child(@TypeOf(reader)) else @TypeOf(reader);
        while (true) {
            const n = try if (@hasField(R, "interface")) reader.interface.readSliceShort(&buf) else if (@hasDecl(R, "read")) reader.read(&buf) else reader.readSliceShort(&buf);
            if (n == 0) break;
            try self.feed(buf[0..n], writer, allocator);
        }
        try self.finish(writer);
    }
    pub fn dumpStats(self: *const OctomarkParser) void {
        if (builtin.mode == .Debug) {
            std.debug.print("\n--- Octomark Stats ---\n{s: <25} | {s: >10} | {s: >15} | {s: >15}\n", .{
                "Function",
                "Calls",
                "Total Time",
                "Avg Call",
            });
            inline for (std.meta.fields(Stats)) |f| {
                const c = @field(self.stats, f.name);
                const avg = if (c.count > 0) c.time_ns / c.count else 0;
                std.debug.print("{s: <25} | {d: >10} | {d: >12.3} ms | {d: >12.3} ns\n", .{
                    f.name,
                    c.count,
                    @as(f64, @floatFromInt(c.time_ns)) / 1e6,
                    @as(f64, @floatFromInt(avg)),
                });
            }
        }
    }
    inline fn writeAll(p: *OctomarkParser, writer: anytype, bytes: []const u8) !void {
        if (p.currentListBuffer()) |lb| {
            try lb.bytes.appendSlice(p.allocator, bytes);
            return;
        }
        const W = if (@typeInfo(@TypeOf(writer)) == .pointer) std.meta.Child(@TypeOf(writer)) else @TypeOf(writer);
        if (comptime @hasField(W, "interface")) try writer.interface.writeAll(bytes) else try writer.writeAll(bytes);
    }
    inline fn writeByte(p: *OctomarkParser, writer: anytype, byte: u8) !void {
        if (p.currentListBuffer()) |lb| {
            try lb.bytes.append(p.allocator, byte);
            return;
        }
        const W = if (@typeInfo(@TypeOf(writer)) == .pointer) std.meta.Child(@TypeOf(writer)) else @TypeOf(writer);
        if (comptime @hasField(W, "interface")) try writer.interface.writeByte(byte) else try writer.writeByte(byte);
    }
    inline fn writeHex(p: *OctomarkParser, writer: anytype, byte: u8) !void {
        const hex = "0123456789ABCDEF";
        try p.writeByte(writer, hex[byte >> 4]);
        try p.writeByte(writer, hex[byte & 0xF]);
    }
    /// Feed a chunk into the parser. Returns error.OutOfMemory or writer errors.
    pub fn feed(self: *OctomarkParser, chunk: []const u8, output: anytype, allocator: std.mem.Allocator) !void {
        const _s = self.startCall(.feed);
        defer self.endCall(.feed, _s);
        try self.pending_buffer.appendSlice(allocator, chunk);
        const data = self.pending_buffer.items;
        const size = self.pending_buffer.items.len;
        var pos: usize = 0;
        while (pos < size) {
            const next = std.mem.indexOfScalar(u8, data[pos..], '\n');
            if (next == null) break;
            const line_len = next.?;
            const skip = try self.processSingleLine(data[pos .. pos + line_len], data, pos + line_len + 1, output);
            pos += line_len + 1;
            if (skip) {
                const nn = std.mem.indexOfScalar(u8, data[pos..], '\n');
                if (nn) |offset| {
                    pos += offset + 1;
                } else {
                    pos = size;
                }
            }
        }
        if (pos > 0) {
            const rem = size - pos;
            if (rem > 0) std.mem.copyForwards(u8, self.pending_buffer.items[0..rem], self.pending_buffer.items[pos .. pos + rem]);
            self.pending_buffer.items.len = rem;
        }
    }
    /// Finalize parsing and close any open blocks. Returns writer errors.
    pub fn finish(self: *OctomarkParser, output: anytype) !void {
        const _s = self.startCall(.finish);
        defer self.endCall(.finish, _s);
        if (self.pending_buffer.items.len > 0) {
            _ = try self.processSingleLine(
                self.pending_buffer.items[0..self.pending_buffer.items.len],
                self.pending_buffer.items,
                self.pending_buffer.items.len,
                output,
            );
        }
        while (self.stack_depth > 0) try self.renderTop(output);
    }
    fn pushBlock(p: *OctomarkParser, t: BlockType, i: i32) !void {
        const _s = p.startCall(.pushBlock);
        defer p.endCall(.pushBlock, _s);
        try p.pushBlockExtra(t, i, 0);
    }
    fn pushBlockExtra(p: *OctomarkParser, t: BlockType, i: i32, extra: u8) !void {
        const _s = p.startCall(.pushBlockExtra);
        defer p.endCall(.pushBlockExtra, _s);
        if (p.stack_depth >= MAX_BLOCK_NESTING) return error.NestingTooDeep;
        p.block_stack[p.stack_depth] = .{ .block_type = t, .indent_level = i, .content_indent = i, .loose = false, .extra_type = extra };
        if (t == .blockquote) p.blockquote_depth += 1;
        if (t == .unordered_list or t == .ordered_list) {
            p.listItemMarkBlock();
            const idx = self_list_buf_idx: {
                try p.list_buffers.append(p.allocator, .{
                    .bytes = .{},
                    .meta = .{},
                    .last_item_idx = null,
                    .para_count = 0,
                });
                break :self_list_buf_idx p.list_buffers.items.len - 1;
            };
            p.block_stack[p.stack_depth].buffer_index = @intCast(idx);
            p.active_list_stack_idx = @intCast(p.stack_depth);
        } else if (t != .paragraph) {
            p.listItemMarkBlock();
        }
        p.stack_depth += 1;
    }
    fn pop(p: *OctomarkParser) void {
        const _s = p.startCall(.pop);
        defer p.endCall(.pop, _s);
        if (p.stack_depth > 0) {
            const popped_idx = p.stack_depth - 1;
            const popped = p.block_stack[popped_idx];
            p.stack_depth -= 1;
            if (popped.block_type == .blockquote) p.blockquote_depth -= 1;
            if (p.active_list_stack_idx == @as(i32, @intCast(popped_idx))) {
                p.active_list_stack_idx = -1;
                var i = p.stack_depth;
                while (i > 0) {
                    i -= 1;
                    const bt = p.block_stack[i].block_type;
                    if (bt == .unordered_list or bt == .ordered_list) {
                        p.active_list_stack_idx = @intCast(i);
                        break;
                    }
                }
            }
        }
    }
    fn topT(p: *const OctomarkParser) ?BlockType {
        return if (p.stack_depth > 0) p.block_stack[p.stack_depth - 1].block_type else null;
    }
    fn renderTop(p: *OctomarkParser, o: anytype) !void {
        if (p.stack_depth == 0) return;
        const s = p.startCall(.renderTop);
        defer p.endCall(.renderTop, s);
        const t = p.block_stack[p.stack_depth - 1].block_type;
        if (t == .paragraph and p.paragraph_content.items.len == 0) {
            p.pop();
            return;
        }
        if (t == .indented_code) p.pending_code_blank_lines.clearRetainingCapacity();
        if (t == .unordered_list or t == .ordered_list) {
            const list_loose = p.block_stack[p.stack_depth - 1].loose;
            try p.flushListParagraph(o, list_loose);
            p.listItemEnd();
            const close_tag = block_close_tags[@intFromEnum(t)];
            const lb_idx: usize = @intCast(p.block_stack[p.stack_depth - 1].buffer_index);
            var lb = &p.list_buffers.items[lb_idx];
            if (lb.last_item_idx) |idx| {
                var last_item = &lb.meta.items[idx];
                if (last_item.tag == .item and last_item.end == 0) last_item.end = lb.bytes.items.len;
            }
            p.pop();
            if (list_loose and lb.para_count > 0) {
                var cursor: usize = 0;
                var i: usize = 0;
                while (i < lb.meta.items.len) : (i += 1) {
                    const p_meta = lb.meta.items[i];
                    if (p_meta.tag != .paragraph) continue;
                    if (p_meta.start < cursor or p_meta.end < p_meta.start or p_meta.end > lb.bytes.items.len) {
                        try p.writeAll(o, lb.bytes.items[cursor..]);
                        cursor = lb.bytes.items.len;
                        break;
                    }
                    try p.writeAll(o, lb.bytes.items[cursor..p_meta.start]);
                    try p.writeAll(o, "<p>");
                    try p.writeAll(o, lb.bytes.items[p_meta.start..p_meta.end]);
                    try p.writeAll(o, "</p>\n");
                    cursor = p_meta.end;
                }
                if (cursor < lb.bytes.items.len) try p.writeAll(o, lb.bytes.items[cursor..]);
                try p.writeAll(o, close_tag);
            } else {
                try p.writeAll(o, lb.bytes.items);
                try p.writeAll(o, close_tag);
            }
            if (p.pending_loose_idx) |idx| {
                if (p.stack_depth == 0 or idx >= p.stack_depth) p.pending_loose_idx = null;
            }
            return;
        }
        if (p.paragraph_content.items.len > 0) {
            if (t == .paragraph) {
                p.listItemMarkParagraph();
                try p.writeAll(o, "<p>");
            }
            const start_pos = if (p.currentListBuffer()) |lb| lb.bytes.items.len else 0;
            try p.parseInlineContent(p.paragraph_content.items, o);
            if (t != .paragraph) {
                if (p.currentListBuffer()) |lb| p.listItemRecordParagraphSpan(start_pos, lb.bytes.items.len);
            }
            p.paragraph_content.clearRetainingCapacity();
        }
        p.pop();
        if (p.pending_loose_idx) |idx| {
            if (p.stack_depth == 0 or idx >= p.stack_depth) p.pending_loose_idx = null;
        }
        try p.writeAll(o, block_close_tags[@intFromEnum(t)]);
    }
    fn closeP(p: *OctomarkParser, o: anytype) !void {
        const _s = p.startCall(.closeP);
        defer p.endCall(.closeP, _s);
        if (p.topT() == .paragraph) try p.renderTop(o);
    }
    fn tryCloseLeaf(p: *OctomarkParser, o: anytype) !void {
        const _s = p.startCall(.tryCloseLeaf);
        defer p.endCall(.tryCloseLeaf, _s);
        const t = p.topT() orelse return;
        if (t == .paragraph or @intFromEnum(t) >= @intFromEnum(BlockType.code)) {
            try p.renderTop(o);
        } else if (p.paragraph_content.items.len > 0) {
            try p.parseInlineContent(p.paragraph_content.items, o);
            p.paragraph_content.clearRetainingCapacity();
        }
    }
    fn currentListBufferIndex(p: *OctomarkParser) ?usize {
        const _s = p.startCall(.currentListBufferIndex);
        defer p.endCall(.currentListBufferIndex, _s);
        if (p.active_list_stack_idx >= 0) {
            const idx = p.block_stack[@intCast(p.active_list_stack_idx)].buffer_index;
            if (idx >= 0) return @intCast(idx);
        }
        return null;
    }
    fn currentListBuffer(p: *OctomarkParser) ?*ListBuffer {
        return if (p.currentListBufferIndex()) |idx| &p.list_buffers.items[idx] else null;
    }
    fn listItemStart(p: *OctomarkParser) void {
        const _s = p.startCall(.listItemStart);
        defer p.endCall(.listItemStart, _s);
        const idx = p.currentListBufferIndex() orelse return;
        var lb = &p.list_buffers.items[idx];
        lb.meta.append(p.allocator, .{
            .tag = .item,
            .start = lb.bytes.items.len,
        }) catch {};
        lb.last_item_idx = if (lb.meta.items.len > 0) lb.meta.items.len - 1 else null;
    }
    fn listItemEnd(p: *OctomarkParser) void {
        const _s = p.startCall(.listItemEnd);
        defer p.endCall(.listItemEnd, _s);
        const idx = p.currentListBufferIndex() orelse return;
        var lb = &p.list_buffers.items[idx];
        if (lb.last_item_idx) |item_idx| {
            var item = &lb.meta.items[item_idx];
            if (item.tag == .item and item.end == 0) item.end = lb.bytes.items.len;
        }
    }
    fn listItemMarkBlock(p: *OctomarkParser) void {
        const _s = p.startCall(.listItemMarkBlock);
        defer p.endCall(.listItemMarkBlock, _s);
        const idx = p.currentListBufferIndex() orelse return;
        var lb = &p.list_buffers.items[idx];
        if (lb.last_item_idx) |item_idx| {
            var item = &lb.meta.items[item_idx];
            if (item.tag == .item) item.flags |= ListMetaFlags.has_block;
        }
    }
    fn listItemMarkParagraph(p: *OctomarkParser) void {
        const _s = p.startCall(.listItemMarkParagraph);
        defer p.endCall(.listItemMarkParagraph, _s);
        const idx = p.currentListBufferIndex() orelse return;
        var lb = &p.list_buffers.items[idx];
        if (lb.last_item_idx) |item_idx| {
            var item = &lb.meta.items[item_idx];
            if (item.tag == .item) item.flags |= ListMetaFlags.has_p;
        }
    }
    fn listItemRecordParagraphSpan(p: *OctomarkParser, start: usize, end: usize) void {
        const _s = p.startCall(.listItemRecordParagraphSpan);
        defer p.endCall(.listItemRecordParagraphSpan, _s);
        const idx = p.currentListBufferIndex() orelse return;
        var lb = &p.list_buffers.items[idx];
        if (lb.last_item_idx == null or end <= start) return;
        lb.meta.append(p.allocator, .{
            .tag = .paragraph,
            .start = start,
            .end = end,
        }) catch {};
        lb.para_count += 1;
    }
    inline fn flushListParagraph(p: *OctomarkParser, o: anytype, wrap_paragraph: bool) !void {
        if (p.paragraph_content.items.len == 0) return;
        if (wrap_paragraph) {
            p.listItemMarkParagraph();
            try p.writeAll(o, "<p>");
            try p.parseInlineContent(p.paragraph_content.items, o);
            try p.writeAll(o, "</p>\n");
        } else {
            const start_pos = if (p.currentListBuffer()) |lb| lb.bytes.items.len else 0;
            try p.parseInlineContent(p.paragraph_content.items, o);
            if (p.currentListBuffer()) |lb| p.listItemRecordParagraphSpan(start_pos, lb.bytes.items.len);
        }
        p.paragraph_content.clearRetainingCapacity();
    }
    inline fn handleBlankLine(p: *OctomarkParser, o: anytype, suppress_after_idx: ?usize, close_containers: bool) !bool {
        const top_bt = p.topT();
        if (top_bt == .paragraph or top_bt == .table or top_bt == .code or top_bt == .math) try p.renderTop(o);
        const l_idx: ?usize = if (p.active_list_stack_idx >= 0) @intCast(p.active_list_stack_idx) else null;
        if (l_idx != null and p.paragraph_content.items.len > 0) {
            const list_loose = p.block_stack[l_idx.?].loose;
            try p.flushListParagraph(o, list_loose);
        }
        if (l_idx) |idx| {
            const suppress = if (suppress_after_idx) |bq_idx| bq_idx > idx else false;
            if (!suppress) p.pending_loose_idx = idx;
        }
        if (close_containers) {
            while (p.stack_depth > 0 and p.topT() != null and @intFromEnum(p.topT().?) >=
                @intFromEnum(BlockType.blockquote))
            {
                try p.renderTop(o);
            }
        }
        return false;
    }
    fn applyPendingLoose(p: *OctomarkParser, o: anytype) !void {
        const _s = p.startCall(.applyPendingLoose);
        defer p.endCall(.applyPendingLoose, _s);
        _ = o;
        if (p.pending_loose_idx) |idx| {
            if (idx < p.stack_depth) {
                p.block_stack[idx].loose = true;
            }
            p.pending_loose_idx = null;
        }
    }
    fn esc(p: *OctomarkParser, text: []const u8, o: anytype) !void {
        const _s = p.startCall(.esc);
        defer p.endCall(.esc, _s);
        var i: usize = 0;
        while (i < text.len) {
            if (std.mem.indexOfAny(u8, text[i..], "&<>\"'")) |off| {
                const j = i + off;
                if (j > i) try p.writeAll(o, text[i..j]);
                try p.writeAll(o, html_escape_map[text[j]].?);
                i = j + 1;
            } else {
                try p.writeAll(o, text[i..]);
                break;
            }
        }
    }
    fn stripBlockquotePrefixes(p: *const OctomarkParser, line: []const u8) struct { slice: []const u8, extra_indent_columns: usize, ok: bool } {
        var text_slice = line;
        var extra_indent_columns: usize = 0;
        var ok = true;
        var i: usize = 0;
        while (i < p.stack_depth) : (i += 1) {
            const block = p.block_stack[i];
            if (block.block_type == .blockquote) {
                var idx: usize = 0;
                var col: usize = 0;
                while (idx < text_slice.len) {
                    const c = text_slice[idx];
                    if (c == ' ') {
                        idx += 1;
                        col += 1;
                    } else if (c == '\t') {
                        idx += 1;
                        col += 4 - (col % 4);
                    } else break;
                }
                if (idx < text_slice.len and text_slice[idx] == '>') {
                    idx += 1;
                    col += 1;
                    if (idx < text_slice.len) {
                        const next = text_slice[idx];
                        if (next == ' ') {
                            idx += 1;
                            col += 1;
                        } else if (next == '\t') {
                            const tab_width = 4 - (col % 4);
                            idx += 1;
                            col += tab_width;
                            if (tab_width > 0) extra_indent_columns += tab_width - 1;
                        }
                    }
                    text_slice = text_slice[idx..];
                } else {
                    ok = false;
                    break;
                }
            }
        }
        return .{ .slice = text_slice, .extra_indent_columns = extra_indent_columns, .ok = ok };
    }
    fn isAsciiPunct(c: u32) bool {
        return (c >= 33 and c <= 47) or (c >= 58 and c <= 64) or (c >= 91 and c <= 96) or (c >= 123 and c <= 126);
    }
    fn isPunct(c: u32) bool {
        if (c < 128) return isAsciiPunct(c);
        var i: usize = 0;
        while (i < punct_symbol_ranges.len) : (i += 1) {
            const r = punct_symbol_ranges[i];
            if (c < r[0]) break;
            if (c <= r[1]) return true;
        }
        return false;
    }
    fn isWhitespace(c: u32) bool {
        if (c < 128) return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0B or c == 0x0C;
        return c == 0x85 or c == 0xA0 or c == 0x1680 or (c >= 0x2000 and c <= 0x200A) or c == 0x2028 or c == 0x2029 or
            c == 0x202F or c == 0x205F or c == 0x3000;
    }
    fn renderCodeSpanContent(p: *OctomarkParser, content: []const u8, o: anytype) !void {
        if (content.len == 0) return;
        var has_non_space = false;
        for (content) |c| if (!isWhitespace(c)) {
            has_non_space = true;
            break;
        };
        var start: usize = 0;
        var end: usize = content.len;
        // CommonMark 0.31.2: "First, line endings are converted to spaces."
        // "If the resulting string both begins and ends with a space character, but does not consist entirely of
        // space characters, a single space character is removed from the front and back."
        if (has_non_space and content.len >= 2) {
            const first = if (content[0] == '\n' or content[0] == '\r') @as(u8, ' ') else content[0];
            const last = if (content[content.len - 1] == '\n' or content[content.len - 1] == '\r')
                @as(u8, ' ')
            else
                content[content.len - 1];
            if (first == ' ' and last == ' ') {
                var all_spaces = true;
                for (content) |c| if (c != ' ' and c != '\n' and c != '\r') {
                    all_spaces = false;
                    break;
                };
                if (!all_spaces) {
                    start = 1;
                    end = content.len - 1;
                }
            }
        }
        var k = start;
        while (k < end) {
            const c = content[k];
            if (c == '\n' or c == '\r') {
                try p.writeByte(o, ' ');
                if (c == '\r' and k + 1 < end and content[k + 1] == '\n') k += 1;
            } else if (html_escape_map[c]) |e| {
                try p.writeAll(o, e);
            } else {
                try p.writeByte(o, c);
            }
            k += 1;
        }
    }
    fn findSpec(p: *OctomarkParser, text: []const u8, start: usize) usize {
        const s = p.startCall(.findSpec);
        defer p.endCall(.findSpec, s);
        return if (std.mem.indexOfAny(u8, text[start..], special_chars)) |off| start + off else text.len;
    }
    fn isSpaceOrNl(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }
    fn findLabelEnd(p: *OctomarkParser, text: []const u8, label_start: usize) ?usize {
        const _s = p.startCall(.findLabelEnd);
        defer p.endCall(.findLabelEnd, _s);
        var depth: usize = 1;
        var k = label_start;
        while (k < text.len) : (k += 1) {
            if (text[k] == '\\' and k + 1 < text.len) {
                k += 1;
                continue;
            }
            if (text[k] == '<') {
                if (parseAutolink(text, k)) |a| {
                    k = a.end - 1;
                    continue;
                }
                const l = p.parseHtmlTag(text[k..]);
                if (l > 0) {
                    k += l - 1;
                    continue;
                }
            }
            if (text[k] == '`') {
                var run_len: usize = 1;
                while (k + run_len < text.len and text[k + run_len] == '`') run_len += 1;
                if (OctomarkParser.findClosingBackticks(text, k + run_len, run_len)) |m_pos| {
                    k = m_pos + run_len - 1;
                    continue;
                }
                return null;
            }
            if (text[k] == ']') {
                depth -= 1;
                if (depth == 0) return k;
            } else if (text[k] == '[') {
                depth += 1;
            }
        }
        return null;
    }
    const LinkDest = struct { dest_start: usize, dest_end: usize, title_start: ?usize, title_end: ?usize, end: usize };
    fn parseLinkDestination(text: []const u8, start: usize) ?LinkDest {
        var i = start;
        while (i < text.len and isSpaceOrNl(text[i])) : (i += 1) {}
        if (i >= text.len) return null;
        const raw_start = i;
        var dest_start: usize = i;
        var dest_end: usize = i;
        var angle = false;
        if (text[i] == '<') {
            var j = i + 1;
            var ok = true;
            while (j < text.len) : (j += 1) {
                const ch = text[j];
                if (ch == '\\' and j + 1 < text.len and isAsciiPunct(text[j + 1])) {
                    j += 1;
                    continue;
                }
                if (ch == '>') {
                    dest_start = i + 1;
                    dest_end = j;
                    j += 1;
                    if (j < text.len and !isSpaceOrNl(text[j]) and text[j] != ')') ok = false else angle = true;
                    i = j;
                    break;
                }
                if (ch == '\n' or ch == '\r') {
                    ok = false;
                    break;
                }
            }
            if (!ok) angle = false;
        }
        if (!angle) {
            if (text[raw_start] == '<') return null;
            i = raw_start;
            dest_start = raw_start;
            var depth: usize = 0;
            while (i < text.len) {
                const ch = text[i];
                if (ch == '\\' and i + 1 < text.len and isAsciiPunct(text[i + 1])) {
                    i += 2;
                    continue;
                }
                if (ch == '(') {
                    depth += 1;
                    i += 1;
                    continue;
                }
                if (ch == ')') {
                    if (depth == 0) break;
                    depth -= 1;
                    i += 1;
                    continue;
                }
                if (isSpaceOrNl(ch)) break;
                i += 1;
            }
            dest_end = i;
        }
        var j = i;
        while (j < text.len and isSpaceOrNl(text[j])) : (j += 1) {}
        if (j < text.len and text[j] == ')') {
            return .{ .dest_start = dest_start, .dest_end = dest_end, .title_start = null, .title_end = null, .end = j + 1 };
        }
        if (j >= text.len) return null;
        const open = text[j];
        if (open != '"' and open != '\'' and open != '(') return null;
        const close: u8 = if (open == '(') ')' else open;
        j += 1;
        const title_start = j;
        var title_end: ?usize = null;
        while (j < text.len) : (j += 1) {
            const ch = text[j];
            if (ch == '\\' and j + 1 < text.len and isAsciiPunct(text[j + 1])) {
                j += 1;
                continue;
            }
            if (ch == close) {
                title_end = j;
                j += 1;
                break;
            }
        }
        if (title_end == null) return null;
        while (j < text.len and isSpaceOrNl(text[j])) : (j += 1) {}
        if (j < text.len and text[j] == ')') {
            return .{ .dest_start = dest_start, .dest_end = dest_end, .title_start = title_start, .title_end = title_end, .end = j + 1 };
        }
        return null;
    }
    const LinkMatch = struct { label_start: usize, label_end: usize, dest: LinkDest, is_image: bool };
    fn parseInlineLink(p: *OctomarkParser, text: []const u8, start: usize, is_image: bool) ?LinkMatch {
        const _s = p.startCall(.parseInlineLink);
        defer p.endCall(.parseInlineLink, _s);
        if (is_image) {
            if (start + 1 >= text.len or text[start + 1] != '[') return null;
        } else if (text[start] != '[') return null;
        const label_start = if (is_image) start + 2 else start + 1;
        const label_end = findLabelEnd(p, text, label_start) orelse return null;
        if (label_end + 1 >= text.len or text[label_end + 1] != '(') return null;
        const dest = parseLinkDestination(text, label_end + 2) orelse return null;
        return .{ .label_start = label_start, .label_end = label_end, .dest = dest, .is_image = is_image };
    }
    const Autolink = struct { end: usize, is_email: bool, content_start: usize, content_end: usize };
    fn parseAutolink(text: []const u8, start: usize) ?Autolink {
        if (start + 1 >= text.len or text[start] != '<') return null;
        if (std.mem.indexOfScalar(u8, text[start + 1 ..], '>')) |off| {
            const lc = text[start + 1 .. start + 1 + off];
            if (std.mem.indexOfAny(u8, lc, " \t\n") != null) return null;
            var al = false;
            var em_l = false;
            if (std.mem.indexOfScalar(u8, lc, ':')) |sc_i| {
                const sch = lc[0..sc_i];
                if (sch.len >= 2 and sch.len <= 32 and std.ascii.isAlphabetic(sch[0])) {
                    al = true;
                    for (sch[1..]) |sc| if (!std.ascii.isAlphanumeric(sc) and sc != '+' and sc != '.' and sc != '-') {
                        al = false;
                        break;
                    };
                }
            } else if (std.mem.indexOfScalar(u8, lc, '@')) |a| {
                if (a > 0 and a < lc.len - 1 and std.mem.indexOfScalar(u8, lc[a + 1 ..], '.') != null) {
                    al = true;
                    em_l = true;
                }
            }
            if (al and std.mem.indexOfAny(u8, lc, if (em_l) " \t\n\\" else " \t\n") != null) al = false;
            if (al) return .{ .end = start + off + 2, .is_email = em_l, .content_start = start + 1, .content_end = start + 1 + off };
        }
        return null;
    }
    fn labelHasLinkLike(p: *OctomarkParser, text: []const u8) bool {
        const _s = p.startCall(.labelHasLinkLike);
        defer p.endCall(.labelHasLinkLike, _s);
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            if (c == '\\' and i + 1 < text.len) {
                i += 2;
                continue;
            }
            if (c == '`') {
                var run_len: usize = 1;
                while (i + run_len < text.len and text[i + run_len] == '`') run_len += 1;
                if (OctomarkParser.findClosingBackticks(text, i + run_len, run_len)) |m_pos| {
                    i = m_pos + run_len;
                    continue;
                }
            }
            if (c == '<') {
                if (parseAutolink(text, i) != null) return true;
            } else if (c == '!') {
                if (parseInlineLink(p, text, i, true)) |m| {
                    i = m.dest.end;
                    continue;
                }
            } else if (c == '[') {
                if (parseInlineLink(p, text, i, false) != null) return true;
            }
            i += 1;
        }
        return false;
    }
    fn decodeEntity(text: []const u8, out_buf: *[8]u8) struct { consumed: usize, len: usize } {
        if (text.len < 2 or text[0] != '&') return .{ .consumed = 0, .len = 0 };
        var j: usize = 1;
        var decoded_len: usize = 0;
        if (j < text.len and text[j] == '#') {
            j += 1;
            const b: u8 = if (j < text.len and (text[j] | 32) == 'x') blk: {
                j += 1;
                break :blk 16;
            } else 10;
            const cp_s = j;
            while (j < text.len and (if (b == 10) std.ascii.isDigit(text[j]) else std.ascii.isHex(text[j]))) : (j += 1) {}
            if (j > cp_s and j < text.len and text[j] == ';') {
                var cp = std.fmt.parseInt(u32, text[cp_s..j], b) catch 0;
                if (cp == 0) cp = 0xFFFD;
                if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) {
                    j = 1;
                } else {
                    decoded_len = std.unicode.utf8Encode(@intCast(cp), out_buf[0..4]) catch 0;
                    if (decoded_len > 0) j += 1 else j = 1; // Success implies consume ;
                }
            } else j = 1;
        } else {
            while (j < text.len and std.ascii.isAlphanumeric(text[j])) : (j += 1) {}
            if (j > 1 and j < text.len and text[j] == ';') {
                const en = text[1..j];
                const d: ?[]const u8 = switch (en.len) {
                    2 => if (std.mem.eql(u8, en, "lt")) "<" else if (std.mem.eql(u8, en, "gt")) ">" else null,
                    3 => if (std.mem.eql(u8, en, "amp")) "&" else if (std.mem.eql(u8, en, "ngE")) "≧̸" else null,
                    4 => if (std.mem.eql(u8, en, "quot")) "\"" else if (std.mem.eql(u8, en, "apos")) "'" else if (std.mem.eql(u8, en, "copy")) "©" else if (std.mem.eql(u8, en, "nbsp")) "\u{00A0}" else if (std.mem.eql(u8, en, "ouml")) "\u{00F6}" else if (std.mem.eql(u8, en, "auml"))
                        "\u{00E4}"
                    else
                        null,
                    5 => if (std.mem.eql(u8, en, "ndash")) "–" else if (std.mem.eql(u8, en, "mdash")) "—" else if (std.mem.eql(u8, en, "AElig")) "\u{00C6}" else null,
                    6 => if (std.mem.eql(u8, en, "Dcaron")) "\u{010E}" else if (std.mem.eql(u8, en, "frac34"))
                        "\u{00BE}"
                    else
                        null,
                    12 => if (std.mem.eql(u8, en, "HilbertSpace")) "\u{210B}" else null,
                    13 => if (std.mem.eql(u8, en, "DifferentialD")) "\u{2146}" else null,
                    24 => if (std.mem.eql(u8, en, "ClockwiseContourIntegral")) "\u{2232}" else null,
                    else => null,
                };
                if (d) |v| {
                    if (v.len <= out_buf.len) {
                        @memcpy(out_buf[0..v.len], v);
                        decoded_len = v.len;
                        j += 1;
                    } else j = 1;
                } else j = 1;
            } else j = 1;
        }
        if (decoded_len == 0) return .{ .consumed = 0, .len = 0 };
        return .{ .consumed = j, .len = decoded_len };
    }
    fn needsPercentEncode(c: u8) bool {
        if (std.ascii.isAlphanumeric(c)) return false;
        return switch (c) {
            '-', '.', '_', '~', '!', '$', '\'', '(', ')', '*', '+', ',', ';', '=', ':', '@', '/', '?', '#' => false,
            else => true,
        };
    }
    pub fn parseInlineContent(p: *OctomarkParser, text: []const u8, o: anytype) !void {
        p.replacements.clearRetainingCapacity();
        try p.scanInline(text, 0);
        std.sort.block(Replacement, p.replacements.items, {}, struct {
            fn less(_: void, a: Replacement, b: Replacement) bool {
                return a.pos < b.pos;
            }
        }.less);
        try p.parseInlineContentDepth(text, o, 0, 0, false);
    }
    fn parseInlineContentScoped(p: *OctomarkParser, text: []const u8, o: anytype, depth: usize, plain: bool) anyerror!void {
        const _s = p.startCall(.parseInlineContentScoped);
        defer p.endCall(.parseInlineContentScoped, _s);
        if (depth > MAX_INLINE_NESTING) {
            try p.writeAll(o, text);
            return;
        }
        const saved_reps = p.replacements;
        const saved_delim_len = p.delimiter_stack_len;

        p.replacements = .{};
        p.delimiter_stack_len = 0;
        defer {
            p.replacements.deinit(p.allocator);
            p.replacements = saved_reps;
            p.delimiter_stack_len = saved_delim_len;
        }

        try p.scanInline(text, 0);
        std.sort.block(Replacement, p.replacements.items, {}, struct {
            fn less(_: void, a: Replacement, b: Replacement) bool {
                return a.pos < b.pos;
            }
        }.less);
        try p.renderInline(text, p.replacements.items, o, depth, 0, plain);
    }
    fn parseInlineContentDepth(p: *OctomarkParser, text: []const u8, o: anytype, depth: usize, g_off: usize, plain: bool) anyerror!void {
        const _s = p.startCall(.parseInlineContent);
        defer p.endCall(.parseInlineContent, _s);
        if (depth > MAX_INLINE_NESTING) {
            try p.writeAll(o, text);
            return;
        }
        try p.renderInline(text, p.replacements.items, o, depth, g_off, plain);
    }
    fn findClosingBackticks(text: []const u8, start: usize, count: usize) ?usize {
        var i = start;
        while (i < text.len) {
            const off = std.mem.indexOfScalar(u8, text[i..], '`') orelse return null;
            i += off;
            var run_len: usize = 0;
            while (i + run_len < text.len and text[i + run_len] == '`') : (run_len += 1) {}
            if (run_len == count) return i;
            i += run_len;
        }
        return null;
    }
    fn scanDelims(p: *OctomarkParser, text: []const u8, start_pos: usize, char: u8, bottom: usize) !usize {
        const s = p.startCall(.scanDelimiters);
        defer p.endCall(.scanDelimiters, s);
        var num: usize = 0;
        var i = start_pos;
        while (i < text.len and text[i] == char) : (i += 1) num += 1;
        if (num == 0) return start_pos;
        var b: u32 = '\n';
        if (start_pos > 0) {
            var bi = start_pos - 1;
            while (bi > 0 and (text[bi] & 0xC0 == 0x80)) bi -= 1;
            b = std.unicode.utf8Decode(text[bi..start_pos]) catch text[start_pos - 1];
        }
        var a: u32 = '\n';
        if (i < text.len) {
            const al = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            if (i + al <= text.len) a = std.unicode.utf8Decode(text[i .. i + al]) catch text[i];
        }
        const w_a = isWhitespace(a);
        const w_b = isWhitespace(b);
        const p_a = isPunct(a);
        const p_b = isPunct(b);
        const was_open = !w_a and (!p_a or w_b or p_b);
        const was_close = !w_b and (!p_b or w_a or p_a);
        var open = was_open;
        var close = was_close;
        if (char == '_') {
            open = was_open and (!was_close or p_b);
            close = was_close and (!was_open or p_a);
        }
        var processed: usize = 0;
        if (close) {
            var idx = p.delimiter_stack_len;
            while (idx > bottom) {
                idx -= 1;
                var opener = &p.delimiter_stack[idx];
                if (opener.char == char and opener.active and opener.can_open) {
                    while (num > 0 and opener.count > 0) {
                        if (char != '~' and (opener.can_close or open) and (opener.count + num) % 3 == 0 and
                            (opener.count % 3 != 0 or num % 3 != 0)) break;
                        const use: usize = if (char == '~')
                            (if (num >= 2 and opener.count >= 2) @as(usize, 2) else 0)
                        else if (num >= 2 and opener.count >= 2) @as(usize, 2) else 1;
                        if (use == 0) break;
                        const t_o = if (char == '~') "<del>" else (if (use == 2) "<strong>" else "<em>");
                        const t_c = if (char == '~') "</del>" else (if (use == 2) "</strong>" else "</em>");
                        try p.replacements.append(p.allocator, .{ .pos = opener.pos + opener.count - use, .end = opener.pos + opener.count, .text = t_o });
                        const closer_pos = start_pos + processed;
                        processed += use;
                        try p.replacements.append(p.allocator, .{ .pos = closer_pos, .end = closer_pos + use, .text = t_c });
                        var di = idx + 1;
                        while (di < p.delimiter_stack_len) : (di += 1) {
                            p.delimiter_stack[di].active = false;
                        }
                        opener.count -= use;
                        num -= use;
                        if (num == 0) break;
                    }
                    if (opener.count == 0) {
                        if (idx < p.delimiter_stack_len - 1) std.mem.copyForwards(Delimiter, p.delimiter_stack[idx .. p.delimiter_stack_len - 1], p.delimiter_stack[idx + 1 .. p.delimiter_stack_len]);
                        p.delimiter_stack_len -= 1;
                    }
                    if (num == 0) break;
                }
            }
        }
        if (open and num > 0 and p.delimiter_stack_len < MAX_INLINE_NESTING) {
            p.delimiter_stack[p.delimiter_stack_len] = .{ .pos = start_pos + processed, .content_end = i, .char = char, .count = num, .can_open = open, .can_close = close, .active = true };
            p.delimiter_stack_len += 1;
        }
        return i;
    }
    fn scanInline(p: *OctomarkParser, text: []const u8, bottom: usize) !void {
        const s = p.startCall(.scanInline);
        defer p.endCall(.scanInline, s);
        var i: usize = 0;
        while (i < text.len) {
            const off = std.mem.indexOfAny(u8, text[i..], "*_`~<\\[!") orelse break;
            i += off;
            switch (text[i]) {
                '*', '_', '~' => i = try p.scanDelims(text, i, text[i], bottom),
                '`' => {
                    var cnt: usize = 1;
                    while (i + cnt < text.len and text[i + cnt] == '`') cnt += 1;
                    if (OctomarkParser.findClosingBackticks(text, i + cnt, cnt)) |m_pos| {
                        i = m_pos + cnt;
                    } else {
                        i += cnt;
                    }
                },
                '<' => {
                    if (parseAutolink(text, i)) |a| {
                        i = a.end;
                    } else {
                        const l = p.parseHtmlTag(text[i..]);
                        i += if (l > 0) l else 1;
                    }
                },
                '[', '!' => {
                    if (parseInlineLink(p, text, i, text[i] == '!')) |m| {
                        const label = text[m.label_start..m.label_end];
                        if (!m.is_image and labelHasLinkLike(p, label)) {
                            i += 1;
                        } else {
                            i = m.dest.end;
                        }
                    } else {
                        i += 1;
                    }
                },
                '\\' => i += if (i + 1 < text.len and isAsciiPunct(text[i + 1])) 2 else 1,
                else => i += 1,
            }
        }
    }
    fn renderInline(p: *OctomarkParser, text: []const u8, reps: []const Replacement, o: anytype, depth: usize, g_off: usize, plain: bool) !void {
        const s = p.startCall(.renderInline);
        defer p.endCall(.renderInline, s);
        var i: usize = 0;
        var r_idx: usize = 0;
        while (i < text.len) {
            while (r_idx < reps.len and reps[r_idx].pos < g_off + i) r_idx += 1;
            if (r_idx < reps.len and reps[r_idx].pos == g_off + i) {
                const rep = reps[r_idx];
                if (!plain) try p.writeAll(o, rep.text);
                i += rep.end - rep.pos;
                r_idx += 1;
                continue;
            }
            const next_rep = if (r_idx < reps.len) reps[r_idx].pos else text.len;
            var next = p.findSpec(text, i);
            if (next > next_rep) next = next_rep;
            if (next < text.len and text[next] == '\n' and next < next_rep) {
                var t_end = next;
                if (!plain) {
                    while (t_end > i and text[t_end - 1] == ' ') t_end -= 1;
                    if (t_end > i) try p.writeAll(o, text[i..t_end]);
                    try p.writeAll(o, if (next - t_end >= 2) "<br>\n" else "\n");
                } else if (t_end > i) try p.writeAll(o, text[i..t_end]);
                i = next + 1;
                continue;
            }
            if (next > i) {
                var t_end = next;
                if (next == text.len) while (t_end > i and text[t_end - 1] == ' ') {
                    t_end -= 1;
                };
                if (t_end > i) try p.writeAll(o, text[i..t_end]);
                i = next;
                continue;
            }
            const c = text[i];
            var h = false;
            var em = false;
            var ec: u8 = 0;
            switch (c) {
                '\\' => {
                    if (i + 1 < text.len) {
                        const n = text[i + 1];
                        if (n == '\n' or n == '\r') {
                            try p.writeAll(o, "<br>\n");
                            if (n == '\r' and i + 2 < text.len and text[i + 2] == '\n') {
                                i += 3;
                            } else {
                                i += 2;
                            }
                        } else if (isAsciiPunct(n)) {
                            em = true;
                            ec = n;
                            i += 2;
                        } else {
                            em = true;
                            ec = '\\';
                            i += 1;
                        }
                    } else {
                        em = true;
                        ec = '\\';
                        i += 1;
                    }
                    h = true;
                },
                '~' => if (std.mem.startsWith(u8, text[i..], "~~")) {
                    i += 2;
                    h = true;
                },
                '`' => {
                    var cnt: usize = 1;
                    while (i + cnt < text.len and text[i + cnt] == '`') cnt += 1;
                    if (OctomarkParser.findClosingBackticks(text, i + cnt, cnt)) |m_pos| {
                        const content = text[i + cnt .. m_pos];
                        if (!plain) try p.writeAll(o, "<code>");
                        try p.renderCodeSpanContent(content, o);
                        if (!plain) try p.writeAll(o, "</code>");
                        i = m_pos + cnt;
                        h = true;
                    } else {
                        if (html_escape_map['`']) |e| {
                            var k: usize = 0;
                            while (k < cnt) : (k += 1) try p.writeAll(o, e);
                        } else {
                            var k: usize = 0;
                            while (k < cnt) : (k += 1) try p.writeByte(o, '`');
                        }
                        i += cnt;
                        h = true;
                    }
                },
                '[', '!' => {
                    const img = (c == '!');
                    if (!img or (i + 1 < text.len and text[i + 1] == '[')) {
                        if (parseInlineLink(p, text, i, img)) |m| {
                            const label = text[m.label_start..m.label_end];
                            if (img or !labelHasLinkLike(p, label)) {
                                if (plain) {
                                    try p.parseInlineContentScoped(label, o, depth + 1, true);
                                } else {
                                    const url = text[m.dest.dest_start..m.dest.dest_end];
                                    const tit = if (m.dest.title_start) |ts| text[ts..m.dest.title_end.?] else null;
                                    try p.writeAll(o, if (img) "<img src=\"" else "<a href=\"");
                                    var u: usize = 0;
                                    while (u < url.len) {
                                        if (url[u] == '&') {
                                            var db: [8]u8 = undefined;
                                            const dr = decodeEntity(url[u..], &db);
                                            if (dr.len > 0) {
                                                for (db[0..dr.len]) |b| {
                                                    if (needsPercentEncode(b)) {
                                                        try p.writeByte(o, '%');
                                                        try p.writeHex(o, b);
                                                    } else if (html_escape_map[b]) |e| {
                                                        try p.writeAll(o, e);
                                                    } else try p.writeByte(o, b);
                                                }
                                                u += dr.consumed;
                                                continue;
                                            }
                                        }
                                        var ch = url[u];
                                        if (ch == '\\' and u + 1 < url.len and isAsciiPunct(url[u + 1])) {
                                            u += 1;
                                            ch = url[u];
                                        }
                                        if (needsPercentEncode(ch)) {
                                            if (ch == '%') {
                                                if (u + 2 < url.len and std.ascii.isHex(url[u + 1]) and
                                                    std.ascii.isHex(url[u + 2]))
                                                {
                                                    try p.writeByte(o, ch);
                                                } else try p.writeAll(o, "%25");
                                            } else {
                                                try p.writeByte(o, '%');
                                                try p.writeHex(o, ch);
                                            }
                                        } else if (html_escape_map[ch]) |e| {
                                            try p.writeAll(o, e);
                                        } else try p.writeByte(o, ch);
                                        u += 1;
                                    }
                                    try p.writeByte(o, '"');
                                    if (tit) |t| {
                                        try p.writeAll(o, " title=\"");
                                        var ti: usize = 0;
                                        while (ti < t.len) {
                                            if (t[ti] == '&') {
                                                var db: [8]u8 = undefined;
                                                const dr = decodeEntity(t[ti..], &db);
                                                if (dr.len > 0) {
                                                    try p.esc(db[0..dr.len], o);
                                                    ti += dr.consumed;
                                                    continue;
                                                }
                                            }
                                            if (t[ti] == '\\' and ti + 1 < t.len and isAsciiPunct(t[ti + 1])) {
                                                ti += 1;
                                            }
                                            if (html_escape_map[t[ti]]) |e| try p.writeAll(o, e) else try p.writeByte(o, t[ti]);
                                            ti += 1;
                                        }
                                        try p.writeByte(o, '"');
                                    }
                                    if (img) {
                                        try p.writeAll(o, " alt=\"");
                                        try p.parseInlineContentScoped(label, o, depth + 1, true);
                                        try p.writeAll(o, "\">");
                                    } else {
                                        try p.writeAll(o, ">");
                                        try p.parseInlineContentScoped(label, o, depth + 1, false);
                                        try p.writeAll(o, "</a>");
                                    }
                                }
                                i = m.dest.end;
                                h = true;
                            }
                        }
                    }
                },
                '<' => {
                    if (parseAutolink(text, i)) |a| {
                        const lc = text[a.content_start..a.content_end];
                        if (!plain) {
                            try p.writeAll(o, "<a href=\"");
                            if (a.is_email) try p.writeAll(o, "mailto:");
                            for (lc) |ch| {
                                if (ch == '\\') {
                                    try p.writeAll(o, "%5C");
                                } else if (ch == '&') {
                                    try p.writeAll(o, "&amp;");
                                } else if (needsPercentEncode(ch)) {
                                    if (ch == '%') {
                                        try p.writeAll(o, "%25");
                                    } else {
                                        try p.writeByte(o, '%');
                                        try p.writeHex(o, ch);
                                    }
                                } else if (html_escape_map[ch]) |e| {
                                    try p.writeAll(o, e);
                                } else {
                                    try p.writeByte(o, ch);
                                }
                            }
                            try p.writeAll(o, "\">");
                        }
                        try p.esc(lc, o);
                        if (!plain) try p.writeAll(o, "</a>");
                        i = a.end;
                        h = true;
                    }
                    if (!h and p.options.enable_html) {
                        const l = p.parseHtmlTag(text[i..]);
                        if (l > 0) {
                            if (!plain) try p.writeAll(o, text[i .. i + l]);
                            i += l;
                            h = true;
                        }
                    }
                },
                '$' => {
                    var m_e: ?usize = null;
                    var k = i + 1;
                    while (k < text.len) : (k += 1) {
                        if (text[k] == '\\' and k + 1 < text.len) {
                            k += 1;
                            continue;
                        }
                        if (text[k] == '$') {
                            m_e = k;
                            break;
                        }
                    }
                    if (m_e) |j| {
                        if (!plain) try p.writeAll(o, "<span class=\"math\">");
                        try p.esc(text[i + 1 .. j], o);
                        if (!plain) try p.writeAll(o, "</span>");
                        i = j + 1;
                        h = true;
                    }
                },
                '&' => {
                    var db: [8]u8 = undefined;
                    const dr = decodeEntity(text[i..], &db);
                    if (dr.len > 0) {
                        try p.esc(db[0..dr.len], o);
                        i += dr.consumed;
                        h = true;
                    } else {
                        try p.writeAll(o, "&amp;");
                        i += 1;
                        h = true;
                    }
                },
                '>', '"', '\'' => {
                    try p.writeAll(o, html_escape_map[c].?);
                    i += 1;
                    h = true;
                },
                else => {},
            }
            if (!h) {
                em = true;
                ec = text[i];
                i += 1;
            }
            if (em) if (html_escape_map[ec]) |e| try p.writeAll(o, e) else try p.writeByte(o, ec);
        }
    }
    fn parseIndentedCodeBlock(parser: *OctomarkParser, line_content: []const u8, leading_spaces: usize, output: anytype) !bool {
        const _s = parser.startCall(.parseIndentedCodeBlock);
        defer parser.endCall(.parseIndentedCodeBlock, _s);
        const bt = parser.topT();
        var list_indent: ?i32 = null;
        var idx = parser.stack_depth;
        while (idx > 0) {
            idx -= 1;
            const entry = parser.block_stack[idx];
            if (entry.block_type == .unordered_list or entry.block_type == .ordered_list) {
                list_indent = entry.content_indent;
                break;
            }
        }
        const required_indent: usize = if (list_indent) |indent| @intCast(indent + 4) else 4;
        if (leading_spaces >= required_indent and bt != .paragraph and bt != .table and bt != .code and bt != .math and
            bt != .indented_code)
        {
            try parser.closeP(output);
            try parser.pushBlock(.indented_code, 0);
            parser.pending_code_blank_lines.clearRetainingCapacity();
            try parser.writeAll(output, "<pre><code>");
            const extra_spaces = leading_spaces - required_indent;
            var pad: usize = 0;
            while (pad < extra_spaces) : (pad += 1) {
                try parser.writeByte(output, ' ');
            }
            try parser.esc(line_content, output);
            try parser.writeByte(output, '\n');
            return true;
        }
        return false;
    }
    fn processLeafBlockContinuation(parser: *OctomarkParser, line: []const u8, output: anytype) !bool {
        const _s = parser.startCall(.processLeafBlockContinuation);
        defer parser.endCall(.processLeafBlockContinuation, _s);
        const top = parser.topT() orelse return false;
        if (top == .html_block) {
            const h_type = parser.block_stack[parser.stack_depth - 1].extra_type;
            const stripped = parser.stripBlockquotePrefixes(line);
            if (!stripped.ok) return false;
            var text_slice = stripped.slice;
            var list_indent: ?usize = null;
            if (parser.stack_depth > 0) {
                var li = parser.stack_depth;
                while (li > 0) {
                    li -= 1;
                    const bt = parser.block_stack[li].block_type;
                    if (bt == .unordered_list or bt == .ordered_list) {
                        list_indent = @intCast(parser.block_stack[li].content_indent);
                        break;
                    }
                }
            }
            if (list_indent) |li| {
                const ind = leadingIndent(text_slice);
                if (ind.columns < li) {
                    try parser.renderTop(output);
                    return false;
                }
                text_slice = stripIndentColumns(text_slice, li);
            }
            if (h_type >= 6) {
                if (std.mem.trim(u8, text_slice, " \t").len == 0) {
                    try parser.renderTop(output);
                    return false;
                }
            }
            var pad: usize = 0;
            while (pad < stripped.extra_indent_columns) : (pad += 1) {
                try parser.writeByte(output, ' ');
            }
            try parser.writeAll(output, text_slice);
            try parser.writeByte(output, '\n');
            if (h_type <= 5) {
                var term = false;
                if (h_type == 1) {
                    const tags = [_][]const u8{ "</script>", "</pre>", "</style>", "</textarea>" };
                    var i: usize = 0;
                    while (i < text_slice.len) : (i += 1) {
                        if (text_slice[i] == '<' and i + 1 < text_slice.len and text_slice[i + 1] == '/') {
                            for (tags) |tag| {
                                if (i + tag.len <= text_slice.len) {
                                    if (std.ascii.eqlIgnoreCase(text_slice[i .. i + tag.len], tag)) {
                                        term = true;
                                        break;
                                    }
                                }
                            }
                        }
                        if (term) break;
                    }
                } else if (h_type == 2) {
                    if (std.mem.indexOf(u8, text_slice, "-->") != null) term = true;
                } else if (h_type == 3) {
                    if (std.mem.indexOf(u8, text_slice, "?>") != null) term = true;
                } else if (h_type == 4) {
                    if (std.mem.indexOf(u8, text_slice, ">") != null) term = true;
                } else if (h_type == 5) {
                    if (std.mem.indexOf(u8, text_slice, "]]>") != null) term = true;
                }
                if (term) try parser.renderTop(output);
            }
            return true;
        }
        if (top != .code and top != .math and top != .indented_code) return false;
        const stripped = parser.stripBlockquotePrefixes(line);
        if (!stripped.ok) return false;
        var text_slice = stripped.slice;
        const extra_indent_columns: usize = stripped.extra_indent_columns;
        var prefix_spaces: usize = 0;
        const trimmed = std.mem.trimLeft(u8, text_slice, &std.ascii.whitespace);
        if (top == .code) {
            var fence_slice = text_slice;
            var list_indent: ?usize = null;
            if (parser.stack_depth > 0) {
                var li = parser.stack_depth;
                while (li > 0) {
                    li -= 1;
                    const bt = parser.block_stack[li].block_type;
                    if (bt == .unordered_list or bt == .ordered_list) {
                        list_indent = @intCast(parser.block_stack[li].content_indent);
                        break;
                    }
                }
            }
            if (list_indent) |li| {
                const ind = leadingIndent(fence_slice);
                if (ind.columns >= li) {
                    fence_slice = stripIndentColumns(fence_slice, li);
                }
            }
            const indent = leadingIndent(fence_slice);
            const trimmed_fence = fence_slice[indent.idx..];
            const entry = parser.block_stack[parser.stack_depth - 1];
            if (indent.columns <= 3 and trimmed_fence.len >= entry.fence_count) {
                var k: usize = 0;
                while (k < trimmed_fence.len and trimmed_fence[k] == entry.fence_char) : (k += 1) {}
                if (k >= entry.fence_count) {
                    var j = k;
                    while (j < trimmed_fence.len and (trimmed_fence[j] == ' ' or trimmed_fence[j] == '\t')) : (j += 1) {}
                    if (j == trimmed_fence.len) {
                        try parser.renderTop(output);
                        return true;
                    }
                }
            }
            text_slice = fence_slice;
        } else if (top == .math) {
            if (trimmed.len >= 2 and std.mem.eql(u8, trimmed[0..2], "$$")) {
                try parser.renderTop(output);
                return true;
            }
        } else if (top == .indented_code) {
            const indent = leadingIndent(text_slice);
            const spaces = indent.columns + extra_indent_columns;
            const is_blank = (indent.idx == text_slice.len);
            var list_indent: ?i32 = null;
            var idx = parser.stack_depth;
            while (idx > 0) {
                idx -= 1;
                const entry = parser.block_stack[idx];
                if (entry.block_type == .unordered_list or entry.block_type == .ordered_list) {
                    list_indent = entry.content_indent;
                    break;
                }
            }
            const required_indent: usize = if (list_indent) |li| @intCast(li + 4) else 4;
            if (is_blank) {
                const extra = if (spaces > required_indent) spaces - required_indent else 0;
                try parser.pending_code_blank_lines.append(parser.allocator, extra);
                return true;
            }
            if (spaces < required_indent) {
                parser.pending_code_blank_lines.clearRetainingCapacity();
                try parser.renderTop(output);
                return false;
            }
            if (parser.pending_code_blank_lines.items.len > 0) {
                for (parser.pending_code_blank_lines.items) |extra| {
                    var pad: usize = 0;
                    while (pad < extra) : (pad += 1) {
                        try parser.writeByte(output, ' ');
                    }
                    try parser.writeByte(output, '\n');
                }
                parser.pending_code_blank_lines.clearRetainingCapacity();
            }
            prefix_spaces = spaces - required_indent;
            text_slice = text_slice[indent.idx..];
        }
        if (parser.stack_depth > 0) {
            const indent = parser.block_stack[parser.stack_depth - 1].indent_level;
            if (indent > 0 and text_slice.len > 0) {
                const indent_usize: usize = @intCast(indent);
                text_slice = stripIndentColumns(text_slice, indent_usize);
            }
        }
        var pad: usize = 0;
        while (pad < prefix_spaces) : (pad += 1) {
            try parser.writeByte(output, ' ');
        }
        try parser.esc(text_slice, output);
        try parser.writeByte(output, '\n');
        return true;
    }
    fn parseFencedCodeBlock(parser: *OctomarkParser, line_content: []const u8, leading_spaces: usize, output: anytype) !bool {
        const _s = parser.startCall(.parseFencedCodeBlock);
        defer parser.endCall(.parseFencedCodeBlock, _s);
        if (leading_spaces > 3) return false;
        const content = std.mem.trimLeft(u8, line_content, " \t");
        const extra_spaces = line_content.len - content.len;
        if (content.len >= 3 and (content[0] == '`' or content[0] == '~')) {
            const f_char = content[0];
            var f_count: usize = 0;
            while (f_count < content.len and content[f_count] == f_char) : (f_count += 1) {}
            if (f_count < 3) return false;
            if (f_char == '`' and std.mem.indexOfScalar(u8, content[f_count..], '`') != null) return false;
            const block_type = parser.topT();
            if (block_type == .paragraph) {
                try parser.renderTop(output);
            } else if (parser.paragraph_content.items.len > 0) {
                try parser.parseInlineContent(parser.paragraph_content.items, output);
                parser.paragraph_content.clearRetainingCapacity();
            }
            if (block_type == .table or block_type == .code or block_type == .math) {
                try parser.renderTop(output);
            }
            try parser.writeAll(output, "<pre><code");
            var info_start = f_count;
            while (info_start < content.len and (content[info_start] == ' ' or content[info_start] == '\t')) : (info_start += 1) {}
            var info_end = info_start;
            while (info_end < content.len and !isWhitespace(content[info_end])) {
                if (content[info_end] == '\\' and info_end + 1 < content.len and isAsciiPunct(content[info_end + 1])) {
                    info_end += 2;
                } else {
                    info_end += 1;
                }
            }
            if (info_end > info_start) {
                try parser.writeAll(output, " class=\"language-");
                var k = info_start;
                while (k < info_end) {
                    if (content[k] == '&') {
                        var db: [8]u8 = undefined;
                        const dr = decodeEntity(content[k..], &db);
                        if (dr.len > 0) {
                            try parser.esc(db[0..dr.len], output);
                            k += dr.consumed;
                            continue;
                        }
                    }
                    if (content[k] == '\\' and k + 1 < info_end and isAsciiPunct(content[k + 1])) {
                        k += 1;
                        try parser.writeByte(output, content[k]);
                    } else if (html_escape_map[content[k]]) |e| {
                        try parser.writeAll(output, e);
                    } else {
                        try parser.writeByte(output, content[k]);
                    }
                    k += 1;
                }
                try parser.writeAll(output, "\"");
            }
            try parser.writeAll(output, ">");
            try parser.pushBlock(.code, @intCast(leading_spaces + extra_spaces));
            parser.block_stack[parser.stack_depth - 1].fence_char = f_char;
            parser.block_stack[parser.stack_depth - 1].fence_count = @intCast(f_count);
            return true;
        }
        return false;
    }
    fn parseMathBlock(parser: *OctomarkParser, line_content: []const u8, leading_spaces: usize, output: anytype) !bool {
        const _s = parser.startCall(.parseMathBlock);
        defer parser.endCall(.parseMathBlock, _s);
        const content = std.mem.trimLeft(u8, line_content, " ");
        const extra_spaces = line_content.len - content.len;
        if (content.len >= 2 and std.mem.eql(u8, content[0..2], "$$")) {
            const block_type = parser.topT();
            if (block_type == .paragraph or block_type == .table or block_type == .code or block_type == .math) {
                try parser.renderTop(output);
            }
            try parser.writeAll(output, "<div class=\"math\">\n");
            try parser.pushBlock(.math, @intCast(leading_spaces + extra_spaces));
            const remainder = content[2..];
            const trimmed_rem = std.mem.trim(u8, remainder, " \t");
            if (trimmed_rem.len > 0) {
                if (trimmed_rem.len >= 2 and std.mem.eql(u8, trimmed_rem[trimmed_rem.len - 2 ..], "$$")) {
                    const math_content = std.mem.trim(u8, trimmed_rem[0 .. trimmed_rem.len - 2], " \t");
                    try parser.esc(math_content, output);
                    try parser.writeByte(output, '\n');
                    try parser.renderTop(output);
                } else {
                    try parser.esc(remainder, output);
                    try parser.writeByte(output, '\n');
                }
            }
            return true;
        }
        return false;
    }
    fn parseHeader(parser: *OctomarkParser, line_content: []const u8, leading_spaces: usize, output: anytype) !bool {
        const _s = parser.startCall(.parseHeader);
        defer parser.endCall(.parseHeader, _s);
        if (leading_spaces > 3) return false;
        if (line_content.len >= 1 and line_content[0] == '#') {
            var level: usize = 0;
            while (level < 6 and level < line_content.len and line_content[level] == '#') : (level += 1) {}
            if (level == 0 or level > 6) return false;
            if (level < line_content.len and line_content[level] != ' ' and line_content[level] != '\t') return false;
            var content_start: usize = level;
            while (content_start < line_content.len and (line_content[content_start] == ' ' or
                line_content[content_start] == '\t')) : (content_start += 1)
            {}
            var end = line_content.len;
            while (end > content_start and (line_content[end - 1] == ' ' or line_content[end - 1] == '\t')) : (end -= 1) {}
            if (end > content_start) {
                var hash_end = end;
                while (hash_end > content_start and line_content[hash_end - 1] == '#') : (hash_end -= 1) {}
                if (hash_end < end) {
                    if (hash_end == content_start) end = content_start;
                    var space_end = hash_end;
                    while (space_end > content_start and (line_content[space_end - 1] == ' ' or
                        line_content[space_end - 1] == '\t')) : (space_end -= 1)
                    {}
                    if (space_end < hash_end) end = space_end;
                }
            }
            try parser.tryCloseLeaf(output);
            parser.listItemMarkBlock();
            const level_char: u8 = '0' + @as(u8, @intCast(level));
            try parser.writeAll(output, "<h");
            try parser.writeByte(output, level_char);
            try parser.writeAll(output, ">");
            try parser.parseInlineContent(line_content[content_start..end], output);
            try parser.writeAll(output, "</h");
            try parser.writeByte(output, level_char);
            try parser.writeAll(output, ">\n");
            return true;
        }
        return false;
    }
    fn parseHorizontalRule(parser: *OctomarkParser, line_content: []const u8, leading_spaces: usize, output: anytype) !bool {
        const _s = parser.startCall(.parseHorizontalRule);
        defer parser.endCall(.parseHorizontalRule, _s);
        if (leading_spaces <= 3 and isThematicBreakLine(line_content)) {
            try parser.tryCloseLeaf(output);
            parser.listItemMarkBlock();
            try parser.writeAll(output, "<hr>\n");
            return true;
        }
        return false;
    }
    fn parseDefinitionList(parser: *OctomarkParser, line_content: *[]const u8, leading_spaces: *usize, output: anytype) !bool {
        const _s = parser.startCall(.parseDefinitionList);
        defer parser.endCall(.parseDefinitionList, _s);
        var line = line_content.*;
        if (line.len > 0 and line[0] == ':') {
            var consumed: usize = 1;
            line = line[1..];
            if (line.len > 0 and line[0] == ' ') {
                line = line[1..];
                consumed += 1;
            }
            try parser.closeP(output);
            var in_dl = false;
            var in_dd = false;
            for (parser.block_stack[0..parser.stack_depth]) |entry| {
                if (entry.block_type == .definition_list) in_dl = true;
                if (entry.block_type == .definition_description) in_dd = true;
            }
            if (!in_dl) {
                try parser.writeAll(output, "<dl>\n");
                try parser.pushBlock(.definition_list, @intCast(leading_spaces.*));
            }
            if (in_dd) {
                while (parser.topT() != .definition_list and parser.stack_depth > 0) {
                    try parser.renderTop(output);
                }
            }
            try parser.writeAll(output, "<dd>");
            try parser.pushBlock(.definition_description, @intCast(leading_spaces.*));
            line_content.* = line;
            leading_spaces.* += consumed;
            return true;
        }
        return false;
    }
    fn parseListItem(parser: *OctomarkParser, line_content: *[]const u8, leading_spaces: *usize, output: anytype) !bool {
        const _s = parser.startCall(.parseListItem);
        defer parser.endCall(.parseListItem, _s);
        var line = line_content.*;
        if (line.len == 0) return false;
        if (isThematicBreakLine(line)) return false;
        if (leading_spaces.* >= 4 and parser.active_list_stack_idx < 0) return false;
        const trimmed_line = std.mem.trimLeft(u8, line, " ");
        const internal_spaces = line.len - trimmed_line.len;
        // Unordered list marker: -, *, +
        var is_ul = false;
        var marker_bytes: usize = 0;
        var marker_columns: usize = 0;
        var marker_extra_columns: usize = 0;
        if (line.len - internal_spaces >= 1) {
            const m = line[internal_spaces];
            if (m == '-' or m == '*' or m == '+') {
                if (internal_spaces + 1 == line.len) {
                    marker_bytes = 1;
                    marker_columns = 2;
                    is_ul = true;
                } else {
                    const next = line[internal_spaces + 1];
                    if (next == ' ' or next == '\t') {
                        const base_col = leading_spaces.* + internal_spaces + 1;
                        const tab_width: usize = if (next == '\t') 4 - (base_col % 4) else 1;
                        marker_bytes = 2;
                        marker_columns = 2;
                        if (next == '\t' and tab_width > 0) marker_extra_columns = tab_width - 1;
                        is_ul = true;
                    }
                }
            }
        }
        var ol_marker_char: u8 = 0;
        const is_ol = blk: {
            var ol_num_len: usize = 0;
            while (internal_spaces + ol_num_len < line.len and std.ascii.isDigit(line[internal_spaces + ol_num_len])) : (ol_num_len += 1) {}
            if (ol_num_len > 0 and ol_num_len <= 9 and internal_spaces + ol_num_len < line.len) {
                const marker = line[internal_spaces + ol_num_len];
                if (marker == '.' or marker == ')') {
                    ol_marker_char = marker;
                    if (internal_spaces + ol_num_len + 1 == line.len) {
                        marker_bytes = ol_num_len + 1;
                        marker_columns = ol_num_len + 2;
                    } else {
                        const next = line[internal_spaces + ol_num_len + 1];
                        if (next != ' ' and next != '\t') break :blk false;
                        const base_col = leading_spaces.* + internal_spaces + ol_num_len + 1;
                        const tab_width: usize = if (next == '\t') 4 - (base_col % 4) else 1;
                        marker_bytes = ol_num_len + 2;
                        marker_columns = ol_num_len + 1 + tab_width;
                        if (next == '\t' and tab_width > 0) marker_extra_columns = tab_width - 1;
                    }
                    // CommonMark: ordered list with start number != 1 cannot interrupt paragraph
                    if (parser.topT() == .paragraph and ol_num_len > 0) {
                        const start_num = std.fmt.parseInt(u32, line[internal_spaces .. internal_spaces + ol_num_len], 10) catch 1;
                        if (start_num != 1) return false;
                    }
                    break :blk true;
                }
            }
            break :blk false;
        };
        if (is_ul or is_ol) {
            const rem_check = std.mem.trimLeft(u8, line[internal_spaces + marker_bytes ..], " \t");
            if (rem_check.len == 0 and (parser.topT() == .paragraph or parser.paragraph_content.items.len > 0)) {
                if (parser.active_list_stack_idx < 0) return false;
            }
            const target_marker = if (is_ul) line[internal_spaces] else ol_marker_char;
            const target_type: BlockType = if (is_ul) .unordered_list else .ordered_list;
            const current_indent: i32 = @intCast(leading_spaces.* + internal_spaces);
            var normalized_indent = current_indent;
            const top_list_indent: ?i32 = if (parser.active_list_stack_idx >= 0)
                parser.block_stack[@intCast(parser.active_list_stack_idx)].indent_level
            else
                null;
            const top_list_content: ?i32 = if (parser.active_list_stack_idx >= 0)
                parser.block_stack[@intCast(parser.active_list_stack_idx)].content_indent
            else
                null;
            if (top_list_indent != null and top_list_content != null) {
                const tli = top_list_indent.?;
                const tlc = top_list_content.?;
                if (current_indent > tli and current_indent < tlc) {
                    normalized_indent = tli;
                }
            }
            if (top_list_indent != null and top_list_content != null) {
                const tli = top_list_indent.?;
                const tlc = top_list_content.?;
                if (current_indent > tli + 3 and current_indent < tlc) {
                    return false;
                }
            }
            const pre_block_type = parser.topT();
            if (pre_block_type == .paragraph or pre_block_type == .table or pre_block_type == .code or
                pre_block_type == .math)
            {
                try parser.renderTop(output);
            }
            while (parser.stack_depth > 0 and
                parser.topT() != null and @intFromEnum(parser.topT().?) < @intFromEnum(BlockType.blockquote) and
                (parser.block_stack[parser.stack_depth - 1].indent_level > normalized_indent or
                    (parser.block_stack[parser.stack_depth - 1].indent_level == normalized_indent and
                        (parser.topT() != target_type or parser.block_stack[parser.stack_depth - 1].extra_type !=
                            target_marker))))
            {
                if (parser.pending_loose_idx) |idx| {
                    const top_idx = parser.stack_depth - 1;
                    if (idx == top_idx) {
                        const closing_indent = parser.block_stack[top_idx].indent_level;
                        if (closing_indent > normalized_indent) {
                            var outer: ?usize = null;
                            var j: usize = top_idx;
                            while (j > 0) {
                                j -= 1;
                                const bt = parser.block_stack[j].block_type;
                                if (bt == .unordered_list or bt == .ordered_list) {
                                    outer = j;
                                    break;
                                }
                            }
                            parser.pending_loose_idx = outer;
                        }
                    }
                }
                try parser.renderTop(output);
            }
            const top = parser.topT();
            const list_loose = (top == .unordered_list or top == .ordered_list) and
                parser.block_stack[parser.stack_depth - 1].loose;
            if (parser.paragraph_content.items.len > 0) {
                const wrap_paragraph = list_loose and parser.topT() != .paragraph;
                try parser.flushListParagraph(output, wrap_paragraph);
            }
            if (top == target_type and parser.block_stack[parser.stack_depth - 1].indent_level == normalized_indent) {
                parser.listItemEnd();
                try parser.writeAll(output, "</li>\n<li>");
                parser.listItemStart();
            } else {
                if (target_type == .unordered_list) {
                    try parser.writeAll(output, "<ul>\n<li>");
                    try parser.pushBlockExtra(target_type, current_indent, target_marker);
                    parser.listItemStart();
                } else {
                    const start_num = std.fmt.parseInt(u32, line[internal_spaces .. internal_spaces + marker_bytes -
                        2], 10) catch 1;
                    if (start_num != 1) {
                        try parser.writeAll(output, "<ol start=\"");
                        var num_buf: [11]u8 = undefined;
                        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{start_num}) catch "1";
                        try parser.writeAll(output, num_str);
                        try parser.writeAll(output, "\">\n<li>");
                    } else {
                        try parser.writeAll(output, "<ol>\n<li>");
                    }
                    try parser.pushBlockExtra(target_type, current_indent, target_marker);
                    parser.block_stack[parser.stack_depth - 1].list_start = start_num;
                    parser.listItemStart();
                }
            }
            var remainder = line[internal_spaces + marker_bytes ..];
            const base_indent = leading_spaces.* + internal_spaces + marker_columns;
            leading_spaces.* = base_indent + marker_extra_columns;
            var item_content_indent = base_indent;
            if (remainder.len > 0) {
                const extra = leadingIndent(remainder);
                if (extra.columns > 0) {
                    if (extra.columns < 4) {
                        const take_cols: usize = extra.columns;
                        remainder = stripIndentColumns(remainder, take_cols);
                        item_content_indent += take_cols;
                        leading_spaces.* += take_cols;
                    }
                }
            }
            if (remainder.len >= 3 and remainder[0] == '[' and
                (remainder[1] == ' ' or remainder[1] == 'x' or remainder[1] == 'X') and remainder[2] == ']')
            {
                if (remainder.len == 3 or remainder[3] == ' ' or remainder[3] == '\t') {
                    parser.pending_task_marker = if (remainder[1] == ' ') @as(u8, 1) else @as(u8, 2);
                    remainder = remainder[3..];
                    if (remainder.len > 0 and (remainder[0] == ' ' or remainder[0] == '\t')) {
                        remainder = remainder[1..];
                        item_content_indent += 4;
                        leading_spaces.* += 4;
                    } else {
                        item_content_indent += 3;
                        leading_spaces.* += 3;
                    }
                }
            }
            parser.block_stack[parser.stack_depth - 1].content_indent = @intCast(item_content_indent);
            const rem_trim = std.mem.trim(u8, remainder, " \t");
            const empty_item = rem_trim.len == 0 and parser.pending_task_marker == 0;
            parser.block_stack[parser.stack_depth - 1].pending_empty_item = empty_item;
            line_content.* = remainder;
            return true;
        }
        return false;
    }
    fn parseTable(parser: *OctomarkParser, line_content: []const u8, full_data: []const u8, current_pos: usize, output: anytype) !bool {
        const _s = parser.startCall(.parseTable);
        defer parser.endCall(.parseTable, _s); // 1. If we are already IN a table, process body rows strictly.
        if (parser.topT() == .table) {
            const trimmed_line = std.mem.trim(u8, line_content, &std.ascii.whitespace);
            // Quick pipe check for body row
            const has_pipe = std.mem.indexOfScalar(u8, trimmed_line, '|') != null;
            if (has_pipe) {
                var body_cells: [64][]const u8 = undefined;
                const body_count = parser.splitTableRowCells(line_content, &body_cells);
                try parser.writeAll(output, "<tr>");
                var k: usize = 0;
                while (k < body_count) : (k += 1) {
                    try parser.writeAll(output, "<td");
                    writeTableAlignment(parser, output, if (k < parser.table_column_count) parser.table_alignments[k] else .none) catch {};
                    try parser.writeAll(output, ">");
                    try parser.parseInlineContent(body_cells[k], output);
                    try parser.writeAll(output, "</td>");
                }
                try parser.writeAll(output, "</tr>\n");
                return true;
            } else { // No pipe = end of table
                try parser.renderTop(output); // Continue to process this line as something else (return false)
                return false;
            }
        }
        if (current_pos >= full_data.len) return false;
        if (std.mem.indexOfScalar(u8, line_content, '|') == null) return false;
        if (!parser.isNextLineTableSeparator(full_data, current_pos)) return false;
        const sep_line_end = if (std.mem.indexOfScalar(u8, full_data[current_pos..], '\n')) |nl|
            current_pos + nl
        else
            full_data.len;
        const sep_line = full_data[current_pos..sep_line_end];
        var header_cells: [64][]const u8 = undefined;
        const header_count = parser.splitTableRowCells(line_content, &header_cells);
        var sep_cells: [64][]const u8 = undefined;
        const sep_count = parser.splitTableRowCells(sep_line, &sep_cells);
        parser.table_column_count = header_count;
        var k: usize = 0;
        while (k < header_count) : (k += 1) {
            var col_align = TableAlignment.none;
            if (k < sep_count) {
                const cell = sep_cells[k];
                if (cell.len > 0) {
                    const left = cell[0] == ':';
                    const right = cell[cell.len - 1] == ':';
                    col_align = if (left and right) TableAlignment.center else if (left) TableAlignment.left else if (right) TableAlignment.right else TableAlignment.none;
                }
            }
            parser.table_alignments[k] = col_align;
        }
        try parser.tryCloseLeaf(output);
        try parser.writeAll(output, "<table><thead><tr>");
        k = 0;
        while (k < header_count) : (k += 1) {
            try parser.writeAll(output, "<th");
            writeTableAlignment(parser, output, parser.table_alignments[k]) catch {};
            try parser.writeAll(output, ">");
            try parser.parseInlineContent(header_cells[k], output);
            try parser.writeAll(output, "</th>");
        }
        try parser.writeAll(output, "</tr></thead><tbody>\n");
        try parser.pushBlock(.table, 0);
        return true;
    }
    fn parseDefinitionTerm(parser: *OctomarkParser, line_content: []const u8, full_data: []const u8, current_pos: usize, output: anytype) !bool {
        const _s = parser.startCall(.parseDefinitionTerm);
        defer parser.endCall(.parseDefinitionTerm, _s);
        if (current_pos < full_data.len) {
            const check = full_data[current_pos..];
            var k: usize = 0;
            while (k < check.len and check[k] == ' ') : (k += 1) {}
            if (k < check.len and check[k] == ':') {
                const block_type = parser.topT();
                if (block_type == .paragraph or block_type == .table or block_type == .code or block_type == .math) {
                    try parser.renderTop(output);
                }
                if (parser.stack_depth == 0 or parser.topT() != .definition_list) {
                    try parser.writeAll(output, "<dl>\n");
                    try parser.pushBlock(.definition_list, 0);
                }
                try parser.writeAll(output, "<dt>");
                try parser.parseInlineContent(line_content, output);
                try parser.writeAll(output, "</dt>\n");
                return true;
            }
        }
        return false;
    }
    fn processParagraph(parser: *OctomarkParser, line_content: []const u8, is_dl: bool, is_list: bool, output: anytype) !void {
        const _s = parser.startCall(.processParagraph);
        defer parser.endCall(.processParagraph, _s);
        if (line_content.len == 0) {
            try parser.closeP(output);
            return;
        }
        const block_type = parser.topT();
        const in_container = (parser.stack_depth > 0 and
            (block_type != null and
                (@intFromEnum(block_type.?) < @intFromEnum(BlockType.blockquote) or block_type.? ==
                    .definition_description)));
        const list_loose = if (parser.active_list_stack_idx >= 0) parser.block_stack[@intCast(parser.active_list_stack_idx)].loose else false;
        if (parser.topT() != .paragraph and (!in_container or list_loose)) {
            try parser.pushBlock(.paragraph, 0);
        } else if (parser.topT() == .paragraph or (in_container and !is_list and !is_dl and !list_loose)) {
            try parser.paragraph_content.append(parser.allocator, '\n');
        }
        if (parser.pending_task_marker > 0) {
            try parser.writeAll(output, if (parser.pending_task_marker == 2)
                "<input type=\"checkbox\" checked disabled> "
            else
                "<input type=\"checkbox\" disabled> ");
            parser.pending_task_marker = 0;
        }
        try parser.paragraph_content.appendSlice(parser.allocator, line_content);
    }
    fn isBSM(p: *OctomarkParser, s: []const u8, ls: usize) bool {
        const _s = p.startCall(.isBlockStartMarker);
        defer p.endCall(.isBlockStartMarker, _s);
        if (ls > 3 or s.len == 0) return false;
        return switch (s[0]) {
            '`' => s.len >= 3 and std.mem.startsWith(u8, s, "```"),
            '$' => s.len >= 2 and std.mem.startsWith(u8, s, "$$"),
            '#', ':', '<', '|' => true,
            '-', '*', '_' => isThematicBreakLine(s) or s.len == 1 or (s.len >= 2 and (s[1] == ' ' or s[1] == '\t')),
            '0'...'9' => blk: {
                var j: usize = 1;
                while (j < s.len and std.ascii.isDigit(s[j])) : (j += 1) {}
                if (j < s.len and (s[j] == '.' or s[j] == ')') and
                    (j + 1 == s.len or (j + 1 < s.len and (s[j + 1] == ' ' or s[j + 1] == '\t'))))
                {
                    if (p.topT() == .paragraph) {
                        const start_num = std.fmt.parseInt(u32, s[0..j], 10) catch 1;
                        if (start_num != 1) break :blk false;
                    }
                    break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }
    fn processSingleLine(p: *OctomarkParser, line: []const u8, full: []const u8, pos: usize, o: anytype) !bool {
        const s = p.startCall(.processSingleLine);
        defer p.endCall(.processSingleLine, s);
        if (try p.processLeafBlockContinuation(line, o)) return false;
        const id = leadingIndent(line);
        var ls = id.columns;
        var lc = line[id.idx..];
        if (lc.len == 0) {
            p.prev_line_blank = true;
            return try p.handleBlankLine(o, null, true);
        }
        const prev_blank = p.prev_line_blank;
        p.prev_line_blank = false;
        var q_lv: usize = 0;
        var ex_id: usize = 0;
        {
            var i: usize = 0;
            var col: usize = ls;
            while (i < lc.len) {
                const start_i = i;
                while (i < lc.len) : (i += 1) switch (lc[i]) {
                    ' ' => col += 1,
                    '\t' => col += 4 - (col % 4),
                    else => break,
                };
                if (col > 3) {
                    i = start_i;
                    break;
                }
                if (i < lc.len and lc[i] == '>') {
                    q_lv += 1;
                    i += 1;
                    col += 1;
                    if (i < lc.len) switch (lc[i]) {
                        ' ' => {
                            i += 1;
                            col += 1;
                        },
                        '\t' => {
                            const tw = 4 - (col % 4);
                            i += 1;
                            col += tw;
                            if (tw > 0) ex_id += tw - 1;
                        },
                        else => {},
                    };
                    lc = lc[i..];
                    i = 0;
                    col = 0;
                } else {
                    i = start_i;
                    break;
                }
            }
        }
        var cur_q: usize = p.blockquote_depth;
        if (q_lv > 0) {
            var remove: usize = 0;
            if (cur_q > 0) {
                remove = if (ls > 3) 3 else ls;
            } else {
                const list_content_indent: ?usize = if (p.active_list_stack_idx >= 0)
                    @intCast(p.block_stack[@intCast(p.active_list_stack_idx)].content_indent)
                else
                    null;
                if (list_content_indent) |lci| {
                    if (ls >= lci) {
                        const extra = ls - lci;
                        if (extra > 0) remove = if (extra > 3) 3 else extra;
                    } else {
                        remove = if (ls > 3) 3 else ls;
                    }
                } else {
                    remove = if (ls > 3) 3 else ls;
                }
            }
            if (remove > 0) ls -= remove;
        }
        ls += ex_id;
        const p_id = leadingIndent(lc);
        ls += p_id.columns;
        lc = lc[p_id.idx..];
        var lazy = false;
        if (q_lv < cur_q and p.topT() == .paragraph) {
            if (!p.isBSM(lc, ls)) {
                q_lv = cur_q;
                lazy = true;
            }
        }
        while (cur_q > q_lv) {
            const t = p.topT().?;
            try p.renderTop(o);
            if (t == .blockquote) cur_q -= 1;
        }
        while (cur_q < q_lv) {
            if (p.topT() == .paragraph) {
                try p.closeP(o);
            } else if (p.paragraph_content.items.len > 0) {
                try p.parseInlineContent(p.paragraph_content.items, o);
                p.paragraph_content.clearRetainingCapacity();
            }
            try p.writeAll(o, "<blockquote>");
            try p.pushBlock(.blockquote, 0);
            cur_q += 1;
        }
        if (lc.len == 0) {
            p.prev_line_blank = true;
            var bq_idx: ?usize = null;
            if (p.stack_depth > 0) {
                var i = p.stack_depth;
                while (i > 0) {
                    i -= 1;
                    const bt = p.block_stack[i].block_type;
                    if (bq_idx == null and bt == .blockquote) bq_idx = i;
                }
            }
            return try p.handleBlankLine(o, bq_idx, false);
        }
        const is_dl = try p.parseDefinitionList(&lc, &ls, o);
        var is_list = try p.parseListItem(&lc, &ls, o);
        if ((is_dl or is_list) and lc.len > 0) {
            const ex = leadingIndent(lc);
            if (ex.idx > 0) {
                ls += ex.columns;
                lc = lc[ex.idx..];
            }
        }
        if (is_list and lc.len > 0) {
            var nest_attempts: usize = 0;
            while (nest_attempts < 2 and lc.len > 0) : (nest_attempts += 1) {
                const list_idx: ?usize = if (p.active_list_stack_idx >= 0) @intCast(p.active_list_stack_idx) else null;
                var list_content_indent: usize = 0;
                if (list_idx) |idx| {
                    list_content_indent = @intCast(p.block_stack[idx].content_indent);
                }
                if (list_idx != null and ls >= list_content_indent) {
                    var lc2 = lc;
                    var ls2 = ls;
                    if (try p.parseListItem(&lc2, &ls2, o)) {
                        lc = lc2;
                        ls = ls2;
                        is_list = true;
                        if (lc.len > 0) {
                            const ex2 = leadingIndent(lc);
                            if (ex2.idx > 0) {
                                ls += ex2.columns;
                                lc = lc[ex2.idx..];
                            }
                        }
                        continue;
                    }
                }
                break;
            }
        }
        const list_idx: ?usize = if (p.active_list_stack_idx >= 0) @intCast(p.active_list_stack_idx) else null;
        var list_content_indent: usize = 0;
        var list_indent: usize = 0;
        if (list_idx) |idx| {
            list_content_indent = @intCast(p.block_stack[idx].content_indent);
            list_indent = @intCast(p.block_stack[idx].indent_level);
        }
        var list_lazy = false;
        if (list_idx != null and !is_list and !is_dl and lc.len > 0 and !lazy and !prev_blank) {
            const li = list_idx.?;
            const entry = p.block_stack[li];
            const has_para = p.topT() == .paragraph or p.paragraph_content.items.len > 0;
            if (ls < list_content_indent and !p.isBSM(lc, ls)) {
                if (has_para) {
                    list_lazy = true;
                } else if (entry.pending_empty_item and ls > list_indent) {
                    list_lazy = true;
                    p.block_stack[li].pending_empty_item = false;
                }
            }
            if (ls >= list_content_indent or list_lazy) {
                if (p.block_stack[li].pending_empty_item) p.block_stack[li].pending_empty_item = false;
            }
        }
        var parse_ls = ls;
        if (list_idx != null and !is_list and !is_dl and ls >= list_content_indent) {
            parse_ls = ls - list_content_indent;
        }
        var html_ls = ls;
        if (list_idx != null and ls >= list_content_indent) html_ls = ls - list_content_indent;
        const force_close_empty = prev_blank and list_idx != null and !is_list and !is_dl and
            p.block_stack[list_idx.?].pending_empty_item;
        if (lc.len > 0) {
            var mi: usize = 0;
            while (mi < p.stack_depth) {
                const e = p.block_stack[mi];
                if (e.block_type == .unordered_list or e.block_type == .ordered_list) {
                    if (force_close_empty and list_idx.? == mi) {
                        while (p.stack_depth > mi) try p.renderTop(o);
                        break;
                    }
                    if (ls < @as(usize, @intCast(e.content_indent)) and !lazy and !is_list and !is_dl and !list_lazy) {
                        if (p.pending_loose_idx) |idx| {
                            if (idx == mi) {
                                var outer: ?usize = null;
                                var j: usize = mi;
                                while (j > 0) {
                                    j -= 1;
                                    const bt = p.block_stack[j].block_type;
                                    if (bt == .unordered_list or bt == .ordered_list) {
                                        outer = j;
                                        break;
                                    }
                                }
                                p.pending_loose_idx = outer;
                            }
                        }
                        while (p.stack_depth > mi) try p.renderTop(o);
                        break;
                    }
                }
                mi += 1;
            }
            if (p.pending_loose_idx) |idx| {
                if (idx < p.stack_depth) {
                    const entry = p.block_stack[idx];
                    const entry_content: usize = @intCast(entry.content_indent);
                    if (is_list or ls >= entry_content) {
                        try p.applyPendingLoose(o);
                    }
                } else {
                    p.pending_loose_idx = null;
                }
            }
            if (ls <= 3 and isThematicBreakLine(lc)) {
                if (p.stack_depth > 0) {
                    const l_id: ?i32 = if (p.active_list_stack_idx >= 0) p.block_stack[@intCast(p.active_list_stack_idx)].content_indent else null;
                    if (l_id) |lim| {
                        if (ls < @as(usize, @intCast(lim))) {
                            try p.closeP(o);
                            while (p.topT() == .unordered_list or p.topT() == .ordered_list) {
                                try p.renderTop(o);
                            }
                        }
                    }
                }
            }
            if (!lazy and parse_ls <= 3 and (p.topT() == .paragraph or (list_idx != null and
                p.paragraph_content.items.len > 0)))
            {
                var st: usize = 0;
                while (st < lc.len and (lc[st] == ' ' or lc[st] == '\t')) st += 1;
                var en = lc.len;
                while (en > st and (lc[en - 1] == ' ' or lc[en - 1] == '\t')) en -= 1;
                if (st < en and (lc[st] == '=' or lc[st] == '-')) {
                    var i = st;
                    while (i < en) : (i += 1) if (lc[i] != lc[st]) break;
                    if (i == en) {
                        const tr = std.mem.trim(u8, p.paragraph_content.items, " \t\n");
                        if (tr.len > 0) {
                            p.paragraph_content.clearRetainingCapacity();
                            if (p.topT() == .paragraph) p.pop();
                            const lv: u8 = if (lc[st] == '=') '1' else '2';
                            try p.writeAll(o, "<h");
                            try p.writeByte(o, lv);
                            try p.writeAll(o, ">");
                            try p.parseInlineContent(tr, o);
                            try p.writeAll(o, "</h");
                            try p.writeByte(o, lv);
                            try p.writeAll(o, ">\n");
                            return false;
                        }
                    }
                }
            }
            switch (lc[0]) {
                '#' => if (try p.parseHeader(lc, parse_ls, o)) return false,
                '`', '~' => if (try p.parseFencedCodeBlock(lc, parse_ls, o)) return false,
                '$' => if (try p.parseMathBlock(lc, parse_ls, o)) return false,
                '-', '*', '_' => if (try p.parseHorizontalRule(lc, parse_ls, o)) return false,
                '|' => if (try p.parseTable(lc, full, pos, o)) return true,
                '>' => {
                    var q_lc = lc;
                    var q_ls = ls;
                    if (p.stack_depth > 0) {
                        const l_idx: ?usize = if (p.active_list_stack_idx >= 0) @intCast(p.active_list_stack_idx) else null;
                        if (l_idx) |idx| {
                            const li: usize = @intCast(p.block_stack[idx].content_indent);
                            if (ls >= li) {
                                q_lc = stripIndentColumns(lc, li);
                                q_ls = ls - li;
                            }
                        }
                    }
                    if (q_ls <= 3) {
                        var q_c: usize = 0;
                        var l_c = q_lc;
                        while (true) {
                            var k: usize = 0;
                            while (k < l_c.len and (l_c[k] == ' ' or l_c[k] == '\t')) k += 1;
                            if (k < l_c.len and l_c[k] == '>') {
                                q_c += 1;
                                k += 1;
                                if (k < l_c.len and (l_c[k] == ' ' or l_c[k] == '\t')) k += 1;
                                l_c = l_c[k..];
                            } else break;
                        }
                        if (q_c > 0) {
                            lc = l_c;
                            try p.closeP(o);
                            var k: usize = 0;
                            while (k < q_c) : (k += 1) {
                                try p.writeAll(o, "<blockquote>");
                                try p.pushBlock(.blockquote, 0);
                            }
                        }
                    }
                },
                '<' => if (lc.len >= 3 and html_ls <= 3) {
                    var h_t: u8 = 0;
                    if (lc.len >= 4 and lc[1] == '!') {
                        if (std.mem.startsWith(u8, lc, "<!--")) h_t = 2 else if (std.mem.startsWith(u8, lc, "<![CDATA[")) h_t = 5 else h_t = 4;
                    } else if (lc.len >= 2 and lc[1] == '?') h_t = 3 else {
                        const is_close = lc.len >= 2 and lc[1] == '/';
                        const tr = if (is_close) lc[2..] else lc[1..];
                        const t1 = [_][]const u8{ "script", "pre", "style", "textarea" };
                        if (!is_close) for (t1) |t| if (std.mem.startsWith(u8, tr, t)) {
                            if (tr.len == t.len or !std.ascii.isAlphanumeric(tr[t.len])) {
                                h_t = 1;
                                break;
                            }
                        };
                        if (h_t == 0) {
                            const t6 = [_][]const u8{
                                "address",  "article",  "aside",    "base",       "basefont", "blockquote", "body",   "caption",
                                "center",   "col",      "colgroup", "dd",         "details",  "dialog",     "dir",    "div",
                                "dl",       "dt",       "fieldset", "figcaption", "figure",   "footer",     "form",   "frame",
                                "frameset", "h1",       "h2",       "h3",         "h4",       "h5",         "h6",     "head",
                                "header",   "hr",       "html",     "iframe",     "legend",   "li",         "link",   "main",
                                "menu",     "menuitem", "nav",      "noframes",   "ol",       "optgroup",   "option", "p",
                                "param",    "section",  "source",   "summary",    "table",    "tbody",      "td",     "textarea",
                                "tfoot",    "th",       "thead",    "title",      "tr",       "ul",
                            };
                            for (t6) |t| if (std.mem.startsWith(u8, tr, t)) {
                                if (tr.len == t.len or !std.ascii.isAlphanumeric(tr[t.len])) {
                                    h_t = 6;
                                    break;
                                }
                            };
                        }
                        if (h_t == 0 and p.topT() != .paragraph) {
                            const l = p.parseHtmlTag(lc);
                            if (l > 0) {
                                var rem = lc[l..];
                                while (rem.len > 0 and (rem[0] == ' ' or rem[0] == '\t')) rem = rem[1..];
                                if (rem.len == 0) h_t = 7;
                            }
                        }
                    }
                    if (h_t > 0) {
                        try p.tryCloseLeaf(o);
                        try p.pushBlockExtra(.html_block, 0, h_t);
                        var pad: usize = 0;
                        while (pad < html_ls) : (pad += 1) try p.writeByte(o, ' ');
                        try p.writeAll(o, lc);
                        try p.writeByte(o, '\n');
                        var term = false;
                        if (h_t == 1) {
                            const tags = [_][]const u8{ "</script>", "</pre>", "</style>", "</textarea>" };
                            var i: usize = 0;
                            while (i < lc.len) : (i += 1) {
                                if (lc[i] == '<' and i + 1 < lc.len and lc[i + 1] == '/') {
                                    for (tags) |tag| {
                                        if (i + tag.len <= lc.len) {
                                            if (std.ascii.eqlIgnoreCase(lc[i .. i + tag.len], tag)) {
                                                term = true;
                                                break;
                                            }
                                        }
                                    }
                                }
                                if (term) break;
                            }
                        } else if (h_t == 2) {
                            if (std.mem.indexOf(u8, lc, "-->") != null) term = true;
                        } else if (h_t == 3) {
                            if (std.mem.indexOf(u8, lc, "?>") != null) term = true;
                        } else if (h_t == 4) {
                            if (std.mem.indexOf(u8, lc, ">") != null) term = true;
                        } else if (h_t == 5) {
                            if (std.mem.indexOf(u8, lc, "]]>") != null) term = true;
                        }
                        if (term) try p.renderTop(o);
                        return false;
                    }
                },
                else => {},
            }
        }
        if (!is_dl and try p.parseDefinitionTerm(lc, full, pos, o)) return false;
        if (!is_dl and try p.parseIndentedCodeBlock(lc, ls, o)) return false;
        try p.processParagraph(lc, is_dl, is_list, o);
        return false;
    }
    fn isNextLineTableSeparator(parser: *OctomarkParser, full_data: []const u8, start_pos: usize) bool {
        const _s = parser.startCall(.isNextLineTableSeparator);
        defer parser.endCall(.isNextLineTableSeparator, _s);
        if (start_pos >= full_data.len) return false;
        const nl = std.mem.indexOfScalar(u8, full_data[start_pos..], '\n') orelse full_data.len - start_pos;
        const next_line = full_data[start_pos .. start_pos + nl];
        const trimmed = std.mem.trim(u8, next_line, &std.ascii.whitespace);
        if (trimmed.len < 3) return false;
        const first = trimmed[0];
        if (first != '|' and first != '-' and first != ':') return false;
        var has_dash = false;
        for (trimmed) |c| {
            switch (c) {
                '-' => has_dash = true,
                ':', '|', ' ', '\t', '\r' => {},
                else => return false,
            }
        }
        return has_dash;
    }
    fn parseHtmlTag(parser: *OctomarkParser, text: []const u8) usize {
        const _s = parser.startCall(.parseHtmlTag);
        defer parser.endCall(.parseHtmlTag, _s);
        const len = text.len;
        if (len < 3 or text[0] != '<') return 0;
        var i: usize = 1;
        if (i + 2 < len and std.mem.eql(u8, text[i .. i + 3], "!--")) {
            i += 3;
            if (i < len and text[i] == '>') return i + 1;
            if (i + 1 < len and text[i] == '-' and text[i + 1] == '>') return i + 2;
            while (i + 2 < len) : (i += 1) {
                if (std.mem.eql(u8, text[i .. i + 3], "-->")) return i + 3;
            }
            return 0;
        }
        if (i + 7 < len and std.mem.eql(u8, text[i .. i + 8], "![CDATA[")) {
            i += 8;
            while (i + 2 < len) : (i += 1) {
                if (text[i] == ']' and text[i + 1] == ']' and text[i + 2] == '>') return i + 3;
            }
            return 0;
        }
        if (i < len and text[i] == '?') {
            i += 1;
            while (i + 1 < len) : (i += 1) {
                if (std.mem.eql(u8, text[i .. i + 2], "?>")) return i + 2;
            }
            return 0;
        }
        if (i < len and text[i] == '!') {
            i += 1;
            while (i < len) : (i += 1) {
                if (text[i] == '>') return i + 1;
            }
            return 0;
        }
        const closing = if (i < len and text[i] == '/') blk: {
            i += 1;
            break :blk true;
        } else false;
        if (i >= len or !std.ascii.isAlphabetic(text[i])) return 0;
        while (i < len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '-')) : (i += 1) {}
        if (closing) {
            while (i < len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
            return if (i < len and text[i] == '>') i + 1 else 0;
        }
        while (i < len) {
            const has_ws = std.ascii.isWhitespace(text[i]);
            while (i < len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
            if (i >= len) return 0;
            if (text[i] == '>') return i + 1;
            if (i + 1 < len and text[i] == '/' and text[i + 1] == '>') return i + 2;
            if (!has_ws) return 0;
            if (std.ascii.isAlphabetic(text[i]) or text[i] == '_' or text[i] == ':') {
                i += 1;
                while (i < len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_' or text[i] == '.' or
                    text[i] == ':' or text[i] == '-')) : (i += 1)
                {}
                const before_eq = i;
                while (i < len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
                if (i < len and text[i] == '=') {
                    i += 1;
                    while (i < len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
                    if (i >= len) return 0;
                    if (text[i] == '"') {
                        i += 1;
                        while (i < len and text[i] != '"') : (i += 1) {}
                        if (i >= len) return 0;
                        i += 1;
                    } else if (text[i] == '\'') {
                        i += 1;
                        while (i < len and text[i] != '\'') : (i += 1) {}
                        if (i >= len) return 0;
                        i += 1;
                    } else {
                        if (std.ascii.isWhitespace(text[i]) or text[i] == '"' or text[i] == '\'' or text[i] == '=' or
                            text[i] == '<' or text[i] == '>' or text[i] == '`') return 0;
                        while (i < len and !std.ascii.isWhitespace(text[i]) and text[i] != '"' and text[i] != '\'' and
                            text[i] != '=' and text[i] != '<' and text[i] != '>' and text[i] != '`') : (i += 1)
                        {}
                    }
                } else {
                    i = before_eq;
                }
            } else return 0;
        }
        return if (i < len and text[i] == '>') i + 1 else 0;
    }
    fn splitTableRowCells(parser: *OctomarkParser, str: []const u8, cells: *[64][]const u8) usize {
        const _s = parser.startCall(.splitTableRowCells);
        defer parser.endCall(.splitTableRowCells, _s);
        var count: usize = 0;
        var cursor = std.mem.trim(u8, str, &std.ascii.whitespace);
        if (cursor.len > 0 and cursor[0] == '|') cursor = cursor[1..];
        while (cursor.len > 0) {
            var k: usize = 0;
            var end_offset: usize = cursor.len;
            while (std.mem.indexOfScalar(u8, cursor[k..], '|')) |offset| {
                const j = k + offset;
                var backslashes: usize = 0;
                var b = j;
                while (b > 0 and cursor[b - 1] == '\\') : (b -= 1) {
                    backslashes += 1;
                }
                if (backslashes % 2 == 0) {
                    end_offset = j;
                    break;
                }
                k = j + 1;
            }
            const cell = std.mem.trim(u8, cursor[0..end_offset], &std.ascii.whitespace);
            if (count < cells.len) {
                cells[count] = cell;
                count += 1;
            }
            if (end_offset >= cursor.len) break;
            cursor = cursor[end_offset + 1 ..];
            cursor = std.mem.trimLeft(u8, cursor, &std.ascii.whitespace);
        }
        return count;
    }
    fn writeTableAlignment(parser: *OctomarkParser, output: anytype, align_type: TableAlignment) !void {
        try switch (align_type) {
            .left => parser.writeAll(output, " style=\"text-align:left\""),
            .center => parser.writeAll(output, " style=\"text-align:center\""),
            .right => parser.writeAll(output, " style=\"text-align:right\""),
            .none => {},
        };
    }
};
