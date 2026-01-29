const StatusBar = @This();

const std = @import("std");
const vx = @import("vaxis");

const App = @import("../App.zig");
const Cell = @import("layout/Cell.zig");
const utils = @import("../utils.zig");

alloc: std.mem.Allocator,

app: *App,

cell: *Cell,

default_width: u16 = 0,

default_height: u16 = 1,

win: ?vx.Window = null,

//content_cols: [4]*Cell,

general_info_column: *Column,

file_info_column: *Column,

const Column = struct {
    arena: std.heap.ArenaAllocator,

    alloc: std.mem.Allocator,

    cell: *Cell,

    value: std.ArrayList(vx.Cell.Character),

    col: i32 = 0,

    pub fn init(alloc: std.mem.Allocator) !*Column {
        const self = try alloc.create(Column);

        self.* = .{
            .arena = .init(alloc),
            .alloc = self.arena.allocator(),
            .value = .empty,
            .col = 0,
            .cell = try .init(self.alloc),
        };

        return self;
    }

    pub fn insertSliceAtCursor(self: *Column, slice: []const u8) !void {
        try self.value.insert(self.alloc, @intCast(self.col), .{
            .grapheme = slice,
            .width = 1,
        });
        self.col += 1;
    }

    /// Removes the last character
    pub fn deleteCharBefore(self: *Column) void {
        if (self.col > 0) {
            _ = self.value.orderedRemove(@intCast(self.col - 1));
            self.value.shrinkAndFree(self.alloc, self.value.items.len);
            self.col -= 1;
        }
    }

    pub fn setValue(self: *Column, win: vx.Window, str: []const u8) !void {
        const str_cpy = try self.alloc.dupe(u8, str);
        var cmd_iter = vx.unicode.graphemeIterator(str_cpy);
        while (cmd_iter.next()) |grapheme| {
            const g = grapheme.bytes(str_cpy);
            const w: u8 = @intCast(win.gwidth(g));
            try self.value.append(self.alloc, .{ .grapheme = g, .width = w });
        }
    }

    pub fn getValue(self: Column) []vx.Cell.Character {
        return self.value.items;
    }

    pub fn getValueStr(self: Column) ![]const u8 {
        var val: std.ArrayList(u8) = .empty;
        for (self.getValue()) |char| {
            try val.appendSlice(self.alloc, char.grapheme);
        }
        return try val.toOwnedSlice(self.alloc);
    }

    pub fn clear(self: *Column) void {
        self.value.shrinkAndFree(self.alloc, 0);
        self.value = .empty;
        self.col = 0;
    }

    pub fn deinit(self: *Column) void {
        self.arena.deinit();
    }
};

pub fn init(alloc: std.mem.Allocator, title: []const u8, app: *App) !*StatusBar {
    const self = try alloc.create(StatusBar);

    self.* = .{
        .alloc = alloc,
        .app = app,
        .cell = try .init(alloc),
        .general_info_column = try .init(alloc),
        .file_info_column = try .init(alloc),
    };

    self.cell.setHeight(self.default_height);
    self.cell.title = title;
    self.general_info_column.cell.setOffsetX(self.cell.offset_x);

    return self;
}

pub fn update(self: *StatusBar, event: App.Event) !void {
    if (!self.cell.isFocused()) {
        return;
    }

    switch (event) {
        .key_press => |key| {
            if (key.matches(vx.Key.enter, .{})) {
                const val = try self.general_info_column.getValueStr();

                if (utils.strEql(val, "q")) {
                    return try self.app.quit();
                }

                if (utils.strEql(val, "w")) {
                    return try self.write();
                }
            }
            if (key.text) |text| {
                try self.general_info_column.insertSliceAtCursor(text);
            }
        },
        else => {},
    }
}

pub fn draw(self: *StatusBar, win: vx.Window) !void {
    var child_opts: vx.Window.ChildOptions = self.cell.getChild();
    child_opts.border = .{};
    const child_win = win.child(child_opts);

    if (self.win == null) {
        self.win = child_win;
    }

    // Use an arena for string manipulations for each draw
    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();

    {
        var content: []const u8 = "";
        if (self.shouldShowMode()) {
            if (self.app.mode != .command) {
                self.general_info_column.clear();
            }
            content = try self.getModeStr(arena.allocator());
        }
        try self.drawGeneralInfoCol(child_win, content);
    }

    {
        try self.drawFileInfoCol(child_win);
    }
}

fn drawGeneralInfoCol(self: *StatusBar, win: vx.Window, content: []const u8) !void {
    var col: u16 = 1;
    var col_opts = self.general_info_column.cell.getChild();
    // Reset border
    col_opts.border = .{};
    const child_win = win.child(col_opts);

    // Display current mode
    Cell.write(child_win, &col, 0, content, .{});

    // Display user input prompt
    for (self.general_info_column.value.items) |*char| {
        Cell.write(child_win, &col, 0, char.grapheme, .{});
    }

    if (self.cell.isFocused()) {
        child_win.showCursor(col, 0);
    }
}

fn drawFileInfoCol(self: *StatusBar, win: vx.Window) !void {
    _ = self;
    _ = win;
}

/// Tells the textarea to save the buffer and prints a success message
/// in the statusbar
fn write(self: *StatusBar) !void {
    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    const editor = self.app.editor;
    const buf = editor.textarea.curBuf();
    const rel_path = try editor.getRelativeBufPath(alloc);
    const bytes = try editor.textarea.writeBuf();
    self.app.cancelAction();

    var print_buf: [256]u8 = undefined;
    const str = try std.fmt.bufPrint(&print_buf, "{}", .{bytes});
    // horribly build the success message
    const success: []const u8 = try std.mem.concat(alloc, u8, &[_][]const u8{
        "\"",
        rel_path[1..],
        std.fs.path.sep_str,
        buf.getName(),
        "\", ",
        str,
        "B written",
    });

    if (self.win) |win| {
        try self.general_info_column.setValue(win, success);
    }
}

fn shouldShowMode(self: StatusBar) bool {
    return self.app.mode == .insert or
        self.app.mode == .command or
        //self.app.mode == .search or
        //self.app.mode == .search_prompt or
        self.app.mode == .replace or
        self.app.mode == .visual or
        self.app.mode == .visual_line or
        self.app.mode == .visual_block;
}

fn getModeStr(self: StatusBar, alloc: std.mem.Allocator) ![]const u8 {
    var mode = self.app.mode;
    var mode_str: []const u8 = mode.str();
    const buf: []u8 = try alloc.alloc(u8, mode_str.len);
    defer alloc.free(buf);

    mode_str = std.ascii.upperString(buf, mode_str);
    if (mode != .command) {
        mode_str = try std.mem.concat(alloc, u8, &[_][]const u8{
            "-- ", mode_str, " --",
        });
    }
    defer alloc.free(mode_str);

    const s = try alloc.dupe(u8, mode_str);
    return s;
}

pub fn reset(self: *StatusBar) void {
    self.app.mode = .normal;
    self.general_info_column.clear();
}

pub fn focus(self: *StatusBar) void {
    self.app.mode = .command;
    self.general_info_column.clear();
    self.cell.focus();
}

pub fn blur(self: *StatusBar) void {
    self.reset();
    self.cell.blur();
}

pub fn deinit(self: *StatusBar) void {
    //for (0..self.content_cols.len) |i| {
    //    self.alloc.destroy(self.content_cols[i]);
    //}
    self.general_info_column.deinit();
    self.alloc.destroy(self.general_info_column);
    self.file_info_column.deinit();
    self.alloc.destroy(self.file_info_column);
    self.alloc.destroy(self.cell);
}
