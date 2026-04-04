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
const ScrollView = @import("layout/ScrollView.zig");
const utils = @import("../utils.zig");

alloc: std.mem.Allocator,

app: *App,

list: *List,

/// A of the paths of expanded directories.
/// Will be obsolete as soon as directory caches are in place.
expanded_dirs: std.ArrayList([]const u8) = .empty,

pub const TreeItem = struct {
    /// General list data
    data: List.Item,

    dir_entry: fs.Directories.Entry = .{},

    /// The amount of notes a directory contains
    num_notes: usize = 0,

    /// The amount of sub directories a directory has
    num_dirs: usize = 0,

    indent_char: []const u8 = "  ",

    indent_level: u16 = 0,

    pub inline fn hasChildren(self: TreeItem) bool {
        return self.data.children.items.len > 0;
    }

    /// Attempts sets the expand state to true.
    /// Returns false if state is already expanded or if there's nothing
    /// to expand, otherwise true.
    pub fn expand(self: *TreeItem) bool {
        if (self.data.is_expanded or self.num_dirs == 0) {
            return false;
        }
        self.data.is_expanded = true;
        return true;
    }

    /// Attempts to set the expand state to false.
    /// Returns false if `is_expanded` is already false.
    pub fn collapse(self: *TreeItem, alloc: std.mem.Allocator) bool {
        if (!self.data.is_expanded) {
            return false;
        }
        self.data.is_expanded = false;
        self.data.children.clearAndFree(alloc);
        self.data.children.deinit(alloc);
        self.data.children = .empty;
        return true;
    }

    pub fn deinit(self: *TreeItem, alloc: std.mem.Allocator) void {
        alloc.free(self.data.path);
        self.data.children.deinit(alloc);
        self.data.deinit(alloc);
    }
};

pub fn init(alloc: std.mem.Allocator, title: []const u8, app: *App) !*DirectoryTree {
    const self = try alloc.create(DirectoryTree);

    self.* = .{
        .alloc = alloc,
        .app = app,
        .list = try .init(alloc, title, app),
    };

    return self;
}

pub fn update(self: *DirectoryTree, event: App.Event) !void {
    if (self.list.len() == 0) {}

    switch (event) {
        .key_press => |key| {
            if (!self.list.isFocused()) {
                return;
            }

            // handle input in insert mode to edit items
            if (self.app.mode == .insert) {
                const dir = self.selectedDir() orelse return;
                try dir.data.input(key, self.alloc);
            }
        },
        .winsize => |ws| {
            const sb_height = self.app.status_bar.cell.height;
            self.list.toggleVbar(ws.rows - sb_height, self.list.numItems());
        },
        else => {},
    }

    self.list.clampIndex(null);
    self.list.is_insert = self.app.mode == .insert and self.list.isFocused();
}

pub fn draw(self: *DirectoryTree, win: vx.Window) !void {
    const opts = self.list.cell.getChild();
    var child_win = win.child(opts);

    self.list.draw(child_win);

    const top_vis_row = self.list.getTopVisRow();
    const bottom_vis_row = self.list.getBottomVisRow();

    var i: usize = 0;
    for (self.list.getItemsSlice()[top_vis_row..bottom_vis_row]) |item| {
        const dir: *TreeItem = @ptrCast(@alignCast(item));
        const term_row = top_vis_row + i;
        dir.data.cell.setHeight(self.list.default_item_height);
        var child_opts = dir.data.cell.getChild();
        // reset border for each tree item
        child_opts.border = .{};

        _ = child_win.child(child_opts);

        var style: vx.Cell.Style = .{ .dim = self.app.isAnyOverlayOpen() };
        if (term_row == self.list.selected_index) {
            style.bg = theme.Color.List.selection_bg;
        }

        self.drawLine(dir, @intCast(term_row), style);
        i += 1;
    }

    self.list.scroll_view.height = child_win.height;
    self.list.scroll_view.setRow(@intCast(self.list.selected_index));
    self.list.scroll_view.reposition();

    // @todo find out why cursor doesn't render on keypress event
    //if (self.app.curevent == .key_press) {
    if (self.selectedDir()) |selected_dir| {
        if (selected_dir.data.edit_info) |pos| {
            child_win.showCursor(pos.col, pos.row);
        }
    }
    //}
}

/// Assigns the list item's indices.
/// This should be called every time any kind of list alteration
/// took place.
fn setRowIndices(self: *DirectoryTree) void {
    var i: usize = 0;
    for (self.list.items.items) |item| {
        const dir: *TreeItem = @ptrCast(@alignCast(item));
        dir.data.index = i;
        i += 1;
    }
}

