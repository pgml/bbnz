const Vim = @This();

const std = @import("std");
const vx = @import("vaxis");
const Key = vx.Key;
const TextArea = @import("TextArea.zig");
const Buffer = TextArea.Buffer;
const Input = @import("../../../Input.zig");

const InputError = error{
    NoKeysFound,
    InvalidKeyMap,
};

alloc: std.mem.Allocator,

/// Current vim mode
mode: Mode,

/// Wether vim support is enabled
enabled: bool,

/// The pressed key
key: vx.Key,

/// Current code point
cp: u21 = 0,

current_op: u21,

current_mod: Mod = .none,

textarea: *TextArea,

pub const Mode = enum {
    normal,
    insert,
    replace,
    command,
    visual,
    visual_line,
    visual_block,

    pub fn bgColor(self: Mode) [3]u8 {
        return switch (self) {
            .insert => [_]u8{ 123, 183, 145 },
            .replace => [_]u8{ 158, 132, 183 },
            .visual => [_]u8{ 183, 178, 123 },
            .visual_line => [_]u8{ 183, 178, 123 },
            .visual_block => [_]u8{ 183, 178, 123 },
            else => [_]u8{ 252, 187, 106 },
        };
    }
    pub fn fgColor(self: Mode) [3]u8 {
        return switch (self) {
            .insert => [_]u8{ 23, 83, 45 },
            .replace => [_]u8{ 58, 32, 83 },
            .visual => [_]u8{ 83, 78, 23 },
            .visual_line => [_]u8{ 83, 78, 23 },
            .visual_block => [_]u8{ 83, 78, 23 },
            else => [_]u8{ 140, 140, 140 },
        };
    }

    const tbl = [@typeInfo(Mode).@"enum".fields.len][:0]const u8{
        "normal",
        "insert",
        "replace",
        ":",
        "visual",
        "visual line",
        "visual block",
    };

    pub fn str(self: Mode) [:0]const u8 {
        return tbl[@intFromEnum(self)];
    }
};

const v_fn = *const fn (self: *Vim) void;
const t_fn = *const fn (self: *TextArea) void;

const Cmd = struct {
    cp: u21,
    mod: ?Mod = null,
    v_fn: ?v_fn = null,
    t_fn: ?t_fn = null,
    args: ?CmdArg = null,
};

const CmdArg = enum {
    op,
};

const ta = TextArea;

const Mod = enum {
    none,
    ctrl,
    alt,
    space,
    super,
    shift,
};

