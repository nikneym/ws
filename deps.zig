const std = @import("std");

pub const pkgs = struct {
    pub const zuri = std.build.Pkg{
        .name = "zuri",
        .source = .{ .path = "lib/zuri/src/zuri.zig" },
    };

    pub const all = [_]std.build.Pkg{
        pkgs.zuri,
    };

    pub fn addAllTo(artifact: *std.build.LibExeObjStep) void {
        inline for (all) |pkg| {
            artifact.addPackage(pkg);
        }
    }
};