const LineArgs = struct {
    item: *TreeItem,
    row: u16,
    style: vx.Style,
};

/// Draws a list row displaying icon and name and calculates the width
/// of the row.
fn drawLine(self: DirectoryTree, item: *TreeItem, row: u16, style: vx.Cell.Style) void {
    const win = self.list.win orelse return;

    var col: u16 = 0;
    var lwidth: usize = 0;
    var view = self.list.scroll_view.view;

    const line_args: LineArgs = .{
        .item = item,
        .row = row,
        .style = style,
    };

    // indentation
    for (1..item.data.list_pad_left + item.data.level) |_| {
        Cell.writeStr(win, &view, &col, row, item.indent_char, style);
    }

    self.drawArrow(&col, line_args);

    Cell.writeSpacer(win, &view, &col, row, style);
    self.drawFolder(&col, line_args);

    Cell.writeSpacer(win, &view, &col, row, style);
    self.drawName(&col, line_args);

    lwidth = col;

    // pad to end of column
    while (col < self.list.getWidth()) {
        Cell.writeStr(win, &view, &col, row, " ", style);
    }

    item.data.width = @intCast(lwidth);
}

/// Draws the folder's arrow depending on the folder state or none if
/// the folder has no sub directories.
fn drawArrow(self: DirectoryTree, col: *u16, args: LineArgs) void {
    const win = self.list.win orelse return;

    var view = self.list.scroll_view.view;
    var arrow_style: vx.Style = .{
        .fg = theme.Color.List.toggle_fg,
        .dim = args.style.dim,
    };

    const selected_dir = self.selectedDir();
    if (selected_dir == args.item) {
        arrow_style.fg = theme.Color.default_fg;
        arrow_style.bg = theme.Color.List.selection_bg;
    }

    var icon: []const u8 = " ";
    if (args.item.num_dirs > 0) {
        icon = Icon.getAlt(.dir_closed);

        if (args.item.data.is_expanded) {
            icon = Icon.getAlt(.dir_open);
        }
    }

    Cell.writeStr(win, &view, col, args.row, icon, arrow_style);
}

/// Draws the folder's icon depending on the folder state or none if
/// the folder has no sub directories.
fn drawFolder(self: DirectoryTree, col: *u16, args: LineArgs) void {
    const win = self.list.win orelse return;

    var view = self.list.scroll_view.view;
    var icon_style: vx.Style = .{
        .fg = theme.Color.List.dir_fg,
        .dim = args.style.dim,
    };

    const selected_dir = self.selectedDir();
    if (selected_dir == args.item) {
        icon_style.fg = theme.Color.default_fg;
        icon_style.bg = theme.Color.List.selection_bg;
    }

    var dir_icon = Icon.getNerd(.dir_closed);
    if (args.item.data.is_expanded and args.item.num_dirs > 0) {
        dir_icon = Icon.getNerd(.dir_open);
    }

    if (args.item.data.is_pinned) {
        dir_icon = Icon.getNerd(.pin);
        icon_style.fg = theme.Color.Border.fg_focused;
    }

    if (self.list.is_insert and selected_dir == args.item) {
        dir_icon = Icon.getNerd(.pen);
    }

    Cell.writeStr(win, &view, col, args.row, dir_icon, icon_style);
}

/// Draws the row's name or renders an input field if in insert mode.
fn drawName(self: DirectoryTree, col: *u16, args: LineArgs) void {
    const win = self.list.win orelse return;
    const item = args.item;
    var view = self.list.scroll_view.view;

    // switch to input value when we're renaming
    if (self.list.is_insert and args.item.data.edit_info != null) {
        for (args.item.data.input_val.items) |char| {
            const ins_row: u16 = @intCast(item.data.getTermRow(view.scroll.y));
            const cell = Cell.get(char.grapheme, char.width, args.style);
            win.writeCell(col.*, ins_row, cell);
            col.* += 1;
        }
    } else {
        Cell.writeStr(win, &view, col, args.row, item.data.name, args.style);
    }
}

/// Refreshes the entire directory tree.
/// Invalidates all pointers and rebuilds the tree from scratch.
fn refresh(self: *DirectoryTree) !void {
    self.deinitItems();
    self.list.items.clearRetainingCapacity();
    try self.restore();
}

