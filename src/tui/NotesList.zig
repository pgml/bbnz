const NotesList = @This();

const std = @import("std");
const vx = @import("vaxis");

const App = @import("../App.zig");
const Buffer = @import("widgets/TextArea/TextArea.zig").Buffer;
const Cell = @import("layout/Cell.zig");
const fs = @import("../fs.zig");
const List = @import("List.zig");
const log = @import("../log.zig");
const theme = @import("layout/theme.zig");
const Icon = theme.Icon;
const ScrollView = @import("layout/ScrollView.zig");
const utils = @import("../utils.zig");

alloc: std.mem.Allocator,

app: *App,

list: *List,

/// The directory path of the currently displayed notes.
/// This path might not match the directory that is selected in the
/// directory tree since we don't automatically display a directory's
/// content on a selection change
current_path: []const u8 = "",

/// Contains dirty buffers of the current notes list
DirtyBuffers: std.ArrayList(Buffer) = .empty,

/// Buffers holds all the open buffers
Buffers: std.ArrayList(*Buffer) = .empty,

pub const NoteItem = struct {
    /// General list data
    data: List.Item,

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
        .list = try .init(alloc, title),
    };

    return self;
}

pub fn update(self: *NotesList, event: App.Event) !void {
    switch (event) {
        .key_press => |key| {
            if (!self.list.isFocused() or self.app.mode != .insert) {
                return;
            }

            if (self.list.is_insert) {
                const note = self.selectedNote() orelse return;
                try note.data.input(key, self.alloc);
            }
        },
        .winsize => |ws| {
            const sb_height = self.app.status_bar.cell.height;
            self.list.toggleVbar(ws.rows - sb_height, self.list.numItems());
        },
        else => {},
    }

    self.list.is_insert = self.app.mode == .insert and self.list.isFocused();
}

pub fn draw(self: *NotesList, win: vx.Window) void {
    const opts = self.list.cell.getChild();
    const child_win = win.child(opts);

    self.list.draw(child_win);

    const top_vis_row = self.list.getTopVisRow();
    const bottom_vis_row = self.list.getBottomVisRow();

    var i: usize = 0;
    for (self.list.getItemsSlice()[top_vis_row..bottom_vis_row]) |item| {
        const note: *NoteItem = @ptrCast(@alignCast(item));
        const term_row: usize = top_vis_row + i;
        note.data.cell.setHeight(self.list.default_item_height);
        var child_opts = note.data.cell.getChild();
        // reset border for each tree item
        child_opts.border = .{};

        _ = child_win.child(child_opts);

        var style: vx.Cell.Style = .{ .dim = self.app.isOverlayOpen() };
        if (term_row == self.list.selected_index) {
            style.bg = theme.Color.List.selection_bg;
        }

        self.writeLine(note, @intCast(term_row), self.list.getWidth(), style);
        note.data.index = @intCast(term_row);
        i += 1;

        if (note.data.edit_info) |pos| {
            self.list.win.?.showCursor(pos.col, pos.row);
        }
    }

    self.list.scroll_view.height = child_win.height;
    self.list.scroll_view.setRow(@intCast(self.list.selected_index));
    self.list.scroll_view.reposition();
}

pub inline fn drawHeader(self: NotesList, win: vx.Window) void {
    const col: u16 = @intCast(self.list.getOffsetX() + 1);
    Cell.drawHeader(win, self.list.getTitle(), col, 0, .{
        .is_focused = self.list.isFocused(),
    });
}

