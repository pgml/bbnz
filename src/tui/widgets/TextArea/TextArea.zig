const TextArea = @This();

const std = @import("std");
const vx = @import("vaxis");
const Key = vx.Key;

const dmp = @import("diffmatchpatch");

pub const App = @import("../../../App.zig");
pub const Buffer = @import("Buffer.zig");
pub const Vim = @import("Vim.zig");
pub const Theme = @import("../../layout/theme.zig");
pub const utils = @import("../../../utils.zig");

alloc: std.mem.Allocator,

app: *App,

/// List of available text buffers
buffers: std.ArrayList(*Buffer),

/// Current buffer
buffer: usize,

win: ?vx.Window = null,

is_focucsed: bool = false,

scroll_view: ?*vx.widgets.ScrollView = null,

/// The textarea's width
width: u16 = 0,

/// The textarea's height
height: u16 = 0,

/// Holds the instance for all the vim functionality
vim: *Vim,

use_virtual_cursor: bool = false,

selection: ?Selection = null,

pub const Event = union(enum) {
    key_press: Key,
};

pub const Selection = struct {
    start_pos: Buffer.CursorPos,

    cur_pos: Buffer.CursorPos,

    mode: Vim.Mode = .normal,

    pub fn init(mode: Vim.Mode, start_pos: Buffer.CursorPos) Selection {
        return .{
            .start_pos = start_pos,
            .cur_pos = .{ .row = 0, .row_offset = 0, .col = 0 },
            .mode = mode,
        };
    }

    pub fn getStart(self: Selection) Buffer.CursorPos {
        if (isBefore(self.start_pos, self.cur_pos)) {
            return self.start_pos;
        }
        return self.cur_pos;
    }

    pub fn getEnd(self: Selection) Buffer.CursorPos {
        if (isBefore(self.start_pos, self.cur_pos)) {
            return self.cur_pos;
        }
        return self.start_pos;
    }

    pub fn isInRange(self: Selection, row_index: u16, column: u16) bool {
        const sel_start = self.getStart();
        const sel_end = self.getEnd();

        var selected = false;

        if (self.mode == .visual) {
            // single row selection
            if (sel_start.row == sel_end.row) {
                if (row_index == sel_start.row and
                    column >= sel_start.col and column <= sel_end.col)
                {
                    selected = true;
                }
            } else {
                // Multi row selection
                // rows inbetween, select all
                if (row_index > sel_start.row and
                    row_index < sel_end.row)
                {
                    selected = true;
                }
                // upper selection row, start col to end of row
                else if (row_index == sel_start.row and
                    column >= sel_start.col)
                {
                    selected = true;
                }
                // last selection row, col 0 to end of row
                else if (row_index == sel_end.row and
                    column <= sel_end.col)
                {
                    selected = true;
                }
            }
        } else if (self.mode == .visual_line) {
            if (row_index >= sel_start.row and row_index <= sel_end.row) {
                selected = true;
            }
        }

        return selected;
    }
};

pub fn init(alloc: std.mem.Allocator, app: *App) !TextArea {
    const self: TextArea = .{
        .alloc = alloc,
        .app = app,
        .buffers = .empty,
        .buffer = 0,
        .vim = try .init(alloc),
        .use_virtual_cursor = app.config.@"virtual-cursor",
    };

    return self;
}

pub fn update(self: *TextArea, event: Event) !void {
    if (!self.is_focucsed) {
        return;
    }

    if (self.vim.enabled) {
        try self.vim.update(event, self);
    } else {
        switch (event) {
            .key_press => |key| {
                if (key.matches(Key.enter, .{})) {
                    self.addNewLine();
                } else if (key.matches(Key.left, .{})) {
                    self.characterLeft();
                } else if (key.matches(Key.right, .{})) {
                    self.characterRight();
                } else if (key.matches(Key.up, .{})) {
                    self.cursorUp();
                } else if (key.matches(Key.down, .{})) {
                    self.cursorDown();
                }

                if (key.text) |text| {
                    try self.insertSliceAtCursor(text);
                }
            },
        }
    }
}

