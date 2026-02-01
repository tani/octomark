const std = @import("std");

const MAX_BLOCK_NESTING = 32;

const BlockType = enum(i32) {
    unordered_list = 0,
    ordered_list = 1,
    blockquote = 2,
    definition_list = 3,
    definition_description = 4,
    code = 5,
    math = 6,
    table = 7,
    paragraph = 8,
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
const ParseError = AllocError || std.fs.File.WriteError;

/// Parser configuration options.
pub const OctomarkOptions = struct {
    enable_html: bool = false,
};

/// Buffered writer optimized for repeated small writes.
pub const FastWriter = struct {
    file: std.fs.File,
    buffer: []u8,
    index: usize,

    /// Create a FastWriter using the given file and buffer storage.
    pub fn init(file: std.fs.File, buffer: []u8) FastWriter {
        return .{ .file = file, .buffer = buffer, .index = 0 };
    }

    /// Convenience helper for stdout.
    pub fn fromStdout(buffer: []u8) FastWriter {
        return .{ .file = std.fs.File.stdout(), .buffer = buffer, .index = 0 };
    }

    fn writeAll(self: *FastWriter, data: []const u8) std.fs.File.WriteError!void {
        if (data.len == 0) return;
        if (data.len >= self.buffer.len) {
            try self.flush();
            try self.file.writeAll(data);
            return;
        }
        const available = self.buffer.len - self.index;
        if (data.len > available) try self.flush();
        std.mem.copyForwards(u8, self.buffer[self.index .. self.index + data.len], data);
        self.index += data.len;
    }

    fn writeByte(self: *FastWriter, byte: u8) std.fs.File.WriteError!void {
        if (self.index == self.buffer.len) try self.flush();
        self.buffer[self.index] = byte;
        self.index += 1;
    }

    pub fn flush(self: *FastWriter) std.fs.File.WriteError!void {
        if (self.index == 0) return;
        try self.file.writeAll(self.buffer[0..self.index]);
        self.index = 0;
    }
};

pub const OctomarkParser = struct {
    is_special_char: [256]bool = [_]bool{false} ** 256,
    html_escape_map: [256]?[]const u8 = [_]?[]const u8{null} ** 256,
    table_alignments: [64]TableAlignment = [_]TableAlignment{TableAlignment.none} ** 64,
    table_column_count: usize = 0,
    block_stack: [MAX_BLOCK_NESTING]BlockEntry = undefined,
    stack_depth: usize = 0,
    pending_buffer: Buffer = undefined,
    options: OctomarkOptions = .{},

    /// Initialize parser state. Returns error.OutOfMemory on allocation failure.
    pub fn init(self: *OctomarkParser, allocator: std.mem.Allocator) AllocError!void {
        self.* = OctomarkParser{};
        const special = "\\['*`&<>\"'_~!$h";
        for (special) |ch| self.is_special_char[ch] = true;
        self.html_escape_map['&'] = "&amp;";
        self.html_escape_map['<'] = "&lt;";
        self.html_escape_map['>'] = "&gt;";
        self.html_escape_map['\"'] = "&quot;";
        self.html_escape_map['\''] = "&#39;";
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
    pub fn feed(self: *OctomarkParser, chunk: []const u8, output: *FastWriter, allocator: std.mem.Allocator) ParseError!void {
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
    pub fn finish(self: *OctomarkParser, output: *FastWriter) ParseError!void {
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

    fn pushBlock(parser: *OctomarkParser, block_type: BlockType, indent: i32) void {
        std.debug.assert(parser.stack_depth <= MAX_BLOCK_NESTING);
        if (parser.stack_depth < MAX_BLOCK_NESTING) {
            parser.block_stack[parser.stack_depth] = BlockEntry{ .block_type = block_type, .indent_level = indent };
            parser.stack_depth += 1;
        }
    }

    fn peekBlock(parser: *OctomarkParser) ?*BlockEntry {
        if (parser.stack_depth == 0) return null;
        return &parser.block_stack[parser.stack_depth - 1];
    }

    fn popBlock(parser: *OctomarkParser) void {
        std.debug.assert(parser.stack_depth <= MAX_BLOCK_NESTING);
        if (parser.stack_depth > 0) parser.stack_depth -= 1;
    }

    fn currentBlockType(parser: *const OctomarkParser) ?BlockType {
        if (parser.stack_depth == 0) return null;
        return parser.block_stack[parser.stack_depth - 1].block_type;
    }

    fn renderAndCloseTopBlock(parser: *OctomarkParser, output: *FastWriter) ParseError!void {
        if (parser.stack_depth == 0) return;
        const block_type = parser.block_stack[parser.stack_depth - 1].block_type;
        parser.popBlock();
        switch (block_type) {
            .unordered_list => try output.writeAll("</li>\n</ul>\n"),
            .ordered_list => try output.writeAll("</li>\n</ol>\n"),
            .blockquote => try output.writeAll("</blockquote>\n"),
            .definition_list => try output.writeAll("</dl>\n"),
            .definition_description => try output.writeAll("</dd>\n"),
            .code => try output.writeAll("</code></pre>\n"),
            .math => try output.writeAll("</div>\n"),
            .table => try output.writeAll("</tbody></table>\n"),
            .paragraph => try output.writeAll("</p>\n"),
        }
    }

    fn closeParagraphIfOpen(parser: *OctomarkParser, output: *FastWriter) ParseError!void {
        if (parser.currentBlockType() == .paragraph) try parser.renderAndCloseTopBlock(output);
    }

    fn closeLeafBlocks(parser: *OctomarkParser, output: *FastWriter) ParseError!void {
        const block_type = parser.currentBlockType();
        if (block_type == .paragraph or block_type == .table or block_type == .code or block_type == .math) {
            try parser.renderAndCloseTopBlock(output);
        }
    }

    fn appendEscapedText(parser: *const OctomarkParser, text: []const u8, output: *FastWriter) ParseError!void {
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const entity = parser.html_escape_map[text[i]];
            if (entity) |value| {
                try output.writeAll(value);
            } else {
                try output.writeByte(text[i]);
            }
        }
    }

    fn nextSpecialIndex(parser: *const OctomarkParser, text: []const u8, start: usize) usize {
        const VecLen = 16;
        const special_chars = [_]u8{ '\\', '[', '\'', '*', '`', '&', '<', '>', '"', '_', '~', '!', '$', 'h' };

        var i = start;
        while (i + VecLen <= text.len) : (i += VecLen) {
            const ptr: *const [VecLen]u8 = @ptrCast(text[i..].ptr);
            const chunk: @Vector(VecLen, u8) = ptr.*;
            const splat0: @Vector(VecLen, u8) = @splat(special_chars[0]);
            var mask = chunk == splat0;
            inline for (special_chars[1..]) |ch| {
                const splat_ch: @Vector(VecLen, u8) = @splat(ch);
                mask = mask | (chunk == splat_ch);
            }
            if (@reduce(.Or, mask)) {
                var j: usize = 0;
                while (j < VecLen) : (j += 1) {
                    if (mask[j]) return i + j;
                }
            }
        }
        while (i < text.len) : (i += 1) {
            if (parser.is_special_char[text[i]]) return i;
        }
        return text.len;
    }

    fn parseInlineContent(parser: *const OctomarkParser, text: []const u8, output: *FastWriter) ParseError!void {
        const length = text.len;
        var i: usize = 0;
        while (i < length) {
            const next = parser.nextSpecialIndex(text, i);
            if (next > i) {
                try output.writeAll(text[i..next]);
                i = next;
                if (i >= length) break;
            }

            if (text[i] == '<' and parser.options.enable_html) {
                const tag_len = parseHtmlTag(text[i..]);
                if (tag_len > 0) {
                    try output.writeAll(text[i .. i + tag_len]);
                    i += tag_len;
                    continue;
                }
            }

            const c = text[i];
            var handled = true;
            if (c == '\\') {
                if (i + 1 < length) {
                    i += 1;
                    try output.writeByte(text[i]);
                } else {
                    try output.writeAll("<br>");
                }
            } else if (c == '_') {
                const content_start = i + 1;
                const end_offset = std.mem.indexOfScalar(u8, text[content_start..], '_');
                if (end_offset) |offset| {
                    const j = content_start + offset;
                    try output.writeAll("<em>");
                    try parser.parseInlineContent(text[content_start..j], output);
                    try output.writeAll("</em>");
                    i = j;
                } else {
                    handled = false;
                }
            } else if (c == '*' and i + 1 < length and text[i + 1] == '*') {
                const content_start = i + 2;
                const end_offset = std.mem.indexOf(u8, text[content_start..], "**");
                if (end_offset) |offset| {
                    const j = content_start + offset;
                    try output.writeAll("<strong>");
                    try parser.parseInlineContent(text[content_start..j], output);
                    try output.writeAll("</strong>");
                    i = j + 1;
                } else {
                    handled = false;
                }
            } else if (c == '`') {
                var backtick_count: usize = 1;
                while (i + backtick_count < length and text[i + backtick_count] == '`') : (backtick_count += 1) {}
                try output.writeAll("<code>");
                const content_start = i + backtick_count;
                var found = false;
                while (i + backtick_count < length) {
                    i += 1;
                    var match = true;
                    var k: usize = 0;
                    while (k < backtick_count) : (k += 1) {
                        if (i + k >= length or text[i + k] != '`') {
                            match = false;
                            break;
                        }
                    }
                    if (match) {
                        found = true;
                        break;
                    }
                }
                if (found) {
                    if (i > content_start) try parser.appendEscapedText(text[content_start..i], output);
                    try output.writeAll("</code>");
                    i += backtick_count - 1;
                } else {
                    try output.writeAll("</code>");
                    i = content_start - 1;
                }
            } else if (c == '~' and i + 1 < length and text[i + 1] == '~') {
                try output.writeAll("<del>");
                i += 2;
                const content_start = i;
                while (i + 1 < length and (text[i] != '~' or text[i + 1] != '~')) : (i += 1) {}
                try parser.parseInlineContent(text[content_start..i], output);
                try output.writeAll("</del>");
                i += 1;
            } else if (c == '!' or c == '[') {
                const start_idx = i;
                if (c == '!') i += 1;
                if (i < length and text[i] == '[') {
                    i += 1;
                    const link_text_start = i;
                    var depth: usize = 1;
                    while (i < length and depth > 0) {
                        if (text[i] == '[') depth += 1 else if (text[i] == ']') depth -= 1;
                        i += 1;
                    }
                    if (i < length and text[i] == '(') {
                        const link_text_len = i - link_text_start - 1;
                        i += 1;
                        const url_start = i;
                        while (i < length and text[i] != ')' and text[i] != ' ') : (i += 1) {}
                        const url_len = i - url_start;
                        while (i < length and text[i] != ')') : (i += 1) {}
                        if (c == '!') {
                            try output.writeAll("<img src=\"");
                            try output.writeAll(text[url_start .. url_start + url_len]);
                            try output.writeAll("\" alt=\"");
                            try output.writeAll(text[link_text_start .. link_text_start + link_text_len]);
                            try output.writeAll("\">");
                        } else {
                            try output.writeAll("<a href=\"");
                            try output.writeAll(text[url_start .. url_start + url_len]);
                            try output.writeAll("\">");
                            try parser.parseInlineContent(text[link_text_start .. link_text_start + link_text_len], output);
                            try output.writeAll("</a>");
                        }
                        i += 1;
                        continue;
                    }
                }
                i = start_idx;
                handled = false;
            } else if (c == 'h' and text.len - i >= 7 and
                std.mem.startsWith(u8, text[i..], "http") and
                ((text.len - i >= 7 and std.mem.startsWith(u8, text[i + 4 ..], "://")) or
                    (text.len - i >= 8 and std.mem.startsWith(u8, text[i + 4 ..], "s://"))))
            {
                const url_start = i;
                while (i < length and !std.ascii.isWhitespace(text[i]) and text[i] != '<' and text[i] != '>') : (i += 1) {}
                try output.writeAll("<a href=\"");
                try output.writeAll(text[url_start..i]);
                try output.writeAll("\">");
                try output.writeAll(text[url_start..i]);
                try output.writeAll("</a>");
                i -= 1;
            } else if (c == '$') {
                try output.writeAll("<span class=\"math\">");
                i += 1;
                const content_start = i;
                if (std.mem.indexOfScalar(u8, text[content_start..], '$')) |offset| {
                    i = content_start + offset;
                } else {
                    i = length;
                }
                if (i > content_start) try parser.appendEscapedText(text[content_start..i], output);
                try output.writeAll("</span>");
            } else {
                handled = false;
            }

            if (!handled) {
                const entity = parser.html_escape_map[c];
                if (entity) |value| {
                    try output.writeAll(value);
                } else {
                    try output.writeByte(c);
                }
            }

            i += 1;
        }
    }

    fn processLeafBlockContinuation(parser: *OctomarkParser, line: []const u8, output: *FastWriter) ParseError!bool {
        const top = parser.currentBlockType();
        if (top != .code and top != .math) return false;

        const trimmed = std.mem.trimLeft(u8, line, &std.ascii.whitespace);

        if (top == .code) {
            if (trimmed.len >= 3 and std.mem.eql(u8, trimmed[0..3], "```")) {
                try parser.renderAndCloseTopBlock(output);
                return true;
            }
        } else {
            if (trimmed.len >= 2 and std.mem.eql(u8, trimmed[0..2], "$$")) {
                try parser.renderAndCloseTopBlock(output);
                return true;
            }
        }

        try parser.appendEscapedText(line, output);
        try output.writeByte('\n');
        return true;
    }

    fn parseFencedCodeBlock(parser: *OctomarkParser, line_content: []const u8, output: *FastWriter) ParseError!bool {
        if (line_content.len >= 3 and std.mem.eql(u8, line_content[0..3], "```")) {
            try parser.closeLeafBlocks(output);
            try output.writeAll("<pre><code");
            var lang_len: usize = 0;
            while (3 + lang_len < line_content.len and !std.ascii.isWhitespace(line_content[3 + lang_len])) : (lang_len += 1) {}
            if (lang_len > 0) {
                try output.writeAll(" class=\"language-");
                try parser.appendEscapedText(line_content[3 .. 3 + lang_len], output);
                try output.writeAll("\"");
            }
            try output.writeAll(">");
            parser.pushBlock(.code, 0);
            return true;
        }
        return false;
    }

    fn parseMathBlock(parser: *OctomarkParser, line_content: []const u8, output: *FastWriter) ParseError!bool {
        if (line_content.len >= 2 and std.mem.eql(u8, line_content[0..2], "$$")) {
            try parser.closeLeafBlocks(output);
            try output.writeAll("<div class=\"math\">\n");
            parser.pushBlock(.math, 0);
            return true;
        }
        return false;
    }

    fn parseHeader(parser: *OctomarkParser, line_content: []const u8, output: *FastWriter) ParseError!bool {
        if (line_content.len >= 2 and line_content[0] == '#') {
            var level: usize = 0;
            while (level < 6 and level < line_content.len and line_content[level] == '#') : (level += 1) {}
            if (level < line_content.len and line_content[level] == ' ') {
                try parser.closeLeafBlocks(output);
                const level_u8: u8 = @intCast(level);
                const level_char: u8 = '0' + level_u8;
                try output.writeAll("<h");
                try output.writeByte(level_char);
                try output.writeAll(">");
                try parser.parseInlineContent(line_content[level + 1 ..], output);
                try output.writeAll("</h");
                try output.writeByte(level_char);
                try output.writeAll(">\n");
                return true;
            }
        }
        return false;
    }

    fn parseHorizontalRule(parser: *OctomarkParser, line_content: []const u8, output: *FastWriter) ParseError!bool {
        if (line_content.len == 3 and (std.mem.eql(u8, line_content, "---") or std.mem.eql(u8, line_content, "***") or std.mem.eql(u8, line_content, "___"))) {
            try parser.closeLeafBlocks(output);
            try output.writeAll("<hr>\n");
            return true;
        }
        return false;
    }

    fn parseDefinitionList(parser: *OctomarkParser, line_content: *[]const u8, leading_spaces: usize, output: *FastWriter) ParseError!bool {
        var line = line_content.*;
        if (line.len > 0 and line[0] == ':') {
            line = line[1..];
            if (line.len > 0 and line[0] == ' ') line = line[1..];
            try parser.closeParagraphIfOpen(output);
            var in_dl = false;
            var in_dd = false;
            for (parser.block_stack[0..parser.stack_depth]) |entry| {
                if (entry.block_type == .definition_list) in_dl = true;
                if (entry.block_type == .definition_description) in_dd = true;
            }
            if (!in_dl) {
                try output.writeAll("<dl>\n");
                parser.pushBlock(.definition_list, @intCast(leading_spaces));
            }
            if (in_dd) {
                while (parser.currentBlockType() != .definition_list and parser.stack_depth > 0) {
                    try parser.renderAndCloseTopBlock(output);
                }
            }
            try output.writeAll("<dd>");
            parser.pushBlock(.definition_description, @intCast(leading_spaces));
            line_content.* = line;
            return true;
        }
        return false;
    }

    fn parseListItem(parser: *OctomarkParser, line_content: *[]const u8, leading_spaces: usize, output: *FastWriter) ParseError!bool {
        var line = line_content.*;
        const trimmed_line = std.mem.trimLeft(u8, line, &std.ascii.whitespace);
        const internal_spaces: usize = line.len - trimmed_line.len;

        const is_ul = (line.len - internal_spaces >= 2 and std.mem.eql(u8, line[internal_spaces .. internal_spaces + 2], "- "));
        const is_ol = (line.len - internal_spaces >= 3 and std.ascii.isDigit(line[internal_spaces]) and
            std.mem.eql(u8, line[internal_spaces + 1 .. internal_spaces + 3], ". "));

        if (is_ul or is_ol) {
            const target_type: BlockType = if (is_ul) .unordered_list else .ordered_list;
            const current_indent: i32 = @intCast(leading_spaces + internal_spaces);
            while (parser.stack_depth > 0 and
                parser.currentBlockType() != null and @intFromEnum(parser.currentBlockType().?) < @intFromEnum(BlockType.blockquote) and
                (parser.peekBlock().?.indent_level > current_indent or
                    (parser.peekBlock().?.indent_level == current_indent and parser.currentBlockType() != target_type)))
            {
                try parser.renderAndCloseTopBlock(output);
            }

            const top = parser.currentBlockType();
            if (top == target_type and parser.peekBlock().?.indent_level == current_indent) {
                try parser.closeLeafBlocks(output);
                try output.writeAll("</li>\n<li>");
            } else {
                try parser.closeLeafBlocks(output);
                try output.writeAll(if (target_type == .unordered_list) "<ul>\n<li>" else "<ol>\n<li>");
                parser.pushBlock(target_type, current_indent);
            }

            const marker_len: usize = if (is_ul) 2 else 3;
            line = line[internal_spaces + marker_len ..];
            if (is_ul and line.len >= 4 and line[0] == '[' and (line[1] == ' ' or line[1] == 'x') and line[2] == ']' and line[3] == ' ') {
                try output.writeAll(if (line[1] == 'x') "<input type=\"checkbox\" checked disabled> " else "<input type=\"checkbox\"  disabled> ");
                line = line[4..];
            }
            line_content.* = line;
            return true;
        }
        return false;
    }

    fn parseTable(parser: *OctomarkParser, line_content: []const u8, full_data: []const u8, current_pos: usize, output: *FastWriter) ParseError!bool {
        if (line_content.len > 0 and line_content[0] == '|') {
            if (parser.currentBlockType() != .table) {
                if (current_pos < full_data.len) {
                    const next_newline = std.mem.indexOfScalar(u8, full_data[current_pos..], '\n');
                    if (next_newline) |offset| {
                        const nl = current_pos + offset;
                        const lookahead = full_data[current_pos..nl];
                        const trimmed = std.mem.trimLeft(u8, lookahead, &std.ascii.whitespace);
                        if (trimmed.len > 0 and trimmed[0] == '|') {
                            try parser.closeLeafBlocks(output);
                            try output.writeAll("<table><thead><tr>");
                            parser.table_column_count = 0;
                            const p_index = if (lookahead.len > 0 and lookahead[0] == '|')
                                @as(?usize, 0)
                            else
                                std.mem.indexOfScalar(u8, lookahead, '|');
                            if (p_index) |pi| {
                                var p = pi + 1;
                                while (p < lookahead.len) {
                                    while (p < lookahead.len and std.ascii.isWhitespace(lookahead[p])) : (p += 1) {}
                                    if (p >= lookahead.len) break;
                                    const start = p;
                                    while (p < lookahead.len and lookahead[p] != '|') : (p += 1) {}
                                    var end = p;
                                    while (end > start and std.ascii.isWhitespace(lookahead[end - 1])) : (end -= 1) {}
                                    var col_align = TableAlignment.none;
                                    if (start < end and lookahead[start] == ':' and lookahead[end - 1] == ':') {
                                        col_align = .center;
                                    } else if (end > start and lookahead[end - 1] == ':') {
                                        col_align = .right;
                                    } else if (start < end and lookahead[start] == ':') {
                                        col_align = .left;
                                    }
                                    if (parser.table_column_count < parser.table_alignments.len) {
                                        parser.table_alignments[parser.table_column_count] = col_align;
                                        parser.table_column_count += 1;
                                    }
                                    if (p < lookahead.len and lookahead[p] == '|') p += 1;
                                }
                            }

                            var header_cells: [64][]const u8 = undefined;
                            const header_count = splitTableRowCells(line_content, &header_cells);
                            var k: usize = 0;
                            while (k < header_count) : (k += 1) {
                                try output.writeAll("<th");
                                const col_align = if (k < parser.table_column_count) parser.table_alignments[k] else TableAlignment.none;
                                switch (col_align) {
                                    .left => try output.writeAll(" style=\"text-align:left\""),
                                    .center => try output.writeAll(" style=\"text-align:center\""),
                                    .right => try output.writeAll(" style=\"text-align:right\""),
                                    .none => {},
                                }
                                try output.writeAll(">");
                                try parser.parseInlineContent(header_cells[k], output);
                                try output.writeAll("</th>");
                            }
                            try output.writeAll("</tr></thead><tbody>\n");
                            parser.pushBlock(.table, 0);
                            return true;
                        }
                    }
                }
            }

            if (parser.currentBlockType() == .table) {
                var body_cells: [64][]const u8 = undefined;
                const body_count = splitTableRowCells(line_content, &body_cells);
                try output.writeAll("<tr>");
                var k: usize = 0;
                while (k < body_count) : (k += 1) {
                    try output.writeAll("<td");
                    const col_align = if (k < parser.table_column_count) parser.table_alignments[k] else TableAlignment.none;
                    switch (col_align) {
                        .left => try output.writeAll(" style=\"text-align:left\""),
                        .center => try output.writeAll(" style=\"text-align:center\""),
                        .right => try output.writeAll(" style=\"text-align:right\""),
                        .none => {},
                    }
                    try output.writeAll(">");
                    try parser.parseInlineContent(body_cells[k], output);
                    try output.writeAll("</td>");
                }
                try output.writeAll("</tr>\n");
                return true;
            }
        }
        return false;
    }

    fn parseDefinitionTerm(parser: *OctomarkParser, line_content: []const u8, full_data: []const u8, current_pos: usize, output: *FastWriter) ParseError!bool {
        if (current_pos < full_data.len) {
            const next_newline = std.mem.indexOfScalar(u8, full_data[current_pos..], '\n');
            if (next_newline) |offset| {
                const nl = current_pos + offset;
                const trimmed = std.mem.trimLeft(u8, full_data[current_pos..nl], &std.ascii.whitespace);
                if (trimmed.len > 0 and trimmed[0] == ':') {
                    try parser.closeLeafBlocks(output);
                    if (parser.stack_depth == 0 or parser.currentBlockType() != .definition_list) {
                        try output.writeAll("<dl>\n");
                        parser.pushBlock(.definition_list, 0);
                    }
                    try output.writeAll("<dt>");
                    try parser.parseInlineContent(line_content, output);
                    try output.writeAll("</dt>\n");
                    return true;
                }
            }
        }
        return false;
    }

    fn processParagraph(parser: *OctomarkParser, line_content: []const u8, is_dl: bool, is_list: bool, output: *FastWriter) ParseError!void {
        const block_type = parser.currentBlockType();
        const in_container = (parser.stack_depth > 0 and
            (block_type != null and
                (@intFromEnum(block_type.?) < @intFromEnum(BlockType.blockquote) or block_type.? == .definition_description)));

        if (parser.currentBlockType() != .paragraph and !in_container) {
            try output.writeAll("<p>");
            parser.pushBlock(.paragraph, 0);
        } else if (parser.currentBlockType() == .paragraph or (in_container and !is_list and !is_dl)) {
            try output.writeByte('\n');
        }

        const line_break = (line_content.len >= 2 and line_content[line_content.len - 1] == ' ' and line_content[line_content.len - 2] == ' ');
        try parser.parseInlineContent(if (line_break) line_content[0 .. line_content.len - 2] else line_content, output);
        if (line_break) try output.writeAll("<br>");
    }

    fn processSingleLine(parser: *OctomarkParser, line: []const u8, full_data: []const u8, current_pos: usize, output: *FastWriter) ParseError!bool {
        if (try parser.processLeafBlockContinuation(line, output)) return false;

        const trimmed_line = std.mem.trimLeft(u8, line, &std.ascii.whitespace);
        const leading_spaces: usize = line.len - trimmed_line.len;
        var line_content = trimmed_line;

        if (line_content.len == 0) {
            try parser.closeLeafBlocks(output);
            while (parser.stack_depth > 0 and parser.currentBlockType() != null and @intFromEnum(parser.currentBlockType().?) >= @intFromEnum(BlockType.blockquote)) {
                try parser.renderAndCloseTopBlock(output);
            }
            return false;
        }

        var quote_level: usize = 0;
        while (line_content.len > 0 and line_content[0] == '>') {
            quote_level += 1;
            line_content = line_content[1..];
            if (line_content.len > 0 and line_content[0] == ' ') line_content = line_content[1..];
        }

        var current_quote_level: usize = 0;
        for (parser.block_stack[0..parser.stack_depth]) |entry| {
            if (entry.block_type == .blockquote) current_quote_level += 1;
        }

        if (quote_level < current_quote_level and parser.currentBlockType() == .paragraph) {
            const trimmed_for_block = std.mem.trimLeft(u8, line_content, &std.ascii.whitespace);
            if (!isBlockStartMarker(trimmed_for_block)) quote_level = current_quote_level;
        }

        while (current_quote_level > quote_level) {
            const t = parser.currentBlockType().?;
            try parser.renderAndCloseTopBlock(output);
            if (t == .blockquote) current_quote_level -= 1;
        }

        while (parser.stack_depth < quote_level) {
            try parser.closeParagraphIfOpen(output);
            try output.writeAll("<blockquote>");
            parser.pushBlock(.blockquote, 0);
        }

        const is_dl = try parser.parseDefinitionList(&line_content, leading_spaces, output);
        const is_list = try parser.parseListItem(&line_content, leading_spaces, output);

        if (try parser.parseFencedCodeBlock(line_content, output)) return false;
        if (try parser.parseMathBlock(line_content, output)) return false;
        if (try parser.parseHeader(line_content, output)) return false;
        if (try parser.parseHorizontalRule(line_content, output)) return false;
        if (try parser.parseTable(line_content, full_data, current_pos, output)) return true;
        if (try parser.parseDefinitionTerm(line_content, full_data, current_pos, output)) return false;

        try parser.processParagraph(line_content, is_dl, is_list, output);
        return false;
    }
};

fn parseHtmlTag(text: []const u8) usize {
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

fn splitTableRowCells(line: []const u8, cells: *[64][]const u8) usize {
    var count: usize = 0;
    var cursor = std.mem.trimLeft(u8, line, &std.ascii.whitespace);
    if (cursor.len > 0 and cursor[0] == '|') cursor = cursor[1..];
    while (cursor.len > 0) {
        cursor = std.mem.trimLeft(u8, cursor, &std.ascii.whitespace);
        if (cursor.len == 0 or cursor[0] == '\n') break;
        const end_offset = std.mem.indexOfScalar(u8, cursor, '|') orelse cursor.len;
        var cell = cursor[0..end_offset];
        cell = std.mem.trimRight(u8, cell, &std.ascii.whitespace);
        if (count < cells.len) {
            cells[count] = cell;
            count += 1;
        }
        if (end_offset >= cursor.len) break;
        cursor = cursor[end_offset + 1 ..];
    }
    return count;
}

fn isBlockStartMarker(str: []const u8) bool {
    if (str.len >= 3 and std.mem.eql(u8, str[0..3], "```")) return true;
    if (str.len >= 2 and std.mem.eql(u8, str[0..2], "$$")) return true;
    if (str.len >= 1 and (str[0] == '#' or str[0] == ':')) return true;
    if (str.len >= 2 and std.mem.eql(u8, str[0..2], "- ")) return true;
    if (str.len >= 3 and std.ascii.isDigit(str[0]) and std.mem.eql(u8, str[1..3], ". ")) return true;
    if (str.len >= 3 and (std.mem.eql(u8, str[0..3], "---") or std.mem.eql(u8, str[0..3], "***") or std.mem.eql(u8, str[0..3], "___"))) return true;
    return false;
}
