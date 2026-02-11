const List = @This();

const std = @import("std");
const vx = @import("vaxis");

const Cell = @import("../tui/layout/Cell.zig");
const fs = @import("../fs.zig");

/// Terminal position
pub const CursorPos = struct {
    row: u16 = 0,
    col: u16 = 0,
};

pub const Item = struct {
    /// The row's index is primarily used to determine the indentation
    /// of a directory.
    index: usize = 0,

    /// The list item's name
    name: []const u8,

    /// The path of the list item
    path: []const u8,

    /// An array list representation of the name.
    /// Used for editing/renaming the list item.
    input_val: std.ArrayList(Cell.Character) = .empty,

    /// The total width including name, icon, toggle arrows etc.
    width: u32 = 0,

    /// Whether to use nerd fonts
    nerd_fonts: bool = true,

    /// Whether the item is pinned to the top of the list.
    is_pinned: bool = false,

    /// Whether the list item is currently cut from the list.
    /// This is usually a temporary state for moving the list item to another
    /// directory.
    is_cut: bool = false,

    //is_selected: bool = false,

    is_temporary: bool = false,

    /// The cursor position of the current edit.
    edit_pos: ?CursorPos = null,

    list_pad_left: u16 = 1,

    cell: *Cell = undefined,

    pub fn getName(self: Item, with_ext: bool) []const u8 {
        if (with_ext) {
            return self.name;
        }
        return std.mem.trimEnd(u8, self.name, fs.Notes.ext);
    }

    pub fn reinit(
        self: *Item,
        alloc: std.mem.Allocator,
        path: []const u8,
        name: []const u8,
    ) void {
        alloc.free(self.path);
        alloc.free(self.name);
        self.path = path;
        self.name = name;
        self.is_temporary = false;
    }

    /// Handles key input when the item is being edited.
    /// This only effects writing all other key actions are defined
    /// via the keymap.
    pub inline fn input(self: *Item, key: vx.Key, alloc: std.mem.Allocator) !void {
        const edit_pos = self.edit_pos orelse return;
        const name_len = self.input_val.items.len;

        if (key.text) |text| {
            const index = edit_pos.col - (self.width - name_len);
            try self.input_val.insert(alloc, index, .{
                .grapheme = text,
                .width = 1,
            });
            self.cursorRight(true);
        }
    }

    /// Moves the cursor one character to the left when the item is being edited
    pub fn cursorLeft(self: *Item) void {
        if (self.edit_pos) |*pos| {
            const name_len = self.input_val.items.len;
            if (pos.col > self.width - name_len) {
                pos.col -= 1;
            }
        }
    }

    /// Moves the cursor one character to the right when the item is being edited
    /// If `oob` is set to true the cursor is allowed to be positioned out of bounds
    /// which we only ever want when we're inserting text, not while navigating.
    pub fn cursorRight(self: *Item, oob: bool) void {
        if (self.edit_pos) |*pos| {
            var can_move = pos.col < self.width;
            if (oob) {
                can_move = pos.col <= self.width;
            }
            if (can_move) {
                pos.col += 1;
            }
        }
    }

    /// Deletes the character before the cursor.
    pub fn deleteBefore(self: *Item, alloc: std.mem.Allocator) void {
        const pos = self.edit_pos orelse return;
        const name_len = self.input_val.items.len;

        self.cursorLeft();
        if (pos.col <= self.width - name_len or name_len == 0) {
            return;
        }

        const index: usize = @intCast(name_len - (self.width - pos.col));
        _ = self.input_val.orderedRemove(index - 1);
        self.input_val.shrinkAndFree(alloc, self.input_val.items.len);
    }

    /// Marks the current item as editable by setting `edit_pos.row` to the
    /// current item index representing the terminal row and `edit_pos.col`
    /// to the length of the item representing the terminal column.
    /// Populates `input_val` from `name`.
    pub fn edit(self: *Item, alloc: std.mem.Allocator, win: ?vx.Window) !void {
        self.input_val = try List.buildNameArray(alloc, self.getName(false), win);
        self.edit_pos = .{
            .col = @intCast(self.width),
            .row = @intCast(self.index),
        };
    }

    /// Cancels the edit.
    /// Sets `edit_pos` to null and frees `input_val`
    pub fn resetInput(self: *Item, alloc: std.mem.Allocator) void {
        self.input_val.deinit(alloc);
        self.input_val = .empty;
        self.edit_pos = null;
    }

    /// Returns the string representation of the `input_val`.
    /// Caller owns memory.
    pub fn getStrFromInput(self: *Item, alloc: std.mem.Allocator) ![]const u8 {
        var path_list: std.ArrayList([]const u8) = .empty;
        defer path_list.deinit(alloc);

        for (self.input_val.items) |char| {
            try path_list.append(alloc, char.grapheme);
        }

        const joined = try std.mem.join(alloc, "", path_list.items);
        return joined;
    }

    pub fn deinit(self: *Item, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.destroy(self.cell);
        self.input_val.deinit(alloc);
    }
};

/// Converts a string into an array list of Characters.
pub fn buildNameArray(
    alloc: std.mem.Allocator,
    name: []const u8,
    win: ?vx.Window,
) !std.ArrayList(Cell.Character) {
    var list: std.ArrayList(Cell.Character) = .empty;
    var g_iter = vx.unicode.graphemeIterator(name);

    while (g_iter.next()) |grapheme| {
        const g = grapheme.bytes(name);
        var width: u16 = 1;
        if (win) |w| {
            width = w.gwidth(g);
        }
        try list.append(alloc, .{ .grapheme = g, .width = @intCast(width) });
    }

    return list;
}
