const BufferList = @This();

const std = @import("std");
const vx = @import("vaxis");

const App = @import("../App.zig");
const Buffer = @import("../tui/widgets/TextArea/Buffer.zig");
const Cell = @import("layout/Cell.zig");
const List = @import("List.zig");
const ScrollView = @import("layout/ScrollView.zig");
const theme = @import("layout/theme.zig");
const Icon = theme.Icon;

alloc: std.mem.Allocator,

app: *App,

list: *List,

/// default heigh of the list.
default_height: u16 = 10,

default_x_off: u16 = 0,

default_y_off: u16 = 3,

pub const BufferListItem = struct {
    /// General list data
    data: List.Item,

    str_index: []const u8 = "",

    is_placeholder: bool = false,

    pub fn deinit(self: *BufferListItem, alloc: std.mem.Allocator) void {
        alloc.free(self.data.path);
        alloc.free(self.str_index);
        self.data.deinit(alloc);
    }
};

pub fn init(alloc: std.mem.Allocator, title: []const u8, app: *App) !*BufferList {
    const self = try alloc.create(BufferList);

    self.* = .{
        .alloc = alloc,
        .app = app,
        .list = try .init(alloc, title),
    };

    return self;
}

pub fn update(self: *BufferList, event: App.Event) !void {
    switch (event) {
        .key_press => |key| {
            _ = key;
        },
        .winsize => |ws| {
            self.default_x_off = ws.cols / 3;
            self.list.setWidth(self.default_x_off);
            self.list.setHeight(self.default_height);
            self.list.toggleVbar(self.default_height, self.list.numItems());
        },
        else => {},
    }
}

pub fn draw(self: *BufferList, win: vx.Window) !void {
    const opts = self.list.cell.getChild();
    const child_win = win.child(opts);

    self.list.draw(child_win);

    const top_vis_row = self.list.getTopVisRow();
    const bottom_vis_row = self.list.getBottomVisRow();

    var i: usize = 0;
    for (self.list.getItemsSlice()[top_vis_row..bottom_vis_row]) |item| {
        const buffer: *BufferListItem = @ptrCast(@alignCast(item));
        const term_row: usize = top_vis_row + i;
        buffer.data.cell.setHeight(self.list.default_item_height);
        var child_opts = buffer.data.cell.getChild();
        // reset border for each tree item
        child_opts.border = .{};

        _ = child_win.child(child_opts);

        var style: vx.Cell.Style = .{};
        if (term_row == self.list.selected_index) {
            style.bg = theme.Color.List.selection_bg;
        }

        try self.writeLine(buffer, @intCast(term_row), self.list.getWidth(), style);
        buffer.data.index = @intCast(term_row);
        i += 1;
    }

    self.list.scroll_view.height = child_win.height;
    self.list.scroll_view.setRow(@intCast(self.list.selected_index));
    self.list.scroll_view.reposition();
}

pub fn cmdToggle(self: *BufferList) void {
    if (self.list.isFocused()) {
        self.list.setFocus(false);
        self.app.focusColumn(self.app.last_column);
    } else {
        self.refresh() catch return;
        self.list.setFocus(true);
        self.app.last_column = self.app.current_column;
        self.app.focusColumn(.buffer_list);
    }
}

fn writeLine(
    self: BufferList,
    item: *BufferListItem,
    row: u16,
    width: u16,
    style: vx.Cell.Style,
) !void {
    var col: u16 = 0;
    var w: usize = 0;

    var view = self.list.scroll_view.view;

    if (self.list.win) |win| {
        Cell.writeStr(win, &view, &col, row, " ", style);

        if (!item.is_placeholder) {
            var icon_style: vx.Style = .{ .fg = theme.Color.List.note_fg };
            if (self.selectedRow()) |selected_item| {
                if (selected_item == item) {
                    icon_style.fg = theme.Color.default_fg;
                    icon_style.bg = theme.Color.List.selection_bg;
                }
            }
            var note_icon = Icon.getNerd(.note);
            if (self.selectedRow()) |selected_item| {
                if (self.list.is_insert and selected_item == item) {
                    note_icon = Icon.getNerd(.pen);
                }
            }

            Cell.writeStr(win, &view, &col, row, item.str_index, style);
            Cell.writeStr(win, &view, &col, row, " ", style);
            Cell.writeStr(win, &view, &col, row, note_icon, icon_style);
            Cell.writeStr(win, &view, &col, row, " ", style);
        }
        Cell.writeStr(win, &view, &col, row, item.data.getName(false), style);

        w = col;

        // pad the rest of the line to make the selection expand to the whole row
        while (col < width) {
            Cell.writeStr(win, &view, &col, row, " ", style);
        }
    }

    item.data.width = @intCast(w);
}

