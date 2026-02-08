const DirectoryTree = @This();

const std = @import("std");
const vx = @import("vaxis");

const App = @import("../App.zig");
const Cell = @import("layout/Cell.zig");
const Config = @import("../Config.zig");
const fs = @import("../fs.zig");
const List = @import("List.zig");
const NotesList = @import("NotesList.zig");
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
tree_items: std.ArrayList(*TreeItem) = .empty,

/// A of the paths of expanded directories.
/// Will be obsolete as soon as directory caches are in place.
expanded_dirs: std.ArrayList([]const u8) = .empty,

scroll_view: vx.widgets.ScrollView,

win: ?vx.Window = null,

is_insert: bool = false,

pub const TreeItem = struct {
    /// General list data
    data: List.Item,

    dir_entry: fs.Directories.Entry = .{},

    cell: *Cell,

    /// The parent index of the directory.
    /// Used to make expanding and collapsing a directory possible
    parent: usize = 0,

    children: std.ArrayList(usize) = .empty,

    /// Indicates whether a directory is expanded
    is_expanded: bool = false,

    /// Indicates the depth of a directory.
    /// Used to determine the indentation of the tree item.
    level: u16 = 0,

    /// The amount of notes a directory contains
    num_notes: usize = 0,

    /// The amount of sub directories a directory has
    num_dirs: usize = 0,

    /// Stores the rendered toggle arrow icon
    icon: []const u8 = "",

    // Stores the rendered toggle arrow icon
    toggle_arrow: []const u8 = "",

    pub fn deinit(self: *TreeItem, alloc: std.mem.Allocator) void {
        alloc.free(self.data.path);
        self.children.deinit(alloc);
        alloc.destroy(self.cell);
        self.data.deinit(alloc);
    }
};