// zig fmt: off
//const norm_cmds = [_]Cmd{
//    .{ .cp = '0',  .mod = null,     .v_fn = beginLine,   .args = null },
//    .{ .cp = '^',  .mod = null,     .v_fn = beginLine,   .args = null },
//    .{ .cp = '$',  .mod = null,     .t_fn = ta.lineEnd,  .args = null },
//
//    .{ .cp = 'A',  .mod = null,     .v_fn = edit,          .args = null },
//    .{ .cp = 'C',  .mod = null,     .v_fn = del,           .args = null },
//    .{ .cp = 'D',  .mod = null,     .v_fn = del,           .args = null },
//    .{ .cp = 'G',  .mod = null,     .t_fn = ta.goToBottom, .args = null },
//    .{ .cp = 'I',  .mod = null,     .v_fn = edit,          .args = null },
//    .{ .cp = 'J',  .mod = null,     .t_fn = ta.joinLine,   .args = null },
//    .{ .cp = 'O',  .mod = null,     .v_fn = newLine,       .args = null },
//
//    .{ .cp = 'a',  .mod = null,     .v_fn = edit,              .args = null },
//    .{ .cp = 'b',  .mod = null,     .t_fn = ta.wordLeft,       .args = null },
//    .{ .cp = 'd',  .mod = null,     .v_fn = dCmd,              .args = .op  },
//    .{ .cp = 'd',  .mod = .ctrl,    .t_fn = ta.halfPageDown,   .args = null },
//    .{ .cp = 'e',  .mod = null,     .t_fn = ta.wordRightEnd,   .args = null },
//    .{ .cp = 'g',  .mod = null,     .v_fn = gCmd,              .args = .op  },
//    //.{ .cp = 'h',  .mod = null,     .t_fn = ta.characterLeft,  .args = null },
//    //.{ .cp = 'i',  .mod = null,     .v_fn = edit,              .args = null },
//    //.{ .cp = 'j',  .mod = null,     .v_fn = down,              .args = null },
//    //.{ .cp = 'k',  .mod = null,     .v_fn = up,                .args = null },
//    //.{ .cp = 'l',  .mod = null,     .t_fn = ta.characterRight, .args = null },
//    .{ .cp = 'o',  .mod = null,     .v_fn = newLine,           .args = null },
//    .{ .cp = 'r',  .mod = .ctrl,    .t_fn = ta.redo,           .args = null },
//    .{ .cp = 'u',  .mod = null,     .t_fn = ta.undo,           .args = null },
//    .{ .cp = 'u',  .mod = .ctrl,    .t_fn = ta.halfPageUp,     .args = null },
//    .{ .cp = 'w',  .mod = null,     .t_fn = ta.wordRight,      .args = null },
//    //.{ .cp = 'w',  .mod = .ctrl,    .v_fn = wCmd,              .args = .op  },
//    .{ .cp = 'x',  .mod = null,     .v_fn = del,               .args = null },
//    .{ .cp = 'z',  .mod = null,     .v_fn = zCmd,              .args = .op  },
//
//    .{ .cp = Key.enter,   .v_fn = newLine },
//    .{ .cp = Key.up,      .v_fn = up },
//    .{ .cp = Key.down,    .v_fn = down },
//    .{ .cp = Key.left,    .t_fn = ta.characterLeft },
//    .{ .cp = Key.right,   .t_fn = ta.characterRight },
//    .{ .cp = Key.escape,  .v_fn = esc },
//};
//
//const ins_cmds = [_]Cmd{
//    .{ .cp = Key.escape,     .v_fn = esc },
//    .{ .cp = Key.enter,      .v_fn = newLine },
//    .{ .cp = Key.backspace,  .v_fn = del },
//    .{ .cp = Key.delete,     .v_fn = del },
//    .{ .cp = Key.tab,        .v_fn = tab },
//};
// zig fmt: on

//const cmd_table = struct {
//    normal: []const Cmd,
//    insert: []const Cmd,
//}{
//    .normal = &norm_cmds,
//    .insert = &ins_cmds,
//};

pub fn init(alloc: std.mem.Allocator) !*Vim {
    const self = try alloc.create(Vim);

    self.* = .{
        .alloc = alloc,
        .mode = .normal,
        .enabled = false,
        .current_op = 0,
        .key = undefined,
        .textarea = undefined,
    };

    return self;
}

pub fn update(self: *Vim, event: TextArea.Event, textarea: *TextArea) !void {
    switch (event) {
        .key_press => |key| {
            self.textarea = textarea;
            self.key = key;
            self.cp = key.codepoint;

            if (key.shifted_codepoint) |scp| {
                self.cp = scp;
            }

            if (self.mode == .insert) {
                if (self.key.text) |text| {
                    self.textarea.insertSliceAtCursor(text) catch return;
                }
            }
        },
    }
}

