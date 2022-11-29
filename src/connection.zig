const std = @import("std");
const net = std.net;
const mem = std.mem;
const io = std.io;

const Receiver = @import("receiver.zig").Receiver;
const Sender = @import("sender.zig").Sender;

const common = @import("common.zig");
const Opcode = common.Opcode;
const Message = common.Message;

const READ_BUFFER_SIZE: usize = 1024 * 8;
const WRITE_BUFFER_SIZE: usize = 1024 * 4;

/// This is a direct implementation of ws over regular net.Stream.
/// The Connection object will always use the current Stream implementation of net namespace.
pub const Connection = struct {
    stream: net.Stream,
    reader: Reader,
    writer: Writer,
    receiver: Receiver(Reader.Reader, READ_BUFFER_SIZE),
    sender: Sender(Writer, WRITE_BUFFER_SIZE),

    const Reader = io.BufferedReader(4096, net.Stream.Reader);
    const Writer = net.Stream.Writer;

    /// Create a new WebSocket connection together with net.Stream.
    pub fn init(allocator: mem.Allocator, stream: net.Stream, host: []const u8, path: []const u8) !Connection {
        var buffered_reader = io.bufferedReader(stream.reader());
        var writer = stream.writer();

        var self = Connection{
            .stream = stream,
            .reader = buffered_reader,
            .writer = writer,
            .receiver = .{ .reader = buffered_reader.reader() },
            .sender = .{ .writer = writer },
        };

        try self.handshake(allocator, host, path);
        return self;
    }

    /// Deinitialize the object.
    pub fn deinit(self: Connection) void {
        self.stream.close();
    }

    fn handshake(self: *Connection, allocator: mem.Allocator, host: []const u8, path: []const u8) !void {
        try self.sender.sendRequest(allocator, host, path);
        try self.receiver.receiveResponse();
    }

    /// Send any kind of WebSocket message to the server.
    pub fn send(self: *Connection, opcode: Opcode, payload: ?[]const u8) !void {
        return self.sender.send(opcode, payload);
    }

    /// Send a text message to the server.
    pub fn sendText(self: *Connection, payload: ?[]const u8) !void {
        return self.sender.send(.text, payload);
    }

    /// Send a binary message to the server.
    pub fn sendBinary(self: *Connection, payload: ?[]const u8) !void {
        return self.sender.send(.binary, payload);
    }

    /// Send a ping message to the server.
    /// If you need to send a payload with this frame, use `send`.
    pub fn ping(self: *Connection) !void {
        return self.sender.send(.ping, null);
    }

    /// Send a pong message to the server.
    /// If you need to send a payload with this frame, use `send`.
    pub fn pong(self: *Connection) !void {
        return self.sender.send(.pong, null);
    }

    /// Close the connection.
    pub fn close(self: *Connection) !void {
        return self.sender.close();
    }

    /// TODO: Add usage example
    /// Send continuation frames to the server.
    pub fn streams(self: *Connection, opcode: Opcode, payload: ?[]const u8) !void {
        return self.sender.stream(opcode, payload);
    }

    /// Receive a message from the server.
    pub fn receive(self: *Connection) !Message {
        return self.receiver.receive();
    }
};
