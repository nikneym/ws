const std = @import("std");
const mem = std.mem;

const common = @import("common.zig");
const Message = common.Message;
const Opcode = common.Opcode;

const Receiver = @import("receiver.zig").Receiver;
const Sender = @import("sender.zig").Sender;

/// Create a new WebSocket client.
/// This interface is for using your own reader and writer.
pub fn client(
    reader: anytype,
    writer: anytype,
    read_buffer: []u8,
    write_buffer: []u8,
) Client(@TypeOf(reader), @TypeOf(writer)) {
    var mask: [4]u8 = undefined;
    std.crypto.random.bytes(&mask);

    return .{
        .receiver = .{ .reader = reader, .buffer = read_buffer },
        .sender = .{ .writer = writer, .mask = mask, .buffer = write_buffer },
    };
}

/// Create a new WebSocket client.
/// This interface is for using your own reader and writer.
pub fn Client(
    comptime Reader: type,
    comptime Writer: type,
) type {
    return struct {
        const Self = @This();

        receiver: Receiver(Reader),
        sender: Sender(Writer),

        pub fn deinit(
            self: Self,
            allocator: mem.Allocator,
            headers: *std.StringHashMapUnmanaged([]const u8),
        ) void {
            self.receiver.freeHttpHeaders(allocator, headers);
            allocator.free(self.receiver.buffer);
            allocator.free(self.sender.buffer);
        }

        pub fn handshake(
            self: *Self,
            allocator: mem.Allocator,
            uri: std.Uri,
            extra_headers: []const common.HttpHeader,
            response_headers: *std.StringHashMapUnmanaged([]const u8),
        ) !void {
            // create a random Sec-WebSocket-Key
            var buf: [24]u8 = undefined;
            std.crypto.random.bytes(buf[0..16]);
            const key = std.base64.standard.Encoder.encode(&buf, buf[0..16]);

            try self.sender.sendRequest(uri, extra_headers, key);
            try self.receiver.receiveResponse(allocator, response_headers);
            errdefer self.receiver.freeHttpHeaders(allocator, response_headers);

            // var iter = response_headers.iterator();
            // while (iter.next()) |kv| {
            //     std.debug.print("{s}={s}\n", .{ kv.key_ptr.*, kv.value_ptr.* });
            // }

            try checkWebSocketAcceptKey(response_headers.*, key);
        }

        const WsAcceptKeyError = error{ KeyControlFailed, AcceptKeyNotFound };

        /// Controls the accept key received from the server
        fn checkWebSocketAcceptKey(
            headers: std.StringHashMapUnmanaged([]const u8),
            key: []const u8,
        ) WsAcceptKeyError!void {
            if (headers.get("sec-websocket-accept")) |sec_websocket_accept| {
                const magic_string = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

                var hash_buf: [20]u8 = undefined;
                var h = std.crypto.hash.Sha1.init(.{});
                h.update(key);
                h.update(magic_string);
                h.final(&hash_buf);

                var encoded_hash_buf: [28]u8 = undefined;
                const our_accept = std.base64.standard.Encoder.encode(&encoded_hash_buf, &hash_buf);

                if (!mem.eql(u8, our_accept, sec_websocket_accept))
                    return error.KeyControlFailed;
            } else return error.AcceptKeyNotFound;
        }

        /// Send a WebSocket message to the server.
        /// The `opcode` field can be text, binary, ping, pong or close.
        /// In order to send continuation frames or streaming messages, check out `stream` function.
        pub fn send(self: *Self, opcode: Opcode, data: []const u8) !void {
            return self.sender.send(opcode, data);
        }

        /// Send a ping message to the server.
        pub fn ping(self: *Self) !void {
            return self.send(.ping, "");
        }

        /// Send a pong message to the server.
        pub fn pong(self: *Self) !void {
            return self.send(.pong, "");
        }

        /// Send a close message to the server.
        pub fn close(self: *Self) !void {
            return self.sender.close();
        }

        /// TODO: Add usage example
        /// Send continuation frames or streaming messages to the server.
        pub fn stream(self: *Self, opcode: Opcode, payload: ?[]const u8) !void {
            return self.sender.stream(opcode, payload);
        }

        /// Receive a message from the server.
        pub fn receive(self: *Self) !Message {
            return self.receiver.receive();
        }
    };
}