pub fn refresh(self: *BufferList) !void {
    self.freeListItems();
    var index: usize = 1;
    for (self.app.editor.textarea.buffers.items) |buffer| {
        var item = try self.makeListItem(buffer.getName(), buffer.path);
        item.str_index = try std.fmt.allocPrint(self.alloc, "{}", .{index});
        try self.list.items.append(self.alloc, item);
        index += 1;
    }

    // Fill remaining rows with empty items to prevent notes from showing.
    // Basically simulating a solid background
    if (self.list.numItems() < self.default_height) {
        // default height minus border
        const num_max = self.default_height - 3;
        for (self.list.numItems()..num_max) |_| {
            const item = try self.makeListItem("", "");
            item.is_placeholder = true;
            try self.list.items.append(self.alloc, item);
        }
    }
}

fn allocNoteItem(self: *BufferList, item: BufferListItem) !*BufferListItem {
    const note_item = try self.alloc.create(BufferListItem);

    const cell: *Cell = try .init(self.alloc);
    cell.setHeight(self.list.default_item_height);

    note_item.* = .{
        .data = .{
            .index = 0,
            .name = try self.alloc.dupe(u8, item.data.name),
            .path = try self.alloc.dupe(u8, item.data.path),
            .width = item.data.width,
            .cell = cell,
            .is_temporary = item.data.is_temporary,
        },
    };

    return note_item;
}

fn makeListItem(
    self: *BufferList,
    name: []const u8,
    path: []const u8,
) !*BufferListItem {
    const width = name.len + 3; // 3 = padding, icon, padding @todo, make it ugly

    const item = try self.allocNoteItem(.{
        .data = .{
            .name = name,
            .width = @intCast(width),
            .path = path,
        },
        .is_placeholder = false,
    });

    return item;
}

inline fn getItem(self: BufferList, index: usize) ?*BufferListItem {
    const item = self.list.getItem(index) orelse return null;
    const list_item: *BufferListItem = @ptrCast(@alignCast(item));
    return list_item;
}

pub fn selectedRow(self: BufferList) ?*BufferListItem {
    if (self.getItem(@intCast(self.list.selected_index))) |item| {
        const row: *BufferListItem = @ptrCast(@alignCast(item));
        return row;
    }
    return null;
}

pub fn cmdLineDown(self: *BufferList) void {
    self.list.lineDown();
    self.list.clampIndex(self.app.editor.textarea.numBufs() - 1);
}

pub fn cmdLineUp(self: *BufferList) void {
    self.list.lineUp();
}

pub fn selectedNote(self: BufferList) ?*BufferListItem {
    if (self.getItem(@intCast(self.list.selected_index))) |item| {
        const note: *BufferListItem = @ptrCast(@alignCast(item));
        return note;
    }
    return null;
}

pub fn cmdSelect(self: *BufferList) void {
    if (self.selectedNote()) |note| {
        self.app.editor.openBuf(note.data.path) catch return;
        self.app.notes_list.updateLastNote();
    }
    self.list.setFocus(false);
    self.app.focusColumn(self.app.last_column);
}

fn freeListItems(self: *BufferList) void {
    for (self.list.items.items) |item| {
        const list_item: *BufferListItem = @ptrCast(@alignCast(item));
        list_item.deinit(self.alloc);
        self.alloc.destroy(list_item);
    }
    self.list.items.clearAndFree(self.alloc);
}

pub fn deinit(self: *BufferList) void {
    for (self.list.items.items) |item| {
        const entry: *BufferListItem = @ptrCast(@alignCast(item));
        entry.deinit(self.alloc);
        self.alloc.destroy(entry);
    }

    self.list.deinit(self.alloc);
    self.alloc.destroy(self.list);
}
