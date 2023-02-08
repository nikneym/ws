const std = @import("std");
const net = std.net;
const mem = std.mem;
const io = std.io;

// these can be used directly too
pub const Client = @import("client.zig").Client;
pub const client = @import("client.zig").client;
pub const Connection = @import("connection.zig").Connection;
pub const Header = [2][]const u8;

pub const Address = union(enum) {
    ip: std.net.Address,
    host: []const u8,

    pub fn resolve(host: []const u8, port: u16) Address {
        const ip = std.net.Address.parseIp(host, port) catch return Address{ .host = host };
        return Address{ .ip = ip };
    }
};

// TODO: implement TLS connection
/// Open a new WebSocket connection.
/// Allocator is used for DNS resolving of host and the storage of response headers.
pub fn connect(allocator: mem.Allocator, url: []const u8, request_headers: ?[]const Header) !Connection {
    const uri = try std.Uri.parse(url);

    const port: u16 = uri.port orelse
        if (mem.eql(u8, uri.scheme, "ws")) 80
        else if (mem.eql(u8, uri.scheme, "wss")) 443
        else return error.UnknownScheme;

    var stream = try switch (Address.resolve(uri.host orelse return error.MissingHost, port)) {
        .ip => |ip| net.tcpConnectToAddress(ip),
        .host => |host| net.tcpConnectToHost(allocator, host, port),
    };
    errdefer stream.close();

    return Connection.init(allocator, stream, uri.path, request_headers);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cli = try connect(allocator, "ws://localhost:8080", &.{
        .{"Host",   "localhost"},
        .{"Origin", "http://localhost/"},
    });
    defer cli.deinit(allocator);

    while (true) {
        var msg = try cli.receive();
        switch (msg.type) {
            .text => {
                std.debug.print("received: {s}\n", .{msg.data});
                try cli.send(.text, msg.data);
            },

            .ping => {
                std.debug.print("got ping! sending pong...\n", .{});
                try cli.pong();
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

    try cli.close();
}
