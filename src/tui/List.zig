const List = @This();

const std = @import("std");
const vx = @import("vaxis");

const App = @import("../App.zig");
const Cell = @import("../tui/layout/Cell.zig");
const ScrollView = @import("../tui/layout/ScrollView.zig");
const fs = @import("../fs.zig");

alloc: std.mem.Allocator,

/// The name of the DirectoryTree.
/// We use this as the default column title.
name: []const u8 = "",

app: *App,

/// The layout cell/column
cell: *Cell,

/// default width of the list.
default_width: u16 = 30,

/// default heigh of the list.
default_height: u16 = 0,

/// default height of a single list item.
default_item_height: u16 = 1,

/// The list index of the selected tree item.
selected_index: isize = 0,

/// A flat list of all visible directories.
items: std.ArrayList(*anyopaque) = .empty,

scroll_view: *ScrollView,

win: ?vx.Window = null,

is_insert: bool = false,

/// Terminal position
pub const CursorPos = struct {
    prev_row: u16 = 0,
    row: u16 = 0,
    col: u16 = 0,
};

pub const Item = struct {
    /// The row's index is primarily used to determine the indentation
    /// of a directory.
    index: usize = 0,

    index_str: []const u8 = "",

    /// The parent index of the directory.
    /// Used to make expanding and collapsing a directory possible
    parent_index: usize = 0,

    /// The list item's name
    name: []const u8,

    /// The path of the list item
    path: []const u8,

    /// The total width including name, icon, toggle arrows etc.
    width: u32 = 0,

    /// An array list representation of the name.
    /// Used for editing/renaming the list item.
    input_val: std.ArrayList(Cell.Character) = .empty,

    children: std.ArrayList(*anyopaque) = .empty,

    /// Indicates the depth of a directory.
    /// Used to determine the indentation of the tree item.
    level: u16 = 0,

    /// Whether to use nerd fonts
    nerd_fonts: bool = true,

    /// Whether the item is pinned to the top of the list.
    is_pinned: bool = false,

    /// Whether the item is pinned to the top of the list.
    is_expanded: bool = false,

    /// Whether the list item is currently cut from the list.
    /// This is usually a temporary state for moving the list item to another
    /// directory.
    is_cut: bool = false,

    //is_selected: bool = false,

    is_temporary: bool = false,

    /// The cursor position of the current edit.
    edit_info: ?CursorPos = null,

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
        const edit_info = self.edit_info orelse return;
        const name_len = self.input_val.items.len;

        if (key.text) |text| {
            const index = edit_info.col - (self.width - name_len);
            try self.input_val.insert(alloc, index, .{
                .grapheme = text,
                .width = 1,
            });
            self.cursorRight(true);
        }
    }

    /// Moves the cursor one character to the left when the item is being edited
    pub fn cursorLeft(self: *Item) void {
        if (self.edit_info) |*pos| {
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
        if (self.edit_info) |*pos| {
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
        const edit_info = self.edit_info orelse return;
        const name_len = self.input_val.items.len;

        self.cursorLeft();
        if (edit_info.col <= self.width - name_len or name_len == 0) {
            return;
        }

        const index: usize = @intCast(name_len - (self.width - edit_info.col));
        _ = self.input_val.orderedRemove(index - 1);
        self.input_val.shrinkAndFree(alloc, self.input_val.items.len);
    }

    /// Marks the current item as editable by setting `edit_pos.row` to the
    /// current item index representing the terminal row and `edit_pos.col`
    /// to the length of the item representing the terminal column.
    /// Populates `input_val` from `name`.
    pub fn edit(
        self: *Item,
        alloc: std.mem.Allocator,
        win: ?vx.Window,
        bottom_row: usize,
    ) !void {
        self.input_val = try List.buildNameArray(alloc, self.getName(false), win);
        self.edit_info = .{
            .col = @intCast(self.width),
            .row = @intCast(self.getTermRow(bottom_row)),
        };
    }

    /// Cancels the edit.
    /// Sets `edit_pos` to null and frees `input_val`
    pub fn resetInput(self: *Item, alloc: std.mem.Allocator) void {
        self.input_val.deinit(alloc);
        self.input_val = .empty;
        self.edit_info = null;
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

    /// Get the terminal row for the current cursor position.
    pub fn getTermRow(self: Item, bottom_row: usize) usize {
        const row: usize = self.index;
        return @intCast(row - bottom_row);
    }

    pub fn deinit(self: *Item, alloc: std.mem.Allocator) void {
        alloc.free(self.index_str);
        alloc.free(self.name);
        alloc.destroy(self.cell);
        self.input_val.deinit(alloc);
    }
};

pub fn init(alloc: std.mem.Allocator, title: []const u8, app: *App) !*List {
    const self = try alloc.create(List);

    self.* = .{
        .alloc = alloc,
        .name = title,
        .cell = try .init(alloc),
        .scroll_view = try .init(alloc),
        .app = app,
    };

    self.cell.setWidth(self.default_width);
    self.cell.title = title;

    return self;
}

pub fn draw(self: *List, win: vx.Window) void {
    self.scroll_view.view.draw(win, .{
        .cols = self.getWidth(),
        .rows = self.len(),
    });
    self.win = win;

    // dim scrollbar if any overlay is open
    if (self.scroll_view.view.vertical_scrollbar) |*vbar| {
        vbar.fg.dim = self.app.isAnyOverlayOpen() and !self.isFocused();
    }
}

pub inline fn drawHeader(
    self: List,
    win: vx.Window,
    col: u16,
    row: u16,
    args: Cell.HeaderArgs,
) void {
    var a = args;
    a.is_focused = self.isFocused();
    Cell.drawHeader(win, self.getTitle(), col, row, a);
}

/// Returns the first visible row of the list.
pub inline fn getTopVisRow(self: List) usize {
    return self.scroll_view.view.scroll.y;
}

/// Returns the last visible row of the list.
pub inline fn getBottomVisRow(self: List) usize {
    const win = self.win orelse return 0;
    return @min(self.getTopVisRow() + win.height, self.len());
}

/// Sorts the items by pinned state moving pinned items to the top
pub fn sortItems(
    self: *List,
    items: *std.ArrayList(*anyopaque),
) !void {
    var cloned = try items.clone(self.alloc);
    defer cloned.deinit(self.alloc);

    items.clearAndFree(self.alloc);

    var pinned: std.ArrayList(*anyopaque) = .empty;
    defer pinned.deinit(self.alloc);

    for (cloned.items) |list_item| {
        const item: *Item = @ptrCast(@alignCast(list_item));
        if (item.is_pinned) {
            try pinned.append(self.alloc, item);
        }
    }

    std.mem.sort(*anyopaque, pinned.items, .{}, lessThan);

    var unpinned: std.ArrayList(*anyopaque) = .empty;
    defer unpinned.deinit(self.alloc);

    for (cloned.items) |list_item| {
        const item: *Item = @ptrCast(@alignCast(list_item));
        if (!item.is_pinned) {
            try unpinned.append(self.alloc, item);
        }
    }

    std.mem.sort(*anyopaque, unpinned.items, .{}, lessThan);

    for (pinned.items) |list_item| {
        const item: *Item = @ptrCast(@alignCast(list_item));
        try items.append(self.alloc, item);
    }

    for (unpinned.items) |list_item| {
        const item: *Item = @ptrCast(@alignCast(list_item));
        try items.append(self.alloc, item);
    }
}

fn lessThan(_: @TypeOf(.{}), a: *anyopaque, b: *anyopaque) bool {
    const item_a: *Item = @ptrCast(@alignCast(a));
    const item_b: *Item = @ptrCast(@alignCast(b));
    return std.mem.order(u8, item_a.name, item_b.name) == .lt;
}

pub inline fn getItemsSlice(self: List) []*anyopaque {
    return self.items.items;
}

pub inline fn getItem(self: List, index: usize) ?*anyopaque {
    if (index >= self.len()) {
        return null;
    }

    return self.items.items[index];
}

pub fn contains(self: List, path: []const u8) bool {
    for (self.items.items) |item| {
        const list_item: *Item = @ptrCast(@alignCast(item));
        if (std.mem.eql(u8, list_item.path, path)) {
            return true;
        }
    }
    return false;
}

/// Shows or hides the vertical scrollbar of the given `scroll_view` depending
/// on whether the list content is larger than the view's height.
pub fn toggleVbar(self: *List, view_height: usize, item_height: usize) void {
    // take border top and bottom into account
    const height = if (view_height > 2) view_height - 2 else view_height;

    if (height > item_height) {
        self.scroll_view.hideScrollBar();
    } else {
        self.scroll_view.showScrollBar();
    }
}

/// Selects the first list item.
pub inline fn goToTop(self: *List) void {
    if (self.is_insert) {
        return;
    }
    self.selected_index = 0;
}

/// Selects the last list item.
pub inline fn goToBottom(self: *List) void {
    if (self.is_insert) {
        return;
    }
    self.selected_index = @intCast(self.numItems());
}

/// Moves the selection one line down.
pub fn lineDown(self: *List) void {
    if (self.is_insert) {
        return;
    }
    self.selected_index += 1;
    self.clampIndex(null);
}

/// Moves the selection one line up.
pub fn lineUp(self: *List) void {
    if (self.is_insert) {
        return;
    }
    self.selected_index -= 1;
    self.clampIndex(null);
}

/// Moves the view up half the viewport size centering the cursor.
/// If the buffer's content is larger than the viewport.
pub fn halfPageUp(self: *List) void {
    const half_height = self.getHeight() / 2;
    const row = self.selected_index;
    const new_row = std.math.clamp(row - half_height, 0, self.numItems());

    const min = self.scroll_view.view.scroll.y;

    if (new_row <= min) {
        if (min > half_height) {
            self.scroll_view.view.scroll.y -= half_height;
        } else {
            self.goToTop();
        }
    }

    if (min == 0) {
        self.goToTop();
    } else {
        self.selected_index = new_row;
    }
}

/// Moves the view down half the viewport size centering the cursor.
/// If the buffer's content is larger than the viewport.
pub fn halfPageDown(self: *List) void {
    const half_height = self.getHeight() / 2;
    const new_index = std.math.clamp(
        self.selected_index + half_height,
        0,
        self.numItems(),
    );

    const min = self.scroll_view.view.scroll.y;
    const max = min + self.getHeight() - 1;

    if (new_index >= max) {
        self.scroll_view.view.scroll.y += half_height;
    }

    if (max == self.numItems()) {
        self.goToBottom();
    } else {
        self.selected_index = new_index;
    }
}

/// pins or unpins `item` and saves the state to the meta config.
/// If `sort` is true the pinned items will appear at the top of the list
/// and the selection will be moved to the new position so the item will be
/// kept being selection.
pub fn togglePin(self: *List, item: *Item, sort: bool) !void {
    item.is_pinned = !item.is_pinned;

    if (sort) {
        try self.sortItems(&self.items);
    }

    try self.app.config.meta_infos.addFileInfo(item);

    // move selection to the new position of the item.
    var index: isize = 0;
    for (self.items.items) |item_| {
        const list_item_: *List.Item = @ptrCast(@alignCast(item_));
        if (std.mem.eql(u8, list_item_.name, item.name)) {
            self.selected_index = index;
            break;
        }
        index += 1;
    }
}

/// Returns the length of the item array list
pub fn len(self: List) usize {
    return self.items.items.len;
}

/// Returns the number of visible items.
pub fn numItems(self: List) usize {
    return if (self.len() > 0)
        self.len() - 1
    else
        self.len();
}

pub fn clampIndex(self: *List, max: ?isize) void {
    const max_items = max orelse @as(isize, @intCast(self.numItems()));
    self.selected_index = std.math.clamp(self.selected_index, 0, max_items);
}

pub fn focus(self: *List) void {
    self.cell.focus();
}

pub fn blur(self: *List) void {
    self.cell.blur();
}

pub inline fn getTitle(self: List) []const u8 {
    return self.cell.title;
}

pub inline fn getWidth(self: List) u16 {
    return self.cell.width;
}

pub inline fn setWidth(self: *List, width: u16) void {
    self.cell.setWidth(width);
}

pub inline fn getHeight(self: List) u16 {
    return self.cell.height;
}

pub inline fn setHeight(self: *List, height: u16) void {
    self.cell.setHeight(height);
}

pub inline fn getOffsetY(self: List) i17 {
    return self.cell.offset_y;
}

pub inline fn setOffsetY(self: *List, off_y: i17) void {
    self.cell.setOffsetY(off_y);
}

pub inline fn getOffsetX(self: List) i17 {
    return self.cell.offset_x;
}

pub inline fn setOffsetX(self: *List, off_x: i17) void {
    self.cell.setOffsetX(off_x);
}

pub inline fn setFocus(self: *List, f: bool) void {
    self.cell.setFocus(f);
}

pub inline fn isFocused(self: List) bool {
    return self.cell.isFocused();
}

pub fn deinit(self: *List, alloc: std.mem.Allocator) void {
    self.items.deinit(alloc);
    alloc.destroy(self.scroll_view);
    alloc.destroy(self.cell);
}

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
