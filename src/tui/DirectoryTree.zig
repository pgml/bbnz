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

    /// The parent index of the directory.
    /// Used to make expanding and collapsing a directory possible
    parent_index: usize = 0,

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

    indent_char: []const u8 = "  ",

    indent_level: u16 = 0,

    pub inline fn hasChildren(self: TreeItem) bool {
        return self.children.items.len > 0;
    }

    /// Attempts sets the expand state to true.
    /// Returns false if state is already expanded or if there's nothing
    /// to expand, otherwise true.
    pub fn expand(self: *TreeItem) bool {
        if (self.is_expanded or self.num_dirs == 0) {
            return false;
        }
        self.is_expanded = true;
        return true;
    }

    /// Attempts to set the expand state to false.
    /// Returns false if `is_expanded` is already false.
    pub fn collapse(self: *TreeItem, alloc: std.mem.Allocator) bool {
        if (!self.is_expanded) {
            return false;
        }
        self.is_expanded = false;
        self.children.clearAndFree(alloc);
        self.children.deinit(alloc);
        self.children = .empty;
        return true;
    }

    pub fn deinit(self: *TreeItem, alloc: std.mem.Allocator) void {
        alloc.free(self.data.path);
        self.children.deinit(alloc);
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
                const dir = self.selectedDir() orelse return;
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
    }

    // @todo find out why cursor doesn't render on keypress event
    //if (self.app.curevent == .key_press) {
    if (self.selectedDir()) |selected_dir| {
        if (selected_dir.data.edit_info) |pos| {
            child_win.showCursor(pos.col, pos.row);
        }
    }
    //}
}

pub inline fn drawHeader(self: DirectoryTree, win: vx.Window, col: u16) void {
    Cell.drawHeader(win, self.cell.title, col, self.cell.isFocused());
}

