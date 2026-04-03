const App = @This();

const std = @import("std");
const vaxis = @import("vaxis");

pub const Config = @import("Config.zig");
pub const Input = @import("Input.zig");
pub const deferred = @import("deferred.zig");
const log = @import("log.zig");

const tui = @import("tui/tui.zig");
const BufferList = tui.BufferList;
const DirectoryTree = tui.DirectoryTree;
pub const Editor = tui.Editor;
const NotesList = tui.NotesList;
const StatusBar = tui.StatusBar;

pub const name = "Bellbird Notes";

alloc: std.mem.Allocator,

config: *Config,

input: *Input,

should_quit: bool,

tty: vaxis.tty.PosixTty,

vx: vaxis.Vaxis,

notes_list: *NotesList,

directory_tree: *DirectoryTree,

buffer_list: *BufferList,

editor: *Editor,

status_bar: *StatusBar,

current_column: Column = .directory_tree,

last_column: Column = .directory_tree,

mode: Editor.TextArea.Vim.Mode = .normal,

win: ?vaxis.Window = null,

loop: vaxis.Loop(Event) = undefined,

curevent: Event = undefined,

/// Special events that should asynchronously execute after a certain delay.
event_queue: ?deferred.Queue = null,

/// Events other then the default vaxis events that are executed after the
/// main loop unlocks.
custom_events: std.ArrayList(Event) = .empty,

/// Whether the main loop should be rerendered.
redraw_ui: bool = false,

/// Cache notes root directory for convenience.
notes_root: []const u8 = "",

pub const Column = enum {
    status_bar,
    directory_tree,
    notes_list,
    editor,
    buffer_list,
};

pub const Event = union(enum) {
    key_press: vaxis.Key,
    key_release: vaxis.Key,
    winsize: vaxis.Winsize,
    update_statusbar: struct {
        col: StatusBar.ColumnPos,
        text: []const u8,
    },
};

pub fn init(alloc: std.mem.Allocator, args_map: std.StringHashMap(?[]const u8)) !App {
    var buffer: [1024]u8 = undefined;

    var self: App = .{
        .alloc = alloc,
        .config = try .init(alloc),
        .input = try .init(alloc),
        .tty = try vaxis.Tty.init(&buffer),
        .vx = try vaxis.init(alloc, .{}),
        .should_quit = false,
        .buffer_list = undefined,
        .notes_list = undefined,
        .directory_tree = undefined,
        .editor = undefined,
        .status_bar = undefined,
    };

    self.resolveArgs(args_map);

    return self;
}

pub fn run(self: *App) !void {
    const writer: *std.Io.Writer = self.tty.writer();

    self.loop = .{
        .vaxis = &self.vx,
        .tty = &self.tty,
    };
    try self.loop.init();
    try self.loop.start();
    defer self.loop.stop();

    if (!self.config.@"no-alt") {
        try self.vx.enterAltScreen(writer);
    }

    self.buffer_list = try .init(self.alloc, "BufferList", self);
    self.directory_tree = try .init(self.alloc, "Folders", self);
    self.notes_list = try .init(self.alloc, "Notes", self);
    self.editor = try .init(self.alloc, "Editor", self);
    self.status_bar = try .init(self.alloc, "StatusBar", self);

    try writer.flush();
    try self.vx.queryTerminal(self.tty.writer(), 1 * std.time.ns_per_s);

    self.input.app = self;
    self.notes_root = try self.alloc.dupe(u8, try self.config.getNotesRootDir());
    try self.restoreState();

    self.event_queue = .init(self.alloc);

    while (!self.should_quit) {
        self.redraw_ui = false;

        if (self.event_queue) |*scheduler| {
            try scheduler.run();
        }

        {
            self.loop.queue.lock();
            defer self.loop.queue.unlock();
            while (self.loop.queue.drain()) |event| {
                self.curevent = event;
                try self.update(event);
                try self.draw();
                self.redraw_ui = true;
            }
        }

        // run all custom events after the vaxis events.
        for (self.custom_events.items) |event| {
            _ = self.loop.tryPostEvent(event);
        }
        self.custom_events.clearAndFree(self.alloc);

        if (self.redraw_ui) {
            try self.vx.render(writer);
            try writer.flush();
            self.redraw_ui = false;
        }
    }
}

pub fn update(self: *App, event: Event) !void {
    try self.buffer_list.update(event);
    try self.directory_tree.update(event);
    try self.notes_list.update(event);
    try self.editor.update(event);
    try self.status_bar.update(event);

    switch (event) {
        .key_press => |key| {
            try self.input.handleSeq(key);
        },
        .winsize => |ws| {
            try self.vx.resize(self.alloc, self.tty.writer(), ws);
        },
        else => {},
    }
}

pub fn draw(self: *App) !void {
    var win: vaxis.Window = self.vx.window();
    win.clear();
    self.win = win;

    try self.initComponents();

    try self.directory_tree.draw(win);
    self.directory_tree.list.drawHeader(win, 1, 0, .{});

    try self.notes_list.draw(win);
    self.notes_list.drawHeader(win);

    self.editor.draw(win);
    try self.editor.drawHeader(win);

    try self.status_bar.draw(win);

    if (self.buffer_list.list.isFocused()) {
        // This has to be called after everything else to make the list appear
        // on top of the other components.
        try self.buffer_list.draw(win);
        self.buffer_list.list.drawHeader(
            win,
            self.buffer_list.default_x_off + 1,
            self.buffer_list.default_y_off,
            .{
                .bold = true,
                .color_title = true,
            },
        );
    }
}

