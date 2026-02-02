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
    math,
    table,
    paragraph,
};

const block_close_tags = blk: {
    var tags: [std.enums.values(BlockType).len][]const u8 = undefined;
    tags[@intFromEnum(BlockType.unordered_list)] = "</li>\n</ul>\n";
    tags[@intFromEnum(BlockType.ordered_list)] = "</li>\n</ol>\n";
    tags[@intFromEnum(BlockType.blockquote)] = "</blockquote>\n";
    tags[@intFromEnum(BlockType.definition_list)] = "</dl>\n";
    tags[@intFromEnum(BlockType.definition_description)] = "</dd>\n";
    tags[@intFromEnum(BlockType.code)] = "</code></pre>\n";
    tags[@intFromEnum(BlockType.math)] = "</div>\n";
    tags[@intFromEnum(BlockType.table)] = "</tbody></table>\n";
    tags[@intFromEnum(BlockType.paragraph)] = "</p>\n";
    break :blk tags;
};

const TableAlignment = enum {
    none,
    left,
    center,
    right,
};

const BlockEntry = struct {
    block_type: BlockType,
    indent_level: i32,
};

const Buffer = std.ArrayListUnmanaged(u8);
const AllocError = std.mem.Allocator.Error;
const ParseError = AllocError || std.fs.File.WriteError || error{ NestingTooDeep, TooManyTableColumns };

/// Parser configuration options.
pub const OctomarkOptions = struct {
    enable_html: bool = false,
};

const special_chars = "\\['*`&<>\"'_~!$h";

const html_escape_map = blk: {
    var map: [256]?[]const u8 = [_]?[]const u8{null} ** 256;
    map['&'] = "&amp;";
    map['<'] = "&lt;";
    map['>'] = "&gt;";
    map['\"'] = "&quot;";
    map['\''] = "&#39;";
    break :blk map;
};