pub fn draw(self: *TextArea) !void {
    var style: vx.Cell.Style = .{};

    if (self.win == null or
        self.scroll_view == null or
        !self.hasBuffers())
    {
        return;
    }

    const win: vx.Window = self.win.?;
    const view: *vx.widgets.ScrollView = self.scroll_view.?;

    if (self.width != win.width or self.height != win.height) {
        self.width = win.width;
        self.height = win.height;
    }

    const buf: *Buffer = self.curBuf();
    if (self.app.curevent == .key_press) {
        buf.updateCursorPos();
    }
    var i: usize = 0;

    const start = view.scroll.y;
    const end = @min(start + win.height, buf.rows.items.len);

    for (buf.rows.items[start..end]) |row| {
        const row_index: u16 = @intCast(start + i);
        var col: u16 = 0;

        for (row.getValue()) |char| {
            if (self.use_virtual_cursor and col == buf.col and
                (buf.row == row_index or self.getTermRow() == row_index))
            {
                style.bg = .{ .rgb = self.vim.mode.bgColor() };
                style.fg = .{ .rgb = self.vim.mode.fgColor() };
            }

            if (self.selection) |*selection| {
                selection.mode = self.app.mode;
                selection.cur_pos = buf.cursor_pos;
                if (selection.isInRange(row_index, col)) {
                    style.bg = Theme.Color.Selection.bg;
                }
            }

            view.writeCell(win, col, row_index, .{
                .char = .{ .grapheme = char.grapheme, .width = char.width },
                .style = style,
            });

            style = .{};
            col += 1;
        }

        // select an invisible, temporary character on empty rows
        if (row.len() == 0 and self.selection != null) {
            if (self.selection.?.isInRange(row_index, col)) {
                view.writeCell(win, col, row_index, .{
                    .char = .{ .grapheme = " ", .width = 1 },
                    .style = .{ .bg = Theme.Color.Selection.bg },
                });
            }
        }

        // Do cursor stuff only on current row
        if ((buf.row == row_index or self.getTermRow() == row_index) and
            self.app.curevent == .key_press)
        {
            if (self.use_virtual_cursor or !self.is_focucsed) {
                win.hideCursor();
            } else {
                win.showCursor(@intCast(buf.col), @intCast(self.getTermRow()));
            }
        }

        i += 1;
    }

    if (self.app.curevent == .key_press) {
        var tmp: [64]u8 = undefined;
        const ln_info = try self.getLnInfo(&tmp);
        try self.app.status_bar.setColumnContent(.file_info, ln_info);
    }
}

pub fn getLnInfo(self: *TextArea, buf: []u8) ![]const u8 {
    const ta_buf = self.app.editor.textarea.curBuf();
    return try std.fmt.bufPrint(
        buf,
        "Ln {}, Col {}",
        .{ ta_buf.row + 1, ta_buf.col + 1 },
    );
}

fn isBefore(a: Buffer.CursorPos, b: Buffer.CursorPos) bool {
    return a.row < b.row or (a.row == b.row and a.col < b.col);
}

pub fn newBuf(self: *TextArea, path: []const u8) !void {
    try self.buffers.append(self.alloc, try .init(self.alloc));
    var buf: *Buffer = self.buffers.getLast();
    // use the arena from the buffer since the history is tied to it.
    buf.history = try .init(buf.alloc);
    buf.setPath(path);
    buf.setIndex(self.numBufs() - 1);

    try buf.setContentFromFile(path);
    try buf.updatePrevVal();

    self.buffer = self.numBufs() + 1;
    self.goToTop();
}

pub fn newScratchBuf(self: *TextArea, content: ?[]const u8) !void {
    try self.buffers.append(self.alloc, try .init(self.alloc));
    const buf: *Buffer = self.buffers.getLast();
    const value = if (content != null) content.? else "";
    try buf.curRow().insertSliceAtCursor(value);

    self.buffer = self.numBufs() + 1;
}

/// Opens a buffer with the given `path`.
/// If no buffer is found it attempts to create a new buffer with `path`.
pub fn openBuf(self: *TextArea, path: []const u8) !void {
    if (self.findBuf(path)) |buffer| {
        self.buffer = buffer.index;
    } else {
        try self.newBuf(path);
    }
}

/// Saves the current buffer content to file.
pub fn writeBuf(self: *TextArea) !usize {
    const buf: *Buffer = self.curBuf();
    const file = std.fs.createFileAbsolute(
        self.curBuf().path,
        .{ .truncate = true },
    ) catch |e| {
        std.log.debug("{}", .{e});
        return 0;
    };
    defer file.close();

    const content = try buf.getString(self.alloc, null);
    defer self.alloc.free(content);
    const write_buf: []u8 = try self.alloc.alloc(u8, content.len);
    defer self.alloc.free(write_buf);

    var writer = file.writer(write_buf);
    const bytes = try writer.interface.write(content);
    try writer.interface.flush();

    return bytes;
}

/// Attempts to find a buffer with the given `path`.
/// If none could be found it returns `null`.
pub fn findBuf(self: TextArea, path: []const u8) ?*Buffer {
    for (self.buffers.items) |buffer| {
        if (std.mem.eql(u8, buffer.path, path)) {
            return buffer;
        }
    }
    return null;
}

