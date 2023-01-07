const std = @import("std");
const net = std.net;
const mem = std.mem;
const io = std.io;
const Uri = @import("zuri").Uri;

// these can be used directly too
pub const Connection = @import("connection.zig").Connection;
pub const Header = [2][]const u8;

// TODO: implement TLS connection
/// Open a new WebSocket connection.
/// Allocator is used for DNS resolving of host and the storage of response headers.
pub fn connect(allocator: mem.Allocator, url: []const u8, request_headers: ?[]const Header) !Connection {
    const uri = try Uri.parse(url, true);

    const port: u16 = uri.port orelse
        if (mem.eql(u8, uri.scheme, "ws")) 80
        else if (mem.eql(u8, uri.scheme, "wss")) 443
        else return error.UnknownScheme;

    var stream = try switch (uri.host) {
        .ip => |address| net.tcpConnectToAddress(address),
        .name => |host| net.tcpConnectToHost(allocator, host, port),
    };
    errdefer stream.close();

    return Connection.init(allocator, stream, uri.path, request_headers);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try connect(allocator, "ws://localhost:8080", &.{
        .{"Host",   "localhost"},
        .{"Origin", "http://localhost/"},
    });
    defer client.deinit(allocator);

    while (true) {
        var msg = try client.receive();
        switch (msg.type) {
            .text => {
                std.debug.print("received: {s}\n", .{msg.data});
                try client.send(.text, msg.data);
            },

            .ping => {
                std.debug.print("got ping! sending pong...\n", .{});
                try client.pong();
            },

            .close => {
                std.debug.print("close", .{});
                break;
            },

            else => {
                std.debug.print("got {s}: {s}\n", .{@tagName(msg.type), msg.data});
            },
        }
    }

    try client.close();
}
