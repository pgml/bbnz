const std = @import("std");
const vaxis = @import("vaxis");

const App = @import("App.zig");
const log = @import("log.zig");

pub const std_options: std.Options = .{
    .logFn = log.toFile,
};

pub const KnownFolderConfig = struct {
    xdg_force_default: bool = false,
    xdg_on_mac: bool = false,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.log.err("memory leak", .{});
        }
    }
    const alloc = gpa.allocator();

    try log.init(alloc);
    defer log.deinit();

    var proc_args = try std.process.argsWithAllocator(alloc);
    defer proc_args.deinit();

    var args: std.StringHashMap(?[]const u8) = .init(alloc);
    defer args.deinit();

    while (proc_args.next()) |arg| {
        const a: []const u8 = arg;
        var key_val = std.mem.splitAny(u8, a, "=");
        try args.put(key_val.first()[2..], key_val.next());
    }

    var app = try App.init(alloc, args);

    defer app.deinit();
    try app.run();
}