pub fn numBufs(self: TextArea) usize {
    return self.buffers.items.len;
}

pub fn hasBuffers(self: TextArea) bool {
    return self.numBufs() > 0;
}

/// Returns the current buffer.
pub fn curBuf(self: TextArea) *Buffer {
    var buf_index = self.buffer;
    if (buf_index > self.numBufs()) {
        buf_index = self.numBufs() - 1;
    }
    return self.buffers.items[buf_index];
}

/// Enables vim motions.
pub fn enableVimMode(self: *TextArea) !void {
    self.vim.enable();
}

/// Insert text at the cursor position
pub fn insertSliceAtCursor(self: *TextArea, data: []const u8) !void {
    const buf: *Buffer = self.curBuf();
    var cur_row = buf.curRow();
    cur_row.col = buf.col;

    var iter = vx.unicode.graphemeIterator(data);

    // line wrap
    if (cur_row.len() > self.width) {
        try buf.addRowAt(@intCast(buf.row + 1), cur_row.offset + 1);
        self.beginLine(false);
        self.cursorDown();
    }

    while (iter.next()) |text| {
        try buf.curRow().insertSliceAtCursor(text.bytes(data));
        self.characterRight();
    }
}

/// Remove the character at `index`.
/// If vim is enabled the cursor will be moved one character to the left.
/// Returns true on a succesful deletion.
pub fn deleteCharAt(self: *TextArea, index: i32) bool {
    const buf: *Buffer = self.curBuf();
    var cur_row: *Buffer.Row = buf.curRow();

    // Skip if we're at the start of an empty line or
    // index is out of bound
    if (cur_row.len() <= 0 or index > cur_row.len()) {
        return false;
    }

    _ = cur_row.deleteCharAt(@intCast(index));
    cur_row.shrinkAndFree();
    buf.col = index;

    return true;
}

/// Removes the character at the cursor position.
pub fn deleteCurChar(self: *TextArea) void {
    const buf: *Buffer = self.curBuf();
    const row_len: i16 = @intCast(buf.curRow().len());

    if (!self.deleteCharAt(@intCast(buf.col))) {
        return;
    }

    if (buf.col == row_len - 1) {
        self.characterLeft();
    }
}

/// Removes all remaining characters of the current row
/// starting from the cursor's position.
pub fn deleteAfterCursor(self: *TextArea) !void {
    const buf: *Buffer = self.curBuf();
    var cur_row: *Buffer.Row = buf.curRow();
    const col: u32 = @intCast(buf.col);

    // Remove the value after the cursor from the current line.
    for (col..cur_row.len()) |_| {
        _ = cur_row.deleteCharAt(col);
    }
}

/// Deletes the selected text.
/// Does not return to normal mode.
pub fn deleteSelection(self: *TextArea) !void {
    const buf: *Buffer = self.curBuf();
    const sel = self.selection orelse return;

    // little array to store which lines should be deleted completely
    var del_lines: std.ArrayList(usize) = .empty;
    defer del_lines.deinit(self.alloc);
    var join = false;

    var row_index: usize = 0;
    for (buf.rows.items) |row| {
        var col: u16 = 0;

        // store every empty line since `row.getValue()` doesn't store empty rows
        // but we need to delete empty lines within the selection as well.
        if (row.len() == 0 and !utils.listContains(usize, del_lines, row_index)) {
            try del_lines.append(self.alloc, row_index);
        }

        for (row.getValue()) |_| {
            defer col += 1;
            if (!sel.isInRange(@intCast(row_index), col)) {
                continue;
            }

            // The column where the deletion should start
            var c: usize = @intCast(sel.getStart().col);

            // Any row that should be delete completely
            if ((row_index > sel.getStart().row and
                row_index < sel.getEnd().row))
            {
                // Store which rows should be deleted, we only clear the
                // row's content here and delete the row later.
                if (!utils.listContains(usize, del_lines, row_index)) {
                    try del_lines.append(self.alloc, row_index);
                }
                join = true;
                c = 0;
            }

            // Set the column of the last row to the first column of the row
            // so that we delete the row's content up to the end of the
            // selection.
            if (row_index == sel.getEnd().row and col <= sel.getEnd().col and
                sel.getStart().row != sel.getEnd().row)
            {
                join = true;
                c = 0;
            }

            if (c >= row.len()) continue;
            _ = row.value.orderedRemove(c);
        }

        row_index += 1;
    }

    // Delete the previously stored rows and delete them.
    for (0..del_lines.items.len) |i| {
        const fln = del_lines.items[0];
        // Check again if the stored lines are in range, we previously
        // stored every empty row because `row.getValue()` doesn't store them.
        // Without this check we'd delete all empty rows. Nobody wants that.
        if (sel.isInRange(@intCast(del_lines.items[i]), 0)) {
            self.deleteLineAt(@intCast(fln));
        }
    }

    // Move the cursor to the start of the selection
    self.moveCursorTo(sel.getStart().row, sel.getStart().col);

    // Finaly, join the remaining lines of the selection
    if (join) {
        self.joinLine();
    }
}