fn writeLine(self: DirectoryTree, item: *TreeItem, row: u16, width: u16, style: vx.Cell.Style) void {
    var col: u16 = 0;
    var w: usize = 0;

    const selected_dir = self.selectedDir();

    if (self.win) |win| {
        // indentation
        for (1..item.data.list_pad_left + item.level) |_| {
            Cell.writeStr(win, &col, row, item.indent_char, style);
        }

        // toggle arrow
        var has_children: []const u8 = " ";

        if (item.num_dirs > 0) {
            if (item.is_expanded) {
                has_children = Icon.getAlt(.dir_open);
            } else {
                has_children = Icon.getAlt(.dir_closed);
            }
        }

        var arrow_style: vx.Style = .{ .fg = theme.Color.List.toggle_fg };
        if (selected_dir == item) {
            arrow_style.fg = theme.Color.default_fg;
            arrow_style.bg = theme.Color.List.selection_bg;
        }

        Cell.writeStr(win, &col, row, has_children, arrow_style);
        Cell.writeStr(win, &col, row, " ", style);

        // folder icon
        var icon_style: vx.Style = .{ .fg = theme.Color.List.dir_fg };
        if (selected_dir == item) {
            icon_style.fg = theme.Color.default_fg;
            icon_style.bg = theme.Color.List.selection_bg;
        }

        var dir_icon = Icon.getNerd(.dir_closed);
        if (item.is_expanded and item.num_dirs > 0) {
            dir_icon = Icon.getNerd(.dir_open);
            has_children = Icon.getAlt(.dir_open);
        }
        if (self.is_insert and selected_dir == item) {
            dir_icon = Icon.getNerd(.pen);
        }

        Cell.writeStr(win, &col, row, dir_icon, icon_style);
        Cell.writeStr(win, &col, row, " ", style);

        // switch to input value when we're renaming
        if (self.is_insert and item.data.edit_info != null) {
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
    try self.expandItemsFromConfig();
}

/// Builds the initial directory tree from the notes root directory
fn buildTreeItems(self: *DirectoryTree) !void {
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const notes_root = try self.app.config.getNotesRootDir();
    const tmp_dir_entries = try fs.Directories.list(arena.allocator(), notes_root);

    for (tmp_dir_entries) |entry| {
        const dir_item = try self.makeTreeItemFromEntry(entry, 0, 0);
        try self.tree_items.append(self.alloc, dir_item);
    }
}

fn expandTreeItem(self: *DirectoryTree, index: usize) !void {
    if (index >= self.treeLen() or self.app.mode == .insert) {
        return;
    }

    var item: *TreeItem = self.getTreeItem(index) orelse return;
    if (!item.expand()) return;

    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();

    // @todo: dont read the directory everytime we expand
    const tmp_dir_entry = try fs.Directories.list(
        arena.allocator(),
        item.data.path,
    );

    var i: usize = 0;
    for (tmp_dir_entry) |entry| {
        const tree_item = try self.makeTreeItemFromEntry(entry, index, item.level + 1);
        try self.tree_items.insert(self.alloc, index + 1, tree_item);
        // track the child directories so that we can free them properly
        // when we collapse this directory.
        try item.children.append(self.alloc, index + i);
        i += 1;
    }
}

fn collapseTreeItem(self: *DirectoryTree, index: usize) !void {
    if (index >= self.tree_items.items.len or self.is_insert) {
        return;
    }

    var item: *TreeItem = self.getTreeItem(index) orelse return;

    // free the children
    for (item.children.items) |_| {
        const cindex = index + 1;
        const child = self.getTreeItem(cindex) orelse continue;

        if (child.children.items.len > 0) {
            try self.collapseTreeItem(cindex);
        }

        const row = self.tree_items.orderedRemove(cindex);
        row.deinit(self.alloc);
        self.alloc.destroy(row);
    }

    _ = item.collapse(self.alloc);
}

/// allocates the given TreeItem.
fn allocTreeItem(
    self: *DirectoryTree,
    item: TreeItem,
) !*TreeItem {
    const tree_item = try self.alloc.create(TreeItem);
    const cell: *Cell = try .init(self.alloc);
    cell.setHeight(self.default_item_height);

    tree_item.* = .{
        .parent_index = item.parent_index,
        .level = item.level,
        .data = .{
            .index = 0,
            .name = try self.alloc.dupe(u8, item.data.name),
            .path = try self.alloc.dupe(u8, item.data.path),
            .width = @intCast(item.data.width),
            .cell = cell,
            .is_temporary = item.data.is_temporary,
        },
        .num_dirs = item.num_dirs,
        .num_notes = item.num_notes,
    };

    return tree_item;
}

/// Creates a default `TreeItem`.
/// If `parent_item` is set, the new item will be a child of `parent_item`.
fn makeTreeItem(self: *DirectoryTree, parent_item: ?*TreeItem) !*TreeItem {
    const name = "New Folder";
    // whitespace after icons
    // @todo find a better way to determine width
    const ws = 2;
    var width = name.len + ws;
    var level: u16 = 0;
    var parent_index: usize = 0;

    var path = try self.alloc.dupe(u8, try self.app.config.getNotesRootDir());
    defer self.alloc.free(path);

    if (parent_item) |parent| {
        const indw = parent.data.width - parent.data.name.len;
        width = indw + name.len + ws;
        level = parent.level + 1;
        parent_index = parent.data.index;

        self.alloc.free(path);
        path = try std.fs.path.join(self.alloc, &.{ parent.data.path, name });
    }

    const tree_item = self.allocTreeItem(.{
        .parent_index = parent_index,
        .level = level,
        .data = .{
            .name = name,
            .path = path,
            .width = @intCast(width),
            .is_temporary = true,
        },
    });

    return tree_item;
}

/// Creates a tree item from a `fs.Directories.Entry`
fn makeTreeItemFromEntry(
    self: *DirectoryTree,
    entry: fs.Directories.Entry,
    parent_index: usize,
    level: u16,
) !*TreeItem {
    return self.allocTreeItem(.{
        .parent_index = parent_index,
        .level = level,
        .data = .{
            .name = entry.basename,
            .path = entry.path,
        },
        .num_dirs = entry.num_dirs,
        .num_notes = entry.num_files,
    });
}

fn getTreeItem(self: DirectoryTree, index: usize) ?*TreeItem {
    if (index > self.treeLen()) return null;
    return self.tree_items.items[index];
}

/// Inserts a temporary item into the directory tree in insert mode
/// as a child of the selected directory and selects it.
pub fn createListItem(self: *DirectoryTree) !void {
    const dir = self.selectedDir() orelse return;
    dir.num_dirs += 1;

    if (!dir.is_expanded) {
        try self.expandTreeItem(dir.data.index);
    }

    const last_index = self.getLastChildIndex(dir.data.index);
    const list_item = try self.makeTreeItem(dir);
    const tmp_path = try std.fs.path.join(self.alloc, &.{
        dir.data.path,
        list_item.data.name,
    });
    defer self.alloc.free(tmp_path);

    self.selected_index = @intCast(last_index);
    try self.tree_items.insert(self.alloc, last_index, list_item);
    try dir.children.append(self.alloc, last_index);
    list_item.data.index = last_index;
    try self.initEditListItem();
}

/// Prepares a list item for editing.
/// Sets app into insert mode and stores the initial target cursor position
/// for the item.
pub fn initEditListItem(self: *DirectoryTree) !void {
    const dir = self.selectedDir() orelse return;
    try dir.data.edit(self.alloc, self.win);
    self.app.setMode(.insert);
}

/// Confirms the edited list item.
/// Renames the edited item on the operating system and updates
/// the meta info file if necessary.
pub fn confirmEdit(self: *DirectoryTree) !void {
    const dir = self.selectedDir() orelse return;
    const dir_path = dir.data.path;

    // get the string from `input_val`
    const name = try dir.data.getStrFromInput(self.alloc);

    // folder create
    if (dir.data.is_temporary) {
        const new_path = fs.Directories.create(self.alloc, dir_path, name) catch |err| {
            std.log.err(
                "Failed to create directory: {s} ({})",
                .{ dir.data.path, err },
            );
            return;
        };

        if (new_path) |path| {
            dir.data.reinit(self.alloc, path, name);
        } else {
            self.alloc.free(name);
        }

        dir.data.resetInput(self.alloc);
        self.app.setMode(.normal);
    }
    // folder rename
    else {
        if (try fs.Directories.rename(self.alloc, dir_path, name)) |new_path| {
            // nothing's changed, bail out
            if (std.mem.eql(u8, dir_path, new_path)) {
                try self.cancelEdit();
                self.alloc.free(name);
                return;
            }

            const meta = self.app.config.meta_infos;
            // check for last directory equality here since it's path will
            // be freed later when we actually need to check it.
            const conf_update = std.mem.eql(u8, dir_path, meta.last_directory);

            // update tree item
            self.alloc.free(dir.data.path);
            self.alloc.free(dir.data.name);
            dir.data.path = new_path;
            dir.data.name = name;

            if (conf_update) {
                self.updateLastDir();
                // @todo update meta info entries as well
            }
        }
        //
        // @todo handle err with overlay or statusbar message maybe.
        //
        try self.cancelEdit();
    }
}

/// Cancels the editing process for the selected item.
/// Sets app mode to normal.
pub fn cancelEdit(self: *DirectoryTree) !void {
    const dir = self.selectedDir() orelse return;
    dir.data.resetInput(self.alloc);
    self.app.setMode(.normal);

    // Remove any traces of temporary child directories.
    if (dir.data.is_temporary) {
        const parent = self.getTreeItem(dir.parent_index) orelse return;
        self.selected_index = @intCast(parent.data.index);

        if (parent.num_dirs == 1) {
            parent.num_dirs -= 1;
        }

        const children = parent.children.items;
        for (0..parent.children.items.len) |i| {
            if (children[i] == dir.data.index) {
                _ = parent.children.orderedRemove(i);
            }
        }

        const item = self.tree_items.orderedRemove(dir.data.index);
        item.deinit(self.alloc);

        self.tree_items.shrinkAndFree(self.alloc, self.tree_items.items.len);
        self.alloc.destroy(dir);
    }
}

fn expandItemsFromConfig(self: *DirectoryTree) !void {
    var meta = self.app.config.meta_infos;
    var i: usize = 0;

    for (self.tree_items.items) |tree_item| {
        if (meta.files_info.get(tree_item.data.path)) |file_info| {
            if (file_info.is_expanded) {
                try self.expandTreeItem(i);
            }
        }
        i += 1;
    }
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

/// Returns the last child of the tree item with the given index
fn getLastChildIndex(self: *DirectoryTree, parent_index: usize) usize {
    if (self.getTreeItem(parent_index)) |dir| {
        var child_index = self.tree_items.items.len;

        if (dir.hasChildren()) {
            var i: usize = parent_index;
            for (self.tree_items.items) |item| {
                if (item.parent_index < parent_index) {
                    continue;
                }
                i += 1;
                child_index = i;
            }
        }
        // if there's no children, take the index of the parent
        else {
            child_index = parent_index;
        }

        return child_index + 1;
    }

    return 0;
}

pub inline fn selectedDir(self: DirectoryTree) ?*TreeItem {
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
    const item = self.getTreeItem(@intCast(self.selected_index)) orelse return;
    self.app.config.meta_infos.addFileInfo(item) catch return;
    self.app.config.meta_infos.write() catch return;
}

pub fn cmdCollapse(self: *DirectoryTree) void {
    self.collapseTreeItem(@intCast(self.selected_index)) catch return;
    const item = self.getTreeItem(@intCast(self.selected_index)) orelse return;
    self.app.config.meta_infos.addFileInfo(item) catch return;
    self.app.config.meta_infos.write() catch return;
}

pub fn cmdSelectDir(self: *DirectoryTree) void {
    if (self.is_insert) return;
    const selected_dir = self.selectedDir() orelse return;
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
    const dir = self.selectedDir() orelse return;
    self.app.config.meta_infos.setValue(.last_directory, dir.data.path) catch return;
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
