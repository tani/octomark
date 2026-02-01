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
    table_header_pending = 9,
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

pub const OctomarkParser = struct {
    is_special_char: [256]bool = [_]bool{false} ** 256,
    html_escape_map: [256]?[]const u8 = [_]?[]const u8{null} ** 256,
    table_alignments: [64]TableAlignment = [_]TableAlignment{TableAlignment.none} ** 64,
    table_column_count: usize = 0,
    block_stack: [MAX_BLOCK_NESTING]BlockEntry = undefined,
    stack_depth: usize = 0,
    pending_buffer: Buffer = .{},
    options: OctomarkOptions = .{},
    table_header_storage: Buffer = .{},
    table_header_pending: bool = false,
    allocator: std.mem.Allocator = undefined,

    /// Initialize parser state. Returns error.OutOfMemory on allocation failure.
    pub fn init(self: *OctomarkParser, allocator: std.mem.Allocator) !void {
        self.* = OctomarkParser{ .allocator = allocator };
        const special = "\\['*`&<>\"'_~!$h";
        for (special) |ch| self.is_special_char[ch] = true;
        self.html_escape_map['&'] = "&amp;";
        self.html_escape_map['<'] = "&lt;";
        self.html_escape_map['>'] = "&gt;";
        self.html_escape_map['\"'] = "&quot;";
        self.html_escape_map['\''] = "&#39;";
        self.pending_buffer = .{};
        try self.pending_buffer.ensureTotalCapacity(allocator, 4096);
        self.table_header_storage = .{};
        try self.table_header_storage.ensureTotalCapacity(allocator, 1024);
        self.options = .{};
    }

    /// Release parser-owned buffers. Safe to call after any error.
    pub fn deinit(self: *OctomarkParser, allocator: std.mem.Allocator) void {
        self.pending_buffer.deinit(allocator);
        self.table_header_storage.deinit(allocator);
    }

    /// Enable parsing options.
    pub fn setOptions(self: *OctomarkParser, options: OctomarkOptions) void {
        self.options = options;
    }

    /// Feed a chunk into the parser. Returns error.OutOfMemory or writer errors.
    pub fn parse(self: *OctomarkParser, reader: anytype, writer: anytype, allocator: std.mem.Allocator) !void {
        var buffer: [4096]u8 = undefined;
        while (true) {
            const n = try reader.readSliceShort(&buffer);
            if (n == 0) break;
            try self.feed(buffer[0..n], writer, allocator);
        }
        try self.finish(writer);
    }

    /// Feed a chunk into the parser. Returns error.OutOfMemory or writer errors.
    pub fn feed(self: *OctomarkParser, chunk: []const u8, output: anytype, allocator: std.mem.Allocator) !void {
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
        if (self.table_header_pending) {
            self.table_header_pending = false;
            try self.processParagraph(self.table_header_storage.items, false, false, output);
        }
        while (self.stack_depth > 0) try self.renderAndCloseTopBlock(output);
    }

    fn pushBlock(parser: *OctomarkParser, block_type: BlockType, indent: i32) !void {
        if (parser.stack_depth >= MAX_BLOCK_NESTING) return error.NestingTooDeep;
        parser.block_stack[parser.stack_depth] = BlockEntry{ .block_type = block_type, .indent_level = indent };
        parser.stack_depth += 1;
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

    fn renderAndCloseTopBlock(parser: *OctomarkParser, output: anytype) !void {
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
            .table_header_pending => unreachable,
        }
    }

    fn closeParagraphIfOpen(parser: *OctomarkParser, output: anytype) !void {
        if (parser.currentBlockType() == .paragraph) try parser.renderAndCloseTopBlock(output);
    }

    fn closeLeafBlocks(parser: *OctomarkParser, output: anytype) !void {
        const block_type = parser.currentBlockType();
        if (block_type == .paragraph or block_type == .table or block_type == .code or block_type == .math) {
            try parser.renderAndCloseTopBlock(output);
        }
    }

    fn appendEscapedText(parser: *const OctomarkParser, text: []const u8, output: anytype) !void {
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

    fn parseInlineContent(parser: *const OctomarkParser, text: []const u8, output: anytype) !void {
        const length = text.len;
        var i: usize = 0;
        while (i < length) {
            const start = i;
            while (i + 7 < length) {
                if (parser.is_special_char[text[i]] or
                    parser.is_special_char[text[i + 1]] or
                    parser.is_special_char[text[i + 2]] or
                    parser.is_special_char[text[i + 3]] or
                    parser.is_special_char[text[i + 4]] or
                    parser.is_special_char[text[i + 5]] or
                    parser.is_special_char[text[i + 6]] or
                    parser.is_special_char[text[i + 7]])
                {
                    break;
                }
                i += 8;
            }

            while (i < length and !parser.is_special_char[text[i]]) : (i += 1) {}

            if (i > start) try output.writeAll(text[start..i]);
            if (i >= length) break;

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

    fn processLeafBlockContinuation(parser: *OctomarkParser, line: []const u8, output: anytype) !bool {
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

    fn parseFencedCodeBlock(parser: *OctomarkParser, line_content: []const u8, output: anytype) !bool {
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
            try parser.pushBlock(.code, 0);
            return true;
        }
        return false;
    }

    fn parseMathBlock(parser: *OctomarkParser, line_content: []const u8, output: anytype) !bool {
        if (line_content.len >= 2 and std.mem.eql(u8, line_content[0..2], "$$")) {
            try parser.closeLeafBlocks(output);
            try output.writeAll("<div class=\"math\">\n");
            try parser.pushBlock(.math, 0);
            return true;
        }
        return false;
    }

    fn parseHeader(parser: *OctomarkParser, line_content: []const u8, output: anytype) !bool {
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

    fn parseHorizontalRule(parser: *OctomarkParser, line_content: []const u8, output: anytype) !bool {
        if (line_content.len == 3 and (std.mem.eql(u8, line_content, "---") or std.mem.eql(u8, line_content, "***") or std.mem.eql(u8, line_content, "___"))) {
            try parser.closeLeafBlocks(output);
            try output.writeAll("<hr>\n");
            return true;
        }
        return false;
    }

    fn parseDefinitionList(parser: *OctomarkParser, line_content: *[]const u8, leading_spaces: usize, output: anytype) !bool {
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
                try parser.pushBlock(.definition_list, @intCast(leading_spaces));
            }
            if (in_dd) {
                while (parser.currentBlockType() != .definition_list and parser.stack_depth > 0) {
                    try parser.renderAndCloseTopBlock(output);
                }
            }
            try output.writeAll("<dd>");
            try parser.pushBlock(.definition_description, @intCast(leading_spaces));
            line_content.* = line;
            return true;
        }
        return false;
    }

    fn parseListItem(parser: *OctomarkParser, line_content: *[]const u8, leading_spaces: usize, output: anytype) !bool {
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
                try parser.pushBlock(target_type, current_indent);
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

    fn parseTable(parser: *OctomarkParser, line_content: []const u8, _: []const u8, _: usize, output: anytype) !bool {
        const trimmed_line = std.mem.trim(u8, line_content, &std.ascii.whitespace);
        if (trimmed_line.len > 0 and trimmed_line[0] == '|') {
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

            // Lookahead for separator row
            const is_separator = blk: {
                if (trimmed_line.len < 3) break :blk false;
                var has_dash = false;
                for (trimmed_line) |c| {
                    if (c == '-' or c == ':' or c == '|') {
                        if (c == '-') has_dash = true;
                        continue;
                    }
                    if (!std.ascii.isWhitespace(c)) break :blk false;
                }
                break :blk has_dash;
            };

            if (is_separator and parser.table_header_pending) {
                try parser.closeLeafBlocks(output);
                try output.writeAll("<table><thead><tr>");
                parser.table_column_count = 0;

                // Parse alignment from separator row
                var p: usize = 0;
                if (trimmed_line[0] == '|') p += 1;
                while (p < trimmed_line.len) {
                    while (p < trimmed_line.len and std.ascii.isWhitespace(trimmed_line[p])) : (p += 1) {}
                    if (p >= trimmed_line.len) break;
                    const start = p;
                    while (p < trimmed_line.len and trimmed_line[p] != '|') : (p += 1) {}
                    var end = p;
                    while (end > start and std.ascii.isWhitespace(trimmed_line[end - 1])) : (end -= 1) {}

                    var col_align = TableAlignment.none;
                    if (start < end) {
                        const cell = trimmed_line[start..end];
                        if (cell.len >= 2) {
                            if (cell[0] == ':' and cell[cell.len - 1] == ':') col_align = .center else if (cell[cell.len - 1] == ':') col_align = .right else if (cell[0] == ':') col_align = .left;
                        }
                    }

                    if (parser.table_column_count < parser.table_alignments.len) {
                        parser.table_alignments[parser.table_column_count] = col_align;
                        parser.table_column_count += 1;
                    } else {
                        // Cap at max columns
                        break;
                    }
                    if (p < trimmed_line.len and trimmed_line[p] == '|') p += 1;
                }

                var header_cells: [64][]const u8 = undefined;
                const header_count = splitTableRowCells(parser.table_header_storage.items, &header_cells);
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
                try parser.pushBlock(.table, 0);
                parser.table_header_pending = false;
                return true;
            }

            // Not a separator, could be a header
            if (parser.table_header_pending) {
                // Flush previous pending header as paragraph
                try parser.processParagraph(parser.table_header_storage.items, false, false, output);
            }
            parser.table_header_storage.clearRetainingCapacity();
            try parser.table_header_storage.appendSlice(parser.allocator, line_content);
            parser.table_header_pending = true;
            return true;
        }

        if (parser.table_header_pending) {
            parser.table_header_pending = false;
            try parser.processParagraph(parser.table_header_storage.items, false, false, output);
        }
        return false;
    }

    fn parseDefinitionTerm(parser: *OctomarkParser, line_content: []const u8, full_data: []const u8, current_pos: usize, output: anytype) !bool {
        if (current_pos < full_data.len) {
            const next_newline = std.mem.indexOfScalar(u8, full_data[current_pos..], '\n');
            if (next_newline) |offset| {
                const nl = current_pos + offset;
                const trimmed = std.mem.trimLeft(u8, full_data[current_pos..nl], &std.ascii.whitespace);
                if (trimmed.len > 0 and trimmed[0] == ':') {
                    try parser.closeLeafBlocks(output);
                    if (parser.stack_depth == 0 or parser.currentBlockType() != .definition_list) {
                        try output.writeAll("<dl>\n");
                        try parser.pushBlock(.definition_list, 0);
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

    fn processParagraph(parser: *OctomarkParser, line_content: []const u8, is_dl: bool, is_list: bool, output: anytype) !void {
        const block_type = parser.currentBlockType();
        const in_container = (parser.stack_depth > 0 and
            (block_type != null and
                (@intFromEnum(block_type.?) < @intFromEnum(BlockType.blockquote) or block_type.? == .definition_description)));

        if (parser.currentBlockType() != .paragraph and !in_container) {
            try output.writeAll("<p>");
            try parser.pushBlock(.paragraph, 0);
        } else if (parser.currentBlockType() == .paragraph or (in_container and !is_list and !is_dl)) {
            try output.writeByte('\n');
        }

        const line_break = (line_content.len >= 2 and line_content[line_content.len - 1] == ' ' and line_content[line_content.len - 2] == ' ');
        try parser.parseInlineContent(if (line_break) line_content[0 .. line_content.len - 2] else line_content, output);
        if (line_break) try output.writeAll("<br>");
    }

    fn processSingleLine(parser: *OctomarkParser, line: []const u8, full_data: []const u8, current_pos: usize, output: anytype) !bool {
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
            try parser.pushBlock(.blockquote, 0);
        }

        const is_dl = try parser.parseDefinitionList(&line_content, leading_spaces, output);
        const is_list = try parser.parseListItem(&line_content, leading_spaces, output);

        if (try parser.parseFencedCodeBlock(line_content, output)) return false;
        if (try parser.parseMathBlock(line_content, output)) return false;
        if (try parser.parseHeader(line_content, output)) return false;
        if (try parser.parseHorizontalRule(line_content, output)) return false;
        if (try parser.parseTable(line_content, full_data, current_pos, output)) return false;
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

fn splitTableRowCells(str: []const u8, cells: *[64][]const u8) usize {
    var count: usize = 0;
    var cursor = std.mem.trim(u8, str, &std.ascii.whitespace);
    if (cursor.len > 0 and cursor[0] == '|') cursor = cursor[1..];

    while (cursor.len > 0) {
        const end_offset = std.mem.indexOfScalar(u8, cursor, '|') orelse cursor.len;
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

fn isBlockStartMarker(str: []const u8) bool {
    if (str.len >= 3 and std.mem.eql(u8, str[0..3], "```")) return true;
    if (str.len >= 2 and std.mem.eql(u8, str[0..2], "$$")) return true;
    if (str.len >= 1 and (str[0] == '#' or str[0] == ':')) return true;
    if (str.len >= 2 and std.mem.eql(u8, str[0..2], "- ")) return true;
    if (str.len >= 3 and std.ascii.isDigit(str[0]) and std.mem.eql(u8, str[1..3], ". ")) return true;
    if (str.len >= 3 and (std.mem.eql(u8, str[0..3], "---") or std.mem.eql(u8, str[0..3], "***") or std.mem.eql(u8, str[0..3], "___"))) return true;
    return false;
}