/// Add a new line.
/// If the cursor is not at the end of a line, the line gets automatically
/// split, moving the text after (including) the cursor onto the new line.
pub fn addNewLine(self: *TextArea) void {
    const buf: *Buffer = self.curBuf();
    const new_row: i32 = buf.row + 1;

    if (new_row > buf.rows.items.len or
        buf.col > buf.curRow().len())
    {
        buf.addRow(0) catch return;
    } else {
        buf.splitRow() catch return;
    }

    self.repositionView();
}

/// Add an empty line below the current one.
pub fn addLineBelow(self: *TextArea) !void {
    const buf: *Buffer = self.curBuf();
    const new_row: u32 = @intCast(buf.row + 1);
    if (new_row <= buf.rows.items.len) {
        try buf.addRowAt(new_row, 0);
        self.cursorDown();
    }
}

/// Add an empty line above the current one.
pub fn addLineAbove(self: *TextArea) !void {
    const buf: *Buffer = self.curBuf();
    try buf.addRowAt(@intCast(buf.row), 0);
    buf.col = 0;
}

/// Deletes the next line and moves its content to the current line.
pub fn joinLine(self: *TextArea) void {
    const buf: *Buffer = self.curBuf();
    const next_index: i32 = buf.row + 1;

    if (next_index >= buf.rows.items.len) {
        return;
    }

    var next_row: *Buffer.Row = buf.rows.items[@intCast(next_index)];
    const next_row_val = next_row.getValue();
    const line_len: u16 = @intCast(buf.curRow().len());

    if (next_row_val.len == 0) {
        self.deleteLineAt(next_index);
        buf.shrinkAndFree();
        return;
    }

    // Prepend whitespace when line to join doesn't start with one
    // and is not empty
    if (!std.mem.eql(u8, next_row_val[0].grapheme, " ") and
        line_len > 0)
    {
        buf.curRow().appendChar(.{}) catch return;
    }

    for (next_row_val) |val| {
        buf.curRow().appendChar(val) catch return;
    }

    self.moveCursorTo(buf.row, line_len);
    self.deleteLineAt(next_index);
    buf.shrinkAndFree();
}

/// Move the cursor to the start of the line.
/// If `non_white` is true, the cursor moves to the first non-white
/// character of the line.
pub fn beginLine(self: *TextArea, non_white: bool) void {
    const buf: *Buffer = self.curBuf();
    buf.col = 0;
    buf.last_col = 0;

    if (non_white) {
        var i: u16 = 0;
        for (buf.curRow().getValue()) |char| {
            defer i += 1;

            if (!std.mem.eql(u8, char.grapheme, " ")) {
                buf.col = i;
                return;
            }
        }
    }
}

/// Moves the cursor to the end of the current line.
pub fn lineEnd(self: *TextArea) void {
    const buf: *Buffer = self.curBuf();
    const row_len: u16 = @intCast(buf.curRow().len());
    buf.col = if (self.vim.enabled and row_len > 0)
        row_len - 1
    else
        row_len;

    buf.last_col = 0;
}

/// Deletes the live at the given `index` and frees its data.
pub fn deleteLineAt(self: *TextArea, index: i32) void {
    const buf: *Buffer = self.curBuf();

    if (buf.rows.items.len == 0) {
        return;
    }

    // delete at first and only line, just empty that line.
    if (buf.row == 0 and buf.numRows() == 1) {
        buf.curRow().shrinkAndFree();
        self.beginLine(false);
    } else {
        // remove row and free memory of removed row
        const row: *Buffer.Row = buf.rows.orderedRemove(@intCast(index));
        row.deinit();
        //self.alloc.destroy(row);
    }

    // if we're deleting the last row, move to the last available line.
    if (buf.row >= buf.numRows()) {
        buf.row = @intCast(buf.rows.items.len - 1);
    }

    // if the current row is empty move cursor to the start of the line.
    if (buf.curRow().len() == 0) {
        self.beginLine(false);
    }

    if (buf.col > buf.curRow().len()) {
        self.lineEnd();
    }
}