fn writeLine(
    self: NotesList,
    item: *NoteItem,
    row: u16,
    width: u16,
    style: vx.Cell.Style,
) void {
    var col: u16 = 0;
    var w: usize = 0;
    var view = self.list.scroll_view.view;

    if (self.list.win) |win| {
        Cell.writeStr(win, &view, &col, row, " ", style);

        var icon_style: vx.Style = .{
            .fg = theme.Color.List.note_fg,
            .dim = style.dim,
        };
        if (self.selectedNote()) |selected_note| {
            if (selected_note == item) {
                icon_style.fg = theme.Color.default_fg;
                icon_style.bg = theme.Color.List.selection_bg;
            }
        }

        var note_icon = Icon.getNerd(.note);
        if (self.selectedNote()) |note| {
            if (self.list.is_insert and note == item) {
                note_icon = Icon.getNerd(.pen);
            }
        }

        Cell.writeStr(win, &view, &col, row, note_icon, icon_style);
        Cell.writeStr(win, &view, &col, row, " ", style);

        // switch to input value when we're renaming
        if (self.list.is_insert and item.data.edit_info != null) {
            for (item.data.input_val.items) |char| {
                win.writeCell(
                    col,
                    @intCast(item.data.getTermRow(view.scroll.y)),
                    Cell.get(char.grapheme, char.width, style),
                );
                col += 1;
            }
        } else {
            Cell.writeStr(win, &view, &col, row, item.data.getName(false), style);
        }

        w = col;

        // pad the rest of the line to make the selection expand to the whole row
        while (col < width) {
            Cell.writeStr(win, &view, &col, row, " ", style);
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
    self.list.items = .empty;

    for (tmp_note_entries) |entry| {
        const note_item = try self.makeNoteItemFromEntry(entry);
        try self.list.items.append(self.alloc, note_item);
    }
}

fn allocNoteItem(self: *NotesList, item: NoteItem) !*NoteItem {
    const note_item = try self.alloc.create(NoteItem);

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

/// Inserts a temporary item into the directory tree in insert mode
/// as a child of the selected directory and selects it.
pub fn createListItem(self: *NotesList) !void {
    const list_item = try self.makeNoteItem();

    try self.list.items.append(self.alloc, list_item);
    list_item.data.index = self.list.numItems();
    self.list.selected_index = @intCast(list_item.data.index);
    try self.initEditListItem();
}

/// Prepares a list item for editing.
/// Sets app into insert mode and stores the initial target cursor position
/// for the item.
pub fn initEditListItem(self: *NotesList) !void {
    const note = self.selectedNote() orelse return;
    try note.data.edit(
        self.alloc,
        self.list.win,
        self.list.scroll_view.view.scroll.y,
    );
    // @todo save previous selected row so we can go back to that row
    // after canceling.
    //note.data.edit_info.?.prev_row = @intCast(self.selected_index);
    self.app.setMode(.insert);
}

inline fn getItem(self: NotesList, index: usize) ?*NoteItem {
    const item = self.list.getItem(index) orelse return null;
    const note_item: *NoteItem = @ptrCast(@alignCast(item));
    return note_item;
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
            log.err(
                "Failed to create directory: {s} ({})",
                .{ note.data.path, err },
            );
            return;
        };

        // free old data and replace with new data if creation was successful.
        note.data.reinit(self.alloc, new_path, name);
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
    const prev_row = note.data.edit_info.?.prev_row;
    note.data.resetInput(self.alloc);
    self.app.setMode(.normal);

    if (note.data.is_temporary) {
        const item = self.list.items.orderedRemove(note.data.index);
        const n: *NoteItem = @ptrCast(@alignCast(item));
        n.deinit(self.alloc);

        self.list.items.shrinkAndFree(self.alloc, self.list.len());
        self.list.selected_index = prev_row;
        self.alloc.destroy(n);
    }
}

pub fn selectedNote(self: NotesList) ?*NoteItem {
    if (self.getItem(@intCast(self.list.selected_index))) |item| {
        const note: *NoteItem = @ptrCast(@alignCast(item));
        return note;
    }
    return null;
}

pub fn cmdSelectNote(self: *NotesList) void {
    if (self.selectedNote()) |note| {
        self.app.editor.openBuf(note.data.path) catch return;
        self.updateLastNote();
    }
}

/// Updates the `last_open_note` entry in the metainfos file.
pub fn updateLastNote(self: *NotesList) void {
    const note = self.selectedNote() orelse return;
    self.app.config.meta_infos.setValue(
        .last_open_note,
        note.data.path,
    ) catch return;
    self.app.config.meta_infos.write() catch return;
}

fn freeNotes(self: *NotesList) void {
    for (self.list.items.items) |item| {
        const note: *NoteItem = @ptrCast(@alignCast(item));
        note.deinit(self.alloc);
        self.alloc.destroy(note);
    }
    self.list.items.clearAndFree(self.alloc);
}

pub fn deinit(self: *NotesList) void {
    self.freeNotes();
    self.list.deinit(self.alloc);
    self.alloc.destroy(self.list);
    self.alloc.free(self.current_path);
}
