const Editor = @This();

const std = @import("std");
const vx = @import("vaxis");

const App = @import("../App.zig");
const Cell = @import("layout/Cell.zig");
const log = @import("../log.zig");
const TextArea = @import("widgets/TextArea/TextArea.zig");
pub const Buffer = TextArea.Buffer;

const theme = @import("layout/theme.zig");

alloc: std.mem.Allocator,

cell: *Cell,

default_width: u16 = 0,

default_height: u16 = 0,

scroll_view: vx.widgets.ScrollView,

textarea: TextArea,

pub fn init(alloc: std.mem.Allocator) !*Editor {
    const self = try alloc.create(Editor);

    self.* = .{
        .alloc = alloc,
        .cell = try .init(alloc),
        .textarea = try .init(alloc),
        .scroll_view = .{},
    };

    self.cell.setWidth(self.default_width);
    //self.cell.focus();

    return self;
}

pub fn update(self: *Editor, event: App.Event) !void {
    if (self.textarea.numBufs() == 0) {
        return;
    }

    try self.textarea.enableVimMode();

    switch (event) {
        .key_press => |key| {
            try self.textarea.update(.{ .key_press = key });
        },
        else => {},
    }
}

pub fn draw(self: *Editor, win: vx.Window) void {
    var child_win: vx.Window = win.child(self.cell.getChild());
    const gutter_width = 6;
    const top_padding = 0;

    child_win.y_off += top_padding;
    child_win.x_off += gutter_width;
    child_win.width -= gutter_width;
    //child_win.height -= top_padding;

    self.textarea.win = child_win;

    if (self.textarea.numBufs() > 0) {
        self.scroll_view.draw(child_win, .{
            .cols = self.textarea.width,
            .rows = self.textarea.curBuf().numRows(),
        });

        self.textarea.scroll_view = &self.scroll_view;

        const ln: vx.widgets.LineNumbers = .{
            .num_lines = self.textarea.curBuf().numRows() +| 1,
            .style = .{
                .fg = theme.Color.LineNumber.fg,
            },
        };

        ln.draw(win.child(.{
            .x_off = self.cell.offset_x,
            .y_off = self.cell.offset_y + 1,
            .width = gutter_width,
            .height = self.textarea.height,
        }), self.scroll_view.scroll.y);

        self.textarea.draw();
    }
}

pub fn deinit(self: *Editor) void {
    self.alloc.destroy(self.cell);
    self.textarea.deinit();
}