pub fn restore(self: *DirectoryTree) !void {
    const meta = self.app.config.meta_infos;

    var i: usize = 0;
    for (self.list.items.items) |item| {
        var dir_item: *TreeItem = @ptrCast(@alignCast(item));
        //dir_item.data.index = i;
        // checked pinned state
        if (meta.files_info.get(dir_item.data.path)) |file_info| {
            if (file_info.@"is-pinned".value) {
                dir_item.data.is_pinned = true;
            }
        }
        i += 1;
    }

    self.setRowByPath(meta.@"last-directory");
    try self.list.sortItems(&self.list.items);
    try self.createExpandRootFolder();
}

/// Builds the initial directory tree from the notes root directory
fn createExpandRootFolder(self: *DirectoryTree) !void {
    const notes_root = self.app.notes_root;
    const root_entry: fs.Directories.Entry = .{
        .basename = App.name,
        .path = notes_root,
        .num_files = try fs.Directories.getChildCount(notes_root, .file),
        .num_dirs = try fs.Directories.getChildCount(notes_root, .directory),
    };
    const root_dir_item = try self.makeTreeItemFromEntry(root_entry, 0, 0);

    try self.app.config.meta_infos.files_info.put(notes_root, .{
        .@"is-expanded" = .{ .value = root_dir_item.data.is_expanded },
        .@"is-pinned" = .{ .value = root_dir_item.data.is_pinned },
    });

    try self.list.items.append(self.alloc, root_dir_item);
    try self.expandTreeItem(0);
    self.setRowIndices();
}

/// Expands the tree item at the `index` and recusively checks for
/// expansion state of any children.
fn expandTreeItem(self: *DirectoryTree, index: usize) !void {
    if (index > self.list.len() or self.app.mode == .insert) {
        return;
    }

    var item: *TreeItem = self.getItem(index) orelse return;
    if (!item.expand()) return;

    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();

    // @todo: dont read the directory everytime we expand
    const tmp_dir_entry = try fs.Directories.list(
        arena.allocator(),
        item.data.path,
    );

    const meta = self.app.config.meta_infos;

    for (tmp_dir_entry) |entry| {
        const level = item.data.level + 1;
        const tree_item = try self.makeTreeItemFromEntry(entry, index, level);

        if (meta.files_info.get(tree_item.data.path)) |file_info| {
            tree_item.data.is_pinned = file_info.@"is-pinned".value;
        }

        try item.data.children.append(self.alloc, tree_item);
    }

    try self.list.sortItems(&item.data.children);
    self.setRowIndices();

    var i = item.data.children.items.len;
    while (i > 0) {
        i -= 1;
        const child_item = item.data.children.items[i];
        const tree_item: *TreeItem = @ptrCast(@alignCast(child_item));
        const insert_index = index + 1;

        try self.list.items.insert(self.alloc, insert_index, tree_item);

        // recusively check children for expanded state
        if (meta.files_info.get(tree_item.data.path)) |file_info| {
            if (!file_info.@"is-expanded".value) {
                continue;
            }
            try self.expandTreeItem(insert_index);
        }
    }

    self.setRowIndices();
}

fn collapseTreeItem(self: *DirectoryTree, index: usize) !void {
    if (index > self.list.len() or self.list.is_insert) {
        return;
    }

    var item: *TreeItem = self.getItem(index) orelse return;

    // free the children
    for (item.data.children.items) |_| {
        const cindex = index + 1;
        const child = self.getItem(cindex) orelse continue;

        if (child.data.children.items.len > 0) {
            try self.collapseTreeItem(cindex);
        }

        const tree_item = self.list.items.orderedRemove(cindex);
        const row: *TreeItem = @ptrCast(@alignCast(tree_item));
        row.deinit(self.alloc);
        self.alloc.destroy(row);
    }

    _ = item.collapse(self.alloc);

    self.setRowIndices();
}

