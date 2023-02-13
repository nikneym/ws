const std = @import("std");
const net = std.net;
const mem = std.mem;
const io = std.io;

// these can be used directly too
pub const Client = @import("client.zig").Client;
pub const client = @import("client.zig").client;
pub const Connection = @import("connection.zig").Connection;
pub const Server = @import("server.zig").Server;
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
pub fn connect(allocator: mem.Allocator, uri: std.Uri, request_headers: ?[]const Header) !Connection {
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

test "Server on :8080" {
    const allocator = std.testing.allocator;

    var server = try Server.init("/chat", try net.Address.parseIp("127.0.0.1", 8080));
    defer server.deinit();

    var cli = try server.accept(allocator);
    defer cli.deinit(allocator);

    while (true) {
        const message = try cli.receiver.receive();
        switch (message.type) {
            .binary => {
                std.debug.print("binary: {any}\n", .{ message.data });
            },

            .close => {
                std.debug.print("close: {s} code: {?}\n", .{ message.data, message.code });
                break;
            },

            else => {
                std.debug.print("{s}: {s}\n", .{ @tagName(message.type), message.data });
            },
        }
    }
}
