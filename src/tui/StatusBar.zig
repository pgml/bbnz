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

colums: std.AutoHashMap(ColumnPos, *Column),

pub const ColumnPos = enum {
    general,
    info,
    key_info,
    file_info,
};

pub const Column = struct {
    arena: std.heap.ArenaAllocator,

    alloc: std.mem.Allocator,

    cell: *Cell,

    value: std.ArrayList(vx.Cell.Character),

    col: i16 = 0,

    pub fn init(alloc: std.mem.Allocator) !*Column {
        const self = try alloc.create(Column);

        self.* = .{
            .arena = .init(alloc),
            .alloc = self.arena.allocator(),
            .value = .empty,
            .cell = try .init(self.alloc),
        };

        return self;
    }

    fn getCol(self: *Column) i16 {
        self.col = @intCast(std.math.clamp(self.col, 0, self.value.items.len));
        return self.col;
    }

    pub fn insertSliceAtCursor(self: *Column, slice: []const u8) !void {
        try self.value.insert(self.alloc, @intCast(self.getCol()), .{
            .grapheme = slice,
            .width = 1,
        });
        self.col += 1;
    }

    /// Removes the last character
    pub fn deleteCharBefore(self: *Column) void {
        if (self.getCol() > 0) {
            _ = self.value.orderedRemove(@intCast(self.getCol() - 1));
            self.value.shrinkAndFree(self.alloc, self.value.items.len);
            self.col -= 1;
        }
    }

    pub fn setValue(self: *Column, win: vx.Window, str: []const u8) !void {
        var cmd_iter = vx.unicode.graphemeIterator(str);
        while (cmd_iter.next()) |grapheme| {
            const g = grapheme.bytes(str);
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

    pub fn draw(self: *Column, win: vx.Window, content: []const u8) u16 {
        var col: u16 = 1;
        var col_opts = self.cell.getChild();

        // Reset border
        col_opts.border = .{};
        const child_win = win.child(col_opts);

        // Display current mode
        Cell.write(child_win, &col, 0, content, .{});

        // Display user input prompt
        for (self.value.items) |char| {
            Cell.write(child_win, &col, 0, char.grapheme, .{});
        }

        self.col = @intCast(col);
        return col;
    }

    pub fn clear(self: *Column) void {
        self.value.shrinkAndFree(self.alloc, 0);
        self.value = .empty;
        self.col = 0;
    }

    pub fn deinit(self: *Column) void {
        self.alloc.destroy(self.cell);
        self.clear();
        self.arena.deinit();
    }
};

pub fn init(alloc: std.mem.Allocator, title: []const u8, app: *App) !*StatusBar {
    const self = try alloc.create(StatusBar);

    self.* = .{
        .alloc = alloc,
        .app = app,
        .cell = try .init(self.alloc),
        .colums = .init(self.alloc),
    };

    self.cell.setHeight(self.default_height);
    self.cell.title = title;

    try self.setupColumns();

    return self;
}

pub fn update(self: *StatusBar, event: App.Event) !void {
    switch (event) {
        .key_press => |key| {
            if (!self.cell.isFocused()) {
                return;
            }

            if (key.matches(vx.Key.enter, .{})) {
                if (self.colums.getEntry(.general)) |entry| {
                    const col = entry.value_ptr.*;
                    const val = try col.getValueStr();

                    if (utils.strEql(val, "q")) {
                        return try self.app.quit();
                    }

                    if (utils.strEql(val, "w")) {
                        return try self.write();
                    }
                }
            }

            if (key.text) |text| {
                if (self.colums.getEntry(.general)) |entry| {
                    const col = entry.value_ptr.*;
                    try col.insertSliceAtCursor(text);
                }
            }
        },
        .update_statusbar => |cnt| {
            const win = self.win orelse return;
            const entry = self.colums.getEntry(cnt.col) orelse return;
            entry.value_ptr.*.clear();
            try entry.value_ptr.*.setValue(win, cnt.text);
        },
        .winsize => |ws| {
            var gen_col_w: u16 = 0;
            if (self.colums.getEntry(.general)) |col| {
                const w = ws.cols - 50;
                col.value_ptr.*.cell.setWidth(w);
                gen_col_w = w;
            }

            var key_col_w: u16 = 0;
            if (self.colums.getEntry(.key_info)) |col| {
                const w = ws.cols - 50;
                key_col_w = w;
                col.value_ptr.*.cell.setOffsetX(gen_col_w);
            }

            if (self.colums.getEntry(.file_info)) |col| {
                col.value_ptr.*.cell.setOffsetX(ws.cols - 20);
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

    var col_iter = self.colums.iterator();
    while (col_iter.next()) |entry| {
        var content: []const u8 = "";
        const col_pos = entry.key_ptr.*;
        const column = entry.value_ptr.*;

        if (col_pos == .general and self.shouldShowMode()) {
            if (self.app.mode != .command) {
                column.clear();
            }
            content = try self.getModeStr(arena.allocator());
        }

        const col = column.draw(child_win, content);

        if (self.cell.isFocused() and col_pos == .general) {
            child_win.showCursor(col, 0);
        }
    }
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

    try self.setColumnContent(.general, success);
    try self.setColumnContent(.file_info, success);
}

pub fn setupColumns(self: *StatusBar) !void {
    try self.colums.put(.general, try .init(self.alloc));

    var col_key_info: *Column = try .init(self.alloc);
    col_key_info.cell.setWidth(15);
    col_key_info.position = .key_info;
    try self.colums.put(.key_info, col_key_info);

    var col_file_info: *Column = try .init(self.alloc);
    col_file_info.cell.setWidth(15);
    col_file_info.position = .file_info;
    try self.colums.put(.file_info, col_file_info);
}

pub fn setColumnContent(
    self: *StatusBar,
    column: ColumnPos,
    text: []const u8,
) !void {
    self.app.loop.postEvent(.{ .update_statusbar = .{
        .col = column,
        .text = text,
    } });
}

pub fn clearColumn(self: *StatusBar, column: ColumnPos) !void {
    self.app.loop.postEvent(.{ .update_statusbar = .{
        .col = column,
        .text = "",
    } });
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
    if (self.colums.getEntry(.general)) |entry| {
        entry.value_ptr.*.clear();
    }
}

pub fn focus(self: *StatusBar) void {
    self.app.mode = .command;
    if (self.colums.getEntry(.general)) |entry| {
        entry.value_ptr.*.clear();
    }
    self.cell.focus();
}

pub fn blur(self: *StatusBar) void {
    self.reset();
    self.cell.blur();
}

pub fn deinit(self: *StatusBar) void {
    var col_iter = self.colums.iterator();
    while (col_iter.next()) |entry| {
        entry.value_ptr.*.deinit();
        self.alloc.destroy(entry.value_ptr.*);
    }
    self.colums.deinit();
    self.alloc.destroy(self.cell);
}
