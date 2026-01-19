const Config = @This();

const std = @import("std");
const env = @import("env.zig");

var arena: std.heap.ArenaAllocator = undefined;

var alloc: std.mem.Allocator = undefined;

pub const application_name = "bellbird-notes";

pub fn init(allocator: std.mem.Allocator) !void {
    arena = std.heap.ArenaAllocator.init(allocator);
    alloc = arena.allocator();
}

pub fn getConfDirPath() ![]const u8 {
    if (std.posix.getenv(env.xdg_config_home)) |conf_home_path| {
        const app_dir_path: []const u8 = try std.mem.concat(alloc, u8, &[_][]const u8{
            conf_home_path,
            "/",
            application_name,
        });

        var app_conf_dir: std.fs.Dir = try std.fs.openDirAbsolute(
            conf_home_path,
            .{},
        );

        app_conf_dir.makePath(app_dir_path) catch |err| {
            std.log.err("Failed to create config directory: {}", .{err});
            return "";
        };

        return app_dir_path;
    }

    return "";
}

pub fn deinit() void {
    arena.deinit();
}
