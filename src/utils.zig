const std = @import("std");

pub fn strEql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn listContains(comptime T: type, list: std.ArrayList(T), elem: T) bool {
    const ListType = @TypeOf(T);
    const list_type_info = @typeInfo(ListType);

    for (list.items) |item| {
        switch (list_type_info) {
            .pointer => |ptr| {
                if (ptr.child == u8) {
                    if (std.mem.eql(T, list.items, elem)) {
                        return true;
                    }
                }
            },
            else => {
                if (item == elem) {
                    return true;
                }
            },
        }
    }

    return false;
}
