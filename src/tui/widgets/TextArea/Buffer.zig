const Buffer = @This();

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

const vx = @import("vaxis");
const Key = vx.Key;

const Cell = @import("../../layout/Cell.zig");
const Config = @import("../../../Config.zig");
const fs = @import("../../../fs.zig");
const History = @import("History.zig");
const TextArea = @import("TextArea.zig");
const Char = Cell.Character;
//const Char = vx.Cell.Character;
const Vim = @import("Vim.zig");

alloc: std.mem.Allocator,

index: usize = 0,

parent: *TextArea,

/// The cursor column index
col: i32 = 0,

/// Last cursor column, used to maintain state when the cursor is moved
/// vertically such that we can maintain the same navigating position.
last_col: i32 = 0,

/// The cursor row index
row: i32 = 0,

/// The number of rows on a multiline the cursor is offset from the start
/// of the line.
row_offset: u16 = 0,

/// List of all buffer rows.
rows: std.ArrayList(*Row),

/// Whether the buffer has any changes.
is_dirty: bool = false,

history: *History,

file_content: []u8,

current_patch: []const u8,

/// Holds the previous text value of the current buffer.
/// Currently used for storing the value before entering any vim mode
/// that alters the text, so that we can create a reliable history.
prev_value: []const u8,

cursor_pos: CursorPos = .{},

/// The path of the file that is loaded into the buffer.
path: []const u8 = "",

/// The path of the file that is loaded into the buffer.
rel_path: []const u8 = "",

pub const CursorPos = struct {
    row: i32 = 0,
    row_offset: u16 = 0,
    col: i32 = 0,
};

/// A single buffer row
pub const Row = struct {
    alloc: std.mem.Allocator,

    /// The buffer's text value
    value: std.ArrayList(Char),

    /// Cursor column
    col: i32,

    /// Offset from the top of the row on multilines
    offset: i16,

    pub fn init(alloc: std.mem.Allocator, offset: i16) !*Row {
        const self = try alloc.create(Row);

        self.* = .{
            .alloc = alloc,
            .value = .empty,
            .col = 0,
            .offset = offset,
        };

        return self;
    }

    pub fn insertSliceAtCursor(self: *Row, slice: []const u8) !void {
        try self.value.insert(self.alloc, @intCast(self.col), .{
            .grapheme = slice,
            .width = 1,
        });
    }

    pub inline fn len(self: Row) usize {
        return self.value.items.len;
    }

    pub inline fn getValue(self: Row) []Char {
        return self.value.items;
    }

    pub inline fn getValueStr(self: Row) ![]const u8 {
        var row: std.ArrayList(u8) = .empty;
        for (self.value.items) |char| {
            try row.append(self.alloc, char.grapheme[0]);
        }
        return try row.toOwnedSlice(self.alloc);
    }

    pub fn eql(self: *Row, cmp: []const u8) bool {
        var i: usize = 0;

        for (self.value.items) |char| {
            if (i >= cmp.len) {
                return false;
            }

            if (char.grapheme[0] != cmp[i]) {
                return false;
            }

            i += 1;
        }

        return true;
    }

    pub fn appendChar(self: *Row, char: Char) !void {
        try self.value.append(self.alloc, char);
    }

    pub inline fn deleteCharAt(self: *Row, index: usize) void {
        _ = self.value.orderedRemove(index);
    }

    pub inline fn shrinkAndFree(self: *Row) void {
        self.value.shrinkAndFree(self.alloc, self.len());
    }

    pub fn deinit(self: *Row) void {
        self.value.deinit(self.alloc);
    }
};

pub fn init(alloc: std.mem.Allocator, parent: *TextArea) !*Buffer {
    const self = try alloc.create(Buffer);

    self.* = .{
        .alloc = alloc,
        .parent = parent,
        .rows = .empty,
        .history = undefined,
        .file_content = "",
        .prev_value = "",
        .current_patch = try alloc.alloc(u8, 0),
    };

    // add first row
    try self.addRow(0);

    return self;
}

pub fn getName(self: Buffer) []const u8 {
    const file = std.fs.path.basename(self.path);
    return std.mem.trimEnd(u8, file, fs.Notes.ext);
}

pub fn setIndex(self: *Buffer, index: usize) void {
    self.index = index;
}

pub fn setPaths(self: *Buffer, path: []const u8) !void {
    self.path = try self.alloc.dupe(u8, path);

    const notes_root = try self.parent.app.config.getNotesRootDir();

    if (!std.mem.startsWith(u8, self.path, notes_root)) {
        return;
    }

    self.rel_path = self.path[notes_root.len..];

    if (std.fs.path.dirname(path)) |dir_name| {
        const len = dir_name.len - notes_root.len;
        const p: []u8 = @constCast(self.rel_path);
        _ = std.mem.replace(u8, dir_name, notes_root, "", p);
        self.rel_path = self.rel_path[1..len];
    }
}

pub fn setContentFromStr(self: *Buffer, content: []const u8) !void {
    self.alloc.free(self.current_patch);
    self.current_patch = try self.alloc.dupe(u8, content);

    for (self.rows.items) |row| {
        row.value.clearAndFree(self.alloc);
        self.alloc.destroy(row);
    }

    self.rows.clearRetainingCapacity();

    var lines = std.mem.splitAny(u8, self.current_patch, "\n");
    var i: usize = 0;

    while (lines.next()) |line| {
        try self.addRow(0);

        var g_iter = vx.unicode.graphemeIterator(line);
        while (g_iter.next()) |g| {
            try self.rows.items[i].appendChar(.{
                .grapheme = g.bytes(line),
                .width = 1,
            });
        }

        i += 1;
    }
}