pub const OctomarkParser = struct {
    table_alignments: [64]TableAlignment = [_]TableAlignment{TableAlignment.none} ** 64,
    table_column_count: usize = 0,
    block_stack: [MAX_BLOCK_NESTING]BlockEntry = undefined,
    stack_depth: usize = 0,
    pending_buffer: Buffer = .{},
    options: OctomarkOptions = .{},
    stats: if (builtin.mode == .Debug) Stats else struct {} = .{},
    timer: if (builtin.mode == .Debug) std.time.Timer else struct {} = undefined,

    const Stats = struct {
        const Counter = struct {
            count: usize = 0,
            time_ns: u64 = 0,
        };
        feed: Counter = .{},
        processSingleLine: Counter = .{},
        parseInlineContent: Counter = .{},
        parseHeader: Counter = .{},
        parseHorizontalRule: Counter = .{},
        parseFencedCodeBlock: Counter = .{},
        parseMathBlock: Counter = .{},
        parseListItem: Counter = .{},
        parseTable: Counter = .{},
        parseDefinitionList: Counter = .{},
        parseDefinitionTerm: Counter = .{},
        appendEscapedText: Counter = .{},
        findNextSpecial: Counter = .{},
        renderAndCloseTopBlock: Counter = .{},
        pushBlock: Counter = .{},
        popBlock: Counter = .{},
        parseHtmlTag: Counter = .{},
        splitTableRowCells: Counter = .{},
        isBlockStartMarker: Counter = .{},
        isNextLineTableSeparator: Counter = .{},
    };

    inline fn startCall(self: *OctomarkParser, comptime field: std.meta.FieldEnum(Stats)) u64 {
        if (builtin.mode == .Debug) {
            @field(self.stats, @tagName(field)).count += 1;
            return self.timer.read();
        }
        return 0;
    }

    inline fn endCall(self: *OctomarkParser, comptime field: std.meta.FieldEnum(Stats), start_ns: u64) void {
        if (builtin.mode == .Debug) {
            @field(self.stats, @tagName(field)).time_ns += self.timer.read() - start_ns;
        }
    }

    /// Initialize parser state. Returns error.OutOfMemory on allocation failure.
    pub fn init(self: *OctomarkParser, allocator: std.mem.Allocator) !void {
        self.* = OctomarkParser{};
        if (builtin.mode == .Debug) {
            self.timer = try std.time.Timer.start();
        }
        self.pending_buffer = .{};
        try self.pending_buffer.ensureTotalCapacity(allocator, 4096);
        self.options = .{};
    }

    /// Release parser-owned buffers. Safe to call after any error.
    pub fn deinit(self: *OctomarkParser, allocator: std.mem.Allocator) void {
        self.pending_buffer.deinit(allocator);
    }

    /// Enable parsing options.
    pub fn setOptions(self: *OctomarkParser, options: OctomarkOptions) void {
        self.options = options;
    }

    /// Feed a chunk into the parser. Returns error.OutOfMemory or writer errors.
    pub fn parse(self: *OctomarkParser, reader: anytype, writer: anytype, allocator: std.mem.Allocator) !void {
        var buffer: [4096]u8 = undefined;
        const ReaderType = @TypeOf(reader);
        const reader_child = if (@typeInfo(ReaderType) == .pointer) std.meta.Child(ReaderType) else ReaderType;
        const has_interface = @hasField(reader_child, "interface");

        while (true) {
            const n = if (has_interface)
                try reader.interface.readSliceShort(&buffer)
            else if (@hasDecl(reader_child, "read"))
                try reader.read(&buffer)
            else
                try reader.readSliceShort(&buffer);
            if (n == 0) break;
            try self.feed(buffer[0..n], writer, allocator);
        }
        try self.finish(writer);
    }

    pub fn dumpStats(self: *const OctomarkParser) void {
        if (builtin.mode == .Debug) {
            std.debug.print("\n--- Octomark Debug Stats (per function) ---\n", .{});
            std.debug.print("{s: <25} | {s: >10} | {s: >15} | {s: >15}\n", .{ "Function", "Calls", "Total Time", "Avg Call" });
            std.debug.print("--------------------------|------------|-----------------|----------------\n", .{});
            inline for (std.meta.fields(Stats)) |f| {
                const counter = @field(self.stats, f.name);
                const total_ms = @as(f64, @floatFromInt(counter.time_ns)) / 1_000_000.0;
                const avg_ns = if (counter.count > 0) counter.time_ns / counter.count else 0;
                std.debug.print("{s: <25} | {d: >10} | {d: >12.3} ms | {d: >12.3} ns\n", .{
                    f.name,
                    counter.count,
                    total_ms,
                    @as(f64, @floatFromInt(avg_ns)),
                });
            }
            std.debug.print("-------------------------------------------\n", .{});
        }
    }

    // Writer helpers for File.Writer/GenericWriter compatibility
    inline fn hasWriterInterface(comptime WriterType: type) bool {
        const writer_child = if (@typeInfo(WriterType) == .pointer) std.meta.Child(WriterType) else WriterType;
        return @hasField(writer_child, "interface");
    }

    inline fn writeAll(writer: anytype, bytes: []const u8) !void {
        if (comptime hasWriterInterface(@TypeOf(writer))) {
            try writer.interface.writeAll(bytes);
        } else {
            try writer.writeAll(bytes);
        }
    }

    inline fn writeByte(writer: anytype, byte: u8) !void {
        if (comptime hasWriterInterface(@TypeOf(writer))) {
            try writer.interface.writeByte(byte);
        } else {
            try writer.writeByte(byte);
        }
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
        if (self.pending_buffer.items.len > 0) {
            _ = try self.processSingleLine(
                self.pending_buffer.items[0..self.pending_buffer.items.len],
                self.pending_buffer.items,
                self.pending_buffer.items.len,
                output,
            );
        }
        while (self.stack_depth > 0) try self.renderAndCloseTopBlock(output);
    }

    fn pushBlock(parser: *OctomarkParser, block_type: BlockType, indent: i32) !void {
        const _s = parser.startCall(.pushBlock);
        defer parser.endCall(.pushBlock, _s);
        if (parser.stack_depth >= MAX_BLOCK_NESTING) return error.NestingTooDeep;
        parser.block_stack[parser.stack_depth] = BlockEntry{ .block_type = block_type, .indent_level = indent };
        parser.stack_depth += 1;
    }

    fn popBlock(parser: *OctomarkParser) void {
        const _s = parser.startCall(.popBlock);
        defer parser.endCall(.popBlock, _s);
        std.debug.assert(parser.stack_depth <= MAX_BLOCK_NESTING);
        if (parser.stack_depth > 0) parser.stack_depth -= 1;
    }

    fn currentBlockType(parser: *const OctomarkParser) ?BlockType {
        if (parser.stack_depth == 0) return null;
        return parser.block_stack[parser.stack_depth - 1].block_type;
    }

    fn renderAndCloseTopBlock(parser: *OctomarkParser, output: anytype) !void {
        const _s = parser.startCall(.renderAndCloseTopBlock);
        defer parser.endCall(.renderAndCloseTopBlock, _s);
        if (parser.stack_depth == 0) return;
        const block_type = parser.block_stack[parser.stack_depth - 1].block_type;
        parser.popBlock();
        try writeAll(output, block_close_tags[@intFromEnum(block_type)]);
    }

    fn closeParagraphIfOpen(parser: *OctomarkParser, output: anytype) !void {
        if (parser.currentBlockType() == .paragraph) try parser.renderAndCloseTopBlock(output);
    }

    fn tryCloseLeafBlock(parser: *OctomarkParser, output: anytype) !void {
        const bt = parser.currentBlockType() orelse return;
        if (@intFromEnum(bt) >= @intFromEnum(BlockType.code)) try parser.renderAndCloseTopBlock(output);
    }

    fn appendEscapedText(parser: *const OctomarkParser, text: []const u8, output: anytype) !void {
        const _s = @constCast(parser).startCall(.appendEscapedText);
        defer @constCast(parser).endCall(.appendEscapedText, _s);
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const entity = html_escape_map[text[i]];
            if (entity) |value| {
                try writeAll(output, value);
            } else {
                try writeByte(output, text[i]);
            }
        }
    }

    fn findNextSpecial(parser: *OctomarkParser, text: []const u8, start: usize) usize {
        const _s = parser.startCall(.findNextSpecial);
        defer parser.endCall(.findNextSpecial, _s);
        if (start >= text.len) return text.len;
        if (std.mem.indexOfAny(u8, text[start..], special_chars)) |offset| {
            return start + offset;
        }
        return text.len;
    }

    fn parseInlineContent(parser: *OctomarkParser, text: []const u8, output: anytype) !void {
        return parser.parseInlineContentDepth(text, output, 0);
    }

    fn parseInlineContentDepth(parser: *OctomarkParser, text: []const u8, output: anytype, depth: usize) !void {
        const _s = parser.startCall(.parseInlineContent);
        defer parser.endCall(.parseInlineContent, _s);
        var i: usize = 0;
        while (i < text.len) {
            const start = i;
            i = parser.findNextSpecial(text, i);

            if (i > start) try writeAll(output, text[start..i]);
            if (i >= text.len) break;

            const c = text[i];

            // Backslash escape or line break
            if (c == '\\') {
                if (i + 1 < text.len) {
                    if (std.ascii.isAlphanumeric(text[i + 1])) {
                        try writeByte(output, '\\');
                        i += 1;
                        continue;
                    }
                    i += 1;
                    try writeByte(output, text[i]);
                    i += 1;
                    continue;
                } else {
                    try writeAll(output, "<br>");
                    i += 1;
                    continue;
                }
            }

            // Paired delimiters: **bold**, _italic_, ~~strikethrough~~
            const delims = [_]struct { tag: []const u8, marker: []const u8 }{
                .{ .tag = "strong", .marker = "**" },
                .{ .tag = "em", .marker = "_" },
                .{ .tag = "del", .marker = "~~" },
            };

            var handled = false;
            for (delims) |d| {
                if (std.mem.startsWith(u8, text[i..], d.marker)) {
                    if (std.mem.indexOf(u8, text[i + d.marker.len ..], d.marker)) |offset| {
                        const j = i + d.marker.len + offset;
                        if (depth + 1 <= MAX_INLINE_NESTING) {
                            try writeAll(output, "<");
                            try writeAll(output, d.tag);
                            try writeAll(output, ">");
                            try parser.parseInlineContentDepth(text[i + d.marker.len .. j], output, depth + 1);
                            try writeAll(output, "</");
                            try writeAll(output, d.tag);
                            try writeAll(output, ">");
                            i = j + d.marker.len;
                            handled = true;
                            break;
                        }
                    }
                }
            }
            if (handled) continue;

            // Code: `text`
            if (c == '`') {
                var code_end: ?usize = null;
                var backtick_count: usize = 1;
                while (i + backtick_count < text.len and text[i + backtick_count] == '`') {
                    backtick_count += 1;
                }

                if (std.mem.indexOf(u8, text[i + backtick_count ..], text[i .. i + backtick_count])) |offset| {
                    const j = i + backtick_count + offset;
                    code_end = j;
                }

                if (code_end) |j| {
                    const content = text[i + backtick_count .. j];

                    try writeAll(output, "<code>");
                    try parser.appendEscapedText(content, output);
                    try writeAll(output, "</code>");
                    i = j + backtick_count;
                    continue;
                }
            }

            // Link: [text](url) or Image: ![text](url)
            if (c == '[' or (c == '!' and i + 1 < text.len and text[i + 1] == '[')) {
                const is_image = (c == '!');
                const bracket_start = if (is_image) i + 2 else i + 1;

                var bracket_end_opt: ?usize = null;
                var bracket_depth: usize = 1;
                var k = bracket_start;
                while (k < text.len) : (k += 1) {
                    if (text[k] == '\\' and k + 1 < text.len) {
                        k += 1;
                        continue;
                    }
                    if (text[k] == ']') {
                        bracket_depth -= 1;
                        if (bracket_depth == 0) {
                            bracket_end_opt = k;
                            break;
                        }
                    } else if (text[k] == '[') {
                        bracket_depth += 1;
                    }
                }

                if (bracket_end_opt) |bracket_end| {
                    if (bracket_end + 1 < text.len and text[bracket_end + 1] == '(') {
                        if (std.mem.indexOfScalar(u8, text[bracket_end + 2 ..], ')')) |paren_offset| {
                            const paren_end = bracket_end + 2 + paren_offset;
                            const label = text[bracket_start..bracket_end];
                            const url = text[bracket_end + 2 .. paren_end];

                            if (is_image) {
                                try writeAll(output, "<img src=\"");
                                try writeAll(output, url);
                                try writeAll(output, "\" alt=\"");
                                var m: usize = 0;
                                while (m < label.len) : (m += 1) {
                                    if (label[m] == '\\' and m + 1 < label.len) {
                                        m += 1;
                                        try writeByte(output, label[m]);
                                    } else {
                                        try writeByte(output, label[m]);
                                    }
                                }
                                try writeAll(output, "\">");
                                i = paren_end + 1;
                                continue;
                            } else {
                                if (depth + 1 <= MAX_INLINE_NESTING) {
                                    try writeAll(output, "<a href=\"");
                                    try writeAll(output, url);
                                    try writeAll(output, "\">");
                                    try parser.parseInlineContentDepth(label, output, depth + 1);
                                    try writeAll(output, "</a>");
                                    i = paren_end + 1;
                                    continue;
                                }
                            }
                        }
                    }
                }
            }

            // Angle bracket autolink: <http://...>
            if (c == '<' and i + 1 < text.len) {
                // Check if it looks like a URI or email
                const scheme_end = std.mem.indexOfScalar(u8, text[i + 1 ..], ':');
                if (scheme_end) |offset| {
                    const scheme_len = offset;
                    // basic heuristic for scheme
                    var is_scheme = true;
                    var si: usize = 0;
                    while (si < scheme_len) : (si += 1) {
                        const sc = text[i + 1 + si];
                        if (!std.ascii.isAlphanumeric(sc) and sc != '+' and sc != '.' and sc != '-') {
                            is_scheme = false;
                            break;
                        }
                    }
                    if (is_scheme) {
                        // find closing >
                        if (std.mem.indexOfScalar(u8, text[i + 1 ..], '>')) |end_offset| {
                            const link_content = text[i + 1 .. i + 1 + end_offset];
                            // check for space
                            if (std.mem.indexOfAny(u8, link_content, " \t\n") == null) {
                                try writeAll(output, "<a href=\"");
                                try writeAll(output, link_content);
                                try writeAll(output, "\">");
                                try writeAll(output, link_content);
                                try writeAll(output, "</a>");
                                i = i + 1 + end_offset + 1;
                                continue;
                            }
                        }
                    }
                }
            }

            // Auto-link: http:// or https:// (raw)
            if (c == 'h' and i + 4 < text.len and (std.mem.startsWith(u8, text[i..], "http:") or std.mem.startsWith(u8, text[i..], "https:"))) {
                var k = i;
                while (k < text.len and !std.ascii.isWhitespace(text[k]) and text[k] != '<' and text[k] != '>') : (k += 1) {}

                while (k > i) {
                    const last = text[k - 1];
                    if (last == ')' or last == '.' or last == ',' or last == ';' or last == '?' or last == '!') {
                        k -= 1;
                    } else {
                        break;
                    }
                }

                const url = text[i..k];
                try writeAll(output, "<a href=\"");
                try writeAll(output, url);
                try writeAll(output, "\">");
                try writeAll(output, url);
                try writeAll(output, "</a>");
                i = k;
                continue;
            }

            // Math: $text$
            if (c == '$') {
                var math_end: ?usize = null;
                var k = i + 1;
                while (k < text.len) : (k += 1) {
                    if (text[k] == '\\' and k + 1 < text.len) {
                        k += 1;
                        continue;
                    }
                    if (text[k] == '$') {
                        math_end = k;
                        break;
                    }
                }

                if (math_end) |j| {
                    try writeAll(output, "<span class=\"math\">");
                    try parser.appendEscapedText(text[i + 1 .. j], output);
                    try writeAll(output, "</span>");
                    i = j + 1;
                    continue;
                }
            }

            // HTML tag (if enabled)
            if (c == '<' and parser.options.enable_html) {
                const tag_len = parser.parseHtmlTag(text[i..]);
                if (tag_len > 0) {
                    try writeAll(output, text[i .. i + tag_len]);
                    i += tag_len;
                    continue;
                }
            }

            // Default: escape or output as-is
            const entity = html_escape_map[text[i]];
            if (entity) |value| {
                try writeAll(output, value);
            } else {
                try writeByte(output, text[i]);
            }
            i += 1;
        }
    }

    fn processLeafBlockContinuation(parser: *OctomarkParser, line: []const u8, output: anytype) !bool {
        const top = parser.currentBlockType();
        if (top != .code and top != .math) return false;

        var text_slice = line;
        var i: usize = 0;
        while (i < parser.stack_depth) : (i += 1) {
            const block = parser.block_stack[i];
            if (block.block_type == .blockquote) {
                const trimmed = std.mem.trimLeft(u8, text_slice, " \t");
                if (trimmed.len > 0 and trimmed[0] == '>') {
                    text_slice = trimmed[1..];
                    if (text_slice.len > 0 and text_slice[0] == ' ') {
                        text_slice = text_slice[1..];
                    }
                } else {
                    return false;
                }
            }
        }

        const trimmed = std.mem.trimLeft(u8, text_slice, &std.ascii.whitespace);

        if (top == .code) {
            if (trimmed.len >= 3 and (std.mem.eql(u8, trimmed[0..3], "```") or std.mem.eql(u8, trimmed[0..3], "~~~"))) {
                try parser.renderAndCloseTopBlock(output);
                return true;
            }
        } else {
            if (trimmed.len >= 2 and std.mem.eql(u8, trimmed[0..2], "$$")) {
                try parser.renderAndCloseTopBlock(output);
                return true;
            }
        }

        if (parser.stack_depth > 0) {
            const indent = parser.block_stack[parser.stack_depth - 1].indent_level;
            var k: i32 = 0;
            while (k < indent and text_slice.len > 0 and text_slice[0] == ' ') {
                text_slice = text_slice[1..];
                k += 1;
            }
        }

        try parser.appendEscapedText(text_slice, output);
        try writeByte(output, '\n');
        return true;
    }

    fn parseFencedCodeBlock(parser: *OctomarkParser, line_content: []const u8, leading_spaces: usize, output: anytype) !bool {
        const _s = parser.startCall(.parseFencedCodeBlock);
        defer parser.endCall(.parseFencedCodeBlock, _s);
        var content = line_content;
        var extra_spaces: usize = 0;
        while (content.len > 0 and content[0] == ' ') {
            extra_spaces += 1;
            content = content[1..];
        }

        if (content.len >= 3 and (std.mem.eql(u8, content[0..3], "```") or std.mem.eql(u8, content[0..3], "~~~"))) {
            const fence_char = content[0];
            const block_type = parser.currentBlockType();
            if (block_type == .paragraph or block_type == .table or block_type == .code or block_type == .math) {
                try parser.renderAndCloseTopBlock(output);
            }
            try writeAll(output, "<pre><code");
            var lang_len: usize = 0;
            while (3 + lang_len < content.len and !std.ascii.isWhitespace(content[3 + lang_len])) : (lang_len += 1) {}
            if (lang_len > 0 and fence_char == '`') {
                try writeAll(output, " class=\"language-");
                try parser.appendEscapedText(content[3 .. 3 + lang_len], output);
                try writeAll(output, "\"");
            } else if (lang_len > 0 and fence_char == '~') {
                // If the user wants info strings on tildes supported (standard GFM)
                try writeAll(output, " class=\"language-");
                try parser.appendEscapedText(content[3 .. 3 + lang_len], output);
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
        var content = line_content;
        var extra_spaces: usize = 0;
        while (content.len > 0 and content[0] == ' ') {
            extra_spaces += 1;
            content = content[1..];
        }

        if (content.len >= 2 and std.mem.eql(u8, content[0..2], "$$")) {
            const block_type = parser.currentBlockType();
            if (block_type == .paragraph or block_type == .table or block_type == .code or block_type == .math) {
                try parser.renderAndCloseTopBlock(output);
            }
            try writeAll(output, "<div class=\"math\">\n");
            try parser.pushBlock(.math, @intCast(leading_spaces + extra_spaces));

            const remainder = content[2..];
            const trimmed_rem = std.mem.trim(u8, remainder, " \t");
            if (trimmed_rem.len > 0) {
                if (trimmed_rem.len >= 2 and std.mem.eql(u8, trimmed_rem[trimmed_rem.len - 2 ..], "$$")) {
                    const math_content = std.mem.trim(u8, trimmed_rem[0 .. trimmed_rem.len - 2], " \t");
                    try parser.appendEscapedText(math_content, output);
                    try writeByte(output, '\n');
                    try parser.renderAndCloseTopBlock(output);
                } else {
                    try parser.appendEscapedText(remainder, output);
                    try writeByte(output, '\n');
                }
            }

            return true;
        }
        return false;
    }

    fn parseHeader(parser: *OctomarkParser, line_content: []const u8, output: anytype) !bool {
        const _s = parser.startCall(.parseHeader); defer parser.endCall(.parseHeader, _s);
        if (line_content.len >= 1 and line_content[0] == '#') {
            var level: usize = 0;
            while (level < 6 and level < line_content.len and line_content[level] == '#') : (level += 1) {}

            // Handle up to 6 levels of hashes (CommonMark limitation)
            if (level == 6 and level < line_content.len and line_content[level] == '#') return false;

            var real_level: usize = 0;
            while (real_level < line_content.len and line_content[real_level] == '#') : (real_level += 1) {}

            if (real_level > 6 or real_level == 0) return false;

            level = real_level;
            const content_start: usize = if (level < line_content.len and line_content[level] == ' ') level + 1 else level;

            try parser.tryCloseLeafBlock(output);
            const level_char: u8 = '0' + @as(u8, @intCast(level));
            try writeAll(output, "<h");
            try writeByte(output, level_char);
            try writeAll(output, ">");
            try parser.parseInlineContent(line_content[content_start..], output);
            try writeAll(output, "</h");
            try writeByte(output, level_char);
            try writeAll(output, ">\n");
            return true;
        }
        return false;
    }

    fn parseHorizontalRule(parser: *OctomarkParser, line_content: []const u8, output: anytype) !bool {
        const _s = parser.startCall(.parseHorizontalRule); defer parser.endCall(.parseHorizontalRule, _s);
        if (line_content.len == 3 and (std.mem.eql(u8, line_content, "---") or std.mem.eql(u8, line_content, "***") or std.mem.eql(u8, line_content, "___"))) {
            try parser.tryCloseLeafBlock(output);
            try writeAll(output, "<hr>\n");
            return true;
        }
        return false;
    }

    fn parseDefinitionList(parser: *OctomarkParser, line_content: *[]const u8, leading_spaces: *usize, output: anytype) !bool {
        const _s = parser.startCall(.parseDefinitionList); defer parser.endCall(.parseDefinitionList, _s);
        var line = line_content.*;
        if (line.len > 0 and line[0] == ':') {
            var consumed: usize = 1;
            line = line[1..];
            if (line.len > 0 and line[0] == ' ') {
                line = line[1..];
                consumed += 1;
            }
            try parser.closeParagraphIfOpen(output);
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
                while (parser.currentBlockType() != .definition_list and parser.stack_depth > 0) {
                    try parser.renderAndCloseTopBlock(output);
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
        const _s = parser.startCall(.parseListItem); defer parser.endCall(.parseListItem, _s);
        var line = line_content.*;
        const trimmed_line = std.mem.trimLeft(u8, line, &std.ascii.whitespace);
        const internal_spaces: usize = line.len - trimmed_line.len;

        // Unordered list marker: -, *, +
        var is_ul = false;
        var marker_len: usize = 0;
        if (line.len - internal_spaces >= 2) {
            const m = line[internal_spaces];
            if ((m == '-' or m == '*' or m == '+') and line[internal_spaces + 1] == ' ') {
                is_ul = true;
                marker_len = 2;
            }
        }

        const is_ol = (line.len - internal_spaces >= 3 and std.ascii.isDigit(line[internal_spaces]) and
            std.mem.eql(u8, line[internal_spaces + 1 .. internal_spaces + 3], ". "));

        if (is_ol) marker_len = 3;

        if (is_ul or is_ol) {
            // Handle empty list items (Requirement 1.8)
            var remainder = line[internal_spaces + marker_len ..];
            remainder = std.mem.trimLeft(u8, remainder, &std.ascii.whitespace);
            if (remainder.len == 0) return true;

            const target_type: BlockType = if (is_ul) .unordered_list else .ordered_list;
            const current_indent: i32 = @intCast(leading_spaces.* + internal_spaces);
            while (parser.stack_depth > 0 and
                parser.currentBlockType() != null and @intFromEnum(parser.currentBlockType().?) < @intFromEnum(BlockType.blockquote) and
                (parser.block_stack[parser.stack_depth - 1].indent_level > current_indent or
                    (parser.block_stack[parser.stack_depth - 1].indent_level == current_indent and parser.currentBlockType() != target_type)))
            {
                try parser.renderAndCloseTopBlock(output);
            }

            const top = parser.currentBlockType();
            if (top == target_type and parser.block_stack[parser.stack_depth - 1].indent_level == current_indent) {
                const block_type = parser.currentBlockType();
                if (block_type == .paragraph or block_type == .table or block_type == .code or block_type == .math) {
                    try parser.renderAndCloseTopBlock(output);
                }
                try writeAll(output, "</li>\n<li>");
            } else {
                const block_type = parser.currentBlockType();
                if (block_type == .paragraph or block_type == .table or block_type == .code or block_type == .math) {
                    try parser.renderAndCloseTopBlock(output);
                }
                try writeAll(output, if (target_type == .unordered_list) "<ul>\n<li>" else "<ol>\n<li>");
                try parser.pushBlock(target_type, current_indent);
            }

            leading_spaces.* += internal_spaces + marker_len;
            line = line[internal_spaces + marker_len ..];
            if (line.len >= 4 and line[0] == '[' and (line[1] == ' ' or line[1] == 'x') and line[2] == ']' and line[3] == ' ') {
                try writeAll(output, if (line[1] == 'x') "<input type=\"checkbox\" checked disabled> " else "<input type=\"checkbox\"  disabled> ");
                line = line[4..];
            }
            line_content.* = line;
            return true;
        }
        return false;
    }

    fn parseTable(parser: *OctomarkParser, line_content: []const u8, full_data: []const u8, current_pos: usize, output: anytype) !bool {
        const _s = parser.startCall(.parseTable);
        defer parser.endCall(.parseTable, _s);
        // 1. If we are already IN a table, process body rows strictly.
        if (parser.currentBlockType() == .table) {
            const trimmed_line = std.mem.trim(u8, line_content, &std.ascii.whitespace);
            // Quick pipe check for body row
            var has_pipe = false;
            for (trimmed_line) |c| {
                if (c == '|') {
                    has_pipe = true;
                    break;
                }
            }

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
                try parser.renderAndCloseTopBlock(output);
                // Continue to process this line as something else (return false)
                return false;
            }
        }

        if (current_pos >= full_data.len) return false;
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

        try parser.tryCloseLeafBlock(output);

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
            const next_newline = std.mem.indexOfScalar(u8, full_data[current_pos..], '\n');
            if (next_newline) |offset| {
                const nl = current_pos + offset;
                const trimmed = std.mem.trimLeft(u8, full_data[current_pos..nl], &std.ascii.whitespace);
                if (trimmed.len > 0 and trimmed[0] == ':') {
                    const block_type = parser.currentBlockType();
                    if (block_type == .paragraph or block_type == .table or block_type == .code or block_type == .math) {
                        try parser.renderAndCloseTopBlock(output);
                    }
                    if (parser.stack_depth == 0 or parser.currentBlockType() != .definition_list) {
                        try writeAll(output, "<dl>\n");
                        try parser.pushBlock(.definition_list, 0);
                    }
                    try writeAll(output, "<dt>");
                    try parser.parseInlineContent(line_content, output);
                    try writeAll(output, "</dt>\n");
                    return true;
                }
            }
        }
        return false;
    }

    fn processParagraph(parser: *OctomarkParser, line_content: []const u8, is_dl: bool, is_list: bool, output: anytype) !void {
        if (line_content.len == 0) {
            try parser.closeParagraphIfOpen(output);
            return;
        }

        const block_type = parser.currentBlockType();
        const in_container = (parser.stack_depth > 0 and
            (block_type != null and
                (@intFromEnum(block_type.?) < @intFromEnum(BlockType.blockquote) or block_type.? == .definition_description)));

        if (parser.currentBlockType() != .paragraph and !in_container) {
            try writeAll(output, "<p>");
            try parser.pushBlock(.paragraph, 0);
        } else if (parser.currentBlockType() == .paragraph or (in_container and !is_list and !is_dl)) {
            try writeByte(output, '\n');
        }

        const line_break = (line_content.len >= 2 and line_content[line_content.len - 1] == ' ' and line_content[line_content.len - 2] == ' ');
        try parser.parseInlineContent(if (line_break) line_content[0 .. line_content.len - 2] else line_content, output);
        if (line_break) try writeAll(output, "<br>");
    }

    fn processSingleLine(parser: *OctomarkParser, line: []const u8, full_data: []const u8, current_pos: usize, output: anytype) !bool {
        const _s = parser.startCall(.processSingleLine);
        defer parser.endCall(.processSingleLine, _s);
        if (try parser.processLeafBlockContinuation(line, output)) return false;

        const trimmed_line = std.mem.trimLeft(u8, line, &std.ascii.whitespace);
        var leading_spaces: usize = line.len - trimmed_line.len;
        var line_content = trimmed_line;

        if (line_content.len == 0) {
            const block_type = parser.currentBlockType();
            if (block_type == .paragraph or block_type == .table or block_type == .code or block_type == .math) {
                try parser.renderAndCloseTopBlock(output);
            }
            while (parser.stack_depth > 0 and parser.currentBlockType() != null and @intFromEnum(parser.currentBlockType().?) >= @intFromEnum(BlockType.blockquote)) {
                try parser.renderAndCloseTopBlock(output);
            }
            return false;
        }

        var quote_level: usize = 0;
        while (true) {
            const trimmed = std.mem.trimLeft(u8, line_content, " ");
            if (trimmed.len > 0 and trimmed[0] == '>') {
                quote_level += 1;
                line_content = trimmed[1..];
                if (line_content.len > 0 and line_content[0] == ' ') line_content = line_content[1..];
            } else {
                break;
            }
        }

        var current_quote_level: usize = 0;
        for (parser.block_stack[0..parser.stack_depth]) |entry| {
            if (entry.block_type == .blockquote) current_quote_level += 1;
        }

        if (quote_level < current_quote_level and (parser.currentBlockType() == .paragraph or parser.currentBlockType() == .unordered_list or parser.currentBlockType() == .ordered_list or parser.currentBlockType() == .blockquote)) {
            const trimmed_for_block = std.mem.trimLeft(u8, line_content, &std.ascii.whitespace);
            if (!parser.isBlockStartMarker(trimmed_for_block)) quote_level = current_quote_level;
        }

        while (current_quote_level > quote_level) {
            const t = parser.currentBlockType().?;
            try parser.renderAndCloseTopBlock(output);
            if (t == .blockquote) current_quote_level -= 1;
        }

        if (line_content.len == 0 and quote_level > current_quote_level) return false;

        while (current_quote_level < quote_level) {
            try parser.closeParagraphIfOpen(output);
            try writeAll(output, "<blockquote>");
            try parser.pushBlock(.blockquote, 0);
            current_quote_level += 1;
        }

        const is_dl = try parser.parseDefinitionList(&line_content, &leading_spaces, output);
        const is_list = try parser.parseListItem(&line_content, &leading_spaces, output);

        const trimmed_for_dispatch = std.mem.trimLeft(u8, line_content, " \t");
        if (trimmed_for_dispatch.len > 0) {
            switch (trimmed_for_dispatch[0]) {
                '#' => if (try parser.parseHeader(line_content, output)) return false,
                '`' => if (try parser.parseFencedCodeBlock(line_content, leading_spaces, output)) return false,
                '~' => if (try parser.parseFencedCodeBlock(line_content, leading_spaces, output)) return false,
                '$' => if (try parser.parseMathBlock(line_content, leading_spaces, output)) return false,
                '-' => {
                    if (line_content.len >= 2 and line_content[0] == '-' and line_content[1] == ' ' and std.mem.trim(u8, line_content, &std.ascii.whitespace).len == 1) return false;
                    if (try parser.parseHorizontalRule(line_content, output)) return false;
                },
                '*' => if (try parser.parseHorizontalRule(line_content, output)) return false,
                '_' => if (try parser.parseHorizontalRule(line_content, output)) return false,
                '|' => if (try parser.parseTable(line_content, full_data, current_pos, output)) return true,
                '<' => {
                    const tags = [_][]const u8{ "div", "pre", "table", "p" };
                    var is_html_block = false;
                    for (tags) |tag| {
                        if (std.mem.startsWith(u8, line_content, "<") and (std.mem.indexOf(u8, line_content, tag) == 1)) {
                            is_html_block = true;
                            break;
                        }
                    }
                    if (is_html_block) {
                        try parser.renderAndCloseTopBlock(output);
                        try writeAll(output, line_content);
                        try writeByte(output, '\n');
                        return true;
                    }
                },
                '>' => {
                    var q_cnt: usize = 0;
                    while (true) {
                        const t = std.mem.trimLeft(u8, line_content, " ");
                        if (t.len > 0 and t[0] == '>') {
                            q_cnt += 1;
                            line_content = t[1..];
                            if (line_content.len > 0 and line_content[0] == ' ') line_content = line_content[1..];
                        } else break;
                    }
                    if (q_cnt > 0) {
                        if (std.mem.trim(u8, line_content, &std.ascii.whitespace).len == 0) return true;
                        try parser.closeParagraphIfOpen(output);
                        var k: usize = 0;
                        while (k < q_cnt) : (k += 1) {
                            try writeAll(output, "<blockquote>");
                            try parser.pushBlock(.blockquote, 0);
                        }
                    }
                },
                else => {},
            }
        }

        if (try parser.parseDefinitionTerm(line_content, full_data, current_pos, output)) return false;

        try parser.processParagraph(line_content, is_dl, is_list, output);
        return false;
    }

    fn isNextLineTableSeparator(parser: *OctomarkParser, full_data: []const u8, start_pos: usize) bool {
        const _s = parser.startCall(.isNextLineTableSeparator);
        defer parser.endCall(.isNextLineTableSeparator, _s);
        if (start_pos >= full_data.len) return true; // Treat EOF as buffering safe (incomplete input)

        const next_line_end = if (std.mem.indexOfScalar(u8, full_data[start_pos..], '\n')) |nl|
            start_pos + nl
        else
            full_data.len;

        const next_line = full_data[start_pos..next_line_end];
        const trimmed_next = std.mem.trim(u8, next_line, &std.ascii.whitespace);

        if (trimmed_next.len < 3) return false;

        var has_dash = false;
        var all_valid = true;
        for (trimmed_next) |c| {
            if (c == '-' or c == ':' or c == '|') {
                if (c == '-') has_dash = true;
                continue;
            }
            if (!std.ascii.isWhitespace(c)) {
                all_valid = false;
                break;
            }
        }
        return (all_valid and has_dash);
    }

    fn parseHtmlTag(parser: *OctomarkParser, text: []const u8) usize {
        const _s = parser.startCall(.parseHtmlTag); defer parser.endCall(.parseHtmlTag, _s);
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

        if (i < len and text[i] == '/') i += 1;

        if (i >= len or !std.ascii.isAlphabetic(text[i])) return 0;

        while (i < len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '-' or text[i] == ':')) : (i += 1) {}

        while (i < len and text[i] != '>') : (i += 1) {
            const c = text[i];
            if (c == '"' or c == '\'') {
                const quote = c;
                i += 1;
                while (i < len and text[i] != quote) : (i += 1) {}
                if (i >= len) return 0;
            }
        }

        if (i < len and text[i] == '>') return i + 1;
        return 0;
    }

    fn splitTableRowCells(parser: *OctomarkParser, str: []const u8, cells: *[64][]const u8) usize {
        const _s = parser.startCall(.splitTableRowCells); defer parser.endCall(.splitTableRowCells, _s);
        var count: usize = 0;
        var cursor = std.mem.trim(u8, str, &std.ascii.whitespace);
        if (cursor.len > 0 and cursor[0] == '|') cursor = cursor[1..];

        while (cursor.len > 0) {
            var end_offset: usize = 0;
            var found = false;
            var k: usize = 0;
            while (k < cursor.len) : (k += 1) {
                if (cursor[k] == '\\' and k + 1 < cursor.len) {
                    k += 1;
                    continue;
                }
                if (cursor[k] == '|') {
                    end_offset = k;
                    found = true;
                    break;
                }
            }
            if (!found) end_offset = cursor.len;

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

    fn isBlockStartMarker(parser: *OctomarkParser, str: []const u8) bool {
        const _s = parser.startCall(.isBlockStartMarker);
        defer parser.endCall(.isBlockStartMarker, _s);
        if (str.len >= 3 and std.mem.eql(u8, str[0..3], "```")) return true;
        if (str.len >= 2 and std.mem.eql(u8, str[0..2], "$$")) return true;
        if (str.len >= 1 and (str[0] == '#' or str[0] == ':')) return true;
        if (str.len >= 2 and std.mem.eql(u8, str[0..2], "- ")) return true;
        if (str.len >= 3 and std.ascii.isDigit(str[0]) and std.mem.eql(u8, str[1..3], ". ")) return true;
        if (str.len >= 3 and (std.mem.eql(u8, str[0..3], "---") or std.mem.eql(u8, str[0..3], "***") or std.mem.eql(u8, str[0..3], "___"))) return true;
        return false;
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
