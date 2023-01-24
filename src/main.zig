const std = @import("std");
const net = std.net;
const mem = std.mem;
const io = std.io;
const Uri = @import("zuri").Uri;

// these can be used directly too
pub const Client = @import("client.zig").Client;
pub const client = @import("client.zig").client;
pub const Connection = @import("connection.zig").Connection;
pub const Server = @import("server.zig").Server;
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

    var server = try Server.init("/chat", try net.Address.parseIp("127.0.0.1", 8080));
    defer server.deinit();

    var cli = try server.accept(allocator);
    defer cli.deinit();
}
