const NotesList = @This();

const std = @import("std");
const vx = @import("vaxis");

const App = @import("../App.zig");
const Buffer = @import("widgets/TextArea/TextArea.zig").Buffer;
const Cell = @import("layout/Cell.zig");
const fs = @import("../fs.zig");
const List = @import("List.zig");
const theme = @import("layout/theme.zig");
const Icon = theme.Icon;
const utils = @import("../utils.zig");

alloc: std.mem.Allocator,

app: *App,

/// The name of the DirectoryTree.
/// We use this as the default column title.
name: []const u8 = "",

/// The layout cell/column
cell: *Cell,

/// default width of the directory tree column.
default_width: u16 = 30,

/// default heigh of the directory tree column.
default_height: u16 = 0,

/// default height of a single directory item
default_item_height: u16 = 1,

/// The list index of the selected tree item/directory.
selected_index: isize = 0,

/// A flat list of all visible directories.
note_items: std.ArrayList(*NoteItem) = .empty,

/// The directory path of the currently displayed notes.
/// This path might not match the directory that is selected in the
/// directory tree since we don't automatically display a directory's
/// content on a selection change
current_path: []const u8 = "",

/// Contains dirty buffers of the current notes list
DirtyBuffers: std.ArrayList(Buffer) = .empty,

/// Buffers holds all the open buffers
Buffers: std.ArrayList(*Buffer) = .empty,

scroll_view: vx.widgets.ScrollView,

win: ?vx.Window = null,

is_insert: bool = false,

pub const NoteItem = struct {
    /// General list data
    data: List.Item,

    /// Stores the rendered toggle arrow icon
    icon: []const u8 = "",

    // Stores the rendered toggle arrow icon
    toggle_arrow: []const u8 = "",

    pub fn deinit(self: *NoteItem, alloc: std.mem.Allocator) void {
        alloc.free(self.data.path);
        self.data.deinit(alloc);
    }
};

pub fn init(alloc: std.mem.Allocator, title: []const u8, app: *App) !*NotesList {
    const self = try alloc.create(NotesList);

    self.* = .{
        .alloc = alloc,
        .app = app,
        .name = title,
        .cell = try .init(alloc),
        .scroll_view = .{},
    };

    self.cell.setWidth(self.default_width);
    self.cell.title = title;

    return self;
}

pub fn update(self: *NotesList, event: App.Event) !void {
    switch (event) {
        .key_press => |key| {
            if (!self.cell.isFocused() or self.app.mode != .insert) {
                return;
            }

            if (self.is_insert) {
                const note = self.selectedNote() orelse return;
                try note.data.input(key, self.alloc);
            }
        },
        else => {},
    }

    self.is_insert = self.app.mode == .insert and self.cell.isFocused();
}

pub fn draw(self: *NotesList, win: vx.Window) void {
    const opts = self.cell.getChild();
    const child_win = win.child(opts);

    if (self.win == null) {
        self.win = child_win;
    }

    var index: isize = 0;
    for (self.note_items.items) |item| {
        item.data.cell.setHeight(self.default_item_height);
        var child_opts = item.data.cell.getChild();
        // reset border for each tree item
        child_opts.border = .{};

        _ = child_win.child(child_opts);

        var style: vx.Cell.Style = .{};
        if (index == self.selected_index) {
            style.bg = theme.Color.List.selection_bg;
        }

        const row: u16 = @intCast(index + item.data.cell.height - 1);
        self.writeLine(item, row, self.cell.width, style);
        item.data.index = @intCast(index);
        index += 1;

        if (item.data.edit_pos) |pos| {
            self.win.?.showCursor(pos.col, pos.row);
        }
    }
}

pub inline fn drawHeader(self: NotesList, win: vx.Window) void {
    const col: u16 = @intCast(self.cell.offset_x + 1);
    Cell.drawHeader(win, self.cell.title, col, self.cell.isFocused());
}

