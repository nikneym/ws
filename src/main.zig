const std = @import("std");
const net = std.net;
const mem = std.mem;
const io = std.io;

const Uri = @import("zuri").Uri;

const cli = @import("client.zig");
pub const createClient = cli.createClient;
pub const Client = cli.Client;

pub const Connection = @import("connection.zig").Connection;

pub fn connect(allocator: mem.Allocator, url: []const u8) !Connection {
    const uri = try Uri.parse(url, true);

    if (!(mem.eql(u8, uri.scheme, "ws") or mem.eql(u8, uri.scheme, "wss")))
        return error.UnknownScheme;

    var client = try switch (uri.host) {
        .ip => |address| net.tcpConnectToAddress(address),
        .name => |host| net.tcpConnectToHost(allocator, host, uri.port orelse 80),
    };

    const host = switch (uri.host) {
        .ip => "", // FIXME
        .name => |host| host,
    };

    return Connection.init(allocator, client, host, uri.path);
}

test "connect to localhost:8080" {
    const allocator = std.testing.allocator;

    var client = try connect(allocator, "ws://localhost:8080/");
    defer client.deinit();

    var msg = try client.receive();
    switch (msg.type) {
        .text => {
            std.debug.print("received: {s}\n", .{msg.data});
            try client.sendText(msg.data);
        },

        .ping => {
            std.debug.print("got ping! sending pong...\n", .{});
            try client.pong();
        },

        else => unreachable,
    }

    try client.close();
}