pub fn setContentFromFile(self: *Buffer, file_path: []const u8) !void {
    const file = std.fs.openFileAbsolute(
        file_path,
        .{ .mode = .read_write },
    ) catch return;

    defer file.close();
    const stat = try file.stat();
    const size = stat.size;

    // Empty file - nothing to read.
    if (stat.size == 0) {
        try self.curRow().appendChar(.{ .grapheme = "", .width = 1 });
        return;
    }

    self.file_content = try self.alloc.alloc(u8, size);
    self.current_patch = try self.alloc.alloc(u8, size);
    self.prev_value = try self.alloc.alloc(u8, size);
    var reader = file.reader(self.file_content);
    var i: usize = 0;

    try reader.interface.readSliceAll(self.file_content);
    var lines = std.mem.splitAny(u8, self.file_content, "\n");

    while (lines.next()) |line| {
        if (i > 0) {
            try self.addRow(0);
        }

        var iter = vx.unicode.graphemeIterator(line);
        while (iter.next()) |g| {
            try self.curRow().appendChar(.{
                .grapheme = g.bytes(line),
                .width = 1,
            });
        }

        i += 1;
    }
}

/// Appends a new row after the last.
pub fn addRow(self: *Buffer, offset: usize) !void {
    if (self.rows.items.len > 0) {
        self.row += 1;
    }
    self.col = 0;

    try self.rows.append(self.alloc, try Row.init(
        self.alloc,
        @intCast(offset),
    ));
}

/// Adds a new row at `index`
pub fn addRowAt(self: *Buffer, index: usize, offset: i32) !void {
    try self.rows.insert(
        self.alloc,
        index,
        try .init(self.alloc, @intCast(offset)),
    );
}

/// Splits the current row and moves the value after the cursor to
/// a new line
pub fn splitRow(self: *Buffer) !void {
    const cur_row: *Row = self.curRow();
    const col: u32 = @intCast(self.col);
    const after_cursor: []Char = cur_row.getValue()[col..];

    // make a copy of the value after the cursor that needs to be moved
    // to the next line.
    const after_cursor_cp: []Char = try self.alloc.alloc(
        Char,
        after_cursor.len,
    );
    defer self.alloc.free(after_cursor_cp);
    @memmove(after_cursor_cp, after_cursor);

    // Remove the value after the cursor from the current line.
    for (col..cur_row.len()) |_| {
        _ = cur_row.deleteCharAt(col);
    }

    // Add new below
    self.row += 1;
    self.col = 0;
    try self.addRowAt(@intCast(self.row), 0);

    // Append copied value to the new line.
    for (after_cursor_cp) |char| {
        try self.curRow().appendChar(char);
    }
}

pub fn updatePrevVal(self: *Buffer) !void {
    self.alloc.free(self.prev_value);
    self.prev_value = try self.getString(self.alloc, null);
}

pub fn getString(self: *Buffer, alloc: std.mem.Allocator, rows: ?[]*Row) ![]u8 {
    var items = self.rows.items;
    if (rows != null) {
        items = rows.?;
    }

    const total = self.totalByteLen(items) - 1;
    var buffer = try alloc.alloc(u8, total);
    var index: usize = 0;
    var row_index = index;

    for (items) |row| {
        defer row_index += 1;

        for (row.value.items) |ch| {
            std.mem.copyForwards(
                u8,
                buffer[index .. index + ch.grapheme.len],
                ch.grapheme,
            );
            index += ch.grapheme.len;
        }

        if (row_index + 1 < self.rows.items.len) {
            buffer[index] = '\n';
            index += 1;
        }
    }

    return buffer;
}

fn totalByteLen(self: *Buffer, rows: []const *Row) usize {
    _ = self;
    var total: usize = 0;

    for (rows) |row| {
        for (row.value.items) |ch| {
            total += ch.grapheme.len;
        }
        total += 1;
    }

    return total;
}

pub fn getHash(self: *Buffer) !u64 {
    const str = try self.getString(self.alloc, null);
    defer self.alloc.free(str);
    const hash = fastHash(str);
    return hash;
}

/// Returns a reference to the current row.
pub fn curRow(self: *Buffer) *Row {
    return self.rows.items[@intCast(self.row)];
}

pub fn numRows(self: Buffer) usize {
    return self.rows.items.len;
}

pub fn cursorPos(self: Buffer) CursorPos {
    return self.cursor_pos;
}

pub fn updateCursorPos(self: *Buffer) void {
    self.cursor_pos.col = self.col;
    self.cursor_pos.row = self.row;
    self.cursor_pos.row_offset = self.row_offset;
}

pub fn shrinkAndFree(self: *Buffer) void {
    self.rows.shrinkAndFree(self.alloc, self.numRows());
}

pub fn deinit(self: *Buffer) void {
    for (self.rows.items) |row| {
        row.deinit();
        self.alloc.destroy(row);
    }
    self.rows.deinit(self.alloc);
    self.alloc.free(self.prev_value);

    self.alloc.free(self.file_content);
    self.alloc.free(self.current_patch);
    self.alloc.free(self.path);

    self.history.deinit();
    self.alloc.destroy(self.history);
}

pub fn hashStr(str: []const u8) [Sha256.digest_length]u8 {
    var sha256: Sha256 = .init(.{});
    sha256.update(str);
    return sha256.finalResult();
}

pub fn fastHash(str: []const u8) u64 {
    return std.hash.Wyhash.hash(0, str);
}