fn writeLine(self: NotesList, item: *NoteItem, row: u16, width: u16, style: vx.Cell.Style) void {
    var col: u16 = 0;
    var w: usize = 0;

    if (self.win) |win| {
        Cell.writeStr(win, &col, row, " ", style);

        var icon_style: vx.Style = .{ .fg = theme.Color.List.note_fg };
        if (self.selectedNote()) |selected_note| {
            if (selected_note == item) {
                icon_style.bg = theme.Color.List.selection_bg;
            }
        }
        var note_icon = Icon.getNerd(.note);
        if (self.selectedNote()) |note| {
            if (self.is_insert and note == item) {
                note_icon = Icon.getNerd(.pen);
            }
        }
        Cell.writeStr(win, &col, row, note_icon, icon_style);
        Cell.writeStr(win, &col, row, " ", style);

        // switch to input value when we're renaming
        if (self.is_insert and item.data.edit_pos != null) {
            for (item.data.input_val.items) |char| {
                win.writeCell(col, row, Cell.get(char.grapheme, char.width, style));
                col += 1;
            }
        } else {
            Cell.writeStr(win, &col, row, item.data.name, style);
        }

        w = col;

        // pad the rest of the line to make the selection expand to the whole row
        while (col < width) {
            Cell.writeStr(win, &col, row, " ", style);
        }
    }

    item.data.width = @intCast(w);
}

pub fn restore(self: *NotesList) !void {
    const meta = self.app.config.meta_infos;
    try self.getNotes(meta.last_directory);
}

pub fn getNotes(self: *NotesList, path: []const u8) !void {
    if (utils.strEql(path, "")) {
        return;
    }

    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();

    self.alloc.free(self.current_path);
    self.current_path = try self.alloc.dupe(u8, path);

    const tmp_note_entries = try fs.Notes.list(
        arena.allocator(),
        self.current_path,
    );

    self.freeNotes();
    self.note_items = .empty;

    for (tmp_note_entries) |entry| {
        const note_item = try self.makeNoteItemFromEntry(entry);
        try self.note_items.append(self.alloc, note_item);
    }
}