pub fn init(alloc: std.mem.Allocator, title: []const u8, app: *App) !*DirectoryTree {
    const self = try alloc.create(DirectoryTree);

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

pub fn run(self: *DirectoryTree) !void {
    try self.buildTreeItems();
}

pub fn update(self: *DirectoryTree, event: App.Event) !void {
    if (self.tree_items.items.len == 0) {}

    switch (event) {
        .key_press => |key| {
            if (!self.cell.isFocused()) {
                return;
            }

            // handle input in insert mode to edit items
            if (self.app.mode == .insert) {
                const dir = self.selectedDir();
                try dir.data.input(key, self.alloc);
            }
        },
        else => {},
    }

    var tree_len = self.tree_items.items.len;
    if (tree_len > 0) {
        tree_len -= 1;
    }

    self.selected_index = std.math.clamp(self.selected_index, 0, tree_len);
    self.is_insert = self.app.mode == .insert and self.cell.isFocused();
}

pub fn draw(self: *DirectoryTree, win: vx.Window) void {
    const opts = self.cell.getChild();
    const child_win = win.child(opts);

    if (self.win == null) {
        self.win = child_win;
    }

    var index: isize = 0;
    for (self.tree_items.items) |item| {
        item.cell.setHeight(self.default_item_height);
        var child_opts = item.cell.getChild();
        // reset border for each tree item
        child_opts.border = .{};

        _ = child_win.child(child_opts);

        var style: vx.Cell.Style = .{};
        if (index == self.selected_index) {
            style.bg = theme.Color.List.selection_bg;
        }

        const row: u16 = @intCast(index + item.cell.height - 1);
        self.writeLine(item, row, self.cell.width, style);
        item.data.index = @intCast(index);
        index += 1;
    }

    // @todo find out why cursor doesn't render on keypress event
    //if (self.app.curevent == .key_press) {
    const selected_dir = self.selectedDir();
    if (selected_dir.data.edit_pos) |pos| {
        child_win.showCursor(pos.col, pos.row);
    }
    //}
}

pub fn drawHeader(self: DirectoryTree, win: vx.Window, col: u16) void {
    Cell.drawHeader(win, self.cell.title, col, self.cell.isFocused());
}

fn writeLine(self: DirectoryTree, item: *TreeItem, row: u16, width: u16, style: vx.Cell.Style) void {
    var col: u16 = 0;
    const pad_left = 1;
    var w: usize = 0;

    const selected_dir = self.selectedDir();

    if (self.win) |win| {
        // indentation
        for (1..pad_left + item.level) |_| {
            Cell.writeStr(win, &col, row, "  ", style);
        }

        // toggle arrow
        var has_children: []const u8 = " ";
        if (item.num_dirs > 0) {
            has_children = Icon.getAlt(.dir_closed);
        }
        var arrow_style: vx.Style = .{ .fg = theme.Color.List.toggle_fg };
        if (selected_dir == item) {
            arrow_style.fg = theme.Color.default_fg;
            arrow_style.bg = theme.Color.List.selection_bg;
        }

        if (item.is_expanded) {
            has_children = Icon.getAlt(.dir_open);
        }
        Cell.writeStr(win, &col, row, has_children, arrow_style);
        Cell.writeStr(win, &col, row, " ", style);

        // folder icon
        var dir_icon = Icon.getNerd(.dir_closed);
        if (item.is_expanded) {
            dir_icon = Icon.getNerd(.dir_open);
            has_children = Icon.getAlt(.dir_open);
        }
        if (self.is_insert and selected_dir == item) {
            dir_icon = Icon.getNerd(.pen);
        }

        Cell.writeStr(win, &col, row, dir_icon, style);
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

        // pad to end of column
        while (col < width) {
            Cell.writeStr(win, &col, row, " ", style);
        }
    }

    item.data.width = @intCast(w);
}

pub fn restore(self: *DirectoryTree) !void {
    const meta = self.app.config.meta_infos;
    self.setRowByPath(meta.last_directory);

    var i: usize = 0;
    for (self.tree_items.items) |item| {
        if (meta.files_info.get(item.data.path)) |file_info| {
            if (file_info.is_expanded) {
                try self.expandTreeItem(i);
            }
        }
        i += 1;
    }
}

/// Builds the initial directory tree from the notes root directory
fn buildTreeItems(self: *DirectoryTree) !void {
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const notes_root = try self.app.config.getNotesRootDir();
    const tmp_dir_entries = try fs.Directories.list(arena.allocator(), notes_root);

    for (tmp_dir_entries) |entry| {
        const dir_item = try self.createDirItem(entry, 0, 0);
        try self.tree_items.append(self.alloc, dir_item);
    }
}

fn expandTreeItem(self: *DirectoryTree, index: usize) !void {
    if (index >= self.tree_items.items.len or self.app.mode == .insert) {
        return;
    }

    var tree_item: *TreeItem = self.getTreeItem(index);
    const level = tree_item.level;

    if (tree_item.is_expanded or tree_item.num_dirs == 0) {
        return;
    }

    tree_item.is_expanded = true;

    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    // @todo: dont read the directory everytime we expand
    const tmp_dir_entry = try fs.Directories.list(
        arena.allocator(),
        tree_item.data.path,
    );

    var i: usize = 0;
    for (tmp_dir_entry) |entry| {
        const item: *TreeItem = try self.createDirItem(entry, index, level + 1);
        try self.tree_items.insert(self.alloc, index + 1, item);
        // track the child directories so that we can free them properly
        // when we collapse this directory.
        try tree_item.children.append(self.alloc, index + i);
        i += 1;
    }
}

fn collapseTreeItem(self: *DirectoryTree, index: usize) !void {
    if (index >= self.tree_items.items.len or self.is_insert) {
        return;
    }

    var tree_item: *TreeItem = self.getTreeItem(index);
    const tree_len = tree_item.children.items.len;

    if (!tree_item.is_expanded or tree_len == 0) {
        return;
    }

    tree_item.is_expanded = false;

    // free the children
    for (tree_item.children.items) |_| {
        const cindex = index + 1;
        const child = self.getTreeItem(cindex);

        if (child.children.items.len > 0) {
            try self.collapseTreeItem(cindex);
        }

        const row = self.tree_items.orderedRemove(cindex);
        row.deinit(self.alloc);
        self.alloc.destroy(row);
    }

    tree_item.children.clearAndFree(self.alloc);
    tree_item.children.deinit(self.alloc);
    tree_item.children = .empty;
}

fn createDirItem(
    self: *DirectoryTree,
    item: fs.Directories.Entry,
    parent_index: usize,
    level: u16,
) !*TreeItem {
    const tree_item = try self.alloc.create(TreeItem);

    const cell: *Cell = try .init(self.alloc);
    cell.setHeight(self.default_item_height);

    tree_item.* = .{
        .parent = parent_index,
        .level = level,
        .data = .{
            .index = 0,
            .name = try self.alloc.dupe(u8, item.basename),
            .path = try self.alloc.dupe(u8, item.path),
        },
        .cell = cell,
        .num_dirs = item.num_dirs,
        .num_notes = item.num_files,
    };

    return tree_item;
}

fn getTreeItem(self: DirectoryTree, index: usize) *TreeItem {
    return self.tree_items.items[index];
}

/// Prepares a list item for editing.
/// Sets app into insert mode and stores the initial target cursor position
/// for the item.
pub fn initEditListItem(self: *DirectoryTree) !void {
    const dir = self.selectedDir();
    try dir.data.edit(self.alloc, self.win);
    self.app.setMode(.insert);
}

/// Confirms the edited list item.
/// Renames the edited item on the operating system and updates
/// the meta info file if necessary.
pub fn confirmEdit(self: *DirectoryTree) !void {
    const dir = self.selectedDir();

    // get the string from `input_val`
    const joined_name = try dir.data.getStrFromInput(self.alloc);

    if (try fs.Directories.rename(self.alloc, dir.data.path, joined_name)) |new_path| {
        const conf_update = std.mem.eql(u8, dir.data.path, self.app.config.meta_infos.last_directory);

        // update tree item
        self.alloc.free(dir.data.path);
        dir.data.path = new_path;

        self.alloc.free(dir.data.name);
        dir.data.name = joined_name;

        if (conf_update) {
            self.updateLastDir();
            // @todo update meta info entries as well
        }
    }
    // @todo handle err with overlay or statusbar message maybe.
    //
    self.cancelEdit();
}

/// Cancels the editing process for the selected item.
/// Sets app mode to normal.
pub fn cancelEdit(self: *DirectoryTree) void {
    const dir = self.selectedDir();
    dir.data.cancelEdit(self.alloc);
    self.app.setMode(.normal);
}

pub fn setRowByPath(self: *DirectoryTree, path: []const u8) void {
    const index = self.getIndexByPath(path);
    self.selected_index = @intCast(index);
}

pub fn getIndexByPath(self: DirectoryTree, path: []const u8) usize {
    var i: usize = 0;
    // @todo iterate through child directories as well
    for (self.tree_items.items) |item| {
        if (utils.strEql(item.data.path, path)) {
            return i;
        }
        i += 1;
    }
    return 0;
}

pub fn selectedDir(self: DirectoryTree) *TreeItem {
    return self.getTreeItem(@intCast(self.selected_index));
}

pub fn focus(self: *DirectoryTree) void {
    self.cell.focus();
}

pub fn blur(self: *DirectoryTree) void {
    self.cell.blur();
}

pub fn setFocus(self: *DirectoryTree, f: bool) void {
    self.cell.setFocus(f);
}

pub fn cmdLineDown(self: *DirectoryTree) void {
    if (self.is_insert) return;
    self.selected_index += 1;
    self.clampIndex();
}

pub fn cmdLineUp(self: *DirectoryTree) void {
    if (self.is_insert) return;
    self.selected_index -= 1;
    self.clampIndex();
}

pub fn cmdExpand(self: *DirectoryTree) void {
    self.expandTreeItem(@intCast(self.selected_index)) catch return;
    const item = self.getTreeItem(@intCast(self.selected_index));
    self.app.config.meta_infos.addFileInfo(item) catch return;
    self.app.config.meta_infos.write() catch return;
}

pub fn cmdCollapse(self: *DirectoryTree) void {
    self.collapseTreeItem(@intCast(self.selected_index)) catch return;
    const item = self.getTreeItem(@intCast(self.selected_index));
    self.app.config.meta_infos.addFileInfo(item) catch return;
    self.app.config.meta_infos.write() catch return;
}

pub fn cmdSelectDir(self: *DirectoryTree) void {
    if (self.is_insert) return;
    const selected_dir = self.selectedDir();
    self.app.notes_list.getNotes(selected_dir.data.path) catch return;
    self.updateLastDir();
}

pub fn cmdGoToTop(self: *DirectoryTree) void {
    if (self.is_insert) return;
    self.selected_index = 0;
}

pub fn cmdGoToBottom(self: *DirectoryTree) void {
    if (self.is_insert) return;
    self.selected_index = @intCast(self.treeLen());
}

fn clampIndex(self: *DirectoryTree) void {
    self.selected_index = std.math.clamp(
        self.selected_index,
        0,
        self.treeLen(),
    );
}

/// Updates the `last_directory` entry in the metainfos file.
fn updateLastDir(self: DirectoryTree) void {
    self.app.config.meta_infos.setValue(
        .last_directory,
        self.selectedDir().data.path,
    ) catch return;
    self.app.config.meta_infos.write() catch return;
}

fn treeLen(self: DirectoryTree) usize {
    var tree_len = self.tree_items.items.len;
    if (tree_len > 0) {
        tree_len -= 1;
    }
    return tree_len;
}

pub fn deinit(self: *DirectoryTree) void {
    for (self.tree_items.items) |entry| {
        entry.deinit(self.alloc);
        self.alloc.destroy(entry);
    }

    self.tree_items.deinit(self.alloc);
    self.alloc.destroy(self.cell);
}