/// Deletes the current line.
/// If `keep_cur_pos` is false the cursor is moved to the
/// beginning of the line.
pub fn deleteCurLine(self: *TextArea, keep_cur_pos: bool) void {
    const buf: *Buffer = self.curBuf();
    self.deleteLineAt(buf.row);

    if (!keep_cur_pos) {
        self.beginLine(false);
    }
}

/// Deletes `n` lines starting from the current row.
pub fn deleteNLines(self: *TextArea, n: usize) void {
    for (0..n) |_| {
        self.deleteCurLine(true);
    }
}

/// Repositions the view to the cursor position, ensuring it's always
/// in the viewport.
pub fn repositionView(self: *TextArea) void {
    const buf: *Buffer = self.curBuf();

    if (self.scroll_view) |view| {
        const min = view.scroll.y;
        const max = min + self.height - 1;
        const row: u32 = @intCast(buf.row);

        if (buf.row < min) {
            view.scroll.y -= min - row;
        } else if (buf.row > max) {
            view.scroll.y += row - max;
        }
    }
}

/// Moves the cursor one line up.
pub fn cursorUp(self: *TextArea) void {
    const buf: *Buffer = self.curBuf();

    if (buf.row > 0) {
        buf.row -= 1;
    }

    if (buf.row - 1 > 0) {
        const prev_row = buf.rows.items[@intCast(buf.row - 1)];
        // save last column position
        if ((prev_row.len() == 0 and
            buf.col > 0 and
            buf.col > buf.last_col and
            buf.last_col >= prev_row.len()) or
            buf.last_col == 0)
        {
            buf.last_col = buf.col;
        }
    }

    self.setCursorRow(@intCast(buf.row));

    if (buf.last_col > 0) {
        self.setCursorCol(buf.last_col);
    }

    self.repositionView();
}

/// Moves the cursor one line down.
pub fn cursorDown(self: *TextArea) void {
    const buf: *Buffer = self.curBuf();

    if (buf.row + 1 < buf.numRows()) {
        buf.row += 1;
    }

    if (buf.row + 1 < buf.numRows()) {
        const next_row = buf.rows.items[@intCast(buf.row + 1)];
        // save last column position
        if ((next_row.len() == 0 and
            buf.col > 0 and
            buf.col > buf.last_col and
            buf.last_col >= next_row.len()) or buf.last_col == 0)
        {
            buf.last_col = buf.col;
        }
    }

    self.setCursorRow(@intCast(buf.row));

    if (buf.last_col > 0) {
        self.setCursorCol(buf.last_col);
    }

    self.repositionView();
}

/// Moves the cursor one character to the left.
pub fn characterLeft(self: *TextArea) void {
    const buf: *Buffer = self.curBuf();

    if (buf.col <= 0) {
        return;
    }

    const char = buf.curRow().getValue()[@intCast(buf.col - 1)];
    self.setCursorCol(buf.col - char.width);
    buf.last_col = 0;
}

/// Moves the cursor one character to the right.
pub fn characterRight(self: *TextArea) void {
    const buf: *Buffer = self.curBuf();
    const row_val = buf.curRow().getValue();

    var row_len = row_val.len;
    // In vim mode we don't allow the cursor to move past the last character
    // unless we're in insert mode so the length of the row should always
    // be one character less.
    if (self.vim.enabled and self.vim.mode == .normal and row_len > 0) {
        row_len -= 1;
    }

    if (buf.col >= row_len) {
        return;
    }

    const char = row_val[@intCast(buf.col)];
    self.setCursorCol(buf.col + char.width);
    buf.last_col = 0;
}

/// WordRight moves the cursor to the start of the next word.
/// If the cursor is at the end of the row it moves one row down.
/// Skips any non-letter characters that follow. (<-- this is actually yet
/// to be implemted)
pub fn wordRight(self: *TextArea) void {
    const buf: *Buffer = self.curBuf();
    const row: *Buffer.Row = buf.curRow();

    if (self.tryNextLine()) {
        return;
    }

    for (@intCast(buf.col)..row.getValue().len) |i| {
        if (self.tryNextLine()) {
            return;
        }

        const char = row.getValue()[i];

        self.characterRight();

        if (charIsSpace(char.grapheme)) {
            return;
        }
    }
}

