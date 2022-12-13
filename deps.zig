const std = @import("std");

pub fn relativeToThis(comptime s: []const u8) []const u8 {
    return comptime std.fs.path.dirname(@src().file).? ++ std.fs.path.sep_str ++ s;
}

pub fn addAllTo(artifact: *std.build.LibExeObjStep) void {
    artifact.addPackagePath("zuri", relativeToThis("lib/zuri/src/zuri.zig"));
}
