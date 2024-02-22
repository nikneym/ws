const std = @import("std");
const client_mod = @import("client.zig");
pub const Connection = @import("connection.zig").Connection;
const common = @import("./common.zig");
const Stream = @import("./stream.zig");

const net = std.net;
const mem = std.mem;
const io = std.io;
const tls = std.crypto.tls;

// these can be used directly too
pub const Client = client_mod.Client;
pub const client = client_mod.client;

pub const Address = union(enum) {
    ip: std.net.Address,
    host: []const u8,

    pub fn resolve(host: []const u8, port: u16) Address {
        const ip = std.net.Address.parseIp(host, port) catch return Address{ .host = host };
        return Address{ .ip = ip };
    }
};

pub const ConnectOptions = struct {
    ca_bundle: ?std.crypto.Certificate.Bundle = null,
    connection_options: Connection.Options = .{},
};

/// Open a new WebSocket connection.
/// Allocator is used for DNS resolving of host and the storage of response headers.
pub fn connect(allocator: mem.Allocator, uri: std.Uri, options: ConnectOptions) !Connection {
    if (uri.host == null) return error.MissingHost;

    const protocol = std.http.Client.protocol_map.get(uri.scheme) orelse return error.UnsupportedUrlScheme;
    const port: u16 = uri.port orelse switch (protocol) {
        .plain => 80,
        .tls => 443,
    };

    var net_stream = try switch (Address.resolve(uri.host orelse return error.MissingHost, port)) {
        .ip => |ip| net.tcpConnectToAddress(ip),
        .host => |host| net.tcpConnectToHost(allocator, host, port),
    };
    errdefer net_stream.close();

    const tls_client: ?tls.Client = switch (protocol) {
        .plain => null,
        .tls => brk: {
            var bundle = options.ca_bundle orelse brk2: {
                var res = std.crypto.Certificate.Bundle{};
                try res.rescan(allocator);
                break :brk2 res;
            };
            defer if (options.ca_bundle == null) bundle.deinit(allocator);
            break :brk try tls.Client.init(net_stream, bundle, uri.host.?);
        },
    };

    const stream = Stream{ .net_stream = net_stream, .tls_client = tls_client };

    return Connection.init(allocator, stream, uri, options.connection_options);
}

test "wss://echo.websocket.org" {
    const allocator = std.testing.allocator;

    var ws = try connect(allocator, try std.Uri.parse("wss://echo.websocket.org"), .{});
    defer ws.deinit(allocator);

    while (true) {
        const msg = try ws.receive();
        switch (msg.type) {
            .text => {
                std.debug.print("received: {s}\n", .{msg.data});
                // try ws.send(.text, msg.data);
                break;
            },

            .ping => {
                std.debug.print("got ping! sending pong...\n", .{});
                try ws.pong();
            },

            .close => {
                std.debug.print("close", .{});
                break;
            },

            else => {
                std.debug.print("got {s}: {s}\n", .{ @tagName(msg.type), msg.data });
            },
        }
    }

    try ws.close();
}
