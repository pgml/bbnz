//! Cell represents not a terminal cell but a layout cell such as the
//! editor, directory tree, status bar columns or a row of a list view.
const Cell = @This();

const std = @import("std");
const vx = @import("vaxis");

const theme = @import("theme.zig");

alloc: std.mem.Allocator,

width: u16,

height: u16,

offset_x: i17,

offset_y: i17,

is_focused: bool,

pub fn init(alloc: std.mem.Allocator) !*Cell {
    const self = try alloc.create(Cell);

    self.* = .{
        .alloc = alloc,
        .width = 0,
        .height = 0,
        .offset_x = 0,
        .offset_y = 0,
        .is_focused = false,
    };

    return self;
}

pub fn setWidth(self: *Cell, width: u16) void {
    self.width = width;
}

pub fn setHeight(self: *Cell, height: u16) void {
    self.height = height;
}

pub fn setOffsetX(self: *Cell, x: i17) void {
    self.offset_x = x;
}

pub fn setOffsetY(self: *Cell, y: i17) void {
    self.offset_y = y;
}

pub fn isFocused(self: Cell) bool {
    return self.is_focused;
}

pub fn focus(self: *Cell) void {
    self.is_focused = true;
}

pub fn blur(self: *Cell) void {
    self.is_focused = false;
}

pub fn setFocus(self: *Cell, f: bool) void {
    if (self.is_focused == f) {
        return;
    }

    if (f) {
        self.focus();
    } else {
        self.blur();
    }
}

pub fn getChild(self: Cell) vx.Window.ChildOptions {
    var win: vx.Window.ChildOptions = .{
        .x_off = self.offset_x,
        .y_off = self.offset_y,
        .border = self.borderOpts(),
    };

    if (self.width > 0) {
        win.width = self.width;
    }

    if (self.height > 0) {
        win.height = self.height;
    }

    return win;
}

fn borderOpts(self: Cell) vx.Window.BorderOptions {
    const color: vx.Color = if (self.isFocused())
        theme.Color.Border.fg_focused
    else
        theme.Color.Border.fg;

    return .{
        .where = .all,
        .glyphs = .single_square,
        .style = .{ .fg = color },
    };
}

pub fn get(grapheme: []const u8, width: u8, style: vx.Style) vx.Cell {
    return .{
        .char = .{ .grapheme = grapheme, .width = width },
        .style = style,
    };
}

pub fn write(win: vx.Window, col: *u16, row: u16, cell: vx.Cell) void {
    win.writeCell(col.*, row, cell);
    col.* += @intCast(cell.char.width);
}
