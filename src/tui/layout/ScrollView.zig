const ScrollView = @This();
const std = @import("std");
const vx = @import("vaxis");

const theme = @import("../layout/theme.zig");

view: vx.widgets.ScrollView,

height: u16,

row: u32 = 0,

default_vbar: vx.widgets.ScrollView.VerticalScrollbar,

line_numbers: ?vx.widgets.LineNumbers = null,

pub fn init(alloc: std.mem.Allocator) !*ScrollView {
    const self = try alloc.create(ScrollView);

    self.* = .{
        .view = .{},
        .height = 0,
        .default_vbar = self.view.vertical_scrollbar.?,
    };

    return self;
}

pub fn setRow(self: *ScrollView, row: i32) void {
    self.row = @intCast(row);
}

/// Repositions the view to the cursor position, ensuring it's always
/// in the viewport.
pub fn reposition(self: *ScrollView) void {
    const min = self.view.scroll.y;
    const max = min + self.height - 1;

    if (self.row < min) {
        self.view.scroll.y -= min - self.row;
    } else if (self.row > max) {
        self.view.scroll.y += self.row - max;
    }
}

const ln_style: vx.Style = .{ .fg = theme.Color.Editor.line_number_fg };
const ln_highlighted_style: vx.Style = .{ .bg = theme.Color.List.selection_bg };

pub fn drawLineNumbers(
    self: *ScrollView,
    win: vx.Window,
    args: struct { gutter_width: u16, x_off: i17, y_off: i17, height: u16 },
) void {
    if (self.line_numbers) |*ln| {
        ln.style = ln_style;
        ln.highlighted_style = ln_highlighted_style;

        ln.draw(win.child(.{
            .x_off = args.x_off,
            .y_off = args.y_off,
            .width = args.gutter_width,
            .height = args.height,
        }), self.view.scroll.y);
    }
}

pub fn showScrollBar(self: *ScrollView) void {
    var vbar = self.view.vertical_scrollbar orelse return;
    vbar.character = .{ .grapheme = self.default_vbar.character.grapheme };
    self.view.vertical_scrollbar = vbar;
}

pub fn hideScrollBar(self: *ScrollView) void {
    var vbar = self.view.vertical_scrollbar orelse return;
    //vbar.bg = .{ .fg = .{ .rgb = .{ 255, 100, 100 } } };
    vbar.character = .{ .grapheme = " " };
    self.view.vertical_scrollbar = vbar;
}