/// WordRightEnd moves the cursor to the end of the next word.
/// If the cursor is at the end of the row it moves one row down.
/// Skips any non-letter characters that follow.
pub fn wordRightEnd(self: *TextArea) void {
    const buf: *Buffer = self.curBuf();
    const row: *Buffer.Row = buf.curRow();
    const row_val = row.getValue();

    if (self.tryNextLine()) {
        return;
    }

    for (@intCast(buf.col + 1)..row.len()) |_| {
        self.characterRight();

        var char = row_val[@intCast(buf.col)];
        while (buf.col < row.len()) {
            char = row_val[@intCast(buf.col)];
            if (!charIsSpace(char.grapheme)) {
                break;
            }
            self.characterRight();
        }

        if (buf.col + 1 >= row.len()) {
            break;
        }

        const next_char = row_val[@intCast(buf.col + 1)];
        if (charIsSpace(next_char.grapheme)) {
            return;
        }
    }
}

/// Moves the cursor to the beginning of the previous word.
/// If the cursor is at the start of the row it moves one row up.
pub fn wordLeft(self: *TextArea) void {
    const buf: *Buffer = self.curBuf();
    const row: *Buffer.Row = buf.curRow();

    // Move to the row above if we reached the start of the line.
    if (buf.col <= 0 and buf.row > 0) {
        self.cursorUp();
        self.lineEnd();
        self.wordLeft();
        return;
    }

    var i: usize = @intCast(buf.col - 1);
    while (i > 0) {
        i -= 1;
        const char = row.getValue()[i];

        self.characterLeft();
        if (charIsSpace(char.grapheme)) {
            return;
        }
    }

    if (i == 0) {
        self.beginLine(false);
    }
}

/// Moves the cursor to the end of the previous word.
/// If the cursor is at the start of the row it moves one row up.
pub fn wordLeftEnd(self: *TextArea) void {
    const buf: *Buffer = self.curBuf();
    const row: *Buffer.Row = buf.curRow();

    self.wordRight();

    for (0..@intCast(buf.col)) |i| {
        const char = row.getValue()[i];
        if (charIsSpace(char.grapheme)) {
            self.characterRight();
            return;
        }
        self.characterLeft();
    }
}

/// Helper to determine if the cursor is at the end of a line and moves
/// to the beginning of the next line if true.
fn tryNextLine(self: *TextArea) bool {
    const buf: *Buffer = self.curBuf();
    const row_len: isize = @intCast(buf.curRow().len());
    const num_rows: i32 = @intCast(buf.numRows());

    if (buf.col >= row_len - 1 and buf.row < num_rows - 1) {
        self.cursorDown();
        self.beginLine(true);
        return true;
    }
    return false;
}

/// Moves the view up half the viewport size centering the cursor.
/// If the buffer's content is larger than the viewport.
pub fn halfPageUp(self: *TextArea) void {
    const buf: *Buffer = self.curBuf();
    const half_height: i16 = @intCast(self.height / 2);
    const row: i32 = @intCast(buf.row);
    const new_row = std.math.clamp(row - half_height, 0, buf.numRows() - 1);

    if (self.scroll_view) |view| {
        const min: i32 = @intCast(view.scroll.y);

        if (new_row <= min) {
            if (min > half_height) {
                view.scroll.y -= @intCast(half_height);
            } else {
                self.goToTop();
            }
        }

        if (min == 0) {
            self.goToTop();
        } else {
            self.moveCursorTo(@intCast(new_row), buf.col);
        }
    }
}

/// Moves the view down half the viewport size centering the cursor.
/// If the buffer's content is larger than the viewport.
pub fn halfPageDown(self: *TextArea) void {
    const buf: *Buffer = self.curBuf();
    const half_height: u16 = self.height / 2;
    const new_row = std.math.clamp(buf.row + half_height, 0, buf.numRows() - 1);

    if (self.scroll_view) |view| {
        const min = view.scroll.y;
        const max = min + self.height - 1;

        if (new_row >= max) {
            view.scroll.y += half_height;
        }

        if (max == buf.numRows() - 1) {
            self.goToBottom();
        } else {
            self.moveCursorTo(@intCast(new_row), buf.col);
        }
    }
}

/// Moves the cursor to the top of the text and repositions the view.
pub fn goToTop(self: *TextArea) void {
    self.moveCursorTo(0, self.curBuf().col);
    self.repositionView();
}

/// Moves the cursor to the bottom of the text and repositions the view.
pub fn goToBottom(self: *TextArea) void {
    const buf: *Buffer = self.curBuf();
    const num_rows: i32 = @intCast(buf.numRows());
    var last_row: i32 = self.height;

    if (num_rows < self.height) {
        last_row = num_rows;
    }

    self.moveCursorTo(num_rows, buf.col);
    self.repositionView();
}