//pub fn dispatchCmds(self: *Vim) void {
//    const cmds = switch (self.mode) {
//        .normal => cmd_table.normal,
//        .insert => cmd_table.insert,
//        else => &[_]Cmd{},
//    };
//
//    self.current_mod = .none;
//
//    for (cmds) |cmd| {
//        if (self.key.mods.ctrl) {
//            self.current_mod = .ctrl;
//        }
//        if (self.key.mods.shift) {
//            self.current_mod = .shift;
//        }
//
//        if (cmd.cp != self.cp) {
//            continue;
//        }
//
//        if (self.current_op == 0 and self.current_mod == .none) {
//            if (cmd.args) |arg| {
//                if (arg == .op) {
//                    self.current_op = self.cp;
//                    return;
//                }
//            }
//        } else {
//            if (getOptFn(self.current_op)) |func| {
//                func(self);
//                return;
//            }
//        }
//
//        if (self.current_mod == .ctrl) {
//            if (cmd.mod != null) {
//                self.execFn(cmd);
//            }
//            continue;
//        }
//
//        if (cmd.mod == null) {
//            self.execFn(cmd);
//        }
//
//        return;
//    }
//
//    if (self.mode == .normal) {
//        self.resetSeq();
//    }
//
//    if (self.mode == .insert) {
//        if (self.key.text) |text| {
//            self.textarea.insertSliceAtCursor(text) catch return;
//        }
//    }
//}
//
//pub fn execFn(self: *Vim, cmd: Cmd) void {
//    if (cmd.v_fn) |func| {
//        func(self);
//    }
//
//    if (cmd.t_fn) |func| {
//        func(self.textarea);
//    }
//}
//
//pub fn getOptFn(op_cp: u21) ?v_fn {
//    for (cmd_table.normal) |cmd| {
//        if (cmd.cp == op_cp) {
//            return cmd.v_fn;
//        }
//    }
//
//    return null;
//}

pub fn enable(self: *Vim) void {
    self.enabled = true;
}

pub fn disable(self: *Vim) void {
    self.enabled = false;
}

pub fn setMode(self: *Vim, mode: Mode) void {
    const buf: *TextArea.Buffer = self.textarea.curBuf();
    const textarea: *TextArea = self.textarea;

    self.mode = mode;
    textarea.app.setMode(self.mode);

    switch (mode) {
        .normal => {
            const last_hash = Buffer.fastHash(buf.prev_value);
            const buf_hash = buf.getHash() catch return;

            // only update if there's a change otherwise
            // remove the entry we added in newHistoryEntry
            if (last_hash != buf_hash) {
                textarea.updateHistoryEntry() catch return;
            }

            const meta = textarea.app.config.meta_infos;
            meta.updateFileInfo(buf.path, .cursor_pos, buf.cursor_pos) catch return;
            textarea.selection = null;

            if (self.textarea.win) |win| {
                win.screen.cursor_shape = .block;
            }
        },
        .insert => {
            self.enterInsertMode(true);
        },
        else => {},
    }

    if (mode == .visual_line or mode == .visual) {
        if (textarea.selection == null) {
            textarea.selection = .init(mode, buf.cursor_pos);
        }
    }
}

/// Sets the mode to `insert` and changes the cursor shape to a blinking beam.
/// If `with_history` is true it also create a new history entry._
fn enterInsertMode(self: *Vim, with_history: bool) void {
    if (with_history) {
        self.textarea.newHistoryEntry();
    }

    self.mode = .insert;
    self.textarea.app.mode = self.mode;

    // if (self.textarea.win) |win| {
    //     win.screen.cursor_shape = .beam_blink;
    // }
}

pub fn resetSeq(self: *Vim) void {
    self.current_op = 0;
}

pub fn visual(self: *Vim, flags: ?Input.Flags) void {
    const line = Input.flagsContain(flags, .line);

    if (line) {
        if (self.mode == .normal or self.mode == .visual) {
            self.setMode(.visual_line);
        } else {
            self.setMode(.normal);
        }
    } else {
        if (self.mode == .normal or self.mode == .visual_line) {
            self.setMode(.visual);
        } else {
            self.setMode(.normal);
        }
    }
}

/// Handle "i", "I", "a" and "A" commands.
pub fn edit(self: *Vim, flags: ?Input.Flags) void {
    _ = flags;

    self.setMode(.insert);

    switch (self.cp) {
        'a' => self.textarea.characterRight(),
        'A' => {
            self.textarea.lineEnd();
            self.textarea.characterRight();
        },
        'I' => self.textarea.beginLine(true),
        else => {},
    }
}

pub fn up(self: *Vim, flags: ?Input.Flags) void {
    _ = flags;
    if (self.cp == Key.up) {
        self.cp = 'k';
    }

    self.textarea.cursorUp();
}

pub fn down(self: *Vim, flags: ?Input.Flags) void {
    _ = flags;
    if (self.cp == Key.down) {
        self.cp = 'j';
    }

    self.textarea.cursorDown();
}

