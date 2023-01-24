const std = @import("std");
const net = std.net;

// FIXME: add an option to change request buffer size?
// FIXME: use StringHashMapUnmanaged([]const u8) instead
pub const IncomingConnection = struct {
    // this will hold url and request headers
    req_buffer: [4096]u8 = undefined,
    headers: std.StringHashMap([]const u8),
    reader: net.Stream.Reader,

    pub fn deinit(self: *IncomingConnection) void {
        self.headers.deinit();
    }
};