/// Don't use...still buggy.
pub fn centreView(self: *TextArea) void {
    const buf: *Buffer = self.curBuf();
    const half_height: u16 = self.height / 2;

    if (self.scroll_view == null or buf.cursor_row == half_height) {
        return;
    }

    const view: *vx.widgets.ScrollView = self.scroll_view.?;
    const diff: i32 = self.height - buf.cursor_row - half_height;

    if (buf.cursor_row >= half_height) {
        const d: usize = @intCast(@abs(diff));
        view.scroll.y += d;

        self.setCursorRow(@intCast(buf.row - d));
    } else {
        const cur_y: i32 = @intCast(view.scroll.y);
        const d: usize = @intCast(diff);

        if (cur_y - diff > 0) {
            view.scroll.y -= d;
        }

        self.setCursorRow(@intCast(buf.row + d));
    }

    buf.cursor_row = half_height;
}

/// Moves the cursor to the given `row` and `col`.
pub fn moveCursorTo(self: *TextArea, row: i32, col: i32) void {
    self.setCursorRow(row);
    self.setCursorCol(col);
}

/// Moves the cursor to the given column.
/// If `reset_last_col` is true it resets the last cursor position
/// `Buffer.last_col`.
pub fn setCursorCol(self: *TextArea, col: i32) void {
    const buf: *Buffer = self.curBuf();
    var row_len: i32 = @intCast(buf.curRow().len());

    if (row_len > 0 and self.vim.mode != .insert) {
        row_len -= 1;
    }
    buf.col = std.math.clamp(col, 0, row_len);
}

/// Moves the cursor to the given row.
pub fn setCursorRow(self: *TextArea, row: i32) void {
    const buf: *Buffer = self.curBuf();
    const num_rows = buf.numRows();
    const clamped = std.math.clamp(row, 0, num_rows);

    // ensure the cursor does not go further as it should
    var max_cur_row = buf.numRows() - 1;
    if (buf.numRows() > self.height and self.height > 0) {
        max_cur_row = self.height - 1;
    }

    buf.row = @intCast(std.math.clamp(clamped, 0, num_rows - 1));
}

pub fn selectRange(
    self: *TextArea,
    from: Buffer.CursorPos,
    to: Buffer.CursorPos,
) void {
    self.vim.setMode(.visual);
    self.selection = .init(.visual, from);
    self.selection.?.cur_pos = to;
    self.moveCursorTo(to.row, to.col);
}

/// Returns the index of the first character of the current word.
pub fn getFirstColumnOfWord(self: TextArea) i32 {
    const buf: *Buffer = self.curBuf();
    const row: *Buffer.Row = buf.curRow();

    var index: usize = 0;
    var col: usize = @intCast(buf.col);
    while (col > 0) {
        col -= 1;

        // break early if we're already at the start of the line
        if (col <= 0) {
            index = col;
            break;
        }

        const char = row.getValue()[col];
        if (TextArea.charIsSpace(char.grapheme)) {
            index = col + 1;
            break;
        }
    }

    return @intCast(index);
}

/// Returns the index of the last character of the current word.
pub fn getLastColumnOfWord(self: TextArea) i32 {
    const buf: *Buffer = self.curBuf();
    const row: *Buffer.Row = buf.curRow();

    // determine the index of the last character of the current word
    var index: usize = 0;
    for (@intCast(buf.col)..row.len()) |col| {
        const char = row.getValue()[col];

        // if current index is larger than the row set the index
        // to the index to the row length
        if (col >= row.len() - 1) {
            index = col;
            break;
        }

        if (TextArea.charIsSpace(char.grapheme)) {
            index = col - 1;
            break;
        }
    }

    return @intCast(index);
}

/// Copies the given string to the clipboard
pub fn yank(self: *TextArea, text: []const u8) void {
    self.vim.setMode(.normal);
    self.app.vx.copyToSystemClipboard(
        self.app.tty.writer(),
        text,
        self.alloc,
    ) catch |err| {
        std.log.err("Clipboard err: {}", .{err});
        return;
    };
}

/// Copies the current selection to the clipboard.
/// If `keep_cur_pos` is true the cursor position remains the same
/// otherwise the cursor is moved to the beginning of the selection
pub fn yankSelection(self: *TextArea, keep_cur_pos: bool) !void {
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    const buf: *Buffer = self.buffers.getLast();
    const sel: Selection = self.selection orelse return;

    var selected_text: std.ArrayList([]const u8) = .empty;
    defer selected_text.deinit(alloc);

    var i: usize = 0;
    for (buf.rows.items) |row| {
        var col: u16 = 0;

        for (row.getValue()) |*char| {
            defer col += 1;
            if (!sel.isInRange(@intCast(i), col)) {
                continue;
            }

            try selected_text.append(alloc, char.grapheme);

            if (col == row.len() - 1) {
                try selected_text.append(alloc, "\n");
            }
        }
        i += 1;
    }

    const text = try std.mem.join(alloc, "", selected_text.items);
    self.yank(text);

    if (!keep_cur_pos) {
        self.moveCursorTo(sel.getStart().row, sel.getStart().col);
        self.selection = null;
    }
}