pub fn newLine(self: *Vim, flags: ?Input.Flags) void {
    _ = flags;
    switch (self.cp) {
        Key.enter => {
            switch (self.mode) {
                .normal => {
                    self.textarea.cursorDown();
                    self.textarea.beginLine(true);
                },
                .insert => self.textarea.addNewLine(),
                else => {},
            }
        },
        'O' => {
            self.setMode(.insert);
            self.textarea.addLineAbove() catch return;
            self.textarea.beginLine(true);
        },
        'o' => {
            self.setMode(.insert);
            self.textarea.addLineBelow() catch return;
            self.textarea.beginLine(true);
        },
        else => {},
    }
}

pub fn beginLine(self: *Vim, flags: ?Input.Flags) void {
    const non_white = Input.flagsContain(flags, .non_white);

    self.textarea.beginLine(non_white);

    //switch (self.cp) {
    //    // move cursor to the first non-white character.
    //    '^' => self.textarea.beginLine(true),
    //    // move cursor to the start of the line.
    //    '0' => self.textarea.beginLine(false),
    //    else => {},
    //}
}

pub fn del(self: *Vim, flags: ?Input.Flags) void {
    switch (self.cp) {
        'C' => {
            // we dont need history stuff here since it's handled
            // in the setMode function
            self.changeAfterCursor(flags);
        },
        'D' => {
            self.textarea.newHistoryEntry();
            self.deleteAfterCursor(flags);
            self.textarea.updateHistoryEntry() catch return;
        },
        'x' => {
            self.textarea.newHistoryEntry();
            self.textarea.deleteCurChar();
            self.textarea.updateHistoryEntry() catch return;
        },
        Key.delete => {
            self.textarea.deleteCurChar();
        },
        Key.backspace => {
            const buf = self.textarea.curBuf();
            const col = if (buf.col > 0) buf.col - 1 else return;
            _ = self.textarea.deleteCharAt(col);
        },
        else => self.resetSeq(),
    }
}

pub fn tab(self: *Vim, flags: ?Input.Flags) void {
    _ = flags;
    // @todo make configureable
    const tab_size = 4;
    for (0..tab_size) |_| {
        self.textarea.insertSliceAtCursor(" ") catch return;
    }
}

pub fn cCmd(self: *Vim, flags: ?Input.Flags) void {
    const t = self.textarea;

    // Even though `setMode(.insert)` automatically creates a history entry
    // we need to create one here because we need a point before
    // any changes to the text happen.
    t.newHistoryEntry();

    if (Input.flagsContain(flags, .word)) {
        self.delWordActions(flags);
    }

    if (Input.flagsContain(flags, .selection)) {
        t.deleteSelection() catch return;
    }

    if (Input.flagsContain(flags, .line)) {
        self.delLineActions(flags);
        // We add a line above the deleted one so that we
        // have a fresh line to insert stuff into
        t.addLineAbove() catch return;
    }

    // set insert mode after any text changes happpen because
    // some delete functions may temporarily slip into other modes.
    self.enterInsertMode(false);
    self.resetSeq();
    t.app.status_bar.clearColumn(.key_info) catch return;
}

pub fn dCmd(self: *Vim, flags: ?Input.Flags) void {
    const t = self.textarea;
    t.newHistoryEntry();

    // delete word actions
    if (Input.flagsContain(flags, .word)) {
        self.delWordActions(flags);
    }

    if (Input.flagsContain(flags, .selection)) {
        t.deleteSelection() catch return;
    }

    // delete line actions
    if (Input.flagsContain(flags, .line)) {
        self.delLineActions(flags);
    }

    self.setMode(.normal);
    self.resetSeq();
}

/// Deletes the current line or the current line including the
/// line above or under depending on if `flags` contains
/// `FlagValue.above` or `FlagValue.below`.
fn delLineActions(self: *Vim, flags: ?Input.Flags) void {
    const t = self.textarea;
    if (Input.flagsContain(flags, .above)) {
        t.cursorUp();
        t.deleteNLines(2);
    } else if (Input.flagsContain(flags, .below)) {
        t.deleteNLines(2);
    } else {
        t.deleteCurLine(true);
    }
}

