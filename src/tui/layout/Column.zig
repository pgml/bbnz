const Column = @This();

const std = @import("std");
const vx = @import("vaxis");

const theme = @import("theme.zig");

alloc: std.mem.Allocator,

width: u16,

height: u16,

offset_x: i17,

offset_y: i17,

is_focused: bool,

pub fn init(alloc: std.mem.Allocator) !*Column {
    const self = try alloc.create(Column);

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

pub fn setWidth(self: *Column, width: u16) void {
    self.width = width;
}

pub fn setHeight(self: *Column, height: u16) void {
    self.height = height;
}

pub fn setOffsetX(self: *Column, x: i17) void {
    self.offset_x = x;
}

pub fn setOffsetY(self: *Column, y: i17) void {
    self.offset_y = y;
}

pub fn isFocused(self: Column) bool {
    return self.is_focused;
}

pub fn focus(self: *Column) void {
    self.is_focused = true;
}

pub fn blur(self: *Column) void {
    self.is_focused = false;
}

pub fn getChild(self: Column) vx.Window.ChildOptions {
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

fn borderOpts(self: Column) vx.Window.BorderOptions {
    const color: vx.Color = if (self.isFocused())
        theme.Color.Border.fg_focused
    else
        theme.Color.Border.fg;

    return .{
        .where = .{ .other = .{ .left = true, .bottom = true, .top = true } },
        .glyphs = .single_square,
        .style = .{ .fg = color },
    };
}

pub fn deinit(self: *Column) void {
    self.alloc.destroy(self);
}