//func (self *Editor) YankAfterCursor() message.StatusBarMsg {
//  self.saveCursorPos()
//  self.Textarea.StartSelection(textarea.SelectVisual)
//  self.GoToLineEnd()
//
//  return self.YankSelection(true)
//}
//
//// YankLine copies the current line to the clipboard
//func (self *Editor) YankLine() message.StatusBarMsg {
//  self.saveCursorPos()
//  self.EnterVisualMode(textarea.SelectVisualLine)
//  return self.YankSelection(true)
//}
//
//// YankWord copies the current word to the clipboard.
//// If outer is set to true it copies the space after the word.
//func (self *Editor) YankWord(outer bool) message.StatusBarMsg {
//  self.EnterVisualMode(textarea.SelectVisual)
//
//  if outer {
//      self.Textarea.SelectOuterWord()
//  } else {
//      self.Textarea.SelectInnerWord()
//  }
//
//  return self.YankSelection(false)
//}

/// Creates a new history entry for the current Buffer
/// saving the correct undo cursor position and current textarea content.
pub fn newHistoryEntry(self: *TextArea) void {
    const buf: *Buffer = self.curBuf();
    buf.history.newTmpEntry(buf.cursorPos());
    buf.updatePrevVal() catch return;
}

/// Updates the history entry saving the undo/redo
/// patch, the current cursor position and the hash of the buffer content
pub fn updateHistoryEntry(self: *TextArea) !void {
    const buf: *Buffer = self.curBuf();
    const cur_buf_val = try buf.getString(self.alloc, buf.rows.items);
    defer self.alloc.free(cur_buf_val);

    var redo_patch = try buf.history.makePatch(buf.prev_value, cur_buf_val);
    defer redo_patch.deinit();

    var undo_patch = try buf.history.makePatch(cur_buf_val, buf.prev_value);
    defer undo_patch.deinit();

    const hash = try buf.getHash();

    try buf.history.updateEntry(
        redo_patch,
        undo_patch,
        buf.cursor_pos,
        hash,
    );

    try buf.updatePrevVal();
}

/// Sets the buffer content to the previous history entry.
pub fn undo(self: *TextArea) void {
    const buf: *Buffer = self.curBuf();
    var patch = buf.history.undo() catch return;
    defer patch.patch.deinit();

    const cur_val = buf.getString(self.alloc, null) catch return;
    defer self.alloc.free(cur_val);

    const patched = buf.history.dmp.patchApply(patch.patch, cur_val) catch return;

    buf.setContentFromStr(patched.@"0") catch return;
    self.moveCursorTo(patch.cursor_pos.row, patch.cursor_pos.col);
    self.repositionView();
}

// Sets the buffer content to the next history entry.
pub fn redo(self: *TextArea) void {
    const buf: *Buffer = self.curBuf();

    var patch = buf.history.redo() catch return;
    defer patch.patch.deinit();

    const prev = buf.getString(self.alloc, null) catch return;
    defer self.alloc.free(prev);

    const patched = buf.history.dmp.patchApply(patch.patch, prev) catch return;

    buf.setContentFromStr(patched.@"0") catch return;
    self.moveCursorTo(patch.cursor_pos.row, patch.cursor_pos.col);
    self.repositionView();
}

/// Get the terminal row for the current cursor position.
pub fn getTermRow(self: TextArea) usize {
    const buf: *Buffer = self.curBuf();
    var row: usize = 0;
    if (self.scroll_view) |view| {
        row = @intCast(buf.row);
        return @intCast(row - view.scroll.y);
    }
    return row;
}

pub fn deinit(self: *TextArea) void {
    for (self.buffers.items) |buffer| {
        buffer.deinit();
        self.alloc.destroy(buffer);
    }
    self.buffers.deinit(self.alloc);
    self.vim.deinit();
    self.alloc.destroy(self.vim);
}

pub fn charIsSpace(char: []const u8) bool {
    const utf8 = std.unicode.Utf8View.init(char) catch return false;
    var iter = utf8.iterator();

    while (iter.nextCodepoint()) |cp| {
        if (cp == 32) {
            return true;
        }
    }

    return false;
}