pub fn redrawUIHook(ctx: *anyopaque) void {
    var app: *App = @ptrCast(@alignCast(ctx));
    app.draw() catch return;
    app.redraw_ui = true;
}

fn restoreState(self: *App) !void {
    try self.config.loadMetaInfo();
    try self.directory_tree.restore();
    try self.notes_list.restore();
    try self.editor.restore();
    //self.focusColumn(@intCast(self.config.meta_infos.current_column));
    self.focusColumn(@enumFromInt(self.config.meta_infos.current_column));
}

/// prepares all components for rendering, sets dimensions and offsets...
inline fn initComponents(self: *App) !void {
    const win = self.win orelse return;
    const sb_height = self.status_bar.cell.height;

    self.buffer_list.list.setOffsetX(self.buffer_list.default_x_off);
    self.buffer_list.list.setOffsetY(self.buffer_list.default_y_off);

    self.directory_tree.list.setHeight(win.height - sb_height);
    self.directory_tree.list.setOffsetY(0);

    self.notes_list.list.setHeight(win.height - sb_height);
    self.notes_list.list.setOffsetX(self.directory_tree.list.getWidth());
    self.notes_list.list.setOffsetY(0);

    const xoff = self.notes_list.list.getWidth() + self.directory_tree.list.getWidth();
    self.editor.cell.setHeight(win.height - sb_height);
    self.editor.cell.setOffsetX(xoff);
    self.editor.cell.setOffsetY(0);

    self.status_bar.cell.setOffsetY(self.editor.cell.height);
}

pub fn focusColumn(self: *App, col: Column) void {
    self.last_column = self.current_column;
    self.directory_tree.list.setFocus(col == .directory_tree);
    self.notes_list.list.setFocus(col == .notes_list);
    self.editor.setFocus(col == .editor);
    self.buffer_list.list.setFocus(col == .buffer_list);
    self.current_column = col;
}

/// Selects and highlights the respectivley next of the
/// currently selected column.
pub fn focusNextColumn(self: *App, cycle: bool) void {
    const num_cols = 3;
    var cur_col = @intFromEnum(self.current_column);

    // Get to the first column if cycling is enabled and we're either
    // currently focusing the editor or notes list with no open buffers
    if ((cycle and cur_col == num_cols) or
        (cycle and cur_col == 2 and self.editor.textarea.numBufs() == 0))
    {
        cur_col = 0;
    }

    const index = @min(cur_col + 1, num_cols);
    return self.focusColumn(@enumFromInt(index));
}

/// Selects and highlights the respectivley previous of the
/// currently selected column.
pub fn focusPrevColumn(self: *App, cycle: bool) void {
    const first_col = 1;
    var cur_col = @intFromEnum(self.current_column);

    if (cycle and cur_col == 1) {
        // go to the editor or the notes list depending on whether
        // the editor has buffers
        if (self.editor.textarea.numBufs() == 0) {
            cur_col = 3;
        } else {
            cur_col = 4;
        }
    }

    const column = @max(cur_col - 1, first_col);
    return self.focusColumn(@enumFromInt(column));
}

pub fn focusedColumnName(self: App) []const u8 {
    return switch (self.current_column) {
        .status_bar => self.status_bar.cell.title,
        .directory_tree => self.directory_tree.list.name,
        .notes_list => self.notes_list.list.name,
        .editor => self.editor.name,
        .buffer_list => self.buffer_list.list.name,
    };
}

pub fn cmdNextCol(self: *App) void {
    self.focusNextColumn(true);
    self.saveColToConf() catch return;
}

pub fn cmdPrevCol(self: *App) void {
    self.focusPrevColumn(true);
    self.saveColToConf() catch return;
}

fn saveColToConf(self: *App) !void {
    self.config.meta_infos.current_column = @intFromEnum(self.current_column);
    try self.config.meta_infos.setValue(
        .current_column,
        self.current_column,
    );
    try self.config.meta_infos.write();
}

pub fn setMode(self: *App, mode: Editor.TextArea.Vim.Mode) void {
    self.mode = mode;

    if (mode == .command) {
        self.last_column = self.current_column;
        // unfocus all colums by setting index to 0
        self.focusColumn(.status_bar);
        self.status_bar.focus();
    }
}

pub fn isAnyOverlayOpen(self: *App) bool {
    return self.buffer_list.list.isFocused();
}

pub fn cancelAction(self: *App) void {
    if (self.mode == .command) {
        self.focusColumn(self.last_column);
        self.status_bar.blur();
    }
}

pub fn quit(self: *App) !void {
    try self.config.meta_infos.write();
    self.should_quit = true;
}

pub fn deinit(self: *App) void {
    self.config.deinit();
    self.alloc.destroy(self.config);

    self.input.deinit();
    self.alloc.destroy(self.input);

    self.buffer_list.deinit();
    self.alloc.destroy(self.buffer_list);

    self.directory_tree.deinit();
    self.alloc.destroy(self.directory_tree);

    self.notes_list.deinit();
    self.alloc.destroy(self.notes_list);

    self.editor.deinit();
    self.alloc.destroy(self.editor);

    self.status_bar.deinit();
    self.alloc.destroy(self.status_bar);

    self.alloc.free(self.notes_root);

    if (self.event_queue) |*queue| {
        queue.deinit();
    }

    self.vx.deinit(self.alloc, self.tty.writer());
    self.tty.deinit();
}

fn resolveArgs(self: *App, args_map: std.StringHashMap(?[]const u8)) void {
    if (args_map.getEntry("no-alt")) |_| {
        self.config.@"no-alt" = true;
    }
    if (args_map.getEntry("virtual-cursor")) |_| {
        self.config.@"virtual-cursor" = true;
    }
}
