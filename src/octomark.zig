const std = @import("std");
const builtin = @import("builtin");

const MAX_BLOCK_NESTING = 32;
const MAX_INLINE_NESTING = 32;

const BlockType = enum(u8) { unordered_list, ordered_list, blockquote, definition_list, definition_description, code, indented_code, math, table, paragraph };
const block_close_tags = [_][]const u8{ "</li>\n</ul>\n", "</li>\n</ol>\n", "</blockquote>\n", "</dl>\n", "</dd>\n", "</code></pre>\n", "</code></pre>\n", "</div>\n", "</tbody></table>\n", "</p>\n" };
const TableAlignment = enum { none, left, center, right };
const BlockEntry = struct { block_type: BlockType, indent_level: i32, content_indent: i32, loose: bool };
const Buffer = std.ArrayListUnmanaged(u8);
const AllocError = std.mem.Allocator.Error;
const ParseError = AllocError || std.fs.File.WriteError || error{ NestingTooDeep, TooManyTableColumns };
pub const OctomarkOptions = struct { enable_html: bool = true };
const special_chars = "\\['*`&<>\"'_~!$\n";
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
    timer: if (builtin.mode == .Debug) std.time.Timer else struct {} = undefined,

    const Delimiter = struct { pos: usize, content_end: usize, char: u8, count: usize, can_open: bool, can_close: bool, active: bool };
    const Replacement = struct { pos: usize, end: usize, text: []const u8 };
    const Stats = struct {
        const C = struct { count: usize = 0, time_ns: u64 = 0 };
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
    };

    inline fn startCall(self: *OctomarkParser, comptime field: std.meta.FieldEnum(Stats)) u64 {
        if (builtin.mode == .Debug) {
            @field(self.stats, @tagName(field)).count += 1;
            return self.timer.read();
        }
        return 0;
    }
    inline fn endCall(self: *OctomarkParser, comptime field: std.meta.FieldEnum(Stats), s: u64) void {
        if (builtin.mode == .Debug) @field(self.stats, @tagName(field)).time_ns += self.timer.read() - s;
    }

    pub fn init(self: *OctomarkParser, allocator: std.mem.Allocator) !void {
        self.* = .{
            .allocator = allocator,
            .paragraph_content = .{},
            .pending_code_blank_lines = .{},
            .replacements = .{},
            .pending_task_marker = 0,
            .pending_loose_idx = null,
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
    }
    pub fn setOptions(self: *OctomarkParser, options: OctomarkOptions) void {
        self.options = options;
    }

    pub fn parse(self: *OctomarkParser, reader: anytype, writer: anytype, allocator: std.mem.Allocator) !void {
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
            std.debug.print("\n--- Octomark Stats ---\n{s: <25} | {s: >10} | {s: >15} | {s: >15}\n", .{ "Function", "Calls", "Total Time", "Avg Call" });
            inline for (std.meta.fields(Stats)) |f| {
                const c = @field(self.stats, f.name);
                const avg = if (c.count > 0) c.time_ns / c.count else 0;
                std.debug.print("{s: <25} | {d: >10} | {d: >12.3} ms | {d: >12.3} ns\n", .{ f.name, c.count, @as(f64, @floatFromInt(c.time_ns)) / 1e6, @as(f64, @floatFromInt(avg)) });
            }
        }
    }

    inline fn writeAll(writer: anytype, bytes: []const u8) !void {
        const W = if (@typeInfo(@TypeOf(writer)) == .pointer) std.meta.Child(@TypeOf(writer)) else @TypeOf(writer);
        if (comptime @hasField(W, "interface")) try writer.interface.writeAll(bytes) else try writer.writeAll(bytes);
    }
    inline fn writeByte(writer: anytype, byte: u8) !void {
        const W = if (@typeInfo(@TypeOf(writer)) == .pointer) std.meta.Child(@TypeOf(writer)) else @TypeOf(writer);
        if (comptime @hasField(W, "interface")) try writer.interface.writeByte(byte) else try writer.writeByte(byte);
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
        if (p.stack_depth >= MAX_BLOCK_NESTING) return error.NestingTooDeep;
        p.block_stack[p.stack_depth] = .{ .block_type = t, .indent_level = i, .content_indent = i, .loose = false };
        p.stack_depth += 1;
    }
    fn pop(p: *OctomarkParser) void {
        if (p.stack_depth > 0) p.stack_depth -= 1;
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
        if (p.paragraph_content.items.len > 0) {
            if (t == .paragraph) try writeAll(o, "<p>");
            try p.parseInlineContent(p.paragraph_content.items, o);
            p.paragraph_content.clearRetainingCapacity();
        }
        p.pop();
        if (p.pending_loose_idx) |idx| {
            if (idx >= p.stack_depth - 1) p.pending_loose_idx = null;
        }
        try writeAll(o, block_close_tags[@intFromEnum(t)]);
    }
    fn closeP(p: *OctomarkParser, o: anytype) !void {
        if (p.topT() == .paragraph) try p.renderTop(o);
    }
    fn tryCloseLeaf(p: *OctomarkParser, o: anytype) !void {
        const t = p.topT() orelse return;
        if (t == .paragraph or @intFromEnum(t) >= @intFromEnum(BlockType.code)) {
            try p.renderTop(o);
        } else if (p.paragraph_content.items.len > 0) {
            try p.parseInlineContent(p.paragraph_content.items, o);
            p.paragraph_content.clearRetainingCapacity();
        }
    }
    fn esc(p: *const OctomarkParser, text: []const u8, o: anytype) !void {
        _ = p;
        var i: usize = 0;
        while (i < text.len) {
            if (std.mem.indexOfAny(u8, text[i..], "&<>\"'")) |off| {
                const j = i + off;
                if (j > i) try writeAll(o, text[i..j]);
                try writeAll(o, html_escape_map[text[j]].?);
                i = j + 1;
            } else {
                try writeAll(o, text[i..]);
                break;
            }
        }
    }
    fn isAsciiPunct(c: u32) bool {
        return (c >= 33 and c <= 47) or (c >= 58 and c <= 64) or (c >= 91 and c <= 96) or (c >= 123 and c <= 126);
    }
    fn isPunct(c: u32) bool {
        if (c < 128) return isAsciiPunct(c);
        return (c >= 0x2000 and c <= 0x206F) or (c >= 0x2E00 and c <= 0x2E7F) or (c >= 0x3000 and c <= 0x303F) or (c >= 0xFF00 and c <= 0xFFEF);
    }
    fn isWhitespace(c: u32) bool {
        if (c < 128) return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0B or c == 0x0C;
        return c == 0xA0 or c == 0x1680 or (c >= 0x2000 and c <= 0x200A) or c == 0x202F or c == 0x205F or c == 0x3000;
    }
    fn findSpec(p: *OctomarkParser, text: []const u8, start: usize) usize {
        const s = p.startCall(.findSpec);
        defer p.endCall(.findSpec, s);
        return if (std.mem.indexOfAny(u8, text[start..], special_chars)) |off| start + off else text.len;
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

    fn parseInlineContentDepth(p: *OctomarkParser, text: []const u8, o: anytype, depth: usize, g_off: usize, plain: bool) anyerror!void {
        const _s = p.startCall(.parseInlineContent);
        defer p.endCall(.parseInlineContent, _s);

        if (depth > MAX_INLINE_NESTING) {
            try writeAll(o, text);
            return;
        }
        try p.renderInline(text, p.replacements.items, o, depth, g_off, plain);
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
        var open = !w_a and (!p_a or w_b or p_b);
        var close = !w_b and (!p_b or w_a or p_a);
        if (char == '_') {
            open = open and (!close or p_b);
            close = close and (!open or p_a);
        }
        if (close) {
            var idx = p.delimiter_stack_len;
            while (idx > bottom) {
                idx -= 1;
                var opener = &p.delimiter_stack[idx];
                if (opener.char == char and opener.active and opener.can_open) {
                    if (char != '~' and (opener.can_close or open) and (opener.count + num) % 3 == 0 and (opener.count % 3 != 0 or num % 3 != 0)) continue;
                    const use: usize = if (char == '~') (if (num >= 2 and opener.count >= 2) @as(usize, 2) else 0) else (if (num >= 2 and opener.count >= 2) @as(usize, 2) else 1);
                    if (use == 0) continue;
                    const t_o = if (char == '~') "<del>" else (if (use == 2) "<strong>" else "<em>");
                    const t_c = if (char == '~') "</del>" else (if (use == 2) "</strong>" else "</em>");
                    try p.replacements.append(p.allocator, .{ .pos = opener.pos + opener.count - use, .end = opener.pos + opener.count, .text = t_o });
                    try p.replacements.append(p.allocator, .{ .pos = start_pos, .end = start_pos + use, .text = t_c });
                    opener.count -= use;
                    num -= use;
                    if (opener.count == 0) {
                        if (idx < p.delimiter_stack_len - 1) std.mem.copyForwards(Delimiter, p.delimiter_stack[idx .. p.delimiter_stack_len - 1], p.delimiter_stack[idx + 1 .. p.delimiter_stack_len]);
                        p.delimiter_stack_len -= 1;
                    }
                    if (num == 0) break;
                }
            }
        }
        if (open and num > 0 and p.delimiter_stack_len < MAX_INLINE_NESTING) {
            p.delimiter_stack[p.delimiter_stack_len] = .{ .pos = start_pos, .content_end = i, .char = char, .count = num, .can_open = open, .can_close = close, .active = true };
            p.delimiter_stack_len += 1;
        }
        return i;
    }
    fn scanInline(p: *OctomarkParser, text: []const u8, bottom: usize) !void {
        const s = p.startCall(.scanInline);
        defer p.endCall(.scanInline, s);
        var i: usize = 0;
        while (i < text.len) {
            const off = std.mem.indexOfAny(u8, text[i..], "*_`~<\\") orelse break;
            i += off;
            switch (text[i]) {
                '*', '_', '~' => i = try p.scanDelims(text, i, text[i], bottom),
                '`' => {
                    var cnt: usize = 1;
                    while (i + cnt < text.len and text[i + cnt] == '`') cnt += 1;
                    if (std.mem.indexOf(u8, text[i + cnt ..], text[i .. i + cnt])) |m| i += cnt + m + cnt else i += cnt;
                },
                '<' => {
                    const l = p.parseHtmlTag(text[i..]);
                    i += if (l > 0) l else 1;
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
                if (!plain) try writeAll(o, rep.text);
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
                    if (t_end > i) try writeAll(o, text[i..t_end]);
                    try writeAll(o, if (next - t_end >= 2) "<br>\n" else "\n");
                } else if (t_end > i) try writeAll(o, text[i..t_end]);
                i = next + 1;
                continue;
            }
            if (next > i) {
                var t_end = next;
                if (next == text.len) while (t_end > i and text[t_end - 1] == ' ') {
                    t_end -= 1;
                };
                if (t_end > i) try writeAll(o, text[i..t_end]);
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
                        if (n == '\n') {
                            try writeAll(o, "<br>\n");
                            i += 2;
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
                    if (std.mem.indexOf(u8, text[i + cnt ..], text[i .. i + cnt])) |off| {
                        const j = i + cnt + off;
                        if (!plain) try writeAll(o, "<code>");
                        try p.esc(text[i + cnt .. j], o);
                        if (!plain) try writeAll(o, "</code>");
                        i = j + cnt;
                        h = true;
                    }
                },
                '[', '!' => {
                    const img = (c == '!');
                    if (!img or (i + 1 < text.len and text[i + 1] == '[')) {
                        const b_s = if (img) i + 2 else i + 1;
                        var b_e_o: ?usize = null;
                        var b_d: usize = 1;
                        var k = b_s;
                        while (k < text.len) : (k += 1) {
                            if (text[k] == '\\' and k + 1 < text.len) {
                                k += 1;
                                continue;
                            }
                            if (text[k] == ']') {
                                b_d -= 1;
                                if (b_d == 0) {
                                    b_e_o = k;
                                    break;
                                }
                            } else if (text[k] == '[') b_d += 1;
                        }
                        if (b_e_o) |b_e| {
                            if (b_e + 1 < text.len and text[b_e + 1] == '(') {
                                const p_s = b_e + 2;
                                var p_e_o: ?usize = null;
                                var p_d: usize = 1;
                                var m = p_s;
                                while (m < text.len) : (m += 1) {
                                    const ch = text[m];
                                    if (ch == '\\' and m + 1 < text.len and isAsciiPunct(text[m + 1])) {
                                        m += 1;
                                        continue;
                                    }
                                    if (ch == '(') p_d += 1 else if (ch == ')') {
                                        p_d -= 1;
                                        if (p_d == 0) {
                                            p_e_o = m;
                                            break;
                                        }
                                    }
                                }
                                if (p_e_o) |p_e| {
                                    var url = std.mem.trim(u8, text[b_e + 2 .. p_e], " \t\n");
                                    var tit: ?[]const u8 = null;
                                    if (url.len >= 2 and url[0] == '<' and url[url.len - 1] == '>') {
                                        url = url[1 .. url.len - 1];
                                    } else {
                                        if (std.mem.indexOfAny(u8, url, " \t\n")) |t_s| {
                                            const p_t = std.mem.trim(u8, url[t_s..], " \t\n");
                                            if (p_t.len >= 2 and ((p_t[0] == '"' and p_t[p_t.len - 1] == '"') or (p_t[0] == '\'' and p_t[p_t.len - 1] == '\'') or (p_t[0] == '(' and p_t[p_t.len - 1] == ')'))) {
                                                url = url[0..t_s];
                                                tit = p_t[1 .. p_t.len - 1];
                                            }
                                        }
                                    }
                                    if (plain) {
                                        try p.parseInlineContentDepth(text[b_s..b_e], o, depth + 1, g_off + b_s, true);
                                    } else {
                                        try writeAll(o, if (img) "<img src=\"" else "<a href=\"");
                                        var u: usize = 0;
                                        while (u < url.len) : (u += 1) {
                                            var ch = url[u];
                                            if (ch == '\\' and u + 1 < url.len and isAsciiPunct(url[u + 1])) {
                                                u += 1;
                                                ch = url[u];
                                            }
                                            if (ch == '\\') try writeAll(o, "%5C") else if (html_escape_map[ch]) |e| {
                                                try writeAll(o, e);
                                            } else try writeByte(o, ch);
                                        }
                                        try writeByte(o, '"');
                                        if (tit) |t| {
                                            try writeAll(o, " title=\"");
                                            try p.esc(t, o);
                                            try writeByte(o, '"');
                                        }
                                        if (img) {
                                            try writeAll(o, " alt=\"");
                                            try p.parseInlineContentDepth(text[b_s..b_e], o, depth + 1, g_off + b_s, true);
                                            try writeAll(o, "\">");
                                        } else {
                                            try writeAll(o, ">");
                                            try p.parseInlineContentDepth(text[b_s..b_e], o, depth + 1, g_off + b_s, false);
                                            try writeAll(o, "</a>");
                                        }
                                    }
                                    i = p_e + 1;
                                    h = true;
                                }
                            }
                        }
                    }
                },
                '<' => {
                    if (i + 1 < text.len) {
                        if (std.mem.indexOfScalar(u8, text[i + 1 ..], '>')) |off| {
                            const lc = text[i + 1 .. i + 1 + off];
                            if (std.mem.indexOfAny(u8, lc, " \t\n") == null) {
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
                                if (al and std.mem.indexOfAny(u8, lc, " \t\n") != null) al = false;
                                if (al) {
                                    if (!plain) {
                                        try writeAll(o, "<a href=\"");
                                        if (em_l) try writeAll(o, "mailto:");
                                        for (lc) |ch| {
                                            if (ch == '\\') try writeAll(o, "%5C") else if (ch == '[') try writeAll(o, "%5B") else if (ch == ']') try writeAll(o, "%5D") else if (html_escape_map[ch]) |e| try writeAll(o, e) else try writeByte(o, ch);
                                        }
                                        try writeAll(o, "\">");
                                    }
                                    try p.esc(lc, o);
                                    if (!plain) try writeAll(o, "</a>");
                                    i += off + 2;
                                    h = true;
                                }
                            }
                        }
                    }
                    if (!h and p.options.enable_html) {
                        const l = p.parseHtmlTag(text[i..]);
                        if (l > 0) {
                            if (!plain) try writeAll(o, text[i .. i + l]);
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
                        if (!plain) try writeAll(o, "<span class=\"math\">");
                        try p.esc(text[i + 1 .. j], o);
                        if (!plain) try writeAll(o, "</span>");
                        i = j + 1;
                        h = true;
                    }
                },
                '&' => {
                    var j = i + 1;
                    var decoded: [4]u8 = undefined;
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
                            const cp = std.fmt.parseInt(u21, text[cp_s..j], b) catch 0;
                            if (cp > 0) decoded_len = std.unicode.utf8Encode(@intCast(cp), &decoded) catch 0;
                            if (decoded_len > 0) {
                                try p.esc(decoded[0..decoded_len], o);
                                i = j + 1;
                                h = true;
                            }
                        }
                    } else {
                        while (j < text.len and std.ascii.isAlphanumeric(text[j])) : (j += 1) {}
                        if (j > i + 1 and j < text.len and text[j] == ';') {
                            const en = text[i + 1 .. j];
                            const d: ?[]const u8 = switch (en.len) {
                                2 => if (std.mem.eql(u8, en, "lt")) "<" else if (std.mem.eql(u8, en, "gt")) ">" else null,
                                3 => if (std.mem.eql(u8, en, "amp")) "&" else null,
                                4 => if (std.mem.eql(u8, en, "quot")) "\"" else if (std.mem.eql(u8, en, "apos")) "'" else if (std.mem.eql(u8, en, "copy")) "©" else if (std.mem.eql(u8, en, "nbsp")) "\u{00A0}" else null,
                                5 => if (std.mem.eql(u8, en, "ndash")) "–" else if (std.mem.eql(u8, en, "mdash")) "—" else null,
                                else => null,
                            };
                            if (d) |v| {
                                try p.esc(v, o);
                                i = j + 1;
                                h = true;
                            }
                        }
                    }
                    if (!h) {
                        try writeAll(o, "&amp;");
                        i += 1;
                        h = true;
                    }
                },
                '>', '"', '\'' => {
                    try writeAll(o, html_escape_map[c].?);
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
            if (em) if (html_escape_map[ec]) |e| try writeAll(o, e) else try writeByte(o, ec);
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
        if (leading_spaces >= required_indent and bt != .paragraph and bt != .table and bt != .code and bt != .math and bt != .indented_code) {
            try parser.closeP(output);
            try parser.pushBlock(.indented_code, 0);
            parser.pending_code_blank_lines.clearRetainingCapacity();
            try writeAll(output, "<pre><code>");
            const extra_spaces = leading_spaces - required_indent;
            var pad: usize = 0;
            while (pad < extra_spaces) : (pad += 1) {
                try writeByte(output, ' ');
            }
            try parser.esc(line_content, output);
            try writeByte(output, '\n');
            return true;
        }
        return false;
    }

    fn processLeafBlockContinuation(parser: *OctomarkParser, line: []const u8, output: anytype) !bool {
        const _s = parser.startCall(.processLeafBlockContinuation);
        defer parser.endCall(.processLeafBlockContinuation, _s);

        const top = parser.topT() orelse return false;
        if (top != .code and top != .math and top != .indented_code) return false;

        var text_slice = line;
        var extra_indent_columns: usize = 0;
        var prefix_spaces: usize = 0;
        var i: usize = 0;
        while (i < parser.stack_depth) : (i += 1) {
            const block = parser.block_stack[i];
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
                    return false;
                }
            }
        }

        const trimmed = std.mem.trimLeft(u8, text_slice, &std.ascii.whitespace);

        if (top == .code) {
            if (trimmed.len >= 3 and (std.mem.eql(u8, trimmed[0..3], "```") or std.mem.eql(u8, trimmed[0..3], "~~~"))) {
                try parser.renderTop(output);
                return true;
            }
        } else if (top == .math) {
            if (trimmed.len >= 2 and std.mem.eql(u8, trimmed[0..2], "$$")) {
                try parser.renderTop(output);
                return true;
            }
        } else if (top == .indented_code) {
            const indent = leadingIndent(text_slice);
            const spaces = indent.columns + extra_indent_columns;
            const is_blank = (indent.idx == text_slice.len);
            if (is_blank) {
                const extra = if (spaces > 4) spaces - 4 else 0;
                try parser.pending_code_blank_lines.append(parser.allocator, extra);
                return true;
            }
            if (spaces < 4) {
                parser.pending_code_blank_lines.clearRetainingCapacity();
                try parser.renderTop(output);
                return false;
            }
            if (parser.pending_code_blank_lines.items.len > 0) {
                for (parser.pending_code_blank_lines.items) |extra| {
                    var pad: usize = 0;
                    while (pad < extra) : (pad += 1) {
                        try writeByte(output, ' ');
                    }
                    try writeByte(output, '\n');
                }
                parser.pending_code_blank_lines.clearRetainingCapacity();
            }
            prefix_spaces = spaces - 4;
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
            try writeByte(output, ' ');
        }
        try parser.esc(text_slice, output);
        try writeByte(output, '\n');
        return true;
    }

    fn parseFencedCodeBlock(parser: *OctomarkParser, line_content: []const u8, leading_spaces: usize, output: anytype) !bool {
        const _s = parser.startCall(.parseFencedCodeBlock);
        defer parser.endCall(.parseFencedCodeBlock, _s);
        if (leading_spaces > 3) return false;
        const content = std.mem.trimLeft(u8, line_content, " ");
        const extra_spaces = line_content.len - content.len;

        if (content.len >= 3 and (std.mem.eql(u8, content[0..3], "```") or std.mem.eql(u8, content[0..3], "~~~"))) {
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
            try writeAll(output, "<pre><code");
            var lang_len: usize = 0;
            while (3 + lang_len < content.len and !std.ascii.isWhitespace(content[3 + lang_len])) : (lang_len += 1) {}
            if (lang_len > 0) {
                try writeAll(output, " class=\"language-");
                try parser.esc(content[3 .. 3 + lang_len], output);
                try writeAll(output, "\"");
            }
            try writeAll(output, ">");
            try parser.pushBlock(.code, @intCast(leading_spaces + extra_spaces));
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
            try writeAll(output, "<div class=\"math\">\n");
            try parser.pushBlock(.math, @intCast(leading_spaces + extra_spaces));

            const remainder = content[2..];
            const trimmed_rem = std.mem.trim(u8, remainder, " \t");
            if (trimmed_rem.len > 0) {
                if (trimmed_rem.len >= 2 and std.mem.eql(u8, trimmed_rem[trimmed_rem.len - 2 ..], "$$")) {
                    const math_content = std.mem.trim(u8, trimmed_rem[0 .. trimmed_rem.len - 2], " \t");
                    try parser.esc(math_content, output);
                    try writeByte(output, '\n');
                    try parser.renderTop(output);
                } else {
                    try parser.esc(remainder, output);
                    try writeByte(output, '\n');
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
            while (content_start < line_content.len and (line_content[content_start] == ' ' or line_content[content_start] == '\t')) : (content_start += 1) {}

            var end = line_content.len;
            while (end > content_start and (line_content[end - 1] == ' ' or line_content[end - 1] == '\t')) : (end -= 1) {}
            if (end > content_start) {
                var hash_end = end;
                while (hash_end > content_start and line_content[hash_end - 1] == '#') : (hash_end -= 1) {}
                if (hash_end < end) {
                    if (hash_end == content_start) end = content_start;
                    var space_end = hash_end;
                    while (space_end > content_start and (line_content[space_end - 1] == ' ' or line_content[space_end - 1] == '\t')) : (space_end -= 1) {}
                    if (space_end < hash_end) end = space_end;
                }
            }

            try parser.tryCloseLeaf(output);
            const level_char: u8 = '0' + @as(u8, @intCast(level));
            try writeAll(output, "<h");
            try writeByte(output, level_char);
            try writeAll(output, ">");
            try parser.parseInlineContent(line_content[content_start..end], output);
            try writeAll(output, "</h");
            try writeByte(output, level_char);
            try writeAll(output, ">\n");
            return true;
        }
        return false;
    }

    fn parseHorizontalRule(parser: *OctomarkParser, line_content: []const u8, leading_spaces: usize, output: anytype) !bool {
        const _s = parser.startCall(.parseHorizontalRule);
        defer parser.endCall(.parseHorizontalRule, _s);
        if (leading_spaces <= 3 and isThematicBreakLine(line_content)) {
            try parser.tryCloseLeaf(output);
            try writeAll(output, "<hr>\n");
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
                try writeAll(output, "<dl>\n");
                try parser.pushBlock(.definition_list, @intCast(leading_spaces.*));
            }
            if (in_dd) {
                while (parser.topT() != .definition_list and parser.stack_depth > 0) {
                    try parser.renderTop(output);
                }
            }
            try writeAll(output, "<dd>");
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

        if (parser.pending_loose_idx) |idx| {
            if (idx < parser.stack_depth) {
                parser.block_stack[idx].loose = true;
                if (parser.paragraph_content.items.len > 0) {
                    try writeAll(output, "<p>");
                    try parser.parseInlineContent(parser.paragraph_content.items, output);
                    parser.paragraph_content.clearRetainingCapacity();
                    try writeAll(output, "</p>\n");
                }
            }
            parser.pending_loose_idx = null;
        }
        if (leading_spaces.* >= 4) {
            var has_list = false;
            var i: usize = 0;
            while (i < parser.stack_depth) : (i += 1) {
                const bt = parser.block_stack[i].block_type;
                if (bt == .unordered_list or bt == .ordered_list) {
                    has_list = true;
                    break;
                }
            }
            if (!has_list) return false;
        }

        const trimmed_line = std.mem.trimLeft(u8, line, " ");
        const internal_spaces = line.len - trimmed_line.len;

        // Unordered list marker: -, *, +
        var is_ul = false;
        var marker_bytes: usize = 0;
        var marker_columns: usize = 0;
        var marker_extra_columns: usize = 0;
        if (line.len - internal_spaces >= 2) {
            const m = line[internal_spaces];
            if (m == '-' or m == '*' or m == '+') {
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

        const is_ol = (line.len - internal_spaces >= 3 and std.ascii.isDigit(line[internal_spaces]) and
            line[internal_spaces + 1] == '.' and (line[internal_spaces + 2] == ' ' or line[internal_spaces + 2] == '\t'));

        if (is_ol) {
            const next = line[internal_spaces + 2];
            const base_col = leading_spaces.* + internal_spaces + 2;
            const tab_width: usize = if (next == '\t') 4 - (base_col % 4) else 1;
            marker_bytes = 3;
            marker_columns = 3;
            if (next == '\t' and tab_width > 0) marker_extra_columns = tab_width - 1;
        }

        if (is_ul or is_ol) {
            var remainder = line[internal_spaces + marker_bytes ..];
            // Don't fully trim here, just consume leading space for content
            if (remainder.len > 0 and remainder[0] == ' ') remainder = remainder[1..];
            if (remainder.len == 0) {
                line_content.* = "";
                return true;
            }

            const target_type: BlockType = if (is_ul) .unordered_list else .ordered_list;
            const current_indent: i32 = @intCast(leading_spaces.* + internal_spaces);
            while (parser.stack_depth > 0 and
                parser.topT() != null and @intFromEnum(parser.topT().?) < @intFromEnum(BlockType.blockquote) and
                (parser.block_stack[parser.stack_depth - 1].indent_level > current_indent or
                    (parser.block_stack[parser.stack_depth - 1].indent_level == current_indent and parser.topT() != target_type)))
            {
                try parser.renderTop(output);
            }

            const top = parser.topT();
            const list_loose = (top == .unordered_list or top == .ordered_list) and parser.block_stack[parser.stack_depth - 1].loose;
            if (top == target_type and parser.block_stack[parser.stack_depth - 1].indent_level == current_indent) {
                const block_type = parser.topT();
                if (block_type == .paragraph or block_type == .table or block_type == .code or block_type == .math) {
                    try parser.renderTop(output);
                }
                if (parser.paragraph_content.items.len > 0) {
                    if (list_loose and parser.topT() != .paragraph) {
                        try writeAll(output, "<p>");
                        try parser.parseInlineContent(parser.paragraph_content.items, output);
                        parser.paragraph_content.clearRetainingCapacity();
                        try writeAll(output, "</p>\n");
                    } else {
                        try parser.parseInlineContent(parser.paragraph_content.items, output);
                        parser.paragraph_content.clearRetainingCapacity();
                    }
                }
                try writeAll(output, "</li>\n<li>");
            } else {
                const block_type = parser.topT();
                if (block_type == .paragraph or block_type == .table or block_type == .code or block_type == .math) {
                    try parser.renderTop(output);
                }
                if (parser.paragraph_content.items.len > 0) {
                    if (list_loose and parser.topT() != .paragraph) {
                        try writeAll(output, "<p>");
                        try parser.parseInlineContent(parser.paragraph_content.items, output);
                        parser.paragraph_content.clearRetainingCapacity();
                        try writeAll(output, "</p>\n");
                    } else {
                        try parser.parseInlineContent(parser.paragraph_content.items, output);
                        parser.paragraph_content.clearRetainingCapacity();
                    }
                }
                try writeAll(output, if (target_type == .unordered_list) "<ul>\n<li>" else "<ol>\n<li>");
                try parser.pushBlock(target_type, current_indent);
            }

            const base_indent = leading_spaces.* + internal_spaces + marker_columns;
            leading_spaces.* = base_indent + marker_extra_columns;
            var item_content_indent = base_indent;
            if (remainder.len >= 3 and remainder[0] == '[' and (remainder[1] == ' ' or remainder[1] == 'x' or remainder[1] == 'X') and remainder[2] == ']') {
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
            line_content.* = remainder;
            return true;
        }
        return false;
    }

    fn parseTable(parser: *OctomarkParser, line_content: []const u8, full_data: []const u8, current_pos: usize, output: anytype) !bool {
        const _s = parser.startCall(.parseTable);
        defer parser.endCall(.parseTable, _s);
        // 1. If we are already IN a table, process body rows strictly.
        if (parser.topT() == .table) {
            const trimmed_line = std.mem.trim(u8, line_content, &std.ascii.whitespace);
            // Quick pipe check for body row
            const has_pipe = std.mem.indexOfScalar(u8, trimmed_line, '|') != null;

            if (has_pipe) {
                var body_cells: [64][]const u8 = undefined;
                const body_count = parser.splitTableRowCells(line_content, &body_cells);
                try writeAll(output, "<tr>");
                var k: usize = 0;
                while (k < body_count) : (k += 1) {
                    try writeAll(output, "<td");
                    writeTableAlignment(output, if (k < parser.table_column_count) parser.table_alignments[k] else .none) catch {};
                    try writeAll(output, ">");
                    try parser.parseInlineContent(body_cells[k], output);
                    try writeAll(output, "</td>");
                }
                try writeAll(output, "</tr>\n");
                return true;
            } else {
                // No pipe = end of table
                try parser.renderTop(output);
                // Continue to process this line as something else (return false)
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

        try writeAll(output, "<table><thead><tr>");
        k = 0;
        while (k < header_count) : (k += 1) {
            try writeAll(output, "<th");
            writeTableAlignment(output, parser.table_alignments[k]) catch {};
            try writeAll(output, ">");
            try parser.parseInlineContent(header_cells[k], output);
            try writeAll(output, "</th>");
        }
        try writeAll(output, "</tr></thead><tbody>\n");
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
                    try writeAll(output, "<dl>\n");
                    try parser.pushBlock(.definition_list, 0);
                }
                try writeAll(output, "<dt>");
                try parser.parseInlineContent(line_content, output);
                try writeAll(output, "</dt>\n");
                return true;
            }
        }
        return false;
    }

    fn processParagraph(parser: *OctomarkParser, line_content: []const u8, is_dl: bool, is_list: bool, output: anytype) !void {
        const _s = parser.startCall(.processParagraph);
        defer parser.endCall(.processParagraph, _s);

        if (parser.pending_loose_idx) |idx| {
            if (idx < parser.stack_depth) {
                parser.block_stack[idx].loose = true;
                if (parser.paragraph_content.items.len > 0) {
                    try writeAll(output, "<p>");
                    try parser.parseInlineContent(parser.paragraph_content.items, output);
                    parser.paragraph_content.clearRetainingCapacity();
                    try writeAll(output, "</p>\n");
                }
            }
            parser.pending_loose_idx = null;
        }

        if (line_content.len == 0) {
            try parser.closeP(output);
            return;
        }

        const block_type = parser.topT();
        const in_container = (parser.stack_depth > 0 and
            (block_type != null and
                (@intFromEnum(block_type.?) < @intFromEnum(BlockType.blockquote) or block_type.? == .definition_description)));
        var list_loose = false;
        if (parser.stack_depth > 0) {
            var i: usize = parser.stack_depth;
            while (i > 0) {
                i -= 1;
                const bt = parser.block_stack[i].block_type;
                if (bt == .unordered_list or bt == .ordered_list) {
                    list_loose = parser.block_stack[i].loose;
                    break;
                }
            }
        }

        if (parser.topT() != .paragraph and (!in_container or list_loose)) {
            try parser.pushBlock(.paragraph, 0);
        } else if (parser.topT() == .paragraph or (in_container and !is_list and !is_dl and !list_loose)) {
            try parser.paragraph_content.append(parser.allocator, '\n');
        }

        if (parser.pending_task_marker > 0) {
            try writeAll(output, if (parser.pending_task_marker == 2) "<input type=\"checkbox\" checked disabled> " else "<input type=\"checkbox\" disabled> ");
            parser.pending_task_marker = 0;
        }

        try parser.paragraph_content.appendSlice(parser.allocator, line_content);
    }

    fn isBSM(p: *OctomarkParser, s: []const u8, ls: usize) bool {
        _ = p;
        if (ls > 3 or s.len == 0) return false;
        if (isThematicBreakLine(s)) return true;
        return switch (s[0]) {
            '`' => s.len >= 3 and std.mem.startsWith(u8, s, "```"),
            '$' => s.len >= 2 and std.mem.startsWith(u8, s, "$$"),
            '#', '.', ':', '<', '|' => true,
            '-', '*', '_' => s.len >= 2 and (s[1] == ' ' or s[1] == '\t'),
            '0'...'9' => s.len >= 3 and std.mem.startsWith(u8, s[1..], ". "),
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
            const bt = p.topT();
            if (bt == .paragraph or bt == .table or bt == .code or bt == .math) try p.renderTop(o);
            var l_idx: ?usize = null;
            if (p.stack_depth > 0) {
                var i = p.stack_depth;
                while (i > 0) {
                    i -= 1;
                    if (p.block_stack[i].block_type == .unordered_list or p.block_stack[i].block_type == .ordered_list) {
                        l_idx = i;
                        break;
                    }
                }
            }
            if (l_idx) |idx| {
                p.pending_loose_idx = idx;
            }
            while (p.stack_depth > 0 and p.topT() != null and @intFromEnum(p.topT().?) >= @intFromEnum(BlockType.blockquote)) {
                try p.renderTop(o);
            }
            return false;
        }
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
        ls += ex_id;
        const p_id = leadingIndent(lc);
        ls += p_id.columns;
        lc = lc[p_id.idx..];
        var cur_q: usize = 0;
        for (p.block_stack[0..p.stack_depth]) |e| {
            if (e.block_type == .blockquote) cur_q += 1;
        }
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
        if (lc.len == 0 and q_lv > cur_q) return false;
        while (cur_q < q_lv) {
            if (p.topT() == .paragraph) {
                try p.closeP(o);
            } else if (p.paragraph_content.items.len > 0) {
                try p.parseInlineContent(p.paragraph_content.items, o);
                p.paragraph_content.clearRetainingCapacity();
            }
            try writeAll(o, "<blockquote>");
            try p.pushBlock(.blockquote, 0);
            cur_q += 1;
        }
        const is_dl = try p.parseDefinitionList(&lc, &ls, o);
        const is_list = try p.parseListItem(&lc, &ls, o);
        if ((is_dl or is_list) and lc.len > 0) {
            const ex = leadingIndent(lc);
            if (ex.idx > 0) {
                ls += ex.columns;
                lc = lc[ex.idx..];
            }
        }
        if (lc.len > 0) {
            var mi: usize = 0;
            while (mi < p.stack_depth) {
                const e = p.block_stack[mi];
                if (e.block_type == .unordered_list or e.block_type == .ordered_list) {
                    if (ls < @as(usize, @intCast(e.content_indent)) and !lazy and !is_list and !is_dl) {
                        while (p.stack_depth > mi) try p.renderTop(o);
                        break;
                    }
                }
                mi += 1;
            }
            if (ls <= 3 and isThematicBreakLine(lc)) {
                if (p.stack_depth > 0) {
                    var l_id: ?i32 = null;
                    var i = p.stack_depth;
                    while (i > 0) {
                        i -= 1;
                        if (p.block_stack[i].block_type == .unordered_list or p.block_stack[i].block_type == .ordered_list) {
                            l_id = p.block_stack[i].content_indent;
                            break;
                        }
                    }
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
            if (!lazy and p.topT() == .paragraph and ls <= 3) {
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
                            p.pop();
                            const lv: u8 = if (lc[st] == '=') '1' else '2';
                            try writeAll(o, "<h");
                            try writeByte(o, lv);
                            try writeAll(o, ">");
                            try p.parseInlineContent(tr, o);
                            try writeAll(o, "</h");
                            try writeByte(o, lv);
                            try writeAll(o, ">\n");
                            return false;
                        }
                    }
                }
            }
            switch (lc[0]) {
                '#' => if (try p.parseHeader(lc, ls, o)) return false,
                '`', '~' => if (try p.parseFencedCodeBlock(lc, ls, o)) return false,
                '$' => if (try p.parseMathBlock(lc, ls, o)) return false,
                '-', '*', '_' => if (try p.parseHorizontalRule(lc, ls, o)) return false,
                '|' => if (try p.parseTable(lc, full, pos, o)) return true,
                '>' => {
                    var q_c: usize = 0;
                    var l_c = lc;
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
                            try writeAll(o, "<blockquote>");
                            try p.pushBlock(.blockquote, 0);
                        }
                    }
                },
                '<' => if (lc.len >= 3 and ls <= 3) {
                    var h_t: u8 = 0;
                    if (lc.len >= 4 and lc[1] == '!') {
                        if (std.mem.startsWith(u8, lc, "<!--")) h_t = 2 else if (std.mem.startsWith(u8, lc, "<![CDATA[")) h_t = 5 else h_t = 4;
                    } else if (lc.len >= 2 and lc[1] == '?') h_t = 3 else {
                        const tr = if (lc[1] == '/') lc[2..] else lc[1..];
                        const t1 = [_][]const u8{ "script", "pre", "style" };
                        for (t1) |t| if (std.mem.startsWith(u8, tr, t)) {
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
                                "param",    "section",  "source",   "summary",    "table",    "tbody",      "td",     "tfoot",
                                "th",       "thead",    "title",    "tr",         "ul",
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
                        try p.renderTop(o);
                        try writeAll(o, lc);
                        try writeByte(o, '\n');
                        return true;
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
                while (i < len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_' or text[i] == '.' or text[i] == ':' or text[i] == '-')) : (i += 1) {}
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
                        if (std.ascii.isWhitespace(text[i]) or text[i] == '"' or text[i] == '\'' or text[i] == '=' or text[i] == '<' or text[i] == '>' or text[i] == '`') return 0;
                        while (i < len and !std.ascii.isWhitespace(text[i]) and text[i] != '"' and text[i] != '\'' and text[i] != '=' and text[i] != '<' and text[i] != '>' and text[i] != '`') : (i += 1) {}
                    }
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

    fn writeTableAlignment(output: anytype, align_type: TableAlignment) !void {
        try switch (align_type) {
            .left => writeAll(output, " style=\"text-align:left\""),
            .center => writeAll(output, " style=\"text-align:center\""),
            .right => writeAll(output, " style=\"text-align:right\""),
            .none => {},
        };
    }
};
