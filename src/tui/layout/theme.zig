const std = @import("std");
const vx = @import("vaxis");

pub const Color = struct {
    pub const Border = struct {
        pub const fg: vx.Color = .{ .rgb = .{ 96, 109, 135 } };
        pub const fg_focused: vx.Color = .{ .rgb = .{ 105, 200, 220 } };
    };

    pub const LineNumber = struct {
        pub const fg: vx.Color = .{ .rgb = .{ 110, 110, 110 } };
    };
};

const border_T = [6][]const u8;

pub const Border = struct {
    pub const double: border_T = .{ "╔", "═", "╗", "║", "╝", "╚" };
    pub const thick: border_T = .{ "┏", "━", "┓", "┃", "┛", "┗" };
};