/// Deletes the current word or the rest of the word from the cursor
/// position if flags contains `FlagValue.remaining`.
fn delWordActions(self: *Vim, flags: ?Input.Flags) void {
    const t = self.textarea;
    const buf = t.curBuf();

    if (Input.flagsContain(flags, .from_cursor)) {
        const end_word = t.getLastColumnOfWord();
        t.selectRange(buf.cursorPos(), .{
            .row = buf.row,
            .col = end_word,
        });
    } else {
        self.selectWord(flags);
    }
    t.deleteSelection() catch return;
}

pub fn gCmd(self: *Vim, flags: ?Input.Flags) void {
    _ = flags;
    switch (self.cp) {
        'g' => self.textarea.goToTop(),
        else => {},
    }
    self.resetSeq();
}

pub fn wCmd(self: *Vim, flags: ?Input.Flags) void {
    _ = flags;
    switch (self.cp) {
        'h' => self.textarea.app.focusPrevColumn(false),
        'l' => self.textarea.app.focusNextColumn(false),
        else => {},
    }
}

pub fn zCmd(self: *Vim, flags: ?Input.Flags) void {
    _ = flags;
    switch (self.cp) {
        //'z' => self.textarea.centreView(),
        else => {},
    }
    self.resetSeq();
}

pub fn deleteAfterCursor(self: *Vim, flags: ?Input.Flags) void {
    _ = flags;
    self.textarea.deleteAfterCursor() catch return;
    self.textarea.characterLeft();
}

pub fn changeAfterCursor(self: *Vim, flags: ?Input.Flags) void {
    self.setMode(.insert);
    self.deleteAfterCursor(flags);
    self.textarea.characterRight();
}

pub fn select(self: *Vim, flags: ?Input.Flags) void {
    const tarea = self.textarea;

    self.setMode(.normal);
    tarea.selection = null;

    const buf: *Buffer = tarea.curBuf();
    const row: *Buffer.Row = buf.curRow();
    const row_len: i32 = @intCast(row.len());

    if ((buf.col < 0 and buf.row > 0) or row_len == 0) {
        return;
    }

    const cur_char = row.getValue()[@intCast(buf.col)];

    var p_index = buf.col - 1;
    p_index = std.math.clamp(buf.col, 0, row_len - 1);
    const p_char = row.getValue()[@intCast(p_index)];

    var n_index = buf.col + 1;
    n_index = std.math.clamp(buf.col, 0, row_len - 1);
    const n_char = row.getValue()[@intCast(n_index)];

    // if it's a single character or not a character at all
    // just select the whitespace, enter visual mode and return
    if ((TextArea.charIsSpace(p_char.grapheme) and
        TextArea.charIsSpace(n_char.grapheme)) or
        TextArea.charIsSpace(cur_char.grapheme))
    {
        tarea.selectRange(buf.cursorPos(), buf.cursorPos());
        self.setMode(.visual);
        return;
    }

    const first_char = tarea.getFirstColumnOfWord();
    var last_char = tarea.getLastColumnOfWord();

    if (Input.flagsContain(flags, .outer)) {
        last_char += 1;
    }

    tarea.selectRange(
        .{ .row = buf.row, .col = @intCast(first_char) },
        .{ .row = buf.row, .col = @intCast(last_char) },
    );
}

fn selectWord(self: *Vim, flags: ?Input.Flags) void {
    const t = self.textarea;
    self.select(flags);
    // if we need to delete the space after the word
    // just move the selection one character to the right
    if (Input.flagsContain(flags, .outer)) {
        t.characterRight();
    }
}

pub fn esc(self: *Vim, flags: ?Input.Flags) void {
    _ = flags;
    switch (self.mode) {
        .insert => {
            self.textarea.characterLeft();
        },
        .normal => {
            self.resetSeq();
        },
        else => {},
    }

    if (self.mode != .normal) {
        self.setMode(.normal);
    }
}

pub fn deinit(self: *Vim) void {
    _ = self;
}