/// allocates the given TreeItem.
fn allocTreeItem(self: *DirectoryTree, item: TreeItem) !*TreeItem {
    const tree_item = try self.alloc.create(TreeItem);
    const cell: *Cell = try .init(self.alloc);
    cell.setHeight(self.list.default_item_height);

    tree_item.* = .{
        .data = .{
            .index = 0,
            .parent_index = item.data.parent_index,
            .name = try self.alloc.dupe(u8, item.data.name),
            .level = item.data.level,
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

    var path = try self.alloc.dupe(u8, self.app.notes_root);
    defer self.alloc.free(path);

    if (parent_item) |parent| {
        const indw = parent.data.width - parent.data.name.len;
        width = indw + name.len + ws;
        level = parent.data.level + 1;
        parent_index = parent.data.index;

        self.alloc.free(path);
        path = try std.fs.path.join(self.alloc, &.{ parent.data.path, name });
    }

    const tree_item = self.allocTreeItem(.{
        .data = .{
            .parent_index = parent_index,
            .name = name,
            .path = path,
            .level = level,
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
        .data = .{
            .parent_index = parent_index,
            .level = level,
            .name = entry.basename,
            .path = entry.path,
        },
        .num_dirs = entry.num_dirs,
        .num_notes = entry.num_files,
    });
}

/// Inserts a temporary item into the directory tree in insert mode
/// as a child of the selected directory and selects it.
pub fn createListItem(self: *DirectoryTree) !void {
    const dir = self.selectedDir() orelse return;
    dir.num_dirs += 1;

    if (!dir.data.is_expanded) {
        try self.expandTreeItem(dir.data.index);
    }

    //const last_index = self.getLastChildIndex(dir.data.index);
    const index = dir.data.index + 1;
    const list_item = try self.makeTreeItem(dir);
    const tmp_path = try std.fs.path.join(self.alloc, &.{
        dir.data.path,
        list_item.data.name,
    });
    defer self.alloc.free(tmp_path);

    self.list.selected_index = @intCast(index);
    try self.list.items.insert(self.alloc, index, list_item);
    try dir.data.children.append(self.alloc, list_item);
    list_item.data.index = index;
    try self.initEditListItem();
    self.setRowIndices();
}

/// Prepares a list item for editing.
/// Sets app into insert mode and stores the initial target cursor position
/// for the item.
pub fn initEditListItem(self: *DirectoryTree) !void {
    // forbid renaming the root folder
    if (self.list.selected_index == 0) {
        return;
    }

    const dir = self.selectedDir() orelse return;
    try dir.data.edit(
        self.alloc,
        self.list.win,
        self.list.scroll_view.view.scroll.y,
    );
    self.app.setMode(.insert);
}

inline fn getItem(self: DirectoryTree, index: usize) ?*TreeItem {
    const item = self.list.getItem(index) orelse return null;
    const tree_item: *TreeItem = @ptrCast(@alignCast(item));
    return tree_item;
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
            const conf_update = std.mem.eql(u8, dir_path, meta.@"last-directory");

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
        const parent = self.getItem(dir.data.parent_index) orelse return;
        self.list.selected_index = @intCast(parent.data.index);

        if (parent.num_dirs == 1) {
            parent.num_dirs -= 1;
        }

        const children = parent.data.children.items;
        for (0..children.len) |i| {
            const child: *TreeItem = @ptrCast(@alignCast(children[i]));
            if (child.data.index == dir.data.index) {
                _ = parent.data.children.orderedRemove(i);
            }
        }

        const item = self.list.items.orderedRemove(dir.data.index);
        const row: *TreeItem = @ptrCast(@alignCast(item));
        row.deinit(self.alloc);

        self.list.items.shrinkAndFree(self.alloc, self.list.items.items.len);
        self.alloc.destroy(row);
    }

    self.setRowIndices();
}

fn expandItemsFromConfig(self: *DirectoryTree) !void {
    var meta = self.app.config.meta_infos;
    var i: usize = self.list.items.items.len;

    while (i > 0) {
        i -= 1;
        const item = self.list.items.items[i];
        const tree_item: *TreeItem = @ptrCast(@alignCast(item));
        if (meta.files_info.get(tree_item.data.path)) |file_info| {
            if (!file_info.is_expanded) {
                continue;
            }
            try self.expandTreeItem(i);
        }
    }
}

pub fn setRowByPath(self: *DirectoryTree, path: []const u8) void {
    const index = self.getIndexByPath(path);
    self.list.selected_index = @intCast(index);
}

pub fn getIndexByPath(self: DirectoryTree, path: []const u8) usize {
    var i: usize = 0;
    // @todo iterate through child directories as well
    for (self.list.items.items) |item| {
        const tree_item: *TreeItem = @ptrCast(@alignCast(item));
        if (utils.strEql(tree_item.data.path, path)) {
            return i;
        }
        i += 1;
    }
    return 0;
}

/// Returns the last child of the tree item with the given index
// broken, don't use, fix later.
//fn getLastChildIndex(self: *DirectoryTree, parent_index: usize) usize {
//    var parent_dir = self.getTreeItem(parent_index) orelse return 0;
//    //var child_index = self.tree_items.items.len;
//
//    if (parent_dir.hasChildren()) {
//        var last_child = parent_dir.children.getLast();
//        //std.log.debug("{}", .{dir.children.getLast()});
//        var i: usize = parent_index;
//        for (self.tree_items.items) |item| {
//            if (item.hasChildren()) {
//                last_child = item.children.getLast();
//            }
//            std.log.debug("{} > {} - {}, {}, {} --- {s}", .{
//                parent_index,
//                item.parent_index,
//                last_child,
//                i,
//                item.hasChildren(),
//                item.data.path,
//            });
//            if (i > last_child) {
//                //std.log.debug("{} {}", .{
//                //    last_child,
//                //});
//                continue;
//            }
//            i += 1;
//            //std.log.debug("yo", .{});
//            //child_index = i;
//        }
//        //child_index = parent_index;
//    }
//    // if there's no children, take the index of the parent
//    else {
//        //child_index = parent_index;
//    }
//
//    return parent_index + 1;
//    //return child_index + 1;
//}

pub inline fn selectedDir(self: DirectoryTree) ?*TreeItem {
    return self.getItem(@intCast(self.list.selected_index));
}

pub fn togglePin(self: *DirectoryTree) !void {
    const list_item = self.list.getItem(@intCast(self.list.selected_index)) orelse return;
    const item: *List.Item = @ptrCast(@alignCast(list_item));
    const path = try self.alloc.dupe(u8, item.path);
    defer self.alloc.free(path);

    try self.list.togglePin(item, false);
    try self.refresh();

    for (self.list.items.items, 0..) |entry, i| {
        const tree_item: *List.Item = @ptrCast(@alignCast(entry));
        if (std.mem.eql(u8, tree_item.path, path)) {
            self.list.selected_index = @intCast(i);
        }
    }

    self.setRowIndices();
}

fn getItemFamily(self: DirectoryTree, index: usize) ![]*anyopaque {
    const items = self.list.items.items;
    const item: *TreeItem = @ptrCast(@alignCast(items[index]));

    var fam: std.ArrayList(*anyopaque) = .empty;
    try fam.append(self.alloc, item);

    for (0..items.len) |i| {
        const entry: *TreeItem = @ptrCast(@alignCast(items[i]));
        if (i <= index) continue;
        if (entry.data.level == item.data.level) break;
        try fam.append(self.alloc, entry);
    }

    return try fam.toOwnedSlice(self.alloc);
}

fn getItemFamilySliced(self: DirectoryTree, index: usize) ![]usize {
    const items = self.list.items.items;
    const item: *TreeItem = @ptrCast(@alignCast(items[index]));

    var fam: std.ArrayList(usize) = .empty;
    try fam.append(self.alloc, index);

    for (0..items.len) |i| {
        const entry: *TreeItem = @ptrCast(@alignCast(items[i]));
        if (i <= index) continue;
        if (entry.data.level == item.data.level) break;
        try fam.append(self.alloc, i);
    }

    return try fam.toOwnedSlice(self.alloc);
}

pub fn cmdExpand(self: *DirectoryTree) void {
    self.expandTreeItem(@intCast(self.list.selected_index)) catch return;
    const item = self.list.getItem(@intCast(self.list.selected_index)) orelse return;
    const list_item: *List.Item = @ptrCast(@alignCast(item));
    self.app.config.meta_infos.updateFileInfo(
        list_item.path,
        .is_expanded,
        true,
    ) catch return;
}

pub fn cmdCollapse(self: *DirectoryTree) void {
    self.collapseTreeItem(@intCast(self.list.selected_index)) catch return;
    const item = self.list.getItem(@intCast(self.list.selected_index)) orelse return;
    const list_item: *List.Item = @ptrCast(@alignCast(item));
    self.app.config.meta_infos.updateFileInfo(
        list_item.path,
        .is_expanded,
        false,
    ) catch return;
}

pub fn cmdSelectDir(self: *DirectoryTree) void {
    if (self.list.is_insert) return;
    const selected_dir = self.selectedDir() orelse return;
    self.app.notes_list.getNotes(selected_dir.data.path) catch return;
    self.updateLastDir();
}

/// Updates the `last_directory` entry in the metainfos file.
fn updateLastDir(self: DirectoryTree) void {
    const dir = self.selectedDir() orelse return;
    self.app.config.meta_infos.setValue(.last_directory, dir.data.path) catch return;
    self.app.config.meta_infos.write() catch return;
}

fn deinitItems(self: *DirectoryTree) void {
    for (self.list.items.items) |item| {
        const entry: *TreeItem = @ptrCast(@alignCast(item));
        entry.deinit(self.alloc);
        self.alloc.destroy(entry);
    }
}

pub fn deinit(self: *DirectoryTree) void {
    self.deinitItems();
    self.list.deinit(self.alloc);
    self.alloc.destroy(self.list);
}