fn allocNoteItem(self: *NotesList, item: NoteItem) !*NoteItem {
    const note_item = try self.alloc.create(NoteItem);

    const cell: *Cell = try .init(self.alloc);
    cell.setHeight(self.default_item_height);

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

fn makeNoteItem(self: *NotesList) !*NoteItem {
    const name = "New Note";
    const width = name.len + 3; // 3 = padding, icon, padding @todo, make it ugly

    return self.allocNoteItem(.{
        .data = .{
            .name = name,
            .path = self.current_path,
            .width = width,
            .is_temporary = true,
        },
    });
}

fn makeNoteItemFromEntry(self: *NotesList, item: fs.Notes.Entry) !*NoteItem {
    return self.allocNoteItem(.{
        .data = .{
            .name = item.name,
            .path = item.path,
        },
    });
}

fn getListItem(self: NotesList, index: usize) ?*NoteItem {
    if (index >= self.note_items.items.len) {
        return null;
    }
    return self.note_items.items[index];
}

/// Inserts a temporary item into the directory tree in insert mode
/// as a child of the selected directory and selects it.
pub fn createListItem(self: *NotesList) !void {
    const list_item = try self.makeNoteItem();

    try self.note_items.append(self.alloc, list_item);
    list_item.data.index = self.note_items.items.len - 1;
    self.selected_index = @intCast(list_item.data.index);
    try self.initEditListItem();
}

/// Prepares a list item for editing.
/// Sets app into insert mode and stores the initial target cursor position
/// for the item.
pub fn initEditListItem(self: *NotesList) !void {
    const note = self.selectedNote() orelse return;
    try note.data.edit(self.alloc, self.win);
    self.app.setMode(.insert);
}

/// Confirms the edited list item.
/// Renames the edited item on the operating system and updates
/// the meta info file if necessary.
pub fn confirmEdit(self: *NotesList) !void {
    const note = self.selectedNote() orelse return;

    // get the string from `input_val`
    const name = try note.data.getStrFromInput(self.alloc);

    if (note.data.is_temporary) {
        const new_path = fs.Notes.create(self.alloc, self.current_path, name) catch |err| {
            self.alloc.free(name);
            std.log.err(
                "Failed to create directory: {s} ({})",
                .{ note.data.path, err },
            );
            return;
        };

        // free old data and replace with new data if creation was successful.
        self.alloc.free(note.data.path);
        self.alloc.free(note.data.name);
        note.data.path = new_path;
        note.data.name = name;
        note.data.resetInput(self.alloc);
        self.app.setMode(.normal);
    } else {
        if (try fs.Notes.rename(self.alloc, note.data.path, name)) |new_path| {
            // nothing's changed, bail out
            if (std.mem.eql(u8, note.data.path, new_path)) {
                try self.cancelEdit();
                self.alloc.free(name);
                return;
            }

            const conf_update = std.mem.eql(
                u8,
                note.data.path,
                self.app.config.meta_infos.last_open_note,
            );

            self.alloc.free(note.data.path);
            self.alloc.free(note.data.name);
            note.data.path = new_path;
            note.data.name = name;

            if (conf_update) {
                self.updateLastNote();
                // @todo update meta info entries as well
            }
        }
        // @todo handle err with overlay or statusbar message maybe.
        //
        try self.cancelEdit();
    }
}

pub fn cancelEdit(self: *NotesList) !void {
    const note = self.selectedNote() orelse return;
    note.data.resetInput(self.alloc);
    self.app.setMode(.normal);

    if (note.data.is_temporary) {
        const item = self.note_items.orderedRemove(note.data.index);
        item.deinit(self.alloc);

        self.note_items.shrinkAndFree(self.alloc, self.note_items.items.len);
        self.alloc.destroy(item);
    }
}

pub fn selectedNote(self: NotesList) ?*NoteItem {
    if (self.getListItem(@intCast(self.selected_index))) |note| {
        return note;
    }
    return null;
}

pub fn focus(self: *NotesList) void {
    self.cell.focus();
}

pub fn blur(self: *NotesList) void {
    self.cell.blur();
}

pub fn setFocus(self: *NotesList, f: bool) void {
    self.cell.setFocus(f);
}

pub fn cmdLineDown(self: *NotesList) void {
    self.selected_index += 1;
    self.clampIndex();
}

pub fn cmdLineUp(self: *NotesList) void {
    self.selected_index -= 1;
    self.clampIndex();
}

pub fn cmdSelectNote(self: *NotesList) void {
    if (self.selectedNote()) |note| {
        self.app.editor.openBuf(note.data.path) catch return;
        self.updateLastNote();
    }
}

/// Updates the `last_open_note` entry in the metainfos file.
fn updateLastNote(self: *NotesList) void {
    const note = self.selectedNote() orelse return;
    self.app.config.meta_infos.setValue(
        .last_open_note,
        note.data.path,
    ) catch return;
    self.app.config.meta_infos.write() catch return;
}

pub fn cmdGoToTop(self: *NotesList) void {
    self.selected_index = 0;
}

pub fn cmdGoToBottom(self: *NotesList) void {
    self.selected_index = @intCast(self.listLen());
}

fn clampIndex(self: *NotesList) void {
    self.selected_index = std.math.clamp(
        self.selected_index,
        0,
        self.listLen(),
    );
}

fn listLen(self: NotesList) usize {
    var list_len = self.note_items.items.len;
    if (list_len > 0) {
        list_len -= 1;
    }
    return list_len;
}

fn freeNotes(self: *NotesList) void {
    for (self.note_items.items) |notes| {
        notes.deinit(self.alloc);
        self.alloc.destroy(notes);
    }
    self.note_items.deinit(self.alloc);
}

pub fn deinit(self: *NotesList) void {
    self.freeNotes();
    self.alloc.free(self.current_path);
}
