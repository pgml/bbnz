const DirectoryTree = @This();

const std = @import("std");
const vx = @import("vaxis");

const App = @import("../App.zig");
const Cell = @import("layout/Cell.zig");
const Config = @import("../Config.zig");
const fs = @import("../fs.zig");
const ListItem = @import("ListItem.zig");
const utils = @import("../utils.zig");

alloc: std.mem.Allocator,

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

const TreeItem = struct {
    /// General list data
    data: ListItem,

    dir_entry: fs.DirEntry = .{},

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
        alloc.free(self.data.name);
        alloc.free(self.data.path);
        self.children.deinit(alloc);
        self.cell.deinit();
    }
};

pub fn init(alloc: std.mem.Allocator) !*DirectoryTree {
    const self = try alloc.create(DirectoryTree);

    self.* = .{
        .alloc = alloc,
        .cell = try .init(alloc),
        .scroll_view = .{},
    };

    self.cell.setWidth(self.default_width);
    self.cell.focus();

    return self;
}

pub fn update(self: *DirectoryTree, event: App.Event) !void {
    if (self.tree_items.items.len == 0) {
        try self.buildTreeItems();
    }

    switch (event) {
        .key_press => |key| {
            switch (key.codepoint) {
                'j' => self.selected_index += 1,
                'k' => self.selected_index -= 1,
                'l' => try self.expandDirItem(@intCast(self.selected_index)),
                'h' => try self.collapseTreeItem(@intCast(self.selected_index)),
                else => {},
            }
        },
        else => {},
    }

    self.selected_index = std.math.clamp(
        self.selected_index,
        0,
        self.tree_items.items.len - 1,
    );
}

pub fn draw(self: *DirectoryTree, win: vx.Window) !void {
    const opts = self.cell.getChild();
    const child_win = win.child(opts);

    var index: isize = 0;
    for (self.tree_items.items) |item| {
        item.cell.setHeight(self.default_item_height);
        var child_opts = item.cell.getChild();
        // reset border for each tree item
        child_opts.border = .{};

        _ = child_win.child(child_opts);

        var style: vx.Cell.Style = .{};
        if (index == self.selected_index) {
            style.bg = .{ .rgb = .{ 66, 75, 93 } };
        }

        const row: u16 = @intCast(index + item.cell.height - 1);
        writeLine(child_win, item, row, self.cell.width, style);
        index += 1;
        item.data.index = @intCast(index);
    }
}

fn writeLine(win: vx.Window, item: *TreeItem, row: u16, width: u16, style: vx.Cell.Style) void {
    var iter = vx.unicode.graphemeIterator(item.data.name);
    var col: u16 = 0;
    var text_width: u16 = 0;
    const pad_left = 1;

    win.writeCell(col, row, .{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = style,
    });
    col += 1;

    for (1..pad_left + item.level) |_| {
        win.writeCell(col, row, .{
            .char = .{ .grapheme = "  ", .width = 2 },
            .style = style,
        });
        col += 2;
    }

    while (iter.next()) |grapheme| {
        const g = grapheme.bytes(item.data.name);
        const w: u8 = @intCast(win.gwidth(g));

        win.writeCell(col, row, .{
            .char = .{ .grapheme = g, .width = w },
            .style = style,
        });

        text_width += w;

        col += 1;
    }

    const pad_right: u16 = @intCast(width - text_width - pad_left);
    for (0..pad_right) |_| {
        win.writeCell(col, row, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = style,
        });
        col += 1;
    }
}

/// Builds the initial directory tree from the notes root directory
fn buildTreeItems(self: *DirectoryTree) !void {
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const notes_root = try Config.getNotesRootDir();
    const tmp_dir_entries = try fs.readDir(arena.allocator(), notes_root);

    for (tmp_dir_entries) |entry| {
        const dir_item = try self.createDirItem(entry, 0, 0);
        try self.tree_items.append(self.alloc, dir_item);
    }
}

fn expandDirItem(self: *DirectoryTree, index: usize) !void {
    if (index >= self.tree_items.items.len) {
        return;
    }

    var tree_item: *TreeItem = self.getTreeItem(index);
    const level = tree_item.level;

    if (tree_item.is_expanded) {
        return;
    }

    tree_item.is_expanded = true;

    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    // @todo: dont read the directory everytime we expand
    const tmp_dir_entry = try fs.readDir(arena.allocator(), tree_item.data.path);

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
    if (index >= self.tree_items.items.len) {
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
    item: fs.DirEntry,
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

fn selectedDir(self: DirectoryTree) *TreeItem {
    return self.getTreeItem(self.selected_index);
}

pub fn deinit(self: *DirectoryTree) void {
    for (self.tree_items.items) |entry| {
        entry.deinit(self.alloc);
        self.alloc.destroy(entry);
    }

    self.tree_items.deinit(self.alloc);
    self.alloc.destroy(self.cell);
}
