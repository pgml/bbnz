const Editor = @This();

const std = @import("std");
const vx = @import("vaxis");

const App = @import("../App.zig");
const Config = App.Config;

const Cell = @import("layout/Cell.zig");
const ScrollView = @import("layout/ScrollView.zig");
const log = @import("../log.zig");
pub const TextArea = @import("widgets/TextArea/TextArea.zig");
pub const Buffer = TextArea.Buffer;
const utils = @import("../utils.zig");

const theme = @import("layout/theme.zig");

alloc: std.mem.Allocator,

app: *App,

name: []const u8,

cell: *Cell,

default_width: u16 = 0,

default_height: u16 = 0,

scroll_view: *ScrollView,

textarea: TextArea,

// in ms - delay for going from visual mode to normal mode after
// yanking stuff
def_delay: u64 = 100,

pub fn init(alloc: std.mem.Allocator, title: []const u8, app: *App) !*Editor {
    const self = try alloc.create(Editor);

    self.* = .{
        .alloc = alloc,
        .app = app,
        .name = title,
        .cell = try .init(alloc),
        .textarea = try .init(alloc, app, self),
        .scroll_view = try .init(self.alloc),
    };

    self.cell.setWidth(self.default_width);
    self.cell.title = try self.alloc.dupe(u8, title);

    return self;
}

pub fn update(self: *Editor, event: App.Event) !void {
    if (!self.cell.isFocused() or self.textarea.numBufs() == 0) {
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
    // hide the editor cursor and reset the breadcrumb if no buffers are open.
    if (self.textarea.numBufs() == 0) {
        if (!std.mem.eql(u8, self.cell.title, self.name)) {
            self.cell.title = self.alloc.dupe(u8, self.name) catch return;
        }
        win.hideCursor();
    }

    var child_win: vx.Window = win.child(self.cell.getChild());
    const gutter_width = 6;
    const top_padding = 0;

    child_win.y_off += top_padding;
    child_win.x_off += gutter_width;
    child_win.width -= gutter_width;
    //child_win.height -= top_padding;

    self.textarea.win = child_win;
    self.textarea.is_focucsed = self.cell.isFocused();

    if (self.textarea.hasBuffers()) {
        const buf: *Buffer = self.textarea.curBuf();
        self.scroll_view.view.draw(child_win, .{
            .cols = self.textarea.width,
            .rows = buf.numRows(),
        });

        // dim scrollbar if an overlay is open
        if (self.scroll_view.view.vertical_scrollbar) |*vbar| {
            vbar.fg.dim = self.app.isAnyOverlayOpen();
        }

        self.scroll_view.height = self.textarea.height;
        self.textarea.scroll_view = self.scroll_view;

        const ln: vx.widgets.LineNumbers = .{
            .num_lines = buf.numRows() +| 1,
            .style = .{
                .fg = theme.Color.Editor.line_number_fg,
                .dim = self.app.isAnyOverlayOpen(),
            },
        };

        ln.draw(win.child(.{
            .x_off = self.cell.offset_x,
            .y_off = self.cell.offset_y + 1,
            .width = gutter_width,
            .height = self.textarea.height,
        }), self.scroll_view.view.scroll.y);

        self.textarea.draw() catch return;
    }
}

pub inline fn drawHeader(self: *Editor, win: vx.Window) !void {
    const col: u16 = @intCast(self.cell.offset_x + 1);
    Cell.drawHeader(win, self.cell.title, col, 0, .{
        .is_focused = self.cell.isFocused(),
    });
}

pub fn restore(self: *Editor) !void {
    const meta = self.app.config.meta_infos;
    if (utils.strEql(meta.last_open_note, "")) {
        return;
    }

    // open all notes of the last session
    for (meta.last_notes.items) |note| {
        try self.openBuf(note, false);
        if (meta.files_info.get(note)) |file_info| {
            const curpos = file_info.cursor_pos;
            self.textarea.moveCursorTo(@intCast(curpos.row), @intCast(curpos.col));
        }
    }

    // switch to the note that was opened in the editor.
    try self.openBuf(meta.last_open_note, false);
}

/// Opens a buffer with the given `path`.
/// if `save_to_conf` is true it saves this specific note to the
/// meta info config file.
pub fn openBuf(self: *Editor, path: []const u8, save_to_conf: bool) !void {
    try self.textarea.openBuf(path);

    if (self.textarea.scroll_view) |view| {
        view.setRow(self.textarea.curBuf().row);
        view.reposition();
    }

    try self.setBreadCrumb(self.textarea.curBuf());

    const note_path = self.textarea.curBuf().path;
    if (save_to_conf) {
        try self.app.config.meta_infos.setValue(.last_open_note, note_path);
    }

    try self.app.config.meta_infos.setValue(.last_notes, note_path);
    try self.app.config.meta_infos.write();
}

// Remove the root notes directory from the absolute buffer path.
// If `no_file` is true the filename gets removed.
pub fn getRelativeBufPath(self: Editor, no_file: bool) []const u8 {
    if (self.textarea.hasBuffers()) {
        const buf: *Buffer = self.textarea.curBuf();
        const notes_root = self.app.config.getNotesRootDir() catch return "";

        if (!std.mem.startsWith(u8, buf.path, notes_root)) {
            return "";
        }

        var rel_path = buf.path[notes_root.len..];

        if (no_file) {
            if (std.fs.path.dirname(buf.path)) |dir_name| {
                const len = dir_name.len - notes_root.len;
                const p: []u8 = @constCast(rel_path);
                _ = std.mem.replace(u8, dir_name, notes_root, "", p);
                return rel_path[0..len];
            }
        }

        return rel_path;
    }
    return "";
}

pub fn setBreadCrumb(self: Editor, buf: ?*Buffer) !void {
    self.alloc.free(self.cell.title);
    var bc_buf: [256]u8 = undefined;
    const breadcrumb = try self.app.editor.buildBreadCrumb(&bc_buf, buf);
    self.cell.title = try self.alloc.dupe(u8, breadcrumb);
}

pub fn buildBreadCrumb(self: Editor, out: []u8, buffer: ?*Buffer) ![]const u8 {
    if (!self.textarea.hasBuffers()) {
        return "";
    }

    const buf: *Buffer = buffer orelse self.textarea.curBuf();
    const rel_path = self.getRelativeBufPath(true);

    if (rel_path.len == 0) {
        return "";
    }

    const separator = " › ";

    var tmp_buf: [256]u8 = undefined;
    const replacements = std.mem.replace(u8, rel_path, "/", separator, tmp_buf[0..]);
    const len = rel_path.len + (replacements * (separator.len - 1));

    return try std.fmt.bufPrint(out, "{s}{s}{s}{s} {s}", .{
        theme.Icon.getNerd(.dir_closed),
        tmp_buf[0..len],
        separator,
        theme.Icon.getNerd(.note),
        buf.getName(),
    });
}

pub fn focus(self: *Editor) void {
    self.cell.focus();
}

pub fn blur(self: *Editor) void {
    self.cell.blur();
}

pub fn setFocus(self: *Editor, f: bool) void {
    self.cell.setFocus(f);
}

pub fn deinit(self: *Editor) void {
    self.alloc.free(self.cell.title);
    self.alloc.destroy(self.cell);
    self.alloc.destroy(self.scroll_view);
    self.textarea.deinit();
}
