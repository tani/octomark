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
    tags[@intFromEnum(BlockType.indented_code)] = "</code></pre>\n";
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
    enable_html: bool = true,
};

const special_chars = "\\['*`&<>\"'_~!$\n";

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
    paragraph_content: std.ArrayList(u8) = undefined,
    delimiter_stack: [MAX_INLINE_NESTING]Delimiter = undefined,
    delimiter_stack_len: usize = 0,
    replacements: std.ArrayList(Replacement) = undefined,
    allocator: std.mem.Allocator = undefined,
    options: OctomarkOptions = .{},

    stats: if (builtin.mode == .Debug) Stats else struct {} = .{},
    timer: if (builtin.mode == .Debug) std.time.Timer else struct {} = undefined,

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

    const ReplacementSorter = struct {
        fn less(_: void, a: Replacement, b: Replacement) bool {
            return a.pos < b.pos;
        }
    };

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
        finish: Counter = .{},
        closeParagraphIfOpen: Counter = .{},
        tryCloseLeafBlock: Counter = .{},
        scanDelimiters: Counter = .{},
        scanInline: Counter = .{},
        renderInline: Counter = .{},
        parseIndentedCodeBlock: Counter = .{},
        processLeafBlockContinuation: Counter = .{},
        processParagraph: Counter = .{},
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
        self.* = OctomarkParser{
            .allocator = allocator,
            .paragraph_content = .{},
            .replacements = .{},
        };
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
        self.paragraph_content.deinit(allocator);
        self.replacements.deinit(allocator);
    }

    /// Enable parsing options.
    pub fn setOptions(self: *OctomarkParser, options: OctomarkOptions) void {
        self.options = options;
    }

    /// Feed a chunk into the parser. Returns error.OutOfMemory or writer errors.
    pub fn parse(self: *OctomarkParser, reader: anytype, writer: anytype, allocator: std.mem.Allocator) !void {
        var buffer: [65536]u8 = undefined;
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

        if (parser.paragraph_content.items.len > 0) {
            try parser.parseInlineContent(parser.paragraph_content.items, output);
            parser.paragraph_content.clearRetainingCapacity();
        }

        parser.popBlock();
        try writeAll(output, block_close_tags[@intFromEnum(block_type)]);
    }

    fn closeParagraphIfOpen(parser: *OctomarkParser, output: anytype) !void {
        const _s = parser.startCall(.closeParagraphIfOpen);
        defer parser.endCall(.closeParagraphIfOpen, _s);
        if (parser.currentBlockType() == .paragraph) try parser.renderAndCloseTopBlock(output);
    }

    fn tryCloseLeafBlock(parser: *OctomarkParser, output: anytype) !void {
        const _s = parser.startCall(.tryCloseLeafBlock);
        defer parser.endCall(.tryCloseLeafBlock, _s);

        const bt = parser.currentBlockType() orelse return;
        if (@intFromEnum(bt) >= @intFromEnum(BlockType.code)) {
            try parser.renderAndCloseTopBlock(output);
        } else if (parser.paragraph_content.items.len > 0) {
            try parser.parseInlineContent(parser.paragraph_content.items, output);
            parser.paragraph_content.clearRetainingCapacity();
        }
    }

    fn appendEscapedText(parser: *const OctomarkParser, text: []const u8, output: anytype) !void {
        const _s = @constCast(parser).startCall(.appendEscapedText);
        defer @constCast(parser).endCall(.appendEscapedText, _s);
        var i: usize = 0;
        const escape_chars = "&<>\"'";
        while (i < text.len) {
            if (std.mem.indexOfAny(u8, text[i..], escape_chars)) |offset| {
                const j = i + offset;
                if (j > i) try writeAll(output, text[i..j]);
                const entity = html_escape_map[text[j]].?;
                try writeAll(output, entity);
                i = j + 1;
            } else {
                try writeAll(output, text[i..]);
                break;
            }
        }
    }

    fn isAsciiPunctuation(c: u8) bool {
        return switch (c) {
            '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~' => true,
            else => false,
        };
    }

    fn findNextSpecial(parser: *OctomarkParser, text: []const u8, start: usize) usize {
        const _s = parser.startCall(.findNextSpecial);
        defer parser.endCall(.findNextSpecial, _s);
        var i = start;
        while (std.mem.indexOfAny(u8, text[i..], special_chars ++ "h")) |offset| {
            i += offset;
            if (text[i] != 'h') return i;
            if (std.mem.startsWith(u8, text[i..], "http:") or std.mem.startsWith(u8, text[i..], "https:")) return i;
            i += 1;
        }
        return text.len;
    }

    pub fn parseInlineContent(parser: *OctomarkParser, text: []const u8, output: anytype) anyerror!void {
        // Clear replacements at top level start to ensure clean state
        parser.replacements.clearRetainingCapacity();
        try parser.scanInline(text, 0); // stack_bottom = 0

        // Sorting
        std.sort.block(Replacement, parser.replacements.items, {}, ReplacementSorter.less);

        try parser.parseInlineContentDepth(text, output, 0, 0);
    }

    fn parseInlineContentDepth(parser: *OctomarkParser, text: []const u8, output: anytype, depth: usize, global_offset: usize) anyerror!void {
        const _s = parser.startCall(.parseInlineContent);
        defer parser.endCall(.parseInlineContent, _s);

        if (depth > 10) {
            try writeAll(output, text);
            return;
        }
        try parser.renderInline(text, parser.replacements.items, output, depth, global_offset);
    }

    fn scanDelimiters(parser: *OctomarkParser, text: []const u8, start_pos: usize, delimiter_char: u8, stack_bottom: usize) !usize {
        const _s = parser.startCall(.scanDelimiters);
        defer parser.endCall(.scanDelimiters, _s);

        var num_delims: usize = 0;
        var i = start_pos;
        while (i < text.len and text[i] == delimiter_char) : (i += 1) {
            num_delims += 1;
        }

        if (num_delims == 0) return start_pos;

        const char_before = if (start_pos == 0) '\n' else text[start_pos - 1];
        const char_after = if (i == text.len) '\n' else text[i];

        const is_whitespace_after = std.ascii.isWhitespace(char_after);
        const is_whitespace_before = std.ascii.isWhitespace(char_before);
        const is_punct_after = isAsciiPunctuation(char_after);
        const is_punct_before = isAsciiPunctuation(char_before);

        var can_open = !is_whitespace_after and (!is_punct_after or is_whitespace_before or is_punct_before);
        var can_close = !is_whitespace_before and (!is_punct_before or is_whitespace_after or is_punct_after);

        if (delimiter_char == '_') {
            can_open = can_open and (!can_close or is_punct_before);
            can_close = can_close and (!can_open or is_punct_after);
        }

        if (can_close) {
            var stack_idx = parser.delimiter_stack_len;
            while (stack_idx > stack_bottom) {
                stack_idx -= 1;
                var opener = &parser.delimiter_stack[stack_idx];
                if (opener.char == delimiter_char and opener.active and opener.can_open) {
                    // Check Rule of 3
                    if ((opener.can_close or can_open) and (opener.count + num_delims) % 3 == 0 and (opener.count % 3 != 0 or num_delims % 3 != 0)) {
                        continue;
                    }

                    const use_delims: usize = if (num_delims >= 2 and opener.count >= 2) 2 else 1;
                    const open_tag = if (use_delims == 2) "<strong>" else "<em>";
                    const close_tag = if (use_delims == 2) "</strong>" else "</em>";

                    try parser.replacements.append(parser.allocator, Replacement{ .pos = opener.pos + opener.count - use_delims, .end = opener.pos + opener.count, .text = open_tag });
                    try parser.replacements.append(parser.allocator, Replacement{ .pos = start_pos, .end = start_pos + use_delims, .text = close_tag });

                    opener.count -= use_delims;
                    num_delims -= use_delims;

                    if (opener.count == 0) {
                        if (stack_idx == parser.delimiter_stack_len - 1) {
                            parser.delimiter_stack_len -= 1;
                        } else {
                            std.mem.copyForwards(Delimiter, parser.delimiter_stack[stack_idx .. parser.delimiter_stack_len - 1], parser.delimiter_stack[stack_idx + 1 .. parser.delimiter_stack_len]);
                            parser.delimiter_stack_len -= 1;
                        }
                    }

                    if (num_delims == 0) break;
                    continue;
                }
            }
        }

        if (can_open and num_delims > 0) {
            if (parser.delimiter_stack_len < MAX_INLINE_NESTING) {
                parser.delimiter_stack[parser.delimiter_stack_len] = Delimiter{
                    .pos = start_pos,
                    .content_end = i,
                    .char = delimiter_char,
                    .count = num_delims,
                    .can_open = can_open,
                    .can_close = can_close,
                    .active = true,
                };
                parser.delimiter_stack_len += 1;
            }
        }

        return i;
    }

    fn scanInline(parser: *OctomarkParser, text: []const u8, stack_bottom: usize) !void {
        const _s = parser.startCall(.scanInline);
        defer parser.endCall(.scanInline, _s);

        var i: usize = 0;
        const len = text.len;

        while (i < len) {
            const offset = std.mem.indexOfAny(u8, text[i..], "*_`<\\") orelse break;
            i += offset;
            const c = text[i];
            switch (c) {
                '*', '_' => {
                    const next_pos = try parser.scanDelimiters(text, i, c, stack_bottom);
                    i = next_pos;
                },
                '`' => {
                    var backtick_count: usize = 1;
                    var k = i + 1;
                    while (k < len and text[k] == '`') : (k += 1) {
                        backtick_count += 1;
                    }
                    if (std.mem.indexOf(u8, text[i + backtick_count ..], text[i .. i + backtick_count])) |match_offset| {
                        i = i + backtick_count + match_offset + backtick_count;
                    } else {
                        i += backtick_count;
                    }
                },
                '<' => {
                    const tag_len = parser.parseHtmlTag(text[i..]);
                    if (tag_len > 0) {
                        i += tag_len;
                    } else {
                        i += 1;
                    }
                },
                '\\' => i += 2,
                else => i += 1,
            }
        }
    }

    fn renderInline(parser: *OctomarkParser, text: []const u8, replacements: []const Replacement, output: anytype, depth: usize, global_offset: usize) anyerror!void {
        const _s = parser.startCall(.renderInline);
        defer parser.endCall(.renderInline, _s);

        var i: usize = 0;
        var rep_idx: usize = 0;

        while (i < text.len) {
            while (rep_idx < replacements.len and replacements[rep_idx].pos < global_offset + i) {
                rep_idx += 1;
            }
            if (rep_idx < replacements.len and replacements[rep_idx].pos == global_offset + i) {
                const rep = replacements[rep_idx];
                try writeAll(output, rep.text);
                const len = rep.end - rep.pos; // Length in original text
                // Advance i by local length
                i += len;
                rep_idx += 1;
                continue;
            }

            const next_rep_pos = if (rep_idx < replacements.len) replacements[rep_idx].pos else text.len;
            var next_special = parser.findNextSpecial(text, i);

            if (next_special > next_rep_pos) next_special = next_rep_pos;

            // Handle Hard Line Break
            if (next_special < text.len and text[next_special] == '\n') {
                // Check if it's strictly before next replacement
                if (next_special < next_rep_pos) {
                    const start = i;
                    // Trim and output handled in special logic
                    var trim_end = next_special;
                    while (trim_end > start and text[trim_end - 1] == ' ') : (trim_end -= 1) {}
                    if (trim_end > start) try writeAll(output, text[start..trim_end]);

                    if (next_special - trim_end >= 2) {
                        try writeAll(output, "<br>\n");
                    } else {
                        try writeByte(output, '\n');
                    }
                    i = next_special + 1;
                    continue;
                }
            }

            if (next_special > i) {
                try writeAll(output, text[i..next_special]);
                i = next_special;
                continue;
            }

            if (i == next_rep_pos) {
                // Should be handled by loop start, but just in case
                continue;
            }

            const c = text[i];
            var handled = false;

            switch (c) {
                '\\' => {
                    if (i + 1 < text.len) {
                        const next = text[i + 1];
                        if (next == '\n') {
                            try writeAll(output, "<br>\n");
                            i += 2;
                        } else if (isAsciiPunctuation(next)) {
                            i += 1;
                            try writeByte(output, text[i]);
                            i += 1;
                        } else {
                            try writeByte(output, '\\');
                            i += 1;
                        }
                    } else {
                        try writeByte(output, '\\');
                        i += 1;
                    }
                    handled = true;
                },
                '~' => {
                    if (std.mem.startsWith(u8, text[i..], "~~")) {
                        if (std.mem.indexOf(u8, text[i + 2 ..], "~~")) |offset| {
                            const j = i + 2 + offset;
                            if (depth + 1 <= MAX_INLINE_NESTING) {
                                try writeAll(output, "<del>");
                                try parser.parseInlineContentDepth(text[i + 2 .. j], output, depth + 1, global_offset + i + 2);
                                try writeAll(output, "</del>");
                                i = j + 2;
                                handled = true;
                            }
                        }
                    }
                },
                '`' => {
                    var backtick_count: usize = 1;
                    while (i + backtick_count < text.len and text[i + backtick_count] == '`') {
                        backtick_count += 1;
                    }
                    if (std.mem.indexOf(u8, text[i + backtick_count ..], text[i .. i + backtick_count])) |offset| {
                        const j = i + backtick_count + offset;
                        const content = text[i + backtick_count .. j];
                        try writeAll(output, "<code>");
                        try parser.appendEscapedText(content, output);
                        try writeAll(output, "</code>");
                        i = j + backtick_count;
                        handled = true;
                    }
                },
                '[', '!' => {
                    const is_image = (c == '!');
                    if (!is_image or (i + 1 < text.len and text[i + 1] == '[')) {
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
                                    var url_part = std.mem.trim(u8, text[bracket_end + 2 .. paren_end], " \t\n");
                                    var title: ?[]const u8 = null;

                                    if (std.mem.indexOfAny(u8, url_part, " \t\n")) |title_start| {
                                        const possible_title = std.mem.trim(u8, url_part[title_start..], " \t\n");
                                        if (possible_title.len >= 2 and ((possible_title[0] == '"' and possible_title[possible_title.len - 1] == '"') or (possible_title[0] == '\'' and possible_title[possible_title.len - 1] == '\''))) {
                                            url_part = url_part[0..title_start];
                                            title = possible_title[1 .. possible_title.len - 1];
                                        }
                                    }

                                    if (is_image) {
                                        try writeAll(output, "<img src=\"");
                                        try parser.appendEscapedText(url_part, output);
                                        try writeAll(output, "\" alt=\"");
                                        var a: usize = bracket_start;
                                        while (a < bracket_end) {
                                            const char = text[a];
                                            if (char == '\\' and a + 1 < bracket_end and isAsciiPunctuation(text[a + 1])) {
                                                a += 1;
                                                const next = text[a];
                                                if (html_escape_map[next]) |entity| {
                                                    try writeAll(output, entity);
                                                } else {
                                                    try writeByte(output, next);
                                                }
                                            } else {
                                                if (html_escape_map[char]) |entity| {
                                                    try writeAll(output, entity);
                                                } else {
                                                    try writeByte(output, char);
                                                }
                                            }
                                            a += 1;
                                        }
                                        if (title) |t| {
                                            try writeAll(output, "\" title=\"");
                                            try parser.appendEscapedText(t, output);
                                        }
                                        try writeAll(output, "\">");
                                        i = paren_end + 1;
                                        handled = true;
                                    } else {
                                        try writeAll(output, "<a href=\"");
                                        try parser.appendEscapedText(url_part, output);
                                        if (title) |t| {
                                            try writeAll(output, "\" title=\"");
                                            try parser.appendEscapedText(t, output);
                                        }
                                        try writeAll(output, "\">");
                                        try parser.parseInlineContentDepth(text[bracket_start..bracket_end], output, depth + 1, global_offset + bracket_start);
                                        try writeAll(output, "</a>");
                                        i = paren_end + 1;
                                        handled = true;
                                    }
                                }
                            }
                        }
                    }
                },
                '<' => {
                    if (i + 1 < text.len) {
                        if (std.mem.indexOfScalar(u8, text[i + 1 ..], '>')) |end_offset| {
                            const link_content = text[i + 1 .. i + 1 + end_offset];
                            if (std.mem.indexOfAny(u8, link_content, " \t\n") == null) {
                                var is_autolink = false;
                                var is_email = false;
                                if (std.mem.indexOfScalar(u8, link_content, ':')) |scheme_offset| {
                                    const scheme = link_content[0..scheme_offset];
                                    var all_alpha = true;
                                    for (scheme) |sc| {
                                        if (!std.ascii.isAlphanumeric(sc) and sc != '+' and sc != '.' and sc != '-') {
                                            all_alpha = false;
                                            break;
                                        }
                                    }
                                    if (all_alpha and scheme.len > 0) is_autolink = true;
                                } else if (std.mem.indexOfScalar(u8, link_content, '@')) |_| {
                                    is_autolink = true;
                                    is_email = true;
                                }

                                if (is_autolink) {
                                    try writeAll(output, "<a href=\"");
                                    if (is_email) try writeAll(output, "mailto:");
                                    try parser.appendEscapedText(link_content, output);
                                    try writeAll(output, "\">");
                                    try parser.appendEscapedText(link_content, output);
                                    try writeAll(output, "</a>");
                                    i = i + 1 + end_offset + 1;
                                    handled = true;
                                }
                            }
                        }
                    }
                    if (!handled and parser.options.enable_html) {
                        const tag_len = parser.parseHtmlTag(text[i..]);
                        if (tag_len > 0) {
                            try writeAll(output, text[i .. i + tag_len]);
                            i += tag_len;
                            handled = true;
                        }
                    }
                },
                'h' => {
                    if (i + 4 < text.len and (std.mem.startsWith(u8, text[i..], "http:") or std.mem.startsWith(u8, text[i..], "https:"))) {
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
                        handled = true;
                    }
                },
                '$' => {
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
                        handled = true;
                    }
                },
                '&' => {
                    var j = i + 1;
                    if (j < text.len and text[j] == '#') {
                        j += 1;
                        if (j < text.len and (text[j] == 'x' or text[j] == 'X')) {
                            j += 1;
                            while (j < text.len and std.ascii.isHex(text[j])) : (j += 1) {}
                        } else {
                            while (j < text.len and std.ascii.isDigit(text[j])) : (j += 1) {}
                        }
                        if (j > i + 2 and j < text.len and text[j] == ';') {
                            try writeAll(output, text[i .. j + 1]);
                            i = j + 1;
                            handled = true;
                        }
                    } else {
                        while (j < text.len and std.ascii.isAlphanumeric(text[j])) : (j += 1) {}
                        if (j > i + 1 and j < text.len and text[j] == ';') {
                            const entity = text[i + 1 .. j];
                            if (decodeEntity(entity)) |decoded| {
                                try parser.appendEscapedText(decoded, output);
                            } else {
                                try writeAll(output, text[i .. j + 1]);
                            }
                            i = j + 1;
                            handled = true;
                        }
                    }
                    if (!handled) {
                        try writeAll(output, "&amp;");
                        i += 1;
                        handled = true;
                    }
                },
                '>', '"', '\'' => {
                    try writeAll(output, html_escape_map[c].?);
                    i += 1;
                    handled = true;
                },
                else => {},
            }
            if (!handled) {
                const entity = html_escape_map[text[i]];
                if (entity) |value| {
                    try writeAll(output, value);
                } else {
                    try writeByte(output, text[i]);
                }
                i += 1;
            }
        }
    }

    fn decodeEntity(inner: []const u8) ?[]const u8 {
        if (inner.len < 2) return null;
        switch (inner[0]) {
            'a' => if (std.mem.eql(u8, inner, "amp")) return "&" else if (std.mem.eql(u8, inner, "apos")) return "'",
            'l' => if (std.mem.eql(u8, inner, "lt")) return "<",
            'g' => if (std.mem.eql(u8, inner, "gt")) return ">",
            'q' => if (std.mem.eql(u8, inner, "quot")) return "\"",
            'c' => if (std.mem.eql(u8, inner, "copy")) return "©",
            'r' => if (std.mem.eql(u8, inner, "reg")) return "®",
            'n' => if (std.mem.eql(u8, inner, "nbsp")) return "\u{00A0}",
            else => return null,
        }
        return null;
    }
    fn parseIndentedCodeBlock(parser: *OctomarkParser, line_content: []const u8, leading_spaces: usize, output: anytype) !bool {
        const _s = parser.startCall(.parseIndentedCodeBlock);
        defer parser.endCall(.parseIndentedCodeBlock, _s);

        const bt = parser.currentBlockType();
        if (leading_spaces >= 4 and bt != .paragraph and bt != .table and bt != .code and bt != .math and bt != .indented_code) {
            try parser.closeParagraphIfOpen(output);
            try parser.pushBlock(.indented_code, 0);
            try writeAll(output, "<pre><code>");
            try parser.appendEscapedText(line_content, output);
            try writeByte(output, '\n');
            return true;
        }
        return false;
    }

    fn processLeafBlockContinuation(parser: *OctomarkParser, line: []const u8, output: anytype) !bool {
        const _s = parser.startCall(.processLeafBlockContinuation);
        defer parser.endCall(.processLeafBlockContinuation, _s);

        const top = parser.currentBlockType() orelse return false;
        if (top != .code and top != .math and top != .indented_code) return false;

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
        } else if (top == .math) {
            if (trimmed.len >= 2 and std.mem.eql(u8, trimmed[0..2], "$$")) {
                try parser.renderAndCloseTopBlock(output);
                return true;
            }
        } else if (top == .indented_code) {
            const trimmed_spaces = std.mem.trimLeft(u8, text_slice, " ");
            const spaces = text_slice.len - trimmed_spaces.len;
            const is_blank = (spaces == text_slice.len);
            if (!is_blank) {
                if (spaces < 4) {
                    try parser.renderAndCloseTopBlock(output);
                    return false;
                }
                text_slice = text_slice[4..];
            }
        }

        if (parser.stack_depth > 0) {
            const indent = parser.block_stack[parser.stack_depth - 1].indent_level;
            if (indent > 0 and text_slice.len > 0) {
                const trimmed_spaces = std.mem.trimLeft(u8, text_slice, " ");
                const spaces = text_slice.len - trimmed_spaces.len;
                const indent_usize: usize = @intCast(indent);
                const remove = if (spaces < indent_usize) spaces else indent_usize;
                text_slice = text_slice[remove..];
            }
        }

        try parser.appendEscapedText(text_slice, output);
        try writeByte(output, '\n');
        return true;
    }

    fn parseFencedCodeBlock(parser: *OctomarkParser, line_content: []const u8, leading_spaces: usize, output: anytype) !bool {
        const _s = parser.startCall(.parseFencedCodeBlock);
        defer parser.endCall(.parseFencedCodeBlock, _s);
        const content = std.mem.trimLeft(u8, line_content, " ");
        const extra_spaces = line_content.len - content.len;

        if (content.len >= 3 and (std.mem.eql(u8, content[0..3], "```") or std.mem.eql(u8, content[0..3], "~~~"))) {
            const block_type = parser.currentBlockType();
            if (parser.paragraph_content.items.len > 0) {
                try parser.parseInlineContent(parser.paragraph_content.items, output);
                parser.paragraph_content.clearRetainingCapacity();
            }
            if (block_type == .paragraph or block_type == .table or block_type == .code or block_type == .math) {
                try parser.renderAndCloseTopBlock(output);
            }
            try writeAll(output, "<pre><code");
            var lang_len: usize = 0;
            while (3 + lang_len < content.len and !std.ascii.isWhitespace(content[3 + lang_len])) : (lang_len += 1) {}
            if (lang_len > 0) {
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
        const content = std.mem.trimLeft(u8, line_content, " ");
        const extra_spaces = line_content.len - content.len;

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
        const _s = parser.startCall(.parseHeader);
        defer parser.endCall(.parseHeader, _s);
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
        const _s = parser.startCall(.parseHorizontalRule);
        defer parser.endCall(.parseHorizontalRule, _s);
        if (line_content.len == 3 and (std.mem.eql(u8, line_content, "---") or std.mem.eql(u8, line_content, "***") or std.mem.eql(u8, line_content, "___"))) {
            try parser.tryCloseLeafBlock(output);
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
        const _s = parser.startCall(.parseListItem);
        defer parser.endCall(.parseListItem, _s);
        var line = line_content.*;
        if (line.len == 0) return false;

        const trimmed_line = std.mem.trimLeft(u8, line, " ");
        const internal_spaces = line.len - trimmed_line.len;

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
            var remainder = line[internal_spaces + marker_len ..];
            // Don't fully trim here, just consume leading space for content
            if (remainder.len > 0 and remainder[0] == ' ') remainder = remainder[1..];
            if (remainder.len == 0) {
                line_content.* = "";
                return true;
            }

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
                if (parser.paragraph_content.items.len > 0) {
                    try parser.parseInlineContent(parser.paragraph_content.items, output);
                    parser.paragraph_content.clearRetainingCapacity();
                }
                try writeAll(output, "</li>\n<li>");
            } else {
                const block_type = parser.currentBlockType();
                if (block_type == .paragraph or block_type == .table or block_type == .code or block_type == .math) {
                    try parser.renderAndCloseTopBlock(output);
                }
                if (parser.paragraph_content.items.len > 0) {
                    try parser.parseInlineContent(parser.paragraph_content.items, output);
                    parser.paragraph_content.clearRetainingCapacity();
                }
                try writeAll(output, if (target_type == .unordered_list) "<ul>\n<li>" else "<ol>\n<li>");
                try parser.pushBlock(target_type, current_indent);
            }

            leading_spaces.* += internal_spaces + marker_len;
            if (remainder.len >= 4 and remainder[0] == '[' and (remainder[1] == ' ' or remainder[1] == 'x') and remainder[2] == ']' and remainder[3] == ' ') {
                try writeAll(output, if (remainder[1] == 'x') "<input type=\"checkbox\" checked disabled> " else "<input type=\"checkbox\"  disabled> ");
                remainder = remainder[4..];
                leading_spaces.* += 4;
            }
            line_content.* = remainder;
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
                try parser.renderAndCloseTopBlock(output);
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
            const check = full_data[current_pos..];
            var k: usize = 0;
            while (k < check.len and check[k] == ' ') : (k += 1) {}
            if (k < check.len and check[k] == ':') {
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
        return false;
    }

    fn processParagraph(parser: *OctomarkParser, line_content: []const u8, is_dl: bool, is_list: bool, output: anytype) !void {
        const _s = parser.startCall(.processParagraph);
        defer parser.endCall(.processParagraph, _s);

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
            try parser.paragraph_content.append(parser.allocator, '\n');
        }

        try parser.paragraph_content.appendSlice(parser.allocator, line_content);
    }

    fn processSingleLine(parser: *OctomarkParser, line: []const u8, full_data: []const u8, current_pos: usize, output: anytype) !bool {
        const _s = parser.startCall(.processSingleLine);
        defer parser.endCall(.processSingleLine, _s);
        if (try parser.processLeafBlockContinuation(line, output)) return false;

        var i_trim: usize = 0;
        const trimmed = std.mem.trimLeft(u8, line, " \t\r");
        i_trim = line.len - trimmed.len;
        const line_content_trimmed = trimmed;
        var leading_spaces: usize = i_trim;
        var line_content = line_content_trimmed;

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
        {
            var i: usize = 0;
            while (i < line_content.len) {
                while (i < line_content.len and line_content[i] == ' ') : (i += 1) {}
                if (i < line_content.len and line_content[i] == '>') {
                    quote_level += 1;
                    i += 1;
                    if (i < line_content.len and line_content[i] == ' ') i += 1;
                    line_content = line_content[i..];
                    i = 0;
                } else break;
            }
        }

        var current_quote_level: usize = 0;
        for (parser.block_stack[0..parser.stack_depth]) |entry| {
            if (entry.block_type == .blockquote) current_quote_level += 1;
        }

        if (quote_level < current_quote_level and (parser.currentBlockType() == .paragraph or parser.currentBlockType() == .unordered_list or parser.currentBlockType() == .ordered_list or parser.currentBlockType() == .blockquote)) {
            if (!parser.isBlockStartMarker(line_content)) quote_level = current_quote_level;
        }

        while (current_quote_level > quote_level) {
            const t = parser.currentBlockType().?;
            try parser.renderAndCloseTopBlock(output);
            if (t == .blockquote) current_quote_level -= 1;
        }

        if (line_content.len == 0 and quote_level > current_quote_level) return false;

        while (current_quote_level < quote_level) {
            if (parser.paragraph_content.items.len > 0) {
                try parser.parseInlineContent(parser.paragraph_content.items, output);
                parser.paragraph_content.clearRetainingCapacity();
            }
            try parser.closeParagraphIfOpen(output);
            try writeAll(output, "<blockquote>");
            try parser.pushBlock(.blockquote, 0);
            current_quote_level += 1;
        }

        const is_dl = try parser.parseDefinitionList(&line_content, &leading_spaces, output);
        const is_list = try parser.parseListItem(&line_content, &leading_spaces, output);

        if (line_content.len > 0) {
            switch (line_content[0]) {
                '#' => if (try parser.parseHeader(line_content, output)) return false,
                '`', '~' => if (try parser.parseFencedCodeBlock(line_content, leading_spaces, output)) return false,
                '$' => if (try parser.parseMathBlock(line_content, leading_spaces, output)) return false,
                '-' => {
                    if (try parser.parseHorizontalRule(line_content, output)) return false;
                },
                '*', '_' => if (try parser.parseHorizontalRule(line_content, output)) return false,
                '|' => if (try parser.parseTable(line_content, full_data, current_pos, output)) return true,
                '>' => {
                    var q_cnt: usize = 0;
                    var lc = line_content;
                    while (true) {
                        var k: usize = 0;
                        while (k < lc.len and lc[k] == ' ') : (k += 1) {}
                        if (k < lc.len and lc[k] == '>') {
                            q_cnt += 1;
                            k += 1;
                            if (k < lc.len and lc[k] == ' ') k += 1;
                            lc = lc[k..];
                        } else break;
                    }
                    if (q_cnt > 0) {
                        line_content = lc;
                        try parser.closeParagraphIfOpen(output);
                        var k: usize = 0;
                        while (k < q_cnt) : (k += 1) {
                            try writeAll(output, "<blockquote>");
                            try parser.pushBlock(.blockquote, 0);
                        }
                    }
                },
                '<' => {
                    if (line_content.len >= 3) {
                        const lc = line_content;
                        var is_html_block = false;
                        if (lc.len >= 4 and lc[1] == '!') {
                            if (std.mem.startsWith(u8, lc, "<!--")) is_html_block = true;
                            if (std.mem.startsWith(u8, lc, "<![CDATA[")) is_html_block = true;
                        } else if (lc.len >= 2 and lc[1] == '?') {
                            is_html_block = true;
                        } else {
                            const tags = [_][]const u8{ "script", "pre", "style", "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col", "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol", "optgroup", "option", "p", "param", "section", "source", "summary", "table", "tbody", "<td>", "tfoot", "th", "thead", "title", "tr", "<ul>" };
                            const trimmed_lc = if (lc[1] == '/') lc[2..] else lc[1..];
                            for (tags) |tag| {
                                if (std.mem.startsWith(u8, trimmed_lc, tag)) {
                                    if (trimmed_lc.len == tag.len) {
                                        is_html_block = true;
                                        break;
                                    }
                                    const next = trimmed_lc[tag.len];
                                    if (next == ' ' or next == '>' or next == '/') {
                                        is_html_block = true;
                                        break;
                                    }
                                }
                            }
                        }
                        if (is_html_block) {
                            try parser.renderAndCloseTopBlock(output);
                            try writeAll(output, line_content);
                            try writeByte(output, '\n');
                            return true;
                        }
                    }
                },
                else => {},
            }
        }

        if (!is_dl and try parser.parseDefinitionTerm(line_content, full_data, current_pos, output)) return false;

        if (!is_list and !is_dl and try parser.parseIndentedCodeBlock(line_content, leading_spaces, output)) return true;

        try parser.processParagraph(line_content, is_dl, is_list, output);
        return false;
    }

    fn isNextLineTableSeparator(parser: *OctomarkParser, full_data: []const u8, start_pos: usize) bool {
        const _s = parser.startCall(.isNextLineTableSeparator);
        defer parser.endCall(.isNextLineTableSeparator, _s);
        if (start_pos >= full_data.len) return false;

        const next_line = blk: {
            if (std.mem.indexOfScalar(u8, full_data[start_pos..], '\n')) |nl| {
                break :blk full_data[start_pos .. start_pos + nl];
            }
            break :blk full_data[start_pos..];
        };
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

        if (i < len and text[i] == '/') i += 1;

        if (i >= len or !std.ascii.isAlphabetic(text[i])) return 0;

        while (i < len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '-' or text[i] == ':')) : (i += 1) {}

        while (i < len) {
            // Check for end of tag
            if (text[i] == '>') return i + 1;
            if (i + 1 < len and text[i] == '/' and text[i + 1] == '>') return i + 2;

            // Must have whitespace before attribute
            if (!std.ascii.isWhitespace(text[i])) return 0;

            // Skip whitespace
            while (i < len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
            if (i >= len) return 0;

            if (text[i] == '>') return i + 1;
            if (i + 1 < len and text[i] == '/' and text[i + 1] == '>') return i + 2;

            // Attribute Name
            if (i < len and (std.ascii.isAlphabetic(text[i]) or text[i] == '_' or text[i] == ':')) {
                i += 1;
                while (i < len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_' or text[i] == '.' or text[i] == ':' or text[i] == '-')) : (i += 1) {}
            } else {
                return 0; // Invalid attribute start
            }

            // Optional Value
            if (i < len and text[i] == '=') {
                i += 1;
                // Value can be unquoted, single-quoted, double-quoted.
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
                    // Unquoted value: no whitespace, ", ', =, <, >, `
                    if (std.ascii.isWhitespace(text[i]) or text[i] == '"' or text[i] == '\'' or text[i] == '=' or text[i] == '<' or text[i] == '>' or text[i] == '`') return 0;
                    while (i < len and !std.ascii.isWhitespace(text[i]) and text[i] != '"' and text[i] != '\'' and text[i] != '=' and text[i] != '<' and text[i] != '>' and text[i] != '`') : (i += 1) {}
                }
            }
        }

        if (i < len and text[i] == '>') return i + 1;
        return 0;
    }

    fn splitTableRowCells(parser: *OctomarkParser, str: []const u8, cells: *[64][]const u8) usize {
        const _s = parser.startCall(.splitTableRowCells);
        defer parser.endCall(.splitTableRowCells, _s);
        var count: usize = 0;
        var cursor = std.mem.trim(u8, str, &std.ascii.whitespace);
        if (cursor.len > 0 and cursor[0] == '|') cursor = cursor[1..];

        while (cursor.len > 0) {
            var end_offset: usize = 0;
            var found = false;
            var k: usize = 0;
            while (std.mem.indexOfScalar(u8, cursor[k..], '|')) |offset| {
                const j = k + offset;
                var backslashes: usize = 0;
                var b = j;
                while (b > 0 and cursor[b - 1] == '\\') : (b -= 1) {
                    backslashes += 1;
                }
                if (backslashes % 2 == 0) {
                    end_offset = j;
                    found = true;
                    break;
                }
                k = j + 1;
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
        if (str.len == 0) return false;
        switch (str[0]) {
            '`' => return str.len >= 3 and std.mem.startsWith(u8, str, "```"),
            '$' => return str.len >= 2 and std.mem.startsWith(u8, str, "$$"),
            '#', '.', ':', '<', '|' => return true,
            '-' => return str.len >= 2 and (str[1] == ' ' or (str.len >= 3 and std.mem.startsWith(u8, str, "---"))),
            '*' => return str.len >= 3 and std.mem.startsWith(u8, str, "***"),
            '_' => return str.len >= 3 and std.mem.startsWith(u8, str, "___"),
            '0'...'9' => return str.len >= 3 and std.mem.eql(u8, str[1..3], ". "),
            else => return false,
        }
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
